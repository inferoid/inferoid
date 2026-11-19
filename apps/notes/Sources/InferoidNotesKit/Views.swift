import AppKit
import SwiftUI

/// What the main window shows: the status page, the meeting list, a chat, the meeting in progress, a saved meeting, or an
/// extension's tab.
enum Pane: Hashable {
    case home, meetings, newChat, live
    case chat(UUID)
    case extensionTab(String)
    case meeting(String)
}

@MainActor
public struct MainView: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject private var chats = ChatStore.shared
    @State private var pane: Pane? = .home
    @State private var renaming: UUID?
    @State private var renameText = ""

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Label("New chat", systemImage: "square.and.pencil").tag(Pane.newChat)
                Label("Home", systemImage: "house").tag(Pane.home)
                Label("Meetings", systemImage: "person.2.wave.2").tag(Pane.meetings)
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
                let saved = chats.threads.filter { !$0.messages.isEmpty }
                if !saved.isEmpty {
                    Section("Chats") {
                        ForEach(saved) { thread in
                            Text(thread.title).lineLimit(1).tag(Pane.chat(thread.id))
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
                        Image(systemName: rec.online ? "lock.fill" : "airplane")
                        Text(rec.online ? "Everything runs on this Mac" : "Offline. Everything runs on this Mac")
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
            switch pane ?? .home {
            case .home: HomeStatusView(pane: $pane)
            case .meetings: MeetingsView(pane: $pane)
            case .newChat: ProgressView()
            case .chat(let id): ChatView(threadID: id, openMeeting: { pane = .meeting($0) }).id(id)
            case .live: LiveMeetingView()
            case .extensionTab(let id):
                if let view = InferoidExtensions.view(for: id) { view } else { Text("This tab is no longer available") }
            case .meeting(let id):
                if let m = rec.meetings.first(where: { $0.id == id }) { MeetingView(meeting: m) } else { MeetingsView(pane: $pane) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    rec.toggle()
                    pane = .live
                } label: {
                    Label(rec.isRecording ? "Stop" : "Start meeting", systemImage: rec.isRecording ? "stop.fill" : "mic.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(rec.isRecording ? .red : .accentColor)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(rec.isWriting)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { rec.reloadMeetings() }
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
}

// MARK: - Home: status

struct HomeStatusView: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject private var chats = ChatStore.shared
    @Binding var pane: Pane?
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Home").font(.largeTitle.bold())
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
                        Button(testing ? "Testing…" : "Test model") { test() }.disabled(testing || rec.isWriting)
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
    }

    private var savedChats: Int { chats.threads.filter { !$0.messages.isEmpty }.count }

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

struct MeetingsView: View {
    @EnvironmentObject var rec: Recorder
    @Binding var pane: Pane?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
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
                                Button { pane = .meeting(m.id) } label: { MeetingRow(meeting: m) }
                                    .buttonStyle(.plain)
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
        .navigationTitle("Meetings")
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
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
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
    @State private var tab = 0
    @State private var transcriptText = ""
    @State private var renameSpeaker = ""
    @State private var isRenaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title).font(.title.bold()).textSelection(.enabled)
                Text(dayLabel(meeting.date) + "  ·  " + timeLabel(meeting)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.top, 20)
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
