import Foundation

/// Where points come from, and how much each is worth.
///
/// The rule that overrides everything else here: points reward *retention*,
/// not consumption. A finished lesson earns a flat amount by length; a
/// correctly answered recall question is worth as much as finishing a full
/// 45-minute mini-course, because remembering something is the actual
/// product this app sells, and speed-scrolling for length is not a behavior
/// worth rewarding.
public enum Points {

    /// 10 / 20 / 30 / 60 by window length — the same ascending order as the
    /// four durations themselves.
    public static func forCompleting(_ window: TimeWindow) -> Int {
        switch window {
        case .three: return 10
        case .ten: return 20
        case .fifteen: return 30
        case .fortyFive: return 60
        }
    }

    /// Flat regardless of the source lesson's length, the recall's stage, or
    /// whether it came from the next-day question or the immediate
    /// post-lesson test — the whole point is that retention outweighs
    /// consumption everywhere, not just on average.
    public static let forCorrectRecall = 30

    public static let forIncorrectRecall = 0
}
