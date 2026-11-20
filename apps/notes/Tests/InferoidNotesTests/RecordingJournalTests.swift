import XCTest
@testable import InferoidNotesKit

final class RecordingJournalTests: XCTestCase {
    override func setUp() {
        RecordingJournal.rootOverride = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() {
        if let root = RecordingJournal.rootOverride { try? FileManager.default.removeItem(at: root) }
        RecordingJournal.rootOverride = nil
    }

    private func manifest() -> RecordingJournal.Manifest {
        .init(started: Date(timeIntervalSince1970: 1_800_000_000), template: "general", model: "m",
              attendees: ["Ryan Green"], otherSpeaker: "Ryan Green")
    }

    @MainActor func testInterruptedRecordingIsFoundAndReadBack() async throws {
        let journal = try RecordingJournal(manifest: manifest())
        let tone = (0..<40_000).map { Float(sin(Double($0) / 10)) * 0.5 }
        journal.append(tone, to: .me)
        journal.append([Float](repeating: 0, count: 16_000), to: .them)
        journal.close()   // simulates a crash after the last flush: nothing is discarded

        let pending = RecordingJournal.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].manifest.otherSpeaker, "Ryan Green")
        XCTAssertEqual(pending[0].seconds, 2.5, accuracy: 0.01)

        var back: [Float] = []
        try await RecordingJournal.read(pending[0].folder, .me) { back += $0 }
        XCTAssertEqual(back.count, tone.count)
        XCTAssertEqual(back[1234], tone[1234], accuracy: 0.001)
    }

    func testActiveAndDiscardedJournalsAreNotOffered() throws {
        let active = try RecordingJournal(manifest: manifest())
        XCTAssertTrue(RecordingJournal.pending(excluding: active.folder).isEmpty)
        active.discard()
        XCTAssertTrue(RecordingJournal.pending().isEmpty)
    }

    func testChannelStatsSeparatesSilenceFromSound() {
        let stats = ChannelStats()
        let before = stats.snapshot.lastSound
        Thread.sleep(forTimeInterval: 0.01)
        stats.record([0, 0, 0])
        XCTAssertEqual(stats.snapshot.lastSound, before)          // exact zeros are not sound
        XCTAssertEqual(stats.snapshot.total, 3)
        stats.record([0, 0.0002, 0])                               // faint room noise is
        XCTAssertGreaterThan(stats.snapshot.lastSound, before)
        XCTAssertNotNil(stats.snapshot.firstSample)
    }
}
