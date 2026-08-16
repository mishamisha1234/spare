import SwiftUI
import SpareCore

/// What the share card needs, computed once from the library and points
/// ledger rather than passed as raw model objects — keeps this view a pure
/// function of data, renderable by `ImageRenderer` with no SwiftData
/// dependency.
struct ShareCardData {
    var heroTitles: [String]
    var remainingCount: Int
    var totalThings: Int
    var fieldsCovered: Int
    var recallPercent: Int?
    var minutesRead: Int
    var recallAnswerCount: Int
    var domainBars: [(domain: String, count: Int)]

    /// Recall is the claim this app is actually making, so the card keeps it
    /// — but not at a sample size where one wrong answer reads as a verdict.
    /// Below this it shows minutes read instead.
    static let recallDisclosureFloor = 10

    /// What the third stat should say right now.
    var thirdStat: (value: String, label: String) {
        guard recallAnswerCount >= Self.recallDisclosureFloor, let percent = recallPercent else {
            return ("\(minutesRead)", "minutes read")
        }
        return ("\(percent)%", "recall")
    }

    init(lessons: [(title: String, domain: String, minutes: Int, generatedAt: Date)], events: [PointEvent]) {
        let sorted = lessons.sorted { $0.generatedAt > $1.generatedAt }
        heroTitles = Array(sorted.prefix(4).map(\.title))
        remainingCount = max(0, sorted.count - heroTitles.count)
        totalThings = lessons.count
        minutesRead = lessons.reduce(0) { $0 + $1.minutes }
        recallAnswerCount = PointsSummary.recallAttempts(events).count

        var counts: [String: Int] = [:]
        var order: [String] = []
        for lesson in lessons {
            if counts[lesson.domain] == nil { order.append(lesson.domain) }
            counts[lesson.domain, default: 0] += 1
        }
        fieldsCovered = order.count
        domainBars = order.map { ($0, counts[$0] ?? 0) }

        if let accuracy = PointsSummary.recallAccuracy(events) {
            recallPercent = Int((accuracy * 100).rounded())
        } else {
            recallPercent = nil
        }
    }
}

/// Four real titles at full size — the hero element, never truncated. "and N
/// more" beneath in secondary color. A hairline, then three stats. A row of
/// thin bars, one per domain, height proportional to lessons in it: the
/// user's fingerprint. A small wordmark. Fixed dark background regardless of
/// the app's own theme setting — this is an artifact meant to travel outside
/// the app, not a themed screen.
struct ShareCardView: View {
    let data: ShareCardData

    private let palette = Theme.palette(for: .dark)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(data.heroTitles, id: \.self) { title in
                    Text(title)
                        .font(Theme.Font.shareHero.font)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(nil)
                }
            }

            if data.remainingCount > 0 {
                Text("and \(data.remainingCount) more")
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)
            }

            Rectangle()
                .fill(palette.border)
                .frame(height: Theme.borderWidth)

            HStack(spacing: Theme.Spacing.l) {
                stat(value: "\(data.totalThings)", label: "things known", color: palette.accent)
                stat(value: "\(data.fieldsCovered)", label: "fields", color: palette.text)
                stat(
                    value: data.thirdStat.value,
                    label: data.thirdStat.label,
                    color: palette.text
                )
            }

            if !data.domainBars.isEmpty {
                fingerprint
            }


            Text("spare")
                .font(Theme.Font.shareWordmark.font)
                .foregroundStyle(palette.secondaryText)
        }
        .padding(Theme.Spacing.l)
        // Content-sized between a floor and the full 9:16 height. Previously
        // pinned to `height` with a greedy Spacer, so a library with two
        // finished lessons rendered two titles above a third of a card of
        // empty background.
        .frame(
            width: Theme.ShareCard.width,
            alignment: .topLeading
        )
        .frame(
            minHeight: Theme.ShareCard.minHeight,
            maxHeight: Theme.ShareCard.height,
            alignment: .topLeading
        )
        .background(palette.background)
    }

    private func stat(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(value)
                .font(Theme.Font.title.font)
                .foregroundStyle(color)
            Text(label)
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
        }
    }

    private var fingerprint: some View {
        let tallest = max(data.domainBars.map(\.count).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: Theme.Spacing.xxs) {
            ForEach(data.domainBars, id: \.domain) { entry in
                Capsule()
                    .fill(palette.secondaryText)
                    .frame(
                        width: Theme.ShareCard.barWidth,
                        height: Theme.ShareCard.maxBarHeight * CGFloat(entry.count) / CGFloat(tallest)
                    )
            }
        }
        .frame(height: Theme.ShareCard.maxBarHeight, alignment: .bottom)
    }
}

#Preview {
    ShareCardView(data: ShareCardData(
        lessons: [
            (title: "Why bridges hum", domain: "Engineering", minutes: 3, generatedAt: Date()),
            (title: "The florin that priced Europe", domain: "History", minutes: 3, generatedAt: Date()),
            (title: "Why sourdough never dies", domain: "Biology", minutes: 10, generatedAt: Date()),
            (title: "Container ships and the box", domain: "Economics", minutes: 10, generatedAt: Date()),
            (title: "How typefaces steer trust", domain: "Design", minutes: 15, generatedAt: Date()),
        ],
        events: [
            PointEvent(occurredAt: .now, kind: .recallCorrect, amount: 30, sourceID: "1"),
            PointEvent(occurredAt: .now, kind: .recallIncorrect, amount: 0, sourceID: "2"),
        ]
    ))
}
