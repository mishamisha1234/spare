import Foundation

/// The canonical set of subject domains offered on onboarding's interest
/// picker, and the set the breadth achievement is measured against. Lives in
/// SpareCore — not the app layer, where the interest picker itself lives —
/// because achievement evaluation is required to stay pure and platform-free.
public enum Domains {
    public static let all: [String] = [
        "History", "Physics", "Biology", "Economics", "Philosophy",
        "Design", "Architecture", "Music", "Film", "Literature",
        "Psychology", "Astronomy", "Geology", "Linguistics", "Mathematics",
        "Engineering", "Medicine", "Art History", "Anthropology", "Politics",
        "Food & Cooking", "Law", "Technology", "Nature",
    ]

    /// Case-insensitive: a lesson's `domainTag` is free text the model
    /// generates, not drawn from this list, so exact-case matching would
    /// make the breadth achievement unreachable by accident rather than by
    /// design.
    public static func matches(_ domainTag: String, _ canonical: String) -> Bool {
        domainTag.caseInsensitiveCompare(canonical) == .orderedSame
    }
}
