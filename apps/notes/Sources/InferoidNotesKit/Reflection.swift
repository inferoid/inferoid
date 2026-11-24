import Foundation
import SwiftUI

public struct WeeklyReflection: Codable, Hashable, Sendable {
    public let weekStart: Date
    public let people: [String]
    public let promisesMade: [String]
    public let promisesKept: [String]
    public let promisesOverdue: [String]
    public let decisionCheckbacks: [String]
    public let itemsAdded: [String]
    public var summary: String?
    public let generatedAt: Date

    public init(weekStart: Date, people: [String], promisesMade: [String], promisesKept: [String], promisesOverdue: [String],
                decisionCheckbacks: [String] = [], itemsAdded: [String], summary: String? = nil, generatedAt: Date = Date()) {
        self.weekStart = weekStart; self.people = people; self.promisesMade = promisesMade; self.promisesKept = promisesKept
        self.promisesOverdue = promisesOverdue; self.decisionCheckbacks = decisionCheckbacks; self.itemsAdded = itemsAdded
        self.summary = summary; self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey { case weekStart, people, promisesMade, promisesKept, promisesOverdue, decisionCheckbacks, itemsAdded, summary, generatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekStart = try c.decode(Date.self, forKey: .weekStart)
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        promisesMade = try c.decodeIfPresent([String].self, forKey: .promisesMade) ?? []
        promisesKept = try c.decodeIfPresent([String].self, forKey: .promisesKept) ?? []
        promisesOverdue = try c.decodeIfPresent([String].self, forKey: .promisesOverdue) ?? []
        decisionCheckbacks = try c.decodeIfPresent([String].self, forKey: .decisionCheckbacks) ?? []
        itemsAdded = try c.decodeIfPresent([String].self, forKey: .itemsAdded) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? weekStart
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(weekStart, forKey: .weekStart); try c.encode(people, forKey: .people)
        try c.encode(promisesMade, forKey: .promisesMade); try c.encode(promisesKept, forKey: .promisesKept)
        try c.encode(promisesOverdue, forKey: .promisesOverdue); try c.encode(decisionCheckbacks, forKey: .decisionCheckbacks)
        try c.encode(itemsAdded, forKey: .itemsAdded); try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(generatedAt, forKey: .generatedAt)
    }

    public var journalText: String {
        var sections: [(String, [String])] = [("People met", people), ("Promises made", promisesMade),
            ("Promises kept", promisesKept), ("Promises overdue", promisesOverdue),
            ("Decision check-backs", decisionCheckbacks), ("Items added", itemsAdded)]
        var output = summary.map { "## Summary\n\n\($0)\n" } ?? ""
        for (title, lines) in sections where !lines.isEmpty { output += "\n## \(title)\n\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return output.isEmpty ? "No recorded activity." : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
public final class ReflectionStore: ObservableObject {
    public static let shared = ReflectionStore()
    @Published public private(set) var reflection: WeeklyReflection?
    @Published public var error: String?
    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL = InferoidPaths.support.appendingPathComponent("Reflections", isDirectory: true)) {
        self.root = root; encoder = JSONEncoder(); decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601; decoder.dateDecodingStrategy = .iso8601
    }

    public func load(week: Date) {
        reflection = try? decoder.decode(WeeklyReflection.self, from: Data(contentsOf: url(for: week)))
    }

    @discardableResult
    func generate(week: Date, meetings: [Meeting], projects: [Project], model: String?, summarize: Bool, writeJournal: Bool = true) async -> WeeklyReflection? {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: week)?.start ?? week
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? week
        let inWeek = meetings.filter {
            guard let meetingDate = date($0.date) else { return false }
            return meetingDate >= start && meetingDate < end
        }
        var people = Set<String>()
        for meeting in inWeek {
            if let data = try? Data(contentsOf: meeting.folder.appendingPathComponent("meta.json")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let names = object["attendees"] as? [String] { names.forEach { people.insert($0) } }
        }
        var made: [String] = []; var kept: [String] = []; var overdue: [String] = []
        if let store = try? BrainStore(), let promises = try? store.commitmentsForChat(limit: 500) {
            for item in promises {
                guard let started = date(item.meetingDate), started >= start, started < end else { continue }
                let label = item.fact.value.isEmpty ? item.fact.predicate : item.fact.value
                let due = BrainDueDate.resolve(item.fact.due, relativeTo: item.meetingDate)
                if item.fact.done { kept.append(label) } else if let due, due < Date() { overdue.append(label) } else { made.append(label) }
            }
        }
        let decisionCheckbacks = JournalStore.dueDecisionCheckbacks(asOf: Date())
            .map { "\($0.decisionTitle.isEmpty ? "Untitled decision" : $0.decisionTitle) · due \($0.checkBackDate?.formatted(date: .abbreviated, time: .omitted) ?? "now")" }
        let registered = Brain.sourceDocuments(meetings: meetings, projects: projects)
        let addedItems = registered.filter { source in
            guard source.includeInBrain else { return false }
            guard let sourceDate = date(source.sourceDate) else { return false }
            return sourceDate >= start && sourceDate < end
        }.map { "\($0.sourceKind.label): \($0.sourceTitle)" }
        var result = WeeklyReflection(weekStart: start, people: people.sorted(), promisesMade: made, promisesKept: kept,
                                      promisesOverdue: overdue, decisionCheckbacks: decisionCheckbacks, itemsAdded: addedItems.sorted())
        if summarize, let model, !model.isEmpty {
            let prompt = "Week of \(start.formatted(date: .long, time: .omitted))\nPeople: \(result.people.joined(separator: ", "))\nMade: \(made.joined(separator: "; "))\nKept: \(kept.joined(separator: "; "))\nOverdue: \(overdue.joined(separator: "; "))\nDecision check-backs: \(decisionCheckbacks.joined(separator: "; "))\nAdded: \(result.itemsAdded.joined(separator: "; "))"
            result.summary = try? await Summarizer.complete(system: "Write a short, factual weekly reflection from these local records. Do not invent details.", user: prompt, model: model, maxTokens: 300)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try encoder.encode(result).write(to: url(for: start), options: .atomic)
            if writeJournal { try JournalStore.upsertWeeklyReflection(result) }
            reflection = result
        }
        catch let caught { self.error = caught.localizedDescription }
        return result
    }

    private func url(for week: Date) -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        return root.appendingPathComponent(formatter.string(from: week) + ".json")
    }
    private func date(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) ?? ISO8601DateFormatter().date(from: value + "T00:00:00Z") }
}

struct WeeklyReflectionView: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject private var projects = ProjectStore.shared
    @ObservedObject private var store = ReflectionStore.shared
    @State private var week = Date()
    @State private var summarize = false
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("Weekly reflection").font(.largeTitle.bold()); Spacer(); Label("Stored only on this Mac", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                HStack { DatePicker("Week", selection: $week, displayedComponents: .date); Toggle("Add a short summary", isOn: $summarize); Button(working ? "Reflecting…" : "Generate") { generate() }.disabled(working) }
                if let reflection = store.reflection { reflectionView(reflection) } else { Text("Choose a week and generate a reflection.").foregroundStyle(.secondary) }
                if let error = store.error { Text(error).foregroundStyle(.red) }
            }
            .padding(28).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Weekly reflection")
        .onAppear { store.load(week: week) }
    }

    @ViewBuilder private func reflectionView(_ r: WeeklyReflection) -> some View {
        if let summary = r.summary, !summary.isEmpty { card("Summary", [summary]) }
        card("People met", r.people)
        card("Promises made", r.promisesMade)
        card("Promises kept", r.promisesKept)
        card("Promises overdue", r.promisesOverdue)
        card("Decision check-backs", r.decisionCheckbacks)
        card("Items added", r.itemsAdded)
    }

    private func card(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.headline); if lines.isEmpty { Text("None").foregroundStyle(.secondary) }; ForEach(lines, id: \.self) { Text("•  \($0)") } }
            .padding(15).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func generate() {
        working = true; store.error = nil
        Task { @MainActor in
            _ = await store.generate(week: week, meetings: rec.meetings, projects: projects.projects, model: rec.model, summarize: summarize)
            working = false
        }
    }
}
