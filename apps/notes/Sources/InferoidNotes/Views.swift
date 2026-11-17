import AppKit
import SwiftUI

/// What the main window shows: home (all meetings), chat across meetings, the meeting in progress, or a saved meeting.
enum Pane: Hashable {
    case home, chat, live
    case meeting(String)
}

struct MainView: View {
    @EnvironmentObject var rec: Recorder
    @State private var pane: Pane? = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Label("Home", systemImage: "house").tag(Pane.home)
                Label("Chat", systemImage: "bubble.left.and.bubble.right").tag(Pane.chat)
                if rec.isRecording || rec.isWriting || !rec.lines.isEmpty {
                    Section("Now") {
                        Label(liveLabel, systemImage: rec.isRecording ? "record.circle" : "waveform")
                            .foregroundStyle(rec.isRecording ? Color.red : Color.primary)
                            .tag(Pane.live)
                    }
                }
                if !rec.meetings.isEmpty {
                    Section("Recent") {
                        ForEach(rec.meetings.prefix(10)) { m in
                            Text(m.title).lineLimit(1).tag(Pane.meeting(m.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Image(systemName: rec.online ? "lock.fill" : "airplane")
                    Text(rec.online ? "Everything runs on this Mac" : "Offline. Everything runs on this Mac")
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }
                        .buttonStyle(.plain)
                        .help("Settings: instructions, note template, feedback (⌘,)")
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } detail: {
            switch pane ?? .home {
            case .home: HomeView(pane: $pane)
            case .chat: AskView(open: { pane = .meeting($0.id) })
            case .live: LiveMeetingView()
            case .meeting(let id):
                if let m = rec.meetings.first(where: { $0.id == id }) { MeetingView(meeting: m) } else { HomeView(pane: $pane) }
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
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(rec.isWriting)
            }
        }
        .frame(minWidth: 780, minHeight: 540)
        .onAppear { rec.reloadMeetings() }
        .onChange(of: rec.isRecording) { _, on in if on { pane = .live } }
    }

    private var liveLabel: String {
        if rec.isRecording { return "Recording  \(clock(rec.elapsed))" }
        return rec.isWriting ? "Writing notes…" : "Last meeting"
    }
}

// MARK: - Home

struct HomeView: View {
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
                    Text("Your meetings will appear here. Notes are plain files in ~/Documents/Inferoid Notes.")
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
        .navigationTitle("Home")
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
                            NSPasteboard.general.setString(notesMarkdown(n), forType: .string)
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
    let meeting: Meeting
    @State private var tab = 0

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
                    NSPasteboard.general.setString(tab == 0 ? meeting.notes : meeting.transcript, forType: .string)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
            Divider()
            ScrollView {
                let text = tab == 0 ? meeting.notes : meeting.transcript
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

// MARK: - Chat across all meetings

struct AskView: View {
    @EnvironmentObject var rec: Recorder
    var open: (Meeting) -> Void = { NSWorkspace.shared.open($0.folder.appendingPathComponent("notes.md")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask your meetings").font(.title2.bold())
            HStack {
                TextField("Search your meetings, or ask a question", text: $rec.askQuery)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .onSubmit { rec.ask() }
                Button("Ask") { rec.ask() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(rec.askQuery.trimmingCharacters(in: .whitespaces).isEmpty || rec.askBusy || rec.isWriting)
                if rec.askBusy { ProgressView().controlSize(.small) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !rec.askAnswer.isEmpty {
                        Text(rec.askAnswer).textSelection(.enabled)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
                    }
                    let hits = rec.askSources.isEmpty ? rec.searchHits : rec.askSources
                    if !hits.isEmpty {
                        Text(rec.askSources.isEmpty ? "Matching meetings" : "Answered from").font(.headline).padding(.top, 4)
                    }
                    ForEach(hits) { hit in
                        Button { open(hit.meeting) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(hit.meeting.title).font(.body.weight(.medium))
                                    Spacer()
                                    Text(dayLabel(hit.meeting.date)).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if rec.askQuery.isEmpty && rec.askAnswer.isEmpty {
                        Text(rec.meetings.isEmpty ? "Your saved meetings will be searchable here."
                             : "\(rec.meetings.count) meetings on this Mac. Ask things like \"what did we agree on pricing?\" Answers cite the meeting.")
                            .foregroundStyle(.secondary).padding(.top, 20)
                    }
                    if let error = rec.error, !rec.askBusy, error.hasPrefix("Ask") {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Chat")
        .onAppear { rec.reloadMeetings() }
    }
}

struct MenuContent: View {
    @EnvironmentObject var rec: Recorder
    @Environment(\.openWindow) private var openWindow
    var body: some View {
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
