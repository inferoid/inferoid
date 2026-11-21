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
            "-m", "/tmp/base.gguf", "--port", "8123", "-c", "32768", "-np", "1",
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
        let c = NotesConfig(model: "gemma-4", base: "/tmp/base.gguf", runtime: "llama",
                            adapters: [NotesAdapter(name: "brain", file: "/tmp/brain.gguf", scale: 0.7)])
        let body = Summarizer.llamaRequestBody(system: "s", user: "u", model: c.appModel,
                                               maxTokens: 10, skill: .notes, config: c)
        let lora = body["lora"] as? [[String: Any]]
        XCTAssertEqual(lora?.count, 1)
        XCTAssertEqual(lora?.first?["scale"] as? Double, 0.0)  // brain adapter explicitly off
    }

    func testLlamaRequestSelectsTheSkillAdapter() {
        let c = NotesConfig(model: "gemma-4", base: "/tmp/base.gguf", runtime: "llama",
                            adapters: [NotesAdapter(name: "brain", file: "/tmp/brain.gguf", scale: 0.7),
                                       NotesAdapter(name: "notes", file: "/tmp/notes.gguf", scale: 0.9)])
        let body = Summarizer.llamaRequestBody(system: "s", user: "u", model: c.appModel,
                                               maxTokens: 10, skill: .notes, config: c)
        let lora = body["lora"] as? [[String: Any]]
        XCTAssertEqual(lora?.count, 2)
        XCTAssertEqual(lora?[0]["scale"] as? Double, 0.0)   // brain off
        XCTAssertEqual(lora?[1]["id"] as? Int, 1)
        XCTAssertEqual(lora?[1]["scale"] as? Double, 0.9)   // notes on
    }
}
