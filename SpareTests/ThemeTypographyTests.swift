import XCTest
import SwiftUI
import CoreGraphics
@testable import Spare

/// Guards the one typography value that silently rendered wrong for five
/// phases.
///
/// `Theme.bodyLineSpacing` was `19 * 0.55` — a *multiplier* applied as if it
/// were a multiplier, when SwiftUI's `.lineSpacing()` adds to the font's own
/// line height instead of scaling it. The result was a 1.71x leading where
/// 1.55x was intended, and nothing failed, because the code was internally
/// consistent and the page still looked plausible.
final class ThemeTypographyTests: XCTestCase {

    /// New York at 19pt has roughly this default line height. Used to turn
    /// the additive spacing back into an effective multiple.
    private let bodyFontLineHeight: CGFloat = 22.6
    private let bodyFontSize: CGFloat = 19

    /// The specific regression: a value large enough to be a multiplier
    /// expressed in points would blow the leading out again.
    func testBodyLineSpacingIsAPointValueNotAMultiplier() {
        XCTAssertGreaterThan(Theme.bodyLineSpacing, 0)
        XCTAssertLessThanOrEqual(
            Theme.bodyLineSpacing, 12,
            "\(Theme.bodyLineSpacing) is too large to be additive points — this is how a multiplier gets passed to .lineSpacing() by mistake"
        )
    }

    /// The property that actually matters: what the reader sees.
    func testEffectiveLeadingLandsInTheIntendedBand() {
        let pitch = bodyFontLineHeight + Theme.bodyLineSpacing
        let multiple = pitch / bodyFontSize
        XCTAssertGreaterThanOrEqual(multiple, 1.35, "leading too tight for a reading column")
        XCTAssertLessThanOrEqual(
            multiple, 1.55,
            "leading is \(multiple)x — the 1.71x regression was in this direction"
        )
    }

    /// Scaling for the reader's text-size preference must scale the points,
    /// never reintroduce a multiply-by-font-size.
    func testScaledLineSpacingStaysProportionalToTheToken() {
        XCTAssertEqual(Theme.Font.scaledBodyLineSpacing(multiplier: 1), Theme.bodyLineSpacing, accuracy: 0.001)
        XCTAssertEqual(Theme.Font.scaledBodyLineSpacing(multiplier: 2), Theme.bodyLineSpacing * 2, accuracy: 0.001)
    }

    func testScaledLeadingStaysInBandAtEveryTextSize() {
        for step in TextSizeStep.allCases {
            let size = bodyFontSize * step.multiplier
            // The font's own line height scales with the font.
            let lineHeight = bodyFontLineHeight * step.multiplier
            let pitch = lineHeight + Theme.Font.scaledBodyLineSpacing(multiplier: step.multiplier)
            let multiple = pitch / size
            XCTAssertGreaterThanOrEqual(multiple, 1.35, "\(step) leading too tight")
            XCTAssertLessThanOrEqual(multiple, 1.55, "\(step) leading too loose")
        }
    }

    func testParagraphSpacingIsLargerThanLineSpacing() {
        // Otherwise a paragraph break is indistinguishable from a line break,
        // which is what it looked like before this token existed.
        XCTAssertGreaterThan(Theme.bodyParagraphSpacing, Theme.bodyLineSpacing * 2)
    }
}
