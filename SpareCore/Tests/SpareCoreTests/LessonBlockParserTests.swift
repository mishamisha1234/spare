import XCTest
@testable import SpareCore

final class LessonBlockParserTests: XCTestCase {

    func testPlainParagraphsAreUnchanged() {
        let blocks = LessonBlockParser.parse("First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(blocks.map(\.text), ["First paragraph.", "Second paragraph."])
    }

    func testHeadingPrefixIsStripped() {
        let blocks = LessonBlockParser.parse("## The day it happened\n\nBody text.")
        XCTAssertEqual(blocks[0].kind, .heading)
        XCTAssertEqual(blocks[0].text, "The day it happened")
        XCTAssertEqual(blocks[1].kind, .paragraph)
    }

    func testChapterHeadingIsAHeading() {
        let blocks = LessonBlockParser.parse("## Chapter 3: The bargain\n\nBody.")
        XCTAssertEqual(blocks[0].kind, .heading)
        XCTAssertEqual(blocks[0].text, "Chapter 3: The bargain")
    }

    func testReflectionPromptStripsAsterisks() {
        let blocks = LessonBlockParser.parse("Body.\n\n*Where do you cross a bridge like this?*")
        XCTAssertEqual(blocks[1].kind, .reflection)
        XCTAssertEqual(blocks[1].text, "Where do you cross a bridge like this?")
    }

    func testEmptyStringProducesNoBlocks() {
        XCTAssertEqual(LessonBlockParser.parse(""), [])
    }

    func testExtraBlankLinesAreCollapsed() {
        let blocks = LessonBlockParser.parse("One.\n\n\n\nTwo.")
        XCTAssertEqual(blocks.map(\.text), ["One.", "Two."])
    }

    func testIDsAreSequentialInSourceOrder() {
        let blocks = LessonBlockParser.parse("## H\n\nP1\n\nP2")
        XCTAssertEqual(blocks.map(\.id), [0, 1, 2])
    }

    func testSingleAsteriskIsNotMistakenForAReflection() {
        // A lone "*" or "**" must not be treated as a reflection wrapper.
        let blocks = LessonBlockParser.parse("*\n\n**")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph])
    }

    func testEveryMockLessonParsesWithoutOrphanedMarkup() {
        for window in TimeWindow.allCases {
            let lesson = MockProvider.fixtureLesson(
                topic: MockProvider.fixtureSuggestions(for: window)[0], window: window
            )
            let blocks = LessonBlockParser.parse(lesson.bodyMarkdown)
            XCTAssertFalse(blocks.isEmpty)
            for block in blocks {
                XCTAssertFalse(block.text.hasPrefix("##"), "heading marker leaked into text")
                XCTAssertFalse(block.text.hasPrefix("*") && block.kind != .reflection, "asterisk leaked into a non-reflection block")
            }
        }
    }
}
