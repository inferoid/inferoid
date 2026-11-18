import Foundation

/// Private brain: search and questions across every saved meeting in ~/Documents/Inferoid Notes.
/// Search is keyword ranking (BM25) over each meeting's notes and transcript; no extra model is needed.
/// A question is answered by the notes model from the best-matching meetings only, citing them by title and date.
struct Meeting: Identifiable, Hashable {
    var id: String { folder.path }
    let folder: URL
    let title: String
    let date: String
    let notes: String
    let transcript: String
}

struct Hit: Identifiable, Hashable {
    var id: String { meeting.id }
    let meeting: Meeting
    let score: Double
    let snippet: String
}

enum Brain {
    static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "was", "are", "were",
        "what", "who", "when", "where", "why", "how", "did", "do", "does", "we", "i", "you", "it", "that", "this", "with", "at",
        "by", "be", "about", "from", "our", "my", "me", "them", "they", "any", "all", "which", "there", "have", "has", "had"]

    static func terms(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }

    static func load(root: URL = Store.root) -> [Meeting] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> Meeting? in
            let notes = (try? String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
            let transcript = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
            if notes.isEmpty && transcript.isEmpty { return nil }
            let name = dir.lastPathComponent  // "yyyy-MM-dd HHmm Title"
            let date = String(name.prefix(10))
            let title = notes.split(separator: "\n").first.map { $0.replacingOccurrences(of: "# ", with: "") }
                ?? String(name.dropFirst(16))
            return Meeting(folder: dir, title: title, date: date, notes: notes, transcript: transcript)
        }.sorted { $0.folder.lastPathComponent > $1.folder.lastPathComponent }
    }

    /// BM25 over notes (counted twice: they are the distilled version) plus transcript.
    static func search(_ query: String, in meetings: [Meeting], limit: Int = 8) -> [Hit] {
        let q = Array(Set(terms(query)))
        guard !q.isEmpty, !meetings.isEmpty else { return [] }
        let docs = meetings.map { m -> [String: Int] in
            var tf: [String: Int] = [:]
            for t in terms(m.notes) { tf[t, default: 0] += 2 }
            for t in terms(m.transcript) { tf[t, default: 0] += 1 }
            return tf
        }
        let lengths = docs.map { Double($0.values.reduce(0, +)) }
        let avg = max(1, lengths.reduce(0, +) / Double(docs.count))
        let n = Double(docs.count)
        var hits: [Hit] = []
        for (i, tf) in docs.enumerated() {
            var score = 0.0
            for t in q {
                guard let f = tf[t] else { continue }
                let df = Double(docs.filter { $0[t] != nil }.count)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let ff = Double(f)
                score += idf * ff * 2.2 / (ff + 1.2 * (0.25 + 0.75 * lengths[i] / avg))
            }
            if score > 0 { hits.append(Hit(meeting: meetings[i], score: score, snippet: snippet(meetings[i], q))) }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// The first notes line (else transcript line) that mentions a query term.
    static func snippet(_ m: Meeting, _ q: [String]) -> String {
        for text in [m.notes, m.transcript] {
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let lower = line.lowercased()
                if q.contains(where: { lower.contains($0) }) {
                    return String(line.trimmingCharacters(in: .whitespaces).prefix(180))
                }
            }
        }
        return String(m.notes.split(separator: "\n").dropFirst().first(where: { !$0.isEmpty })?.prefix(180) ?? "")
    }

    static let generalSystem = """
    You are a private assistant that runs entirely on the user's Mac; nothing they type leaves it. \
    Answer helpfully and briefly. None of the user's saved meetings matched this question, so answer \
    from general knowledge and never invent meeting details. If the question needs their own records, say so.
    """

    static let askSystem = """
    You answer questions about the user's past meetings, using only the meeting notes and transcript lines below.
    "Me" is the user. Cite the meeting for every fact, like [Title, 2026-11-14]. If the meetings below do not answer the
    question, say so plainly and do not guess. Keep the answer short: a few sentences or a short list.
    """

    /// The prompt context: notes of the best meetings plus the transcript lines that mention the question's words.
    static func context(for question: String, hits: [Hit], budget: Int = 24_000) -> String {
        let q = terms(question)
        var out = ""
        for hit in hits {
            let m = hit.meeting
            var block = "### \(m.title) (\(m.date))\n\(m.notes)\n"
            let lines = m.transcript.split(separator: "\n").filter { line in
                let lower = line.lowercased()
                return q.contains { lower.contains($0) }
            }.prefix(12)
            if !lines.isEmpty { block += "Transcript lines:\n" + lines.joined(separator: "\n") + "\n" }
            if out.count + block.count > budget { break }
            out += block + "\n"
        }
        return out
    }

    static func ask(_ question: String, model: String, meetings: [Meeting],
                    onText: (@Sendable (String) -> Void)? = nil) async throws -> (answer: String, sources: [Hit]) {
        let hits = Array(search(question, in: meetings, limit: 5))
        guard !hits.isEmpty else {
            // No meeting matches: answer the question itself instead of a dead end. Still fully local.
            let answer = try await Summarizer.complete(system: generalSystem, user: question, model: model, onText: onText)
            return (answer.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let user = "Meetings:\n\n" + context(for: question, hits: hits) + "\nQuestion: " + question
        let answer = try await Summarizer.complete(system: askSystem, user: user, model: model, onText: onText)
        return (answer.trimmingCharacters(in: .whitespacesAndNewlines), hits)
    }
}
