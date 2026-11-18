import AppKit
import Foundation
import SwiftUI

// MARK: - Note template (presentation only)

/// The sections the notes model always writes. The template changes how they are shown, named and ordered;
/// it never changes what the model is asked to write, so it cannot break the model.
enum NoteSection: String, CaseIterable, Codable, Identifiable {
    case summary, keyPoints, decisions, actionItems, openQuestions
    var id: String { rawValue }
    var defaultName: String {
        switch self {
        case .summary: return "Summary"
        case .keyPoints: return "Key points"
        case .decisions: return "Decisions"
        case .actionItems: return "Action items"
        case .openQuestions: return "Open questions"
        }
    }
}

struct NoteLayout: Codable, Equatable {
    var order: [NoteSection] = NoteSection.allCases
    var hidden: Set<NoteSection> = []
    var names: [String: String] = [:]

    static let standard = NoteLayout()

    func name(_ s: NoteSection) -> String {
        let custom = names[s.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? s.defaultName : custom
    }

    /// Sections to show, in order. Sections added in a later app version are appended.
    var visible: [NoteSection] {
        (order + NoteSection.allCases.filter { !order.contains($0) }).filter { !hidden.contains($0) }
    }

    /// The saved layout (readable from any thread).
    static var current: NoteLayout {
        guard let data = UserDefaults.standard.data(forKey: "noteLayout"),
              let layout = try? JSONDecoder().decode(NoteLayout.self, from: data) else { return .standard }
        return layout
    }
}

// MARK: - Preferences

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    nonisolated static let instructionsLimit = 300

    @Published var instructions = UserDefaults.standard.string(forKey: "instructions") ?? "" {
        didSet {
            if instructions.count > Prefs.instructionsLimit { instructions = String(instructions.prefix(Prefs.instructionsLimit)) }
            UserDefaults.standard.set(instructions, forKey: "instructions")
        }
    }
    @Published var layout = NoteLayout.current {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(layout), forKey: "noteLayout") }
    }
    @Published var askFeedback = UserDefaults.standard.object(forKey: "askFeedback") as? Bool ?? true {
        didSet { UserDefaults.standard.set(askFeedback, forKey: "askFeedback") }
    }
    @Published var voiceProcessingEnabled = UserDefaults.standard.object(forKey: "voiceProcessingEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceProcessingEnabled, forKey: "voiceProcessingEnabled") }
    }

    /// Instructions as sent to the model: one line, trimmed, capped.
    nonisolated static var instructionsNow: String {
        let raw = UserDefaults.standard.string(forKey: "instructions") ?? ""
        return String(raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(instructionsLimit))
    }
}

// MARK: - Feedback

/// What one rating sends. No audio, no transcript, no account or device ID. `notes` only if the user ticked the box.
struct Feedback: Codable {
    var app = "notes"
    var app_version: String
    var model: String
    var template: String
    var rating: String          // "up" or "down"
    var notes_bad = false       // the notes (the model)
    var app_bad = false         // the app (recording, transcript, speakers, crashes)
    var comment = ""
    var notes: Notes?
}

enum FeedbackSender {
    static var endpoint: URL {
        URL(string: UserDefaults.standard.string(forKey: "feedbackURL") ?? "https://app.inferoid.com/forge/api/v1/feedback")!
    }
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// Ratings that could not be sent yet (offline, or the server was down). Kept on this Mac until they go out.
    static var outbox: URL {
        let dir = InferoidPaths.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feedback-outbox.jsonl")
    }

    static func pending() -> [Data] {
        guard let text = try? String(contentsOf: outbox, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { Data($0.utf8) }
    }

    private static func post(_ body: Data) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200 ..< 300).contains(status) || status == 400  // 400: the server will never accept it; drop it
    }

    /// Saves the rating next to the meeting, then tries to send it and anything still waiting.
    /// Returns true when everything went out.
    @discardableResult
    static func submit(_ item: Feedback, folder: URL?) async -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(item) else { return false }
        if let folder { try? data.write(to: folder.appendingPathComponent("feedback.json")) }
        var queue = pending()
        queue.append(data)
        return await flush(queue)
    }

    @discardableResult
    static func flush(_ items: [Data]? = nil) async -> Bool {
        let queue = items ?? pending()
        var left: [Data] = []
        for body in queue {
            if !(await post(body)) { left.append(body) }
        }
        let text = left.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        if left.isEmpty { try? FileManager.default.removeItem(at: outbox) } else { try? (text + "\n").write(to: outbox, atomically: true, encoding: .utf8) }
        return left.isEmpty
    }
}

/// Shown above the notes after a call: thumbs up sends at once; thumbs down asks what went wrong.
struct FeedbackBar: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject var prefs = Prefs.shared
    @State private var down = false
    @State private var notesBad = false
    @State private var appBad = false
    @State private var comment = ""
    @State private var includeNotes = false
    @State private var stopAsking = false
    @State private var done: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let done {
                Label(done, systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else if !down {
                HStack(spacing: 10) {
                    Text("How were these notes?").font(.body.weight(.medium))
                    Button { send(up: true) } label: { Image(systemName: "hand.thumbsup") }.help("Good notes")
                    Button { down = true } label: { Image(systemName: "hand.thumbsdown") }.help("Something was wrong")
                    Spacer()
                    Button("Don't ask again") { prefs.askFeedback = false; rec.feedbackFor = nil }
                        .buttonStyle(.link).font(.caption)
                    Button { rec.feedbackFor = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Not now")
                }
            } else {
                Text("What went wrong?").font(.body.weight(.medium))
                Toggle("The notes: wrong, missing or made-up points", isOn: $notesBad)
                Toggle("The app: recording, transcript, speakers or a crash", isOn: $appBad)
                TextField("One line about it (optional)", text: $comment).textFieldStyle(.roundedBorder)
                Toggle("Include these notes so we can improve the model (the transcript is never sent)", isOn: $includeNotes)
                    .disabled(!notesBad)
                Toggle("Don't ask again", isOn: $stopAsking)
                HStack {
                    Text("Sent: your rating, the boxes you tick and your line\(includeNotes && notesBad ? ", and these notes" : ""). No audio, no transcript, no account.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Report on GitHub") { NSWorkspace.shared.open(githubIssue()) }
                        .help("Opens a pre-filled public issue in your browser. You review it and submit it yourself; your notes are not included.")
                    Button("Skip") { finish(nil) }
                    Button("Send") { send(up: false) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private func send(up: Bool) {
        let item = Feedback(app_version: FeedbackSender.appVersion, model: Summarizer.displayName(rec.model),
                            template: rec.template.rawValue, rating: up ? "up" : "down",
                            notes_bad: !up && notesBad, app_bad: !up && appBad,
                            comment: up ? "" : String(comment.prefix(280)),
                            notes: !up && notesBad && includeNotes ? rec.notes : nil)
        let folder = rec.savedFolder
        done = "Thanks. Sending…"
        Task {
            let sent = await FeedbackSender.submit(item, folder: folder)
            finish(sent ? "Thanks, sent." : "Thanks. Saved on this Mac; it will be sent when Inferoid can be reached.")
        }
    }

    /// A new-issue page on the public repo, filled in from this form. Never includes the notes or transcript.
    private func githubIssue() -> URL {
        var parts: [String] = []
        if notesBad { parts.append("the notes") }
        if appBad { parts.append("the app") }
        let line = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        var c = URLComponents(string: "https://github.com/inferoid/inferoid/issues/new")!
        c.queryItems = [
            URLQueryItem(name: "template", value: "notes-feedback.yml"),
            URLQueryItem(name: "title", value: "Notes feedback: " + (line.isEmpty ? (parts.isEmpty ? "something went wrong" : parts.joined(separator: " and ")) : String(line.prefix(80)))),
            URLQueryItem(name: "version", value: FeedbackSender.appVersion),
            URLQueryItem(name: "model", value: Summarizer.displayName(rec.model)),
            URLQueryItem(name: "meeting_type", value: rec.template.label),
            URLQueryItem(name: "part", value: parts.isEmpty ? "" : parts.joined(separator: " and ")),
            URLQueryItem(name: "details", value: line),
        ]
        return c.url!
    }

    private func finish(_ message: String?) {
        if stopAsking { prefs.askFeedback = false }
        guard let message else { rec.feedbackFor = nil; return }
        done = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            rec.feedbackFor = nil
        }
    }
}

// MARK: - Settings window (⌘,)

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            InstructionsSettings().tabItem { Label("Instructions", systemImage: "text.bubble") }
            TemplateSettings().tabItem { Label("Note template", systemImage: "list.bullet.rectangle") }
            AudioSettings().tabItem { Label("Audio", systemImage: "waveform") }
            FeedbackSettings().tabItem { Label("Feedback", systemImage: "hand.thumbsup") }
        }
        .frame(width: 560, height: 460)
    }
}

struct AudioSettings: View {
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Suppress call audio in the microphone", isOn: $prefs.voiceProcessingEnabled)
                .toggleStyle(.checkbox)
            Text("Uses macOS voice processing (acoustic echo cancellation) so speaker output is less likely to be transcribed as Me. Turn it off if it makes your microphone sound worse.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
    }
}

struct InstructionsSettings: View {
    @ObservedObject var prefs = Prefs.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Anything your notes should always know or do").font(.headline)
            Text("Added to every meeting's notes. Short facts and focus requests work best, for example: "
                 + "\"I'm Sam from Acme; we sell billing software.\" or \"Always note pricing and dates.\"")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $prefs.instructions)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            HStack {
                Label("Experimental. The notes model was trained on a fixed set of meeting types; it may not follow every instruction. "
                      + "It always writes the same sections; change how they look in Note template.",
                      systemImage: "flask")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("\(prefs.instructions.count)/\(Prefs.instructionsLimit)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}

struct TemplateSettings: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Meeting type").font(.headline)
                Spacer()
                Picker("", selection: $rec.template) {
                    ForEach(Template.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Text("Sections: drag to reorder, rename, or untick to hide. Applies to new notes, copies and saved files.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(prefs.layout.order) { s in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Toggle("", isOn: shown(s)).labelsHidden().toggleStyle(.checkbox)
                        TextField(s.defaultName, text: name(s)).textFieldStyle(.roundedBorder)
                    }
                }
                .onMove { from, to in prefs.layout.order.move(fromOffsets: from, toOffset: to) }
            }
            .frame(minHeight: 190)
            HStack {
                Button("Add a custom section") {}.disabled(true)
                Text("Needs a model update").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to default") { prefs.layout = .standard }
            }
        }
        .padding(20)
    }

    private func shown(_ s: NoteSection) -> Binding<Bool> {
        Binding(get: { !prefs.layout.hidden.contains(s) },
                set: { on in if on { prefs.layout.hidden.remove(s) } else { prefs.layout.hidden.insert(s) } })
    }

    private func name(_ s: NoteSection) -> Binding<String> {
        Binding(get: { prefs.layout.names[s.rawValue] ?? "" },
                set: { prefs.layout.names[s.rawValue] = String($0.prefix(40)) })
    }
}

struct FeedbackSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var waiting = FeedbackSender.pending().count
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Ask how the notes were after each call", isOn: $prefs.askFeedback).toggleStyle(.checkbox)
            Text("A thumbs up or down, which part went wrong (the notes or the app) and one optional line. "
                 + "No audio, no transcript, no account. The notes themselves are sent only when you tick that box.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Every rating is also saved next to its meeting as feedback.json.").font(.caption).foregroundStyle(.secondary)
            if waiting > 0 {
                HStack {
                    Text("\(waiting) rating\(waiting == 1 ? "" : "s") waiting to send").font(.caption)
                    Button(sending ? "Sending…" : "Send now") {
                        sending = true
                        Task {
                            await FeedbackSender.flush()
                            waiting = FeedbackSender.pending().count
                            sending = false
                        }
                    }
                    .disabled(sending)
                }
            }
            Spacer()
        }
        .padding(20)
    }
}
