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
    }
}

/// The shareable artifact.
///
/// Laid out in points that map 1:1 to pixels — `ShareCardPreview` renders it
/// at `scale = 1`, so the numbers here are the exported image's pixel
/// dimensions. That is why this file uses raw sizes rather than `Theme`
/// spacing: the card is a fixed-size graphic that leaves the app, not a
/// screen that adapts to a device. Its palette is still the theme's dark one
/// in both appearances.
struct ShareCardView: View {
    let data: ShareCardData

    private let palette = Theme.palette(for: .dark)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titles

            if data.remainingCount > 0 {
                Text("and \(data.remainingCount) more")
                    .font(.system(size: Metrics.moreSize, design: .default))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.top, Metrics.moreTopGap)
            }

            Rectangle()
                .fill(palette.border)
                .frame(height: Metrics.hairline)
                .padding(.top, Metrics.hairlineGap)
                .padding(.bottom, Metrics.hairlineGap)

            stats

            if !data.domainBars.isEmpty {
                fingerprint
                    .padding(.top, Metrics.barsTopGap)
            }

            Spacer(minLength: Metrics.wordmarkMinGap)

            Text("spare")
                .font(.system(size: Metrics.wordmarkSize, design: .serif))
                .foregroundStyle(palette.secondaryText)
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width, alignment: .topLeading)
        // Content-sized between a floor and the full height: a library with
        // two finished lessons rendered two titles above a third of a card of
        // empty background.
        .frame(minHeight: Metrics.minHeight, maxHeight: Metrics.height, alignment: .topLeading)
        .background(palette.background)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: Metrics.titleGap) {
            ForEach(data.heroTitles, id: \.self) { title in
                Text(title)
                    .font(.system(size: Metrics.titleSize, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.text)
                    .lineSpacing(Metrics.titleLineHeight - Metrics.titleSize)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 0) {
            stat(value: "\(data.totalThings)", label: "things known", color: palette.accent)
            stat(value: "\(data.fieldsCovered)", label: "fields", color: palette.text)
            stat(value: data.thirdStat.value, label: data.thirdStat.label, color: palette.text)
        }
    }

    private func stat(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Metrics.statLabelGap) {
            Text(value)
                .font(.system(size: Metrics.statValueSize, design: .serif))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: Metrics.statLabelSize, design: .default))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        // Three equal columns, so the numbers line up regardless of width.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One bar per domain, height proportional to lessons in it, with a
    /// three-letter label under each. Previously two 3px hairlines with no
    /// labels — unreadable at feed scale and meaningless to a stranger.
    private var fingerprint: some View {
        let maxCount = max(data.domainBars.map(\.count).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: Metrics.barGap) {
            ForEach(data.domainBars, id: \.domain) { bar in
                VStack(spacing: Metrics.barLabelGap) {
                    RoundedRectangle(cornerRadius: Metrics.barWidth / 2)
                        .fill(palette.secondaryText)
                        .frame(
                            width: Metrics.barWidth,
                            height: Metrics.barBaseHeight
                                + (CGFloat(bar.count) / CGFloat(maxCount)) * Metrics.barRange
                        )
                    Text(Self.abbreviation(for: bar.domain))
                        .font(.system(size: Metrics.barLabelSize, design: .default))
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Three letters, uppercased. Enough to recognise a domain you chose
    /// without turning the row into a legend.
    static func abbreviation(for domain: String) -> String {
        let letters = domain.filter { $0.isLetter }
        return String(letters.prefix(3)).uppercased()
    }

    /// Pixel geometry, in one place. Points here equal pixels in the export.
    enum Metrics {
        static let width: CGFloat = 1080
        static let height: CGFloat = 1350
        /// Floor for a card with fewer than four titles.
        static let minHeight: CGFloat = 900
        static let padding: CGFloat = 72

        static let titleSize: CGFloat = 68
        static let titleLineHeight: CGFloat = 78
        static let titleGap: CGFloat = 28

        static let moreSize: CGFloat = 28
        static let moreTopGap: CGFloat = 28

        static let hairline: CGFloat = 2
        static let hairlineGap: CGFloat = 56

        static let statValueSize: CGFloat = 56
        static let statLabelSize: CGFloat = 24
        static let statLabelGap: CGFloat = 12

        static let barsTopGap: CGFloat = 56
        static let barWidth: CGFloat = 28
        static let barGap: CGFloat = 16
        static let barBaseHeight: CGFloat = 40
        static let barRange: CGFloat = 200
        static let barLabelSize: CGFloat = 20
        static let barLabelGap: CGFloat = 12

        static let wordmarkSize: CGFloat = 32
        static let wordmarkMinGap: CGFloat = 56
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
