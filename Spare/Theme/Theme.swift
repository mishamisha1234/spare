import SwiftUI
import SpareCore

/// The single source of every color, font, spacing, and radius value in the
/// app. No view may hardcode a color, font, or spacing constant outside this
/// file — that is what keeps the "quiet reading app" feel consistent as
/// screens are added.
///
/// Feel: closer to Instapaper or Kindle than to a learning app. Calm,
/// uncluttered, adult. No gamification chrome.
enum Theme {

    // MARK: - Appearance mode

    /// User-selectable appearance. `system` (the default) follows the device;
    /// `light`/`dark` pin it regardless of device setting.
    enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    // MARK: - Palette

    /// The resolved color set for one mode. Never constructed by a view
    /// directly — read through `Theme.colors(for:)`, which takes the
    /// environment's actual color scheme so `.system` resolves correctly.
    struct Palette {
        var background: Color
        var text: Color
        var secondaryText: Color
        var border: Color
        var accent: Color
        var textOnAccent: Color
    }

    private static let light = Palette(
        background: Color(hex: 0xFAF8F5),
        text: Color(hex: 0x1A1A1A),
        secondaryText: Color(hex: 0x8A837A),
        border: Color(hex: 0xD8D2C8),
        accent: Color(hex: 0xC87F2E),
        textOnAccent: Color(hex: 0xFAF8F5)
    )

    private static let dark = Palette(
        background: Color(hex: 0x111110),
        text: Color(hex: 0xE8E6E1),
        secondaryText: Color(hex: 0x8F8A80),
        border: Color(hex: 0x3A3833),
        accent: Color(hex: 0xD9924A),
        textOnAccent: Color(hex: 0x17150F)
    )

    /// Resolve the palette for a concrete `ColorScheme` (from the environment).
    /// The accent color is never shared between modes — read it through here,
    /// never as a bare hex literal in a view.
    static func palette(for scheme: ColorScheme) -> Palette {
        switch scheme {
        case .light: light
        case .dark: dark
        @unknown default: light
        }
    }

    // MARK: - Typography

    enum Font {
        /// Body copy: New York (serif), 19pt, 1.55 line spacing. Reader
        /// screen only — this is the one place prose is read at length.
        case body
        /// Screen titles ("How long do you have?").
        case largeTitle
        /// Section and lesson titles.
        case title
        /// Suggestion row titles, card headings.
        case headline
        /// UI labels, buttons, tags.
        case label
        /// Secondary/meta text: timestamps, tags, captions.
        case caption
        /// A small label sitting above a title — e.g. a suggestion's domain
        /// tag. Meant to outrank the title it sits over, not recede.
        case eyebrow
        /// The share card's hero lesson titles: the serif at display size,
        /// since the titles are the entire point of that graphic.
        case shareHero
        /// The share card's "spare" wordmark: small, quiet, serif to match
        /// the reading font the rest of the app is built on.
        case shareWordmark

        var font: SwiftUI.Font {
            switch self {
            case .body:
                // New York is SF's serif companion; `.serif` design selects it
                // on Apple platforms without naming it as a fragile string.
                return .system(size: 19, weight: .regular, design: .serif)
            case .largeTitle:
                return .system(size: 34, weight: .semibold, design: .default)
            case .title:
                return .system(size: 22, weight: .semibold, design: .default)
            case .headline:
                return .system(size: 17, weight: .medium, design: .default)
            case .label:
                return .system(size: 15, weight: .medium, design: .default)
            case .caption:
                return .system(size: 13, weight: .medium, design: .default)
            case .eyebrow:
                return .system(size: 11, weight: .semibold, design: .default)
            case .shareHero:
                return .system(size: 30, weight: .semibold, design: .serif)
            case .shareWordmark:
                return .system(size: 15, weight: .medium, design: .serif)
            }
        }

        /// Line spacing to apply via `.lineSpacing(_:)`. Only `.body` carries
        /// the 1.55 multiple; UI text uses tight, default spacing.
        var lineSpacing: CGFloat {
            switch self {
            case .body: 19 * 0.55
            default: 0
            }
        }

        /// Letter-spacing to apply via `.tracking(_:)`, in points. Only
        /// `.eyebrow` carries it — 0.08em at its own 11pt size.
        var tracking: CGFloat {
            switch self {
            case .eyebrow: 11 * 0.08
            default: 0
            }
        }

        /// Body font scaled by a reader-chosen `TextSizeStep` multiplier.
        /// Still centrally defined here — call sites never do their own math.
        static func scaledBody(multiplier: Double) -> SwiftUI.Font {
            .system(size: 19 * multiplier, weight: .regular, design: .serif)
        }

        static func scaledBodyLineSpacing(multiplier: Double) -> CGFloat {
            19 * multiplier * 0.55
        }

        /// The Home circle label scales with its diameter — size still
        /// carries the meaning, so the label must never overpower the shape.
        static func circleLabel(diameter: CGFloat) -> SwiftUI.Font {
            .system(size: max(12, diameter * 0.22), weight: .semibold, design: .default)
        }
    }

    // MARK: - Spacing

    /// The only spacing values allowed anywhere. Nothing in between.
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 16
        static let m: CGFloat = 24
        static let l: CGFloat = 40
        static let xl: CGFloat = 64
    }

    // MARK: - Shape

    /// One radius, everywhere. No shadows, no gradients — separation comes
    /// from spacing and hairline borders only.
    static let cornerRadius: CGFloat = 14
    static let borderWidth: CGFloat = 1

    // MARK: - Control sizes

    /// Fixed heights for interactive controls. Not on the 4/8/16/24/40/64
    /// spacing scale (that governs gaps between elements, not their own
    /// size) — centralized here so no view invents its own number.
    enum ControlSize {
        /// Full-width primary/secondary buttons (Continue, Mark complete, …).
        static let button: CGFloat = 52
        /// Single-line text fields — matches the accessibility minimum.
        static let textField: CGFloat = CircleSize.minimumTapTarget
        /// Selectable chips (interests, curiosity-gap entries).
        static let chip: CGFloat = 40
        /// Compact filter chips (Library domain filter).
        static let filterChip: CGFloat = 36
        /// A tappable option row (e.g. a "go deeper" angle choice).
        static let optionRow: CGFloat = 48
        /// The Reader's thin scroll-progress bar.
        static let progressBar: CGFloat = 2
        /// One onboarding step-progress dot.
        static let progressDot: CGFloat = 6
    }

    // MARK: - Interaction

    /// Small numeric constants for press/disabled feedback and text
    /// shrink-to-fit. Not color, font, or spacing in the strict sense, but
    /// centralized here anyway so there is exactly one place any visual
    /// constant can come from.
    enum Interaction {
        static let pressedOpacity: Double = 0.75
        static let disabledOpacity: Double = 0.6
        /// Floor for `.minimumScaleFactor` on the Home circle labels, so the
        /// 3-minute circle's text never shrinks past legibility.
        static let circleLabelMinimumScale: Double = 0.7
        /// Floor for `.minimumScaleFactor` on onboarding interest chips. A
        /// fixed-height chip with a long single word ("Architecture") would
        /// otherwise wrap mid-word onto a second line and grow taller than
        /// its neighbors — confirmed visually via the CI screenshot artifact.
        static let chipLabelMinimumScale: Double = 0.7
    }

    // MARK: - Motion

    /// The only appear animation in the app: a short scale-in, skipped
    /// entirely under reduce-motion.
    static let appearAnimation: Animation = .easeOut(duration: 0.28)

    // MARK: - Share card

    /// Fixed 9:16 render size for the share card (a story/reel aspect
    /// ratio), independent of the device's own screen size — the card is
    /// rendered off-screen via `ImageRenderer`, not laid out to fill a
    /// visible frame.
    enum ShareCard {
        static let width: CGFloat = 405
        static let height: CGFloat = 720
        /// Height of the tallest domain bar in the fingerprint row; other
        /// bars scale relative to it.
        static let maxBarHeight: CGFloat = 64
        static let barWidth: CGFloat = 4
    }

    // MARK: - Home circle sizing

    /// Diameters for the four time windows, in ascending order. Size is the
    /// only thing that communicates duration on Home — nothing else may.
    enum CircleSize {
        static let three: CGFloat = 80
        static let ten: CGFloat = 110
        static let fifteen: CGFloat = 132
        static let fortyFive: CGFloat = 160

        /// Minimum interactive area regardless of visual diameter.
        static let minimumTapTarget: CGFloat = 44

        /// The visual diameter for a given window. The only place this
        /// mapping is allowed to exist.
        static func diameter(for window: TimeWindow) -> CGFloat {
            switch window {
            case .three: three
            case .ten: ten
            case .fifteen: fifteen
            case .fortyFive: fortyFive
            }
        }
    }
}

// MARK: - Color(hex:)

extension Color {
    /// Constructs a color from a packed `0xRRGGBB` literal. Kept private to
    /// the theme layer in intent — views should never call this directly with
    /// their own hex value.
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

// MARK: - Environment plumbing

/// Reads the app's chosen appearance mode from Settings and resolves it to a
/// concrete `Theme.Palette`, following the device setting when mode is
/// `.system`.
struct ThemedPalette: DynamicProperty {
    @Environment(\.colorScheme) private var colorScheme

    var palette: Theme.Palette {
        Theme.palette(for: colorScheme)
    }
}

/// Applies the user's chosen `Theme.AppearanceMode` as a `.preferredColorScheme`
/// at the root of the view hierarchy. `.system` passes `nil`, which defers to
/// the device.
struct AppearanceModifier: ViewModifier {
    var mode: Theme.AppearanceMode

    func body(content: Content) -> some View {
        content.preferredColorScheme(mode.colorScheme)
    }
}

extension View {
    func themedAppearance(_ mode: Theme.AppearanceMode) -> some View {
        modifier(AppearanceModifier(mode: mode))
    }

    /// The one appear animation in the app: a short scale-in, skipped
    /// entirely under reduce-motion. Reads reduce-motion itself — callers
    /// never need to check it.
    func themedAppear() -> some View {
        modifier(ThemedAppearModifier())
    }
}

private struct ThemedAppearModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.92)
            .opacity(hasAppeared || reduceMotion ? 1 : 0)
            .onAppear {
                if reduceMotion {
                    hasAppeared = true
                } else {
                    withAnimation(Theme.appearAnimation) { hasAppeared = true }
                }
            }
    }
}
