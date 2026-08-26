import XCTest
@testable import Spare

/// The registry, and the reset that is derived from it.
///
/// This is the half of the guarantee that can be written in Swift. The other
/// half — that no key exists outside the registry at all — cannot be: nothing
/// can enumerate every `@AppStorage` key in a module at runtime, because
/// `AppStorage` does not expose its key and `Mirror` would need an instance of
/// every view that declares one. That half is a CI grep guard, in `ci.yml`.
///
/// What broke without both: the trial's four flags went straight into
/// `@AppStorage` and never reached the hand-written reset list, so the second
/// and third launches of a UI test ran on the first one's leftovers, and the
/// failure looked like three unrelated flakes.
final class AppSettingsKeyTests: XCTestCase {

    /// A defaults suite of its own, so nothing here can disturb the simulator's
    /// real preferences or another test's.
    private func makeDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "AppSettingsKeyTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testResetClearsEveryDeclaredKey() throws {
        let defaults = try makeDefaults()

        // Written as strings through the raw value on purpose: this test is
        // about the registry, so it must not depend on the typed overloads
        // that read from it.
        for key in AppSettingsKey.allCases {
            defaults.set("occupied", forKey: key.rawValue)
        }
        for key in AppSettingsKey.allCases {
            XCTAssertNotNil(defaults.object(forKey: key.rawValue), "\(key) was not set up")
        }

        AppSettingsKey.resetAll(in: defaults)

        for key in AppSettingsKey.allCases {
            XCTAssertNil(
                defaults.object(forKey: key.rawValue),
                "\(key.rawValue) survived a reset — it is declared but not cleared"
            )
        }
    }

    /// Adding a case is the whole of the work. There is no second list to
    /// update, which is the property the old code did not have.
    func testTheResetIsDrivenByTheRegistryAndNotAList() throws {
        let defaults = try makeDefaults()
        XCTAssertFalse(AppSettingsKey.allCases.isEmpty)

        // Every case's raw value is distinct: two cases sharing a string would
        // make one of them silently unresettable by the other's name.
        let rawValues = AppSettingsKey.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count, "duplicate raw values: \(rawValues)")

        defaults.set(true, forKey: AppSettingsKey.hasCompletedOnboarding)
        AppSettingsKey.resetAll(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: AppSettingsKey.hasCompletedOnboarding))
    }

    /// The device identifier is not an app setting and must survive.
    ///
    /// It lives in the App Group suite under its own key. Clearing it on a
    /// UI-test reset would hand every launch a new device and a fresh free
    /// allowance, which is the opposite of a clean slate — and in production
    /// it would reset somebody's trial eligibility on a whim.
    func testTheDeviceIdentifierIsNotInTheRegistry() {
        XCTAssertFalse(
            AppSettingsKey.allCases.map(\.rawValue).contains("spare.deviceIdentifier"),
            "the device identifier must not be resettable as though it were a preference"
        )
    }

    /// Reset touches only what it declares, so a neighbouring key in the same
    /// suite is left alone.
    func testResetLeavesUnrelatedKeysAlone() throws {
        let defaults = try makeDefaults()
        defaults.set("keep me", forKey: "spare.deviceIdentifier")

        AppSettingsKey.resetAll(in: defaults)

        XCTAssertEqual(defaults.string(forKey: "spare.deviceIdentifier"), "keep me")
    }
}
