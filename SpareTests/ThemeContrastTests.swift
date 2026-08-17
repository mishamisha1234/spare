import XCTest
@testable import Spare

/// WCAG contrast, recomputed from the palette rather than recorded as
/// once-checked numbers.
///
/// This exists because the amber shipped for five phases at ~3.0:1 against
/// the background and nobody noticed: it looks fine, and "looks fine" is not
/// a measurement. A palette tweak that drops a pair below the line should
/// fail here rather than reach a screenshot.
final class ThemeContrastTests: XCTestCase {

    /// WCAG 2.1 relative luminance.
    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel((hex >> 16) & 0xFF)
        let g = channel((hex >> 8) & 0xFF)
        let b = channel(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// AA for text below the large-text threshold.
    private let bodyMinimum = 4.5

    private func assertAA(
        _ foreground: UInt32,
        on background: UInt32,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ratio = contrast(foreground, background)
        XCTAssertGreaterThanOrEqual(
            ratio, bodyMinimum,
            String(format: "%@ is %.2f:1, below the %.1f:1 needed for body text", what, ratio, bodyMinimum),
            file: file, line: line
        )
    }

    // MARK: - Light

    /// The pair the course circle's 13pt subtitle depends on, and the one
    /// that was failing.
    func testLightTextOnAccentClearsAA() {
        assertAA(Theme.Hex.lightTextOnAccent, on: Theme.Hex.lightAccent, "light text on accent")
    }

    /// Used for links like "View the lesson" at 15pt.
    func testLightAccentOnBackgroundClearsAA() {
        assertAA(Theme.Hex.lightAccent, on: Theme.Hex.lightBackground, "light accent on background")
    }

    func testLightBodyAndSecondaryTextClearAA() {
        assertAA(Theme.Hex.lightText, on: Theme.Hex.lightBackground, "light text on background")
        assertAA(Theme.Hex.lightSecondaryText, on: Theme.Hex.lightBackground, "light secondary on background")
    }

    // MARK: - Dark

    func testDarkTextOnAccentClearsAA() {
        assertAA(Theme.Hex.darkTextOnAccent, on: Theme.Hex.darkAccent, "dark text on accent")
    }

    func testDarkAccentOnBackgroundClearsAA() {
        assertAA(Theme.Hex.darkAccent, on: Theme.Hex.darkBackground, "dark accent on background")
    }

    func testDarkBodyAndSecondaryTextClearAA() {
        assertAA(Theme.Hex.darkText, on: Theme.Hex.darkBackground, "dark text on background")
        assertAA(Theme.Hex.darkSecondaryText, on: Theme.Hex.darkBackground, "dark secondary on background")
    }

    /// The tightest pair in the palette, called out on its own.
    ///
    /// Near-white on the light accent measures 4.5199:1 against a 4.5
    /// threshold — it clears AA by 0.02. That is not comfort, it is a
    /// coincidence, and any future change to the light accent almost
    /// certainly breaks it. This test is the tripwire.
    ///
    /// Worth recording why it is this tight. A design review proposed
    /// flipping the ink to #1A1A1A, citing 5.39:1 — correct against the
    /// accent at the time (#C87F2E), which has since been darkened to
    /// #A06525. Against the current accent that flip gives 3.63:1. The two
    /// requirements cannot both be met by one accent: dark ink on accent
    /// needs luminance >= 0.223, accent as text on the background needs
    /// <= 0.172. Keeping the ink light is the side that satisfies both.
    func testTightestPairStillClearsAA() {
        let ratio = contrast(Theme.Hex.lightTextOnAccent, Theme.Hex.lightAccent)
        XCTAssertGreaterThanOrEqual(
            ratio, 4.5,
            String(format: "light text on accent is %.4f:1 — the 17pt button labels need 4.5", ratio)
        )
        // Fails loudly if someone "improves" the accent and eats the margin.
        XCTAssertLessThan(
            ratio, 6.0,
            "the margin got much larger — good, but update the README note that calls this 0.02"
        )
    }

    /// The alternative the review proposed, asserted as *not* an improvement,
    /// so nobody re-applies it from the review document later.
    func testProposedDarkInkOnAccentWouldFailAgainstTheCurrentAccent() {
        let proposed = contrast(0x1A1A1A, Theme.Hex.lightAccent)
        XCTAssertLessThan(
            proposed, 4.5,
            "dark ink now passes — the accent must have changed, so revisit which ink to use"
        )
    }

    // MARK: - Non-text UI

    /// WCAG's threshold for the boundary of a control, which is lower than
    /// for text but not absent — a 1.4:1 edge is not a visible affordance.
    private let uiMinimum = 3.0

    private func assertUI(
        _ foreground: UInt32,
        on background: UInt32,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ratio = contrast(foreground, background)
        XCTAssertGreaterThanOrEqual(
            ratio, uiMinimum,
            String(format: "%@ is %.2f:1, below the %.1f:1 needed for a control edge", what, ratio, uiMinimum),
            file: file, line: line
        )
    }

    func testInteractiveBordersAreVisibleInBothModes() {
        assertUI(Theme.Hex.lightBorderInteractive, on: Theme.Hex.lightBackground, "light interactive border")
        assertUI(Theme.Hex.darkBorderInteractive, on: Theme.Hex.darkBackground, "dark interactive border")
    }

    /// The decorative `border` is deliberately *not* held to 3:1 — it
    /// separates rows rather than bounding controls. This asserts the two
    /// are actually different, so a later edit can't collapse them and
    /// silently make every control edge invisible again.
    func testDecorativeAndInteractiveBordersAreDistinct() {
        XCTAssertNotEqual(Theme.Hex.lightBorder, Theme.Hex.lightBorderInteractive)
        XCTAssertNotEqual(Theme.Hex.darkBorder, Theme.Hex.darkBorderInteractive)
        XCTAssertGreaterThan(
            contrast(Theme.Hex.lightBorderInteractive, Theme.Hex.lightBackground),
            contrast(Theme.Hex.lightBorder, Theme.Hex.lightBackground)
        )
    }

    // MARK: - The maths itself

    /// Guards the helper, so a broken formula can't quietly pass everything.
    func testContrastFormulaAgainstKnownValues() {
        XCTAssertEqual(contrast(0xFFFFFF, 0x000000), 21, accuracy: 0.01, "black on white is the maximum")
        XCTAssertEqual(contrast(0xFFFFFF, 0xFFFFFF), 1, accuracy: 0.01, "a colour against itself is the minimum")
        // Mid grey on white, a widely published reference value.
        XCTAssertEqual(contrast(0x808080, 0xFFFFFF), 3.95, accuracy: 0.02)
    }

    func testContrastIsSymmetric() {
        XCTAssertEqual(
            contrast(Theme.Hex.lightAccent, Theme.Hex.lightBackground),
            contrast(Theme.Hex.lightBackground, Theme.Hex.lightAccent),
            accuracy: 0.0001
        )
    }
}
