import Foundation

/// Cumulative points → a level number.
///
/// Square-root curve: `level(points) == floor(sqrt(points / 40)) + 1`, so
/// points required for `level` is `40 * (level - 1)^2` — a plain quadratic in
/// level, which is what makes the *level* axis flatten as points climb.
/// Level 2 costs 40 points (one 3-minute lesson plus a recall), level 3
/// costs 160, level 4 costs 360: each additional level takes a meaningfully
/// bigger jump than the last, without a hard ceiling that ever stops
/// progress outright.
public enum Level {

    public static func pointsRequired(forLevel level: Int) -> Int {
        guard level > 1 else { return 0 }
        let step = level - 1
        return 40 * step * step
    }

    public static func level(forPoints points: Int) -> Int {
        guard points > 0 else { return 1 }
        return Int(Foundation.sqrt(Double(points) / 40.0)) + 1
    }

    /// Points still needed to reach the next level, for a progress readout.
    public static func pointsToNextLevel(forPoints points: Int) -> Int {
        let next = level(forPoints: points) + 1
        return max(0, pointsRequired(forLevel: next) - points)
    }

    /// 0...1 progress through the current level, for a progress bar.
    public static func progressToNextLevel(forPoints points: Int) -> Double {
        let current = level(forPoints: points)
        let floor = pointsRequired(forLevel: current)
        let ceiling = pointsRequired(forLevel: current + 1)
        guard ceiling > floor else { return 0 }
        return Double(points - floor) / Double(ceiling - floor)
    }
}
