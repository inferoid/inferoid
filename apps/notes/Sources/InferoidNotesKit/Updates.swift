import AppKit
import CryptoKit
import Foundation

/// Keeps the Inferoid app current: checks GitHub for a newer signed release, then downloads it, checks its checksum and
/// that it is signed by our Developer ID, swaps the app bundle and relaunches.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    enum State: Equatable {
        case idle, checking, upToDate, development
        case available(String)
        case installing(String)
        case failed(String)
    }

    @Published var state: State = .idle
    private var zipURL: URL?
    private var checksumURL: URL?

    static let releasesAPI = URL(string: "https://api.github.com/repos/inferoid/inferoid/releases/latest")!
    /// Developer ID team that signs release builds (notes-app.yml / sign-notarize.sh).
    static let teamID = "D44DQ48C95"

    var currentVersion: String { FeedbackSender.appVersion }

    /// Builds from ./build-app.sh (apps/notes/build/) are development builds: never replace them with a release.
    var isDevelopmentBuild: Bool { Bundle.main.bundleURL.path.contains("/apps/notes/build/") || currentVersion == "dev" }

    func check() async {
        if isDevelopmentBuild { state = .development; return }
        state = .checking
        do {
            var request = URLRequest(url: Self.releasesAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Inferoid-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                state = .failed("Couldn't read the latest release.")
                return
            }
            func asset(_ name: String) -> URL? {
                guard let found = assets.first(where: { ($0["name"] as? String) == name }),
                      let link = found["browser_download_url"] as? String else { return nil }
                return URL(string: link)
            }
            zipURL = asset("Inferoid.zip")
            checksumURL = asset("Inferoid.zip.sha256")
            let latest = tag.replacingOccurrences(of: "notes-v", with: "")
            state = (zipURL != nil && Self.isNewer(latest, than: currentVersion)) ? .available(latest) : .upToDate
        } catch {
            state = .failed("Couldn't check for updates (\(error.localizedDescription)).")
        }
    }

    /// "0.7.10" is newer than "0.7.9"; missing parts count as 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    func install() async {
        guard case .available(let version) = state, let zipURL else { return }
        state = .installing("Downloading Inferoid \(version)…")
        do {
            let (downloaded, _) = try await URLSession.shared.download(from: zipURL)
            let data = try Data(contentsOf: downloaded)
            guard let checksumURL else {
                state = .failed("The release has no checksum, so it wasn't installed.")
                return
            }
            let (checksumData, _) = try await URLSession.shared.data(from: checksumURL)
            let expected = String(decoding: checksumData, as: UTF8.self)
                .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)?.lowercased() ?? ""
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard !expected.isEmpty, expected == actual else {
                state = .failed("The download didn't match its checksum, so it wasn't installed.")
                return
            }

            state = .installing("Checking the signature…")
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("inferoid-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("Inferoid.zip")
            try data.write(to: zip)
            guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]).status == 0 else {
                state = .failed("Couldn't unpack the update.")
                return
            }
            let newApp = work.appendingPathComponent("Inferoid.app")
            let signer = Self.run("/usr/bin/codesign", ["-dv", "--verbose=2", newApp.path])
            guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]).status == 0,
                  signer.output.contains("TeamIdentifier=\(Self.teamID)") else {
                state = .failed("The update isn't signed by Inferoid, so it wasn't installed.")
                return
            }

            state = .installing("Restarting Inferoid…")
            let target = Bundle.main.bundleURL.path
            let pid = ProcessInfo.processInfo.processIdentifier
            // After this app quits: move the old app aside, copy the new one in (restore the old one on failure), relaunch.
            let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(target).old"
            if mv "\(target)" "\(target).old" && /usr/bin/ditto "\(newApp.path)" "\(target)"; then
              rm -rf "\(target).old"
            else
              rm -rf "\(target)"; mv "\(target).old" "\(target)"
            fi
            open "\(target)"
            rm -rf "\(work.path)"
            """
            let swapper = Process()
            swapper.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            swapper.arguments = ["/bin/sh", "-c", script]
            swapper.standardOutput = FileHandle.nullDevice
            swapper.standardError = FileHandle.nullDevice
            try swapper.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("The update failed (\(error.localizedDescription)).")
        }
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Keeps the Brain model current: compares the installed pack (brain.json "revision") with models.json in the public
/// repo, and updates through the same installer people already use (`inferoid add brain`), which downloads only the
/// files that changed and checks every one against its checksum.
@MainActor
final class ModelUpdater: ObservableObject {
    static let shared = ModelUpdater()

    enum State: Equatable {
        case idle, checking, upToDate, notInstalled, done
        case available(String)
        case updating
        case failed(String)
    }

    @Published var state: State = .idle

    static let manifest = URL(string: "https://raw.githubusercontent.com/inferoid/inferoid/main/models.json")!
    static let manifestKey = "inkling-2-mini-g13"
    /// Installs from before brain.json recorded a revision used the first pack.
    static let firstRevision = "7a7c673e159f18a6313ab9099e15f85b8e607193"
    static var log: URL { InferoidPaths.support.appendingPathComponent("Logs/model-update.log") }

    var installedRevision: String? {
        guard let data = try? Data(contentsOf: BrainModelConfig.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["revision"] as? String) ?? Self.firstRevision
    }

    func check() async {
        guard let installed = installedRevision else { state = .notInstalled; return }
        state = .checking
        do {
            var request = URLRequest(url: Self.manifest)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            // No manifest yet (404) or an unreadable one: nothing newer is published, so the model is current.
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let models = json["models"] as? [String: Any],
                  let entry = models[Self.manifestKey] as? [String: Any],
                  let revision = entry["revision"] as? String else {
                state = .upToDate
                return
            }
            state = revision == installed ? .upToDate : .available(entry["name"] as? String ?? "A new model")
        } catch {
            state = .failed("Couldn't check for model updates (\(error.localizedDescription)).")
        }
    }

    func update(model: String) async {
        state = .updating
        let log = Self.log
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        // Newest installer first (it carries the new pinned revision), then the install itself. A login shell finds
        // uv and the inferoid command where `uv tool install` put them.
        let command = "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; " +
            "(uv tool upgrade inferoid || true) && inferoid add brain"
        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                if let handle = try? FileHandle(forWritingTo: log) {
                    process.standardOutput = handle
                    process.standardError = handle
                }
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(returning: -1)
                }
            }
        }
        guard status == 0 else {
            state = .failed("The model update didn't finish. Details are in Logs/model-update.log.")
            return
        }
        try? await ModelManager.shared.restart(model)
        state = .done
    }
}
