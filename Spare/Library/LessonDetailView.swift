import SwiftUI
import SpareCore

/// Re-reading a lesson already in the Library. A static render of the stored
/// body — no streaming, no revision pipeline, since the content already went
/// through both passes when it was first generated.
struct LessonDetailView: View {
    let lesson: StoredLesson

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppSettingsKey.textSizeStep) private var textSizeStepRaw = TextSizeStep.standard.rawValue

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }
    private var textSizeStep: TextSizeStep { TextSizeStep(rawValue: textSizeStepRaw) ?? .standard }
    private var blocks: [LessonBlock] { LessonBlockParser.parse(lesson.bodyMarkdown) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text(lesson.title)
                    .font(Theme.Font.largeTitle.font)
                    .foregroundStyle(palette.text)
                Text(lesson.subtitle)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)

                ForEach(blocks) { block in
                    switch block.kind {
                    case .heading:
                        Text(block.text)
                            .font(Theme.Font.title.font)
                            .foregroundStyle(palette.text)
                            .padding(.top, Theme.Spacing.s)
                    case .reflection:
                        Text(block.text)
                            .font(Theme.Font.scaledBody(multiplier: textSizeStep.multiplier))
                            .italic()
                            .foregroundStyle(palette.secondaryText)
                    case .paragraph:
                        Text(block.text)
                            .font(Theme.Font.scaledBody(multiplier: textSizeStep.multiplier))
                            .lineSpacing(Theme.Font.scaledBodyLineSpacing(multiplier: textSizeStep.multiplier))
                            .foregroundStyle(palette.text)
                    }
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("lessonDetail.screen")
    }
}
