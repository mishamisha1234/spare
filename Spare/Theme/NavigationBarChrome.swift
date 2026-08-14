import SwiftUI
import UIKit

/// Flattens UIKit's navigation-bar chrome so it matches the theme.
///
/// The toolbar shadow visible in the Phase 2 screenshots is drawn by the
/// navigation bar, not by our buttons — which is why `.buttonStyle(.plain)`
/// on the buttons themselves could not reach it. This clears the bar's
/// background and shadow across all three appearance slots (standard,
/// scroll-edge, compact); `scrollEdgeAppearance` is the one that governs the
/// unscrolled state the screenshots were taken in.
///
/// If a shadow still shows up after this, it is iOS 26's per-item "glass"
/// treatment on toolbar buttons, which has no SwiftUI-level override short of
/// abandoning `.toolbar` entirely. That trade — losing native back-swipe and
/// VoiceOver behaviour to remove a shadow — is explicitly not worth making,
/// so it stays documented in the README instead.
enum NavigationBarChrome {
    /// `@MainActor`: UIKit's appearance proxies are main-actor isolated.
    @MainActor
    static func flatten() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.backgroundEffect = nil
        appearance.shadowColor = .clear
        appearance.shadowImage = UIImage()

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.compactScrollEdgeAppearance = appearance
    }
}
