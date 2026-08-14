import Foundation
import SwiftData
import SpareCore

/// Generates and stores the recall question silently on arrival, so
/// tomorrow's question is instant and works offline — and handles marking a
/// lesson complete.
@MainActor
final class CompletionViewModel: ObservableObject {
    @Published private(set) var isGeneratingRecall = false

    private let provider: LessonProvider
    private let modelContext: ModelContext

    init(provider: LessonProvider, modelContext: ModelContext) {
        self.provider = provider
        self.modelContext = modelContext
    }

    func ensureRecallGenerated(for lesson: StoredLesson) async {
        let lessonID = lesson.id
        let existing = FetchDescriptor<StoredRecallItem>(
            predicate: #Predicate { $0.lessonID == lessonID }
        )
        if (try? modelContext.fetch(existing).first) != nil { return }

        isGeneratingRecall = true
        defer { isGeneratingRecall = false }

        // Best-effort: a missing recall question is not worth blocking the
        // completion screen over, so failures are silent here.
        if let question = try? await provider.generateRecallQuestion(for: lesson.lesson) {
            modelContext.insert(StoredRecallItem(question: question, lessonID: lessonID))
            try? modelContext.save()
        }
    }

    func markComplete(_ lesson: StoredLesson) {
        lesson.completedAt = .now
        lesson.scrollProgress = 1
        try? modelContext.save()
    }
}
