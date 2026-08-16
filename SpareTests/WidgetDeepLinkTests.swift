import XCTest
import SpareCore
@testable import Spare

/// The widget builds these URLs in one process and the app parses them in
/// another, so a mismatch can't be caught by the compiler. Round-tripping
/// every case is the cheapest way to keep the two honest.
final class WidgetDeepLinkTests: XCTestCase {

    private func roundTrip(_ link: WidgetDeepLink, file: StaticString = #filePath, line: UInt = #line) {
        guard let url = link.url else {
            return XCTFail("no URL produced for \(link)", file: file, line: line)
        }
        XCTAssertEqual(WidgetDeepLink(url: url), link, file: file, line: line)
    }

    func testEveryWindowRoundTripsThroughASuggestionsLink() {
        for window in TimeWindow.allCases {
            roundTrip(.suggestions(window))
        }
    }

    func testEveryWindowRoundTripsThroughAPaywallLink() {
        for window in TimeWindow.allCases {
            roundTrip(.paywall(window))
        }
    }

    func testResumeCarriesBothLessonAndChapter() {
        roundTrip(.resumeCourse(lessonID: UUID(), chapterIndex: 2))
        roundTrip(.resumeCourse(lessonID: UUID(), chapterIndex: 0))
    }

    /// Suggestions and paywall differ only by host; confusing them would send
    /// a paying reader to a purchase screen.
    func testSuggestionsAndPaywallAreDistinctDestinations() {
        let suggestions = WidgetDeepLink.suggestions(.thirty).url
        let paywall = WidgetDeepLink.paywall(.thirty).url
        XCTAssertNotEqual(suggestions, paywall)
        XCTAssertEqual(WidgetDeepLink(url: suggestions!), .suggestions(.thirty))
        XCTAssertEqual(WidgetDeepLink(url: paywall!), .paywall(.thirty))
    }

    // MARK: - Rejecting what isn't ours

    func testForeignSchemesAreRejected() {
        XCTAssertNil(WidgetDeepLink(url: URL(string: "https://example.com/suggestions?window=ten")!))
    }

    func testUnknownHostsAreRejected() {
        XCTAssertNil(WidgetDeepLink(url: URL(string: "spare://settings")!))
    }

    func testMalformedParametersAreRejectedRatherThanDefaulted() {
        XCTAssertNil(WidgetDeepLink(url: URL(string: "spare://suggestions")!), "no window")
        XCTAssertNil(WidgetDeepLink(url: URL(string: "spare://suggestions?window=ninety")!))
        XCTAssertNil(WidgetDeepLink(url: URL(string: "spare://resume?lesson=nonsense&chapter=1")!))
        XCTAssertNil(WidgetDeepLink(url: URL(string: "spare://resume?lesson=\(UUID().uuidString)")!), "no chapter")
    }

    /// A course generated before the 45-to-30 change still deep-links, for
    /// the same reason `TimeWindow.stored` exists.
    func testLegacyWindowRawValueStillParses() {
        let url = URL(string: "spare://suggestions?window=fortyFive")!
        XCTAssertEqual(WidgetDeepLink(url: url), .suggestions(.thirty))
    }
}
