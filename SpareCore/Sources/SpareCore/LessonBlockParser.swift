import Foundation

/// The three block kinds a generated lesson body can contain, per the content
/// spec: `## ` headings, an italic reflection prompt (mini-course chapters
/// only), and prose paragraphs.
public enum LessonBlockKind: Equatable, Sendable {
    case heading
    case reflection
    case paragraph
}

public struct LessonBlock: Identifiable, Equatable, Sendable {
    public var id: Int
    public var kind: LessonBlockKind
    /// Text with the block's own markup (## , wrapping *) already stripped.
    public var text: String

    public init(id: Int, kind: LessonBlockKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Splits a lesson's `bodyMarkdown` into renderable blocks. Deliberately
/// narrow: the content spec only ever produces these three shapes, so this is
/// not a general Markdown parser.
public enum LessonBlockParser {
    public static func parse(_ markdown: String) -> [LessonBlock] {
        markdown
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, paragraph in
                if paragraph.hasPrefix("## ") {
                    return LessonBlock(id: index, kind: .heading, text: String(paragraph.dropFirst(3)))
                }
                if paragraph.hasPrefix("*"), paragraph.hasSuffix("*"), paragraph.count > 2 {
                    let inner = paragraph.dropFirst().dropLast()
                    return LessonBlock(id: index, kind: .reflection, text: String(inner))
                }
                return LessonBlock(id: index, kind: .paragraph, text: paragraph)
            }
    }
}
