import Foundation

/// Where a reader is inside a chaptered course, and how that is worded.
///
/// A course is the one format nobody finishes in a sitting, so its progress
/// has to survive leaving the app: Home shows the position on the circle
/// itself, and each chapter end states it rather than saving all
/// acknowledgement for the final page.
///
/// Pure arithmetic over a stored scroll fraction — no view state, no clock —
/// so the off-by-one risks in "chapter 2 of 4" are testable.
public enum CourseProgress {

    /// Zero-based chapter the reader has reached, from a 0...1 scroll
    /// fraction. Clamped at both ends: a fraction of exactly 1.0 is the last
    /// chapter, not one past it.
    public static func chapterIndex(scrollProgress: Double, chapterCount: Int) -> Int {
        guard chapterCount > 1 else { return 0 }
        let clamped = min(max(scrollProgress, 0), 1)
        let index = Int(clamped * Double(chapterCount))
        return min(index, chapterCount - 1)
    }

    /// How many chapters are fully behind the reader. Distinct from
    /// `chapterIndex`: partway through chapter 2, one chapter is *done* and
    /// the current one is not.
    public static func chaptersCompleted(scrollProgress: Double, chapterCount: Int) -> Int {
        guard chapterCount > 1 else { return scrollProgress >= 1 ? 1 : 0 }
        let clamped = min(max(scrollProgress, 0), 1)
        return min(Int(clamped * Double(chapterCount)), chapterCount)
    }

    /// "Chapter 2 of 4" — the resume label on Home's course circle. Takes a
    /// zero-based index and displays it one-based.
    public static func positionLabel(chapterIndex index: Int, chapterCount: Int) -> String {
        let display = min(max(index, 0), max(chapterCount - 1, 0)) + 1
        return "Chapter \(display) of \(chapterCount)"
    }

    /// "chapter 2 of 4 done" — shown at a chapter end, where stopping is a
    /// legitimate outcome rather than abandonment.
    public static func completionLabel(chaptersCompleted done: Int, chapterCount: Int) -> String {
        let clamped = min(max(done, 0), chapterCount)
        return "chapter \(clamped) of \(chapterCount) done"
    }

    /// Maps a block's id to the 1-based chapter number it closes.
    ///
    /// Every chapter ends with an italic reflection prompt (the content spec
    /// requires one), so reflections are the chapter boundaries. Returning a
    /// lookup keyed by block id rather than position means the caller can
    /// render it inline without tracking a running count itself — and it
    /// stays correct while a course is still streaming in.
    public static func chapterEndsByBlockID(blocks: [LessonBlock]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var chapter = 0
        for block in blocks where block.kind == .reflection {
            chapter += 1
            result[block.id] = chapter
        }
        return result
    }

    /// The index of the block that opens a given zero-based chapter, for
    /// scrolling a resumed course back to where the reader stopped. `nil` if
    /// that chapter has no heading yet.
    public static func blockID(openingChapter index: Int, blocks: [LessonBlock]) -> Int? {
        let headings = blocks.filter { $0.kind == .heading }
        guard index >= 0, index < headings.count else { return nil }
        return headings[index].id
    }

    /// A course worth offering to resume: chaptered, started, and neither
    /// finished nor still sitting at the very beginning.
    public static func isResumable(
        window: TimeWindow,
        scrollProgress: Double,
        completedAt: Date?
    ) -> Bool {
        guard window.format.isChaptered, completedAt == nil else { return false }
        return scrollProgress > 0 && scrollProgress < 1
    }
}
