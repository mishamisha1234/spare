import XCTest
@testable import SpareCore

final class MarkdownExportTests: XCTestCase {

    private let exportedAt = Date(timeIntervalSince1970: 1_750_000_000)

    private func lesson(
        title: String = "Why bridges hum",
        subtitle: String = "Wind makes steel sing",
        domain: String = "Engineering",
        window: TimeWindow = .three,
        body: String = "On June 10, 2000 the bridge swayed.",
        generatedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> ExportableLesson {
        ExportableLesson(
            title: title,
            subtitle: subtitle,
            domainTag: domain,
            window: window,
            bodyMarkdown: body,
            generatedAt: generatedAt ?? exportedAt,
            completedAt: completedAt
        )
    }

    // MARK: - Shape

    func testDocumentOpensWithTheLibraryTitleAndACount() {
        let markdown = MarkdownExport.document(
            lessons: [lesson(), lesson(title: "Second")], generatedAt: exportedAt
        )
        XCTAssertTrue(markdown.hasPrefix("# Things I now know"))
        XCTAssertTrue(markdown.contains("2 lessons, exported"))
    }

    func testSingleLessonIsNotPluralised() {
        let markdown = MarkdownExport.document(lessons: [lesson()], generatedAt: exportedAt)
        XCTAssertTrue(markdown.contains("1 lesson, exported"))
        XCTAssertFalse(markdown.contains("1 lessons"))
    }

    func testEmptyLibraryExportsSomethingHonestRatherThanAnEmptyFile() {
        let markdown = MarkdownExport.document(lessons: [], generatedAt: exportedAt)
        XCTAssertTrue(markdown.contains("Nothing exported yet."))
        XCTAssertFalse(markdown.contains("0 lessons"))
    }

    func testEachLessonBecomesASecondLevelHeading() {
        let markdown = MarkdownExport.document(lessons: [lesson()], generatedAt: exportedAt)
        XCTAssertTrue(markdown.contains("## Why bridges hum"))
    }

    func testNewestFirstMatchingTheLibrarysOwnOrder() {
        let older = lesson(title: "Older", generatedAt: exportedAt.addingTimeInterval(-86_400))
        let newer = lesson(title: "Newer", generatedAt: exportedAt)
        let markdown = MarkdownExport.document(lessons: [older, newer], generatedAt: exportedAt)

        let newerIndex = markdown.range(of: "## Newer")!.lowerBound
        let olderIndex = markdown.range(of: "## Older")!.lowerBound
        XCTAssertLessThan(newerIndex, olderIndex)
    }

    func testLessonsAreSeparatedByRulesButTheLastOneIsNotTrailedByOne() {
        let markdown = MarkdownExport.document(
            lessons: [lesson(title: "A"), lesson(title: "B")], generatedAt: exportedAt
        )
        XCTAssertEqual(markdown.components(separatedBy: "\n---").count - 1, 1, "one rule between two lessons")
        XCTAssertFalse(markdown.hasSuffix("---\n"), "no rule after the final lesson")
    }

    // MARK: - Metadata

    func testMetadataCarriesDomainAndLength() {
        let line = MarkdownExport.metadataLine(for: lesson(domain: "History", window: .ten))
        XCTAssertEqual(line, "History · 10 min")
    }

    func testCompletionIsNotedOnlyWhenTrue() {
        XCTAssertTrue(
            MarkdownExport.metadataLine(for: lesson(completedAt: exportedAt)).contains("completed")
        )
        XCTAssertFalse(
            MarkdownExport.metadataLine(for: lesson(completedAt: nil)).contains("completed")
        )
    }

    func testEmptySubtitleIsOmittedRatherThanLeavingStrayItalics() {
        let markdown = MarkdownExport.document(lessons: [lesson(subtitle: "")], generatedAt: exportedAt)
        XCTAssertFalse(markdown.contains("**\n"), "no empty italic line")
        XCTAssertFalse(markdown.contains("*\n*"))
    }

    // MARK: - Heading demotion

    /// A lesson's own `## ` sections have to nest under its `## ` title, or
    /// the export reads as a flat list of equal-weight headings.
    func testBodyHeadingsAreDemotedOneLevel() {
        let markdown = MarkdownExport.demoted("## The acid does the guarding\n\nProse.")
        XCTAssertTrue(markdown.contains("### The acid does the guarding"))
    }

    func testDemotionLeavesProseAndItalicsAlone() {
        let source = "Plain prose.\n\n*A reflection prompt.*"
        XCTAssertEqual(MarkdownExport.demoted(source), source)
    }

    /// A `#` inside a fenced block is a comment in someone's code sample, not
    /// a heading — demoting it would corrupt the content.
    func testHashesInsideFencedCodeAreNotTreatedAsHeadings() {
        let source = """
        ## A real heading

        ```
        # not a heading
        ```

        ## Another real heading
        """
        let demoted = MarkdownExport.demoted(source)
        XCTAssertTrue(demoted.contains("### A real heading"))
        XCTAssertTrue(demoted.contains("### Another real heading"))
        XCTAssertTrue(demoted.contains("\n# not a heading"), "code comment must survive untouched")
        XCTAssertFalse(demoted.contains("## not a heading"))
    }

    func testDemotionSurvivesAnUnclosedFence() {
        // Malformed input shouldn't throw away the rest of the document.
        let demoted = MarkdownExport.demoted("## Heading\n\n```\n# inside")
        XCTAssertTrue(demoted.contains("### Heading"))
        XCTAssertTrue(demoted.contains("# inside"))
    }

    // MARK: - Filename

    func testFilenameIsDatedAndSafeOnEveryPlatform() {
        let name = MarkdownExport.filename(generatedAt: exportedAt)
        XCTAssertTrue(name.hasPrefix("spare-library-"))
        XCTAssertTrue(name.hasSuffix(".md"))
        for illegal in [":", "/", "\\", "?", "*", "|", "\"", "<", ">"] {
            XCTAssertFalse(name.contains(illegal), "filename contains \(illegal)")
        }
    }
}
