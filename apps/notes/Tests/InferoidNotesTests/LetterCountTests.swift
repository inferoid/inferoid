import XCTest
@testable import InferoidNotesKit

final class LetterCountTests: XCTestCase {
    func testCountsLettersInCommonPhrasings() {
        XCTAssertTrue(ChatStore.letterCountFact("how many r is in strawberry?")?.contains("has 3 letter \"r\"") == true)
        XCTAssertTrue(ChatStore.letterCountFact("How many R's does strawberry have")?.contains("has 3 letter \"r\"") == true)
        XCTAssertTrue(ChatStore.letterCountFact("count the r in 'strawberry'")?.contains("has 3 letter \"r\"") == true)
        XCTAssertTrue(ChatStore.letterCountFact("how many times does s appear in mississippi")?.contains("has 4 letter \"s\"") == true)
        XCTAssertTrue(ChatStore.letterCountFact("how many a's are in banana")?.contains("has 3 letter \"a\"") == true)
    }

    func testIgnoresOrdinaryQuestions() {
        XCTAssertNil(ChatStore.letterCountFact("how many meetings did I have in march"))
        XCTAssertNil(ChatStore.letterCountFact("how many people are in the team"))
        XCTAssertNil(ChatStore.letterCountFact("what did Ryan say about the timeline?"))
    }
}
