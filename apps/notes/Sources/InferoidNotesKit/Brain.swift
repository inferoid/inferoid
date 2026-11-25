import Foundation

public enum BrainSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case meeting, library, article, movies, journal, project, trip

    public var label: String {
        switch self {
        case .meeting: return "Meeting"
        case .library: return "Library"
        case .article: return "Article"
        case .movies: return "Media"
        case .journal: return "Journal"
        case .project: return "Project"
        case .trip: return "Trip"
        }
    }

    public var systemImage: String {
        switch self {
        case .meeting: return "person.2.wave.2"
        case .library: return "books.vertical"
        case .article: return "doc.text"
        case .movies: return "film"
        case .journal: return "book.pages"
        case .project: return "folder"
        case .trip: return "airplane"
        }
    }

    public var icon: String { systemImage }
}

/// A local record that can participate in Brain search. Extensions can register another kind without changing chat.
public protocol BrainSource: Sendable {
    var sourceID: String { get }
    var sourceKind: BrainSourceKind { get }
    var sourceTitle: String { get }
    var sourceDate: String { get }
    var textChunks: [String] { get }
    var includeInBrain: Bool { get }
}

/// A source provider that can be combined with the built-in meetings and projects by another edition or feature.
public protocol BrainSourceRegistry: Sendable {
    func sources() -> [any BrainSource]
}

public struct BrainSourceDocument: BrainSource, Hashable, Sendable {
    public let sourceID: String
    public let sourceKind: BrainSourceKind
    public let sourceTitle: String
    public let sourceDate: String
    public let textChunks: [String]
    public let includeInBrain: Bool

    public init(id: String, kind: BrainSourceKind, title: String, date: String, chunks: [String], includeInBrain: Bool) {
        sourceID = id; sourceKind = kind; sourceTitle = title; sourceDate = date
        textChunks = chunks; self.includeInBrain = includeInBrain
    }
}

public struct SourceRegistry: BrainSourceRegistry, Sendable {
    private let registered: [BrainSourceDocument]

    public init(meetings: [Meeting] = [], projects: [Project] = [], includeCollections: Bool = true) {
        registered = Self.documents(meetings: meetings, projects: projects, includeCollections: includeCollections)
    }

    public func sources() -> [any BrainSource] { registered.map { $0 as any BrainSource } }

    /// The complete local source set. `includeInBrain` is kept on every document so callers can use the same
    /// registry for lookup/UI and for searching without accidentally exposing excluded or private-at-creation data.
    public static func documents(meetings: [Meeting], projects: [Project], includeCollections: Bool = true) -> [BrainSourceDocument] {
        let meetingDocs = meetings.map { BrainSourceDocument(id: $0.sourceID, kind: $0.sourceKind, title: $0.title, date: $0.date,
                                                              chunks: $0.textChunks, includeInBrain: $0.includeInBrain) }
        guard includeCollections else { return meetingDocs + projects.flatMap { ProjectStore.documents(for: $0, includedOnly: false) } }

        let collectionDocs = CollectionStore.brainItems().map { item in
            let date = item.kind == .movies ? (item.watchedDates.first ?? item.createdAt) : (item.readingStart ?? item.createdAt)
            var text = "# \(item.title.isEmpty ? "Untitled" : item.title)"
            if item.kind == .articles {
                if !item.source.isEmpty { text += "\n\(item.source)" }
                if !item.url.isEmpty { text += "\n\(item.url)" }
            } else if !item.creator.isEmpty { text += "\n\(item.creator)" }
            if item.kind == .movies { text += "\n\(item.mediaType.title)" }
            if !item.notes.isEmpty { text += "\n\(item.notes)" }
            if !item.highlights.isEmpty { text += "\n" + item.highlights.map(\.text).joined(separator: "\n") }
            let kind: BrainSourceKind
            switch item.kind {
            case .library: kind = .library
            case .articles: kind = .article
            case .movies: kind = .movies
            }
            return BrainSourceDocument(id: item.id.uuidString, kind: kind, title: item.title.isEmpty ? "Untitled" : item.title,
                                       date: ISO8601DateFormatter().string(from: date), chunks: Brain.chunks(text), includeInBrain: item.includeInBrain)
        }
        // One page per day (older rewrites left several copies of a day) and no routine output: generated briefs fed back
        // into the Brain crowd out the user's own records.
        let journal = JournalStore.load()
        let pages = journal.filter { $0.kind != .routine && ($0.kind != .daily || JournalStore.day($0.date, in: journal).id == $0.id) }
        let journalDocs = pages.map { entry in
            BrainSourceDocument(id: entry.id.uuidString, kind: .journal,
                                title: entry.sourceTitle,
                                date: ISO8601DateFormatter().string(from: entry.date),
                                chunks: Brain.chunks(entry.brainText), includeInBrain: entry.includeInBrain)
        }
        let tripDocs = TravelStore.load().map { trip in
            var text = "# \(trip.title.isEmpty ? trip.place : trip.title)\n\(trip.place)"
            if !trip.places.isEmpty { text += "\nPlaces: " + trip.places.joined(separator: ", ") }
            if !trip.peopleMet.isEmpty { text += "\nPeople met: " + trip.peopleMet.joined(separator: ", ") }
            if !trip.notes.isEmpty { text += "\n\(trip.notes)" }
            return BrainSourceDocument(id: trip.id.uuidString, kind: .trip,
                                       title: trip.title.isEmpty ? trip.place : trip.title,
                                       date: ISO8601DateFormatter().string(from: trip.startDate), chunks: Brain.chunks(text),
                                       includeInBrain: trip.includeInBrain)
        }
        return meetingDocs + collectionDocs + journalDocs + tripDocs + projects.flatMap { ProjectStore.documents(for: $0, includedOnly: false) }
    }

    public static func lookup(_ id: String, meetings: [Meeting], projects: [Project]) -> BrainSourceDocument? {
        let all = documents(meetings: meetings, projects: projects)
        if let exact = all.first(where: { $0.sourceID == id }) { return exact }
        guard let projectID = projectIDFromEpisode(id), let project = projects.first(where: { $0.id == projectID }) else { return nil }
        return BrainSourceDocument(id: id, kind: .project, title: project.name, date: project.updatedAt.iso8601,
                                   chunks: Brain.chunks(project.instructions), includeInBrain: project.includeInBrain)
    }

    /// Resolves the folder stored in Brain graph episodes to the canonical source ID used by chat and chips.
    public static func episodeSource(_ storedID: String, meetings: [Meeting], projects: [Project]) -> BrainSourceDocument? {
        if let meeting = meetings.first(where: { $0.folder.path == storedID }) {
            return BrainSourceDocument(id: meeting.sourceID, kind: meeting.sourceKind, title: meeting.title, date: meeting.date,
                                       chunks: meeting.textChunks, includeInBrain: meeting.includeInBrain)
        }
        if let projectID = projectIDFromEpisode(storedID), let project = projects.first(where: { $0.id == projectID }) {
            return BrainSourceDocument(id: storedID, kind: .project, title: project.name, date: project.updatedAt.iso8601,
                                       chunks: Brain.chunks(project.instructions), includeInBrain: project.includeInBrain)
        }
        for item in CollectionStore.brainItems() where CollectionStore.folder(for: item).path == storedID {
            let kind: BrainSourceKind
            switch item.kind {
            case .library: kind = .library
            case .articles: kind = .article
            case .movies: kind = .movies
            }
            return documents(meetings: [], projects: []).first { $0.sourceID == item.id.uuidString && $0.sourceKind == kind }
        }
        for trip in TravelStore.load() where TravelStore.folder(for: trip).path == storedID {
            return documents(meetings: [], projects: []).first { $0.sourceID == trip.id.uuidString && $0.sourceKind == .trip }
        }
        for entry in JournalStore.load() where JournalStore.folder(for: entry).path == storedID {
            return documents(meetings: [], projects: []).first { $0.sourceID == entry.id.uuidString && $0.sourceKind == .journal }
        }
        return lookup(storedID, meetings: meetings, projects: projects)
    }

    public static func projectID(from sourceID: String) -> UUID? {
        let parts = sourceID.split(separator: ":")
        guard parts.count >= 2, parts[0] == "project" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    public static func projectIDFromEpisode(_ sourceID: String) -> UUID? {
        let parts = sourceID.split(separator: ":")
        guard parts.count == 2, parts[0] == "project" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }
}

/// Private brain: search and questions across local meetings and registered sources in the vault.
/// Search is keyword ranking (BM25-style) over source chunks; no extra model is needed.
/// A question is answered by the notes model from the best-matching local records, citing their title and date.
public struct Meeting: Identifiable, Hashable, Sendable {
    public var id: String { folder.path }
    public let folder: URL
    public let title: String
    public let date: String
    public let notes: String
    public let transcript: String
    /// Missing metadata means included, so meetings saved before this setting was added keep working.
    public let includeInBrain: Bool
    public let sourceKind: BrainSourceKind
    public let sourceID: String

    public init(folder: URL, title: String, date: String, notes: String, transcript: String, includeInBrain: Bool = true,
                sourceKind: BrainSourceKind = .meeting, sourceID: String? = nil) {
        self.folder = folder
        self.title = title
        self.date = date
        self.notes = notes
        self.transcript = transcript
        self.includeInBrain = includeInBrain
        self.sourceKind = sourceKind
        self.sourceID = sourceID ?? folder.path
    }
}

extension Meeting: BrainSource {
    public var sourceTitle: String { title }
    public var sourceDate: String { date }
    public var textChunks: [String] { Brain.chunks(notes + "\n" + transcript) }
}

struct Hit: Identifiable, Hashable {
    var id: String { meeting.sourceID }
    let meeting: Meeting
    let score: Double
    let snippet: String
}

public struct SourceHit: Identifiable, Hashable, Sendable {
    public let sourceID: String
    public let kind: BrainSourceKind
    public let title: String
    public let date: String
    public let score: Double
    public let snippet: String

    public var id: String { sourceID }

    public init(sourceID: String, kind: BrainSourceKind, title: String, date: String, score: Double, snippet: String) {
        self.sourceID = sourceID; self.kind = kind; self.title = title; self.date = date
        self.score = score; self.snippet = snippet
    }
}

public enum Brain {
    static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "was", "are", "were",
        "what", "who", "when", "where", "why", "how", "did", "do", "does", "we", "i", "you", "it", "that", "this", "with", "at",
        "by", "be", "about", "from", "our", "my", "me", "them", "they", "any", "all", "which", "there", "have", "has", "had"]

    static func terms(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }

    public static func chunks(_ text: String, size: Int = 1800) -> [String] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        var chunks: [String] = []
        var start = cleaned.startIndex
        while start < cleaned.endIndex {
            let end = cleaned.index(start, offsetBy: size, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            chunks.append(String(cleaned[start..<end]))
            if end == cleaned.endIndex { break }
            start = cleaned.index(end, offsetBy: -200, limitedBy: cleaned.startIndex) ?? end
        }
        return chunks
    }

    static func load(root: URL = Store.root) -> [Meeting] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var records = dirs.compactMap { dir -> Meeting? in
            let notes = (try? String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
            let transcript = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
            if notes.isEmpty && transcript.isEmpty { return nil }
            let name = dir.lastPathComponent  // "yyyy-MM-dd HHmm Title"
            let date = String(name.prefix(10))
            let title = notes.split(separator: "\n").first.map { $0.replacingOccurrences(of: "# ", with: "") }
                ?? String(name.dropFirst(16))
            return Meeting(folder: dir, title: title, date: date, notes: notes, transcript: transcript,
                           includeInBrain: Store.includeInBrain(in: dir))
        }
        return records.sorted { $0.date > $1.date }
    }

    /// BM25 over notes (counted twice: they are the distilled version) plus transcript.
    static func search(_ query: String, in meetings: [Meeting], limit: Int = 8) -> [Hit] {
        let meetings = meetings.filter(\.includeInBrain)
        let q = Array(Set(terms(query)))
        guard !q.isEmpty, !meetings.isEmpty else { return [] }
        let docs = meetings.map { m -> [String: Int] in
            var tf: [String: Int] = [:]
            for t in terms(m.title) { tf[t, default: 0] += 2 }
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

    public static func searchSources(_ query: String, in sources: [any BrainSource], limit: Int = 8) -> [SourceHit] {
        let sources = sources.filter(\.includeInBrain)
        let q = Array(Set(terms(query)))
        guard !q.isEmpty, !sources.isEmpty else { return [] }
        let docs = sources.map { source -> [String: Int] in
            var tf: [String: Int] = [:]
            for chunk in source.textChunks { for term in terms(chunk) { tf[term, default: 0] += 1 } }
            return tf
        }
        let lengths = docs.map { Double(max(1, $0.values.reduce(0, +))) }
        let avg = max(1, lengths.reduce(0, +) / Double(docs.count))
        let count = Double(docs.count)
        var hits: [SourceHit] = []
        for (index, tf) in docs.enumerated() {
            var score = 0.0
            for term in q {
                guard let frequency = tf[term] else { continue }
                let df = Double(docs.filter { $0[term] != nil }.count)
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let f = Double(frequency)
                score += idf * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * lengths[index] / avg))
            }
            if score > 0 {
                let source = sources[index]
                hits.append(SourceHit(sourceID: source.sourceID, kind: source.sourceKind, title: source.sourceTitle,
                                      date: source.sourceDate, score: score, snippet: sourceSnippet(source, q)))
            }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    private static func sourceSnippet(_ source: any BrainSource, _ query: [String]) -> String {
        for chunk in source.textChunks {
            for line in chunk.split(separator: "\n") where query.contains(where: { line.lowercased().contains($0) }) {
                return String(line.trimmingCharacters(in: .whitespaces).prefix(180))
            }
        }
        return String(source.textChunks.first?.prefix(180) ?? "")
    }

    static func sourceDocuments(meetings: [Meeting], projects: [Project]) -> [BrainSourceDocument] {
        SourceRegistry.documents(meetings: meetings, projects: projects)
    }

    public static func context(for question: String, sourceHits: [SourceHit], sources: [any BrainSource], budget: Int = 12_000) -> String {
        let terms = terms(question)
        var out = ""
        for hit in sourceHits {
            guard let source = sources.first(where: { $0.sourceID == hit.sourceID }) else { continue }
            let heading = "### \(source.sourceKind.label): \(source.sourceTitle), \(source.sourceDate.prefix(10))\n"
            var block = heading
            for chunk in source.textChunks {
                let lines = chunk.split(separator: "\n").filter { line in terms.contains { line.lowercased().contains($0) } }.prefix(12)
                if !lines.isEmpty { block += lines.map { chatSpeakerText(String($0)) }.joined(separator: "\n") + "\n" }
            }
            if block == heading { block += source.textChunks.first ?? "" }
            if out.count + block.count > budget { break }
            out += block + "\n"
        }
        return out
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
    You are a private assistant on the user's Mac for their own local records; nothing they type leaves it. \
    Answer helpfully and briefly. None of the user's saved records matched this question, so answer \
    from general knowledge and never invent record details. Use saved records only when they answer the user's question; \
    never bring up records, prices or plans the user did not ask about. If the question needs their own records, say so.
    """

    static let askSystem = """
    You answer questions about the user's saved records, using only the excerpts below. Use record excerpts only when they answer the user's question; never bring up records or plans the user did not ask about.
    Transcript labels use "you (the user)" for the person on this Mac and "the other person" for the call participant. Cite the record for every fact, like [Title, 2026-11-14]. If the records below do not answer the
    question, say so plainly and do not guess. Keep the answer short: a few sentences or a short list.
    """

    /// The prompt context: notes of the best meetings plus the transcript lines that mention the question's words.
    static func context(for question: String, hits: [Hit], budget: Int = 24_000) -> String {
        let q = terms(question)
        var out = ""
        for hit in hits {
            let m = hit.meeting
            var block = "### \(m.title) (\(m.date.prefix(10)))\n\(chatSpeakerText(m.notes))\n"
            let lines = m.transcript.split(separator: "\n").filter { line in
                let lower = line.lowercased()
                return q.contains { lower.contains($0) }
            }.prefix(12)
            if !lines.isEmpty { block += "Transcript lines:\n" + lines.map { chatSpeakerText(String($0)) }.joined(separator: "\n") + "\n" }
            if out.count + block.count > budget { break }
            out += block + "\n"
        }
        return out
    }

    static func chatSpeakerText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\bMe\b"#, with: "you (the user)", options: .regularExpression)
            .replacingOccurrences(of: #"\bThem\b"#, with: "the other person", options: .regularExpression)
    }

    static func ask(_ question: String, model: String, meetings: [Meeting], projects: [Project] = [],
                    onText: (@Sendable (String) -> Void)? = nil) async throws -> (answer: String, sources: [SourceHit]) {
        let documents = SourceRegistry.documents(meetings: meetings, projects: projects)
        let hits = Array(searchSources(question, in: documents, limit: 5))
        guard !hits.isEmpty else {
            // No local source matches: answer the question itself instead of a dead end. Still fully local.
            let answer = try await Summarizer.complete(system: generalSystem, user: question, model: model, onText: onText)
            return (answer.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let user = "Saved records:\n\n" + context(for: question, sourceHits: hits, sources: documents) + "\nQuestion: " + question
        let answer = try await Summarizer.complete(system: askSystem, user: user, model: model, onText: onText)
        return (answer.trimmingCharacters(in: .whitespacesAndNewlines), hits)
    }
}
