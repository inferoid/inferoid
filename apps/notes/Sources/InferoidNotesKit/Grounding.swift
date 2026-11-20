import Foundation

/// Keeps meeting notes to what was actually said. A small notes model given almost no transcript can reproduce a
/// meeting it saw in training (a one-line test produced a made-up "Project Phoenix" kickoff), so:
/// - very short recordings get no model notes at all, and
/// - any point naming a person, project or place that never appears in the transcript is dropped.
enum Grounding {
    /// Below this many spoken words there is nothing to summarise.
    static let minWords = 40

    static func wordCount(_ lines: [Line]) -> Int {
        lines.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    static func shortNotes(_ lines: [Line]) -> Notes {
        Notes(title: "Short recording",
              summary: "Too little was said to write notes (\(wordCount(lines)) words). The transcript is saved.",
              key_points: [], decisions: [], action_items: [], open_questions: [])
    }

    /// Names in `text` that the transcript never mentions. Only names are checked: speech recognition writes numbers
    /// as words ("thirty minutes"), so a digit check would drop correct points. Tested on 56,630 reference points from
    /// the notes training set: 0.2% wrongly flagged.
    static func unsupported(_ text: String, transcript: String, allowed: Set<String>) -> [String] {
        let said = Set(tokens(transcript.lowercased()))
        let months: Set<String> = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
                                   "mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        func known(_ part: String) -> Bool {
            allowed.contains(part) || said.contains(part) || months.contains(String(part.prefix(3)))
                || (part.hasSuffix("s") && said.contains(String(part.dropLast())))
        }
        var missing: [String] = []
        let words = text.split(whereSeparator: { $0.isWhitespace })
        for (i, raw) in words.enumerated() {
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard let first = word.first, first.isUppercase, !word.contains(where: \.isNumber),
                  word.dropFirst().contains(where: \.isLowercase),
                  word.filter(\.isUppercase).count < 2 else { continue }   // acronyms like MWh, FTEs: skip
            // A capitalised word at a sentence start is an ordinary word.
            let previous = i > 0 ? words[i - 1] : ""
            if i == 0 || [".", ":", "?", "!"].contains(where: { previous.hasSuffix($0) }) { continue }
            var key = word.lowercased()
            if key.hasSuffix("'s") || key.hasSuffix("’s") { key = String(key.dropLast(2)) }
            let parts = key.split(whereSeparator: { "-–/".contains($0) }).map(String.init)
            if parts.allSatisfy(known) { continue }
            missing.append(word)
        }
        return missing
    }

    /// Drops points that name things the transcript does not contain. Returns the notes and how many
    /// points were dropped. The title and summary are replaced if they are not supported either.
    static func check(_ notes: Notes, transcript: String, attendees: [String]) -> (Notes, Int) {
        var allowed: Set<String> = ["me", "them", "i", "ok", "okay"]
        for name in attendees { for part in name.lowercased().split(separator: " ") { allowed.insert(String(part)) } }
        let bad = { (s: String) in !unsupported(s, transcript: transcript, allowed: allowed).isEmpty }
        var out = notes, dropped = 0
        func keep(_ list: [String]) -> [String] {
            let kept = list.filter { !bad($0) }
            dropped += list.count - kept.count
            return kept
        }
        out.key_points = keep(notes.key_points)
        out.decisions = keep(notes.decisions)
        out.open_questions = keep(notes.open_questions)
        out.action_items = notes.action_items.filter { !bad($0.task) && !bad($0.due) }
        dropped += notes.action_items.count - out.action_items.count
        if bad(out.summary) {
            out.summary = "The model's summary mentioned details that are not in the transcript, so it was removed."
            dropped += 1
        }
        if bad(out.title) { out.title = "Meeting notes" }
        return (out, dropped)
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }).map(String.init)
    }
}
