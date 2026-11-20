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

    public init() {
        model = UserDefaults.standard.string(forKey: "model") ?? NotesConfig.load()?.appModel ?? "gemma4:e4b"
        template = Template(rawValue: UserDefaults.standard.string(forKey: "template") ?? "") ?? .general
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in Recorder.shared.online = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "ai.inferoid.notes.net"))
        meetings = Brain.load()
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

        var problems: [String] = []
        let pushMe: ([Float]) -> Void = { [meQueue] samples in meQueue.async { me.push(samples) } }
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
            try tap.start { [themQueue] samples in themQueue.async { them.push(samples) } }
            system = tap
        } catch {
            problems.append("Call audio: \(error.localizedDescription) Allow it in System Settings > Privacy & Security > Screen & System Audio Recording.")
        }
        if mic == nil && system == nil {
            error = problems.joined(separator: "\n")
            return
        }
        if !problems.isEmpty { error = problems.joined(separator: "\n") }
        isRecording = true
        status = "Recording"
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
            }
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
        isRecording = false
        levelMe = 0; levelThem = 0
        let me = segMe, them = segThem
        await withCheckedContinuation { c in meQueue.async { me?.flush(); c.resume() } }
        await withCheckedContinuation { c in themQueue.async { them?.flush(); c.resume() } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        for task in pending { await task.value }
        pending = []
        await writeNotes()
    }

    func writeNotes() async {
        guard !lines.isEmpty else { status = "Nothing was said"; return }
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
            notes = result.notes
            notesInfo = String(format: "Written by %@ on this Mac in %.0f s", Summarizer.displayName(model), result.seconds)
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
