import Foundation

/// Crash-safe copy of a meeting's audio while it is being recorded.
///
/// Both channels (Me and Them) are appended as 16 kHz mono 16-bit PCM to their own file inside the encrypted vault,
/// next to a small manifest. A meeting that ends normally deletes its journal once the transcript is saved. If the app
/// crashes, is force-quit or the Mac loses power, the journal is still there at the next launch and the meeting can be
/// re-transcribed from the audio. Pattern after pasrom/meeting-transcriber (MIT): separate tracks + in-progress marker.
final class RecordingJournal {
    struct Manifest: Codable {
        var started: Date
        var template: String
        var model: String
        var attendees: [String]
        var otherSpeaker: String
    }

    enum Channel: String { case me, them }

    static let rate = 16_000
    let folder: URL
    private var handles: [Channel: FileHandle] = [:]
    private var unsynced: [Channel: Int] = [:]
    private let lock = NSLock()

    /// Tests point this at a temporary folder.
    static var rootOverride: URL?
    static var root: URL { rootOverride ?? InferoidPaths.support.appendingPathComponent("Recordings in progress", isDirectory: true) }

    init(manifest: Manifest) throws {
        let fm = FileManager.default
        folder = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        for channel in [Channel.me, .them] {
            let url = folder.appendingPathComponent("\(channel.rawValue).pcm")
            fm.createFile(atPath: url.path, contents: nil)
            handles[channel] = try FileHandle(forWritingTo: url)
        }
    }

    /// Appends samples (called on the channel's queue). Flushed to disk about every 2 s of audio.
    func append(_ samples: [Float], to channel: Channel) {
        guard !samples.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = Int16(max(-1, min(1, samples[i])) * Float(Int16.max)) }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); defer { lock.unlock() }
        guard let handle = handles[channel] else { return }
        try? handle.write(contentsOf: data)
        unsynced[channel, default: 0] += samples.count
        if unsynced[channel, default: 0] >= Self.rate * 2 {
            try? handle.synchronize()
            unsynced[channel] = 0
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        for handle in handles.values { try? handle.synchronize(); try? handle.close() }
        handles = [:]
    }

    /// Called after the meeting is saved.
    func discard() {
        close()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Recovery

    struct Pending: Identifiable {
        let folder: URL
        let manifest: Manifest
        var id: URL { folder }
        /// Recorded length, from the longer of the two tracks.
        var seconds: Double {
            [Channel.me, .them].map { RecordingJournal.sampleCount(folder, $0) }.max().map { Double($0) / Double(RecordingJournal.rate) } ?? 0
        }
    }

    /// Journals left behind by a meeting that did not finish (excluding `active`, the one being recorded now).
    static func pending(excluding active: URL? = nil) -> [Pending] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder in
            guard folder.standardizedFileURL != active?.standardizedFileURL,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let manifest = try? decoder.decode(Manifest.self, from: data) else { return nil }
            return Pending(folder: folder, manifest: manifest)
        }
        .sorted { $0.manifest.started < $1.manifest.started }
    }

    static func sampleCount(_ folder: URL, _ channel: Channel) -> Int {
        let url = folder.appendingPathComponent("\(channel.rawValue).pcm")
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size / MemoryLayout<Int16>.size
    }

    /// Reads one track in one-second pieces (never the whole recording in memory).
    @MainActor static func read(_ folder: URL, _ channel: Channel, chunk: ([Float]) async throws -> Void) async throws {
        let url = folder.appendingPathComponent("\(channel.rawValue).pcm")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let bytes = rate * MemoryLayout<Int16>.size
        while let data = try handle.read(upToCount: bytes), !data.isEmpty {
            let count = data.count / MemoryLayout<Int16>.size
            let samples: [Float] = data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                return (0..<count).map { Float(p[$0]) / Float(Int16.max) }
            }
            try await chunk(samples)
        }
    }
}
