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
