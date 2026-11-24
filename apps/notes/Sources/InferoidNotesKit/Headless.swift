import FluidAudio
import Foundation

/// Test and benchmark modes (no UI, no microphone needed):
///   InferoidNotes --feed me.wav [them.wav] [--model M] [--template T] [--out DIR]
///       runs recorded audio through the same splitter, speech model and notes as a live meeting.
///   InferoidNotes --summarize transcript.txt --model M [--template T] [--instructions TEXT] [--context N] [--json OUT]
///       notes only, for comparing models on the same transcript.
///   InferoidNotes --ask "question" [--model M] [--root DIR]
///       private brain: answers from saved local records (default ~/Documents/Inferoid Notes).
///   InferoidNotes --brain-ingest DIR --db brain.sqlite [--model M]
///       builds a fact graph from every meeting folder in DIR into a separate database (graph tests).
///   InferoidNotes --brain-ask questions.jsonl --root DIR --db brain.sqlite [--model M] [--out answers.jsonl]
///       answers each {"id","question"} line the way Brain chat does: meeting excerpts + graph facts, short reply.
public enum Headless {
    static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    public static func run(_ args: [String]) async throws {
        let template = Template(rawValue: value(args, "--template") ?? "general") ?? .general
        let defaultModel = NotesConfig.defaultModel ?? "gemma4:e4b"
        if let question = value(args, "--ask") {
            let model = value(args, "--model") ?? defaultModel
            let meetings = Brain.load(root: value(args, "--root").map { URL(fileURLWithPath: $0) } ?? Store.root)
            try await ModelManager.shared.ensure(model)
            let started = Date()
            let r = try await Brain.ask(question, model: model, meetings: meetings)
            print(r.answer)
            print(String(format: "\n(%d saved records searched; answered from: %@; %.1f s)",
                         SourceRegistry.documents(meetings: meetings, projects: []).count,
                         r.sources.map { "\($0.kind.label): \($0.title) \($0.date)" }.joined(separator: " | "), Date().timeIntervalSince(started)))
            await MainActor.run { ModelManager.shared.stop() }
            return
        }
        if let root = value(args, "--brain-ingest"), let db = value(args, "--db") {
            let model = value(args, "--model") ?? defaultModel
            let store = try BrainStore(url: URL(fileURLWithPath: db))
            try await ModelManager.shared.ensure(model)
            var counts: [String: Int] = [:]
            let started = Date()
            await BrainBackfill.run(root: URL(fileURLWithPath: root), model: model, store: store) { result in
                counts["\(result)", default: 0] += 1
            }
            print(String(format: "%@ in %.0f s", counts.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "), Date().timeIntervalSince(started)))
            await MainActor.run { ModelManager.shared.stop() }
            return
        }
        if let path = value(args, "--brain-ask"), let root = value(args, "--root"), let db = value(args, "--db") {
            let model = value(args, "--model") ?? defaultModel
            let store = try BrainStore(url: URL(fileURLWithPath: db))
            let meetings = Brain.load(root: URL(fileURLWithPath: root))
            try await ModelManager.shared.ensure(model)
            var out = ""
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
                guard let q = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = q["id"] as? String, let question = q["question"] as? String else { continue }
                let hits = Brain.search(question, in: meetings, limit: 4)
                let facts = ChatStore.factsForChat(question, store: store)
                let (system, turn, tokens) = await MainActor.run {
                    (ChatStore.systemPrompt(tools: []),
                     ChatStore.evidenceText(question: question, hits: hits, brainFacts: facts) + ChatStore.question(question),
                     ChatStore.replyTokens)
                }
                let t0 = Date()
                let answer = try await Summarizer.chat(system: system, turns: [ChatTurn(role: "user", text: turn)], model: model,
                                                       maxTokens: tokens)
                let row: [String: Any] = ["id": id, "answer": answer, "seconds": Date().timeIntervalSince(t0),
                                          "facts": facts.map { $0.fact.id }, "meetings": hits.map { $0.meeting.id }]
                out += String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)! + "\n"
                print(id, String(format: "%.1f s", Date().timeIntervalSince(t0)))
            }
            if let dest = value(args, "--out") { try out.write(toFile: dest, atomically: true, encoding: .utf8) } else { print(out) }
            await MainActor.run { ModelManager.shared.stop() }
            return
        }
        if let path = value(args, "--summarize") {
            let model = value(args, "--model") ?? defaultModel
            try await ModelManager.shared.ensure(model)
            let context = Int(value(args, "--context") ?? "32768") ?? 32768
            let transcript = try String(contentsOfFile: path, encoding: .utf8)
            let instructions = value(args, "--instructions") ?? ""  // bench custom instructions; the app's setting is not used here
            if args.contains("--live") {
                // As in a meeting: the app reads the transcript so far every ~minute; the last ~half minute stays unread.
                let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
                let minutes = Int(value(args, "--minutes") ?? "30") ?? 30
                let step = max(1, lines.count / minutes)
                var k = step
                while k < lines.count - step / 2 {
                    await Summarizer.prefill(transcript: lines[..<k].joined(separator: "\n"), template: template, model: model, context: context,
                                             instructions: instructions)
                    k += step
                }
            }
            let started = Date()
            let firstSummary = Stamp()
            let r = try await Summarizer.run(transcript: transcript, template: template, model: model, context: context,
                                             instructions: instructions) { text in
                if firstSummary.date == .distantPast, let p = partialNotes(text), p.summary.count > 40 { firstSummary.date = Date() }
            }
            let summaryAfter = firstSummary.date == .distantPast ? r.seconds : firstSummary.date.timeIntervalSince(started)
            let out: [String: Any] = ["model": model, "seconds": r.seconds, "summary_visible_s": summaryAfter, "prompt_tokens": r.promptTokens,
                                      "output_tokens": r.outputTokens, "notes": try JSONSerialization.jsonObject(with: Data(r.raw.utf8))]
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            if let json = value(args, "--json") { try data.write(to: URL(fileURLWithPath: json)) }
            print(String(data: data, encoding: .utf8)!)
            await MainActor.run { ModelManager.shared.stop() }
            return
        }
        guard let mePath = value(args, "--feed") else {
            print("usage: InferoidNotes --feed me.wav [them.wav] [--model M] | --summarize transcript.txt --model M | --ask \"question\"")
            return
        }
        let i = args.firstIndex(of: "--feed")!
        let themPath = (i + 2 < args.count && !args[i + 2].hasPrefix("--")) ? args[i + 2] : nil

        let transcriber = Transcriber()
        var t0 = Date()
        try await transcriber.load()
        print(String(format: "speech model loaded in %.1f s", Date().timeIntervalSince(t0)))

        var utterances: [(String, [Float], Double, Double)] = []
        let converter = AudioConverter()
        for (speaker, path) in [("Me", mePath), ("Them", themPath)] {
            guard let path else { continue }
            let samples = try converter.resampleAudioFile(path: path)
            let seg = Segmenter { s, a, b in utterances.append((speaker, s, a, b)) }
            var k = 0
            while k < samples.count { let n = min(1600, samples.count - k); seg.push(Array(samples[k ..< k + n])); k += n }
            seg.flush()
        }
        t0 = Date()
        var lines: [Line] = []
        var audioSeconds = 0.0
        for (speaker, s, a, b) in utterances {
            let text = try await transcriber.transcribe(s)
            audioSeconds += Double(s.count) / 16_000
            if !text.isEmpty { lines.append(Line(speaker: speaker, start: a, end: b, text: text)) }
        }
        lines.sort { $0.start < $1.start }
        let asrSeconds = Date().timeIntervalSince(t0)
        print(transcriptText(lines))
        print(String(format: "\n%d lines, %.0f s of speech transcribed in %.1f s (%.0fx real time)",
                     lines.count, audioSeconds, asrSeconds, audioSeconds / max(asrSeconds, 0.001)))
        var notes: Notes?
        var meta: [String: Any] = ["asr_seconds": asrSeconds, "speech_seconds": audioSeconds]
        if let model = value(args, "--model") {
            let r = try await Summarizer.run(transcript: transcriptText(lines), template: template, model: model)
            notes = r.notes
            meta["model"] = model; meta["notes_seconds"] = r.seconds
            print("\n" + notesMarkdown(r.notes, layout: .standard))
            print(String(format: "notes by %@ in %.1f s (%d prompt tokens, %d output tokens)", model, r.seconds, r.promptTokens, r.outputTokens))
        }
        if let out = value(args, "--out") {
            let folder = try Store.save(started: Date(), lines: lines, notes: notes, meta: meta, to: URL(fileURLWithPath: out))
            print("saved \(folder.path)")
        }
    }
}
