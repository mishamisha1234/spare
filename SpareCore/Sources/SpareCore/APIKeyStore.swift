import Foundation

/// Supplies the Anthropic API key to the provider.
///
/// Deliberately a protocol: the real implementation is Keychain-backed and
/// lives in the iOS app, because Security.framework has no place in a package
/// that must build on Linux. SpareCore only ever sees the abstraction, which
/// also means provider tests never need a real key.
public protocol APIKeyStore: Sendable {
    /// The stored key, or nil when the user hasn't entered one.
    func currentKey() async -> String?
}

extension APIKeyStore {
    public func hasKey() async -> Bool {
        await currentKey()?.isEmpty == false
    }
}

/// Fixed key, for tests and previews. Never used to hold a real key at runtime.
public struct StaticAPIKeyStore: APIKeyStore {
    private let key: String?

    public init(_ key: String?) {
        self.key = key
    }

    public func currentKey() async -> String? { key }

    public static let none = StaticAPIKeyStore(nil)
}
