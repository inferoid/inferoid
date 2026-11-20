import XCTest
@testable import InferoidNotesKit

final class GroundingTests: XCTestCase {
    let oneLine = "[00:02] Me: So today we are talking about different things."

    func testFlagsInventedNames() {
        let missing = Grounding.unsupported("Project Phoenix is a new initiative to overhaul the legacy billing system.",
                                            transcript: oneLine, allowed: [])
        XCTAssertEqual(missing, ["Phoenix"])
    }

    func testKeepsNamesThatWereSaid() {
        let transcript = "[00:01] Them: Ryan here. The Northstar pilot starts in Oct, thirty days, the TVs are on-site."
        XCTAssertTrue(Grounding.unsupported("The team agreed that Ryan owns the Northstar pilot from Oct.", transcript: transcript, allowed: []).isEmpty)
        XCTAssertTrue(Grounding.unsupported("Install the TVs within 30 days; MWh costs need FTEs.", transcript: transcript, allowed: []).isEmpty)
    }

    func testCheckDropsUnsupportedPointsAndSummary() {
        let notes = Notes(title: "Project Phoenix Kickoff", summary: "The team held the Project Phoenix kickoff.",
                          key_points: ["Project Phoenix overhauls billing.", "We are talking about different things."],
                          decisions: ["The Discovery phase runs to August."], action_items: [], open_questions: [])
        let (checked, dropped) = Grounding.check(notes, transcript: oneLine, attendees: [])
        XCTAssertEqual(checked.key_points, ["We are talking about different things."])
        XCTAssertTrue(checked.decisions.isEmpty)
        XCTAssertEqual(checked.title, "Meeting notes")
        XCTAssertEqual(dropped, 3)
    }

    func testShortRecordingThreshold() {
        let line = Line(speaker: "Me", start: 0, end: 2, text: "So today we are talking about different things.")
        XCTAssertLessThan(Grounding.wordCount([line]), Grounding.minWords)
    }
}
