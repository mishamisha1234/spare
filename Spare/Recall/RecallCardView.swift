import SwiftUI
import SwiftData
import SpareCore

/// The one-question-per-session recall card shown above the time circles on
/// Home when something is due. Answering is immediate: tap an option, see
/// the right answer and the stored explanation right there, no separate
/// screen. Dismissible without answering — the item simply stays due and
/// can show again next time Home appears.
struct RecallCardView: View {
    let item: StoredRecallItem
    var onViewLesson: (UUID) -> Void
    var onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.pointsLedger) private var pointsLedger
    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    @State private var isRevealed = false

    private var options: [String] { item.options }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            header

            Text(item.question)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.text)
                // .fixedSize without this, a tight layout (this card plus
                // the four circles all competing for one non-scrolling
                // screen) compresses this Text vertically before it touches
                // the Spacers -- confirmed on the CI screenshot, which
                // showed the question cut off mid-word with an ellipsis. The
                // option rows below don't have this problem because their
                // `.frame(minHeight:)` already protects them from being
                // squeezed the same way.
                // .lineLimit alongside it gives the card a real height
                // ceiling: without one, a genuinely long question pushed the
                // circles below it right off the fixed, non-scrolling
                // screen -- also confirmed on a CI screenshot, this time the
                // "10 min" circle overlapping the card's bottom edge. Recall
                // questions are meant to be one short sentence, so 2 lines
                // is generous, not a real-world truncation risk.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Theme.Spacing.xs) {
                ForEach(options, id: \.self) { option in
                    optionRow(option)
                }
            }

            if isRevealed {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(item.explanation)
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        onViewLesson(item.lessonID)
                    } label: {
                        Text("View the lesson")
                            .font(Theme.Font.label.font)
                            .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recall.viewLesson")
                }
            }
        }
        .padding(Theme.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
        )
        // No container-level accessibilityIdentifier: see OnboardingView —
        // confirmed to clobber every descendant's own identifier. This is
        // exactly what broke here: "recall.option.*" existed visually
        // (confirmed via the CI screenshot) but wasn't findable by identifier
        // once a "recall.card" identifier sat on the container above it.
        // recall.option.*, recall.viewLesson, and recall.dismiss are what's
        // tested; nothing needs one at this level too.
    }

    private var header: some View {
        HStack {
            Text("ONE QUESTION")
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(palette.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recall.dismiss")
            .accessibilityLabel("Dismiss question")
        }
    }

    private func optionRow(_ option: String) -> some View {
        let isCorrectOption = option == item.answer
        return Button {
            guard !isRevealed else { return }
            select(option)
        } label: {
            HStack {
                Text(option)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(rowTextColor(isCorrectOption: isCorrectOption))
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(minHeight: Theme.ControlSize.optionRow)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(rowBorderColor(isCorrectOption: isCorrectOption), lineWidth: Theme.borderWidth)
            )
            // A stroke only draws pixels along the border, so without this
            // the row's interior isn't hit-testable at all -- confirmed via
            // the CI accessibility tree: the tap landed at the frame's
            // center, past the short left-aligned label, and silently did
            // nothing because nothing there could receive it.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRevealed)
        .accessibilityIdentifier("recall.option.\(option)")
    }

    private func rowBorderColor(isCorrectOption: Bool) -> Color {
        guard isRevealed else { return palette.border }
        return isCorrectOption ? palette.accent : palette.border
    }

    private func rowTextColor(isCorrectOption: Bool) -> Color {
        guard isRevealed else { return palette.text }
        return isCorrectOption ? palette.text : palette.secondaryText
    }

    private func select(_ option: String) {
        isRevealed = true
        let correct = option == item.answer
        item.record(correct: correct)
        try? modelContext.save()
        NotificationScheduler.reschedule(modelContext: modelContext)

        let ledger = pointsLedger
        let event = PointEvent(
            occurredAt: .now,
            kind: correct ? .recallCorrect : .recallIncorrect,
            amount: correct ? Points.forCorrectRecall : Points.forIncorrectRecall,
            sourceID: item.lessonID.uuidString
        )
        Task { await ledger.record(event) }
    }
}
