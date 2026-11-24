import AppKit
import Foundation
import SwiftUI

enum CollectionKind: String, Codable, CaseIterable, Hashable, Sendable {
    // `library` and `movies` are retained as their on-disk names for old JSON and vault folders.
    case library, articles, movies

    var title: String {
        switch self {
        case .library: return "Books"
        case .articles: return "Articles"
        case .movies: return "Media"
        }
    }
    var icon: String { self == .library ? "books.vertical" : (self == .articles ? "doc.text" : "play.rectangle") }
    var creatorLabel: String { self == .library ? "Author" : (self == .articles ? "Source / site" : "Creator / channel") }
    var dateLabel: String { self == .library ? "Reading period" : (self == .articles ? "Date read" : "Watched / listened") }
}

enum CollectionMediaType: String, Codable, CaseIterable, Hashable, Sendable {
    case movie, show, youtube, podcast, talk

    var title: String { rawValue == "youtube" ? "YouTube" : rawValue.capitalized }
    var icon: String {
        switch self {
        case .movie: return "film"
        case .show: return "tv"
        case .youtube: return "play.rectangle"
        case .podcast: return "mic"
        case .talk: return "person.wave.2"
        }
    }
}

enum CollectionBookFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case print, ebook, audiobook

    var title: String { rawValue.capitalized }
}

struct CollectionHighlight: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var location: String?

    init(text: String, location: String? = nil) {
        self.text = text
        self.location = location
    }
}

struct CollectionItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: CollectionKind
    var title: String
    var creator: String
    var year: Int?
    var coverFile: String?
    var coverSeed: Int
    var source: String
    var url: String
    var format: CollectionBookFormat
    var type: CollectionMediaType
    var notes: String
    var highlights: [CollectionHighlight]
    var includeInBrain: Bool
    var readingStart: Date?
    var readingEnd: Date?
    var readingNow: Bool
    var watchedDates: [Date]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), kind: CollectionKind, title: String = "", creator: String = "", year: Int? = nil,
         coverFile: String? = nil, coverSeed: Int? = nil, notes: String = "", highlights: [CollectionHighlight] = [],
         includeInBrain: Bool = !PrivateMode.isEnabled, readingStart: Date? = nil, readingEnd: Date? = nil, readingNow: Bool = false,
         watchedDates: [Date] = [], createdAt: Date = Date(), updatedAt: Date = Date(), source: String = "",
         url: String = "", format: CollectionBookFormat = .print, type: CollectionMediaType = .movie) {
        self.id = id; self.kind = kind; self.title = title; self.creator = creator; self.year = year
        self.coverFile = coverFile; self.coverSeed = coverSeed ?? Self.seed(for: title); self.notes = notes
        self.source = source; self.url = url; self.format = format; self.type = type
        self.highlights = highlights; self.includeInBrain = includeInBrain; self.readingStart = readingStart
        self.readingEnd = readingEnd; self.readingNow = readingNow; self.watchedDates = watchedDates
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, creator, year, coverFile, coverSeed, source, url, format, type, notes, highlights, includeInBrain
        case readingStart, readingEnd, readingNow, watchedDates, createdAt, updatedAt
    }

    private enum LegacyCodingKeys: String, CodingKey { case bookFormat, mediaType }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try values.decodeIfPresent(CollectionKind.self, forKey: .kind) ?? .library
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        creator = try values.decodeIfPresent(String.self, forKey: .creator) ?? ""
        year = try values.decodeIfPresent(Int.self, forKey: .year)
        coverFile = try values.decodeIfPresent(String.self, forKey: .coverFile)
        coverSeed = try values.decodeIfPresent(Int.self, forKey: .coverSeed) ?? Self.seed(for: title)
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? ""
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let oldFormat = try legacy.decodeIfPresent(CollectionBookFormat.self, forKey: .bookFormat)
        let oldType = try legacy.decodeIfPresent(CollectionMediaType.self, forKey: .mediaType)
        format = try values.decodeIfPresent(CollectionBookFormat.self, forKey: .format)
            ?? oldFormat ?? .print
        type = try values.decodeIfPresent(CollectionMediaType.self, forKey: .type)
            ?? oldType ?? .movie
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        highlights = try values.decodeIfPresent([CollectionHighlight].self, forKey: .highlights) ?? []
        includeInBrain = try values.decodeIfPresent(Bool.self, forKey: .includeInBrain) ?? true
        readingStart = try values.decodeIfPresent(Date.self, forKey: .readingStart)
        readingEnd = try values.decodeIfPresent(Date.self, forKey: .readingEnd)
        readingNow = try values.decodeIfPresent(Bool.self, forKey: .readingNow) ?? false
        watchedDates = try values.decodeIfPresent([Date].self, forKey: .watchedDates) ?? []
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    static func seed(for title: String) -> Int {
        title.utf8.reduce(17) { ($0 &* 31) &+ Int($1) } & 0x7fffffff
    }

    var bookFormat: CollectionBookFormat {
        get { format }
        set { format = newValue }
    }

    var mediaType: CollectionMediaType {
        get { type }
        set { type = newValue }
    }
}

enum JournalEntryKind: String, Codable, CaseIterable, Hashable, Sendable {
    case daily, voice, decision, weekly
    /// A routine's result ("Promise check"), shown under the day's notes, never mixed into them.
    case routine

    var label: String {
        switch self {
        case .daily: return "Daily"
        case .voice: return "Voice"
        case .decision: return "Decision"
        case .weekly: return "Weekly"
        case .routine: return "Routine"
        }
    }

    var icon: String {
        switch self {
        case .daily: return "book.pages"
        case .voice: return "waveform"
        case .decision: return "arrow.triangle.branch"
        case .weekly: return "calendar"
        case .routine: return "repeat"
        }
    }
}

struct DecisionSourceLink: Codable, Hashable, Sendable, Identifiable {
    var sourceID: String
    var kind: BrainSourceKind
    var title: String
    var id: String { sourceID }

    init(sourceID: String, kind: BrainSourceKind, title: String) {
        self.sourceID = sourceID; self.kind = kind; self.title = title
    }
}

struct JournalEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var date: Date
    var kind: JournalEntryKind
    var text: String
    var voiceMemo: String
    var decisionTitle: String
    var decisionWhy: String
    var decisionExpectation: String
    var decisionShapedBy: [DecisionSourceLink]
    var checkBackDate: Date?
    var includeInBrain: Bool
    var createdAt: Date
    var updatedAt: Date
    /// The day's activity summarized by the local model, and the activity it was made from (to know when to redo it).
    var summary = ""
    var summaryKey = ""

    init(id: UUID = UUID(), date: Date = Date(), kind: JournalEntryKind = .daily, text: String = "", voiceMemo: String = "",
         decisionTitle: String = "", decisionWhy: String = "", decisionExpectation: String = "",
         decisionShapedBy: [DecisionSourceLink] = [], checkBackDate: Date? = nil,
         includeInBrain: Bool = !PrivateMode.isEnabled, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.date = date; self.kind = kind; self.text = text; self.voiceMemo = voiceMemo
        self.decisionTitle = decisionTitle; self.decisionWhy = decisionWhy; self.decisionExpectation = decisionExpectation
        self.decisionShapedBy = decisionShapedBy
        self.checkBackDate = checkBackDate ?? (kind == .decision ? Calendar.current.date(byAdding: .day, value: 30, to: date) : nil)
        self.includeInBrain = includeInBrain; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, kind, text, voiceMemo, decisionTitle, decisionWhy, decisionExpectation, decisionShapedBy
        case checkBackDate, includeInBrain, createdAt, updatedAt, summary, summaryKey
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try values.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        if let decodedKind = try values.decodeIfPresent(JournalEntryKind.self, forKey: .kind) {
            kind = decodedKind
        } else if let oldVoice = try values.decodeIfPresent(String.self, forKey: .voiceMemo), !oldVoice.isEmpty {
            kind = .voice
        } else {
            kind = .daily
        }
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        voiceMemo = try values.decodeIfPresent(String.self, forKey: .voiceMemo) ?? ""
        decisionTitle = try values.decodeIfPresent(String.self, forKey: .decisionTitle) ?? ""
        decisionWhy = try values.decodeIfPresent(String.self, forKey: .decisionWhy) ?? ""
        decisionExpectation = try values.decodeIfPresent(String.self, forKey: .decisionExpectation) ?? ""
        decisionShapedBy = try values.decodeIfPresent([DecisionSourceLink].self, forKey: .decisionShapedBy) ?? []
        checkBackDate = try values.decodeIfPresent(Date.self, forKey: .checkBackDate)
            ?? (kind == .decision ? Calendar.current.date(byAdding: .day, value: 30, to: date) : nil)
        includeInBrain = try values.decodeIfPresent(Bool.self, forKey: .includeInBrain) ?? true
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? date
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        summaryKey = try values.decodeIfPresent(String.self, forKey: .summaryKey) ?? ""
    }

    var sourceTitle: String {
        switch kind {
        case .decision: return decisionTitle.isEmpty ? "Decision \(date.formatted(date: .numeric, time: .omitted))" : decisionTitle
        case .weekly: return "Weekly reflection \(date.formatted(date: .numeric, time: .omitted))"
        case .routine: return decisionTitle.isEmpty ? "Routine \(date.formatted(date: .numeric, time: .omitted))" : decisionTitle
        case .voice: return "Voice memo \(date.formatted(date: .numeric, time: .omitted))"
        case .daily: return "Journal \(date.formatted(date: .numeric, time: .omitted))"
        }
    }

    var brainText: String {
        var parts = [text, voiceMemo]
        if kind == .decision {
            parts += [decisionTitle, decisionWhy, decisionExpectation]
            parts.append(decisionShapedBy.map { "Shaped by: \($0.title)" }.joined(separator: "\n"))
        }
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    }
}

enum CollectionStore {
    static var rootOverride: URL?

    static func root(_ kind: CollectionKind) -> URL {
        let folderName: String
        switch kind {
        case .library: folderName = "Library"
        case .articles: folderName = "Articles"
        case .movies: folderName = "Movies"
        }
        return (rootOverride ?? InferoidPaths.support).appendingPathComponent(folderName, isDirectory: true)
    }

    static func folder(for item: CollectionItem) -> URL { root(item.kind).appendingPathComponent(item.id.uuidString, isDirectory: true) }

    static func load(_ kind: CollectionKind) -> [CollectionItem] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: root(kind), includingPropertiesForKeys: nil)) ?? []
        let decoder = makeDecoder()
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("item.json")),
                  let item = try? decoder.decode(CollectionItem.self, from: data) else { return nil }
            return item
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func item(id: UUID, kind: CollectionKind) -> CollectionItem? { load(kind).first { $0.id == id } }

    static func save(_ item: CollectionItem) throws {
        let folder = folder(for: item)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var value = item
        if PrivateMode.isEnabled { value.includeInBrain = false }
        value.updatedAt = Date()
        try encode(value).write(to: folder.appendingPathComponent("item.json"), options: .atomic)
        try writeBrainFiles(value, folder: folder)
        let meta: [String: Any] = ["started": ISO8601DateFormatter().string(from: valueDate(value)),
                                   "includeInBrain": value.includeInBrain]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// Moves an item's folder (cover, notes, highlights) when the user changes its kind.
    static func move(_ item: CollectionItem, to kind: CollectionKind) throws {
        var moved = item; moved.kind = kind
        let source = folder(for: item), destination = folder(for: moved)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.createDirectory(at: root(kind), withIntermediateDirectories: true)
        try? BrainStore().removeMeetingData(meetingFolder: source)
        try FileManager.default.moveItem(at: source, to: destination)
    }

    static func setCover(_ source: URL, for item: CollectionItem) throws -> CollectionItem {
        let folder = folder(for: item)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let name = "cover.\(ext)"
        let destination = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        var updated = item; updated.coverFile = name; updated.updatedAt = Date()
        try save(updated)
        return updated
    }

    static func setCoverData(_ data: Data, fileExtension: String = "jpg", for item: CollectionItem) throws -> CollectionItem {
        let folder = folder(for: item)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = fileExtension.isEmpty ? "jpg" : fileExtension
        let name = "cover.\(ext)"
        let destination = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination, options: .atomic)
        var updated = item; updated.coverFile = name; updated.updatedAt = Date()
        try save(updated)
        return updated
    }

    static func coverURL(for item: CollectionItem) -> URL? {
        guard let file = item.coverFile else { return nil }
        return folder(for: item).appendingPathComponent(file)
    }

    static func delete(_ item: CollectionItem) throws {
        try? FileManager.default.trashItem(at: folder(for: item), resultingItemURL: nil)
        try? BrainStore().removeMeetingData(meetingFolder: folder(for: item))
    }

    static func setIncludeInBrain(_ included: Bool, for item: CollectionItem) throws -> CollectionItem {
        var updated = item; updated.includeInBrain = included; updated.updatedAt = Date()
        try save(updated)
        if !included { try? BrainStore().removeMeetingData(meetingFolder: folder(for: item)) }
        return updated
    }

    static func brainItems() -> [CollectionItem] { CollectionKind.allCases.flatMap(load) }

    private static func writeBrainFiles(_ item: CollectionItem, folder: URL) throws {
        var notes = "# \(item.title.isEmpty ? "Untitled" : item.title)\n\n"
        if item.kind == .articles {
            if !item.source.isEmpty { notes += "Source / site: \(item.source)\n" }
        } else if !item.creator.isEmpty { notes += "\(item.kind.creatorLabel): \(item.creator)\n" }
        if !item.url.isEmpty { notes += "URL: \(item.url)\n" }
        if item.kind == .library { notes += "Format: \(item.format.title)\n" }
        if item.kind == .movies { notes += "Type: \(item.type.title)\n" }
        if let year = item.year { notes += "Year: \(year)\n" }
        if !item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notes += "\n## Notes\n\n\(item.notes)\n" }
        if !item.highlights.isEmpty {
            notes += "\n## Highlights\n\n"
            notes += item.highlights.map { "- \"\($0.text)\"" + ($0.location.map { " (\($0))" } ?? "") }.joined(separator: "\n") + "\n"
        }
        try notes.write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        var transcriptLines: [String] = []
        if !item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { transcriptLines.append("[Notes] \(item.notes)") }
        transcriptLines += item.highlights.enumerated().map { index, highlight in
            "[Highlight \(index + 1)] \(highlight.text)" + (highlight.location.map { " (\($0))" } ?? "")
        }
        let transcript = transcriptLines.joined(separator: "\n")
        try transcript.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    private static func valueDate(_ item: CollectionItem) -> Date {
        if item.kind != .movies { return item.readingStart ?? item.createdAt }
        return item.watchedDates.first ?? item.createdAt
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = makeEncoder(); return try encoder.encode(value)
    }

    private static func makeEncoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
    private static func makeDecoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

enum JournalStore {
    static var rootOverride: URL?
    static var root: URL { (rootOverride ?? InferoidPaths.support).appendingPathComponent("Journal", isDirectory: true) }
    static func folder(for entry: JournalEntry) -> URL { root.appendingPathComponent(entry.id.uuidString, isDirectory: true) }

    static func load() -> [JournalEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("entry.json")) else { return nil }
            return try? d.decode(JournalEntry.self, from: data)
        }.sorted { $0.date > $1.date }
    }

    static func entry(id: UUID) -> JournalEntry? { load().first { $0.id == id } }

    /// The one daily page for `day` (not saved until it has content). Empty duplicate pages from the old
    /// "New entry" button are removed.
    static func day(_ day: Date, in entries: [JournalEntry]) -> JournalEntry {
        let calendar = Calendar.current
        let sameDay = entries.filter { $0.kind == .daily && calendar.isDate($0.date, inSameDayAs: day) }
        return sameDay.first { !$0.text.isEmpty || !$0.summary.isEmpty || !$0.voiceMemo.isEmpty } ?? sameDay.first
            ?? JournalEntry(date: calendar.startOfDay(for: day).addingTimeInterval(12 * 3600), kind: .daily)
    }

    static func removeEmptyDuplicateDays() {
        let calendar = Calendar.current
        // Routine results used to be saved as the day's page ("# Promise check\n\n…"): move them to their own entries.
        for var entry in load() where entry.kind == .daily && entry.text.hasPrefix("# ") {
            let parts = entry.text.components(separatedBy: "\n\n")
            guard parts.count >= 2 else { continue }
            entry.kind = .routine
            entry.decisionTitle = String(parts[0].dropFirst(2))
            entry.text = parts.dropFirst().joined(separator: "\n\n")
            try? save(entry)
        }
        var keep: Set<UUID> = []
        let daily = load().filter { $0.kind == .daily }
        for entry in daily { keep.insert(day(entry.date, in: daily).id) }
        for entry in daily where !keep.contains(entry.id) && entry.text.isEmpty && entry.summary.isEmpty && entry.voiceMemo.isEmpty {
            try? FileManager.default.removeItem(at: folder(for: entry))
            _ = calendar
        }
    }

    static func dueDecisionCheckbacks(asOf date: Date = Date()) -> [JournalEntry] {
        load().filter { $0.kind == .decision && ($0.checkBackDate.map { $0 <= date } ?? false) }
            .sorted { ($0.checkBackDate ?? .distantFuture) < ($1.checkBackDate ?? .distantFuture) }
    }

    @discardableResult
    static func upsertWeeklyReflection(_ reflection: WeeklyReflection, includeInBrain: Bool = !PrivateMode.isEnabled) throws -> JournalEntry {
        if var existing = load().first(where: { $0.kind == .weekly && Calendar.current.isDate($0.date, inSameDayAs: reflection.weekStart) }) {
            existing.date = reflection.weekStart
            existing.text = reflection.journalText
            existing.includeInBrain = includeInBrain
            try save(existing)
            return existing
        }
        let entry = JournalEntry(date: reflection.weekStart, kind: .weekly, text: reflection.journalText, includeInBrain: includeInBrain)
        try save(entry)
        return entry
    }

    static func save(_ entry: JournalEntry) throws {
        let folder = folder(for: entry)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var value = entry; value.updatedAt = Date()
        if PrivateMode.isEnabled { value.includeInBrain = false }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(value).write(to: folder.appendingPathComponent("entry.json"), options: .atomic)
        var notes = "# \(value.sourceTitle)\n\n"
        if value.kind == .decision {
            notes += "## Why\n\n\(value.decisionWhy)\n\n## What I expect\n\n\(value.decisionExpectation)\n"
            if !value.decisionShapedBy.isEmpty { notes += "\n## What shaped it\n\n" + value.decisionShapedBy.map { "- \($0.title)" }.joined(separator: "\n") + "\n" }
        }
        if !value.summary.isEmpty { notes += "\n## What happened\n\n\(value.summary)\n" }
        notes += "\n\(value.text)\n"
        try notes.write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let voice = value.voiceMemo.isEmpty ? "" : value.voiceMemo
        let transcript = value.brainText
        try transcript.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let meta: [String: Any] = ["started": ISO8601DateFormatter().string(from: value.date), "includeInBrain": value.includeInBrain]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    static func delete(_ entry: JournalEntry) throws {
        try? FileManager.default.trashItem(at: folder(for: entry), resultingItemURL: nil)
        try? BrainStore().removeMeetingData(meetingFolder: folder(for: entry))
    }

    static func setIncludeInBrain(_ included: Bool, for entry: JournalEntry) throws -> JournalEntry {
        var updated = entry; updated.includeInBrain = included
        try save(updated)
        if !included { try? BrainStore().removeMeetingData(meetingFolder: folder(for: entry)) }
        return updated
    }
}

enum BrainContent {
    static func allFolders() -> [URL] {
        let collectionFolders = CollectionKind.allCases.flatMap { kind in
            (try? FileManager.default.contentsOfDirectory(at: CollectionStore.root(kind), includingPropertiesForKeys: nil)) ?? []
        }
        let journalFolders = (try? FileManager.default.contentsOfDirectory(at: JournalStore.root, includingPropertiesForKeys: nil)) ?? []
        let travelFolders = (try? FileManager.default.contentsOfDirectory(at: TravelStore.root, includingPropertiesForKeys: nil)) ?? []
        return (collectionFolders + journalFolders + travelFolders).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
    }

    static func process(folder: URL, model: String) async -> BrainExtraction.Result {
        guard let brain = try? BrainStore() else { return .failed }
        return await BrainExtraction.process(folder: folder, model: model, store: brain)
    }

    static func refresh(folder: URL, model: String) async -> BrainExtraction.Result {
        if let brain = try? BrainStore() { try? brain.removeMeetingData(meetingFolder: folder) }
        return await process(folder: folder, model: model)
    }
}

@MainActor
final class VoiceMemoRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var status = ""
    @Published var lines: [Line] = []
    private var mic: MicCapture?
    private var segmenter: Segmenter?
    private var pending: [Task<Void, Never>] = []

    func start() async {
        guard !isRecording, !Recorder.shared.isRecording, !Recorder.shared.isWriting else { status = "Finish the current meeting first"; return }
        lines = []
        await Recorder.shared.prepare()
        guard await Recorder.shared.transcriber.isReady else { status = "Speech model is not ready"; return }
        let segmenter = Segmenter { [weak self] samples, start, end in
            Task { @MainActor in
                guard let self else { return }
                let task = Task {
                    guard let text = try? await Recorder.shared.transcriber.transcribe(samples), !text.isEmpty else { return }
                    self.lines.append(Line(speaker: "Me", start: start, end: end, text: text))
                }
                self.pending.append(task)
            }
        }
        let mic = MicCapture()
        do {
            try mic.start({ [weak segmenter] samples in segmenter?.push(samples) }, voiceProcessingEnabled: Prefs.shared.voiceProcessingEnabled)
            self.segmenter = segmenter; self.mic = mic; isRecording = true; status = "Recording"
        } catch { status = error.localizedDescription }
    }

    func stop() async {
        guard isRecording else { return }
        mic?.stop(); mic = nil; segmenter?.flush(); segmenter = nil; isRecording = false
        for task in pending { await task.value }
        pending = []; status = lines.isEmpty ? "No speech captured" : "Voice memo ready"
    }

    var text: String { lines.sorted { $0.start < $1.start }.map { "[\(clock($0.start))] \($0.text)" }.joined(separator: "\n") }
}
