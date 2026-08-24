import Foundation

/// Where points come from, and how much each is worth.
///
/// The rule that overrides everything else here: points reward *retention*,
/// not consumption. A finished lesson earns a flat amount by length; a
/// correctly answered recall question is worth as much as finishing a full
/// 30-minute course, because remembering something is the actual
/// product this app sells, and speed-scrolling for length is not a behavior
/// worth rewarding.
public enum Points {

    /// 5 / 10 / 15 / 30 / 60 by window length — the same ascending order as the
    /// five durations themselves.
    ///
    /// Deliberately sublinear at the top and generous at the bottom. A minute
    /// is worth half a three-minute lesson rather than a third of it, because
    /// the thing being rewarded is coming back, and the 1-minute length is what
    /// somebody reaches for on a day they would otherwise read nothing.
    public static func forCompleting(_ window: TimeWindow) -> Int {
        switch window {
        case .one: return 5
        case .three: return 10
        case .seven: return 15
        case .fifteen: return 30
        case .thirty: return 60
        }
    }

    /// Flat regardless of the source lesson's length, the recall's stage, or
    /// whether it came from the next-day question or the immediate
    /// post-lesson test — the whole point is that retention outweighs
    /// consumption everywhere, not just on average.
    public static let forCorrectRecall = 30

    public static let forIncorrectRecall = 0
}
