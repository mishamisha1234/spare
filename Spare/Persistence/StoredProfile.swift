import Foundation
import SwiftData
import SpareCore

/// SwiftData wrapper around `ProfileSnapshot`.
///
/// Persistence types live here, never in SpareCore. Anything crossing into
/// generation logic goes as a Sendable value copy — `@Model` classes are not
/// Sendable and must not cross actor boundaries.
@Model
final class StoredProfile {
    var interests: [String]
    var work: String
    var curiosityGaps: [String]
    var complexityRaw: String
    var createdAt: Date

    init(
        interests: [String] = [],
        work: String = "",
        curiosityGaps: [String] = [],
        complexity: Complexity = .standard,
        createdAt: Date = .now
    ) {
        self.interests = interests
        self.work = work
        self.curiosityGaps = curiosityGaps
        self.complexityRaw = complexity.rawValue
        self.createdAt = createdAt
    }

    convenience init(snapshot: ProfileSnapshot, createdAt: Date = .now) {
        self.init(
            interests: snapshot.interests,
            work: snapshot.work,
            curiosityGaps: snapshot.curiosityGaps,
            complexity: snapshot.complexity,
            createdAt: createdAt
        )
    }

    var complexity: Complexity {
        get { Complexity(rawValue: complexityRaw) ?? .standard }
        set { complexityRaw = newValue.rawValue }
    }

    /// Value copy for handing to a `LessonProvider`.
    var snapshot: ProfileSnapshot {
        ProfileSnapshot(
            interests: interests,
            work: work,
            curiosityGaps: curiosityGaps,
            complexity: complexity
        )
    }

    func apply(_ snapshot: ProfileSnapshot) {
        interests = snapshot.interests
        work = snapshot.work
        curiosityGaps = snapshot.curiosityGaps
        complexity = snapshot.complexity
    }
}
