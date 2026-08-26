import XCTest
@testable import SpareCore

/// The local half of the instrumentation.
///
/// What these hold it to is mostly the boundary: which events leave the
/// device, and the fact that one device cannot compute a share.
final class FunnelTests: XCTestCase {

    /// Three of the six the server already knows -- it starts the trials,
    /// counts the lessons, and knows when a week is up. Sending those again
    /// would give one number two sources, and the client's would be the wrong
    /// one.
    func testOnlyTheTwoEventsTheServerCannotSeeAreForwarded() {
        let forwarded = FunnelEvent.allCases.filter(\.isReportedToServer)
        XCTAssertEqual(Set(forwarded), [.paywallDismissed, .converted])
    }

    func testEveryEventIsAnsweredExplicitly() {
        // Adding a case must be a decision about whether it leaves the device.
        XCTAssertEqual(FunnelEvent.allCases.count, 6)
    }

    func testSummarisesEachKind() {
        let counts = FunnelCounts.summarise([
            .paywallShown, .paywallShown,
            .paywallDismissed,
            .trialStarted,
            .trialLessonCompleted, .trialLessonCompleted, .trialLessonCompleted,
            .trialEnded,
            .converted,
        ])

        XCTAssertEqual(counts.paywallsShown, 2)
        XCTAssertEqual(counts.paywallsDismissed, 1)
        XCTAssertEqual(counts.trialsStarted, 1)
        XCTAssertEqual(counts.trialLessonsCompleted, 3)
        XCTAssertEqual(counts.trialsEnded, 1)
        XCTAssertEqual(counts.conversions, 1)
    }

    func testADeviceCountsAsEngagedAtThreeLessons() {
        let two = FunnelCounts.summarise(
            [.paywallDismissed, .trialLessonCompleted, .trialLessonCompleted]
        )
        XCTAssertEqual(two.didEngageAfterDismissal, false)

        let three = FunnelCounts.summarise(
            [.paywallDismissed, .trialLessonCompleted, .trialLessonCompleted, .trialLessonCompleted]
        )
        XCTAssertEqual(three.didEngageAfterDismissal, true)
    }

    /// Nil, not false. With no dismissal there is nothing to be a share *of*,
    /// and answering "no" would be a claim where there is only an absence --
    /// which on a screen about a 40% threshold reads as a data point.
    func testNoDismissalMeansNoAnswerRatherThanANegativeOne() {
        XCTAssertNil(FunnelCounts.summarise([]).didEngageAfterDismissal)
        XCTAssertNil(
            FunnelCounts.summarise([.trialStarted, .trialLessonCompleted])
                .didEngageAfterDismissal
        )
    }

    /// The threshold the client reads has to be the one the server counts to.
    func testTheEngagementThresholdMatchesTheServer() {
        XCTAssertEqual(FunnelThresholds.engagedLessons, 3)
        XCTAssertEqual(FunnelThresholds.healthyPercent, 40)
        XCTAssertEqual(FunnelThresholds.unhealthyPercent, 15)
    }

    func testTheNoopReporterSendsNothingAndDoesNotThrow() async {
        await NoopFunnelReporter().report(.converted)
    }
}
