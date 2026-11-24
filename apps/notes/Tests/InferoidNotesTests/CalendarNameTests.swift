import XCTest
@testable import InferoidNotesKit

final class CalendarNameTests: XCTestCase {
    func testUsesNameWhenPresent() {
        XCTAssertEqual(MeetingCalendar.displayName(name: "Ryan Green", url: URL(string: "mailto:ryan.green@antler.co")), "Ryan Green")
    }

    func testMakesNameFromEmailOnlyGuest() {
        XCTAssertEqual(MeetingCalendar.displayName(name: nil, url: URL(string: "mailto:ryan.green@antler.co")), "Ryan Green")
        XCTAssertEqual(MeetingCalendar.displayName(name: "ryan.green@antler.co", url: nil), "Ryan Green")
        XCTAssertEqual(MeetingCalendar.displayName(name: "", url: URL(string: "mailto:ana_maria-lopez2@x.com")), "Ana Maria Lopez2")
    }

    func testNoNameWithoutAddress() {
        XCTAssertNil(MeetingCalendar.displayName(name: nil, url: nil))
        XCTAssertNil(MeetingCalendar.displayName(name: " ", url: URL(string: "https://example.com")))
    }
}

final class CalendarAddressTests: XCTestCase {
    func testAddressFromMailto() {
        XCTAssertEqual(MeetingCalendar.address(URL(string: "mailto:Mehran@Emotos.ai")), "mehran@emotos.ai")
        XCTAssertEqual(MeetingCalendar.address(nil), "")
    }
}
