import Foundation
import SpareCore

/// The tappable interest grid on onboarding step 2. Deliberately broad and
/// concrete rather than abstract categories — each one should read as
/// something a lesson could actually be about.
///
/// The list itself lives in `SpareCore.Domains`: the breadth achievement
/// needs the same canonical set, and achievement logic is required to stay
/// pure SpareCore, so this is a thin app-layer alias rather than a second
/// copy that could drift out of sync.
enum OnboardingDomains {
    static let all: [String] = Domains.all
}
