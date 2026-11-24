import Foundation

/// Who the assistant is and who the user is, learned in the first conversation (like OpenClaw's first-run
/// ritual: name, emoji, who you are, how to talk). Saved on this Mac and added to every chat's system prompt.
struct AssistantProfile: Codable, Equatable {
    var assistantName = ""
    var emoji = ""
    var userName = ""
    var callMe = ""
    var aboutUser = ""
    var style = ""
    /// Emojis are on unless the user asks the assistant to stop (nil in files saved before this setting).
    var useEmoji: Bool?
    /// Next onboarding question to ask; `AssistantIntro.steps.count` means finished.
    var step = 0

    var isOnboarded: Bool { step >= AssistantIntro.questionCount }
    var displayName: String { assistantName.isEmpty ? "Assistant" : assistantName }
    var displayEmoji: String { emoji.isEmpty ? "✨" : emoji }

    static var fileURL: URL { InferoidPaths.support.appendingPathComponent("assistant.json") }

    static func load() -> AssistantProfile {
        guard let data = try? Data(contentsOf: fileURL), let value = try? JSONDecoder().decode(AssistantProfile.self, from: data) else { return AssistantProfile() }
        return value
    }

    func save() {
        try? FileManager.default.createDirectory(at: InferoidPaths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    /// The part of the system prompt that makes every chat personal.
    var systemPromptSection: String {
        guard isOnboarded else { return "" }
        var s = "\nYour name is \(displayName) \(displayEmoji)."
        if !callMe.isEmpty { s += " Call the user \(callMe)." }
        s += (useEmoji ?? true) ? " Use an emoji now and then where it fits, like a friend texting. If the user asks you to stop, stop." : " Never use emojis."
        if !aboutUser.isEmpty { s += "\nWhat the user told you about themselves: \(aboutUser)" }
        if !style.isEmpty { s += "\nHow they want you to talk: \(style)" }
        return s + "\n"
    }

    /// What the user said about themselves, for "what do you know about me?" questions.
    var aboutSection: String {
        var lines: [String] = []
        if !userName.isEmpty { lines.append("Name: \(userName)" + (callMe.isEmpty || callMe == userName ? "" : " (goes by \(callMe))")) }
        if !aboutUser.isEmpty { lines.append("In their words: \(aboutUser)") }
        if !style.isEmpty { lines.append("How they like answers: \(style)") }
        return lines.joined(separator: "\n")
    }
}

enum AssistantIntro {
    /// The assistant chat has a fixed id so it is always the same, first chat.
    static let threadID = UUID(uuidString: "A5510000-0000-4000-8000-000000000001")!
    static let questionCount = 4
    static let emojis = ["✨", "🦉", "🌱", "🧭", "🪐", "🦊", "🌊", "🔭"]

    static let opening = """
    Hey 👋 I just came online on your Mac. I'm your private assistant: I can read your meetings, people, books, media, trips and journal, and none of it leaves this Mac.

    Let's make this yours. First: what would you like to call me?
    """

    /// Applies the user's answer to the current step and returns the next message. `saved` lists titles the user
    /// already added (books, trips, meetings…) so the last message can point at them or invite them to add some.
    static func answer(_ raw: String, profile: inout AssistantProfile, saved: [String] = []) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch profile.step {
        case 0:
            profile.assistantName = cleanName(text, prefixes: ["call you", "you are", "you're", "name you", "your name is", "i'll call you", "i will call you", "let's go with", "how about"]) ?? "Assistant"
            // The assistant picks its own signature emoji (as OpenClaw does); the user can change it by asking.
            let seed = profile.assistantName.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            profile.emoji = emojis[seed % emojis.count]
            profile.step = 1
            return "\(profile.assistantName) it is \(profile.emoji) Now you: who are you, and what should I call you?"
        case 1:
            profile.userName = text
            profile.callMe = callName(from: text)
            profile.step = 2
            return "Good to meet you, \(profile.callMe). Tell me a little about yourself: what you do, who matters most to you, what you're working on. A few lines is plenty."
        case 2:
            profile.aboutUser = text
            profile.step = 3
            return "Thanks. Last one: how should I talk to you? Short and direct, or more detail? Anything I should never do?"
        case 3:
            profile.style = text
            if emojiPreference(in: text) == false { profile.useEmoji = false }
            profile.step = questionCount
            let mark = (profile.useEmoji ?? true) ? " \(profile.emoji)" : ""
            if saved.isEmpty {
                return "Got it, \(profile.callMe).\(mark)\n\nYour Brain is empty so far. Drop a book, article or video link into Library, add a trip in Travels, or record a meeting. Then ask me what it all says about you."
            }
            let named = saved.prefix(2).map { "\u{201C}\($0)\u{201D}" }.joined(separator: " and ")
            let more = saved.count > 2 ? " and \(saved.count - 2) more" : ""
            return "Got it, \(profile.callMe).\(mark)\n\nI see you've already added \(named)\(more). Ask me about any of them, or ask what they say about you."
        default:
            return ""
        }
    }

    /// "stop using emojis" / "no emojis" → false; "use emojis again" → true.
    static func emojiPreference(in text: String) -> Bool? {
        if text.range(of: #"(?i)\b(stop|no|no more|don'?t|do not|quit|without)\b[^.?!]*\bemojis?\b"#, options: .regularExpression) != nil { return false }
        if text.range(of: #"(?i)\b(use|bring back|start using)\b[^.?!]*\bemojis?\b"#, options: .regularExpression) != nil { return true }
        return nil
    }

    static func cleanName(_ text: String, prefixes: [String]) -> String? {
        var value = text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?\"'"))
        let lower = value.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix + " ") {
            value = String(value.dropFirst(prefix.count + 1))
            break
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " .!?\"'"))
        guard !value.isEmpty else { return nil }
        // A long sentence is not a name: keep its first two words.
        let words = value.split(separator: " ")
        return words.count > 3 ? words.prefix(2).joined(separator: " ") : value
    }

    /// "I'm Sara Lee, call me Sara" → "Sara"; "Mehran" → "Mehran".
    static func callName(from text: String) -> String {
        let patterns = [#"(?i)\bcall me\s+([\p{L}][\p{L}'\-]*)"#, #"(?i)\b(?:i am|i'm|im|my name is|name's|it's|this is)\s+([\p{L}][\p{L}'\-]*)"#]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let match = String(text[range])
                if let name = match.split(separator: " ").last { return String(name).trimmingCharacters(in: .punctuationCharacters) }
            }
        }
        let first = text.split { $0 == " " || $0 == "," || $0 == "." }.first.map(String.init) ?? text
        return first.isEmpty ? "there" : first
    }

    static func firstEmoji(in text: String) -> String? {
        text.first { character in
            guard let scalar = character.unicodeScalars.first else { return false }
            return scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && character.unicodeScalars.count > 1)
        }.map(String.init)
    }
}
