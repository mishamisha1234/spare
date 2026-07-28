import XCTest
@testable import SpareCore

/// Stub transport: no network, so these run identically on Linux and macOS.
private struct StubTransport: HTTPTransport {
    var response: HTTPResponse
    var chunks: [Data] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse { response }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        let chunks = self.chunks
        let response = self.response
        return AsyncThrowingStream { continuation in
            guard response.isSuccess else {
                continuation.finish(throwing: HTTPTransportMapper.providerError(
                    status: response.statusCode, body: response.body
                ))
                return
            }
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

final class HTTPTransportTests: XCTestCase {

    private let url = URL(string: "https://api.anthropic.com/v1/messages")!

    func testRequestCarriesMethodHeadersAndBody() {
        let request = HTTPRequest(
            url: url,
            headers: MessagesRequest.headers(apiKey: "sk-test"),
            body: Data("{}".utf8)
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["x-api-key"], "sk-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(request.body, Data("{}".utf8))
        XCTAssertEqual(request.timeout, 300)
    }

    func testSuccessRange() {
        XCTAssertTrue(HTTPResponse(statusCode: 200, body: Data()).isSuccess)
        XCTAssertTrue(HTTPResponse(statusCode: 299, body: Data()).isSuccess)
        XCTAssertFalse(HTTPResponse(statusCode: 300, body: Data()).isSuccess)
        XCTAssertFalse(HTTPResponse(statusCode: 500, body: Data()).isSuccess)
    }

    func testStubTransportRoundTrip() async throws {
        let transport = StubTransport(response: HTTPResponse(statusCode: 200, body: Data("ok".utf8)))
        let response = try await transport.send(HTTPRequest(url: url))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "ok")
    }

    func testStreamingChunksArriveInOrder() async throws {
        let transport = StubTransport(
            response: HTTPResponse(statusCode: 200, body: Data()),
            chunks: [Data("data: a\n\n".utf8), Data("data: b\n\n".utf8)]
        )
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for try await chunk in transport.stream(HTTPRequest(url: url)) {
            events += parser.consume(chunk)
        }
        XCTAssertEqual(events.map(\.data), ["a", "b"])
    }

    func testStreamingFailsBeforeYieldingOnErrorStatus() async {
        let transport = StubTransport(
            response: HTTPResponse(statusCode: 429, body: Data(#"{"error":{"message":"slow down"}}"#.utf8))
        )
        do {
            for try await _ in transport.stream(HTTPRequest(url: url)) {
                XCTFail("must not yield on an error status")
            }
            XCTFail("expected a thrown error")
        } catch {
            XCTAssertEqual(
                error as? LessonProviderError,
                .httpStatus(code: 429, message: "slow down")
            )
        }
    }

    // MARK: - Error mapping

    func testAuthFailuresMapToMissingAPIKey() {
        for status in [401, 403] {
            XCTAssertEqual(
                HTTPTransportMapper.providerError(status: status, body: Data()),
                .missingAPIKey
            )
        }
    }

    func testOtherStatusesKeepTheirCodeAndMessage() {
        let error = HTTPTransportMapper.providerError(
            status: 529,
            body: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)
        )
        XCTAssertEqual(error, .httpStatus(code: 529, message: "Overloaded"))
        XCTAssertTrue(error.isRetryable)
    }

    func testNonJSONErrorBodyFallsBackToRawText() {
        let message = HTTPTransportMapper.message(from: Data("<html>502 Bad Gateway</html>".utf8))
        XCTAssertTrue(message.contains("502"))
    }

    func testEmptyErrorBodyStillProducesAMessage() {
        XCTAssertEqual(HTTPTransportMapper.message(from: Data()), "no response body")
    }

    func testLongErrorBodyIsTruncated() {
        let long = String(repeating: "x", count: 5_000)
        XCTAssertEqual(HTTPTransportMapper.message(from: Data(long.utf8)).count, 500)
    }
}
