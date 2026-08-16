import Foundation

/// One entry in an export. A value type rather than the SwiftData model, so
/// the formatting is testable on Linux and can't accidentally depend on
/// anything that only exists inside the app.
public struct ExportableLesson: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var domainTag: String
    public var window: TimeWindow
    public var bodyMarkdown: String
    public var generatedAt: Date
    public var completedAt: Date?

    public init(
        title: String,
        subtitle: String,
        domainTag: String,
        window: TimeWindow,
        bodyMarkdown: String,
        generatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.domainTag = domainTag
        self.window = window
        self.bodyMarkdown = bodyMarkdown
        self.generatedAt = generatedAt
        self.completedAt = completedAt
    }
}

/// Turns a library into one Markdown document.
///
/// Plain Markdown, no front matter, no proprietary wrapper: the point of an
/// export is that it opens in something other than this app. It should paste
/// into Obsidian, Bear, or a text editor and read correctly with no cleanup.
public enum MarkdownExport {

    /// Heading levels shift down by one so each lesson's own `## ` section
    /// headings nest under its `## ` title without colliding — a lesson title
    /// becomes `## `, its internal sections `### `.
    public static func document(
        lessons: [ExportableLesson],
        generatedAt: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        var lines: [String] = ["# Things I now know", ""]

        if lessons.isEmpty {
            lines.append("Nothing exported yet.")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        lines.append("\(lessons.count) \(lessons.count == 1 ? "lesson" : "lessons"), exported \(dateFormatter.string(from: generatedAt)).")
        lines.append("")

        // Newest first, matching the Library's own order so the export isn't
        // a differently-sorted surprise.
        let ordered = lessons.sorted { $0.generatedAt > $1.generatedAt }

        for lesson in ordered {
            lines.append("## \(lesson.title)")
            lines.append("")
            if !lesson.subtitle.isEmpty {
                lines.append("*\(lesson.subtitle)*")
                lines.append("")
            }
            lines.append(metadataLine(for: lesson))
            lines.append("")
            lines.append(demoted(lesson.bodyMarkdown))
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        // Drop the trailing rule: a separator after the last item separates
        // it from nothing.
        if lines.suffix(2) == ["---", ""] {
            lines.removeLast(2)
        }

        return lines.joined(separator: "\n")
    }

    static func metadataLine(for lesson: ExportableLesson) -> String {
        var parts = [lesson.domainTag, lesson.window.label]
        if lesson.completedAt != nil {
            parts.append("completed")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Pushes every ATX heading down one level so lesson bodies nest under
    /// their own title. Fenced code blocks are skipped — a `#` comment inside
    /// one is code, not a heading.
    static func demoted(_ markdown: String) -> String {
        var inFence = false
        return markdown
            .components(separatedBy: "\n")
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") {
                    inFence.toggle()
                    return line
                }
                guard !inFence, trimmed.hasPrefix("#") else { return line }
                return "#" + line
            }
            .joined(separator: "\n")
    }

    /// A filename safe on every platform the file might land on, including
    /// the ones that dislike colons in a timestamp.
    public static func filename(generatedAt: Date = .now) -> String {
        "spare-library-\(fileDateFormatter.string(from: generatedAt)).md"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
