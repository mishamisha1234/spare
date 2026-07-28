import Foundation

/// Ordering rules for the two-pass pipeline.
///
/// The reader **never sees unrevised text.** Pass 1 (draft) is an internal
/// input to pass 2 only; pass 2 (revision) is the sole source of displayed
/// prose. The gate enforces four invariants:
///
/// 1. **Revision stays ahead of the reader.** Lead is measured in words and
///    reported so the UI can slow the reader down (or the pipeline can be
///    prioritized) before the reader catches up to generation.
/// 2. **Display is held until revision covers the opening.** Nothing is shown
///    until pass 2 has produced `initialRevealWords` (~250) words, or has
///    finished outright for a body shorter than that.
/// 3. **Chaptered formats work one chapter ahead.** While the reader is in
///    chapter N, chapter N+1 is drafted *and* revised.
/// 4. **Text already shown is immutable.** Displayed text only ever grows, and
///    only by appending. A candidate update that would rewrite shown text is
///    rejected and recorded rather than applied.
public struct RevisionGate: Sendable, Equatable {

    // MARK: Configuration

    public struct Configuration: Sendable, Equatable {
        /// Revised words required before anything is shown.
        public var initialRevealWords: Int
        /// Revised words that must sit ahead of the reader to be comfortable.
        public var minimumLeadWords: Int
        /// How many chapters ahead of the reader to keep working on.
        public var chapterPrefetchDepth: Int

        public init(
            initialRevealWords: Int = 250,
            minimumLeadWords: Int = 150,
            chapterPrefetchDepth: Int = 1
        ) {
            self.initialRevealWords = initialRevealWords
            self.minimumLeadWords = minimumLeadWords
            self.chapterPrefetchDepth = chapterPrefetchDepth
        }

        public static let standard = Configuration()
    }

    public enum Phase: Sendable, Equatable {
        /// Buffering revision; nothing shown to the reader yet.
        case holding
        /// Revealing revised text as it arrives.
        case revealed
        /// Revision complete for the whole lesson.
        case finished
        case failed(String)
    }

    /// How much revised runway sits ahead of the reader.
    public enum Pacing: Sendable, Equatable {
        /// Comfortable lead.
        case ahead(words: Int)
        /// Ahead, but under `minimumLeadWords` — prioritize generation.
        case tight(words: Int)
        /// The reader has reached the end of revised text. The UI must show a
        /// waiting state rather than unrevised prose.
        case starved
        /// Everything is revised; lead is irrelevant.
        case complete
    }

    // MARK: Per-chapter buffers

    struct ChapterBuffer: Sendable, Equatable {
        var draft: String = ""
        var draftFinished: Bool = false
        var revised: String = ""
        var revisedFinished: Bool = false

        var isRevisionStarted: Bool { !revised.isEmpty || revisedFinished }
        var isDraftStarted: Bool { !draft.isEmpty || draftFinished }
    }

    // MARK: Stored state

    public let window: TimeWindow
    public let configuration: Configuration

    private var buffers: [ChapterBuffer]
    /// The only text the reader has ever been shown. Append-only by construction.
    private var committedText: String = ""
    private var readerWordOffsetStorage: Int = 0
    /// Canonical body from `.finished`, which supersedes the assembled runway.
    private var finalBody: String?

    public private(set) var phase: Phase = .holding
    public private(set) var metadata: LessonMetadata?
    /// Canonical lesson, available once the stream reports `.finished`.
    public private(set) var finalLesson: Lesson?
    /// Rejected updates that would have rewritten already-shown text. Always
    /// empty in correct operation; asserted on in tests.
    public private(set) var appendOnlyViolations: Int = 0

    // MARK: Init

    public init(window: TimeWindow, configuration: Configuration = .standard) {
        self.window = window
        self.configuration = configuration
        self.buffers = Array(repeating: ChapterBuffer(), count: max(1, window.format.chapterCount))
    }

    public var chapterCount: Int { buffers.count }

    // MARK: Ingesting stream events

    public mutating func apply(_ event: LessonStreamEvent) {
        switch event {
        case .metadata(let metadata):
            self.metadata = metadata

        case .draftDelta(let chapter, let text):
            guard let index = validIndex(chapter) else { return }
            buffers[index].draft += text

        case .draftChapterFinished(let chapter):
            guard let index = validIndex(chapter) else { return }
            buffers[index].draftFinished = true

        case .revisedDelta(let chapter, let text):
            guard let index = validIndex(chapter) else { return }
            buffers[index].revised += text
            refreshDisplay()

        case .revisedChapterFinished(let chapter):
            guard let index = validIndex(chapter) else { return }
            buffers[index].revisedFinished = true
            refreshDisplay()

        case .finished(let lesson):
            finalLesson = lesson
            for index in buffers.indices {
                buffers[index].revisedFinished = true
            }
            // The canonical body wins over the assembled runway: it is what gets
            // persisted, so it is what the reader must be looking at.
            finalBody = lesson.bodyMarkdown
            phase = .revealed
            refreshDisplay()
            phase = .finished
        }
    }

    public mutating func fail(_ message: String) {
        phase = .failed(message)
    }

    private func validIndex(_ chapter: Int) -> Int? {
        buffers.indices.contains(chapter) ? chapter : nil
    }

    // MARK: Display

    /// Revised text assembled in chapter order, stopping at the first chapter
    /// that is still being revised. Never includes draft text.
    private var revisedRunway: String {
        if let finalBody { return finalBody }
        var parts: [String] = []
        for buffer in buffers {
            guard buffer.isRevisionStarted else { break }
            if !buffer.revised.isEmpty {
                parts.append(buffer.revised)
            }
            if !buffer.revisedFinished { break }
        }
        return parts.joined(separator: "\n\n")
    }

    private mutating func refreshDisplay() {
        let candidate = revisedRunway

        // Invariant 2: hold the opening back until revision covers it.
        if phase == .holding {
            let allRevised = buffers.allSatisfy(\.revisedFinished)
            let coversOpening = candidate.lessonWordCount >= configuration.initialRevealWords
            guard coversOpening || allRevised else { return }
            phase = .revealed
        }

        // Invariant 4: only ever append.
        guard candidate.count >= committedText.count, candidate.hasPrefix(committedText) else {
            appendOnlyViolations += 1
            return
        }
        committedText = candidate
    }

    /// The text the Reader may render. Empty while holding.
    public var displayText: String { committedText }

    public var displayWordCount: Int { committedText.lessonWordCount }

    public var isRevealed: Bool {
        switch phase {
        case .holding, .failed: return false
        case .revealed, .finished: return true
        }
    }

    /// Progress of the initial hold, 0...1, for a determinate opening indicator.
    public var holdProgress: Double {
        guard phase == .holding else { return 1 }
        let words = revisedRunway.lessonWordCount
        return min(Double(words) / Double(max(1, configuration.initialRevealWords)), 1)
    }

    // MARK: Reader position

    /// Reader's position in words. Monotonic: scrolling back up does not
    /// reduce the high-water mark used for pacing decisions.
    public var readerWordOffset: Int { readerWordOffsetStorage }

    public mutating func updateReaderWordOffset(_ offset: Int) {
        readerWordOffsetStorage = max(readerWordOffsetStorage, max(0, offset))
    }

    /// Convenience for scroll-progress-driven UIs.
    public mutating func updateReaderProgress(_ progress: Double) {
        let total = max(displayWordCount, 1)
        updateReaderWordOffset(ReadingTime.wordOffset(totalWordCount: total, progress: progress))
    }

    /// Invariant 1, reported.
    public var pacing: Pacing {
        if case .finished = phase { return .complete }
        if buffers.allSatisfy(\.revisedFinished) { return .complete }
        let lead = displayWordCount - readerWordOffsetStorage
        if lead <= 0 { return .starved }
        if lead < configuration.minimumLeadWords { return .tight(words: lead) }
        return .ahead(words: lead)
    }

    public var isRevisionAheadOfReader: Bool {
        switch pacing {
        case .ahead, .complete: return true
        case .tight, .starved: return false
        }
    }

    // MARK: Chapter pipeline (invariant 3)

    /// Which chapter the reader is currently in, derived from word offset
    /// against revised chapter lengths.
    public var readerChapterIndex: Int {
        var consumed = 0
        for (index, buffer) in buffers.enumerated() {
            // A chapter with no revised text yet is the frontier: the reader is
            // waiting at its opening, not somewhere past it.
            guard buffer.isRevisionStarted else { return index }
            let words = buffer.revised.lessonWordCount
            if readerWordOffsetStorage < consumed + words { return index }
            consumed += words
        }
        return max(0, buffers.count - 1)
    }

    /// The next chapter the pipeline should draft-and-revise, or nil when the
    /// prefetch window is already satisfied. Chapters at or behind the reader
    /// take priority over the prefetch window.
    public var nextChapterToGenerate: Int? {
        let reader = readerChapterIndex
        // Urgent: anything up to and including the reader's chapter that is
        // not fully revised.
        for index in 0...reader where !buffers[index].revisedFinished {
            return index
        }
        // Prefetch: keep `chapterPrefetchDepth` chapters ahead in flight. A
        // chapter counts as underway once either pass has produced anything.
        let horizon = min(reader + configuration.chapterPrefetchDepth, buffers.count - 1)
        guard horizon > reader else { return nil }
        for index in (reader + 1)...horizon
        where !buffers[index].isDraftStarted && !buffers[index].isRevisionStarted {
            return index
        }
        return nil
    }

    /// True once every chapter has been revised end to end.
    public var isFullyRevised: Bool { buffers.allSatisfy(\.revisedFinished) }

    // MARK: Introspection (tests, diagnostics)

    public func draftText(chapter: Int) -> String {
        validIndex(chapter).map { buffers[$0].draft } ?? ""
    }

    public func revisedText(chapter: Int) -> String {
        validIndex(chapter).map { buffers[$0].revised } ?? ""
    }

    public func isChapterRevised(_ chapter: Int) -> Bool {
        validIndex(chapter).map { buffers[$0].revisedFinished } ?? false
    }
}
