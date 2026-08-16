import SwiftUI
import SpareCore

/// Re-reading a lesson already in the Library. A static render of the stored
/// body — no streaming, no revision pipeline, since the content already went
/// through both passes when it was first generated.
struct LessonDetailView: View {
    let lesson: StoredLesson
    /// Zero-based chapter to jump to on open, when this view was reached by
    /// resuming a part-read course from Home.
    var resumeChapterIndex: Int?

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppSettingsKey.textSizeStep) private var textSizeStepRaw = TextSizeStep.standard.rawValue

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }
    private var textSizeStep: TextSizeStep { TextSizeStep(rawValue: textSizeStepRaw) ?? .standard }
    private var blocks: [LessonBlock] { LessonBlockParser.parse(lesson.bodyMarkdown) }

    private var chapterEnds: [Int: Int] {
        guard lesson.window.format.isChaptered else { return [:] }
        return CourseProgress.chapterEndsByBlockID(blocks: blocks)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text(lesson.title)
                        .font(Theme.Font.largeTitle.font)
                        .foregroundStyle(palette.text)
                    Text(lesson.subtitle)
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.secondaryText)

                    ForEach(blocks) { block in
                        blockView(block)
                            // Each block carries its id so a resumed course
                            // can scroll straight to the chapter heading the
                            // reader stopped at.
                            .id(block.id)

                        if let chapter = chapterEnds[block.id] {
                            chapterProgress(chapter)
                        }
                    }
                }
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                guard
                    let index = resumeChapterIndex,
                    let target = CourseProgress.blockID(openingChapter: index, blocks: blocks)
                else { return }
                proxy.scrollTo(target, anchor: .top)
            }
        }
        .background(palette.background)
        .navigationBarTitleDisplayMode(.inline)
        // No container-level accessibilityIdentifier: see OnboardingView.
    }

    @ViewBuilder
    private func blockView(_ block: LessonBlock) -> some View {
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

    private func chapterProgress(_ chapter: Int) -> some View {
        Text(CourseProgress.completionLabel(
            chaptersCompleted: chapter,
            chapterCount: lesson.window.format.chapterCount
        ))
        .font(Theme.Font.caption.font)
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
