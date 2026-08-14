import XCTest
@testable import SpareCore

final class StreamingJSONFieldExtractorTests: XCTestCase {

    private func extractAll(_ json: String, field: String = "bodyMarkdown", chunkSize: Int = 1) -> String {
        var extractor = StreamingJSONFieldExtractor(field: field)
        var emitted = ""
        for chunk in chunks(of: json, size: chunkSize) {
            emitted += extractor.consume(chunk)
        }
        return emitted
    }

    private func chunks(of text: String, size: Int) -> [String] {
        guard size > 1 else { return text.map(String.init) }
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end]))
            index = end
        }
        return result
    }

    // MARK: - Basics

    func testExtractsTargetField() {
        let json = #"{"title":"T","bodyMarkdown":"Hello there","domainTag":"D"}"#
        XCTAssertEqual(extractAll(json), "Hello there")
    }

    func testEmitsIncrementallyRatherThanAtTheEnd() {
        var extractor = StreamingJSONFieldExtractor(field: "bodyMarkdown")
        _ = extractor.consume(#"{"bodyMarkdown":"Hel"#)
        XCTAssertEqual(extractor.accumulated, "Hel", "text must be available before the value closes")
        let more = extractor.consume(#"lo"}"#)
        XCTAssertEqual(more, "lo")
        XCTAssertTrue(extractor.isFieldComplete)
    }

    func testAccumulatedMatchesEmittedTotal() {
        let json = #"{"bodyMarkdown":"One two three four"}"#
        var extractor = StreamingJSONFieldExtractor(field: "bodyMarkdown")
        var emitted = ""
        for chunk in chunks(of: json, size: 3) {
            emitted += extractor.consume(chunk)
        }
        XCTAssertEqual(emitted, extractor.accumulated)
    }

    func testResultIsIdenticalRegardlessOfChunkBoundaries() {
        let json = HTTPFixtures.lessonJSON(body: "Line one.\n\nLine two with \"quotes\" and a \\ backslash.")
        let reference = extractAll(json, chunkSize: 1)
        for size in [2, 3, 5, 7, 13, 64, 4_096] {
            XCTAssertEqual(extractAll(json, chunkSize: size), reference, "chunk size \(size) changed the result")
        }
    }

    // MARK: - Correctness against real JSON decoding

    func testMatchesJSONDecoderForTheSameField() throws {
        struct Payload: Decodable { let bodyMarkdown: String }
        let body = "On June 10, 2000 — a Saturday — the \"wobbly bridge\" closed.\n\nIt reopened in 2002.\tEnd."
        let json = HTTPFixtures.lessonJSON(body: body)

        let decoded = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        XCTAssertEqual(extractAll(json), decoded.bodyMarkdown)
        XCTAssertEqual(extractAll(json), body)
    }

    // MARK: - Escapes

    func testDecodesStandardEscapes() {
        let json = #"{"bodyMarkdown":"a\nb\tc\"d\\e\/f"}"#
        XCTAssertEqual(extractAll(json), "a\nb\tc\"d\\e/f")
    }

    func testDecodesUnicodeEscapes() {
        let json = #"{"bodyMarkdown":"em\u2014dash and \u00e9"}"#
        XCTAssertEqual(extractAll(json), "em—dash and é")
    }

    func testDecodesSurrogatePairs() {
        let json = #"{"bodyMarkdown":"wave \uD83D\uDC4B done"}"#
        XCTAssertEqual(extractAll(json), "wave \u{1F44B} done")
    }

    func testUnicodeEscapeSplitAcrossChunksIsNotCorrupted() {
        var extractor = StreamingJSONFieldExtractor(field: "bodyMarkdown")
        var emitted = ""
        emitted += extractor.consume(#"{"bodyMarkdown":"a\u20"#)
        emitted += extractor.consume(#"14b"}"#)
        XCTAssertEqual(emitted, "a—b")
    }

    // MARK: - The reason this isn't a substring search

    func testFieldNameAppearingInAnotherValueIsNotMatched() {
        let json = #"{"title":"All about bodyMarkdown","bodyMarkdown":"real body"}"#
        XCTAssertEqual(extractAll(json), "real body")
    }

    func testFieldNameNestedInsideAnObjectValueIsNotMatched() {
        let json = #"{"meta":{"bodyMarkdown":"decoy"},"bodyMarkdown":"real body"}"#
        XCTAssertEqual(extractAll(json), "real body")
    }

    func testFieldNameInsideAnArrayIsNotMatched() {
        let json = #"{"deeperAngles":["bodyMarkdown","other"],"bodyMarkdown":"real body"}"#
        XCTAssertEqual(extractAll(json), "real body")
    }

    func testEscapedQuoteDoesNotEndTheValueEarly() {
        let json = #"{"bodyMarkdown":"she said \"stop\" and stopped","next":"x"}"#
        XCTAssertEqual(extractAll(json), "she said \"stop\" and stopped")
    }

    func testTrailingBackslashBeforeClosingQuote() {
        let json = #"{"bodyMarkdown":"path C:\\temp\\","next":"x"}"#
        XCTAssertEqual(extractAll(json), #"path C:\temp\"#)
    }

    // MARK: - Absent / incomplete

    func testMissingFieldEmitsNothing() {
        let json = #"{"title":"T","subtitle":"S"}"#
        var extractor = StreamingJSONFieldExtractor(field: "bodyMarkdown")
        XCTAssertEqual(extractor.consume(json), "")
        XCTAssertFalse(extractor.isFieldComplete)
    }

    func testTruncatedValueIsNotMarkedComplete() {
        var extractor = StreamingJSONFieldExtractor(field: "bodyMarkdown")
        let emitted = extractor.consume(#"{"bodyMarkdown":"half a sen"#)
        XCTAssertEqual(emitted, "half a sen")
        XCTAssertFalse(extractor.isFieldComplete, "a truncated stream must not look finished")
    }

    func testOnlyTheFirstOccurrenceIsCaptured() {
        // Duplicate keys are invalid JSON, but a truncated-then-retried stream
        // could concatenate two objects; the first value must win rather than
        // silently appending a second copy.
        let json = #"{"bodyMarkdown":"first"}{"bodyMarkdown":"second"}"#
        XCTAssertEqual(extractAll(json), "first")
    }

    // MARK: - Other fields

    func testExtractsHeadingField() {
        let json = HTTPFixtures.chapterJSON(heading: "The day it happened", body: "Body text.")
        XCTAssertEqual(extractAll(json, field: "heading"), "The day it happened")
        XCTAssertEqual(extractAll(json, field: "bodyMarkdown"), "Body text.")
    }

    func testHandlesEmptyStringValue() {
        let json = #"{"bodyMarkdown":"","title":"T"}"#
        var extractor = StreamingJSONFieldExtractor(field: "bodyMarkdown")
        XCTAssertEqual(extractor.consume(json), "")
        XCTAssertTrue(extractor.isFieldComplete)
    }
}
