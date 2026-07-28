import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A minimal HTTP request, expressed in value types so provider logic can be
/// tested without a network or a URLSession.
public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(
        url: URL,
        method: String = "POST",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 300
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Seam between provider logic and the network. `FoundationHTTPTransport` is
/// the shipping implementation; tests substitute a stub.
public protocol HTTPTransport: Sendable {
    /// A complete request/response round trip.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse

    /// A streaming round trip, yielding response bytes as they arrive.
    /// Throws before yielding anything if the status code is not a success.
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error>
}

/// Maps transport-level failures onto the provider's error type, so callers
/// only ever handle one error enum.
public enum HTTPTransportMapper {
    public static func providerError(status: Int, body: Data) -> LessonProviderError {
        let message = Self.message(from: body)
        switch status {
        case 401, 403: return .missingAPIKey
        default: return .httpStatus(code: status, message: message)
        }
    }

    /// Pulls `error.message` out of an API error envelope, falling back to the
    /// raw body so diagnostics are never empty.
    public static func message(from body: Data) -> String {
        if let root = try? JSONDecoder().decode(JSONValue.self, from: body),
           let message = root["error"]?["message"]?.stringValue {
            return message
        }
        let raw = String(data: body, encoding: .utf8) ?? ""
        return raw.isEmpty ? "no response body" : String(raw.prefix(500))
    }
}

/// URLSession-backed transport.
///
/// On Apple platforms streaming uses `URLSession.bytes(for:)`. Elsewhere —
/// Linux and Windows, where this package is only exercised by tests — it falls
/// back to a buffered request so the type still compiles and behaves.
public struct FoundationHTTPTransport: HTTPTransport {

    public init() {}

    private func urlRequest(from request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        return urlRequest
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = urlRequest(from: request)
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: LessonProviderError.network(error.localizedDescription))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.resume(returning: HTTPResponse(statusCode: status, body: data ?? Data()))
            }
            task.resume()
        }
    }

    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if canImport(Darwin)
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest(from: request))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        // Drain the body so the error message is usable.
                        var body = Data()
                        for try await byte in bytes where body.count < 4_096 {
                            body.append(byte)
                        }
                        throw HTTPTransportMapper.providerError(status: status, body: body)
                    }
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        // Flush on record boundaries so the SSE parser sees
                        // events promptly without a syscall per byte.
                        if buffer.count >= 512 || byte == 0x0A {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    #else
                    let response = try await send(request)
                    guard response.isSuccess else {
                        throw HTTPTransportMapper.providerError(
                            status: response.statusCode, body: response.body
                        )
                    }
                    continuation.yield(response.body)
                    #endif
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LessonProviderError.cancelled)
                } catch let error as LessonProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LessonProviderError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
