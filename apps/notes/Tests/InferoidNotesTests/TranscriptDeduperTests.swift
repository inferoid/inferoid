import XCTest
@testable import InferoidNotes

final class TranscriptDeduperTests: XCTestCase {
    func testRemovesFuzzyEchoPrefixAndKeepsOwnerWords() {
        let lines = [
            Line(speaker: "Them", start: 8, end: 11, text: "Our team works with several local clients."),
            Line(speaker: "Me", start: 9, end: 12, text: "Our teem works with several local clients. Great point."),
        ]

        let result = TranscriptDeduper.deduplicated(lines)

        XCTAssertEqual(result.map(\.speaker), ["Them", "Me"])
        XCTAssertEqual(result[0].text, lines[0].text)
        XCTAssertEqual(result[1].text, "Great point")
    }

    func testDropsPureEchoButNeverDeletesCallAudio() {
        let lines = [
            Line(speaker: "Them", start: 20, end: 23, text: "The next review is on Thursday."),
            Line(speaker: "Me", start: 21, end: 24, text: "The next review is on Thursday."),
        ]

        let result = TranscriptDeduper.deduplicated(lines)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "Them")
        XCTAssertEqual(result[0].text, lines[0].text)
    }

    func testDropsAShortPureEcho() {
        let lines = [
            Line(speaker: "Them", start: 2, end: 3, text: "Sounds good."),
            Line(speaker: "Me", start: 3, end: 4, text: "Sounds good."),
        ]

        let result = TranscriptDeduper.deduplicated(lines)

        XCTAssertEqual(result.map(\.speaker), ["Them"])
    }

    func testDoesNotDeduplicateOutsideTheTimeWindow() {
        let lines = [
            Line(speaker: "Them", start: 0, end: 3, text: "We should review the budget tomorrow."),
            Line(speaker: "Me", start: 30, end: 33, text: "We should review the budget tomorrow."),
        ]

        let result = TranscriptDeduper.deduplicated(lines)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].text, lines[1].text)
    }

    func testSupportsARealNameForTheCallAudioStream() {
        let lines = [
            Line(speaker: "Alex Rivera", start: 4, end: 7, text: "Please send the draft after lunch."),
            Line(speaker: "Me", start: 5, end: 8, text: "Please send the draft after lunch. Sounds good."),
        ]

        let result = TranscriptDeduper.deduplicated(lines)

        XCTAssertEqual(result[0].speaker, "Alex Rivera")
        XCTAssertEqual(result[1].text, "Sounds good")
    }
}
