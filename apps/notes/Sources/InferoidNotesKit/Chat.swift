import AppKit
import Foundation
import SwiftUI

// MARK: - Model

/// An action the model asked to run; it runs only after the user approves it.
public struct ChatAction: Codable, Hashable {
    public var tool: String
    public var args: [String: String]
    /// "proposed", "running", "done", "cancelled", "failed"
    public var state: String
}

public struct ChatMessage: Identifiable, Codable, Hashable {
    public var id: UUID
    /// "user", "assistant" or "tool" (an approved action's result)
    public var role: String
    public var text: String
    /// Meeting ids (folder paths) the answer drew on.
    public var sources: [String]
    public var action: ChatAction?
    public var date: Date

    init(role: String, text: String, sources: [String] = [], action: ChatAction? = nil) {
        self.id = UUID(); self.role = role; self.text = text; self.sources = sources; self.action = action; self.date = Date()
    }
}

public struct ChatThread: Identifiable, Codable, Hashable {
    public var id: UUID
    public var title: String
    public var created: Date
    public var updated: Date
    public var messages: [ChatMessage]

    init() {
        id = UUID(); title = "New chat"; created = Date(); updated = Date(); messages = []
    }
}

// MARK: - Store

/// Conversations, saved as one JSON file per chat in Application Support/<data folder>/Chats. Nothing leaves the Mac.
@MainActor
public final class ChatStore: ObservableObject {
    public static let shared = ChatStore()

    @Published public private(set) var threads: [ChatThread] = []
    @Published public private(set) var busyThread: UUID?
    @Published public var error: String?
    private var task: Task<Void, Never>?

    private var folder: URL { InferoidPaths.support.appendingPathComponent("Chats", isDirectory: true) }

    init() { load() }

    func load() {
        let fm = FileManager.default
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var loaded: [ChatThread] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let thread = try? decoder.decode(ChatThread.self, from: data), !thread.messages.isEmpty {
                loaded.append(thread)
            }
        }
        threads = loaded.sorted { $0.updated > $1.updated }
    }

    func thread(_ id: UUID) -> ChatThread? { threads.first { $0.id == id } }

    /// A new, empty chat (saved once it has a message).
    func newThread() -> UUID {
        if let empty = threads.first(where: { $0.messages.isEmpty }) { return empty.id }
        let t = ChatThread()
        threads.insert(t, at: 0)
        return t.id
    }

    func rename(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].title = clean
        save(threads[i])
    }

    func delete(_ id: UUID) {
        threads.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id.uuidString + ".json"))
    }

    private func save(_ thread: ThreadSnapshot) {
        guard !thread.messages.isEmpty else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(thread) {
            try? data.write(to: folder.appendingPathComponent(thread.id.uuidString + ".json"), options: .atomic)
        }
    }

    private func update(_ id: UUID, _ change: (inout ChatThread) -> Void) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[i])
        threads[i].updated = Date()
    }

    func stop() {
        task?.cancel()
        task = nil
        busyThread = nil
    }

    /// Sends `text` in chat `id`: grounds it on matching meetings, streams the reply, and turns an ```action block into
    /// an approval card.
    func send(_ text: String, in id: UUID, model: String, meetings: [Meeting]) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, busyThread == nil, let before = thread(id) else { return }
        error = nil
        let history = before.messages
        let hits = Brain.search(question, in: meetings, limit: 4)
        let reply = ChatMessage(role: "assistant", text: "", sources: hits.map { $0.meeting.id })
        update(id) { t in
            if t.messages.isEmpty { t.title = String(question.prefix(60)) }
            t.messages.append(ChatMessage(role: "user", text: question))
            t.messages.append(reply)
        }
        busyThread = id
        let system = Self.systemPrompt(tools: InferoidExtensions.chatTools)
        let user = Self.userPrompt(question: question, history: history, hits: hits)
        let replyID = reply.id
        task = Task { @MainActor in
            do {
                if ModelManager.shared.manages(model) { self.setText(id, replyID, "Loading the model…") }
                try await ModelManager.shared.ensure(model)
                self.setText(id, replyID, "")
                let answer = try await Summarizer.complete(system: system, user: user, model: model, maxTokens: 1500) { partial in
                    Task { @MainActor in ChatStore.shared.setText(id, replyID, Self.visibleText(partial)) }
                }
                let parsed = Self.parseAction(answer)
                self.update(id) { t in
                    if let i = t.messages.firstIndex(where: { $0.id == replyID }) {
                        t.messages[i].text = parsed.text.isEmpty && parsed.action != nil ? "I can do that." : parsed.text
                        if let action = parsed.action {
                            if InferoidExtensions.tool(named: action.tool) != nil {
                                t.messages[i].action = action
                            } else {
                                t.messages[i].text += "\n\n(This action is not available in this app.)"
                            }
                        }
                    }
                }
            } catch {
                if Task.isCancelled {
                    let partial = self.thread(id)?.messages.first(where: { $0.id == replyID })?.text ?? ""
                    self.setText(id, replyID, partial.isEmpty ? "Stopped." : partial + " [stopped]")
                } else {
                    self.update(id) { t in t.messages.removeAll { $0.id == replyID && $0.text.isEmpty } }
                    self.error = error.localizedDescription
                }
            }
            ModelManager.shared.idle()
            if let t = self.thread(id) { self.save(t) }
            self.busyThread = nil
            self.task = nil
        }
    }

    func setText(_ thread: UUID, _ message: UUID, _ text: String) {
        update(thread) { t in
            if let i = t.messages.firstIndex(where: { $0.id == message }) { t.messages[i].text = text }
        }
    }

    /// Runs the approved action and shows its result in the chat.
    func approve(_ message: UUID, in id: UUID) {
        guard let msg = thread(id)?.messages.first(where: { $0.id == message }), var action = msg.action,
              action.state == "proposed", let tool = InferoidExtensions.tool(named: action.tool) else { return }
        action.state = "running"
        setAction(id, message, action)
        Task { @MainActor in
            var done = action
            var result: String
            do {
                result = try await tool.handler(action.args)
                done.state = "done"
            } catch {
                result = "That did not work: \(error.localizedDescription)"
                done.state = "failed"
            }
            self.setAction(id, message, done)
            self.update(id) { t in t.messages.append(ChatMessage(role: "tool", text: result)) }
            if let t = self.thread(id) { self.save(t) }
        }
    }

    func cancel(_ message: UUID, in id: UUID) {
        guard var action = thread(id)?.messages.first(where: { $0.id == message })?.action, action.state == "proposed" else { return }
        action.state = "cancelled"
        setAction(id, message, action)
        if let t = thread(id) { save(t) }
    }

    private func setAction(_ thread: UUID, _ message: UUID, _ action: ChatAction) {
        update(thread) { t in
            if let i = t.messages.firstIndex(where: { $0.id == message }) { t.messages[i].action = action }
        }
    }

    // MARK: Prompts

    static func systemPrompt(tools: [ChatTool]) -> String {
        var s = """
        You are the user's private assistant. You run entirely on their Mac; nothing they type leaves it.
        Be direct, helpful and brief. When meeting excerpts are given, use them and cite the meeting like [Title, 2026-11-14].
        Never invent meeting details. If you do not know, say so.
        """
        if !tools.isEmpty {
            s += "\n\nYou can ask to run ONE of these actions when the user wants it done. Say in one sentence what you will do, "
            s += "then add a block exactly like this (the user must approve it before it runs):\n"
            s += "```action\n{\"tool\": \"<tool name>\", \"args\": {\"<argument>\": \"<value>\"}}\n```\nActions:\n"
            for tool in tools {
                s += "- \(tool.name): \(tool.description) Arguments: \(tool.argumentsHint)\n"
            }
            s += "Only use an action when the user asks for something it does. Never claim an action ran before you see its result."
        }
        return s
    }

    static func userPrompt(question: String, history: [ChatMessage], hits: [Hit]) -> String {
        var s = ""
        let recent = history.suffix(8)
        if !recent.isEmpty {
            s += "Conversation so far:\n"
            for m in recent {
                let who = m.role == "user" ? "User" : (m.role == "tool" ? "Action result" : "Assistant")
                s += "\(who): \(String(m.text.prefix(1500)))\n"
            }
            s += "\n"
        }
        if !hits.isEmpty {
            s += "Meeting excerpts that may help:\n" + Brain.context(for: question, hits: hits, budget: 12_000) + "\n"
        }
        if let fact = letterCountFact(question) { s += fact + "\n" }
        s += "User: " + question
        return s
    }

    /// Small models read word pieces, not letters, so they miscount letters ("no r's in strawberry"). Count them in
    /// code and hand the model the exact answer.
    nonisolated static func letterCountFact(_ question: String) -> String? {
        let pattern = #"(?i)\b(?:how\s+many|count|number\s+of)\b.*?(?<![a-z'])(['"]?)([a-z])\1('s|s)?(?![a-z]).*?\b(?:in|does|of)\s+(?:the\s+word\s+)?['"]?([a-z]{2,})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)),
              let q = Range(m.range(at: 1), in: question), let l = Range(m.range(at: 2), in: question),
              let w = Range(m.range(at: 4), in: question) else { return nil }
        let letter = question[l].lowercased(), word = question[w].lowercased()
        let quoted = !question[q].isEmpty, plural = m.range(at: 3).location != NSNotFound
        if (letter == "i" || letter == "a") && !quoted && !plural { return nil }  // "did I have", "a meeting"
        let count = word.filter { String($0) == letter }.count
        let spelled = word.map(String.init).joined(separator: "-")
        return "Checked by code (exact): \"\(word)\" is spelled \(spelled) and has \(count) letter \"\(letter)\". Use this count."
    }

    /// While streaming, hide a half-written action block.
    static func visibleText(_ text: String) -> String {
        if let r = text.range(of: "```action") { return String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
    }

    /// Splits the reply into the text to show and the requested action, if any.
    static func parseAction(_ text: String) -> (text: String, action: ChatAction?) {
        guard let start = text.range(of: "```action") else { return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
        let after = text[start.upperBound...]
        let end = after.range(of: "```")
        let json = String(end.map { after[..<$0.lowerBound] } ?? after).trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = String(text[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = object["tool"] as? String else { return (shown, nil) }
        var args: [String: String] = [:]
        if let raw = object["args"] as? [String: Any] {
            for (key, value) in raw { args[key] = "\(value)" }
        }
        return (shown, ChatAction(tool: tool, args: args, state: "proposed"))
    }
}

typealias ThreadSnapshot = ChatThread

// MARK: - View

struct ChatView: View {
    @EnvironmentObject var rec: Recorder
    @ObservedObject var store = ChatStore.shared
    let threadID: UUID
    var openMeeting: (String) -> Void
    @State private var draft = ""

    var body: some View {
        let thread = store.thread(threadID)
        let busy = store.busyThread == threadID
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if thread?.messages.isEmpty ?? true {
                            EmptyChat(meetingCount: rec.meetings.count, hasTools: !InferoidExtensions.chatTools.isEmpty) { draft = $0 }
                        }
                        ForEach(thread?.messages ?? []) { message in
                            MessageRow(message: message, busy: busy, meetings: rec.meetings, openMeeting: openMeeting,
                                       approve: { store.approve(message.id, in: threadID) },
                                       cancel: { store.cancel(message.id, in: threadID) })
                                .id(message.id)
                        }
                        if let error = store.error, !busy {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 28).padding(.vertical, 20)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: thread?.messages.last?.text ?? "") { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: thread?.messages.count ?? 0) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Inferoid", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .onSubmit(send)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
                if busy {
                    Button { store.stop() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.bordered).controlSize(.large).help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busyThread != nil || rec.isWriting)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (Return)")
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            .frame(maxWidth: 836)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(thread?.title ?? "Chat")
        .onAppear { rec.reloadMeetings() }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.busyThread == nil, !rec.isWriting else { return }
        draft = ""
        store.send(text, in: threadID, model: rec.model, meetings: rec.meetings)
    }
}

struct EmptyChat: View {
    let meetingCount: Int
    let hasTools: Bool
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What can I help with?").font(.title2.bold())
            Text(meetingCount > 0
                 ? "Ask anything. I also search your \(meetingCount) saved meetings and cite them. Everything stays on this Mac."
                 : "Ask anything. After you record meetings, I can search them too. Everything stays on this Mac.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { pick(s) } label: {
                        Text(s).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 40)
    }

    private var suggestions: [String] {
        var out = ["What can you do on this Mac?"]
        if meetingCount > 0 { out.append("What did we agree on in my last meeting?"); out.append("List my open action items from this week's meetings") }
        if hasTools { out.append("Create a workflow that classifies intake sheets in my Desktop/intake folder") }
        return out
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let busy: Bool
    let meetings: [Meeting]
    let openMeeting: (String) -> Void
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 80)
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.16)))
            }
        } else if message.role == "tool" {
            Label(message.text, systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if message.text.isEmpty && busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(rendered(message.text)).textSelection(.enabled)
                }
                let cited = message.sources.compactMap { id in meetings.first { $0.id == id } }
                if !cited.isEmpty && !message.text.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary)
                        ForEach(cited) { m in
                            Button(m.title) { openMeeting(m.id) }
                                .buttonStyle(.link).font(.caption).lineLimit(1)
                        }
                    }
                }
                if let action = message.action {
                    ActionCard(action: action, approve: approve, cancel: cancel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct ActionCard: View {
    let action: ChatAction
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Action: \(action.tool.replacingOccurrences(of: "_", with: " "))", systemImage: "bolt.horizontal.circle")
                .font(.headline)
            ForEach(action.args.keys.sorted(), id: \.self) { key in
                Text("\(key): \(action.args[key] ?? "")").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            switch action.state {
            case "proposed":
                HStack {
                    Button("Approve", action: approve).buttonStyle(.borderedProminent)
                    Button("Cancel", action: cancel)
                    Text("Nothing runs until you approve.").font(.caption).foregroundStyle(.secondary)
                }
            case "running":
                ProgressView().controlSize(.small)
            case "done":
                Label("Done", systemImage: "checkmark").foregroundStyle(.green)
            case "cancelled":
                Text("Cancelled").foregroundStyle(.secondary)
            default:
                Text("Failed").foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.4)))
    }
}
