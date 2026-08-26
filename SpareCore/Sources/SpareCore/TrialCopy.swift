import Foundation

/// Every sentence the trial says out loud.
///
/// In SpareCore rather than beside the views for the same reason
/// `EntitlementRules` is: these are promises about what the reader gets, they
/// are built from the limits rather than typed out, and they can then be
/// pinned by tests that run on Linux without waiting for a Mac.
///
/// The cap is named in the offer itself. An undisclosed cap is the App Review
/// problem this project already fixed once on the free tier's daily limit, and
/// this one hands out Opus — so "10 lessons" appears in the same breath as
/// "7 days", not in a footnote somebody finds afterwards.
public enum TrialCopy {

    // MARK: - The offer, on dismissing the first paywall

    public static let offerHeadline = "No problem."

    /// The grant, with both of its limits in it.
    ///
    /// This is not a question. The reader has already declined to pay; asking
    /// them a second question would be the shakedown the ordering rule exists
    /// to prevent. They are being told what they now have.
    public static var offerBody: String {
        "Here's Spare Premium free for \(TrialLimits.days) days — "
            + "\(TrialLimits.lessons) lessons, every length, no card needed. "
            + "We'll show you what you've learned at the end."
    }

    /// The second line, naming the one limit the headline sentence compresses.
    ///
    /// "Every length" is true and a course is a length, so a reader could
    /// reasonably read the offer as ten courses — which is $14 of inference,
    /// not $8. Saying so here costs one line and closes the gap.
    public static var offerCourseNote: String {
        let courses = TrialLimits.courses
        return "Up to \(courses) of those can be \(courses == 1 ? "a mini-course" : "mini-courses")."
    }

    public static let offerButton = "Start reading"

    // MARK: - The nudge, around day 4

    /// A progress report, not a pitch.
    ///
    /// No price, no button, no countdown framing. The reader is in the middle
    /// of something they were given; the only useful thing to say is where
    /// they are in it.
    public static func nudge(daysRemaining: Int, thingsLearned: Int) -> String {
        let days = "\(daysRemaining) \(daysRemaining == 1 ? "day" : "days") left of Premium."
        guard thingsLearned > 0 else { return days }
        return days + " You've learned \(thingsLearned) \(thingsLearned == 1 ? "thing" : "things")."
    }

    /// When the nudge starts appearing: with three days or fewer to go.
    public static let nudgeFromDaysRemaining = 3

    // MARK: - The remaining count

    /// Below this, the count moves onto Home as well as Settings.
    ///
    /// A disclosed cap creates its own mild urgency and reads as fair; the
    /// same cap discovered on refusal reads as a trick. Four is the point
    /// where it stops being trivia and starts being something to plan around.
    public static let lessonsRemainingBelow = 4

    /// Not dismissible, unlike the nudge. This one is the disclosure.
    public static func lessonsRemaining(_ count: Int) -> String {
        guard count > 0 else { return "No trial lessons left." }
        return "\(count) trial \(count == 1 ? "lesson" : "lessons") left."
    }

    // MARK: - Day 7

    public static let summaryHeadline = "Your week with Premium"

    /// The reader's own numbers, in the order the spec sets them out.
    ///
    /// Every clause is omitted when it has nothing true to say. A zero streak
    /// or a recall percentage computed from no answers would be a worse
    /// sentence than a shorter one — and this screen is the whole loss-aversion
    /// argument, so a figure the reader can tell is padding costs more than
    /// the figure was worth.
    public static func summaryLine(_ summary: TrialSummary) -> String {
        var clauses: [String] = []

        let things = summary.thingsLearned
        clauses.append("\(things) \(things == 1 ? "thing" : "things") you now know")

        // A one-day streak is not a streak. Saying so would be padding, and
        // padding is exactly what a reader checks for on this screen.
        if summary.streakDays > 1 {
            clauses.append("\(summary.streakDays)-day streak")
        }
        if let recall = summary.recallPercent {
            clauses.append("\(recall)% recall")
        }
        return clauses.joined(separator: ". ") + "."
    }

    /// What the free tier keeps. The point of the whole screen: nothing is
    /// taken away, so the decision is about what to keep having rather than
    /// what to stop losing.
    public static var summaryFreeTierNote: String {
        "Your library stays. Every lesson you read is still there, and recall keeps running on all of it. "
            + "Free covers the 3- and 7-minute lengths, one lesson a day."
    }

    public static let summaryPrimaryButton = "Keep Premium"
    public static let summarySecondaryButton = "Continue on Free"
}
