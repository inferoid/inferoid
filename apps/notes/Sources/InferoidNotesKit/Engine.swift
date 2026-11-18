import FluidAudio
import Foundation

/// On-device speech-to-text: NVIDIA Parakeet TDT 0.6B (English) on the Neural Engine via FluidAudio.
actor Transcriber {
    private var asr: AsrManager?
    var isReady: Bool { asr != nil }

    func load() async throws {
        if asr != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let asr else { return "" }
        var audio = samples
        if audio.count < Segmenter.rate { audio += [Float](repeating: 0, count: Segmenter.rate - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(audio, decoderState: &state).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct Line: Identifiable, Codable, Hashable {
    var id = UUID()
    var speaker: String      // "Me" or "Them"
    var start: Double
    var end: Double
    var text: String
}

func clock(_ seconds: Double) -> String {
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

func transcriptText(_ lines: [Line]) -> String {
    lines.map { "[\(clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
}

// MARK: - Notes

struct ActionItem: Codable, Hashable { var task: String; var owner: String; var due: String }

struct Notes: Codable, Hashable {
    var title: String
    var summary: String
    var key_points: [String]
    var decisions: [String]
    var action_items: [ActionItem]
    var open_questions: [String]
}

enum Template: String, CaseIterable, Identifiable, Codable {
    case general, investor, customer, oneOnOne
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "General meeting"
        case .investor: return "Investor meeting"
        case .customer: return "Customer call"
        case .oneOnOne: return "1:1"
        }
    }
    var guidance: String {
        switch self {
        case .general:
            return "This is a general business meeting."
        case .investor:
            return "This is a meeting with an investor. In key_points, capture the investor's questions, concerns, signals of interest, and anything they asked to see next."
        case .customer:
            return "This is a customer call. In key_points, capture the customer's problems, current tools, budget, timeline, decision process, and objections, in their words where possible."
        case .oneOnOne:
            return "This is a 1:1 meeting. In key_points, capture updates, blockers, feedback given, and support requested."
        }
    }
}

/// Writes the notes with a local model. Two kinds of local server:
/// - Ollama (default), model names like "gemma4:e4b"
/// - an OpenAI-compatible server such as mlx_lm.server on port 8090, model names "mlx:<id>"
enum Summarizer {
    static let ollama = URL(string: "http://127.0.0.1:11434")!
    static let mlx = URL(string: "http://127.0.0.1:8090")!

    static let system = """
    You write meeting notes from a transcript. "Me" is the person who recorded the meeting; "Them" or a calendar attendee name is everyone else on the call.
    Rules:
    - Use only facts stated in the transcript. Never invent names, numbers, dates, or commitments.
    - The transcript comes from speech recognition and may contain misheard words; prefer the most plausible reading.
    - summary: 2-4 sentences on what the meeting was about and where it ended.
    - key_points: the most important specific points, each one sentence.
    - decisions: things both sides agreed on. Empty list if none.
    - action_items: concrete next steps. owner is "Me", a listed attendee name, "Them", or "" if unclear. Use attendee names exactly as provided when the transcript supports it. due is the date or time said in the meeting, or "".
    - open_questions: questions raised and not answered.
    - title: 3-8 words.
    Return only JSON matching the schema.
    """

    static let schemaHint = """
    Reply with one JSON object and nothing else, in this shape:
    {"title": "...", "summary": "...", "key_points": ["..."], "decisions": ["..."], \
    "action_items": [{"task": "...", "owner": "...", "due": "..."}], "open_questions": ["..."]}
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "key_points": ["type": "array", "items": ["type": "string"]],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "action_items": ["type": "array", "items": [
                "type": "object",
                "properties": ["task": ["type": "string"], "owner": ["type": "string"], "due": ["type": "string"]],
                "required": ["task", "owner", "due"],
            ]],
            "open_questions": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["title", "summary", "key_points", "decisions", "action_items", "open_questions"],
    ]

    struct Result { var notes: Notes; var seconds: Double; var promptTokens: Int; var outputTokens: Int; var raw: String }

    static func models() async -> [String] {
        var names: [String] = []
        if let (data, _) = try? await URLSession.shared.data(from: ollama.appendingPathComponent("api/tags")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["models"] as? [[String: Any]] {
            names += list.compactMap { $0["name"] as? String }.sorted()
        }
        var request = URLRequest(url: mlx.appendingPathComponent("v1/models"))
        request.timeoutInterval = 1
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["data"] as? [[String: Any]] {
            names += list.compactMap { $0["id"] as? String }.map { "mlx:" + $0 }
        }
        if let managed = NotesConfig.load()?.appModel {
            names.removeAll { $0 == managed }
            names.insert(managed, at: 0)
        }
        return names
    }

    static func displayName(_ model: String) -> String {
        if let c = NotesConfig.load(), model == c.appModel { return "Inferoid notes model (\(c.model.replacingOccurrences(of: "inferoid-notes-", with: "").uppercased()))" }
        return model.hasPrefix("mlx:") ? "MLX " + (model.split(separator: "/").last.map(String.init) ?? model) : model
    }

    /// The first {...} object in a reply (tolerates code fences or text around it).
    static func extractJSON(_ text: String) -> String {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { return text }
        return String(text[a ... b])
    }

    static func run(transcript: String, template: Template, model: String, context: Int = 32768,
                    attendeeNames: [String] = [], instructions: String = "",
                    onText: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        var tries = 0
        while true {
            do {
                return try await stream(transcript: transcript, template: template, model: model, context: context,
                                        attendeeNames: attendeeNames, constrained: !model.hasPrefix("mlx:"), maxTokens: nil,
                                        instructions: instructions, onText: onText)
            } catch let error as NSError where error.localizedDescription.contains("not valid JSON") && tries < 2 {
                // The model broke the JSON. Try again (up to 3 in all); the transcript is cached, so this costs only the writing.
                tries += 1
                continue
            } catch let error as NSError where error.localizedDescription.contains("structured output") {
                // Some Ollama builds lack the grammar library for some engines; ask for the same JSON in the prompt instead.
                return try await stream(transcript: transcript, template: template, model: model, context: context,
                                        attendeeNames: attendeeNames, constrained: false, maxTokens: nil,
                                        instructions: instructions, onText: onText)
            }
        }
    }

    /// Reads the transcript so far without writing notes (1 output token), so the server caches it.
    /// At the end of the meeting only the last minute is still unread.
    static func prefill(transcript: String, template: Template, model: String, context: Int = 32768,
                        attendeeNames: [String] = [], instructions: String = "") async {
        _ = try? await stream(transcript: transcript, template: template, model: model, context: context,
                              attendeeNames: attendeeNames, constrained: false, maxTokens: 1, instructions: instructions,
                              onText: nil, prefillOnly: true)
    }

    private static func fail(_ message: String, _ code: Int = 1) -> NSError {
        NSError(domain: "Summarizer", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Raw ChatML prompt for the MLX server (Qwen family). Mid-meeting reads stop right after the transcript, so each one
    /// is an exact prefix of the next and of the final request: models with linear-attention layers (Qwen 3.5/3.6)
    /// can only reuse a cached prompt that is an exact prefix.
    private static func chatML(system: String, user: String, open: Bool) -> String {
        let head = "<|im_start|>system\n" + system + "<|im_end|>\n<|im_start|>user\n" + user
        return open ? head : head + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Raw Gemma 4 prompt (our fine-tuned note models). No <|think|> token, so the model does not think first.
    /// The server does not add <bos> to raw prompts, so it is written here.
    private static func gemma(system: String, user: String, open: Bool) -> String {
        let head = "<bos><|turn>system\n" + system + "<turn|>\n<|turn>user\n" + user
        return open ? head : head + "<turn|>\n<|turn>model\n"
    }

    static func isGemma(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("gemma") || m.contains("e4b") || m.contains("e2b")
    }

    private static func stream(transcript: String, template: Template, model: String, context: Int,
                               attendeeNames: [String], constrained: Bool,
                               maxTokens: Int?, instructions: String = "", onText: (@Sendable (String) -> Void)?,
                               prefillOnly: Bool = false) async throws -> Result {
        // The user's instructions go in the same slot as the meeting-type guidance the model was trained with;
        // the output sections never change (the note template only changes how they are shown).
        let attendees = attendeeNames.isEmpty ? "" : "\nAttendees on the calendar event: " + attendeeNames.joined(separator: ", ") + ". Use these names for action-item owners when appropriate."
        let sys = system + "\n" + template.guidance + attendees + (instructions.isEmpty ? "" : " " + instructions) + "\n" + schemaHint
        let user = "Transcript:\n" + (prefillOnly && model.hasPrefix("mlx:") ? transcript + "\n" : transcript)
        let r = try await send(system: sys, user: user, model: model, context: context, format: constrained ? schema : nil,
                               maxTokens: maxTokens ?? 4000, open: prefillOnly, onText: onText)
        if maxTokens != nil {
            return Result(notes: Notes(title: "", summary: "", key_points: [], decisions: [], action_items: [], open_questions: []),
                          seconds: r.seconds, promptTokens: r.promptTokens, outputTokens: r.outputTokens, raw: r.content)
        }
        let json = extractJSON(r.content)
        do {
            let notes = try JSONDecoder().decode(Notes.self, from: Data(json.utf8))
            return Result(notes: notes, seconds: r.seconds, promptTokens: r.promptTokens, outputTokens: r.outputTokens, raw: json)
        } catch {
            throw fail("The model's notes were not valid JSON: \(r.content.prefix(200))")
        }
    }

    /// Plain text answer (the Ask tab). Same servers and prompt formats as the notes.
    static func complete(system: String, user: String, model: String, maxTokens: Int = 1500, context: Int = 32768,
                         onText: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await send(system: system, user: user, model: model, context: context, format: nil,
                       maxTokens: maxTokens, open: false, onText: onText).content
    }

    struct Sent { var content: String; var seconds: Double; var promptTokens: Int; var outputTokens: Int }

    /// One streamed request to Ollama (/api/chat) or the MLX server (/v1/completions with a raw prompt).
    /// `open` stops the prompt right after the user text (prefill only).
    private static func send(system sys: String, user: String, model: String, context: Int, format: [String: Any]?,
                             maxTokens: Int, open: Bool, onText: (@Sendable (String) -> Void)?) async throws -> Sent {
        let isMLX = model.hasPrefix("mlx:")
        var body: [String: Any]
        var request: URLRequest
        if isMLX {
            let prompt = isGemma(model) ? gemma(system: sys, user: user, open: open) : chatML(system: sys, user: user, open: open)
            body = ["model": String(model.dropFirst(4)), "stream": true, "temperature": 0.2,
                    "max_tokens": maxTokens, "stream_options": ["include_usage": true], "prompt": prompt]
            request = URLRequest(url: mlx.appendingPathComponent("v1/completions"))
        } else {
            var options: [String: Any] = ["temperature": 0.2, "num_ctx": context]
            if open || maxTokens < 4000 { options["num_predict"] = maxTokens }
            body = ["model": model, "stream": true, "think": false, "keep_alive": "30m", "options": options,
                    "messages": [["role": "system", "content": sys], ["role": "user", "content": user]]]
            if let format { body["format"] = format }
            request = URLRequest(url: ollama.appendingPathComponent("api/chat"))
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        var content = "", promptTokens = 0, outputTokens = 0, errorText = ""
        for try await line in bytes.lines {
            var payload = Substring(line)
            if isMLX {
                guard payload.hasPrefix("data:") else { if status >= 400 { errorText += line }; continue }
                payload = payload.dropFirst(5).drop { $0 == " " }
                if payload == "[DONE]" { break }
            }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                if status >= 400 { errorText += line }
                continue
            }
            if let error = json["error"] {
                let text = (error as? String) ?? ((error as? [String: Any])?["message"] as? String) ?? "\(error)"
                throw fail((isMLX ? "Model server: " : "Ollama: ") + text, status)
            }
            if isMLX {
                if let choices = json["choices"] as? [[String: Any]],
                   let piece = (choices.first?["text"] as? String) ?? ((choices.first?["delta"] as? [String: Any])?["content"] as? String) {
                    content += piece
                    onText?(content)
                }
                if let usage = json["usage"] as? [String: Any] {
                    promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                    outputTokens = usage["completion_tokens"] as? Int ?? outputTokens
                }
            } else {
                if let piece = (json["message"] as? [String: Any])?["content"] as? String, !piece.isEmpty {
                    content += piece
                    onText?(content)
                }
                if json["done"] as? Bool == true {
                    promptTokens = json["prompt_eval_count"] as? Int ?? 0
                    outputTokens = json["eval_count"] as? Int ?? 0
                }
            }
        }
        if status >= 400 { throw fail("Model server error \(status): \(errorText.prefix(300))", status) }
        return Sent(content: content, seconds: Date().timeIntervalSince(started), promptTokens: promptTokens, outputTokens: outputTokens)
    }
}

// MARK: - Notes as they are written

private struct PartialAction: Decodable { var task: String?; var owner: String?; var due: String? }
private struct PartialNotes: Decodable {
    var title: String?; var summary: String?; var key_points: [String]?; var decisions: [String]?
    var action_items: [PartialAction]?; var open_questions: [String]?
}

/// Best-effort notes from an unfinished JSON reply: closes open strings, lists and objects and drops a half-written key.
func partialNotes(_ text: String) -> Notes? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    let chars = Array(text[start...])
    var stack: [Character] = []
    var expectKey: [Bool] = []
    var inString = false, escape = false, stringStart = 0, stringIsKey = false, lastCompletedKeyStart = -1
    for (i, c) in chars.enumerated() {
        if inString {
            if escape { escape = false } else if c == "\\" { escape = true } else if c == "\"" {
                inString = false
                lastCompletedKeyStart = stringIsKey ? stringStart : -1
            }
            continue
        }
        switch c {
        case "\"": inString = true; stringStart = i; stringIsKey = stack.last == "{" && (expectKey.last ?? false)
        case "{": stack.append("{"); expectKey.append(true); lastCompletedKeyStart = -1
        case "[": stack.append("["); expectKey.append(false); lastCompletedKeyStart = -1
        case "}", "]": stack.popLast(); expectKey.popLast(); lastCompletedKeyStart = -1
        case ":": if !expectKey.isEmpty { expectKey[expectKey.count - 1] = false }; lastCompletedKeyStart = -1
        case ",": if stack.last == "{" { expectKey[expectKey.count - 1] = true }; lastCompletedKeyStart = -1
        default: break
        }
    }
    var out: [Character]
    if inString {
        out = stringIsKey ? Array(chars[..<stringStart]) : chars + (escape ? [] : ["\""])
        if escape { out.removeLast(); out.append("\"") }
    } else if lastCompletedKeyStart >= 0 {
        out = Array(chars[..<lastCompletedKeyStart])
    } else {
        out = chars
    }
    while let last = out.last, last == " " || last == "\n" || last == "\t" || last == "\r" || last == "," { out.removeLast() }
    if out.last == ":" { out.append(contentsOf: "null") }
    for open in stack.reversed() { out.append(open == "{" ? "}" : "]") }
    guard let p = try? JSONDecoder().decode(PartialNotes.self, from: Data(String(out).utf8)) else { return nil }
    return Notes(title: p.title ?? "", summary: p.summary ?? "", key_points: p.key_points ?? [], decisions: p.decisions ?? [],
                 action_items: (p.action_items ?? []).map { ActionItem(task: $0.task ?? "", owner: $0.owner ?? "", due: $0.due ?? "") },
                 open_questions: p.open_questions ?? [])
}

/// The notes as Markdown, laid out by the note template (order, names, hidden sections). The title always comes first.
func notesMarkdown(_ n: Notes, layout: NoteLayout = .current, attendeeNames: [String] = []) -> String {
    func list(_ xs: [String]) -> String { xs.isEmpty ? "- None\n" : xs.map { "- \($0)\n" }.joined() }
    var md = "# \(n.title)\n"
    if !attendeeNames.isEmpty { md += "\nAttendees: \(attendeeNames.joined(separator: ", "))\n" }
    for s in layout.visible {
        switch s {
        case .summary:
            // The default layout keeps the summary as a plain paragraph under the title, as before.
            md += layout.name(.summary) == NoteSection.summary.defaultName ? "\n\(n.summary)\n" : "\n## \(layout.name(.summary))\n\(n.summary)\n"
        case .keyPoints: md += "\n## \(layout.name(s))\n" + list(n.key_points)
        case .decisions: md += "\n## \(layout.name(s))\n" + list(n.decisions)
        case .actionItems:
            md += "\n## \(layout.name(s))\n"
            md += n.action_items.isEmpty ? "- None\n" : n.action_items.map { a in
                "- [ ] \(a.task)" + (a.owner.isEmpty ? "" : " (\(a.owner))") + (a.due.isEmpty ? "" : ", due \(a.due)") + "\n"
            }.joined()
        case .openQuestions: md += "\n## \(layout.name(s))\n" + list(n.open_questions)
        }
    }
    return md
}

// MARK: - Storage: plain Markdown files in ~/Documents/Inferoid Notes

enum Store {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inferoid Notes")
    }

    @discardableResult
    static func save(started: Date, lines: [Line], notes: Notes?, meta: [String: Any],
                     attendeeNames: [String] = [], to dir: URL? = nil) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let safeTitle = (notes?.title ?? "Meeting").replacingOccurrences(of: "/", with: "-")
        let folder = dir ?? root.appendingPathComponent("\(stamp.string(from: started)) \(safeTitle)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ("# Transcript\n\n" + lines.map { "**[\(clock($0.start))] \($0.speaker):** \($0.text)\n" }.joined(separator: "\n"))
            .write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        if let notes {
            try notesMarkdown(notes, attendeeNames: attendeeNames).write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
            // Every section, whatever the template hides, so the notes can be shown another way later.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(notes).write(to: folder.appendingPathComponent("notes.json"))
        }
        var m = meta
        m["started"] = ISO8601DateFormatter().string(from: started)
        m["lines"] = lines.count
        try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("meta.json"))
        return folder
    }

    /// Renames one saved transcript label without touching transcript text.
    @discardableResult
    static func renameSpeaker(in folder: URL, from oldName: String, to newName: String) throws -> String {
        let cleanName = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !cleanName.isEmpty, !cleanName.contains("\n"), !cleanName.contains("\r") else {
            throw NSError(domain: "Store", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speaker name cannot be empty."])
        }
        let url = folder.appendingPathComponent("transcript.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = text.replacingOccurrences(of: "] \(oldName):**", with: "] \(cleanName):**")
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return updated
    }
}
