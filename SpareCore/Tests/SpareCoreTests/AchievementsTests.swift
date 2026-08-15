import XCTest
@testable import SpareCore

final class AchievementsTests: XCTestCase {

    private func recallEvents(correct: Int, incorrect: Int, calendar: Calendar = .current) -> [PointEvent] {
        var events: [PointEvent] = []
        for i in 0..<correct {
            events.append(PointEvent(
                occurredAt: Date().addingTimeInterval(TimeInterval(-i * 3600)),
                kind: .recallCorrect, amount: 30, sourceID: "r\(i)"
            ))
        }
        for i in 0..<incorrect {
            events.append(PointEvent(
                occurredAt: Date().addingTimeInterval(TimeInterval(-i * 3600)),
                kind: .recallIncorrect, amount: 0, sourceID: "w\(i)"
            ))
        }
        return events
    }

    // MARK: - Counts

    func testCountAchievementsUnlockAtEachThreshold() {
        for threshold in [10, 50, 100, 500] {
            let library = LibrarySnapshot(
                completedLessonCount: threshold, completedMiniCourseCount: 0, completedDomains: []
            )
            let unlocked = Achievements.unlocked(events: [], library: library)
            XCTAssertTrue(unlocked.contains { $0.id == "count-\(threshold)" }, "threshold \(threshold) should unlock")
        }
    }

    func testCountAchievementDoesNotUnlockOneShort() {
        let library = LibrarySnapshot(completedLessonCount: 9, completedMiniCourseCount: 0, completedDomains: [])
        let unlocked = Achievements.unlocked(events: [], library: library)
        XCTAssertFalse(unlocked.contains { $0.id == "count-10" })
    }

    func testHigherCountThresholdsImplyLowerOnes() {
        let library = LibrarySnapshot(completedLessonCount: 100, completedMiniCourseCount: 0, completedDomains: [])
        let unlocked = Set(Achievements.unlocked(events: [], library: library).map(\.id))
        XCTAssertTrue(unlocked.isSuperset(of: ["count-10", "count-50", "count-100"]))
        XCTAssertFalse(unlocked.contains("count-500"))
    }

    // MARK: - Breadth

    func testBreadthUnlocksOnlyWithEveryCanonicalDomainCovered() {
        let almostAll = Array(Domains.all.dropLast())
        let short = LibrarySnapshot(completedLessonCount: 0, completedMiniCourseCount: 0, completedDomains: almostAll)
        XCTAssertFalse(Achievements.unlocked(events: [], library: short).contains { $0.id == "breadth-all" })

        let all = LibrarySnapshot(completedLessonCount: 0, completedMiniCourseCount: 0, completedDomains: Domains.all)
        XCTAssertTrue(Achievements.unlocked(events: [], library: all).contains { $0.id == "breadth-all" })
    }

    func testBreadthMatchingIsCaseInsensitive() {
        let lowercased = Domains.all.map { $0.lowercased() }
        let library = LibrarySnapshot(completedLessonCount: 0, completedMiniCourseCount: 0, completedDomains: lowercased)
        XCTAssertTrue(Achievements.unlocked(events: [], library: library).contains { $0.id == "breadth-all" })
    }

    // MARK: - Depth

    func testDepthUnlocksAtTenMiniCourses() {
        let short = LibrarySnapshot(completedLessonCount: 0, completedMiniCourseCount: 9, completedDomains: [])
        XCTAssertFalse(Achievements.unlocked(events: [], library: short).contains { $0.id == "depth-10" })

        let enough = LibrarySnapshot(completedLessonCount: 0, completedMiniCourseCount: 10, completedDomains: [])
        XCTAssertTrue(Achievements.unlocked(events: [], library: enough).contains { $0.id == "depth-10" })
    }

    // MARK: - Retention

    func testRetentionRequiresBothVolumeAndAccuracy() {
        // High accuracy, too few attempts.
        let tooFew = recallEvents(correct: 9, incorrect: 0)
        XCTAssertFalse(Achievements.unlocked(events: tooFew, library: .empty).contains { $0.id == "retention-90" })

        // Enough attempts, accuracy just under 90%.
        let lowAccuracy = recallEvents(correct: 44, incorrect: 6) // 88%
        XCTAssertFalse(Achievements.unlocked(events: lowAccuracy, library: .empty).contains { $0.id == "retention-90" })

        // Enough attempts, accuracy at exactly 90%.
        let qualifies = recallEvents(correct: 45, incorrect: 5) // 90%
        XCTAssertTrue(Achievements.unlocked(events: qualifies, library: .empty).contains { $0.id == "retention-90" })
    }

    // MARK: - Consistency

    func testConsistencyThresholdsUseDistinctActiveDays() {
        var events: [PointEvent] = []
        for day in 0..<30 {
            events.append(PointEvent(
                occurredAt: Date().addingTimeInterval(TimeInterval(-day * 86_400)),
                kind: .lessonCompleted, amount: 10, sourceID: "l\(day)"
            ))
        }
        let unlocked = Set(Achievements.unlocked(events: events, library: .empty).map(\.id))
        XCTAssertTrue(unlocked.contains("consistency-30"))
        XCTAssertFalse(unlocked.contains("consistency-100"))
    }

    // MARK: - Empty state

    func testNothingUnlocksFromNothing() {
        XCTAssertEqual(Achievements.unlocked(events: [], library: .empty), [])
    }
}
