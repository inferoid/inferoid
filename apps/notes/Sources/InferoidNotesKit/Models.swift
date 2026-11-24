import AppKit
import Foundation

/// Shared local model choices used by apps built on the Notes kit.
/// Keeping this catalog in the public kit lets private extensions make the
/// same hardware recommendation without copying model-fit thresholds.
public struct InferoidModelOption: Sendable {
    public let modelID: String
    public let minimumRAMGB: Int
    public let downloadGB: Double

    public init(modelID: String, minimumRAMGB: Int, downloadGB: Double) {
        self.modelID = modelID
        self.minimumRAMGB = minimumRAMGB
        self.downloadGB = downloadGB
    }
}

public enum InferoidModelCatalog {
    public static let notes: [InferoidModelOption] = [
        InferoidModelOption(modelID: "inferoid-notes-e4b", minimumRAMGB: 16, downloadGB: 3.9),
        InferoidModelOption(modelID: "inferoid-notes-e2b", minimumRAMGB: 8, downloadGB: 2.5),
    ]

    public static func recommendedNotesModel(ramGB: Int) -> InferoidModelOption? {
        notes.first { ramGB >= $0.minimumRAMGB }
    }
}

struct NotesAdapter: Decodable, Equatable {
    var name: String
    var file: String
    var sha256: String
    var scale: Double

    private enum CodingKeys: String, CodingKey { case name, file, sha256, scale }

    init(name: String, file: String, sha256: String = "", scale: Double = 1.0) {
        self.name = name; self.file = file; self.sha256 = sha256; self.scale = scale
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        file = try values.decode(String.self, forKey: .file)
        sha256 = try values.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
    }
}

/// The notes model that `inferoid setup` installed: ~/inferoid-notes/notes.json.
/// The llama fields are optional so an old MLX config decodes exactly as before.
struct NotesConfig: Decodable {
    var model: String
    var model_dir: String
    var python: String
    var port: Int?
    var runtime: String?
    var server: String?
    var base: String?
    var adapters: [NotesAdapter]

    private enum CodingKeys: String, CodingKey { case model, model_dir, python, port, runtime, server, base, adapters }

    init(model: String = "", model_dir: String = "", python: String = "", port: Int? = nil,
         runtime: String? = nil, server: String? = nil, base: String? = nil, adapters: [NotesAdapter] = []) {
        self.model = model; self.model_dir = model_dir; self.python = python; self.port = port
        self.runtime = runtime; self.server = server; self.base = base; self.adapters = adapters
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        model_dir = try values.decodeIfPresent(String.self, forKey: .model_dir) ?? ""
        python = try values.decodeIfPresent(String.self, forKey: .python) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port)
        runtime = try values.decodeIfPresent(String.self, forKey: .runtime)
        server = try values.decodeIfPresent(String.self, forKey: .server)
        base = try values.decodeIfPresent(String.self, forKey: .base)
        adapters = try values.decodeIfPresent([NotesAdapter].self, forKey: .adapters) ?? []
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("inferoid-notes") }

    static func load() -> NotesConfig? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("notes.json")) else { return nil }
        return try? JSONDecoder().decode(NotesConfig.self, from: data)
    }

    var isLlama: Bool { runtime == "llama" }
    /// 24 GB+ Macs: no notes model of its own; Inkling (brain.json) does notes, chat and extraction.
    var isInkling: Bool { runtime == "inkling" }

    /// The one model the app uses by default: Inkling where installed (24 GB+), else the notes model.
    static var defaultModel: String? {
        BrainModelConfig.load()?.appModel ?? load().flatMap { $0.isInkling ? nil : $0.appModel }
    }

    /// The name the app uses for this model (the path lets the managed server recognize it).
    var appModel: String { (isLlama ? "llama:" + (base ?? "") : "mlx:" + model_dir) }

    static func serverArguments(_ c: NotesConfig) -> [String] {
        // --cache-ram caps the prompts llama-server keeps in RAM for reuse (default 8 GB pushed a 24 GB Mac to critical
        // memory pressure); 2 GB still holds a whole chat thread.
        var args = ["-m", c.base ?? "", "--port", String(c.port ?? 8090), "-c", "32768", "-np", "1", "--cache-ram", "2048"]
        for adapter in c.adapters { args += ["--lora", adapter.file] }
        args.append("--lora-init-without-apply")
        return args
    }
}

/// Model manager. A Mac's GPU memory is shared by every model that is loaded, so two models at once can crash
/// (24 GB Mac: a 11 GB Ollama model plus the notes model ran out of GPU memory). The app therefore:
/// - starts the model only when it is needed: on 24 GB+ Macs the one model is Inkling (`brain.json`) for notes, chat and
///   Brain extraction; elsewhere the notes model. If both are installed only one runs at a time (starting one stops the
///   other: Inkling's 12.3 GB plus the notes model would not fit next to the app on 24 GB),
/// - asks Ollama to unload its models first,
/// - stops a model after 10 idle minutes and when the app quits.
@MainActor
final class ModelManager {
    static let shared = ModelManager()

    let config = NotesConfig.load().flatMap { $0.isInkling ? nil : $0 }
    let brain = BrainModelConfig.load()
    private var processes: [String: Process] = [:]
    /// A start in progress per model: a second caller waits for it instead of launching a second server
    /// (two Inkling servers do not fit in memory: "Address already in use", then Metal out of memory).
    private var starting: [String: Task<Void, Error>] = [:]
    private var idleTimer: Timer?
    private let idleSeconds: TimeInterval = 600

    /// One model per Mac: Inkling on 24 GB+ (notes, chat, Brain extraction), else the notes model.
    var managedModel: String? { brain?.appModel ?? config?.appModel }

    func manages(_ model: String) -> Bool {
        (config != nil && model == config?.appModel) || (brain != nil && model == brain?.appModel)
    }

    private var managed: [String] { [config?.appModel, brain?.appModel].compactMap { $0 } }

    private func pidFile(_ model: String) -> URL {
        NotesConfig.home.appendingPathComponent(model == brain?.appModel ? "brain-server.pid" : "server.pid")
    }

    private func endpoint(_ model: String) -> URL? {
        if model == brain?.appModel { return brain?.endpoint }
        return config.map { Summarizer.endpoint(for: $0) }
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ModelManager.shared.stop() }
        }
    }

    /// Makes sure `model` can run now. For the managed notes model: frees Ollama, starts the server, waits until it answers.
    func ensure(_ model: String) async throws {
        idleTimer?.invalidate()
        guard manages(model) else { return }
        if let running = starting[model] { try await running.value; return }
        let task = Task { @MainActor in try await self.startIfNeeded(model) }
        starting[model] = task
        defer { starting[model] = nil }
        try await task.value
    }

    private func startIfNeeded(_ model: String) async throws {
        for other in managed where other != model { await stopAndWait(other) }
        if await serverUp(model) { return }
        await unloadOllama()
        // A server we did not start (left by a crashed or rebuilt app) may hold the port and the memory.
        // Our own server still loading: wait for it below instead of starting another next to it.
        if processes[model]?.isRunning != true { await killOrphans(model); try start(model) }
        let name = model == brain?.appModel ? "The Brain model" : "The notes model"
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if await serverUp(model) { return }
            if let p = processes[model], !p.isRunning {
                throw NSError(domain: "Models", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(name) stopped while loading. See ~/inferoid-notes/\(logName(model))"])
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw NSError(domain: "Models", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name) did not start within 3 minutes."])
    }

    /// The server stopped answering (crashed generation thread): stop it and start it again.
    func restart(_ model: String) async throws {
        guard manages(model) else { return }
        await stopAndWait(model)
        try await ensure(model)
    }

    /// Call when the work is done; the model stays loaded for 10 minutes in case it is needed again.
    func idle() {
        guard !processes.isEmpty || managed.contains(where: { FileManager.default.fileExists(atPath: pidFile($0).path) }) else { return }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleSeconds, repeats: false) { _ in
            MainActor.assumeIsolated { ModelManager.shared.stop() }
        }
    }

    func stop() {
        idleTimer?.invalidate(); idleTimer = nil
        for model in managed { stop(model) }
    }

    private func stop(_ model: String) {
        let file = pidFile(model)
        if let p = processes[model], p.isRunning {
            p.terminate()
        } else if let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)  // a server left running by an earlier app session that crashed
        }
        processes[model] = nil
        try? FileManager.default.removeItem(at: file)
    }

    /// Stops whatever still listens on the model's port (an earlier app session's server) and waits for it to exit.
    private func killOrphans(_ model: String) async {
        stop(model)  // the pid file, if any
        guard let port = endpoint(model)?.port else { return }
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe(); lsof.standardOutput = pipe; lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return }
        lsof.waitUntilExit()
        let pids = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != getpid() }
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        for _ in 0..<30 where pids.contains(where: { kill($0, 0) == 0 }) { try? await Task.sleep(nanoseconds: 500_000_000) }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Stops `model` and waits (up to 15 s) until its memory is free, so the next model does not load next to it.
    private func stopAndWait(_ model: String) async {
        let p = processes[model]
        stop(model)
        for _ in 0..<30 where p?.isRunning == true { try? await Task.sleep(nanoseconds: 500_000_000) }
    }

    private func logName(_ model: String) -> String { model == brain?.appModel ? "brain-server.log" : "server.log" }

    private func start(_ model: String) throws {
        let p = Process()
        if model == brain?.appModel, let b = brain {
            guard FileManager.default.fileExists(atPath: b.g13) else {
                throw NSError(domain: "Models", code: 5, userInfo: [NSLocalizedDescriptionKey:
                    "The Brain model server (g13) is missing. Reinstall with: inferoid add brain"])
            }
            guard FileManager.default.fileExists(atPath: b.model_dir) else {
                throw NSError(domain: "Models", code: 6, userInfo: [NSLocalizedDescriptionKey:
                    "The Brain model is missing at \(b.model_dir). Reinstall with: inferoid add brain"])
            }
            p.executableURL = URL(fileURLWithPath: b.g13)
            p.arguments = BrainModelConfig.serverArguments(b)
        } else if let c = config {
            try configure(p, notes: c)
        } else { return }
        let log = NotesConfig.home.appendingPathComponent(logName(model))
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        p.standardOutput = handle; p.standardError = handle
        try p.run()
        processes[model] = p
        try? String(p.processIdentifier).write(to: pidFile(model), atomically: true, encoding: .utf8)
    }

    private func configure(_ p: Process, notes c: NotesConfig) throws {
        if c.isLlama {
            guard let server = c.server, FileManager.default.fileExists(atPath: server) else {
                throw NSError(domain: "Models", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "The llama-server executable is missing. Reinstall with: inferoid add notes --runtime llama"])
            }
            guard let base = c.base, FileManager.default.fileExists(atPath: base) else {
                throw NSError(domain: "Models", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "The Gemma 4 base model is missing at \(c.base ?? "the configured path"). Reinstall with: inferoid add notes --runtime llama"])
            }
            p.executableURL = URL(fileURLWithPath: server)
            p.arguments = NotesConfig.serverArguments(c)
        } else {
            p.executableURL = URL(fileURLWithPath: c.python)
            p.arguments = ["-m", "mlx_lm.server", "--model", c.model_dir, "--port", String(c.port ?? 8090)]
        }
    }

    private func serverUp(_ model: String) async -> Bool {
        guard let url = endpoint(model) else { return false }
        var request = URLRequest(url: url.appendingPathComponent("v1/models"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Unloads every model Ollama has in memory (same as `ollama stop`). Ollama reloads them on their next request.
    private func unloadOllama() async {
        guard let (data, _) = try? await URLSession.shared.data(from: Summarizer.ollama.appendingPathComponent("api/ps")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loaded = json["models"] as? [[String: Any]] else { return }
        for name in loaded.compactMap({ $0["name"] as? String }) {
            var request = URLRequest(url: Summarizer.ollama.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "keep_alive": 0])
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
