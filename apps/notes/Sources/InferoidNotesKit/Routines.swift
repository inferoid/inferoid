import AppKit
import Foundation
import SwiftUI
import UserNotifications

public enum RoutineSchedule: Codable, Hashable, Sendable {
    case everyDay
    case weekdays
    case weekly(weekday: Int)
    case monthly(day: Int)
    case once

    var label: String {
        switch self {
        case .everyDay: return "Every day"
        case .weekdays: return "Weekdays"
        case .weekly(let weekday): return "Weekly on \(Calendar.current.weekdaySymbols[max(0, min(6, weekday - 1))])"
        case .monthly(let day): return "Monthly on the \(day.ordinal)"
        case .once: return "Once"
        }
    }
}

public enum RoutineScope: Codable, Hashable, Sendable {
    case wholeBrain
    case project(UUID)
    case libraryOnly

    var label: String {
        switch self {
        case .wholeBrain: return "Whole Brain"
        case .project: return "One project"
        case .libraryOnly: return "Library only"
        }
    }
}

public enum RoutineDelivery: String, Codable, CaseIterable, Hashable, Sendable {
    case notificationAndJournal, notificationOnly, journalOnly

    var label: String {
        switch self {
        case .notificationAndJournal: return "Notification + Journal"
        case .notificationOnly: return "Notification only"
        case .journalOnly: return "Journal only"
        }
    }
}

public struct RoutineRun: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let success: Bool
    public let result: String

    public init(id: UUID = UUID(), date: Date = Date(), success: Bool, result: String) {
        self.id = id; self.date = date; self.success = success; self.result = result
    }
}

public struct Routine: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var prompt: String
    public var schedule: RoutineSchedule
    public var hour: Int
    public var minute: Int
    public var onceDate: Date?
    public var scope: RoutineScope
    public var delivery: RoutineDelivery
    public var enabled: Bool
    public var lastRun: Date?
    public var nextRun: Date?
    public var history: [RoutineRun]

    public init(id: UUID = UUID(), name: String, prompt: String, schedule: RoutineSchedule,
                hour: Int, minute: Int, onceDate: Date? = nil, scope: RoutineScope = .wholeBrain,
                delivery: RoutineDelivery = .notificationAndJournal, enabled: Bool = true,
                lastRun: Date? = nil, nextRun: Date? = nil, history: [RoutineRun] = []) {
        self.id = id; self.name = name; self.prompt = prompt; self.schedule = schedule
        self.hour = max(0, min(23, hour)); self.minute = max(0, min(59, minute)); self.onceDate = onceDate
        self.scope = scope; self.delivery = delivery; self.enabled = enabled; self.lastRun = lastRun
        self.nextRun = nextRun ?? RoutineScheduleCalculator.nextRun(after: Date(), schedule: schedule, hour: hour, minute: minute, onceDate: onceDate)
        self.history = Array(history.suffix(20))
    }

    var timeLabel: String {
        var components = DateComponents(); components.hour = hour; components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// Calendar-only schedule math. It has no persistence or app dependencies, so DST and catch-up behavior can be tested directly.
public enum RoutineScheduleCalculator {
    public static func nextRun(after date: Date, schedule: RoutineSchedule, hour: Int, minute: Int,
                               onceDate: Date? = nil, calendar: Calendar = .current) -> Date? {
        let hour = max(0, min(23, hour)); let minute = max(0, min(59, minute))
        switch schedule {
        case .once:
            guard let onceDate else { return nil }
            return time(on: onceDate, hour: hour, minute: minute, calendar: calendar).flatMap { $0 > date ? $0 : nil }
        case .everyDay:
            return firstMatch(after: date, days: 0..<3, hour: hour, minute: minute, calendar: calendar) { _ in true }
        case .weekdays:
            return firstMatch(after: date, days: 0..<10, hour: hour, minute: minute, calendar: calendar) {
                let weekday = calendar.component(.weekday, from: $0)
                return weekday != 1 && weekday != 7
            }
        case .weekly(let weekday):
            return firstMatch(after: date, days: 0..<15, hour: hour, minute: minute, calendar: calendar) {
                calendar.component(.weekday, from: $0) == max(1, min(7, weekday))
            }
        case .monthly(let day):
            return firstMonthMatch(after: date, day: day, hour: hour, minute: minute, calendar: calendar)
        }
    }

    public static func isDue(_ nextRun: Date?, at date: Date = Date()) -> Bool {
        guard let nextRun else { return false }
        return nextRun <= date
    }

    /// Returns the persisted due occurrence once. Callers must advance `nextRun` before starting async work.
    public static func catchUpOccurrence(nextRun: Date?, at date: Date = Date()) -> Date? {
        isDue(nextRun, at: date) ? nextRun : nil
    }

    private static func firstMatch(after date: Date, days: Range<Int>, hour: Int, minute: Int,
                                   calendar: Calendar, matches: (Date) -> Bool) -> Date? {
        let start = calendar.startOfDay(for: date)
        for offset in days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start), matches(day),
                  let candidate = time(on: day, hour: hour, minute: minute, calendar: calendar), candidate > date else { continue }
            return candidate
        }
        return nil
    }

    private static func firstMonthMatch(after date: Date, day: Int, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        let start = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: date)) ?? date
        for offset in 0..<14 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: start),
                  let range = calendar.range(of: .day, in: .month, for: month) else { continue }
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = min(max(1, day), range.count); components.hour = hour; components.minute = minute
            if let candidate = calendar.date(from: components), candidate > date { return candidate }
        }
        return nil
    }

    private static func time(on date: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour; components.minute = minute; components.second = 0
        return calendar.date(from: components)
    }
}

private extension Int {
    var ordinal: String {
        let suffix: String
        switch self % 100 {
        case 11...13: suffix = "th"
        default:
            switch self % 10 { case 1: suffix = "st"; case 2: suffix = "nd"; case 3: suffix = "rd"; default: suffix = "th" }
        }
        return "\(self)\(suffix)"
    }
}

@MainActor
public final class RoutineStore: ObservableObject {
    public static let shared = RoutineStore()
    @Published public private(set) var routines: [Routine] = []
    @Published public private(set) var runningRoutineID: UUID?
    @Published public var error: String?

    private let root: URL
    private let file: URL
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL = InferoidPaths.support.appendingPathComponent("Routines", isDirectory: true)) {
        self.root = root; self.file = root.appendingPathComponent("routines.json")
        encoder = JSONEncoder(); decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601; decoder.dateDecodingStrategy = .iso8601
        load()
    }

    public func load() {
        if let data = try? Data(contentsOf: file), let decoded = try? decoder.decode([Routine].self, from: data) {
            routines = decoded
            // "Promise check" is no longer a built-in routine (11-24): remove the copy older versions created.
            if !UserDefaults.standard.bool(forKey: "routines.promiseCheckRemoved") {
                routines.removeAll { $0.name == "Promise check" }
                UserDefaults.standard.set(true, forKey: "routines.promiseCheckRemoved")
                persist()
                for entry in JournalStore.load() where entry.kind == .routine && entry.decisionTitle == "Promise check" {
                    try? JournalStore.delete(entry)
                }
            }
        } else {
            routines = Self.defaults()
            persist()
        }
    }

    public func save(_ routine: Routine) {
        var value = routine
        value.nextRun = RoutineScheduleCalculator.nextRun(after: Date(), schedule: value.schedule, hour: value.hour,
                                                          minute: value.minute, onceDate: value.onceDate)
        if let index = routines.firstIndex(where: { $0.id == value.id }) { routines[index] = value } else { routines.append(value) }
        persist()
    }

    public func delete(_ routine: Routine) {
        routines.removeAll { $0.id == routine.id }; persist()
    }

    public func start() {
        guard timer == nil else { checkDue(); return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in RoutineStore.shared.checkDue() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                           object: nil, queue: .main) { _ in
            Task { @MainActor in RoutineStore.shared.checkDue() }
        }
        checkDue()
    }

    public func checkDue(at now: Date = Date()) {
        sendDecisionCheckbackNudgeIfNeeded(at: now)
        guard runningRoutineID == nil, let routine = routines.first(where: { $0.enabled && RoutineScheduleCalculator.isDue($0.nextRun, at: now) }) else { return }
        runningRoutineID = routine.id
        Task { @MainActor in await run(routineID: routine.id, scheduled: true, now: now) }
    }

    public func runNow(_ routine: Routine) async {
        guard runningRoutineID == nil else { return }
        await run(routineID: routine.id, scheduled: false, now: Date())
    }

    private func run(routineID: UUID, scheduled: Bool, now: Date) async {
        guard runningRoutineID == nil || runningRoutineID == routineID else { return }
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else {
            if runningRoutineID == routineID { runningRoutineID = nil }
            return
        }
        var routine = routines[index]
        guard routine.enabled || !scheduled else { return }
        runningRoutineID = routine.id
        if scheduled || RoutineScheduleCalculator.isDue(routine.nextRun, at: now) {
            routine.nextRun = RoutineScheduleCalculator.nextRun(after: now, schedule: routine.schedule, hour: routine.hour,
                                                               minute: routine.minute, onceDate: routine.onceDate)
            routines[index] = routine; persist()
        }
        let recorder = Recorder.shared
        let projects = ProjectStore.shared.projects
        do {
            let isWeeklyReflection = routine.name.caseInsensitiveCompare("Weekly reflection") == .orderedSame
                || (routine.schedule == .weekly(weekday: 1) && routine.prompt.localizedCaseInsensitiveContains("weekly reflection"))
            let result: String
            if isWeeklyReflection {
                result = (await ReflectionStore.shared.generate(week: now, meetings: recorder.meetings, projects: projects,
                                                                model: recorder.model, summarize: true,
                                                                writeJournal: routine.delivery != .notificationOnly))?.journalText ?? "Weekly reflection could not be generated."
            } else {
                result = try await RoutineEngine.run(routine: routine, meetings: recorder.meetings, projects: projects, model: recorder.model)
            }
            if !isWeeklyReflection { try deliver(result: result, routine: routine) }
            record(RoutineRun(date: Date(), success: true, result: result))
        } catch {
            let message = error.localizedDescription
            self.error = message
            record(RoutineRun(date: Date(), success: false, result: message))
        }
        runningRoutineID = nil
        checkDue()
    }

    private func record(_ run: RoutineRun) {
        guard let index = routines.firstIndex(where: { $0.id == runningRoutineID }) else { return }
        routines[index].lastRun = run.date; routines[index].history = Array((routines[index].history + [run]).suffix(20)); persist()
        if routines[index].delivery != .journalOnly { notify(title: routines[index].name, body: run.result) }
    }

    private func deliver(result: String, routine: Routine) throws {
        if routine.delivery != .notificationOnly {
            let entry = JournalEntry(kind: .routine, text: result, decisionTitle: routine.name)
            try JournalStore.save(entry)
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let askedKey = "routineNotificationPermissionAsked"
        let alreadyAsked = UserDefaults.standard.bool(forKey: askedKey)
        UserDefaults.standard.set(true, forKey: askedKey)
        Task {
            if !alreadyAsked { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
            let content = UNMutableNotificationContent(); content.title = title; content.body = String(body.prefix(500))
            let request = UNNotificationRequest(identifier: "routine-\(UUID().uuidString)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    private func sendDecisionCheckbackNudgeIfNeeded(at date: Date) {
        guard !JournalStore.dueDecisionCheckbacks(asOf: date).isEmpty else { return }
        let key = "decisionCheckbackNudgeDate"
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = formatter.string(from: date)
        guard UserDefaults.standard.string(forKey: key) != day else { return }
        UserDefaults.standard.set(day, forKey: key)
        notify(title: "Decision check-back", body: "You have decision check-backs due in your Journal.")
    }

    private func persist() {
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try encoder.encode(routines).write(to: file, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }

    private static func defaults() -> [Routine] {
        [Routine(name: "Morning brief", prompt: "Give me a concise morning brief from my Brain: what matters today, open promises, and useful context.", schedule: .weekdays, hour: 8, minute: 0),
         Routine(name: "Weekly reflection", prompt: "Write a factual weekly reflection from my Brain, including what changed and any decision check-backs due.", schedule: .weekly(weekday: 1), hour: 18, minute: 0),
         Routine(name: "Keep in touch", prompt: "Identify level 1–2 people I have not contacted in 30 or 60 days and suggest a thoughtful next step.", schedule: .weekly(weekday: 2), hour: 9, minute: 0)]
    }
}

private enum RoutineEngine {
    /// People in Orbit with closeness and last contact, newest first as Orbit lists them.
    static func peopleSection(now: Date = Date()) -> String {
        guard let people = try? BrainStore().orbitPeople(limit: 40, now: now), !people.isEmpty else { return "" }
        let iso = ISO8601DateFormatter()
        let lines = people.map { person -> String in
            let level = person.closenessLevel ?? person.suggestedClosenessLevel
            var line = "- \(person.entity.name) (\(person.entity.world.rawValue), closeness \(level) of 5"
            if let last = person.lastMet.flatMap({ iso.date(from: $0) }) {
                line += ", last met \(max(0, Int(now.timeIntervalSince(last) / 86_400))) days ago"
            } else {
                line += ", no meetings recorded"
            }
            if person.hasOpenPromise { line += ", open promise" }
            return line + ")"
        }
        return "People in Orbit (closeness 1 = very close, 5 = far):\n" + lines.joined(separator: "\n") + "\n"
    }

    static func run(routine: Routine, meetings: [Meeting], projects: [Project], model: String) async throws -> String {
        let all = SourceRegistry.documents(meetings: meetings, projects: projects)
        let sources: [BrainSourceDocument]
        switch routine.scope {
        case .wholeBrain: sources = all
        case .project(let id): sources = projects.first(where: { $0.id == id }).map { ProjectStore.documents(for: $0, includedOnly: false) } ?? []
        case .libraryOnly: sources = all.filter { $0.sourceKind == .library }
        }
        let hits = Brain.searchSources(routine.prompt, in: sources, limit: 8)
        let context = Brain.context(for: routine.prompt, sourceHits: hits, sources: sources, budget: 16_000)
        // Routines like "Keep in touch" are about people: give them Orbit (closeness and last contact), not just documents.
        let people: String
        if case .wholeBrain = routine.scope { people = peopleSection() } else { people = "" }
        let records = [people, context].filter { !$0.isEmpty }.joined(separator: "\n")
        let user = records.isEmpty ? routine.prompt : "Local records:\n\n\(records)\nTask: \(routine.prompt)"
        return try await Summarizer.complete(system: "You are a private local routine assistant. Use only the supplied local records, be concise and factual, and say when the records do not answer the task. Nothing leaves this Mac.", user: user, model: model, maxTokens: 600)
    }
}

struct RoutinesView: View {
    @ObservedObject private var store = RoutineStore.shared
    @State private var editing: Routine?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Routines").font(.largeTitle.bold()); Spacer(); Button("New routine") { editing = Routine(name: "New routine", prompt: "", schedule: .everyDay, hour: 9, minute: 0) }.buttonStyle(.borderedProminent) }
                Text("Small local prompts that run on a schedule and deliver to your Journal, notifications, or both.").foregroundStyle(.secondary)
                if store.routines.isEmpty { Text("No routines yet.").foregroundStyle(.secondary) }
                ForEach(store.routines) { routine in RoutineRow(routine: routine, isRunning: store.runningRoutineID == routine.id,
                                                                  run: { Task { await store.runNow(routine) } }, edit: { editing = routine },
                                                                  delete: { store.delete(routine) }) }
                if let error = store.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Label("Stored only on this Mac", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Routines")
        .sheet(item: $editing) { routine in
            RoutineEditorView(initial: routine) { value in store.save(value); editing = nil } onCancel: { editing = nil }
        }
        .onAppear { store.start() }
    }
}

private struct RoutineRow: View {
    let routine: Routine; let isRunning: Bool; let run: () -> Void; let edit: () -> Void; let delete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: routine.enabled ? "clock.fill" : "pause.circle").foregroundStyle(routine.enabled ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(routine.name).font(.headline)
                    Text("\(routine.schedule.label) · \(routine.timeLabel) · \(routine.delivery.label)").font(.caption).foregroundStyle(.secondary)
                    if let next = routine.nextRun { Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                    if let last = routine.lastRun { Text("Last run: \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(); Button(isRunning ? "Running…" : "Run now", action: run).disabled(isRunning || !routine.enabled); Button("Edit", action: edit); Button("Delete", role: .destructive, action: delete)
            }
            if !routine.history.isEmpty {
                DisclosureGroup("Run history (\(routine.history.count))") { ForEach(routine.history.reversed()) { run in Label(run.result, systemImage: run.success ? "checkmark.circle" : "xmark.circle").font(.caption).foregroundStyle(run.success ? Color.secondary : Color.red).lineLimit(2) } }
                    .font(.caption)
            }
        }.padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct RoutineEditorView: View {
    @State private var draft: Routine
    @State private var scheduleChoice: String
    @State private var weekday: Int
    @State private var monthDay: Int
    @State private var time: Date
    let onSave: (Routine) -> Void; let onCancel: () -> Void

    init(initial: Routine, onSave: @escaping (Routine) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: initial); self.onSave = onSave; self.onCancel = onCancel
        _scheduleChoice = State(initialValue: Self.choice(initial.schedule)); _weekday = State(initialValue: Self.weekday(initial.schedule)); _monthDay = State(initialValue: Self.monthDay(initial.schedule))
        var c = DateComponents(); c.hour = initial.hour; c.minute = initial.minute; _time = State(initialValue: Calendar.current.date(from: c) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Routine").font(.title.bold()); Form {
                TextField("Name", text: $draft.name); TextField("What should it do?", text: $draft.prompt, axis: .vertical).lineLimit(3...6)
                Picker("Schedule", selection: $scheduleChoice) { Text("Every day").tag("everyDay"); Text("Weekdays").tag("weekdays"); Text("Weekly").tag("weekly"); Text("Monthly").tag("monthly"); Text("Once").tag("once") }
                if scheduleChoice == "weekly" { Picker("Day", selection: $weekday) { ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) } } }
                if scheduleChoice == "monthly" { Stepper("Day \(monthDay)", value: $monthDay, in: 1...31) }
                if scheduleChoice == "once" { DatePicker("Date", selection: Binding(get: { draft.onceDate ?? Date() }, set: { draft.onceDate = $0 }), displayedComponents: .date) }
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                Picker("Scope", selection: Binding(get: { scopeKey(draft.scope) }, set: { draft.scope = scope(for: $0) })) { Text("Whole Brain").tag("brain"); Text("Library only").tag("library"); ForEach(ProjectStore.shared.projects) { Text($0.name).tag("project:\($0.id.uuidString)") } }
                Picker("Delivery", selection: $draft.delivery) { ForEach(RoutineDelivery.allCases, id: \.self) { Text($0.label).tag($0) } }
                Toggle("Enabled", isOn: $draft.enabled)
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Cancel", action: onCancel); Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(22).frame(width: 560, height: 510)
    }

    private func save() {
        let c = Calendar.current
        draft.schedule = schedule(); draft.hour = c.component(.hour, from: time); draft.minute = c.component(.minute, from: time)
        if scheduleChoice == "once", draft.onceDate == nil { draft.onceDate = Date() }
        onSave(draft)
    }
    private func schedule() -> RoutineSchedule { switch scheduleChoice { case "weekdays": return .weekdays; case "weekly": return .weekly(weekday: weekday); case "monthly": return .monthly(day: monthDay); case "once": return .once; default: return .everyDay } }
    private func scopeKey(_ value: RoutineScope) -> String { switch value { case .wholeBrain: return "brain"; case .libraryOnly: return "library"; case .project(let id): return "project:\(id.uuidString)" } }
    private func scope(for key: String) -> RoutineScope { if key == "library" { return .libraryOnly }; if let id = UUID(uuidString: String(key.dropFirst(8))) { return .project(id) }; return .wholeBrain }
    private static func choice(_ schedule: RoutineSchedule) -> String { switch schedule { case .everyDay: return "everyDay"; case .weekdays: return "weekdays"; case .weekly: return "weekly"; case .monthly: return "monthly"; case .once: return "once" } }
    private static func weekday(_ schedule: RoutineSchedule) -> Int { if case .weekly(let day) = schedule { return day }; return 1 }
    private static func monthDay(_ schedule: RoutineSchedule) -> Int { if case .monthly(let day) = schedule { return day }; return 1 }
}
