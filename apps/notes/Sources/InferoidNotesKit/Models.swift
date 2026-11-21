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

    /// The name the app uses for this model (the path lets the managed server recognize it).
    var appModel: String { (isLlama ? "llama:" + (base ?? "") : "mlx:" + model_dir) }

    static func serverArguments(_ c: NotesConfig) -> [String] {
        var args = ["-m", c.base ?? "", "--port", String(c.port ?? 8090), "-c", "32768", "-np", "1"]
        for adapter in c.adapters { args += ["--lora", adapter.file] }
        args.append("--lora-init-without-apply")
        return args
    }
}

/// Model manager. A Mac's GPU memory is shared by every model that is loaded, so two models at once can crash
/// (24 GB Mac: a 11 GB Ollama model plus the notes model ran out of GPU memory). The app therefore:
/// - starts the notes model only when it is needed (a meeting starts, notes are written, a question is asked),
/// - asks Ollama to unload its models first,
/// - stops the notes model after 10 idle minutes and when the app quits.
@MainActor
final class ModelManager {
    static let shared = ModelManager()

    let config = NotesConfig.load()
    private var process: Process?
    private var idleTimer: Timer?
    private let idleSeconds: TimeInterval = 600

    var managedModel: String? { config?.appModel }

    func manages(_ model: String) -> Bool { config != nil && model == config?.appModel }

    private var pidFile: URL { NotesConfig.home.appendingPathComponent("server.pid") }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ModelManager.shared.stop() }
        }
    }

    /// Makes sure `model` can run now. For the managed notes model: frees Ollama, starts the server, waits until it answers.
    func ensure(_ model: String) async throws {
        idleTimer?.invalidate()
        guard manages(model), let config else { return }
        if await serverUp(config) { return }
        await unloadOllama()
        try start(config)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if await serverUp(config) { return }
            if let p = process, !p.isRunning {
                throw NSError(domain: "Models", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The notes model stopped while loading. See ~/inferoid-notes/server.log"])
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw NSError(domain: "Models", code: 2, userInfo: [NSLocalizedDescriptionKey: "The notes model did not start within 3 minutes."])
    }

    /// Call when the work is done; the model stays loaded for 10 minutes in case it is needed again.
    func idle() {
        guard process != nil || FileManager.default.fileExists(atPath: pidFile.path) else { return }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleSeconds, repeats: false) { _ in
            MainActor.assumeIsolated { ModelManager.shared.stop() }
        }
    }

    func stop() {
        idleTimer?.invalidate(); idleTimer = nil
        if let p = process, p.isRunning {
            p.terminate()
        } else if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  config != nil {
            kill(pid, SIGTERM)  // a server left running by an earlier app session that crashed
        }
        process = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func start(_ c: NotesConfig) throws {
        let p = Process()
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
        let log = NotesConfig.home.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        p.standardOutput = handle; p.standardError = handle
        try p.run()
        process = p
        try? String(p.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    private func serverUp(_ c: NotesConfig) async -> Bool {
        var request = URLRequest(url: Summarizer.endpoint(for: c).appendingPathComponent("v1/models"))
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
