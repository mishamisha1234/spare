import XCTest
@testable import SpareCore

final class LevelTests: XCTestCase {

    func testZeroPointsIsLevelOne() {
        XCTAssertEqual(Level.level(forPoints: 0), 1)
        XCTAssertEqual(Level.pointsRequired(forLevel: 1), 0)
    }

    func testLevelBoundariesAreExact() {
        // pointsRequired(level) == 40 * (level - 1)^2
        for level in 1...10 {
            let points = Level.pointsRequired(forLevel: level)
            XCTAssertEqual(Level.level(forPoints: points), level, "level \(level) boundary at \(points) points")
        }
    }

    func testOnePointBelowABoundaryIsStillThePreviousLevel() {
        let boundary = Level.pointsRequired(forLevel: 3)
        XCTAssertEqual(Level.level(forPoints: boundary - 1), 2)
    }

    func testLevelNeverDecreasesAsPointsIncrease() {
        var previous = Level.level(forPoints: 0)
        for points in stride(from: 0, through: 5_000, by: 17) {
            let level = Level.level(forPoints: points)
            XCTAssertGreaterThanOrEqual(level, previous)
            previous = level
        }
    }

    func testCurveFlattensGapsBetweenLevelsGrow() {
        // "Flattening" means each successive level costs strictly more
        // points than the last, not less -- the level axis grows more slowly
        // relative to points as points climb.
        let gap1 = Level.pointsRequired(forLevel: 3) - Level.pointsRequired(forLevel: 2)
        let gap2 = Level.pointsRequired(forLevel: 4) - Level.pointsRequired(forLevel: 3)
        let gap3 = Level.pointsRequired(forLevel: 5) - Level.pointsRequired(forLevel: 4)
        XCTAssertLessThan(gap1, gap2)
        XCTAssertLessThan(gap2, gap3)
    }

    func testPointsToNextLevelReachesZeroExactlyAtTheBoundary() {
        let boundary = Level.pointsRequired(forLevel: 4)
        XCTAssertEqual(Level.pointsToNextLevel(forPoints: boundary), Level.pointsRequired(forLevel: 5) - boundary)
        XCTAssertGreaterThan(Level.pointsToNextLevel(forPoints: boundary - 1), 0)
    }

    func testProgressToNextLevelIsZeroAtTheFloorAndApproachesOneAtTheCeiling() {
        let floor = Level.pointsRequired(forLevel: 3)
        let ceiling = Level.pointsRequired(forLevel: 4)
        XCTAssertEqual(Level.progressToNextLevel(forPoints: floor), 0, accuracy: 0.0001)
        XCTAssertEqual(Level.progressToNextLevel(forPoints: ceiling - 1), Double(ceiling - floor - 1) / Double(ceiling - floor), accuracy: 0.0001)
    }
}
