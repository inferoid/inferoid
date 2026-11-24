import XCTest
@testable import InferoidNotesKit

final class LlamaRuntimeTests: XCTestCase {
    private func config(_ object: [String: Any]) throws -> NotesConfig {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(NotesConfig.self, from: data)
    }

    func testLlamaConfigAndArguments() throws {
        let c = try config([
            "runtime": "llama", "server": "/tmp/llama-server", "base": "/tmp/base.gguf", "port": 8123,
            "adapters": [["name": "brain", "file": "/tmp/brain.gguf", "sha256": "b", "scale": 0.7],
                          ["name": "notes", "file": "/tmp/notes.gguf", "sha256": "n", "scale": 1.0]],
        ])
        XCTAssertTrue(c.isLlama)
        XCTAssertEqual(c.appModel, "llama:/tmp/base.gguf")
        XCTAssertEqual(NotesConfig.serverArguments(c), [
            "-m", "/tmp/base.gguf", "--port", "8123", "-c", "32768", "-np", "1", "--cache-ram", "2048",
            "--lora", "/tmp/brain.gguf", "--lora", "/tmp/notes.gguf", "--lora-init-without-apply",
        ])
    }

    func testMlxConfigStillUsesTheOldModelIdentity() throws {
        let c = try config(["model": "inferoid-notes-e4b", "model_dir": "/tmp/e4b", "python": "/tmp/python", "port": 8090])
        XCTAssertFalse(c.isLlama)
        XCTAssertEqual(c.appModel, "mlx:/tmp/e4b")
        XCTAssertEqual(c.adapters, [])
    }

    func testLlamaRequestUsesBaseWhenSkillAdapterIsMissing() {
        let c = NotesConfig(model: "gemma-4", runtime: "llama", base: "/tmp/base.gguf",
                            adapters: [NotesAdapter(name: "brain", file: "/tmp/brain.gguf", scale: 0.7)])
        let body = Summarizer.llamaRequestBody(system: "s", user: "u", model: c.appModel,
                                               maxTokens: 10, skill: .notes, config: c)
        let lora: [[String: Any]] = body["lora"] as? [[String: Any]] ?? []
        XCTAssertEqual(lora.count, 1)
        let brainScale: Double? = lora[0]["scale"] as? Double
        XCTAssertEqual(brainScale, 0)  // brain adapter explicitly off
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
    }

    func testLlamaRequestSelectsTheSkillAdapter() {
        let c = NotesConfig(model: "gemma-4", runtime: "llama", base: "/tmp/base.gguf",
                            adapters: [NotesAdapter(name: "brain", file: "/tmp/brain.gguf", scale: 0.7),
                                       NotesAdapter(name: "notes", file: "/tmp/notes.gguf", scale: 0.9)])
        let body = Summarizer.llamaRequestBody(system: "s", user: "u", model: c.appModel,
                                               maxTokens: 10, skill: .notes, config: c)
        let lora: [[String: Any]] = body["lora"] as? [[String: Any]] ?? []
        XCTAssertEqual(lora.count, 2)
        let brainScale: Double? = lora[0]["scale"] as? Double
        let notesID: Int? = lora[1]["id"] as? Int
        let notesScale: Double? = lora[1]["scale"] as? Double
        XCTAssertEqual(brainScale, 0)    // brain off
        XCTAssertEqual(notesID, 1)
        XCTAssertEqual(notesScale, 0.9)  // notes on
    }
}
