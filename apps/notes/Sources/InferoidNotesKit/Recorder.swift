import AppKit
import AVFoundation
import Foundation
import Network
import SwiftUI

@MainActor
public final class Recorder: ObservableObject {
    public static let shared = Recorder()

    @Published public var isRecording = false
    @Published var isWriting = false
    @Published var status = "Ready"
    @Published var error: String?
    @Published var lines: [Line] = []
    @Published var notes: Notes?
    @Published var notesInfo = ""
    @Published private(set) var attendeeNames: [String] = []
    @Published var elapsed: TimeInterval = 0
    @Published var levelMe: Float = 0
    @Published var levelThem: Float = 0
    @Published var online = true
    @Published var models: [String] = []
    @Published var model: String { didSet { UserDefaults.standard.set(model, forKey: "model") } }
    @Published var template: Template { didSet { UserDefaults.standard.set(template.rawValue, forKey: "template") } }
    @Published var savedFolder: URL?
    /// The meeting whose notes the feedback bar is asking about (nil: no bar).
    @Published var feedbackFor: URL?
    /// The model menu shows only the Inferoid notes model unless this is on.
    @Published var showAllModels = UserDefaults.standard.bool(forKey: "showAllModels") {
        didSet {
            UserDefaults.standard.set(showAllModels, forKey: "showAllModels")
            if !showAllModels, let m = ModelManager.shared.managedModel { model = m }
        }
    }

    var visibleModels: [String] {
        if !showAllModels, let m = ModelManager.shared.managedModel { return [m] }
        return models.isEmpty ? [model] : models
    }

    let transcriber = Transcriber()
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var segMe: Segmenter?
    private var segThem: Segmenter?
    private let meQueue = DispatchQueue(label: "ai.inferoid.notes.me")
    private let themQueue = DispatchQueue(label: "ai.inferoid.notes.them")
    private var pending: [Task<Void, Never>] = []
    private var started = Date()
    private var timer: Timer?
    private var prefillTimer: Timer?
    private var prefillBusy = false
    private var prefilledLines = 0
    private let monitor = NWPathMonitor()
    // Reliability: crash-safe audio journal and per-channel health (see RecordingJournal, ChannelStats).
    private var journal: RecordingJournal?
    private var statsMe = ChannelStats()
    private var statsThem = ChannelStats()
    private var pushMe: (([Float]) -> Void)?
    private var pushThem: (([Float]) -> Void)?
    private var lastRestart: [RecordingJournal.Channel: Date] = [:]
    private var restartsInARow: [RecordingJournal.Channel: Int] = [:]
    private var healthMessage: String?
    private var deviceWatcher: AudioDeviceWatcher?
    private var wakeObserver: NSObjectProtocol?
    private var ticks = 0
    /// Meetings that were interrupted (crash, force quit, power loss) and can be recovered from their audio.
    @Published var pendingRecoveries: [RecordingJournal.Pending] = []

    public init() {
        model = UserDefaults.standard.string(forKey: "model") ?? NotesConfig.load()?.appModel ?? "gemma4:e4b"
        template = Template(rawValue: UserDefaults.standard.string(forKey: "template") ?? "") ?? .general
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in Recorder.shared.online = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "ai.inferoid.notes.net"))
        meetings = Brain.load()
        // Quitting mid-meeting: flush the audio journal before the vault detaches; it is offered for recovery next time.
        Vault.willClose.append { MainActor.assumeIsolated { Recorder.shared.journal?.close() } }
        Task { await refreshModels(); await prepare() }
        Task.detached { await FeedbackSender.flush() }  // ratings saved while offline
    }

    func refreshModels() async {
        models = await Summarizer.models()
        if !models.isEmpty, !models.contains(model) { model = models[0] }
    }

    func prepare() async {
        if await transcriber.isReady { return }
        status = "Loading the speech model…"
        do {
            try await transcriber.load()
            status = "Ready"
        } catch {
            status = "Speech model failed to load"
            self.error = error.localizedDescription
        }
    }

    func toggle() { Task { isRecording ? await stop() : await start() } }

    func start() async {
        guard !isRecording, !isWriting else { return }
        error = nil
        await prepare()
        guard await transcriber.isReady else { return }
        lines = []; notes = nil; notesInfo = ""; savedFolder = nil; feedbackFor = nil; elapsed = 0
        started = Date()
        let calendarContext = await MeetingCalendar.currentContext(at: started)
        attendeeNames = calendarContext.attendeeNames

        let me = Segmenter { [weak self] samples, start, end in self?.utterance("Me", samples, start, end) }
        let otherSpeaker = calendarContext.otherParticipant ?? "Them"
        let them = Segmenter { [weak self] samples, start, end in self?.utterance(otherSpeaker, samples, start, end) }
        segMe = me; segThem = them

        let journal = try? RecordingJournal(manifest: .init(started: started, template: template.rawValue, model: model,
                                                             attendees: attendeeNames, otherSpeaker: otherSpeaker))
        self.journal = journal
        let statsMe = ChannelStats(), statsThem = ChannelStats()
        self.statsMe = statsMe; self.statsThem = statsThem
        lastRestart = [:]; restartsInARow = [:]; healthMessage = nil
        let pushMe: ([Float]) -> Void = { [meQueue] samples in
            meQueue.async { statsMe.record(samples); journal?.append(samples, to: .me); me.push(samples) }
        }
        let pushThem: ([Float]) -> Void = { [themQueue] samples in
            themQueue.async { statsThem.record(samples); journal?.append(samples, to: .them); them.push(samples) }
        }
        self.pushMe = pushMe; self.pushThem = pushThem

        var problems: [String] = []
        if await AVCaptureDevice.requestAccess(for: .audio) {
            let capture = MicCapture()
            do {
                try capture.start(pushMe, voiceProcessingEnabled: Prefs.shared.voiceProcessingEnabled)
                mic = capture
                if capture.voiceProcessing { fallBackIfSilent(capture, pushMe) }
            } catch { problems.append("Microphone: \(error.localizedDescription)") }
        } else {
            problems.append("Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone.")
        }
        let tap = SystemAudioCapture()
        do {
            try tap.start(pushThem)
            system = tap
        } catch {
            problems.append("Call audio: \(error.localizedDescription) Allow it in System Settings > Privacy & Security > Screen & System Audio Recording.")
        }
        if mic == nil && system == nil {
            error = problems.joined(separator: "\n")
            journal?.discard(); self.journal = nil
            return
        }
        if !problems.isEmpty { error = problems.joined(separator: "\n") }
        isRecording = true
        status = "Recording"
        deviceWatcher = AudioDeviceWatcher { change in
            Task { @MainActor in
                let r = Recorder.shared
                if change == .input { r.restart(.me, reason: "switched to another microphone") }
                else { r.restart(.them, reason: "switched to another speaker or headset") }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { _ in
            Task { @MainActor in
                Recorder.shared.restart(.me, reason: "paused while the Mac slept")
                Recorder.shared.restart(.them, reason: "paused while the Mac slept")
            }
        }
        prefilledLines = 0
        // Read the transcript into the model every 45 s during the meeting, so notes start right after hang-up.
        prefillTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { _ in
            Task { @MainActor in await Recorder.shared.prefillNow() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                let r = Recorder.shared
                r.elapsed = Date().timeIntervalSince(r.started)
                r.levelMe = r.segMe?.level ?? 0
                r.levelThem = r.segThem?.level ?? 0
                r.ticks += 1
                if r.ticks % 10 == 0 { r.checkHealth() }
            }
        }
    }

    /// Once a second while recording: restart a channel that stopped delivering audio, or a microphone that gives
    /// only digital silence (a quiet room is never exactly zero). Call audio is legitimately all zeros when nothing
    /// plays, so only stalled callbacks count for it.
    func checkHealth() {
        guard isRecording else { return }
        let now = Date()
        if mic != nil {
            let s = statsMe.snapshot
            if now.timeIntervalSince(s.lastCallback) > 3 {
                restart(.me, reason: "stopped sending audio")
            } else if s.total > RecordingJournal.rate * 3, now.timeIntervalSince(s.lastSound) > 5,
                      (restartsInARow[.me] ?? 0) < 3 {
                restart(.me, reason: "gave only silence")
            }
        }
        if system != nil, now.timeIntervalSince(statsThem.snapshot.lastCallback) > 3 {
            restart(.them, reason: "stopped sending audio")
        }
        // Healthy again for 30 s: forget earlier restarts and clear the notice.
        for channel in [RecordingJournal.Channel.me, .them] {
            if let last = lastRestart[channel], now.timeIntervalSince(last) > 30 { restartsInARow[channel] = 0 }
        }
        if let note = healthMessage, error == note,
           lastRestart.values.allSatisfy({ now.timeIntervalSince($0) > 30 }) {
            error = nil; healthMessage = nil
        }
    }

    /// Stops and reopens one channel (at most every 5 s). The gap is filled with silence so transcript times stay
    /// in step with the clock and with the other channel.
    func restart(_ channel: RecordingJournal.Channel, reason: String) {
        guard isRecording else { return }
        let now = Date()
        if let last = lastRestart[channel], now.timeIntervalSince(last) < 5 { return }
        lastRestart[channel] = now
        let attempts = (restartsInARow[channel] ?? 0) + 1
        restartsInARow[channel] = attempts
        let label = channel == .me ? "Microphone" : "Call audio"
        let stats = channel == .me ? statsMe : statsThem
        guard let push = channel == .me ? pushMe : pushThem else { return }
        padGap(stats, push)
        do {
            switch channel {
            case .me:
                mic?.stop()
                let fresh = MicCapture()
                try fresh.start(push, voiceProcessingEnabled: false)   // a restart means trouble: keep it simple
                mic = fresh
            case .them:
                system?.stop()
                let fresh = SystemAudioCapture()
                try fresh.start(push)
                system = fresh
            }
            stats.restarted()
            let note = attempts >= 3
                ? "\(label) keeps dropping (\(reason)). Check it in System Settings > Sound."
                : "\(label) \(reason); reconnected."
            error = note; healthMessage = note
        } catch {
            if channel == .me { mic = nil } else { system = nil }
            let note = "\(label) \(reason) and could not reconnect: \(error.localizedDescription)"
            self.error = note; healthMessage = nil
        }
    }

    private func padGap(_ stats: ChannelStats, _ push: ([Float]) -> Void) {
        let s = stats.snapshot
        guard let first = s.firstSample else { return }
        var missing = Int(Date().timeIntervalSince(first) * Double(RecordingJournal.rate)) - s.total
        guard missing > RecordingJournal.rate / 2 else { return }
        missing = min(missing, RecordingJournal.rate * 3600)
        while missing > 0 {
            let n = min(missing, RecordingJournal.rate)
            push([Float](repeating: 0, count: n))
            missing -= n
        }
    }

    /// Voice processing can deliver pure silence (for example while another app also uses it on the same mic).
    /// After 3 s of digital silence, restart the microphone without it.
    private func fallBackIfSilent(_ capture: MicCapture, _ pushMe: @escaping ([Float]) -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard isRecording, mic === capture, !capture.heardSound else { return }
            capture.stop()
            let plain = MicCapture()
            do {
                try plain.start(pushMe, voiceProcessingEnabled: false)
                mic = plain
                error = "The echo filter gave silence on this microphone, so Inferoid turned it off for this meeting."
            } catch {
                mic = nil
                self.error = "Microphone: \(error.localizedDescription)"
            }
        }
    }

    nonisolated private func utterance(_ speaker: String, _ samples: [Float], _ start: Double, _ end: Double) {
        Task { @MainActor in
            let task = Task {
                guard let text = try? await self.transcriber.transcribe(samples), !text.isEmpty else { return }
                let line = Line(speaker: speaker, start: start, end: end, text: text)
                let index = self.lines.firstIndex { $0.start > start } ?? self.lines.endIndex
                self.lines.insert(line, at: index)
                self.lines = TranscriptDeduper.deduplicated(self.lines)
            }
            self.pending.append(task)
        }
    }

    func prefillNow() async {
        guard isRecording, !prefillBusy, lines.count > prefilledLines else { return }
        prefillBusy = true
        let count = lines.count
        do { try await ModelManager.shared.ensure(model) } catch { prefillBusy = false; return }
        await Summarizer.prefill(transcript: transcriptText(lines), template: template, model: model,
                                 attendeeNames: attendeeNames, instructions: Prefs.instructionsNow)
        prefilledLines = count
        prefillBusy = false
    }

    func stop() async {
        guard isRecording else { return }
        timer?.invalidate(); timer = nil
        prefillTimer?.invalidate(); prefillTimer = nil
        mic?.stop(); system?.stop(); mic = nil; system = nil
        deviceWatcher = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil; pushMe = nil; pushThem = nil
        isRecording = false
        levelMe = 0; levelThem = 0
        let me = segMe, them = segThem
        await withCheckedContinuation { c in meQueue.async { me?.flush(); c.resume() } }
        await withCheckedContinuation { c in themQueue.async { them?.flush(); c.resume() } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        for task in pending { await task.value }
        pending = []
        journal?.close()
        await writeNotes()
        // The journal is only deleted once the transcript is safely saved; otherwise it stays for recovery.
        if savedFolder != nil { journal?.discard() }
        journal = nil
        refreshRecoveries()
    }

    // MARK: - Recovery of interrupted meetings

    func refreshRecoveries() {
        pendingRecoveries = RecordingJournal.pending(excluding: journal?.folder)
    }

    func discardRecovery(_ p: RecordingJournal.Pending) {
        try? FileManager.default.removeItem(at: p.folder)
        refreshRecoveries()
    }

    /// Re-transcribes an interrupted meeting from its saved audio, then writes and saves notes as usual.
    func recover(_ p: RecordingJournal.Pending) async {
        guard !isRecording, !isWriting else { return }
        await prepare()
        guard await transcriber.isReady else { return }
        error = nil; notes = nil; notesInfo = ""; savedFolder = nil; feedbackFor = nil
        isWriting = true
        var recovered: [Line] = []
        let total = max(1, p.seconds)
        do {
            for (channel, speaker) in [(RecordingJournal.Channel.me, "Me"), (.them, p.manifest.otherSpeaker)] {
                let found = UtteranceBox()
                let seg = Segmenter { samples, start, end in found.items.append((samples, start, end)) }
                var done = 0.0
                func drain() async {
                    for (samples, start, end) in found.items {
                        if let text = try? await transcriber.transcribe(samples), !text.isEmpty {
                            recovered.append(Line(speaker: speaker, start: start, end: end, text: text))
                        }
                    }
                    found.items.removeAll()
                }
                try await RecordingJournal.read(p.folder, channel) { chunk in
                    seg.push(chunk)
                    done += Double(chunk.count) / Double(RecordingJournal.rate)
                    status = String(format: "Recovering the interrupted meeting… %@ %.0f%%",
                                    channel == .me ? "your side" : "the call", 100 * min(1, done / total))
                    await drain()
                }
                seg.flush()
                await drain()
            }
        } catch {
            self.error = "Recovery: \(error.localizedDescription)"
        }
        isWriting = false
        lines = TranscriptDeduper.deduplicated(recovered.sorted { $0.start < $1.start })
        started = p.manifest.started
        attendeeNames = p.manifest.attendees
        elapsed = total
        if lines.isEmpty {
            status = "Nothing was said in the interrupted meeting"
            discardRecovery(p)
            return
        }
        await writeNotes()
        if savedFolder != nil { discardRecovery(p) }
    }

    func writeNotes() async {
        guard !lines.isEmpty else { status = "Nothing was said"; return }
        if Grounding.wordCount(lines) < Grounding.minWords {
            notes = Grounding.shortNotes(lines)
            notesInfo = "Not enough was said for notes; the transcript is saved."
            status = "Notes ready"
            savedFolder = try? Store.save(started: started, lines: lines, notes: notes,
                                          meta: ["template": template.rawValue, "duration_s": Int(elapsed), "short": true],
                                          attendeeNames: attendeeNames)
            reloadMeetings()
            return
        }
        isWriting = true
        notes = nil
        status = "Writing notes on this Mac…"
        let writeStarted = Date()
        var meta: [String: Any] = ["model": model, "template": template.rawValue,
                                   "duration_s": Int(elapsed), "speech_model": "parakeet-tdt-0.6b-v2"]
        if !attendeeNames.isEmpty { meta["attendees"] = attendeeNames }
        do {
            if ModelManager.shared.manages(model) { status = "Loading the notes model…" }
            try await ModelManager.shared.ensure(model)
            status = "Writing notes on this Mac…"
            let lastShown = Stamp()
            let instructions = Prefs.instructionsNow
            if !instructions.isEmpty { meta["instructions"] = instructions }
            let result = try await Summarizer.run(transcript: transcriptText(lines), template: template, model: model,
                                                  attendeeNames: attendeeNames, instructions: instructions) { text in
                Task { @MainActor in
                    let r = Recorder.shared
                    guard r.isWriting, Date().timeIntervalSince(lastShown.date) > 0.15, let partial = partialNotes(text) else { return }
                    lastShown.date = Date()
                    r.notes = partial
                }
            }
            let (checked, dropped) = Grounding.check(result.notes, transcript: transcriptText(lines), attendees: attendeeNames)
            notes = checked
            notesInfo = String(format: "Written by %@ on this Mac in %.0f s", Summarizer.displayName(model), result.seconds)
            if dropped > 0 {
                notesInfo += " · removed \(dropped) point\(dropped == 1 ? "" : "s") naming things not in the transcript"
                meta["grounding_dropped"] = dropped
            }
            meta["notes_seconds"] = result.seconds
            meta["seconds_after_stop"] = Date().timeIntervalSince(writeStarted)
            meta["prompt_tokens"] = result.promptTokens
            meta["output_tokens"] = result.outputTokens
            status = "Notes ready"
        } catch {
            self.error = "Notes: \(error.localizedDescription)"
            status = "Transcript saved; notes failed"
        }
        savedFolder = try? Store.save(started: started, lines: lines, notes: notes, meta: meta, attendeeNames: attendeeNames)
        if notes != nil, Prefs.shared.askFeedback { feedbackFor = savedFolder }
        reloadMeetings()
        ModelManager.shared.idle()
        isWriting = false
    }

    // MARK: - Ask (private brain)

    @Published var askQuery = ""
    @Published var askAnswer = ""
    @Published var askSources: [Hit] = []
    @Published var askBusy = false
    @Published var meetings: [Meeting] = []

    func reloadMeetings() { meetings = Brain.load() }

    var searchHits: [Hit] { Brain.search(askQuery, in: meetings) }

    func ask() {
        let question = askQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !askBusy, !isWriting else { return }
        askBusy = true; askAnswer = ""; askSources = []; error = nil
        Task {
            do {
                if ModelManager.shared.manages(model) { askAnswer = "Loading the notes model…" }
                try await ModelManager.shared.ensure(model)
                askAnswer = ""
                let r = try await Brain.ask(question, model: model, meetings: meetings) { text in
                    Task { @MainActor in Recorder.shared.askAnswer = text }
                }
                askAnswer = r.answer; askSources = r.sources
            } catch {
                askAnswer = ""
                self.error = "Ask: \(error.localizedDescription)"
            }
            ModelManager.shared.idle()
            askBusy = false
        }
    }
}

/// A mutable timestamp shared with the streaming callback.
final class Stamp: @unchecked Sendable { var date = Date.distantPast }

/// Collects utterances from a Segmenter during recovery.
private final class UtteranceBox { var items: [([Float], Double, Double)] = [] }
