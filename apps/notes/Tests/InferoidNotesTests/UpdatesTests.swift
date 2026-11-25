import XCTest
@testable import InferoidNotesKit

final class UpdatesTests: XCTestCase {
    func testReleaseVersionsCompareNumerically() {
        XCTAssertTrue(AppUpdater.isNewer("0.7.2", than: "0.7.1"))
        XCTAssertTrue(AppUpdater.isNewer("0.7.10", than: "0.7.9"))
        XCTAssertTrue(AppUpdater.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(AppUpdater.isNewer("0.7.1", than: "0.7.1"))
        XCTAssertFalse(AppUpdater.isNewer("0.7.0", than: "0.7.1"))
        XCTAssertFalse(AppUpdater.isNewer("0.7", than: "0.7.0"))
    }
}
