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
    /// For a user message: exactly what the model was sent for this turn (records + question). Later turns resend it
    /// unchanged so the server's cache still matches. Missing in chats saved before 0.7.
    public var prompt: String?
    /// Fingerprint of each source's text when it was sent, so a source edited later is sent again (automatic resync).
    public var sourceHashes: [String: String]?

    init(role: String, text: String, sources: [String] = [], action: ChatAction? = nil, prompt: String? = nil) {
        self.id = UUID(); self.role = role; self.text = text; self.sources = sources; self.action = action; self.date = Date()
        self.prompt = prompt
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
    private var prefetchTask: Task<Void, Never>?
    private var prefetchKey = ""

    /// Brain chat replies are short chat messages: the first word in under a second, the whole answer in a few seconds.
    static let replyTokens = 500
    static let shortReply = "\n\nReply like a chat message: answer first, at most 120 words, cite the meetings you use."
    /// Records per turn. On the 12 Brain questions (11-23), cutting the records to 6,000 characters lost the key facts
    /// for every model; with full records Inkling scored 67.5 vs E4B 46.0. So the budget stays; reading the records
    /// while the user types hides the time.
    static let evidenceBudget = 12_000
    /// Oldest turns are dropped once the thread passes this (~10K tokens), leaving room for the reply.
    static let threadBudget = 40_000

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
        ensureAssistantThread()
    }

    // MARK: Assistant chat

    @Published private(set) var profile = AssistantProfile.load()

    /// The assistant's own chat always exists and opens with its introduction.
    private func ensureAssistantThread() {
        guard !threads.contains(where: { $0.id == AssistantIntro.threadID }) else { return }
        var thread = ChatThread()
        thread.id = AssistantIntro.threadID
        thread.title = profile.isOnboarded ? profile.displayName : "Assistant"
        thread.messages = [ChatMessage(role: "assistant", text: AssistantIntro.opening)]
        threads.append(thread)
        save(thread)
    }

    var assistantThread: ChatThread? { thread(AssistantIntro.threadID) }

    /// Assistant messages the user has not opened yet (the sidebar badge).
    func unreadCount(_ id: UUID) -> Int {
        guard let t = thread(id) else { return 0 }
        let seen = UserDefaults.standard.integer(forKey: "chat.seen." + id.uuidString)
        return t.messages.dropFirst(min(seen, t.messages.count)).filter { $0.role == "assistant" && !$0.text.isEmpty }.count
    }

    func markSeen(_ id: UUID) {
        guard let t = thread(id) else { return }
        let key = "chat.seen." + id.uuidString
        if UserDefaults.standard.integer(forKey: key) != t.messages.count {
            UserDefaults.standard.set(t.messages.count, forKey: key)
            objectWillChange.send()
        }
    }

    /// Renames the assistant and changes its emoji (the pencil on its row).
    func updateIdentity(name: String, emoji: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty { profile.assistantName = cleanName }
        if let picked = AssistantIntro.firstEmoji(in: emoji) { profile.emoji = picked }
        profile.save()
        update(AssistantIntro.threadID) { $0.title = profile.displayName }
        if let t = thread(AssistantIntro.threadID) { save(t) }
    }

    /// Clears the assistant's conversation but keeps who it is and what it knows about the user.
    func startFreshAssistantChat() {
        guard profile.isOnboarded else { restartIntro(); return }
        update(AssistantIntro.threadID) { t in
            t.messages = [ChatMessage(role: "assistant", text: "Fresh start, \(profile.callMe.isEmpty ? "there" : profile.callMe)\((profile.useEmoji ?? true) ? " \(profile.displayEmoji)" : ""). What's on your mind?")]
        }
        if let t = thread(AssistantIntro.threadID) { save(t) }
        UserDefaults.standard.set(1, forKey: "chat.seen." + AssistantIntro.threadID.uuidString)
    }

    /// Starts the introduction again (from the assistant chat's menu).
    func restartIntro() {
        profile = AssistantProfile(); profile.save()
        threads.removeAll { $0.id == AssistantIntro.threadID }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(AssistantIntro.threadID.uuidString + ".json"))
        UserDefaults.standard.removeObject(forKey: "chat.seen." + AssistantIntro.threadID.uuidString)
        ensureAssistantThread()
    }

    /// During the introduction the replies are scripted, so they are instant and never depend on the model.
    private func answerIntro(_ text: String, in id: UUID, meetings: [Meeting]) {
        var next = profile
        let reply = AssistantIntro.answer(text, profile: &next, saved: Self.savedTitles(meetings: meetings))
        profile = next; profile.save()
        update(id) { t in
            t.messages.append(ChatMessage(role: "user", text: text))
            t.messages.append(ChatMessage(role: "assistant", text: reply))
            t.title = profile.displayName
        }
        if let t = thread(id) { save(t) }
    }

    func thread(_ id: UUID) -> ChatThread? { threads.first { $0.id == id } }

    /// A new, empty chat (saved once it has a message).
    func newThread(id requestedID: UUID? = nil) -> UUID {
        if let requestedID {
            if threads.contains(where: { $0.id == requestedID }) { return requestedID }
            var requested = ChatThread(); requested.id = requestedID; threads.insert(requested, at: 0); return requestedID
        }
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
        guard id != AssistantIntro.threadID else { restartIntro(); return }
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

    /// Sends `text` in chat `id`: grounds it on matching local sources, streams the reply, and turns an ```action block into
    /// an approval card.
    func send(_ text: String, in id: UUID, model: String, meetings: [Meeting], projects: [Project] = [], project: Project? = nil, person: String? = nil) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, busyThread == nil, let before = thread(id) else { return }
        error = nil
        if id == AssistantIntro.threadID, !profile.isOnboarded { answerIntro(question, in: id, meetings: meetings); return }
        if profile.isOnboarded, let emoji = AssistantIntro.emojiPreference(in: question) { profile.useEmoji = emoji; profile.save() }
        let history = before.messages
        // In a chat about a person, "what does he like?" still searches for that person.
        let evidenceResult = Self.evidence(for: person.map { question + " " + $0 } ?? question, history: history, meetings: meetings, projects: projects, project: project)
        let sourceHits = evidenceResult.sourceHits
        let evidence = evidenceResult.text
        let turnPrompt = evidence + Self.question(question)
        var reply = ChatMessage(role: "assistant", text: "", sources: sourceHits.map(\.sourceID))
        reply.sourceHashes = evidenceResult.hashes.filter { id, _ in sourceHits.contains { $0.sourceID == id } }
        update(id) { t in
            if t.messages.isEmpty { t.title = String(question.prefix(50)) }
            t.messages.append(ChatMessage(role: "user", text: question, prompt: turnPrompt))
            t.messages.append(reply)
        }
        busyThread = id
        let system = Self.systemPrompt(tools: InferoidExtensions.chatTools, project: project, person: person)
        let turns = Self.turns(history) + [ChatTurn(role: "user", text: turnPrompt)]
        let replyID = reply.id
        // A read started while typing that covers the same records finishes first (the server has one slot); any other
        // is stale and stops.
        let pending = prefetchKey == Self.prefetchKey(model, history, evidence) ? prefetchTask : nil
        if pending == nil { prefetchTask?.cancel() }
        prefetchTask = nil; prefetchKey = ""
        task = Task { @MainActor in
            do {
                if ModelManager.shared.manages(model) { self.setText(id, replyID, "Loading the model…") }
                try await ModelManager.shared.ensure(model)
                await pending?.value
                self.setText(id, replyID, "")
                var answer = ""
                let followUp = Self.webFollowUp(question, history: history)
                if let followUp, let researched = try await self.research(question: question, answer: "", history: history, turnPrompt: turnPrompt,
                                                                          system: system, model: model, thread: id, reply: replyID, followUp: followUp) {
                    answer = researched
                } else {
                    // A refusal ("I can't summarize…") is hidden as soon as it starts: the app will look it up instead.
                    let hideRefusals = ResearchPrefs.enabled && person == nil && !Self.asksAboutUser(question) && Research.wantsWorldFacts(question)
                    answer = try await Summarizer.chat(system: system, turns: turns, model: model, maxTokens: Self.replyTokens) { partial in
                        Task { @MainActor in
                            let visible = Self.visibleText(partial)
                            ChatStore.shared.setText(id, replyID, hideRefusals && Research.declined(visible) ? Self.checkingOnline : visible)
                        }
                    }
                    if let researched = try await self.research(question: question, answer: answer, history: history, turnPrompt: turnPrompt,
                                                                system: system, model: model, thread: id, reply: replyID,
                                                                autoSearch: person == nil) {
                        answer = researched
                    }
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

    static let checkingOnline = "Good question, let me check online…"

    /// When the reply asked for a search, or said the records don't have it, look the question up (Wikipedia first),
    /// read the top pages and answer again from them. Returns nil when no research was done.
    /// "tell me more" right after a web answer: search the same subject again for pages not used yet.
    static func webFollowUp(_ question: String, history: [ChatMessage]) -> (query: String, used: Set<String>)? {
        guard ResearchPrefs.enabled, Research.isFollowUp(question),
              let last = history.last(where: { $0.role == "assistant" }),
              let query = last.sources.first(where: { $0.hasPrefix("webquery|") }).map({ String($0.dropFirst(9)) }) else { return nil }
        let used = Set(history.flatMap(\.sources).compactMap { ResearchPage.parse(sourceID: $0)?.url.absoluteString })
        return (query, used)
    }

    private func research(question: String, answer: String, history: [ChatMessage], turnPrompt: String, system: String,
                          model: String, thread id: UUID, reply replyID: UUID,
                          followUp: (query: String, used: Set<String>)? = nil, autoSearch: Bool = true) async throws -> String? {
        guard ResearchPrefs.enabled, !Self.asksAboutUser(question) else { return nil }
        let asked = Research.searchRequest(in: answer)
        // Searching after a reply that hedged is only for questions about the world; a judgement call keeps its answer.
        let fallback = autoSearch && Research.wantsWorldFacts(question) && (Research.declined(answer) || Research.citesWebWithoutSearch(answer))
        guard followUp != nil || asked != nil || fallback else {
            Research.log(["question": question, "firstReply": String(answer.prefix(200)), "decision": "answered without searching"])
            return nil
        }
        // Search words come from the question (or the model's own search block), never from a model-written sentence.
        let items = CollectionStore.brainItems()
        let query = followUp?.query ?? Research.enrich(asked ?? Research.query(from: question), question: question, items: items)
        guard !query.isEmpty else { return nil }
        setText(id, replyID, Self.checkingOnline)
        let pages = await Research.search(query, excluding: followUp?.used ?? [])
        Research.log(["question": question, "firstReply": String(answer.prefix(400)),
                      "queryFrom": followUp != nil ? "follow-up" : (asked != nil ? "model search block" : "question"),
                      "query": query, "engine": pages.first?.engine ?? "none",
                      "pages": pages.map { ["title": $0.title, "url": $0.url.absoluteString, "chars": $0.text.count] }])
        guard !pages.isEmpty else {
            return asked != nil ? "I looked online for \"\(query)\" but couldn't find a good page on it." : nil
        }
        update(id) { t in if let i = t.messages.firstIndex(where: { $0.id == replyID }) { t.messages[i].sources = pages.map(\.sourceID) + ["webquery|" + query] } }
        let paragraphs = Research.paragraphs(style: profile.style)
        let followUp = Research.evidence(pages, query: query)
            + "\nUsing these pages, answer the user's question: \(question)\n"
            + "Write \(paragraphs == 1 ? "one short paragraph" : "two short paragraphs"), citing pages inline as [Web: page title] (the app shows them as links, so don't list them again at the end). "
            + "Use only what the pages say; if they are thin, say less rather than adding claims. Do not mention the user's records."
            + (followUp != nil ? " The user asked for more: add new points, don't repeat your previous answer." : "")
        setText(id, replyID, "")
        return try await Summarizer.chat(system: system, turns: Self.turns(history) + [ChatTurn(role: "user", text: turnPrompt + "\n\n" + followUp)],
                                         model: model, maxTokens: Self.replyTokens) { partial in
            Task { @MainActor in ChatStore.shared.setText(id, replyID, Self.visibleText(partial)) }
        }
    }

    /// Called as the user types (debounced): retrieves the records for the draft and has the model read the thread plus
    /// those records, so the reply to the finished question starts at once.
    func prefetch(_ draft: String, in id: UUID, model: String, meetings: [Meeting], projects: [Project] = [], project: Project? = nil, person: String? = nil) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8, busyThread == nil, ModelManager.shared.manages(model), let t = thread(id) else { return }
        let evidence = Self.evidence(for: person.map { text + " " + $0 } ?? text, history: t.messages, meetings: meetings, projects: projects, project: project).text
        let key = Self.prefetchKey(model, t.messages, evidence)
        guard key != prefetchKey else { return }
        prefetchTask?.cancel()
        prefetchKey = key
        let system = Self.systemPrompt(tools: InferoidExtensions.chatTools, project: project, person: person)
        let turns = Self.turns(t.messages) + [ChatTurn(role: "user", text: evidence)]
        prefetchTask = Task { @MainActor in
            do { try await ModelManager.shared.ensure(model) } catch { return }
            guard !Task.isCancelled else { return }
            await Summarizer.prefillChat(system: system, turns: turns, model: model)
            ModelManager.shared.idle()
        }
    }

    /// Loads the chat model when a chat opens, so the first question does not wait for it.
    func warm(model: String) {
        guard ModelManager.shared.manages(model), busyThread == nil else { return }
        Task { @MainActor in
            try? await ModelManager.shared.ensure(model)
            ModelManager.shared.idle()
        }
    }

    private static func prefetchKey(_ model: String, _ history: [ChatMessage], _ evidence: String) -> String {
        "\(model)|\(history.count)|\(history.last?.id.uuidString ?? "")|\(evidence.hashValue)"
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

    static func systemPrompt(tools: [ChatTool], project: Project? = nil, person: String? = nil) -> String {
        var s = """
        You are a private assistant on the user's Mac for notes and questions about their own records. Nothing they type leaves it.
        Be direct, helpful and brief. Use local excerpts only when they answer the user's question. Cite a source like [Meeting: Title, 2026-11-14] or [Project: Name · file.md].
        Never invent record details. When the user asks what happened in their life, who said what, or for a name, date or
        number from their records, and the excerpts do not contain it, say it is not in their records instead of guessing.
        When they ask for advice, ideas, recommendations or an opinion, answer directly from what you know about them and the
        world. Never add notes like "this is a recommendation, not a record lookup".
        A fact marked "replaced" is an earlier version: answer with the newer one.
        In transcript excerpts, "you (the user)" is the person on this Mac and "the other person" is the call participant.
        """
        if ResearchPrefs.enabled {
            s += "\nIf the user wants facts about the world (a book's ideas, a place, a public figure, news, how something works) that the excerpts don't contain, reply with only a search block and nothing else:\n```search\n<short query naming the subject>\n```\nThe app will look it up online and give you the pages.\n"
        }
        s += ChatStore.shared.profile.systemPromptSection
        if let person { s += personSection(person) }
        if let project {
            s += "\nYou are in the project \"\(project.name)\". The user wrote these project instructions; treat them as true context about the project and follow them:\n\(project.instructions)\n"
        }
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

    /// A chat opened from a person's page is about them: their saved details go into the system prompt.
    static func personSection(_ name: String) -> String {
        var s = "\nThis chat is about \(name), a person in the user's life. \"He\", \"she\" or \"they\" means \(name) unless the user says otherwise.\n"
        if let dossier = try? BrainStore().personDossier(name) {
            let d = dossier.details
            if !dossier.entity.summary.isEmpty { s += "Who they are: \(dossier.entity.summary)\n" }
            if let notes = d.notes, !notes.isEmpty { s += "The user's notes about them: \(notes)\n" }
            if !d.likes.isEmpty { s += "Likes: \(d.likes.joined(separator: ", "))\n" }
            if !d.dislikes.isEmpty { s += "Dislikes: \(d.dislikes.joined(separator: ", "))\n" }
            if !d.importantDates.isEmpty { s += "Dates: \(d.importantDates.joined(separator: ", "))\n" }
            if let level = dossier.entity.closenessLevel { s += "Closeness: \(level) of 5 (1 = very close)\n" }
            s += "Meetings with them on record: \(dossier.meetings.count)\n"
        }
        return s
    }

    /// The thread as the model sees it, oldest first: each user turn exactly as it was sent, each finished reply as
    /// shown, action results as user turns. Append-only, so a follow-up only adds tokens after the cached prefix. Once
    /// the thread passes `threadBudget`, the oldest exchanges drop out (one cache miss, then append-only again).
    static func turns(_ history: [ChatMessage]) -> [ChatTurn] {
        var out: [ChatTurn] = []
        for m in history {
            switch m.role {
            case "user": out.append(ChatTurn(role: "user", text: m.prompt ?? m.text))
            case "tool": out.append(ChatTurn(role: "user", text: "Action result: " + m.text))
            default:
                let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, text != "Stopped.", text != "Loading the model…" { out.append(ChatTurn(role: "assistant", text: text)) }
            }
        }
        var total = out.reduce(0) { $0 + $1.text.count }
        while total > threadBudget, out.count > 1 {
            total -= out.removeFirst().text.count
            while let first = out.first, first.role == "assistant" { total -= out.removeFirst().text.count }
        }
        return out
    }

    /// The records for one new turn: meetings and Brain facts the thread has not been given yet (a follow-up like "why?"
    /// adds nothing and reads only its own words).
    static func evidence(for question: String, history: [ChatMessage], meetings: [Meeting], projects: [Project] = [], project: Project? = nil) -> (hits: [Hit], sourceHits: [SourceHit], text: String, hashes: [String: String]) {
        let aboutMe = asksAboutUser(question) ? personalDigest(meetings: meetings) : ""
        guard needsRecords(question) else { return ([], [], aboutMe, [:]) }
        let documents: [BrainSourceDocument]
        if let project {
            documents = ProjectStore.documents(for: project, includedOnly: false)
        } else {
            documents = Brain.sourceDocuments(meetings: meetings, projects: projects)
        }
        let hashes = Dictionary(documents.map { ($0.sourceID, fingerprint($0.textChunks)) }, uniquingKeysWith: { first, _ in first })
        // A source already in the thread is not sent again, unless it changed since (then the new text goes in).
        var sent = Set<String>()
        for message in history {
            for id in message.sources {
                if let then = message.sourceHashes?[id], let now = hashes[id], then != now { sent.remove(id); continue }
                sent.insert(id)
            }
        }
        let sourceHits = Brain.searchSources(question, in: documents).filter { !sent.contains($0.sourceID) }
        let hits = Brain.search(question, in: meetings.filter(\.includeInBrain), limit: 4).filter { !sent.contains($0.meeting.sourceID) }
        let brainFacts: [BrainFactHit] = {
            guard let brain = try? BrainStore() else { return [] }
            return factsForChat(question, store: brain)
        }()
        let personDetails = (try? BrainStore().personDetailsForChat(question)) ?? []
        let given = history.compactMap(\.prompt).joined()
        return (hits, sourceHits, aboutMe + evidenceText(question: question, sourceHits: sourceHits, sources: documents,
                                                         brainFacts: brainFacts.filter { !given.contains(factLine($0)) },
                                                         personDetails: personDetails), hashes)
    }

    /// Stable across launches (FNV-1a), unlike `hashValue`.
    nonisolated static func fingerprint(_ chunks: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for chunk in chunks { for byte in chunk.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 } }
        return String(hash, radix: 16)
    }

    /// "What do you know about me?", "who am I?", "what are my interests?": keyword search cannot answer these, so
    /// the turn gets a digest of everything the user chose to include, not only meetings.
    nonisolated static func asksAboutUser(_ question: String) -> Bool {
        question.range(of: #"(?i)\b(about me|know me|who am i|about myself|my (life|interests?|taste|profile|hobbies|personality|story)|describe me|what do i (like|read|watch)|remember about me)\b"#,
                       options: .regularExpression) != nil
    }

    /// What the user has added, for the end of the introduction.
    static func savedTitles(meetings: [Meeting]) -> [String] {
        CollectionStore.brainItems().map(\.title).filter { !$0.isEmpty }
            + TravelStore.load().map { $0.title.isEmpty ? $0.place : $0.title }.filter { !$0.isEmpty }
            + JournalStore.load().map(\.sourceTitle)
            + meetings.filter { $0.sourceKind == .meeting }.map(\.title)
    }

    /// A short, budgeted summary of the user's profile, books, articles, media, trips and journal (only items included
    /// in the Brain), so personal questions draw on all of it.
    static func personalDigest(meetings: [Meeting] = [], budget: Int = 7_000) -> String {
        var s = """
        The user is asking about themselves. Answer as a short portrait, not a list: what the items below suggest about who
        they are, what they care about and how they think. Read their notes for feeling (an excited note means they love it).
        Make inferences, mark them as guesses ("looks like", "I'd guess"), and cite the item behind each one. Don't repeat
        the list back. End with one question that would help you know them better.

        About the user (from their profile and the items they saved on this Mac):

        """
        let about = ChatStore.shared.profile.aboutSection
        if !about.isEmpty { s += about + "\n" }
        func clip(_ text: String, _ limit: Int = 240) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
        }
        let items = CollectionStore.brainItems().filter(\.includeInBrain)
        for kind in CollectionKind.allCases {
            let group = items.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            s += "\(kind.title):\n"
            for item in group.prefix(15) {
                var line = "- [\(kind == .library ? "Library" : (kind == .articles ? "Article" : "Media")): \(item.title)]"
                if !item.creator.isEmpty { line += " by \(item.creator)" }
                if !item.notes.isEmpty { line += ". Their notes: \(clip(item.notes))" }
                if let quote = item.highlights.first?.text { line += ". Highlight: \"\(clip(quote, 120))\"" }
                s += line + "\n"
            }
        }
        let trips = TravelStore.load().filter(\.includeInBrain)
        if !trips.isEmpty {
            s += "Trips:\n"
            for trip in trips.prefix(10) {
                var line = "- [Trip: \(trip.title.isEmpty ? trip.place : trip.title), \(trip.startDate.formatted(date: .abbreviated, time: .omitted))]"
                if !trip.place.isEmpty, !trip.title.isEmpty { line += " in \(trip.place)" }
                if !trip.peopleMet.isEmpty { line += ", with \(trip.peopleMet.joined(separator: ", "))" }
                if !trip.notes.isEmpty { line += ". Their notes: \(clip(trip.notes))" }
                s += line + "\n"
            }
        }
        let included = meetings.filter { $0.includeInBrain && $0.sourceKind == .meeting }
        if !included.isEmpty {
            s += "Meetings (\(included.count)):\n"
            for meeting in included.prefix(8) { s += "- [Meeting: \(meeting.title), \(meeting.date)] \(clip(meeting.notes, 200))\n" }
        }
        let journal = JournalStore.load().filter(\.includeInBrain)
        if !journal.isEmpty {
            s += "Journal:\n"
            for entry in journal.prefix(8) {
                let body = entry.kind == .decision ? entry.decisionWhy : (entry.text.isEmpty ? entry.voiceMemo : entry.text)
                s += "- [Journal: \(entry.sourceTitle), \(entry.date.formatted(date: .abbreviated, time: .omitted))] \(clip(body))\n"
            }
        }
        return String(s.prefix(budget)) + "\n"
    }

    /// Keeps casual conversation and questions about this assistant from being grounded in the user's records.
    nonisolated static func needsRecords(_ question: String) -> Bool {
        let normalized = question.lowercased()
            .replacingOccurrences(of: "'s", with: " is")
            .replacingOccurrences(of: "'re", with: " are")
            .replacingOccurrences(of: "'m", with: " am")
        let words = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return false }

        // Only greetings, thanks and questions about the assistant itself skip the records. Any other word
        // ("what do you remember about the budget?") still searches.
        let smallTalkWords: Set<String> = [
            "a", "about", "afternoon", "all", "am", "an", "and", "are", "assistant", "bye", "can", "do", "doing", "evening",
            "fine", "for", "going", "good", "great", "hello", "help", "helpful", "hey", "hi", "how", "i", "inferoid", "is",
            "it", "me", "morning", "much", "my", "name", "nice", "night", "ok", "okay", "please", "so", "tell", "thank",
            "thanks", "that", "the", "there", "to", "today", "up", "very", "well", "what", "who", "yo", "you", "your",
            "yourself"
        ]
        return !words.allSatisfy(smallTalkWords.contains)
    }

    /// Graph facts for a question. Deterministic intent first (gbrain-style): questions about promises / commitments /
    /// to-dos get the commitments themselves, open ones first, since keyword search cannot find them; everything else
    /// gets keyword matches.
    nonisolated static func factsForChat(_ question: String, store: BrainStore) -> [BrainFactHit] {
        var hits = (try? store.factsForChat(question, limit: 8)) ?? []
        if asksAboutCommitments(question) {
            let seen = Set(hits.map(\.fact.id))
            hits += ((try? store.commitmentsForChat()) ?? []).filter { !seen.contains($0.fact.id) }
        }
        return hits
    }

    nonisolated static func asksAboutCommitments(_ question: String) -> Bool {
        question.range(of: #"(?i)\b(promis\w*|commit\w*|owe[sd]?|to-?dos?|action items?|follow[- ]?ups?|still open|remain\w* open|open items?|who (will|is going to)|outstanding|pending)\b"#,
                       options: .regularExpression) != nil
    }

    static func evidenceText(question: String, hits: [Hit] = [], sourceHits: [SourceHit] = [], sources: [any BrainSource] = [],
                             brainFacts: [BrainFactHit] = [], personDetails: [BrainPersonSearchHit] = []) -> String {
        var s = ""
        if !sourceHits.isEmpty {
            s += "Local source excerpts that may help:\n" + Brain.context(for: question, sourceHits: sourceHits, sources: sources, budget: evidenceBudget) + "\n"
        } else if !hits.isEmpty {
            s += "Meeting excerpts that may help:\n" + Brain.context(for: question, hits: hits, budget: evidenceBudget) + "\n"
        }
        if !brainFacts.isEmpty {
            s += "Brain facts (durable extracted facts, newest first; cite meeting date and line when using one):\n"
            for hit in brainFacts.sorted(by: { $0.meetingDate > $1.meetingDate }) { s += factLine(hit) + "\n" }
            s += "\n"
        }
        if !personDetails.isEmpty {
            s += "Personal details saved on this Mac (use only when relevant):\n"
            for detail in personDetails { s += "- \(detail.personName), \(detail.category): \(detail.value)\n" }
            s += "\n"
        }
        return s
    }

    static func factLine(_ hit: BrainFactHit) -> String {
        let fact = hit.fact
        var status = fact.status == "verified" ? "verified" : "unverified"
        // Old versions stay in the graph for history questions; the label keeps answers on the latest one.
        if let replaced = fact.invalidatedAt { status += ", replaced \(replaced.prefix(10))" }
        if fact.done { status += ", done" }
        if fact.kind == .commitment, !fact.done, fact.invalidatedAt == nil { status += ", open" }
        let meeting = hit.meeting.isEmpty ? hit.meetingDate : hit.meeting
        var s = "- [\(meeting), \(hit.line), \(fact.kind.rawValue), \(status)] \(Brain.chatSpeakerText(fact.predicate)): \(Brain.chatSpeakerText(fact.value))"
        if !fact.quote.isEmpty { s += " — \"\(Brain.chatSpeakerText(fact.quote))\"" }
        return s
    }

    /// The end of a new user turn: exact letter counts when asked, the question, and the short-reply instruction.
    static func question(_ question: String) -> String {
        var s = ""
        if let fact = letterCountFact(question) { s += fact + "\n" }
        return s + "User: " + question + shortReply
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
        var text = text
        for fence in ["```action", "```search"] {
            if let r = text.range(of: fence) { text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
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
    @ObservedObject private var projectStore = ProjectStore.shared
    let threadID: UUID
    var openSource: (String, BrainSourceKind) -> Void
    var project: Project? = nil
    var projectBack: (() -> Void)? = nil
    var projectDeleted: (() -> Void)? = nil
    var person: String? = nil
    var personBack: (() -> Void)? = nil
    var initialDraft: String? = nil
    @State private var draft = ""
    @State private var typing: Task<Void, Never>?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false

    /// The app's one model (Inkling on 24 GB+ Macs), so chat never swaps models with the notes.
    private var chatModel: String { rec.model }

    var body: some View {
        let thread = store.thread(threadID)
        let busy = store.busyThread == threadID
        VStack(spacing: 0) {
            if let parent = project?.name ?? person {
                HStack(spacing: 7) {
                    Button(parent) { (projectBack ?? personBack)?() }.buttonStyle(.link)
                    Text("/").foregroundStyle(.secondary)
                    Text(thread?.title ?? "Chat").lineLimit(1)
                    Spacer()
                    Menu {
                        Button("Rename") { renameText = thread?.title ?? "Chat"; renaming = true }
                        Button("Delete chat", role: .destructive) { confirmingDelete = true }
                    } label: {
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 28).padding(.vertical, 12)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if thread?.messages.isEmpty ?? true {
                            EmptyChat(meetingCount: rec.meetings.count, hasTools: !InferoidExtensions.chatTools.isEmpty) { draft = $0 }
                        }
                        ForEach(thread?.messages ?? []) { message in
                            MessageRow(message: message, busy: busy, meetings: rec.meetings, projects: projectStore.projects, openSource: openSource,
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
        .onAppear {
            if let initialDraft, draft.isEmpty { draft = initialDraft }
            rec.reloadMeetings()
            store.markSeen(threadID)
            if threadID != AssistantIntro.threadID || store.profile.isOnboarded { store.warm(model: chatModel) }
        }
        .onChange(of: thread?.messages.count ?? 0) { _, _ in store.markSeen(threadID) }
        .onChange(of: draft) { _, text in
            typing?.cancel()
            typing = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                store.prefetch(text, in: threadID, model: chatModel, meetings: rec.meetings, projects: projectStore.projects, project: project, person: person)
            }
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Save") { store.rename(threadID, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this chat?", isPresented: $confirmingDelete) {
            Button("Delete chat", role: .destructive) {
                if let project { try? projectStore.deleteChat(threadID, from: project.id, chatStore: store) }
                else { store.delete(threadID) }
                if let person { PersonChats.remove(threadID, from: person); personBack?() }
                projectDeleted?()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.busyThread == nil, !rec.isWriting else { return }
        typing?.cancel()
        draft = ""
        store.send(text, in: threadID, model: chatModel, meetings: rec.meetings, projects: projectStore.projects, project: project, person: person)
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
    let projects: [Project]
    let openSource: (String, BrainSourceKind) -> Void
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
                } else if message.text == ChatStore.checkingOnline {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(message.text).foregroundStyle(.secondary)
                    }
                } else {
                    Text(rendered(citedSources.isEmpty ? message.text : Self.withoutCitations(message.text))).textSelection(.enabled)
                }
                let shown = citedSources
                if !shown.isEmpty && !message.text.isEmpty && message.text != ChatStore.checkingOnline {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, id in
                            if let web = ResearchPage.parse(sourceID: id) {
                                Link(destination: web.url) {
                                    Label("\(web.url.host?.replacingOccurrences(of: "www.", with: "") ?? "Web"): \(web.title)", systemImage: "arrow.up.right.square")
                                }
                                .font(.caption).lineLimit(1).truncationMode(.tail).help(web.url.absoluteString)
                            } else if let source = SourceRegistry.lookup(id, meetings: meetings, projects: projects) {
                                Button { openSource(source.sourceID, source.sourceKind) } label: {
                                    Label("\(source.sourceKind.label): \(source.sourceTitle)", systemImage: "doc.text")
                                }
                                .buttonStyle(.link).font(.caption).lineLimit(1).truncationMode(.tail)
                            } else {
                                Text("Deleted source").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let engine = shown.lazy.compactMap({ ResearchPage.parse(sourceID: $0)?.engine }).first, !message.text.isEmpty {
                    let query = message.sources.first { $0.hasPrefix("webquery|") }.map { String($0.dropFirst(9)) }
                    Text("Searched \(engine)\(query.map { " for \u{201C}\($0)\u{201D}" } ?? ""). Only the search words left this Mac.")
                        .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                if let action = message.action {
                    ActionCard(action: action, approve: approve, cancel: cancel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The links under the answer already name its sources, so "[Web: …]", "[Meeting: …]" and "Source:" lines are
    /// removed from the text shown (the saved text keeps them, so the model still sees its citations).
    static func withoutCitations(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\s*\[(Web|Meeting|Library|Book|Article|Media|Trip|Journal|Project|Source)[^\]]*\](,?\s*(and\s*)?)?"#,
                                            with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?m)^\s*(Sources?|Pages used)\s*:\s*$"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]+([.,;:])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only the sources the answer actually cites (by title); web pages always show, they were read for this answer.
    private var citedSources: [String] {
        let text = message.text.lowercased()
        return message.sources.filter { id in
            if ResearchPage.parse(sourceID: id) != nil { return true }
            guard let source = SourceRegistry.lookup(id, meetings: meetings, projects: projects) else { return false }
            let title = source.sourceTitle.lowercased()
            return !title.isEmpty && (text.contains(title) || text.contains(String(title.prefix(24))))
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
