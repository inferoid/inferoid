import AppKit
import Darwin
import SwiftUI

private enum BrainUI {
    // System colours so every screen reads correctly in light and dark mode.
    static let page = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let ink = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let blue = adaptive(light: (0.12, 0.30, 0.72), dark: (0.45, 0.62, 1.0))
    static let teal = adaptive(light: (0.04, 0.42, 0.39), dark: (0.30, 0.78, 0.72))
    static let orange = adaptive(light: (0.62, 0.25, 0.06), dark: (0.98, 0.60, 0.36))
    static let purple = adaptive(light: (0.32, 0.22, 0.58), dark: (0.70, 0.60, 0.98))
    static let green = adaptive(light: (0.19, 0.38, 0.16), dark: (0.50, 0.80, 0.45))

    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static func color(for world: BrainWorld) -> Color {
        switch world {
        case .friend: return teal
        case .family: return green
        case .business: return blue
        case .mentor: return purple
        case .mentee: return orange
        case .other, .unknown: return muted
        }
    }

    static func label(for world: BrainWorld) -> String {
        switch world {
        case .friend: return "Friend"
        case .family: return "Family"
        case .business: return "Business"
        case .mentor: return "Mentor"
        case .mentee: return "Mentee"
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
    @ObservedObject private var projectStore = ProjectStore.shared
    let episode: BrainEpisode?
    let open: (String, BrainSourceKind) -> Void

    var body: some View {
        let source = episode.flatMap { SourceRegistry.episodeSource($0.meetingFolder, meetings: rec.meetings, projects: projectStore.projects) }
        Button {
            if let source { open(source.sourceID, source.sourceKind) }
        } label: {
            Group {
                if let source {
                    Label("\(source.sourceKind.label) · \(BrainUI.date(source.sourceDate))", systemImage: source.sourceKind.systemImage)
                } else if episode != nil {
                    Label("Deleted source", systemImage: "trash")
                } else {
                    Label("Source", systemImage: "arrow.up.right.square")
                }
            }
                .font(.caption)
                .foregroundStyle(BrainUI.blue)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .disabled(source == nil)
        .help("Open the source")
    }
}

private struct BrainBuildCard: View {
    @EnvironmentObject private var rec: Recorder
    @State private var task: Task<Void, Never>?

    var body: some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Build your Brain from saved records", systemImage: "sparkles")
                    .font(.headline)
                Text("Inferoid will read saved records one at a time and keep the resulting graph on this Mac.")
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
    @State private var nudges: [BrainNudge] = []
    @State private var dismissedNudges: Set<String> = []
    @State private var error: String?
    @State private var addingPerson = false
    @State private var mode: OrbitMode = .orbit
    @State private var searchText = ""
    @State private var sort: OrbitListSort = .name
    @State private var removingPerson: String?

    private var visiblePeople: [BrainOrbitPerson] {
        people.filter { world == nil || $0.entity.world == world }
    }

    var body: some View {
        VStack(spacing: 0) {
            orbitHeader
            HStack(spacing: 0) {
                Group {
                    if mode == .list { orbitList } else { orbit }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                BrainNudgesAside(nudges: shownNudges, pane: $pane, dismiss: dismissNudge)
            }
        }
        .background(BrainUI.page)
        .navigationTitle("Brain · Orbit")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search people")
        .sheet(isPresented: $addingPerson, onDismiss: { load() }) { AddPersonSheet(world: world ?? .friend) }
        .task { load() }
        .task {
            upcoming = await MeetingCalendar.upcomingEvent(within: 30)
        }
        .onChange(of: mode) { _, value in if value == .promises { pane = .brainPromises; mode = .orbit } }
        .confirmationDialog("Remove \(removingPerson ?? "") from Orbit?", isPresented: Binding(get: { removingPerson != nil }, set: { if !$0 { removingPerson = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let name = removingPerson { removePerson(name) }; removingPerson = nil }
            Button("Cancel", role: .cancel) { removingPerson = nil }
        } message: { Text("The Brain forgets what it learned about them. If a future meeting mentions them, they come back as a new person.") }
    }

    private var orbitHeader: some View {
        HStack(spacing: 10) {
            Text("Orbit").font(.title2.weight(.semibold))
            Picker("View", selection: $mode) {
                Text("Orbit").tag(OrbitMode.orbit)
                Text("List").tag(OrbitMode.list)
                Text("Promises").tag(OrbitMode.promises)
            }
            .pickerStyle(.segmented).frame(width: 210)
            Spacer(minLength: 8)
            worldFilters
            Button { addingPerson = true } label: { Label("Add person", systemImage: "person.badge.plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var worldFilters: some View {
        HStack(spacing: 6) {
            filterButton(nil, title: "All worlds")
            ForEach([BrainWorld.friend, .family, .business, .mentor, .mentee], id: \.self) { item in
                filterButton(item, title: BrainUI.label(for: item))
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
        BrainOrbitCanvas(people: Array(visiblePeople.prefix(40)), matters: matters, upcoming: upcoming, pane: $pane, onRemove: { removingPerson = $0.entity.name })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var orbitList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("People").font(.headline); Spacer(); Picker("Sort", selection: $sort) { ForEach(OrbitListSort.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.menu) }
            LazyVStack(spacing: 0) {
                ForEach(sortedListPeople, id: \.entity.id) { person in
                    Button { pane = .brainPerson(person.entity.name) } label: { OrbitListRow(person: person) }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Remove \(person.entity.name)…", role: .destructive) { removingPerson = person.entity.name } }
                    Divider()
                }
            }.padding(.horizontal, 12).background(RoundedRectangle(cornerRadius: 12).fill(BrainUI.panel))
        }
    }

    private var sortedListPeople: [BrainOrbitPerson] {
        let filtered = visiblePeople.filter { searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.entity.name.localizedCaseInsensitiveContains(searchText) }
        switch sort {
        case .name: return filtered.sorted { $0.entity.name.localizedCaseInsensitiveCompare($1.entity.name) == .orderedAscending }
        case .closeness: return filtered.sorted {
            let left = $0.closenessLevel ?? $0.suggestedClosenessLevel, right = $1.closenessLevel ?? $1.suggestedClosenessLevel
            return left == right ? $0.entity.name.localizedCaseInsensitiveCompare($1.entity.name) == .orderedAscending : left < right
        }
        case .lastMet: return filtered.sorted {
            let left = lastDate($0) ?? .distantPast, right = lastDate($1) ?? .distantPast
            return left == right ? $0.entity.name.localizedCaseInsensitiveCompare($1.entity.name) == .orderedAscending : left > right
        }
        }
    }

    private func lastDate(_ person: BrainOrbitPerson) -> Date? { person.lastMet.flatMap { ISO8601DateFormatter().date(from: $0) } }

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
            Text("TOPICS").font(.caption.weight(.bold)).tracking(1).foregroundStyle(BrainUI.muted)
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

    private func removePerson(_ name: String) {
        do { try BrainStore().forgetPerson(name); load(); rec.reloadMeetings() } catch { self.error = error.localizedDescription }
    }

    private func load() {
        do {
            let store = try BrainStore()
            people = try store.orbitPeople(limit: 40)
            matters = try store.matterStories()
            nudges = try store.nudges()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private var shownNudges: [BrainNudge] {
        nudges.filter { !dismissedNudges.contains($0.id) && !UserDefaults.standard.bool(forKey: "brain.nudge.dismissed.\($0.id)") }.prefix(5).map { $0 }
    }

    private func dismissNudge(_ nudge: BrainNudge) {
        dismissedNudges.insert(nudge.id)
        UserDefaults.standard.set(true, forKey: "brain.nudge.dismissed.\(nudge.id)")
    }
}

private enum OrbitListSort: CaseIterable, Hashable {
    case name, closeness, lastMet
    var title: String { switch self { case .name: return "Name"; case .closeness: return "Closeness"; case .lastMet: return "Last met" } }
}

private struct OrbitListRow: View {
    let person: BrainOrbitPerson
    var body: some View {
        HStack(spacing: 12) {
            Text(BrainUI.initials(person.entity.name)).font(.caption.bold()).foregroundStyle(.white).frame(width: 34, height: 34).background(Circle().fill(BrainUI.color(for: person.entity.world)))
            VStack(alignment: .leading, spacing: 3) { Text(person.entity.name).font(.headline); Text(BrainUI.label(for: person.entity.world)).font(.caption).foregroundStyle(BrainUI.muted) }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) { Text("Closeness \(person.closenessLevel ?? person.suggestedClosenessLevel)").font(.caption); Text(person.lastMet.map(BrainUI.date) ?? "Never met").font(.caption).foregroundStyle(BrainUI.muted) }
            Image(systemName: "chevron.right").foregroundStyle(BrainUI.muted)
        }.padding(.vertical, 10)
    }
}

private enum OrbitMode: Hashable { case orbit, list, promises }

private struct BrainOrbitCanvas: View {
    let people: [BrainOrbitPerson]
    let matters: [BrainMatterStory]
    let upcoming: MeetingCalendarEvent?
    @Binding var pane: Pane?
    var onRemove: (BrainOrbitPerson) -> Void = { _ in }
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var zoomStart: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2 + pan.width, y: proxy.size.height / 2 + pan.height)
            let radii = BrainOrbitLayout.radii(people: people, size: proxy.size, zoom: zoom)
            let layout = BrainOrbitLayout.points(people: people, size: proxy.size, zoom: zoom, offset: pan)
            ZStack {
            ZStack {
                ForEach(Array(radii.enumerated()), id: \.offset) { index, radius in
                    Circle().stroke(BrainUI.muted.opacity(index == 0 ? 0.32 : 0.22), style: StrokeStyle(lineWidth: 1, dash: index == 0 ? [] : [4, 5]))
                        .frame(width: radius * 2, height: radius * 2).position(center)
                }
                        ZStack {
                            Circle().fill(BrainUI.ink)
                            Text("You").font(.headline).foregroundStyle(BrainUI.page)
                        }
                        .frame(width: 88, height: 88).position(center)
                        ForEach(layout, id: \.personID) { point in
                            if let person = people.first(where: { $0.entity.id == point.personID }) {
                                Button {
                                    if upcoming?.attendeeNames.contains(where: { $0.caseInsensitiveCompare(person.entity.name) == .orderedSame }) == true {
                                        pane = .brainBriefing(person.entity.name)
                                    } else { pane = .brainPerson(person.entity.name) }
                                } label: {
                                    VStack(spacing: 3) {
                                        let tint = BrainUI.color(for: person.entity.world)
                                        ZStack {
                                            if person.hasOpenPromise || person.hasChanged {
                                                Circle().stroke(Color.orange.opacity(0.55), lineWidth: 4).frame(width: 52, height: 52)
                                            }
                                            if person.closenessLevel == nil {
                                                Text(BrainUI.initials(person.entity.name)).font(.caption.weight(.bold)).foregroundStyle(tint)
                                                    .frame(width: 40, height: 40)
                                                    .background(Circle().fill(BrainUI.page))
                                                    .overlay(Circle().stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                                            } else {
                                                Text(BrainUI.initials(person.entity.name)).font(.caption.weight(.bold)).foregroundStyle(.white)
                                                    .frame(width: 44, height: 44).background(Circle().fill(tint))
                                            }
                                        }
                                        Text(person.closenessLevel == nil ? "\(person.entity.name) · suggested \(point.level)" : person.entity.name)
                                            .font(.caption2.weight(person.closenessLevel == nil ? .regular : .semibold))
                                            .foregroundStyle(person.closenessLevel == nil ? BrainUI.muted : BrainUI.ink)
                                            .lineLimit(1).fixedSize()
                                            .padding(.horizontal, 4).background(Capsule().fill(BrainUI.page.opacity(0.85)))
                                    }
                                    .frame(width: 140)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button("Remove \(person.entity.name)…", role: .destructive) { onRemove(person) } }
                                .position(point.position)
                                .accessibilityLabel("Open dossier for \(person.entity.name)")
                            }
                        }
                        ForEach(Array(matters.prefix(5).enumerated()), id: \.offset) { index, matter in
                            Button { pane = .brainMatter(matter.matter.id) } label: {
                                Text(matter.matter.name).font(.caption.weight(.semibold)).foregroundStyle(BrainUI.ink)
                                    .padding(.horizontal, 9).padding(.vertical, 5).background(RoundedRectangle(cornerRadius: 8).fill(BrainUI.panel))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(BrainUI.ink, lineWidth: 1))
                            }
                            .buttonStyle(.plain).position(x: center.x, y: center.y - 88 - CGFloat(index) * 28)
                        }
                    }
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in pan = CGSize(width: dragStart.width + value.translation.width, height: dragStart.height + value.translation.height) }
                    .onEnded { _ in dragStart = pan })
                .simultaneousGesture(MagnificationGesture().onChanged { value in zoom = min(1.8, max(0.65, zoomStart * value)) }
                    .onEnded { _ in zoomStart = zoom })
                .onTapGesture(count: 2) { pan = .zero; dragStart = .zero; zoom = 1; zoomStart = 1 }
                .background(OrbitScrollCapture { delta in
                    zoom = min(1.8, max(0.65, zoom * (1 + delta / 500)))
                    zoomStart = zoom
                })

                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        HStack(spacing: 6) {
                            Button("+") { zoom = min(1.8, zoom + 0.1); zoomStart = zoom }.accessibilityLabel("Zoom in")
                            Button("−") { zoom = max(0.65, zoom - 0.1); zoomStart = zoom }.accessibilityLabel("Zoom out")
                            Button("Center on You") { pan = .zero; dragStart = .zero }.font(.caption)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Text("Drag to move around · pinch or scroll to zoom\nRings 1 (very close) → 5 (far) · glow = open promise · dashed = suggested level")
                            .font(.caption).foregroundStyle(BrainUI.muted).multilineTextAlignment(.trailing)
                    }
                    .padding(16)
                }
            }
            .background(BrainUI.page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OrbitScrollCapture: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> OrbitWheelView {
        let view = OrbitWheelView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: OrbitWheelView, context: Context) {
        nsView.onScroll = onScroll
    }
}

private final class OrbitWheelView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
}

private struct BrainNudgesCard: View {
    let nudges: [BrainNudge]
    @Binding var pane: Pane?
    let dismiss: (BrainNudge) -> Void

    var body: some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("NUDGES").font(.caption.weight(.bold)).tracking(1).foregroundStyle(BrainUI.muted)
                ForEach(nudges) { nudge in
                    HStack(spacing: 8) {
                        Button { if let person = nudge.personName { pane = .brainPerson(person) } } label: {
                            VStack(alignment: .leading, spacing: 2) { Text(nudge.title).fontWeight(.semibold); Text(nudge.detail).font(.caption).foregroundStyle(BrainUI.muted) }
                        }.buttonStyle(.plain)
                        Spacer()
                        Button("Dismiss") { dismiss(nudge) }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }
}

private struct BrainNudgesAside: View {
    let nudges: [BrainNudge]
    @Binding var pane: Pane?
    let dismiss: (BrainNudge) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("For you today").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(nudges) { nudge in
                        BrainCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("NUDGE").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(BrainUI.orange)
                                Button {
                                    if let person = nudge.personName { pane = .brainPerson(person) }
                                } label: {
                                    Text(nudge.title).font(.subheadline.weight(.semibold)).foregroundStyle(BrainUI.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Text(nudge.detail).font(.caption).foregroundStyle(BrainUI.muted).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    if nudge.personName != nil { Button("Chat about") { if let name = nudge.personName { pane = .brainPerson(name) } }.buttonStyle(.link) }
                                    Spacer()
                                    Button("Dismiss") { dismiss(nudge) }.buttonStyle(.borderless).font(.caption)
                                }
                            }
                        }
                    }
                    if nudges.isEmpty { Text("Nothing needs your attention today.").foregroundStyle(BrainUI.muted) }
                }
            }
            Spacer()
        }
        .padding(20).frame(width: 300, alignment: .topLeading)
        .background(BrainUI.panel.opacity(0.45))
        .overlay(alignment: .leading) { Divider() }
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
    @State private var showEdit = false
    @State private var error: String?
    @State private var trips: [Trip] = []
    @State private var confirmRemove = false
    @State private var chatDraft = ""
    @State private var noImport = false
    @ObservedObject private var chatStore = ChatStore.shared

    var body: some View {
        ScrollView {
            if let dossier {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        header(dossier)
                        closenessPicker(dossier)
                        ProjectComposer(projectName: name, placeholder: "Chat about \(name)", showsAttach: false,
                                        draft: $chatDraft, importing: $noImport, send: { startChat($0) })
                        personChats
                    }
                    .frame(width: 400, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Spacer()
                            Button("What the Brain knows") { showKnowledge = true }.buttonStyle(.bordered)
                        }
                        personalDetails(dossier)
                        tripLinks
                        BrainCard {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("WHAT THEY CARE ABOUT").font(.caption.weight(.bold)).tracking(1).foregroundStyle(BrainUI.muted)
                                Text(dossier.entity.summary.isEmpty ? "Nothing yet. It fills in from your meetings and notes." : dossier.entity.summary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack(alignment: .top, spacing: 16) {
                            PromiseColumn(title: "You owe \(dossier.entity.name)", facts: dossier.openCommitmentsByPerson, dossier: dossier, pane: $pane)
                            PromiseColumn(title: "\(dossier.entity.name) owes you", facts: dossier.openCommitmentsToPerson, dossier: dossier, pane: $pane)
                        }
                        if !dossier.positionHistory.isEmpty { positions(dossier) }
                        meetings(dossier)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
                .sheet(isPresented: $showKnowledge) {
                    BrainKnowledgeSheet(dossier: dossier, isPresented: $showKnowledge)
                }
                .sheet(isPresented: $showEdit, onDismiss: { load() }) {
                    BrainPersonEditSheet(dossier: dossier, isPresented: $showEdit)
                }
            } else {
                BrainEmptyState(title: "No dossier found", message: "The Brain does not know \(name) yet.").padding(28)
            }
        }
        .background(BrainUI.page)
        .navigationTitle("Brain · \(name)")
        .toolbar { if dossier != nil { Button("Remove from Orbit", role: .destructive) { confirmRemove = true } } }
        .confirmationDialog("Remove \(name) from Orbit?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                do { try BrainStore().forgetPerson(name); rec.reloadMeetings(); pane = .brainOrbit } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The Brain forgets what it learned about them. If a future meeting mentions them, they come back as a new person.") }
        .task { load() }
        .overlay(alignment: .bottom) { if let error { Text(error).font(.caption).foregroundStyle(.red).padding() } }
    }

    private func header(_ dossier: BrainPersonDossier) -> some View {
        HStack(spacing: 14) {
            Text(BrainUI.initials(dossier.entity.name)).font(.title2.bold()).foregroundStyle(.white)
                .frame(width: 56, height: 56).background(Circle().fill(BrainUI.color(for: dossier.entity.world)))
            VStack(alignment: .leading, spacing: 4) {
                Text(dossier.entity.name).font(.title.bold()).lineLimit(1)
                HStack(spacing: 6) {
                    Text(BrainUI.label(for: dossier.entity.world)).font(.caption.weight(.semibold)).foregroundStyle(BrainUI.color(for: dossier.entity.world))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(BrainUI.color(for: dossier.entity.world).opacity(0.14)))
                    Text(dossier.meetings.isEmpty ? "No meetings yet" : "Last met \(BrainUI.date(dossier.meetings.first?.startedAt)) · \(dossier.meetings.count) meeting\(dossier.meetings.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(BrainUI.muted)
                }
            }
        }
    }

    private func closenessPicker(_ dossier: BrainPersonDossier) -> some View {
        let suggested = BrainCloseness.suggestedLevel(meetingCount: dossier.meetings.count,
                                                       lastMet: dossier.meetings.first.flatMap { ISO8601DateFormatter().date(from: $0.startedAt) })
        let current = dossier.entity.closenessLevel
        let labels = ["Very close", "Close", "Regular", "Some", "Far"]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("How close").font(.caption.weight(.semibold))
                Spacer()
                if current == nil { Text("suggested \(suggested)").font(.caption).foregroundStyle(BrainUI.muted) }
            }
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { level in
                    let selected = (current ?? 0) == level
                    Button { setCloseness(selected ? nil : level) } label: {
                        VStack(spacing: 1) {
                            Text("\(level)").font(.callout.weight(.semibold))
                            Text(labels[level - 1]).font(.system(size: 9))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(selected ? Color.white : BrainUI.ink)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : BrainUI.panel))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(current == nil && level == suggested ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18),
                                                                               style: StrokeStyle(lineWidth: 1, dash: current == nil && level == suggested ? [3, 2] : [])))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var personChats: some View {
        let threads = PersonChats.ids(for: name).compactMap { chatStore.thread($0) }.filter { !$0.messages.isEmpty }.sorted { $0.updated > $1.updated }
        VStack(alignment: .leading, spacing: 6) {
            Text("CHATS").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(BrainUI.muted)
            if threads.isEmpty {
                Text("Ask anything about \(name): what to get them, what you last talked about, what they care about.")
                    .font(.callout).foregroundStyle(BrainUI.muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(threads) { thread in
                Button { pane = .personChat(name, thread.id) } label: {
                    ProjectChatRow(thread: thread) { PersonChats.remove(thread.id, from: name); chatStore.delete(thread.id) }
                }
                .buttonStyle(.plain)
                .contextMenu { Button("Delete chat", role: .destructive) { PersonChats.remove(thread.id, from: name); chatStore.delete(thread.id) } }
            }
        }
    }

    private func startChat(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let id = ChatStore.shared.newThread(id: UUID())
        PersonChats.add(id, to: name)
        chatDraft = ""
        pane = .personChat(name, id)
        ChatStore.shared.send(question, in: id, model: rec.model, meetings: rec.meetings, projects: ProjectStore.shared.projects, person: name)
    }

    private func setCloseness(_ level: Int?) {
        do { try BrainStore().setClosenessLevel(level, forPerson: name); load() } catch { self.error = error.localizedDescription }
    }

    private func personalDetails(_ dossier: BrainPersonDossier) -> some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Personal details").font(.headline); Spacer(); Text(dossier.details.includeInBrain ? "In Brain" : "Not in Brain").font(.caption).foregroundStyle(BrainUI.muted) }
                let notes = (dossier.details.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if dossier.details.likes.isEmpty && dossier.details.dislikes.isEmpty && dossier.details.importantDates.isEmpty && notes.isEmpty && dossier.details.learned.isEmpty {
                    Text("Nothing saved yet.").foregroundStyle(BrainUI.muted)
                }
                detailLine("Likes", values: dossier.details.likes)
                detailLine("Dislikes", values: dossier.details.dislikes)
                detailLine("Dates", values: dossier.details.importantDates)
                if !notes.isEmpty { detailRow("Notes", notes) }
                if !dossier.details.learned.isEmpty {
                    Divider()
                    Text("Learned from meetings").font(.caption.weight(.semibold)).foregroundStyle(BrainUI.muted)
                    ForEach(dossier.details.learned, id: \.self) { item in
                        HStack(alignment: .top) {
                            Text("\(item.category.capitalized): \(item.value)")
                            Spacer()
                            BrainSourceChip(episode: dossier.meetings.first(where: { $0.id == item.sourceEpisodeID })) { sourceID, kind in pane = sourcePane(sourceID: sourceID, kind: kind) }
                        }
                    }
                }
                Button("Edit details") { showEdit = true }.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var tripLinks: some View {
        if !trips.isEmpty {
            BrainCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Travels with " + name).font(.headline)
                    ForEach(trips) { trip in
                        Button { pane = .content(.trip, trip.id.uuidString) } label: {
                            HStack { Image(systemName: "airplane"); Text(trip.title.isEmpty ? trip.place : trip.title); Spacer(); Text(trip.startDate.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(BrainUI.muted); Image(systemName: "chevron.right").foregroundStyle(BrainUI.muted) }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private func detailLine(_ title: String, values: [String]) -> some View {
        if !values.isEmpty { detailRow(title, values.joined(separator: ", ")) }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.caption).foregroundStyle(BrainUI.muted).frame(width: 64, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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
                            BrainSourceChip(episode: dossier.meetings.first(where: { $0.id == fact.episodeID })) { sourceID, kind in pane = sourcePane(sourceID: sourceID, kind: kind) }
                        }
                    }
                }
            }
        }
    }

    private func meetings(_ dossier: BrainPersonDossier) -> some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Meetings with \(dossier.entity.name)").font(.headline)
                if dossier.meetings.isEmpty { Text("None yet. Meetings where \(dossier.entity.name) speaks or is invited show up here.").foregroundStyle(BrainUI.muted) }
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
        do { dossier = try BrainStore().personDossier(name); trips = TravelStore.trips(forPerson: name) } catch { self.error = error.localizedDescription }
    }
}

private struct BrainPersonEditSheet: View {
    let dossier: BrainPersonDossier
    @Binding var isPresented: Bool
    @State private var closeness = 0
    @State private var includeInBrain = true
    @State private var likes = ""
    @State private var dislikes = ""
    @State private var importantDates = ""
    @State private var notes = ""
    @State private var error: String?

    init(dossier: BrainPersonDossier, isPresented: Binding<Bool>) {
        self.dossier = dossier; self._isPresented = isPresented
        _closeness = State(initialValue: dossier.entity.closenessLevel ?? 0)
        _includeInBrain = State(initialValue: dossier.details.includeInBrain)
        _likes = State(initialValue: dossier.details.likes.joined(separator: "\n"))
        _dislikes = State(initialValue: dossier.details.dislikes.joined(separator: "\n"))
        _importantDates = State(initialValue: dossier.details.importantDates.joined(separator: "\n"))
        _notes = State(initialValue: dossier.details.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(dossier.entity.name)").font(.title2.bold())
            Form {
                Picker("Closeness", selection: $closeness) {
                    Text("Not set").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) · \(closenessLabel($0))").tag($0) }
                }
                Toggle("Include personal details in Brain", isOn: $includeInBrain)
                detailEditor("Likes", text: $likes)
                detailEditor("Dislikes / allergies", text: $dislikes)
                detailEditor("Important dates", text: $importantDates)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.caption.weight(.semibold))
                    TextEditor(text: $notes).font(.body).frame(minHeight: 110).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.2)))
                    Text("Anything worth remembering about them. The Brain uses it in chat and briefs.").font(.caption2).foregroundStyle(BrainUI.muted)
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { StoredLocally(); Spacer(); Button("Cancel") { isPresented = false }; Button("Save") { save() }.buttonStyle(.borderedProminent) }
        }
        .padding(24).frame(width: 540, height: 570)
    }

    private func detailEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            TextEditor(text: text).font(.body).frame(minHeight: 42).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.2)))
            Text("One item per line").font(.caption2).foregroundStyle(BrainUI.muted)
        }
    }

    private func closenessLabel(_ value: Int) -> String {
        switch value { case 1: return "very close"; case 2: return "close"; case 3: return "in touch"; case 4: return "distant"; default: return "far" }
    }

    private func save() {
        let details = BrainPersonDetails(includeInBrain: includeInBrain, likes: lines(likes), dislikes: lines(dislikes),
                                         familyNames: dossier.details.familyNames, importantDates: lines(importantDates),
                                         giftIdeas: dossier.details.giftIdeas, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let store = try BrainStore()
            try store.setClosenessLevel(closeness == 0 ? nil : closeness, forPerson: dossier.entity.name)
            try store.updatePersonDetails(forPerson: dossier.entity.name, details: details)
            isPresented = false
        } catch let caught { self.error = caught.localizedDescription }
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
                        BrainSourceChip(episode: dossier.meetings.first(where: { $0.id == fact.episodeID })) { sourceID, kind in pane = sourcePane(sourceID: sourceID, kind: kind) }
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

    private var manual: [(String, String)] {
        var rows: [(String, String)] = []
        let d = dossier.details
        if !dossier.entity.summary.isEmpty { rows.append(("Who they are", dossier.entity.summary)) }
        if let notes = d.notes, !notes.isEmpty { rows.append(("Notes", notes)) }
        if !d.likes.isEmpty { rows.append(("Likes", d.likes.joined(separator: ", "))) }
        if !d.dislikes.isEmpty { rows.append(("Dislikes", d.dislikes.joined(separator: ", "))) }
        if !d.importantDates.isEmpty { rows.append(("Dates", d.importantDates.joined(separator: ", "))) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("What the Brain knows about \(dossier.entity.name)").font(.title2.bold()); Spacer(); Button("Done") { isPresented = false } }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("From your notes", empty: "You haven't written anything about \(dossier.entity.name) yet. Use Edit details on their page.", isEmpty: manual.isEmpty) {
                        ForEach(manual, id: \.0) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(row.0).font(.caption).foregroundStyle(BrainUI.muted).frame(width: 90, alignment: .leading)
                                Text(row.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    section("From meetings", empty: "Nothing learned from meetings yet. Facts appear after a meeting with \(dossier.entity.name) is processed.", isEmpty: facts.isEmpty) {
                        ForEach(facts, id: \.id) { fact in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fact.value.isEmpty ? fact.predicate : fact.value).fixedSize(horizontal: false, vertical: true)
                                Text("\(fact.kind.rawValue.capitalized) · \(BrainUI.date(fact.validFrom))").font(.caption).foregroundStyle(BrainUI.muted)
                            }
                        }
                    }
                    section("Meetings", empty: "No meetings with \(dossier.entity.name) yet.", isEmpty: dossier.meetings.isEmpty) {
                        ForEach(dossier.meetings, id: \.id) { meeting in
                            Text(BrainUI.date(meeting.startedAt))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !facts.isEmpty {
                Button("Forget what meetings taught the Brain about this person", role: .destructive) {
                    if let store = try? BrainStore() {
                        for fact in facts { try? store.applyCorrection(factID: fact.id, action: "forget") }
                    }
                    isPresented = false
                }
                .buttonStyle(.bordered)
            }
            StoredLocally()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 460)
        .task { facts = (try? BrainStore().factsForPerson(dossier.entity.name)) ?? [] }
    }

    @ViewBuilder private func section<Content: View>(_ title: String, empty: String, isEmpty: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if isEmpty { Text(empty).foregroundStyle(BrainUI.muted).fixedSize(horizontal: false, vertical: true) } else { content() }
        }
    }
}

struct BrainPromisesView: View {
    @EnvironmentObject private var rec: Recorder
    @Binding var pane: Pane?
    @State private var items: [BrainPromiseItem] = []
    @State private var snoozed: [Int64: Date] = [:]
    @State private var showClosed = false
    @State private var error: String?
    @State private var orbitMode: OrbitMode = .promises

    private var shown: [BrainPromiseItem] {
        items.filter { item in
            guard let until = snoozed[item.fact.id] else { return true }
            return until <= Date()
        }
    }

    private var openItems: [BrainPromiseItem] { shown.filter { !$0.fact.done && $0.fact.invalidatedAt == nil } }
    private var closedItems: [BrainPromiseItem] { shown.filter { $0.fact.done || $0.fact.invalidatedAt != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("Orbit").font(.title2.weight(.semibold))
                    Picker("View", selection: $orbitMode) {
                        Text("Orbit").tag(OrbitMode.orbit); Text("List").tag(OrbitMode.list); Text("Promises").tag(OrbitMode.promises)
                    }.pickerStyle(.segmented).frame(width: 210)
                    Spacer(); StoredLocally()
                }
                if openItems.isEmpty { BrainEmptyState(title: "No open promises", message: "When a meeting contains a commitment, it will appear here with its source.") }
                else {
                    HStack(alignment: .top, spacing: 16) {
                        promiseColumn("I owe", items: openItems.filter(\.iOwe))
                        promiseColumn("Owed to me", items: openItems.filter { !$0.iOwe })
                    }
                }
                if !closedItems.isEmpty {
                    DisclosureGroup("Done and cancelled (\(closedItems.count))", isExpanded: $showClosed) {
                        HStack(alignment: .top, spacing: 16) {
                            promiseColumn("I owed", items: closedItems.filter(\.iOwe))
                            promiseColumn("Was owed to me", items: closedItems.filter { !$0.iOwe })
                        }.padding(.top, 8)
                    }
                }
            }
            .padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(BrainUI.page)
        .navigationTitle("Brain · Promises")
        .task { load() }
        .onChange(of: orbitMode) { _, value in if value != .promises { pane = .brainOrbit } }
        .overlay(alignment: .bottom) { if let error { Text(error).font(.caption).foregroundStyle(.red).padding() } }
    }

    private func promiseColumn(_ title: String, items: [BrainPromiseItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline); Spacer(); Text("\(items.count)").font(.caption).foregroundStyle(BrainUI.muted) }
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
                    if item.fact.done || item.fact.invalidatedAt != nil {
                        Text(item.fact.done ? "Done" : "Cancelled").font(.caption).foregroundStyle(BrainUI.muted)
                    } else {
                        Button("Done") { correct(item, action: "done") }.buttonStyle(.bordered)
                        Button(item.iOwe ? "Draft follow-up" : "Draft a nudge") { draft(item) }.buttonStyle(.borderedProminent)
                        Button("Snooze") { snooze(item) }.buttonStyle(.bordered)
                    }
                    Spacer()
                    BrainSourceChip(episode: item.episode) { sourceID, kind in pane = sourcePane(sourceID: sourceID, kind: kind) }
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
            items = try BrainStore().promiseItems()
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

    private var matchedName: String { dossier?.entity.name ?? personName }

    var body: some View {
        BrainCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(BrainUI.orange).frame(width: 10, height: 10)
                    Text("In \(max(1, Int(event.startDate.timeIntervalSince(Date()) / 60))) minutes").font(.caption.weight(.bold)).foregroundStyle(BrainUI.orange)
                    Spacer(); StoredLocally()
                }
                HStack(spacing: 12) {
                    Text(BrainUI.initials(matchedName)).font(.headline).foregroundStyle(.white).frame(width: 44, height: 44).background(Circle().fill(BrainUI.orange))
                    VStack(alignment: .leading) { Text("Call with \(matchedName)").font(.title3.bold()); Text(event.title).font(.caption).foregroundStyle(BrainUI.muted) }
                }
                briefingLines
                HStack {
                    Button("Start recording when it begins") { Task { await rec.start(); pane = .live } }.buttonStyle(.borderedProminent)
                    Button("Open briefing") { pane = .brainBriefing(personName) }.buttonStyle(.bordered)
                }
            }
        }
        .task {
            let identifiers = [personName] + event.attendeeEmails
            dossier = try? BrainStore().personDossier(matching: identifiers)
        }
    }

    private var briefingLines: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Last time: \(dossier?.meetings.first.map { BrainUI.date($0.startedAt) } ?? "No previous meeting")")
            Text("You promised: \(dossier?.openCommitmentsByPerson.first.map { $0.value.isEmpty ? $0.predicate : $0.value } ?? "Nothing open extracted")")
            Text("They promised: \(dossier?.openCommitmentsToPerson.first.map { $0.value.isEmpty ? $0.predicate : $0.value } ?? "Nothing open extracted")")
            if let dossier, let old = dossier.positionHistory.first(where: { $0.invalidatedAt != nil && $0.supersededBy != nil }),
               let current = dossier.positionHistory.first(where: { $0.id == old.supersededBy }) {
                Text("Changed since last: \(old.value) → \(current.value)")
            } else { Text("Changed since last: No replaced facts found") }
            let details = dossier?.details.likes.prefix(2).joined(separator: ", ") ?? ""
            if !details.isEmpty { Text("They like: \(details)") }
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
            Text("Find connections").font(.largeTitle.bold())
            TextField("New person or group", text: $search)
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
                    Text(fact.predicate.uppercased()).font(.caption.weight(.bold)).foregroundStyle(BrainUI.color(for: .business))
                    if fact.status == "unverified" { Text("UNVERIFIED").font(.caption2.weight(.bold)).foregroundStyle(BrainUI.muted).padding(3).overlay(RoundedRectangle(cornerRadius: 4).stroke(BrainUI.muted)) }
                    Spacer(); Text(BrainUI.date(fact.validFrom)).font(.caption).foregroundStyle(BrainUI.muted)
                }
                if let old {
                    Text(old.value.isEmpty ? old.quote : old.value).strikethrough().foregroundStyle(BrainUI.muted)
                    Text(fact.value.isEmpty ? fact.quote : fact.value).fontWeight(.bold)
                } else { Text(fact.value.isEmpty ? fact.quote : fact.value).fontWeight(.bold) }
                HStack {
                    BrainSourceChip(episode: try? BrainStore().episode(id: fact.episodeID)) { sourceID, kind in pane = sourcePane(sourceID: sourceID, kind: kind) }
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
                    HStack(alignment: .firstTextBaseline) { VStack(alignment: .leading) { Text(story.matter.name).font(.largeTitle.bold()); Text("Topic story · \(story.episodes.count) meetings").foregroundStyle(BrainUI.muted) }; Spacer(); StoredLocally() }
                    if story.facts.isEmpty { BrainEmptyState(title: "No story yet", message: "Positions and commitments extracted from meetings will form this chronology.") }
                    else {
                        ForEach(story.parties + [BrainEntity(id: -1, kind: .person, name: "You", world: .unknown, summary: "", createdAt: "", updatedAt: "", forgotten: false)], id: \.id) { party in
                            lane(party, story: story)
                        }
                    }
                    HStack(spacing: 14) { Text("Solid = current position"); Text("Light = earlier position"); Text("Dashed = open commitment") }.font(.caption).foregroundStyle(BrainUI.muted)
                }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
            } else { BrainEmptyState(title: "Topic not found", message: "This topic has not been extracted yet.").padding(28) }
        }
        .background(BrainUI.page).navigationTitle("Brain · Topic story")
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
                        BrainSourceChip(episode: story.episodes.first(where: { $0.id == fact.episodeID })) { sourceID, kind in pane = sourcePane(sourceID: sourceID, kind: kind) }
                    }
                }
            }
        }
    }
}


/// Adds a person by hand: name, world, who they are, email. Saved only on this Mac.
struct AddPersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var world: BrainWorld
    @State private var name = ""
    @State private var summary = ""
    @State private var email = ""
    @State private var notes = ""
    @State private var closeness = 0
    @State private var error: String?

    private let worlds: [BrainWorld] = [.friend, .family, .business, .mentor, .mentee, .other]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add person").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                Picker("World", selection: $world) {
                    ForEach(worlds, id: \.self) { item in Text(item.rawValue.capitalized).tag(item) }
                }
                Picker("Closeness", selection: $closeness) {
                    Text("Not set (suggested)").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) · \(closenessLabel($0))").tag($0) }
                }
                TextField("Who they are (role, company, what they care about)", text: $summary, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Email (optional, links calendar invites to them)", text: $email)
                TextField("Notes (anything worth remembering)", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                StoredLocally()
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func save() {
        do {
            let store = try BrainStore()
            _ = try store.addPerson(name: name, world: world, summary: summary, email: email.isEmpty ? nil : email,
                                    closenessLevel: closeness == 0 ? nil : closeness)
            let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanNotes.isEmpty {
                try store.updatePersonDetails(forPerson: name.trimmingCharacters(in: .whitespacesAndNewlines), details: BrainPersonDetails(notes: cleanNotes))
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func closenessLabel(_ value: Int) -> String {
        switch value { case 1: return "very close"; case 2: return "close"; case 3: return "in touch"; case 4: return "distant"; default: return "far" }
    }
}

/// Chats started on a person's page belong to that person (like project chats) and stay out of the main Chats list.
enum PersonChats {
    private static var file: URL { InferoidPaths.support.appendingPathComponent("PersonChats.json") }
    private static func key(_ name: String) -> String { name.lowercased().trimmingCharacters(in: .whitespaces) }

    static func load() -> [String: [UUID]] {
        guard let data = try? Data(contentsOf: file), let map = try? JSONDecoder().decode([String: [UUID]].self, from: data) else { return [:] }
        return map
    }

    private static func save(_ map: [String: [UUID]]) {
        try? FileManager.default.createDirectory(at: InferoidPaths.support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: file, options: .atomic) }
    }

    static func ids(for name: String) -> [UUID] { load()[key(name)] ?? [] }
    /// The person a chat was started about, if any (stored lowercased; shown capitalized).
    static func person(for id: UUID) -> String? { load().first { $0.value.contains(id) }.map { $0.key.capitalized } }
    static var allIDs: Set<UUID> { Set(load().values.flatMap { $0 }) }

    static func add(_ id: UUID, to name: String) {
        var map = load(); map[key(name), default: []].append(id); save(map)
    }

    static func remove(_ id: UUID, from name: String) {
        var map = load(); map[key(name)]?.removeAll { $0 == id }; save(map)
    }
}
