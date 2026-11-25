import AppKit
import SwiftUI

/// What the main window shows: the status page, the meeting list, a chat, the meeting in progress, a saved meeting, or an
/// extension's tab.
enum Pane: Hashable {
    case home, meetings, newChat, live
    case library, travels, journal, routines
    case content(BrainSourceKind, String)
    case projects, reflection
    case brainOrbit, brainPromises, brainChanges
    case brainPerson(String), brainMatter(Int64), brainBriefing(String)
    case project(UUID)
    case projectChat(UUID, UUID)
    case personChat(String, UUID)
    case chat(UUID)
    case chatDraft(UUID, String)
    case extensionTab(String)
    case meeting(String)
}

func sourcePane(sourceID: String, kind: BrainSourceKind) -> Pane {
    switch kind {
    case .meeting: return .meeting(sourceID)
    case .library, .article, .movies, .journal, .trip: return .content(kind, sourceID)
    case .project:
        return SourceRegistry.projectID(from: sourceID).map(Pane.project) ?? .projects
    }
}

func sourcePane(_ source: Meeting) -> Pane { sourcePane(sourceID: source.sourceID, kind: source.sourceKind) }

@MainActor
public struct MainView: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject private var chats = ChatStore.shared
    @State private var pane: Pane? = .home
    @State private var renaming: UUID?
    @State private var renameText = ""

    public init() {}

    private var brainSection: some View {
        Section("Brain") {
            Label("Orbit", systemImage: "circle.hexagongrid").tag(Pane.brainOrbit)
            Label("Library", systemImage: "books.vertical").tag(Pane.library)
            Label("Travels", systemImage: "airplane").tag(Pane.travels)
            Label("Journal", systemImage: "book.pages").tag(Pane.journal)
            Label("Projects", systemImage: "folder").tag(Pane.projects)
            Label("Routines", systemImage: "repeat").tag(Pane.routines)
        }
    }

    /// The detail pane for the sidebar selection (split out so the compiler can type-check `body` quickly).
    @ViewBuilder
    private func detailView(for selected: Pane) -> some View {
            switch selected {
            case .home: HomeStatusView(pane: $pane)
            case .meetings: MeetingsView(pane: $pane)
            case .library: LibraryView(pane: $pane)
            case .travels: TravelsView(pane: $pane)
            case .journal: JournalView(pane: $pane)
            case .content(let kind, let id): contentView(kind: kind, id: id)
            case .projects: ProjectsView(pane: $pane)
            case .reflection: WeeklyReflectionView()
            case .routines: RoutinesView()
            case .brainOrbit: BrainOrbitView(pane: $pane)
            case .brainPromises: BrainPromisesView(pane: $pane)
            case .brainChanges: BrainChangesView(pane: $pane)
            case .brainPerson(let name): BrainPersonView(pane: $pane, name: name)
            case .brainMatter(let id): BrainMatterView(pane: $pane, matterID: id)
            case .brainBriefing(let name): BrainBriefingView(pane: $pane, personName: name)
            case .newChat: ProgressView()
            case .chat(let id): ChatView(threadID: id, openSource: { open(sourceID: $0, kind: $1) }).id(id)
            case .chatDraft(let id, let draft): ChatView(threadID: id, openSource: { open(sourceID: $0, kind: $1) }, initialDraft: draft).id(id)
            case .project(let id): ProjectView(projectID: id, pane: $pane)
            case .personChat(let name, let threadID):
                ChatView(threadID: threadID, openSource: { open(sourceID: $0, kind: $1) }, person: name,
                         personBack: { pane = .brainPerson(name) }).id(threadID)
            case .projectChat(let projectID, let threadID):
                if let project = ProjectStore.shared.project(projectID) {
                    ChatView(threadID: threadID, openSource: { open(sourceID: $0, kind: $1) }, project: project,
                             projectBack: { pane = .project(projectID) }, projectDeleted: { pane = .project(projectID) }).id(threadID)
                } else {
                    ProjectsView(pane: $pane)
                }
            case .live: LiveMeetingView()
            case .extensionTab(let id):
                if let view = InferoidExtensions.view(for: id) { view } else { Text("This tab is no longer available") }
            case .meeting(let id):
                if let projectID = SourceRegistry.projectIDFromEpisode(id) { ProjectView(projectID: projectID, pane: $pane) }
                else if let m = rec.meetings.first(where: { $0.id == id }) { MeetingView(meeting: m, pane: $pane) }
                else { MeetingsView(pane: $pane) }
            }
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Label("Home", systemImage: "house").tag(Pane.home)
                Label("Meetings", systemImage: "person.2.wave.2").tag(Pane.meetings)
                brainSection
                ForEach(InferoidExtensions.topItems) { item in
                    Label(item.title, systemImage: item.systemImage).tag(Pane.extensionTab(item.id))
                }
                if rec.isRecording || rec.isWriting || !rec.lines.isEmpty {
                    Section("Now") {
                        Label(liveLabel, systemImage: rec.isRecording ? "record.circle" : "waveform")
                            .foregroundStyle(rec.isRecording ? Color.red : Color.primary)
                            .tag(Pane.live)
                    }
                }
                let projectChatIDs = Set(ProjectStore.shared.projects.flatMap(\.chatIDs)).union(PersonChats.allIDs)
                let saved = chats.threads.filter { !$0.messages.isEmpty && !projectChatIDs.contains($0.id) && $0.id != AssistantIntro.threadID }
                Section("Chats") {
                    Label("New chat", systemImage: "square.and.pencil").tag(Pane.newChat)
                    if chats.assistantThread != nil {
                        AssistantSidebarRow(unread: pane == .chat(AssistantIntro.threadID) ? 0 : chats.unreadCount(AssistantIntro.threadID))
                        .tag(Pane.chat(AssistantIntro.threadID))
                        .contextMenu { Button("Start the introduction again") { chats.restartIntro() } }
                    }
                        ForEach(saved) { thread in
                            SidebarChatRow(title: thread.title) {
                                if pane == .chat(thread.id) { pane = .home }
                                chats.delete(thread.id)
                            }
                            .tag(Pane.chat(thread.id))
                                .contextMenu {
                                    Button("Rename") { renameText = thread.title; renaming = thread.id }
                                    Button("Delete", role: .destructive) {
                                        if pane == .chat(thread.id) { pane = .home }
                                        chats.delete(thread.id)
                                    }
                                }
                        }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Divider().padding(.bottom, 6)
                    ForEach(InferoidExtensions.bottomItems) { item in
                        Button { pane = .extensionTab(item.id) } label: {
                            Label(item.title, systemImage: item.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(pane == .extensionTab(item.id) ? Color.accentColor.opacity(0.18) : Color.clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: rec.privateMode ? "eye.slash.fill" : (rec.online ? "lock.fill" : "airplane"))
                        Text(rec.privateMode ? "Private mode is on" : (rec.online ? "Everything runs on this Mac" : "Offline. Everything runs on this Mac"))
                        Spacer()
                        SettingsLink { Image(systemName: "gearshape") }
                            .buttonStyle(.plain)
                            .help("Settings: instructions, note template, feedback (⌘,)")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 6)
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
        } detail: {
            detailView(for: pane ?? .home)
        }
        .toolbar {
            // Starting a meeting lives on Home and in the menu bar; the toolbar only offers Stop while recording.
            if rec.isRecording {
                ToolbarItem(placement: .primaryAction) {
                    Button { rec.toggle(); pane = .live } label: { Label("Stop meeting", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { rec.reloadMeetings(); RoutineStore.shared.start() }
        .onChange(of: rec.isRecording) { _, on in if on { pane = .live } }
        .onChange(of: pane) { _, new in
            if new == .newChat { pane = .chat(chats.newThread()) }
        }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { if let id = renaming { chats.rename(id, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var liveLabel: String {
        if rec.isRecording { return "Recording  \(clock(rec.elapsed))" }
        return rec.isWriting ? "Writing notes…" : "Last meeting"
    }

    @ViewBuilder private func contentView(kind: BrainSourceKind, id: String) -> some View {
        switch kind {
        case .library:
            if let uuid = UUID(uuidString: id), let item = CollectionStore.item(id: uuid, kind: .library) { CollectionItemView(item: item, pane: $pane) }
            else { LibraryView(pane: $pane) }
        case .article:
            if let uuid = UUID(uuidString: id), let item = CollectionStore.item(id: uuid, kind: .articles) { CollectionItemView(item: item, pane: $pane) }
            else { LibraryView(pane: $pane) }
        case .movies:
            if let uuid = UUID(uuidString: id), let item = CollectionStore.item(id: uuid, kind: .movies) { CollectionItemView(item: item, pane: $pane) }
            else { LibraryView(pane: $pane) }
        case .trip:
            if let uuid = UUID(uuidString: id), let trip = TravelStore.trip(id: uuid) { TripView(trip: trip, pane: $pane) }
            else { TravelsView(pane: $pane) }
        case .journal:
            if let uuid = UUID(uuidString: id), let entry = JournalStore.entry(id: uuid) { JournalView(pane: $pane, initialDay: entry.date) }
            else { JournalView(pane: $pane) }
        case .meeting: MeetingsView(pane: $pane)
        case .project:
            if let projectID = SourceRegistry.projectID(from: id) { ProjectView(projectID: projectID, pane: $pane) }
            else { ProjectsView(pane: $pane) }
        }
    }

    private func open(sourceID: String, kind: BrainSourceKind) {
        pane = sourcePane(sourceID: sourceID, kind: kind)
    }
}

// MARK: - Home: status

struct HomeStatusView: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject private var chats = ChatStore.shared
    @Binding var pane: Pane?
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false
    @ObservedObject private var appUpdater = AppUpdater.shared
    @ObservedObject private var modelUpdater = ModelUpdater.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Home").font(.largeTitle.bold())
                    Spacer()
                    ModelStatusPill()
                }
                GetStartedCard(pane: $pane)
                if let status = InferoidExtensions.homeStatus { status }
                card {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI model").font(.headline)
                            Text(Summarizer.displayName(rec.model)).foregroundStyle(.secondary)
                            if let testResult {
                                Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(testOK ? Color.green : Color.orange)
                                    .font(.callout).textSelection(.enabled)
                            } else {
                                Text("Runs on this Mac. Test it to see it answer.").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            Button(testing ? "Testing…" : "Test model") { test() }.disabled(testing || rec.isWriting)
                            modelUpdateControl
                        }
                    }
                }
                card {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inferoid").font(.headline)
                            Text("Version \(appUpdater.currentVersion)").foregroundStyle(.secondary)
                            appUpdateLine
                        }
                        Spacer()
                        appUpdateButton
                    }
                }
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Start").font(.headline)
                        HStack(spacing: 10) {
                            Button { pane = .newChat } label: { Label("New chat", systemImage: "square.and.pencil") }
                                .buttonStyle(.borderedProminent)
                            Button {
                                if !rec.isRecording { rec.toggle() }
                                pane = .live
                            } label: { Label(rec.isRecording ? "Open the meeting" : "Start meeting", systemImage: "mic.fill") }
                                .disabled(rec.isWriting)
                            MeetingSettings()
                        }
                        Text("\(rec.meetings.count) meetings and \(savedChats) chats on this Mac. Nothing is sent to a cloud AI.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        .task {
            if appUpdater.state == .idle { await appUpdater.check() }
            if modelUpdater.state == .idle { await modelUpdater.check() }
        }
    }

    private var savedChats: Int { chats.threads.filter { !$0.messages.isEmpty }.count }

    /// Model update: shown under Test model. A new or fine-tuned pack in models.json shows "Update model".
    @ViewBuilder private var modelUpdateControl: some View {
        switch modelUpdater.state {
        case .available(let name):
            VStack(alignment: .trailing, spacing: 4) {
                Text("Update available: \(name)").font(.caption).foregroundStyle(.orange)
                Button("Update model") { Task { await modelUpdater.update(model: rec.model) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(rec.isWriting || rec.isRecording)
            }
        case .updating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating the model…").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            Label("Model updated", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                .frame(maxWidth: 260, alignment: .trailing)
        case .upToDate:
            Text("Model up to date").font(.caption).foregroundStyle(.secondary)
        case .idle, .checking, .notInstalled:
            EmptyView()
        }
    }

    @ViewBuilder private var appUpdateLine: some View {
        switch appUpdater.state {
        case .available(let version):
            Text("Update available: version \(version)").font(.callout).foregroundStyle(.orange)
        case .upToDate:
            Text("You're up to date.").font(.callout).foregroundStyle(.secondary)
        case .development:
            Text("Development build: update it from git.").font(.callout).foregroundStyle(.secondary)
        case .checking:
            Text("Checking for updates…").font(.callout).foregroundStyle(.secondary)
        case .installing(let message):
            Text(message).font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var appUpdateButton: some View {
        switch appUpdater.state {
        case .available:
            Button("Update") { Task { await appUpdater.install() } }
                .buttonStyle(.borderedProminent)
                .disabled(rec.isRecording || rec.isWriting)
        case .installing:
            ProgressView().controlSize(.small)
        case .development:
            EmptyView()
        default:
            Button("Check for updates") { Task { await appUpdater.check() } }
                .disabled(appUpdater.state == .checking)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private func test() {
        testing = true; testResult = nil
        let model = rec.model
        Task { @MainActor in
            let started = Date()
            do {
                try await ModelManager.shared.ensure(model)
                let reply = try await Summarizer.complete(system: "Reply in one short sentence.", user: "Say that you are ready to help.",
                                                          model: model, maxTokens: 60)
                let seconds = Date().timeIntervalSince(started)
                testOK = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                testResult = testOK ? String(format: "Ready (%.1f s): %@", seconds, String(reply.prefix(120))) : "The model gave an empty answer."
            } catch {
                testOK = false
                testResult = "Not ready: \(error.localizedDescription)"
            }
            ModelManager.shared.idle()
            testing = false
        }
    }
}

// MARK: - Meetings

/// An interrupted meeting (crash, force quit, power loss) whose audio was saved and can be transcribed now.
struct RecoveryBanner: View {
    @EnvironmentObject var rec: Recorder
    let pending: RecordingJournal.Pending

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.counterclockwise.circle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("A meeting was interrupted").font(.headline)
                Text("Recorded \(pending.manifest.started.formatted(date: .abbreviated, time: .shortened)), \(Int(pending.seconds / 60)) min of audio saved encrypted on this Mac. Inferoid can transcribe it and write the notes now.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Recover meeting") { Task { await rec.recover(pending) } }
                        .buttonStyle(.borderedProminent).disabled(rec.isRecording || rec.isWriting)
                    Button("Delete audio") { rec.discardRecovery(pending) }
                }
                .padding(.top, 4)
                if rec.isWriting, rec.status.hasPrefix("Recovering") {
                    Text(rec.status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
    }
}

struct MeetingsView: View {
    @EnvironmentObject var rec: Recorder
    @Binding var pane: Pane?
    @State private var deleteTarget: Meeting?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(rec.pendingRecoveries) { p in RecoveryBanner(pending: p) }
                VStack(alignment: .leading, spacing: 14) {
                    Text(rec.isRecording ? "A meeting is being recorded" : "Ready for your next call").font(.title2.bold())
                    Text("Start a meeting when the call begins. Inferoid listens to your microphone and the call audio, "
                         + "transcribes on this Mac, and writes the notes when you stop.")
                        .foregroundStyle(.secondary)
                    if rec.isRecording && !rec.attendeeNames.isEmpty {
                        Label("With \(rec.attendeeNames.joined(separator: ", ")) (from your calendar)", systemImage: "calendar")
                            .font(.callout.weight(.medium))
                    } else {
                        Label("Start during a calendar event and Inferoid uses the guests' names. "
                              + "With one guest, the transcript shows their name instead of \"Them\".", systemImage: "calendar")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            if !rec.isRecording { rec.toggle() }
                            pane = .live
                        } label: {
                            Label(rec.isRecording ? "Open the meeting" : "Start meeting", systemImage: "mic.fill").padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(rec.isWriting)
                        MeetingSettings()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.15)))

                if rec.meetings.isEmpty {
                    Text("Your meetings will appear here, stored encrypted on this Mac.")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(dayLabel(group.day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(group.items) { m in
                                Button { pane = .meeting(m.id) } label: { MeetingRow(meeting: m, onDelete: rec.canDeleteMeeting(m) ? { deleteTarget = m } : nil) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Delete meeting", role: .destructive) { deleteTarget = m }
                                            .disabled(!rec.canDeleteMeeting(m))
                                    }
                                if m.id != group.items.last?.id { Divider().padding(.leading, 52) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { rec.refreshRecoveries() }
        .navigationTitle("Meetings")
        .confirmationDialog("Delete this meeting? Its recording, transcript and notes move to the Trash, and anything the Brain learned from it is forgotten.",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete meeting", role: .destructive) {
                if let target = deleteTarget {
                    do {
                        try rec.deleteMeeting(target)
                        if pane == .meeting(target.id) { pane = .meetings }
                    } catch { rec.error = "Delete meeting: \(error.localizedDescription)" }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
    }

    private var groups: [(day: String, items: [Meeting])] {
        var out: [(day: String, items: [Meeting])] = []
        for m in rec.meetings {
            if let last = out.last, last.day == m.date { out[out.count - 1].items.append(m) } else { out.append((m.date, [m])) }
        }
        return out
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    var onDelete: (() -> Void)? = nil
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12)))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.body.weight(.medium)).lineLimit(1)
                Text(summaryLine(meeting)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(timeLabel(meeting)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: meeting.includeInBrain ? "checkmark.square.fill" : "square")
                .font(.caption).foregroundStyle(meeting.includeInBrain ? Color.accentColor : Color.secondary)
                .help(meeting.includeInBrain ? "Included in Brain" : "Excluded from Brain")
            if let onDelete {
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete meeting")
                    .opacity(hovering ? 1 : 0)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Template and model, side by side.
struct MeetingSettings: View {
    @EnvironmentObject var rec: Recorder
    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $rec.template) {
                ForEach(Template.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("What kind of meeting: changes what the notes focus on")
            ModelMenu()
        }
    }
}

/// Shows only the Inferoid notes model unless "Show other models" is on.
struct ModelMenu: View {
    @EnvironmentObject var rec: Recorder
    var body: some View {
        Menu {
            ForEach(rec.visibleModels, id: \.self) { m in
                Button {
                    rec.model = m
                } label: {
                    if m == rec.model { Label(Summarizer.displayName(m), systemImage: "checkmark") } else { Text(Summarizer.displayName(m)) }
                }
            }
            Divider()
            Toggle("Show other models (Ollama)", isOn: $rec.showAllModels)
        } label: {
            Text(Summarizer.displayName(rec.model))
        }
        .fixedSize()
        .disabled(rec.isWriting)
        .help("The model that writes the notes")
    }
}

// MARK: - Meeting in progress

struct LiveMeetingView: View {
    @EnvironmentObject var rec: Recorder
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle().fill(rec.isRecording ? Color.red : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                    Text(rec.isRecording ? "Recording  \(clock(rec.elapsed))" : rec.status).font(.headline).monospacedDigit()
                    if rec.isWriting { ProgressView().controlSize(.small) }
                    Spacer()
                    if rec.isRecording {
                        Meter(icon: "mic.fill", help: "Your microphone (Me)", level: rec.levelMe)
                        Meter(icon: "speaker.wave.2.fill", help: "Call audio (Them)", level: rec.levelThem)
                    }
                }
                HStack {
                    MeetingSettings()
                    Spacer()
                    Picker("", selection: $tab) {
                        Text("Transcript").tag(0)
                        Text("Notes").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                if rec.isRecording {
                    Text("Recording. Let everyone on the call know.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = rec.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(16)
            Divider()
            if tab == 0 { TranscriptView() } else { NotesView() }
        }
        .navigationTitle("Meeting")
        .onChange(of: rec.notes) { _, notes in if notes != nil { tab = 1 } }
        .onChange(of: rec.isRecording) { _, on in if on { tab = 0 } }
    }
}

/// Live input level, shown while recording.
struct Meter: View {
    let icon: String
    let help: String
    let level: Float
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Color.green).frame(width: g.size.width * CGFloat(min(1, sqrt(Double(level)) * 4)))
                }
            }
            .frame(width: 50, height: 5)
        }
        .help(help)
    }
}

struct TranscriptView: View {
    @EnvironmentObject var rec: Recorder
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if rec.lines.isEmpty {
                        Text(rec.isRecording ? "Listening…" : "Start a meeting. Your voice and the call audio are transcribed here, live, on this Mac.")
                            .foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
                    }
                    ForEach(rec.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(line.speaker).font(.caption.bold())
                                    .foregroundStyle(line.speaker == "Me" ? Color.accentColor : Color.orange)
                                Text(clock(line.start)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(line.text).textSelection(.enabled)
                        }
                        .id(line.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: rec.lines.count) { _, _ in
                if let last = rec.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

struct NotesView: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject var prefs = Prefs.shared
    var body: some View {
        ScrollView {
            if let n = rec.notes {
                VStack(alignment: .leading, spacing: 14) {
                    if !rec.isWriting, rec.feedbackFor != nil, rec.feedbackFor == rec.savedFolder {
                        FeedbackBar()
                    }
                    Text(n.title).font(.title2.bold())
                    ForEach(prefs.layout.visible) { s in sectionView(s, n) }
                    HStack {
                        Text(rec.notesInfo).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let folder = rec.savedFolder {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                        Button("Copy as Markdown") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(notesMarkdown(n, attendeeNames: rec.attendeeNames), forType: .string)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            } else {
                Text(rec.isWriting ? rec.status : "Notes appear here when the meeting ends.")
                    .foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func sectionView(_ s: NoteSection, _ n: Notes) -> some View {
        let name = prefs.layout.name(s)
        switch s {
        case .summary:
            if name == NoteSection.summary.defaultName { Text(n.summary) } else {
                VStack(alignment: .leading, spacing: 6) { Text(name).font(.headline); Text(n.summary) }
            }
        case .keyPoints: section(name, n.key_points)
        case .decisions: section(name, n.decisions)
        case .actionItems:
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.headline)
                if n.action_items.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(n.action_items, id: \.self) { a in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "square").foregroundStyle(.secondary)
                        Text(a.task + (a.owner.isEmpty ? "" : "  · \(a.owner)") + (a.due.isEmpty ? "" : "  · \(a.due)"))
                    }
                }
            }
        case .openQuestions: section(name, n.open_questions)
        }
    }

    private func section(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if items.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(items, id: \.self) { Text("•  " + $0) }
        }
    }
}

// MARK: - A saved meeting

struct MeetingView: View {
    @EnvironmentObject var rec: Recorder
    let meeting: Meeting
    @Binding var pane: Pane?
    @State private var tab = 0
    @State private var transcriptText = ""
    @State private var renameSpeaker = ""
    @State private var isRenaming = false
    @State private var includeInBrain: Bool
    @State private var confirmingDelete = false

    init(meeting: Meeting, pane: Binding<Pane?>) {
        self.meeting = meeting
        self._pane = pane
        self._includeInBrain = State(initialValue: meeting.includeInBrain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title).font(.title.bold()).textSelection(.enabled)
                Text(dayLabel(meeting.date) + "  ·  " + timeLabel(meeting)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.top, 20)
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Include in Brain", isOn: Binding(get: { includeInBrain }, set: { value in
                    if rec.setIncludeInBrain(value, for: meeting) { includeInBrain = value }
                }))
                .toggleStyle(.checkbox)
                if !includeInBrain {
                    Text("The Brain and chat won't use this meeting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28).padding(.top, 12)
            HStack {
                Picker("", selection: $tab) {
                    Text("Notes").tag(0)
                    Text("Transcript").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab == 0 ? meeting.notes : transcriptText, forType: .string)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
                Button("Delete meeting", role: .destructive) { confirmingDelete = true }
                    .disabled(!rec.canDeleteMeeting(meeting))
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
            Divider()
            if tab == 1, transcriptText.contains("] Them:**") {
                HStack(spacing: 8) {
                    if isRenaming {
                        TextField("New speaker name", text: $renameSpeaker)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Button("Save") {
                            let name = renameSpeaker.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            if let updated = try? Store.renameSpeaker(in: meeting.folder, from: "Them", to: name) {
                                transcriptText = updated
                                isRenaming = false
                                rec.reloadMeetings()
                            }
                        }
                        Button("Cancel") { isRenaming = false }
                    } else {
                        Button("Rename Them") {
                            renameSpeaker = ""
                            isRenaming = true
                        }
                        Text("Changes every ‘Them’ label in this saved transcript.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
            ScrollView {
                let text = tab == 0 ? meeting.notes : transcriptText
                if text.isEmpty {
                    Text(tab == 0 ? "No notes for this meeting; the transcript is saved." : "No transcript.")
                        .foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
                } else {
                    MarkdownBlock(text: text)
                        .padding(28)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(meeting.title)
        .id(meeting.id)
        .onAppear { transcriptText = meeting.transcript }
        .confirmationDialog("Delete this meeting? Its recording, transcript and notes move to the Trash, and anything the Brain learned from it is forgotten.", isPresented: $confirmingDelete) {
            Button("Delete meeting", role: .destructive) {
                do {
                    try rec.deleteMeeting(meeting)
                    pane = .meetings
                } catch { rec.error = "Delete meeting: \(error.localizedDescription)" }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Renders the Markdown the app saves: ## headings, - bullets, - [ ] tasks, **bold** inline. The "# Title" line is skipped.
struct MarkdownBlock: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
        }
        .textSelection(.enabled)
    }

    private var lines: [String] {
        text.components(separatedBy: "\n").filter { !$0.hasPrefix("# ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3))).font(.headline).padding(.top, 10)
        } else if line.hasPrefix("- [ ] ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "square").foregroundStyle(.secondary)
                inline(String(line.dropFirst(6)))
            }
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(String(line.dropFirst(2)))
            }
        } else {
            inline(line)
        }
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
    }
}

public struct MenuContent: View {
    @EnvironmentObject var rec: Recorder
    @Environment(\.openWindow) private var openWindow
    public init() {}

    public var body: some View {
        Button(rec.isRecording ? "Stop meeting" : "Start meeting") { rec.toggle(); openMain() }
        Button("Open Inferoid") { openMain() }
        if let folder = rec.savedFolder {
            Button("Show last notes in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Labels

/// "Today", "Yesterday", or "Monday, Nov 10" for a yyyy-MM-dd date.
func dayLabel(_ day: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    guard let date = f.date(from: day) else { return day }
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    let out = DateFormatter()
    out.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "EEEE, MMM d" : "MMM d, yyyy"
    return out.string(from: date)
}

/// "14:05" from the folder name "yyyy-MM-dd HHmm Title".
func timeLabel(_ m: Meeting) -> String {
    let name = m.folder.lastPathComponent
    guard name.count >= 15 else { return "" }
    let hhmm = name.dropFirst(11).prefix(4)
    return hhmm.allSatisfy(\.isNumber) ? "\(hhmm.prefix(2)):\(hhmm.suffix(2))" : ""
}

/// The summary: the first plain line of the notes after the title.
func summaryLine(_ m: Meeting) -> String {
    m.notes.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.hasPrefix("-") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map(String.init) ?? "Transcript only"
}

/// A sidebar chat row with a delete button that appears on hover.
private struct SidebarChatRow: View {
    let title: String
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                Button(action: delete) { Image(systemName: "trash").font(.caption) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete chat")
            }
        }
        .onHover { hovering = $0 }
    }
}

/// The assistant's row: emoji, name and unread badge; on hover, edit (name and emoji) and start fresh.
private struct AssistantSidebarRow: View {
    @ObservedObject private var chats = ChatStore.shared
    let unread: Int
    @State private var hovering = false
    @State private var editing = false
    @State private var confirmFresh = false

    var body: some View {
        HStack(spacing: 6) {
            Text(chats.profile.isOnboarded ? chats.profile.displayEmoji : "✨")
            Text(chats.profile.isOnboarded ? chats.profile.displayName : "Assistant").fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 0)
            if hovering && chats.profile.isOnboarded {
                Button { editing = true } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Change name and emoji")
                Button { confirmFresh = true } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless)
                    .help("Start a fresh conversation (keeps what it knows about you)")
            } else if unread > 0 {
                Text("\(unread)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.red))
            }
        }
        .foregroundStyle(.primary)
        .onHover { hovering = $0 }
        .sheet(isPresented: $editing) { AssistantIdentitySheet() }
        .confirmationDialog("Start a fresh conversation with \(chats.profile.displayName)?", isPresented: $confirmFresh, titleVisibility: .visible) {
            Button("Start fresh") { chats.startFreshAssistantChat() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The messages are cleared. Your profile and everything in your Brain stay.") }
    }
}

private struct AssistantIdentitySheet: View {
    @ObservedObject private var chats = ChatStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ChatStore.shared.profile.displayName
    @State private var emoji = ChatStore.shared.profile.displayEmoji

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your assistant").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                TextField("Emoji", text: $emoji)
                HStack(spacing: 8) {
                    ForEach(AssistantIntro.emojis, id: \.self) { option in
                        Button(option) { emoji = option }.buttonStyle(.bordered).font(.title3)
                    }
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { chats.updateIdentity(name: name, emoji: emoji); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 460)
    }
}

/// Home's setup list: what to connect or add so the Brain has something to work with. Done items are ticked.
private struct GetStartedCard: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject private var chats = ChatStore.shared
    @Binding var pane: Pane?
    @State private var calendarConnected = MeetingCalendar.isConnected
    @State private var hasLibrary = !CollectionStore.brainItems().isEmpty
    @State private var hasPeople = ((try? BrainStore().orbitPeople(limit: 1)) ?? []).isEmpty == false
    @AppStorage("home.getStarted.hidden") private var hidden = false

    private struct Step: Identifiable {
        let id: String; let title: String; let detail: String; let done: Bool; let action: String?; let run: (() -> Void)?
    }

    private var steps: [Step] {
        [
            Step(id: "calendar", title: "Connect your calendar", detail: "Names the people in your meetings and prepares a brief before each one.",
                 done: calendarConnected, action: "Connect", run: { Task { calendarConnected = await MeetingCalendar.connect() } }),
            Step(id: "assistant", title: "Meet your assistant", detail: "A one-minute intro so it knows what to call you.",
                 done: chats.profile.isOnboarded, action: "Open", run: { pane = .chat(AssistantIntro.threadID) }),
            Step(id: "meeting", title: "Record your first meeting", detail: "Notes are written on this Mac when you stop.",
                 done: rec.meetings.contains { $0.sourceKind == .meeting }, action: nil, run: nil),
            Step(id: "people", title: "Add the people who matter", detail: "Family, friends and colleagues, by how close they are.",
                 done: hasPeople, action: "Orbit", run: { pane = .brainOrbit }),
            Step(id: "library", title: "Add a book, article or video", detail: "Paste a link; the Brain learns what you read and watch.",
                 done: hasLibrary, action: "Library", run: { pane = .library }),
            Step(id: "email", title: "Connect email", detail: "Coming soon.", done: false, action: nil, run: nil),
        ]
    }

    var body: some View {
        let list = steps
        let remaining = list.filter { !$0.done && $0.id != "email" }.count
        if !hidden || remaining > 0 {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Get started").font(.headline)
                    Text("\(list.filter(\.done).count) of \(list.count - 1) done").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if remaining == 0 { Button("Hide") { hidden = true }.buttonStyle(.borderless) }
                }
                ForEach(list) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.done ? Color.green : Color.secondary).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).fontWeight(.medium).strikethrough(step.done, color: .secondary)
                                .foregroundStyle(step.id == "email" ? .secondary : .primary)
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !step.done, let action = step.action, let run = step.run {
                            Button(action, action: run).buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.15)))
            .onAppear {
                calendarConnected = MeetingCalendar.isConnected
                hasLibrary = !CollectionStore.brainItems().isEmpty
                hasPeople = ((try? BrainStore().orbitPeople(limit: 1)) ?? []).isEmpty == false
            }
        }
    }
}

/// Green when the local model answered its last request, red (with Restart) when it failed.
private struct ModelStatusPill: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject private var health = ModelHealth.shared

    var body: some View {
        let failed = health.lastError != nil
        HStack(spacing: 8) {
            Circle().fill(health.restarting ? Color.orange : (failed ? Color.red : Color.green)).frame(width: 10, height: 10)
            Text(health.restarting ? "Restarting the model…" : (failed ? "Model stopped working" : "Model ready"))
                .font(.callout.weight(.medium))
            if failed && !health.restarting {
                Button("Restart") { restart() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill((failed ? Color.red : Color.green).opacity(0.12)))
        .help(health.lastError ?? (health.lastOK.map { "Last answered \($0.formatted(date: .omitted, time: .shortened))" } ?? "Runs on this Mac"))
    }

    private func restart() {
        health.restarting = true
        Task {
            do { try await ModelManager.shared.restart(rec.model); health.report(nil) }
            catch { health.report(error.localizedDescription) }
            health.restarting = false
        }
    }
}
