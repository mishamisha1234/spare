import Foundation

/// The identifier the proxy meters against.
///
/// A random UUID minted on first launch and kept in the App Group's defaults.
/// Deliberately not `identifierForVendor`, which is stable across installs of
/// any app from the same vendor and is more identity than metering needs, and
/// deliberately not the Keychain, which can survive a delete-and-reinstall and
/// would make the free tier feel unescapable to somebody switching phones.
///
/// It is spoofable, and the design assumes so. There are no accounts, so
/// nothing here proves who is asking; what it does is raise resetting the free
/// tier from "edit a value in the app's storage" to "delete the app and lose
/// your library and your recall schedule". The server's global monthly spend
/// ceiling is what actually protects the bill — see `server/README.md`.
///
/// Stored in the App Group rather than standard defaults so the widget and the
/// app agree, and so it survives an app-container migration.
enum DeviceIdentity {

    private static let key = "spare.deviceIdentifier"

    /// Minted on first read and stable thereafter.
    ///
    /// Falls back to a fresh UUID rather than a fixed placeholder if the shared
    /// defaults are unavailable: a placeholder would put every affected install
    /// on one counter, so a single stranger's lesson would exhaust the day's
    /// allowance for all of them.
    static func current(
        defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.identifier)
    ) -> String {
        guard let defaults else { return UUID().uuidString }
        if let existing = defaults.string(forKey: key), existing.count >= 8 {
            return existing
        }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: key)
        return minted
    }
}

/// Where the proxy lives, read from the bundle.
///
/// A missing or malformed value is a build configuration mistake, not something
/// to paper over at runtime: returning nil lets the injection site fall back to
/// `MockProvider` so the app still works offline, rather than sending every
/// request to a URL that cannot exist.
enum ProxyConfiguration {

    static func baseURL(bundle: Bundle = .main) -> URL? {
        guard let raw = bundle.object(forInfoDictionaryKey: "SPProxyBaseURL") as? String,
              !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme == "https"
        else { return nil }
        return url
    }
}
