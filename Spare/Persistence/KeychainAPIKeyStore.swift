import Foundation
import Security
import SpareCore

/// Keychain-backed storage for the Anthropic API key.
///
/// The key is entered in Settings and lives here and nowhere else: not in
/// source, not in Info.plist, not in UserDefaults, never committed. It is read
/// on demand for each request rather than held in memory.
///
/// This is still a key on a device, which is extractable by someone with the
/// device and the will to do it — see the README for why that is an accepted
/// v1 trade and what the migration path off it looks like.
struct KeychainAPIKeyStore: APIKeyStore {

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    private let service: String
    private let account: String

    init(service: String = "app.spare.ios", account: String = "anthropic-api-key") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func currentKey() async -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Stores (or replaces) the key.
    ///
    /// `ThisDeviceOnly` deliberately keeps it off iCloud Keychain: a key that
    /// syncs is a key on more devices than the user thought.
    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete()
            return
        }

        try delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
