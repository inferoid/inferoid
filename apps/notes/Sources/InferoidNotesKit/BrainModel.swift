import Foundation

/// The Brain chat model that `inferoid add brain` installed: ~/inferoid-notes/brain.json. Today that is Inkling 2 Mini
/// (3-bit g13 pack, 12.3 GB) served by g13 on Macs with 24 GB or more; smaller Macs chat with the notes model.
struct BrainModelConfig: Decodable, Equatable {
    var runtime: String
    var g13: String
    var model_dir: String
    var port: Int?

    static var path: URL { NotesConfig.home.appendingPathComponent("brain.json") }

    static func load() -> BrainModelConfig? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(BrainModelConfig.self, from: data)
    }

    var appModel: String { "inkling:" + model_dir }
    var endpoint: URL { URL(string: "http://127.0.0.1:\(port ?? 8095)")! }

    /// 24K context: the longest notes transcript in the 23-call bench is 13.2K tokens plus up to 4K of notes.
    /// One session, no vision tower, and no SSD prompt cache: the cache would write the records' KV state outside the
    /// encrypted vault. The model's own MTP draft head speeds up writing. A 1 GB RAM prompt cache and 512-token prefill
    /// chunks keep an 8.5K-token Brain prompt inside a 24 GB Mac's GPU memory: with g13's defaults 8 of 12 such prompts
    /// failed with Metal "Insufficient Memory" on a 24 GB M4 (11-23), with these settings none did.
    static func serverArguments(_ c: BrainModelConfig) -> [String] {
        ["serve", "--model", c.model_dir, "--port", String(c.port ?? 8095), "--ctx", "24576", "--kv", "q8",
         "--no-vision", "--mtp", "auto", "--parallel", "1", "--disk-cache", "0", "--ram-cache", "1", "--prefill-step", "512"]
    }
}

/// Inkling 2 Mini prompts written by hand, byte for byte what its chat template renders (checked against the template
/// in the tests), with one change: the prompt ends by opening the assistant's final-answer channel. That is how
/// Thinking Machines gets answers without written reasoning, and it is what makes the first word arrive in about half a
/// second on a 24 GB M4 instead of after 2-8 s of hidden thinking (effort 0 alone still thinks).
enum InklingPrompt {
    static let answerOpen = "<|message_model|><|content_text|>"
    static let stops = ["<|end_message|>", "<|content_model_end_sampling|>"]

    /// `turns` alternate user / assistant text, oldest first, ending with the user's new message.
    static func render(system: String, turns: [ChatTurn]) -> String {
        var s = "<|message_system|><|content_text|>" + clean(system) + "<|end_message|>"
        s += "<|message_system|><|content_text|>Thinking effort level: 0<|end_message|>"
        for t in turns { s += turn(t) }
        return s + answerOpen
    }

    /// The prompt up to the end of `partial`, the new user message so far, with nothing closed after it: an exact prefix
    /// of the final prompt, so the server can read it while the user is still typing.
    static func prefix(system: String, turns: [ChatTurn], partial: String) -> String {
        var s = "<|message_system|><|content_text|>" + clean(system) + "<|end_message|>"
        s += "<|message_system|><|content_text|>Thinking effort level: 0<|end_message|>"
        for t in turns { s += turn(t) }
        return s + "<|message_user|><|content_text|>" + clean(partial)
    }

    static func turn(_ t: ChatTurn) -> String {
        t.role == "assistant"
            ? "<|message_model|><|content_text|>" + clean(t.text) + "<|end_message|><|content_model_end_sampling|>"
            : "<|message_user|><|content_text|>" + clean(t.text) + "<|end_message|>"
    }

    /// Meeting text must never open a control token: the server parses special tokens in raw prompts, so a transcript
    /// containing "<|message_system|>" could otherwise write its own system message.
    static func clean(_ text: String) -> String { text.replacingOccurrences(of: "<|", with: "< |") }
}

/// One message of a chat as the model sees it.
struct ChatTurn: Equatable {
    var role: String  // "user" or "assistant"
    var text: String
}
