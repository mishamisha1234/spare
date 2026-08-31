import Foundation

/// The pre-release client token, read from the bundle.
///
/// Not a secret in the sense the Anthropic key is. It ships inside the app
/// binary, where anyone holding the .ipa can read it, and it only has to hold
/// the window between the Worker going live and the first TestFlight install —
/// see `server/DEPLOY.md`. What it buys is that every `/v1/*` endpoint except
/// `/v1/status` answers 404 to anything that is not this app.
///
/// Supplied through the `SPARE_CLIENT_TOKEN` build setting rather than written
/// here as a literal, because **this repository is public**. A tracked literal
/// would publish the token on push, which makes the gate worthless before it
/// has done the one job it exists for — and CI's committed-secret scan would
/// fail the build for it anyway.
///
/// Nil is a real case, not a defensive shrug. CI builds without the token and
/// never calls the proxy; unsigned and sample builds don't either. Callers omit
/// the header rather than sending an empty one, which the server reads as an
/// unauthorised client and answers 404 — the same as sending nothing.
enum SpareClient {

    /// Resolved once. `$(` guards the case where the build setting is undefined
    /// and Xcode leaves the unexpanded `$(SPARE_CLIENT_TOKEN)` in the plist,
    /// which is a string, is not empty, and would otherwise be sent as a token.
    static let token: String? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SpareClientToken") as? String,
              !raw.isEmpty,
              !raw.hasPrefix("$(")
        else { return nil }
        return raw
    }()
}
