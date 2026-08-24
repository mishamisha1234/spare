import XCTest
@testable import SpareCore

/// The four invariants from the streaming design:
/// 1. revision stays ahead of the reader
/// 2. display is held until revision covers the opening (~250 words)
/// 3. chaptered formats work one chapter ahead
/// 4. text already shown is never mutated
final class RevisionGateTests: XCTestCase {

    private func words(_ count: Int, tag: String = "word") -> String {
        Array(repeating: tag, count: count).joined(separator: " ")
    }

    // MARK: - Invariant 2: initial hold

    func testNothingIsShownBeforeThresholdIsReached() {
        var gate = RevisionGate(window: .ten)
        gate.apply(.revisedDelta(chapter: 0, text: words(100)))
        XCTAssertEqual(gate.phase, .holding)
        XCTAssertTrue(gate.displayText.isEmpty)
        XCTAssertFalse(gate.isRevealed)
    }

    func testRevealsOnceThresholdIsReached() {
        var gate = RevisionGate(window: .ten)
        gate.apply(.revisedDelta(chapter: 0, text: words(200)))
        XCTAssertTrue(gate.displayText.isEmpty, "200 words is below the 250-word threshold")
        gate.apply(.revisedDelta(chapter: 0, text: " " + words(60)))
        XCTAssertEqual(gate.phase, .revealed)
        XCTAssertEqual(gate.displayWordCount, 260)
    }

    // MARK: - Withdrawal

    /// The one exception to invariant 4, and it must not be mistaken for a
    /// breach of it.
    ///
    /// A revision that comes back under the word floor is re-run, and what it
    /// already put on the screen has to come back off. Shown text shrinking is
    /// exactly the shape of an append-only violation, so if the rewind went
    /// through the ordinary path the gate would count it as one and then refuse
    /// to apply it — leaving the withdrawn text on screen and the retry
    /// appended underneath it.
    func testAWithdrawnRevisionIsRewoundRatherThanCountedAsAViolation() {
        var gate = RevisionGate(window: .ten)
        gate.apply(.revisedDelta(chapter: 0, text: words(400)))
        XCTAssertTrue(gate.isRevealed)
        XCTAssertEqual(gate.displayWordCount, 400)

        gate.apply(.revisionRestarted(chapter: 0))

        XCTAssertEqual(gate.displayText, "", "the withdrawn attempt is still being shown")
        XCTAssertEqual(gate.phase, .holding, "an unchaptered rewind goes back behind the curtain")
        XCTAssertEqual(gate.revisionRestarts, 1)
        XCTAssertEqual(gate.appendOnlyViolations, 0)

        // And the retry reveals normally.
        gate.apply(.revisedDelta(chapter: 0, text: words(300)))
        XCTAssertTrue(gate.isRevealed)
        XCTAssertEqual(gate.displayWordCount, 300)
        XCTAssertEqual(gate.appendOnlyViolations, 0)
    }

    /// Rewinding chapter 2 keeps chapter 1: the reader has read it, it passed
    /// its own check, and taking it back would be a bug rather than a policy.
    func testRewindingAChapterKeepsTheOnesBeforeIt() {
        var gate = RevisionGate(window: .thirty)
        gate.apply(.revisedDelta(chapter: 0, text: words(300, tag: "first")))
        gate.apply(.revisedChapterFinished(chapter: 0))
        gate.apply(.revisedDelta(chapter: 1, text: words(200, tag: "second")))
        XCTAssertEqual(gate.displayWordCount, 500)

        gate.apply(.revisionRestarted(chapter: 1))

        XCTAssertEqual(gate.displayWordCount, 300, "chapter 1 was taken back too")
        XCTAssertTrue(gate.displayText.contains("first"))
        XCTAssertFalse(gate.displayText.contains("second"))
        XCTAssertTrue(gate.isRevealed, "the reader is mid-course, not back at the opening")
        XCTAssertEqual(gate.appendOnlyViolations, 0)
    }

    func testDraftAloneNeverReveals() {
        var gate = RevisionGate(window: .ten)
        gate.apply(.draftDelta(chapter: 0, text: words(5_000)))
        gate.apply(.draftChapterFinished(chapter: 0))
        XCTAssertEqual(gate.phase, .holding)
        XCTAssertTrue(gate.displayText.isEmpty, "draft text must never reach the reader")
    }

    func testShortLessonRevealsWhenRevisionFinishesBelowThreshold() {
        var gate = RevisionGate(window: .three)
        gate.apply(.revisedDelta(chapter: 0, text: words(40)))
        XCTAssertTrue(gate.displayText.isEmpty)
        gate.apply(.revisedChapterFinished(chapter: 0))
        XCTAssertTrue(gate.isRevealed, "a fully revised body must reveal even if under threshold")
        XCTAssertEqual(gate.displayWordCount, 40)
    }

    func testHoldProgressReportsFractionOfThreshold() {
        var gate = RevisionGate(window: .ten)
        XCTAssertEqual(gate.holdProgress, 0, accuracy: 0.001)
        gate.apply(.revisedDelta(chapter: 0, text: words(125)))
        XCTAssertEqual(gate.holdProgress, 0.5, accuracy: 0.01)
        gate.apply(.revisedDelta(chapter: 0, text: " " + words(125)))
        XCTAssertEqual(gate.holdProgress, 1, accuracy: 0.001)
    }

    func testCustomThresholdIsHonoured() {
        var gate = RevisionGate(
            window: .ten,
            configuration: .init(initialRevealWords: 10, minimumLeadWords: 5)
        )
        gate.apply(.revisedDelta(chapter: 0, text: words(12)))
        XCTAssertTrue(gate.isRevealed)
    }

    // MARK: - Invariant 4: append-only display

    func testDisplayTextOnlyGrowsAndOnlyByAppending() {
        var gate = RevisionGate(window: .ten)
        var snapshots: [String] = []

        for _ in 0..<20 {
            gate.apply(.revisedDelta(chapter: 0, text: words(30) + " "))
            snapshots.append(gate.displayText)
        }

        for (previous, next) in zip(snapshots, snapshots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.count, previous.count, "display text shrank")
            XCTAssertTrue(next.hasPrefix(previous), "display text rewrote already-shown text")
        }
        XCTAssertEqual(gate.appendOnlyViolations, 0)
    }

    func testFinishedLessonBodyBecomesTheCanonicalDisplayText() {
        var gate = RevisionGate(window: .three)
        let body = words(300)
        gate.apply(.revisedDelta(chapter: 0, text: body))
        let lesson = Lesson(
            title: "T", subtitle: "S", domainTag: "D",
            bodyMarkdown: body + " " + words(20),
            surprisingClaim: "C", deeperAngles: ["a", "b", "c"]
        )
        gate.apply(.finished(lesson))
        XCTAssertEqual(gate.phase, .finished)
        XCTAssertEqual(gate.displayText, lesson.bodyMarkdown)
        XCTAssertEqual(gate.finalLesson, lesson)
        XCTAssertEqual(gate.appendOnlyViolations, 0)
    }

    func testConflictingFinalBodyIsRejectedRatherThanRewritingShownText() {
        var gate = RevisionGate(window: .three)
        let shown = words(300, tag: "original")
        gate.apply(.revisedDelta(chapter: 0, text: shown))
        XCTAssertEqual(gate.displayText, shown)

        // A final body that contradicts what the reader already saw.
        let lesson = Lesson(
            title: "T", subtitle: "S", domainTag: "D",
            bodyMarkdown: words(300, tag: "rewritten"),
            surprisingClaim: "C", deeperAngles: ["a", "b", "c"]
        )
        gate.apply(.finished(lesson))

        XCTAssertEqual(gate.displayText, shown, "shown text must survive a conflicting final body")
        XCTAssertEqual(gate.appendOnlyViolations, 1)
    }

    // MARK: - Invariant 1: revision stays ahead of the reader

    func testPacingReportsLeadInWords() {
        var gate = RevisionGate(window: .ten)
        gate.apply(.revisedDelta(chapter: 0, text: words(600)))
        gate.updateReaderWordOffset(100)
        XCTAssertEqual(gate.pacing, .ahead(words: 500))
        XCTAssertTrue(gate.isRevisionAheadOfReader)
    }

    func testPacingGoesTightInsideMinimumLead() {
        var gate = RevisionGate(window: .ten)
        gate.apply(.revisedDelta(chapter: 0, text: words(300)))
        gate.updateReaderWordOffset(250)
        XCTAssertEqual(gate.pacing, .tight(words: 50))
        XCTAssertFalse(gate.isRevisionAheadOfReader)
    }

    func testPacingStarvesWhenReaderCatchesUp() {
        var gate = RevisionGate(window: .ten)
        gate.apply(.revisedDelta(chapter: 0, text: words(300)))
        gate.updateReaderWordOffset(300)
        XCTAssertEqual(gate.pacing, .starved)
        XCTAssertFalse(gate.isRevisionAheadOfReader)
    }

    func testPacingIsCompleteOnceEverythingIsRevised() {
        var gate = RevisionGate(window: .ten)
        gate.apply(.revisedDelta(chapter: 0, text: words(300)))
        gate.apply(.revisedChapterFinished(chapter: 0))
        gate.updateReaderWordOffset(300)
        XCTAssertEqual(gate.pacing, .complete)
        XCTAssertTrue(gate.isRevisionAheadOfReader)
    }

    func testReaderOffsetIsMonotonic() {
        var gate = RevisionGate(window: .ten)
        gate.updateReaderWordOffset(400)
        gate.updateReaderWordOffset(100)
        XCTAssertEqual(gate.readerWordOffset, 400, "scrolling back must not lower the high-water mark")
        gate.updateReaderWordOffset(-50)
        XCTAssertEqual(gate.readerWordOffset, 400)
    }

    func testProgressDrivenOffsetTracksDisplayLength() {
        var gate = RevisionGate(window: .ten)
        gate.apply(.revisedDelta(chapter: 0, text: words(400)))
        gate.updateReaderProgress(0.5)
        XCTAssertEqual(gate.readerWordOffset, 200)
    }

    // MARK: - Invariant 3: chapter pipeline

    func testFirstChapterIsRequestedImmediately() {
        let gate = RevisionGate(window: .thirty)
        XCTAssertEqual(gate.chapterCount, TimeWindow.thirty.format.chapterCount)
        XCTAssertEqual(gate.nextChapterToGenerate, 0)
    }

    func testNextChapterIsPrefetchedWhileReaderIsInCurrentChapter() {
        var gate = RevisionGate(window: .thirty)
        gate.apply(.revisedDelta(chapter: 0, text: words(300)))
        gate.apply(.revisedChapterFinished(chapter: 0))
        // Reader is still in chapter 0; chapter 1 should be starting.
        XCTAssertEqual(gate.readerChapterIndex, 0)
        XCTAssertEqual(gate.nextChapterToGenerate, 1)
    }

    func testPrefetchStopsOnceNextChapterIsUnderway() {
        var gate = RevisionGate(window: .thirty)
        gate.apply(.revisedDelta(chapter: 0, text: words(300)))
        gate.apply(.revisedChapterFinished(chapter: 0))
        gate.apply(.draftDelta(chapter: 1, text: words(10)))
        XCTAssertNil(gate.nextChapterToGenerate, "one chapter ahead is enough")
    }

    func testChapterTheReaderHasEnteredTakesPriorityOverPrefetch() {
        var gate = RevisionGate(window: .thirty)
        gate.apply(.revisedDelta(chapter: 0, text: words(300)))
        gate.apply(.revisedChapterFinished(chapter: 0))
        gate.apply(.draftDelta(chapter: 1, text: words(300)))
        gate.apply(.draftChapterFinished(chapter: 1))

        // Reader crosses into chapter 1, which is drafted but not revised.
        gate.updateReaderWordOffset(300)
        XCTAssertEqual(gate.readerChapterIndex, 1)
        XCTAssertEqual(gate.nextChapterToGenerate, 1, "the reader's own chapter must be revised first")
    }

    func testReaderChapterIndexTracksRevisedChapterLengths() {
        var gate = RevisionGate(window: .thirty)
        for chapter in 0..<3 {
            gate.apply(.revisedDelta(chapter: chapter, text: words(100)))
            gate.apply(.revisedChapterFinished(chapter: chapter))
        }
        gate.updateReaderWordOffset(0)
        XCTAssertEqual(gate.readerChapterIndex, 0)
        gate.updateReaderWordOffset(150)
        XCTAssertEqual(gate.readerChapterIndex, 1)
        gate.updateReaderWordOffset(250)
        XCTAssertEqual(gate.readerChapterIndex, 2)
    }

    func testUnrevisedLaterChapterIsNotDisplayedEvenWhenRevisedOutOfOrder() {
        var gate = RevisionGate(window: .thirty)
        // Chapter 1 arrives revised before chapter 0 finishes.
        gate.apply(.revisedDelta(chapter: 0, text: words(300, tag: "first")))
        gate.apply(.revisedDelta(chapter: 1, text: words(300, tag: "second")))
        XCTAssertFalse(gate.displayText.contains("second"), "must not show a later chapter before the current one closes")

        gate.apply(.revisedChapterFinished(chapter: 0))
        XCTAssertTrue(gate.displayText.contains("second"), "chapter 1 becomes visible once chapter 0 closes")
    }

    func testSingleChapterWindowsReportOneChapter() {
        for window in [TimeWindow.three, .ten, .fifteen] {
            XCTAssertEqual(RevisionGate(window: window).chapterCount, 1)
        }
    }

    func testNoChapterToGenerateOnceEverythingIsRevised() {
        var gate = RevisionGate(window: .thirty)
        for chapter in 0..<TimeWindow.thirty.format.chapterCount {
            gate.apply(.revisedDelta(chapter: chapter, text: words(100)))
            gate.apply(.revisedChapterFinished(chapter: chapter))
        }
        XCTAssertTrue(gate.isFullyRevised)
        XCTAssertNil(gate.nextChapterToGenerate)
    }

    func testOutOfRangeChapterEventsAreIgnored() {
        var gate = RevisionGate(window: .three)
        gate.apply(.revisedDelta(chapter: 9, text: words(500)))
        XCTAssertTrue(gate.displayText.isEmpty)
        XCTAssertEqual(gate.phase, .holding)
    }

    // MARK: - Metadata and failure

    func testMetadataIsCaptured() {
        var gate = RevisionGate(window: .three)
        let metadata = LessonMetadata(title: "Why bridges hum", subtitle: "S", domainTag: "Engineering")
        gate.apply(.metadata(metadata))
        XCTAssertEqual(gate.metadata, metadata)
    }

    func testFailureIsNotRevealed() {
        var gate = RevisionGate(window: .three)
        gate.apply(.revisedDelta(chapter: 0, text: words(300)))
        gate.fail("network dropped")
        XCTAssertEqual(gate.phase, .failed("network dropped"))
        XCTAssertFalse(gate.isRevealed)
    }

    // MARK: - End to end against MockProvider

    func testFullMockStreamNeverShowsUnrevisedTextAndNeverRewrites() async throws {
        let provider = MockProvider(simulateLatency: false)
        let topic = MockProvider.fixtureSuggestions(for: .thirty)[0]
        var gate = RevisionGate(window: .thirty)
        var previous = ""
        var revealedBeforeThreshold = false

        for try await event in provider.streamLesson(topic: topic, window: .thirty, profile: .empty) {
            let wasHolding = gate.phase == .holding
            gate.apply(event)

            if wasHolding, gate.isRevealed, gate.displayWordCount < 250, !gate.isFullyRevised {
                revealedBeforeThreshold = true
            }
            XCTAssertTrue(gate.displayText.hasPrefix(previous), "rewrote shown text on \(event)")
            previous = gate.displayText
        }

        XCTAssertFalse(revealedBeforeThreshold)
        XCTAssertEqual(gate.appendOnlyViolations, 0)
        XCTAssertEqual(gate.phase, .finished)
        XCTAssertTrue(gate.isFullyRevised)

        let lesson = try XCTUnwrap(gate.finalLesson)
        XCTAssertEqual(gate.displayText, lesson.bodyMarkdown)
        XCTAssertTrue(
            TimeWindow.thirty.wordBudget.contains(gate.displayWordCount),
            "\(gate.displayWordCount) words outside \(TimeWindow.thirty.wordBudget)"
        )
    }

    func testMockStreamKeepsRevisionAheadOfASteadyReader() async throws {
        let provider = MockProvider(simulateLatency: false)
        let topic = MockProvider.fixtureSuggestions(for: .ten)[0]
        var gate = RevisionGate(window: .ten)
        var starvedWhileIncomplete = false

        for try await event in provider.streamLesson(topic: topic, window: .ten, profile: .empty) {
            gate.apply(event)
            guard gate.isRevealed else { continue }
            // A reader who has consumed everything shown minus a page of runway.
            gate.updateReaderWordOffset(max(0, gate.displayWordCount - 200))
            if gate.pacing == .starved, !gate.isFullyRevised {
                starvedWhileIncomplete = true
            }
        }

        XCTAssertFalse(starvedWhileIncomplete, "revision fell behind a reader with a 200-word runway")
    }
}
