import AppKit
import Foundation
import Security
import SwiftUI

/// Encrypted storage for everything private (meetings, transcripts, notes, chats, app state).
///
/// The data lives in an AES-256 encrypted APFS disk image (a sparse bundle) next to the app's support folder. Its
/// random passphrase is kept in the login Keychain for this Mac only. The app mounts the image at launch (hidden from
/// Finder and Spotlight) and detaches it on quit, so copies of the image, Time Machine backups and iCloud never hold
/// readable notes. While mounted, programs running as the same user can read it, like any open file.
///
/// Older plaintext data is copied in once and checked; the plaintext originals stay until the user deletes them.
/// Call `Vault.openOrQuit()` at launch, after setting `InferoidPaths.folderName`, before anything reads or writes.
public enum Vault {
    /// Where the vault is mounted while the app runs, or nil before `open()` succeeds.
    public private(set) static var mountPoint: URL?
    /// Top-level support items that are not private and stay outside the vault (e.g. a downloaded runtime).
    public static var keepOutside: Set<String> = []
    /// Plaintext items from before the vault that still exist, for the "delete old copies" prompt.
    public static var legacyItems: [URL] {
        [legacyDocuments, legacySupport].flatMap(privateItems)
    }

    static var image: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(InferoidPaths.folderName) Vault.sparsebundle")
    }
    static var mountTarget: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".\(InferoidPaths.folderName) Vault", isDirectory: true)
    }
    static var legacyDocuments: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(InferoidPaths.folderName)
    }
    static var legacySupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(InferoidPaths.folderName, isDirectory: true)
    }
    static var keychainService: String { "ai.inferoid.vault.\(InferoidPaths.folderName)" }

    public enum VaultError: LocalizedError {
        case keychain(OSStatus), tool(String), copyMismatch(String)
        public var errorDescription: String? {
            switch self {
            case .keychain(let s): return "The vault key could not be read from the Keychain (error \(s))."
            case .tool(let m): return "The encrypted vault could not be opened: \(m)"
            case .copyMismatch(let m): return "Moving your notes into the vault did not check out (\(m)). Nothing was deleted."
            }
        }
    }

    /// Creates the vault on first use, mounts it, and points InferoidPaths inside it. Throws instead of falling back
    /// to unencrypted storage.
    public static func open() throws {
        if let mountPoint, FileManager.default.fileExists(atPath: mountPoint.path) { return }
        let fm = FileManager.default
        let firstRun = !fm.fileExists(atPath: image.path)
        let pass: String
        if firstRun {
            pass = try newPassphrase()
            try storePassphrase(pass)  // key first: an image must never exist without its key
            try fm.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try hdiutil(["create", "-size", "500g", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-encryption", "AES-256",
                             "-stdinpass", "-volname", "Inferoid Vault", image.path], stdin: pass)
            } catch {
                try? fm.removeItem(at: image)
                throw error
            }
        } else {
            pass = try readPassphrase()
        }
        detachStale()
        try fm.createDirectory(at: mountTarget, withIntermediateDirectories: true)
        try hdiutil(["attach", image.path, "-stdinpass", "-nobrowse", "-owners", "on", "-noautoopen",
                     "-mountpoint", mountTarget.path], stdin: pass)
        // Keep Spotlight from indexing private text.
        fm.createFile(atPath: mountTarget.appendingPathComponent(".metadata_never_index").path, contents: nil)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mountTarget.path)
        mountPoint = mountTarget
        InferoidPaths.privateRoot = mountTarget
        try fm.createDirectory(at: InferoidPaths.documents, withIntermediateDirectories: true)
        try fm.createDirectory(at: InferoidPaths.support, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: mountTarget.appendingPathComponent(".migrated").path) {
            try migrate()
            fm.createFile(atPath: mountTarget.appendingPathComponent(".migrated").path, contents: nil)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            close()
        }
    }

    /// Detaches the vault (on quit). Data stays encrypted on disk.
    public static func close() {
        guard let point = mountPoint else { return }
        _ = try? hdiutil(["detach", point.path])
        mountPoint = nil
    }

    /// Opens at launch. On failure the app shows `VaultErrorView` (Retry / Quit) instead of its window and never
    /// continues without encryption.
    @MainActor public static func openAtLaunch() {
        do { try open(); VaultState.shared.error = nil } catch { VaultState.shared.error = error.localizedDescription }
    }

    /// Copies the pre-vault plaintext folders in and checks file counts and sizes. Originals are left in place.
    static func migrate() throws {
        let pairs = [(legacyDocuments, InferoidPaths.documents), (legacySupport, InferoidPaths.support)]
        for (from, to) in pairs {
            for item in privateItems(from) {
                let dest = to.appendingPathComponent(item.lastPathComponent)
                _ = try run("/usr/bin/ditto", [item.path, dest.path], stdin: nil)
                let a = inventory(item), b = inventory(dest)
                for (path, size) in a where b[path] != size {
                    throw VaultError.copyMismatch(item.lastPathComponent + path)
                }
            }
        }
    }

    /// Deletes the plaintext copies left from before the vault (user action only). Moves them to the Trash.
    public static func deleteLegacyCopies() throws {
        for item in legacyItems {
            try FileManager.default.trashItem(at: item, resultingItemURL: nil)
        }
    }

    /// A readable Markdown copy of every meeting, for Obsidian or backup. This copy is NOT encrypted.
    public static func exportMeetings(to folder: URL) throws {
        let dest = folder.appendingPathComponent("\(InferoidPaths.folderName) export")
        _ = try run("/usr/bin/ditto", [InferoidPaths.documents.path, dest.path], stdin: nil)
    }

    // MARK: helpers

    static func privateItems(_ folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && !keepOutside.contains($0) }.sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Relative path -> size for every regular file under `root` (a single file maps "" to its size).
    static func inventory(_ root: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        if let v = try? root.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true {
            return ["": v.fileSize ?? 0]
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return out }
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out[String(url.path.dropFirst(root.path.count))] = v.fileSize ?? 0
        }
        return out
    }

    static func detachStale() {
        if FileManager.default.fileExists(atPath: mountTarget.appendingPathComponent(".metadata_never_index").path) {
            _ = try? hdiutil(["detach", mountTarget.path, "-force"])
        }
    }

    @discardableResult
    static func hdiutil(_ args: [String], stdin: String? = nil) throws -> String {
        try run("/usr/bin/hdiutil", args, stdin: stdin)
    }

    static func run(_ tool: String, _ args: [String], stdin: String?) throws -> String {
        let p = Process(); let out = Pipe(); let input = Pipe()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = out; p.standardError = out; p.standardInput = input
        try p.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw VaultError.tool(text.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)")
        }
        return text
    }

    // MARK: Keychain (this Mac only, available after the user logs in)

    static func newPassphrase() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw VaultError.keychain(-1) }
        return Data(bytes).base64EncodedString()
    }

    static func storePassphrase(_ pass: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService, kSecAttrAccount as String: "vault"]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(pass.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Inferoid vault key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    static func readPassphrase() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "vault", kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let pass = String(data: data, encoding: .utf8) else {
            throw VaultError.keychain(status)
        }
        return pass
    }
}

/// Whether the vault failed to open, for the window to show `VaultErrorView` instead of the app.
@MainActor public final class VaultState: ObservableObject {
    public static let shared = VaultState()
    @Published public var error: String?
}

/// Shown instead of the app when the encrypted vault cannot be opened.
public struct VaultErrorView: View {
    @ObservedObject private var state = VaultState.shared
    public init() {}
    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.trianglebadge.exclamationmark").font(.system(size: 40))
            Text("Inferoid could not open your encrypted notes").font(.title2)
            Text(state.error ?? "").foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Inferoid will not save anything unencrypted.").font(.callout)
            HStack {
                Button("Retry") { Vault.openAtLaunch() }.keyboardShortcut(.defaultAction)
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(40).frame(minWidth: 560, minHeight: 360)
    }
}
