import XCTest
import SpareCore
@testable import Spare

/// The paywall's free-tier sentence is a promise, not decoration: it is what the
/// App Store listing follows, and it is the only place a reader is told what
/// they are giving up.
///
/// These tests exist because the sentence was briefly untrue. Cached lessons
/// were served without counting against the daily allowance, so a free reader
/// could have several a day — more the fuller the cache got — while the sheet
/// said one. Nobody would have reported that as a bug, which is exactly why it
/// needed pinning rather than remembering.
final class PaywallCopyTests: XCTestCase {

    func testDisclosureMatchesTheFreeTierRules() {
        let copy = PaywallView.freeTierDisclosure

        XCTAssertEqual(EntitlementRules.freeLessonsPerDay, 1,
                       "the sentence below says 'one lesson a day'")
        XCTAssertTrue(copy.contains("one lesson a day"), copy)
    }

    /// The free library is not capped, and the sentence has to say so
    /// unconditionally.
    ///
    /// This replaces an assertion that the copy named a ten-entry limit. That
    /// test was correct about the product it described; the product changed.
    /// The reverse trial sells the reader on keeping a library they built
    /// during a free week, so truncating that library at the moment the trial
    /// ends would take away the very thing they are being asked to keep.
    func testDisclosurePromisesTheWholeLibrary() {
        let copy = PaywallView.freeTierDisclosure
        XCTAssertTrue(copy.lowercased().contains("whole library"), copy)

        // No surviving numeric library promise. A stale "your last 10" would
        // still read as true to somebody skimming, which is the worst kind of
        // wrong copy: plausible.
        for stale in ["library entries", "last 10", "older entries"] {
            XCTAssertFalse(copy.lowercased().contains(stale), "stale library limit: \(copy)")
        }
    }

    /// Premium must not be sold on something the free tier also gives.
    ///
    /// The pitch used to open "unlocks every length, keeps your whole
    /// library, ..." — true when free showed only its last ten entries, and a
    /// false differentiator the moment that cap was removed.
    func testPremiumPitchDoesNotSellBackTheLibrary() {
        let pitch = PaywallView.premiumPitch.lowercased()
        XCTAssertFalse(pitch.contains("library"), pitch)
    }

    /// The mini-course cap is the one limit that applies after paying, and it
    /// is named on the sheet rather than discovered in Settings afterwards.
    func testPremiumPitchStatesTheMiniCourseCap() {
        XCTAssertTrue(
            PaywallView.premiumPitch.contains("\(EntitlementRules.premiumMiniCoursesPerMonth) mini-courses"),
            PaywallView.premiumPitch
        )
    }

    /// The two lengths named must be exactly the ones the server allows. If a
    /// window is ever added to or removed from the free tier, this fails rather
    /// than leaving the sheet describing a product that no longer exists.
    ///
    /// It has done its job once already: the free lengths moved from 3-and-10
    /// to 3-and-7 and this is what said so.
    func testDisclosureNamesTheFreeWindows() {
        let free = TimeWindow.allCases.filter(\.isFreeTierEligible)
        XCTAssertEqual(free, [.three, .seven], "free windows changed; the paywall sentence has not")
        XCTAssertTrue(PaywallView.freeTierDisclosure.contains("3- and 7-minute"))
    }

    /// The 1-minute length is premium, and the sentence must not imply
    /// otherwise by describing free as "the short ones".
    func testDisclosureDoesNotImplyTheShortestLengthIsFree() {
        XCTAssertFalse(TimeWindow.one.isFreeTierEligible)
        let copy = PaywallView.freeTierDisclosure.lowercased()
        XCTAssertFalse(copy.contains("1-minute"), copy)
        XCTAssertFalse(copy.contains("shortest"), copy)
    }

    /// No hedging. A disclosure that says "usually" or "up to" is one that has
    /// been written around a limit somebody was not confident in.
    func testDisclosureDoesNotHedge() {
        let copy = PaywallView.freeTierDisclosure.lowercased()
        for weasel in ["up to", "usually", "typically", "may", "roughly", "about"] {
            XCTAssertFalse(copy.contains(weasel), "hedged with \"\(weasel)\": \(copy)")
        }
    }
}
