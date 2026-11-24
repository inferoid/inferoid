import Darwin
import SwiftUI

private enum BrainUI {
    static let page = Color(red: 0.94, green: 0.945, blue: 0.96)
    static let panel = Color(red: 0.985, green: 0.985, blue: 0.99)
    static let ink = Color(red: 0.08, green: 0.09, blue: 0.10)
    static let muted = Color(red: 0.30, green: 0.33, blue: 0.38)
    static let blue = Color(red: 0.12, green: 0.30, blue: 0.72)
    static let teal = Color(red: 0.04, green: 0.42, blue: 0.39)
    static let orange = Color(red: 0.62, green: 0.25, blue: 0.06)
    static let purple = Color(red: 0.32, green: 0.22, blue: 0.58)
    static let green = Color(red: 0.19, green: 0.38, blue: 0.16)

    static func color(for world: BrainWorld) -> Color {
        switch world {
        case .client: return teal
        case .opposing: return orange
        case .court: return purple
        case .team: return blue
        case .personal: return green
        case .other, .unknown: return muted
        }
    }

    static func label(for world: BrainWorld) -> String {
        switch world {
        case .client: return "Client"
        case .opposing: return "Opposing"
        case .court: return "Court"
        case .team: return "Team"
        case .personal: return "Personal"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        let letters = words.prefix(2).compactMap { word -> String? in
            guard let first = word.first else { return nil }
            return String(first)
        }
        return letters.joined().uppercased()
    }

    static func date(_ value: String?) -> String {
        guard let value else { return "No date" }
        return String(value.prefix(10))
    }
}

private struct BrainCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(BrainUI.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.18)))
    }
}

private struct StoredLocally: View {
    var body: some View {
        Label("Stored only on this Mac", systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(BrainUI.green)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Capsule().fill(Color.green.opacity(0.10)))
            .accessibilityLabel("Stored only on this Mac")
    }
}

private struct BrainSourceChip: View {
    @EnvironmentObject private var rec: Recorder
    let episode: BrainEpisode?
    let open: (String) -> Void

    var body: some View {
        Button {
            guard let episode, rec.meetings.contains(where: { $0.folder.path == episode.meetingFolder }) else { return }
            open(episode.meetingFolder)
        } label: {
            Label(BrainUI.date(episode?.startedAt), systemImage: "arrow.up.right.square")
                .font(.caption)
                .foregroundStyle(BrainUI.blue)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .disabled(episode == nil || !rec.meetings.contains(where: { $0.folder.path == episode?.meetingFolder }))
        .help("Open the source meeting")
    }
}

private struct BrainBuildCard: View {
    @EnvironmentObject private var rec: Recorder
    @State private var task: Task<Void, Never>?

    var body: some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Build your Brain from past meetings", systemImage: "sparkles")
                    .font(.headline)
                Text("Inferoid will read saved transcripts one at a time and keep the resulting graph on this Mac.")
                    .foregroundStyle(BrainUI.muted)
                if let progress = rec.brainBackfillProgress {
                    ProgressView(value: progress)
                    HStack {
                        Text(rec.brainBackfillStatus).font(.caption).foregroundStyle(BrainUI.muted)
                        Spacer()
                        Button("Cancel") { task?.cancel() }
                    }
                } else {
                    HStack {
                        Button("Build from past meetings") {
                            task = Task { await rec.backfillBrain() }
                        }
                        .buttonStyle(.borderedProminent)
                        StoredLocally()
                    }
                    if !rec.brainBackfillStatus.isEmpty {
                        Text(rec.brainBackfillStatus).font(.caption).foregroundStyle(BrainUI.muted)
                    }
                }
            }
        }
        .onDisappear { task?.cancel() }
    }
}

struct BrainOrbitView: View {
    @EnvironmentObject private var rec: Recorder
    @Binding var pane: Pane?
    @State private var people: [BrainOrbitPerson] = []
    @State private var matters: [BrainMatterStory] = []
    @State private var world: BrainWorld?
    @State private var upcoming: MeetingCalendarEvent?
    @State private var error: String?

    private var visiblePeople: [BrainOrbitPerson] {
        people.filter { world == nil || $0.entity.world == world }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Orbit").font(.largeTitle.bold())
                        Text("People and matters arranged by the attention they need.").foregroundStyle(BrainUI.muted)
                    }
                    Spacer()
                    StoredLocally()
                }
                worldFilters
                if people.isEmpty && matters.isEmpty {
                    BrainBuildCard()
                    BrainEmptyState(title: "Your Brain is empty", message: "Record a few meetings, or build it from the meetings already saved on this Mac.")
                } else {
                    orbit
                    needsYou
                    if !matters.isEmpty { matterPills }
                    if let upcoming, let person = upcoming.attendeeNames.first,
                       upcoming.startDate.timeIntervalSince(Date()) <= 15 * 60 {
                        BrainBriefingCard(personName: person, event: upcoming, pane: $pane)
                    }
                    BrainBuildCard()
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(BrainUI.page)
        .navigationTitle("Brain · Orbit")
        .task { load() }
        .task {
            upcoming = await MeetingCalendar.upcomingEvent(within: 30)
        }
    }

    private var worldFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterButton(nil, title: "All worlds")
                ForEach(BrainWorld.allCases.filter { $0 != .unknown }, id: \.self) { item in
                    filterButton(item, title: BrainUI.label(for: item))
                }
            }
        }
    }

    private func filterButton(_ item: BrainWorld?, title: String) -> some View {
        Button { world = item } label: {
            Text(title).font(.caption.weight(.semibold))
                .foregroundStyle(world == item ? Color.white : BrainUI.color(for: item ?? .unknown))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(world == item ? BrainUI.ink : BrainUI.color(for: item ?? .unknown).opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private var orbit: some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your orbit").font(.headline)
                GeometryReader { proxy in
                    let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                            .frame(width: min(proxy.size.width, proxy.size.height) * 0.52)
                        Circle().fill(BrainUI.ink).frame(width: 64, height: 64)
                            .overlay(Text("You").font(.headline).foregroundStyle(.white))
                        ForEach(Array(visiblePeople.prefix(40).enumerated()), id: \.offset) { _, person in
                            let point = orbitPoint(person: person, size: proxy.size)
                            Button {
                                if upcoming?.attendeeNames.contains(where: { $0.caseInsensitiveCompare(person.entity.name) == .orderedSame }) == true {
                                    pane = .brainBriefing(person.entity.name)
                                } else {
                                    pane = .brainPerson(person.entity.name)
                                }
                            } label: {
                                VStack(spacing: 3) {
                                    ZStack {
                                        if person.hasOpenPromise || person.hasChanged {
                                            Circle().stroke(BrainUI.color(for: person.entity.world).opacity(0.35), lineWidth: 5)
                                                .frame(width: 54, height: 54)
                                        }
                                        Text(BrainUI.initials(person.entity.name)).font(.caption.weight(.bold)).foregroundStyle(.white)
                                            .frame(width: 44, height: 44).background(Circle().fill(BrainUI.color(for: person.entity.world)))
                                            .opacity(isStale(person) ? 0.48 : 1)
                                    }
                                    Text(person.entity.name).font(.caption2.weight(.semibold)).lineLimit(1)
                                }
                                .frame(width: 104)
                            }
                            .buttonStyle(.plain)
                            .position(point)
                            .accessibilityLabel("Open dossier for \(person.entity.name)")
                        }
                        ForEach(matters.prefix(5), id: \.matter.id) { matter in
                            Button { pane = .brainMatter(matter.matter.id) } label: {
                                Text(matter.matter.name).font(.caption.weight(.semibold))
                                    .foregroundStyle(BrainUI.ink).padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(BrainUI.panel))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(BrainUI.ink, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .position(x: center.x, y: center.y - 88 - CGFloat(matters.firstIndex(where: { $0.matter.id == matter.matter.id }) ?? 0) * 28)
                        }
                    }
                }
                .frame(minHeight: 420)
                HStack {
                    Text("Closer means more recent and more frequent. Faded means no contact in 60+ days.")
                    Spacer()
                    Text("Glow = an open promise or changed position")
                }
                .font(.caption).foregroundStyle(BrainUI.muted)
            }
        }
    }

    private func orbitPoint(person: BrainOrbitPerson, size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let scale = min(size.width, size.height)
        let maxCount = max(1, visiblePeople.map(\.meetingCount).max() ?? 1)
        let frequency = min(1, log(Double(person.meetingCount + 1)) / log(Double(maxCount + 1)))
        let recency: Double
        if let value = person.lastMet, let date = ISO8601DateFormatter().date(from: value) {
            recency = max(0, 1 - Date().timeIntervalSince(date) / (180 * 24 * 60 * 60))
        } else { recency = 0 }
        let relevance = 0.65 * frequency + 0.35 * recency
        let radius = scale * (0.20 + CGFloat(1 - relevance) * 0.22)
        let worlds: [BrainWorld] = [.client, .opposing, .court, .team, .personal, .other]
        let sector = worlds.firstIndex(of: person.entity.world) ?? worlds.count - 1
        let members = visiblePeople.filter { $0.entity.world == person.entity.world }
        let position = members.firstIndex(where: { $0.entity.id == person.entity.id }) ?? 0
        let sectorWidth = (Double.pi * 2) / Double(worlds.count)
        let angle = -Double.pi / 2 + Double(sector) * sectorWidth + sectorWidth * (0.2 + 0.6 * Double(position + 1) / Double(members.count + 1))
        let r = Double(radius); return CGPoint(x: Double(center.x) + Foundation.cos(angle) * r, y: Double(center.y) + Foundation.sin(angle) * r)
    }

    private var needsYou: some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("NEEDS YOU").font(.caption.weight(.bold)).tracking(1).foregroundStyle(BrainUI.muted)
                let needs = people.filter { $0.hasOpenPromise || $0.hasChanged }.prefix(4)
                if needs.isEmpty {
                    Text("Nothing urgent surfaced from recent meetings.").foregroundStyle(BrainUI.muted)
                } else {
                    ForEach(Array(needs), id: \.entity.id) { person in
                        Button { pane = .brainPerson(person.entity.name) } label: {
                            HStack {
                                Text(person.entity.name).fontWeight(.semibold).foregroundStyle(BrainUI.color(for: person.entity.world))
                                Text(person.hasChanged ? "changed position" : "has an open promise").foregroundStyle(BrainUI.ink)
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(BrainUI.muted)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                Button("See everything that changed") { pane = .brainChanges }.buttonStyle(.link)
            }
        }
    }

    private var matterPills: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MATTERS").font(.caption.weight(.bold)).tracking(1).foregroundStyle(BrainUI.muted)
            FlowLayout(items: matters) { matter in
                Button { pane = .brainMatter(matter.matter.id) } label: {
                    Text(matter.matter.name).font(.caption.weight(.semibold)).foregroundStyle(BrainUI.ink)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(BrainUI.panel))
                        .overlay(Capsule().stroke(BrainUI.ink.opacity(0.5)))
                }.buttonStyle(.plain)
            }
        }
    }

    private func isStale(_ person: BrainOrbitPerson) -> Bool {
        guard let value = person.lastMet, let date = ISO8601DateFormatter().date(from: value) else { return false }
        return Date().timeIntervalSince(date) > 60 * 24 * 60 * 60
    }

    private func load() {
        do {
            let store = try BrainStore()
            people = try store.orbitPeople(limit: 40)
            matters = try store.matterStories()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct FlowLayout<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(items: [Item], @ViewBuilder content: @escaping (Item) -> Content) { self.items = items; self.content = content }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

private struct BrainEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(BrainUI.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }
}

struct BrainPersonView: View {
    @EnvironmentObject private var rec: Recorder
    @Binding var pane: Pane?
    let name: String
    @State private var dossier: BrainPersonDossier?
    @State private var showKnowledge = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let dossier {
                VStack(alignment: .leading, spacing: 16) {
                    header(dossier)
                    BrainCard {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("WHAT THEY CARE ABOUT").font(.caption.weight(.bold)).tracking(1).foregroundStyle(BrainUI.muted)
                            Text(dossier.entity.summary.isEmpty ? "No summary has been extracted yet." : dossier.entity.summary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        PromiseColumn(title: "You owe \(dossier.entity.name)", facts: dossier.openCommitmentsByPerson, dossier: dossier, pane: $pane)
                        PromiseColumn(title: "\(dossier.entity.name) owes you", facts: dossier.openCommitmentsToPerson, dossier: dossier, pane: $pane)
                    }
                    positions(dossier)
                    meetings(dossier)
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
                .sheet(isPresented: $showKnowledge) {
                    BrainKnowledgeSheet(dossier: dossier, isPresented: $showKnowledge)
                }
            } else {
                BrainEmptyState(title: "No dossier found", message: "The Brain does not know \(name) yet.").padding(28)
            }
        }
        .background(BrainUI.page)
        .navigationTitle("Brain · \(name)")
        .task { load() }
        .overlay(alignment: .bottom) { if let error { Text(error).font(.caption).foregroundStyle(.red).padding() } }
    }

    private func header(_ dossier: BrainPersonDossier) -> some View {
        HStack(spacing: 14) {
            Text(BrainUI.initials(dossier.entity.name)).font(.title.bold()).foregroundStyle(.white)
                .frame(width: 64, height: 64).background(Circle().fill(BrainUI.color(for: dossier.entity.world)))
            VStack(alignment: .leading, spacing: 4) {
                Text(dossier.entity.name).font(.largeTitle.bold())
                Text(dossier.entity.summary.isEmpty ? "Person in your meetings" : dossier.entity.summary)
                    .foregroundStyle(BrainUI.muted).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Text(BrainUI.label(for: dossier.entity.world)).font(.caption.weight(.semibold)).foregroundStyle(BrainUI.color(for: dossier.entity.world))
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(BrainUI.color(for: dossier.entity.world).opacity(0.12)))
                Text("Last met \(BrainUI.date(dossier.meetings.first?.startedAt))").font(.caption).foregroundStyle(BrainUI.muted)
                Button("What the Brain knows") { showKnowledge = true }.buttonStyle(.bordered)
            }
        }
    }

    private func positions(_ dossier: BrainPersonDossier) -> some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Positions over time").font(.headline)
                if dossier.positionHistory.isEmpty {
                    Text("No positions have been extracted yet.").foregroundStyle(BrainUI.muted)
                } else {
                    ForEach(dossier.positionHistory, id: \.id) { fact in
                        HStack(alignment: .top, spacing: 8) {
                            Text(fact.predicate).frame(width: 130, alignment: .leading).foregroundStyle(BrainUI.muted)
                            Text(fact.value.isEmpty ? fact.quote : fact.value)
                                .fontWeight(fact.invalidatedAt == nil ? .semibold : .regular)
                                .strikethrough(fact.invalidatedAt != nil)
                            Text(BrainUI.date(fact.validFrom)).font(.caption).foregroundStyle(BrainUI.muted)
                            Spacer()
                            BrainSourceChip(episode: dossier.meetings.first(where: { $0.id == fact.episodeID })) { path in pane = .meeting(path) }
                        }
                    }
                }
            }
        }
    }

    private func meetings(_ dossier: BrainPersonDossier) -> some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Every meeting with \(dossier.entity.name)").font(.headline)
                ForEach(dossier.meetings, id: \.id) { meeting in
                    Button { pane = .meeting(meeting.meetingFolder) } label: {
                        HStack {
                            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(BrainUI.color(for: dossier.entity.world))
                            Text(BrainUI.date(meeting.startedAt))
                            Spacer(); Text("Open meeting").font(.caption).foregroundStyle(BrainUI.blue)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func load() {
        do { dossier = try BrainStore().personDossier(name) } catch { self.error = error.localizedDescription }
    }
}

private struct PromiseColumn: View {
    let title: String
    let facts: [BrainFact]
    let dossier: BrainPersonDossier
    @Binding var pane: Pane?

    var body: some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                if facts.isEmpty { Text("Nothing open.").foregroundStyle(BrainUI.muted) }
                ForEach(facts, id: \.id) { fact in
                    HStack(alignment: .top) {
                        Text(fact.value.isEmpty ? fact.predicate : fact.value)
                        Spacer()
                        BrainSourceChip(episode: dossier.meetings.first(where: { $0.id == fact.episodeID })) { path in pane = .meeting(path) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct BrainKnowledgeSheet: View {
    let dossier: BrainPersonDossier
    @Binding var isPresented: Bool
    @State private var facts: [BrainFact] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("What the Brain knows about \(dossier.entity.name)").font(.title2.bold()); Spacer(); Button("Done") { isPresented = false } }
            Text("These are extracted from local meeting transcripts. Forget removes them from the Brain without deleting the meeting.")
                .foregroundStyle(BrainUI.muted)
            List(facts, id: \.id) { fact in
                VStack(alignment: .leading, spacing: 3) {
                    Text(fact.value.isEmpty ? fact.predicate : fact.value)
                    Text(fact.kind.rawValue.capitalized).font(.caption).foregroundStyle(BrainUI.muted)
                }
            }
            Button("Forget what the Brain knows about this person", role: .destructive) {
                if let store = try? BrainStore() {
                    for fact in facts { try? store.applyCorrection(factID: fact.id, action: "forget") }
                }
                isPresented = false
            }
            .buttonStyle(.bordered)
            StoredLocally()
        }
        .padding(24)
        .frame(minWidth: 470, minHeight: 400)
        .task { facts = (try? BrainStore().factsForPerson(dossier.entity.name)) ?? [] }
    }
}

struct BrainPromisesView: View {
    @EnvironmentObject private var rec: Recorder
    @Binding var pane: Pane?
    @State private var items: [BrainPromiseItem] = []
    @State private var snoozed: [Int64: Date] = [:]
    @State private var error: String?

    private var shown: [BrainPromiseItem] {
        items.filter { item in
            guard let until = snoozed[item.fact.id] else { return true }
            return until <= Date()
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text("Promises").font(.largeTitle.bold()); Text("From your meetings. Nobody typed these in.").foregroundStyle(BrainUI.muted) }; Spacer(); StoredLocally() }
                if shown.isEmpty { BrainEmptyState(title: "No open promises", message: "When a meeting contains a commitment, it will appear here with its source.") }
                else {
                    HStack(alignment: .top, spacing: 16) {
                        promiseColumn("I owe", items: shown.filter(\.iOwe))
                        promiseColumn("Owed to me", items: shown.filter { !$0.iOwe })
                    }
                }
            }
            .padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(BrainUI.page)
        .navigationTitle("Brain · Promises")
        .task { load() }
        .overlay(alignment: .bottom) { if let error { Text(error).font(.caption).foregroundStyle(.red).padding() } }
    }

    private func promiseColumn(_ title: String, items: [BrainPromiseItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline); Spacer(); Text("\(items.count) open").font(.caption).foregroundStyle(BrainUI.muted) }
            ForEach(items, id: \.fact.id) { item in promiseCard(item) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.55)))
    }

    private func promiseCard(_ item: BrainPromiseItem) -> some View {
        let late = item.dueDate.map { $0 < Date() } ?? false
        return BrainCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(item.fact.value.isEmpty ? item.fact.predicate : item.fact.value).font(.headline)
                    Spacer()
                    Text(dueText(item)).font(.caption.weight(.semibold)).foregroundStyle(late ? Color.white : BrainUI.muted)
                        .padding(.horizontal, 7).padding(.vertical, 4).background(Capsule().fill(late ? BrainUI.orange : Color.clear))
                }
                Text("\(item.iOwe ? "To" : "From") \(item.otherPartyName ?? "another meeting participant") · promised \(BrainUI.date(item.fact.validFrom))")
                    .font(.caption).foregroundStyle(BrainUI.muted)
                HStack {
                    Button("Done") { correct(item, action: "done") }.buttonStyle(.bordered)
                    Button(item.iOwe ? "Draft follow-up" : "Draft a nudge") { draft(item) }.buttonStyle(.borderedProminent)
                    Button("Snooze") { snooze(item) }.buttonStyle(.bordered)
                    Spacer()
                    BrainSourceChip(episode: item.episode) { path in pane = .meeting(path) }
                }
            }
        }
    }

    private func dueText(_ item: BrainPromiseItem) -> String {
        guard let date = item.dueDate else { return "No date" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func correct(_ item: BrainPromiseItem, action: String) {
        try? BrainStore().applyCorrection(factID: item.fact.id, action: action)
        load()
    }

    private func snooze(_ item: BrainPromiseItem) {
        let date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86400)
        snoozed[item.fact.id] = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "brain.snooze.\(item.fact.id)")
    }

    private func draft(_ item: BrainPromiseItem) {
        let subject = item.fact.value.isEmpty ? item.fact.predicate : item.fact.value
        let draft = "Draft a concise follow-up to \(item.otherPartyName ?? "the other person") about \(subject)."
        let id = ChatStore.shared.newThread()
        pane = .chatDraft(id, draft)
    }

    private func load() {
        do {
            items = try BrainStore().openPromiseItems()
            for item in items {
                let key = "brain.snooze.\(item.fact.id)"
                if let value = UserDefaults.standard.object(forKey: key) as? Double { snoozed[item.fact.id] = Date(timeIntervalSince1970: value) }
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct BrainBriefingCard: View {
    @EnvironmentObject private var rec: Recorder
    let personName: String
    let event: MeetingCalendarEvent
    @Binding var pane: Pane?
    @State private var dossier: BrainPersonDossier?

    var body: some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(BrainUI.orange).frame(width: 10, height: 10)
                    Text("In \(max(1, Int(event.startDate.timeIntervalSince(Date()) / 60))) minutes").font(.caption.weight(.bold)).foregroundStyle(BrainUI.orange)
                    Spacer(); StoredLocally()
                }
                HStack(spacing: 12) {
                    Text(BrainUI.initials(personName)).font(.headline).foregroundStyle(.white).frame(width: 44, height: 44).background(Circle().fill(BrainUI.orange))
                    VStack(alignment: .leading) { Text("Call with \(personName)").font(.title3.bold()); Text(event.title).font(.caption).foregroundStyle(BrainUI.muted) }
                }
                briefingLines
                HStack {
                    Button("Start recording when it begins") { Task { await rec.start(); pane = .live } }.buttonStyle(.borderedProminent)
                    Button("Open briefing") { pane = .brainBriefing(personName) }.buttonStyle(.bordered)
                }
            }
        }
        .task { dossier = try? BrainStore().personDossier(personName) }
    }

    private var briefingLines: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Last time: \(dossier?.meetings.first.map { BrainUI.date($0.startedAt) } ?? "No previous meeting")")
            Text("You promised: \(dossier?.openCommitmentsByPerson.first.map { $0.value.isEmpty ? $0.predicate : $0.value } ?? "Nothing open extracted")")
            Text("They promised: \(dossier?.openCommitmentsToPerson.first.map { $0.value.isEmpty ? $0.predicate : $0.value } ?? "Nothing open extracted")")
            Text("Moved since: \(dossier?.positionHistory.first(where: { $0.invalidatedAt == nil }).map { $0.value } ?? "No changed position found")")
            Text("Unanswered: Review the source meeting for questions not yet resolved.").foregroundStyle(BrainUI.muted)
        }
        .font(.callout)
    }
}

struct BrainBriefingView: View {
    @EnvironmentObject private var rec: Recorder
    @Binding var pane: Pane?
    let personName: String
    @State private var event: MeetingCalendarEvent?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Before you meet").font(.largeTitle.bold()); Spacer(); StoredLocally() }
                if let event { BrainBriefingCard(personName: personName, event: event, pane: $pane) }
                else { BrainEmptyState(title: "No upcoming event found", message: "Calendar access is local. When a known attendee has an event starting within 30 minutes, the briefing will appear here.") }
            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(BrainUI.page).navigationTitle("Brain · Briefing")
        .task { event = await MeetingCalendar.upcomingEvent(within: 30) }
    }
}

struct BrainChangesView: View {
    @Binding var pane: Pane?
    @State private var changes: [BrainFact] = []
    @State private var search = ""
    @State private var conflict = BrainConflictSearch(entities: [], facts: [])
    @State private var error: String?

    private var displayChanges: [BrainFact] {
        changes.filter { fact in
            guard fact.invalidatedAt != nil, let replacement = fact.supersededBy else { return true }
            return !changes.contains(where: { $0.id == replacement })
        }
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                changesColumn
                conflictColumn
            }
            .padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(BrainUI.page).navigationTitle("Brain · What changed")
        .task { load() }
        .overlay(alignment: .bottom) { if let error { Text(error).font(.caption).foregroundStyle(.red).padding() } }
    }

    private var changesColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("This week").font(.largeTitle.bold()); Spacer(); Text("\(displayChanges.count) changes").font(.caption).foregroundStyle(BrainUI.muted) }
            if displayChanges.isEmpty { BrainEmptyState(title: "Nothing changed this week", message: "Position changes and new unverified facts will appear here.") }
            ForEach(displayChanges, id: \.id) { fact in
                let old = changes.first(where: { $0.supersededBy == fact.id })
                BrainChangeCard(fact: fact, old: old, pane: $pane)
            }
            Text("Every correction fixes the Brain on this Mac immediately.").font(.caption).foregroundStyle(BrainUI.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conflictColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conflict check").font(.largeTitle.bold())
            TextField("New client or party", text: $search)
                .textFieldStyle(.roundedBorder)
                .onChange(of: search) { _, value in
                    guard let store = try? BrainStore() else { return }
                    conflict = (try? store.conflictSearch(value)) ?? BrainConflictSearch(entities: [], facts: [])
                }
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!conflict.entities.isEmpty || !conflict.facts.isEmpty) {
                BrainCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Possible connection").font(.headline).foregroundStyle(BrainUI.orange)
                        ForEach(conflict.entities, id: \.id) { entity in
                            HStack { Circle().fill(BrainUI.color(for: entity.world)).frame(width: 9, height: 9); Text(entity.name); Spacer(); Text(BrainUI.label(for: entity.world)).font(.caption).foregroundStyle(BrainUI.muted) }
                        }
                        ForEach(conflict.facts.prefix(8), id: \.id) { fact in
                            Text("\(fact.predicate): \(fact.value)").font(.caption)
                        }
                    }
                }
            } else if !search.isEmpty {
                Text("No Brain connection found.").foregroundStyle(BrainUI.muted)
            }
            Spacer(minLength: 20)
            StoredLocally()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() {
        do { changes = try BrainStore().changes(since: Date().addingTimeInterval(-7 * 24 * 60 * 60)) } catch { self.error = error.localizedDescription }
    }
}

private struct BrainChangeCard: View {
    let fact: BrainFact
    let old: BrainFact?
    @Binding var pane: Pane?
    @State private var corrected = false

    var body: some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(fact.predicate.uppercased()).font(.caption.weight(.bold)).foregroundStyle(BrainUI.color(for: .team))
                    if fact.status == "unverified" { Text("UNVERIFIED").font(.caption2.weight(.bold)).foregroundStyle(BrainUI.muted).padding(3).overlay(RoundedRectangle(cornerRadius: 4).stroke(BrainUI.muted)) }
                    Spacer(); Text(BrainUI.date(fact.validFrom)).font(.caption).foregroundStyle(BrainUI.muted)
                }
                if let old {
                    Text(old.value.isEmpty ? old.quote : old.value).strikethrough().foregroundStyle(BrainUI.muted)
                    Text(fact.value.isEmpty ? fact.quote : fact.value).fontWeight(.bold)
                } else { Text(fact.value.isEmpty ? fact.quote : fact.value).fontWeight(.bold) }
                HStack {
                    BrainSourceChip(episode: try? BrainStore().episode(id: fact.episodeID)) { path in pane = .meeting(path) }
                    Spacer()
                    if !corrected {
                        Button(fact.status == "unverified" ? "Confirm" : "Correct") { apply("confirm") }.buttonStyle(.bordered)
                        Button("Wrong") { apply("wrong") }.buttonStyle(.bordered)
                    } else { Text("Updated").font(.caption).foregroundStyle(BrainUI.green) }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(fact.status == "unverified" ? BrainUI.muted.opacity(0.55) : Color.clear, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private func apply(_ action: String) {
        try? BrainStore().applyCorrection(factID: fact.id, action: action)
        corrected = true
    }
}

struct BrainMatterView: View {
    @Binding var pane: Pane?
    let matterID: Int64
    @State private var story: BrainMatterStory?

    var body: some View {
        ScrollView {
            if let story {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) { VStack(alignment: .leading) { Text(story.matter.name).font(.largeTitle.bold()); Text("Matter story · \(story.episodes.count) meetings").foregroundStyle(BrainUI.muted) }; Spacer(); StoredLocally() }
                    if story.facts.isEmpty { BrainEmptyState(title: "No story yet", message: "Positions and commitments extracted from meetings will form this chronology.") }
                    else {
                        ForEach(story.parties + [BrainEntity(id: -1, kind: .person, name: "You", world: .unknown, summary: "", createdAt: "", updatedAt: "", forgotten: false)], id: \.id) { party in
                            lane(party, story: story)
                        }
                    }
                    HStack(spacing: 14) { Text("Solid = current position"); Text("Light = earlier position"); Text("Dashed = open commitment") }.font(.caption).foregroundStyle(BrainUI.muted)
                }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
            } else { BrainEmptyState(title: "Matter not found", message: "This matter has not been extracted yet.").padding(28) }
        }
        .background(BrainUI.page).navigationTitle("Brain · Matter story")
        .task { story = (try? BrainStore().matterStories())?.first(where: { $0.matter.id == matterID }) }
    }

    private func lane(_ party: BrainEntity, story: BrainMatterStory) -> some View {
        let facts = story.facts.filter { fact in
            if party.id == -1 { return fact.kind == .commitment && fact.ownerID == nil }
            return fact.subjectID == party.id || fact.objectID == party.id || fact.ownerID == party.id || fact.counterpartyID == party.id
        }
        return BrainCard {
            VStack(alignment: .leading, spacing: 9) {
                Text(party.name).font(.headline).foregroundStyle(BrainUI.color(for: party.world))
                if facts.isEmpty { Text("No extracted events.").font(.caption).foregroundStyle(BrainUI.muted) }
                ForEach(facts.sorted { $0.validFrom < $1.validFrom }, id: \.id) { fact in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(fact.invalidatedAt == nil ? BrainUI.color(for: party.world) : BrainUI.color(for: party.world).opacity(0.25)).frame(width: 9, height: 9).padding(.top, 5)
                        Text(fact.value.isEmpty ? fact.predicate : fact.value).fontWeight(fact.invalidatedAt == nil ? .semibold : .regular).strikethrough(fact.invalidatedAt != nil)
                        Spacer(); Text(BrainUI.date(fact.validFrom)).font(.caption).foregroundStyle(BrainUI.muted)
                        BrainSourceChip(episode: story.episodes.first(where: { $0.id == fact.episodeID })) { path in pane = .meeting(path) }
                    }
                }
            }
        }
    }
}
