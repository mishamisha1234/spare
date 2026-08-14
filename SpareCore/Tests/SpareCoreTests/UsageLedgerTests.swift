import XCTest
@testable import SpareCore

final class UsageLedgerTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func event(
        _ kind: UsageKind,
        input: Int = 1_000,
        output: Int = 500,
        at date: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> UsageEvent {
        UsageEvent(
            kind: kind,
            model: "claude-opus-5",
            usage: TokenUsage(inputTokens: input, outputTokens: output),
            occurredAt: date
        )
    }

    func testCostIsDerivedWhenNotSupplied() {
        let recorded = event(.lessonDraft)
        XCTAssertEqual(
            recorded.estimatedCostUSD,
            CostEstimator.cost(of: TokenUsage(inputTokens: 1_000, outputTokens: 500)),
            accuracy: 0.000001
        )
    }

    func testInMemoryLedgerRecordsInOrder() async {
        let ledger = InMemoryUsageLedger()
        await ledger.record(event(.suggestions))
        await ledger.record(event(.lessonDraft))
        await ledger.record(event(.lessonRevision))

        let kinds = await ledger.events.map(\.kind)
        XCTAssertEqual(kinds, [.suggestions, .lessonDraft, .lessonRevision])
    }

    func testFilteringByKind() async {
        let ledger = InMemoryUsageLedger()
        await ledger.record(event(.chapterDraft))
        await ledger.record(event(.chapterRevision))
        await ledger.record(event(.chapterDraft))

        let drafts = await ledger.events(ofKind: .chapterDraft)
        XCTAssertEqual(drafts.count, 2)
    }

    func testTotalSumsEveryEvent() {
        let events = [event(.lessonDraft), event(.lessonRevision)]
        XCTAssertEqual(
            UsageSummary.total(events),
            events[0].estimatedCostUSD + events[1].estimatedCostUSD,
            accuracy: 0.000001
        )
    }

    func testMonthTotalExcludesOtherMonths() {
        let thisMonth = Date(timeIntervalSince1970: 1_750_000_000)
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth)!
        let events = [
            event(.lessonDraft, at: thisMonth),
            event(.lessonRevision, at: thisMonth),
            event(.suggestions, at: lastMonth),
        ]

        let total = UsageSummary.monthTotal(events, containing: thisMonth, calendar: calendar)
        XCTAssertEqual(
            total,
            events[0].estimatedCostUSD + events[1].estimatedCostUSD,
            accuracy: 0.000001
        )
        XCTAssertLessThan(total, UsageSummary.total(events))
    }

    func testMonthTotalOfAnEmptyLedgerIsZero() {
        XCTAssertEqual(
            UsageSummary.monthTotal([], containing: Date(), calendar: calendar), 0, accuracy: 0.0001
        )
    }

    func testByKindGroupsSpend() {
        let events = [
            event(.chapterDraft), event(.chapterDraft), event(.chapterRevision),
        ]
        let totals = UsageSummary.byKind(events)
        XCTAssertEqual(totals[.chapterDraft] ?? 0, events[0].estimatedCostUSD * 2, accuracy: 0.000001)
        XCTAssertEqual(totals[.chapterRevision] ?? 0, events[2].estimatedCostUSD, accuracy: 0.000001)
    }

    func testTotalTokensAccumulates() {
        let events = [
            event(.lessonDraft, input: 100, output: 200),
            event(.lessonRevision, input: 300, output: 400),
        ]
        let total = UsageSummary.totalTokens(events)
        XCTAssertEqual(total.inputTokens, 400)
        XCTAssertEqual(total.outputTokens, 600)
    }

    func testEveryKindHasALabel() {
        for kind in UsageKind.allCases {
            XCTAssertFalse(kind.label.isEmpty, "\(kind) has no label")
        }
    }

    func testEventRoundTripsThroughJSON() throws {
        let original = event(.courseOutline)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(UsageEvent.self, from: data), original)
    }

    // MARK: - Retry policy

    func testFirstAttemptNeverWaits() {
        XCTAssertEqual(RetryPolicy.standard.delay(beforeAttempt: 1), 0)
    }

    func testBackoffIsExponentialAndCapped() {
        let policy = RetryPolicy(maxAttempts: 6, initialDelay: 1, multiplier: 2, maxDelay: 5)
        XCTAssertEqual(policy.delay(beforeAttempt: 2), 1)
        XCTAssertEqual(policy.delay(beforeAttempt: 3), 2)
        XCTAssertEqual(policy.delay(beforeAttempt: 4), 4)
        XCTAssertEqual(policy.delay(beforeAttempt: 5), 5, "capped at maxDelay")
        XCTAssertEqual(policy.delay(beforeAttempt: 6), 5)
    }

    func testMaxAttemptsIsNeverBelowOne() {
        XCTAssertEqual(RetryPolicy(maxAttempts: 0).maxAttempts, 1)
    }

    func testRecordingSleeperDoesNotActuallyWait() async throws {
        let sleeper = RecordingSleeper()
        let start = Date()
        try await sleeper.sleep(seconds: 30)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays, [30])
    }
}
