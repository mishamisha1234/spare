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
        /// Decorative separators only: hairlines between rows, the share
        /// card's rule. Below the 3:1 needed for a control edge.
        var border: Color
        /// The edge of anything tappable — circle strokes, option cards,
        /// outline buttons, chips, text fields. Clears 3:1 against the
        /// background, which `border` does not.
        var borderInteractive: Color
        var accent: Color
        var textOnAccent: Color
    }

    // The review proposed flipping `light.textOnAccent` to #1A1A1A, citing
    // 3.08:1 for near-white on the accent. That was measured against the
    // pre-Phase-6 accent (#C87F2E); the accent has since been darkened to
    // #A06525 and near-white on it is 4.52:1, which already passes.
    //
    // Applying the flip on top of the current accent would give 3.63:1 —
    // worse than what is there now. And the two requirements cannot both be
    // met by one accent: dark ink on accent needs luminance >= 0.223, accent
    // as text on the background needs <= 0.172. One colour cannot do both,
    // so the choice is which side to satisfy, and the current palette
    // satisfies both at 4.52 by keeping the ink light and the accent dark.
    //
    // Contrast, measured rather than eyeballed. Every pair below that carries
    // text at body size clears WCAG AA (4.5:1); see `ThemeContrastTests`,
    // which recomputes the ratios so a future palette tweak can't quietly
    // drop one below the line.
    //
    // The light accent was 0xC87F2E and the light secondary 0x8A837A. Both
    // measured ~3.0-3.5:1 against the background — fine for a large numeral,
    // not fine for the 13pt subtitle on the course circle or a 15pt "View the
    // lesson" link, which is exactly where they were being used. Darkened
    // along the same hue until they clear 4.5. Dark mode already passed
    // everywhere and is unchanged.
    private static let light = Palette(
        background: Color(hex: 0xFAF8F5),
        text: Color(hex: 0x1A1A1A),
        secondaryText: Color(hex: 0x767065),
        border: Color(hex: 0xD8D2C8),
        borderInteractive: Color(hex: 0x988F84),
        accent: Color(hex: 0xA06525),
        // Stays near-white, against the review's advice — see below.
        textOnAccent: Color(hex: 0xFAF8F5)
    )

    private static let dark = Palette(
        background: Color(hex: 0x111110),
        text: Color(hex: 0xE8E6E1),
        secondaryText: Color(hex: 0x8F8A80),
        border: Color(hex: 0x3A3833),
        borderInteractive: Color(hex: 0x656055),
        accent: Color(hex: 0xD9924A),
        textOnAccent: Color(hex: 0x17150F)
    )

    /// The raw palette values, for the contrast test. Exposed as plain
    /// integers because `Color` gives no portable way back to components.
    enum Hex {
        static let lightBackground: UInt32 = 0xFAF8F5
        static let lightText: UInt32 = 0x1A1A1A
        static let lightSecondaryText: UInt32 = 0x767065
        static let lightBorder: UInt32 = 0xD8D2C8
        static let lightBorderInteractive: UInt32 = 0x988F84
        static let lightAccent: UInt32 = 0xA06525
        static let lightTextOnAccent: UInt32 = 0xFAF8F5

        static let darkBackground: UInt32 = 0x111110
        static let darkText: UInt32 = 0xE8E6E1
        static let darkSecondaryText: UInt32 = 0x8F8A80
        static let darkBorder: UInt32 = 0x3A3833
        static let darkBorderInteractive: UInt32 = 0x656055
        static let darkAccent: UInt32 = 0xD9924A
        static let darkTextOnAccent: UInt32 = 0x17150F
    }

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
        /// Body copy: New York (serif), 19pt. Reader screen only — this is
        /// the one place prose is read at length. Leading is an additive
        /// point value; see `bodyLineSpacing`.
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
        /// A section heading inside the reading column. Serif, so it belongs
        /// to the prose rather than to the app chrome around it.
        case readerHeading
        /// A figure on the Stats screen: large enough to be the thing you
        /// read first, without a badge around it.
        case statValue

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
            case .readerHeading:
                return .system(size: 21, weight: .semibold, design: .serif)
            case .statValue:
                return .system(size: 28, weight: .regular, design: .default)
            }
        }

        /// Points added *between* lines, not a multiplier.
        ///
        /// SwiftUI's `.lineSpacing()` adds to the font's own line height
        /// rather than scaling it. Passing `19 * 0.55` (10.45pt) on top of
        /// New York 19pt's ~22.6pt default produced a ~33pt pitch — a 1.71x
        /// leading where 1.55x was intended. 5pt gives ~27.6pt, which is the
        /// 1.45x that actually reads as the intended density.
        var lineSpacing: CGFloat {
            switch self {
            case .body: Theme.bodyLineSpacing
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

        /// Scales with the reader's text size, but stays an additive point
        /// value — see `lineSpacing` for why this is not a multiple.
        static func scaledBodyLineSpacing(multiplier: Double) -> CGFloat {
            Theme.bodyLineSpacing * multiplier
        }

        /// One size for every circle label.
        ///
        /// It used to scale with diameter, which made the 3-minute label tiny
        /// and the course label large — a second, redundant encoding of the
        /// same information the diameter already carries, and the reason the
        /// two-line course label needed its own shrink factor.
        static let circleLabel: SwiftUI.Font = .system(size: 22, weight: .medium, design: .default)
    }

    // MARK: - Spacing

    /// The only spacing values allowed anywhere. Nothing in between.
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 16
        static let m: CGFloat = 24
        /// Added step. 24 was too tight and 40 too loose for the circle-grid
        /// row gutter, Settings group gaps, and the share-card stat block.
        static let ml: CGFloat = 32
        /// Vertical padding inside a list row.
        static let rowVertical: CGFloat = 20
        /// Between stacked answer cards.
        static let optionRowGap: CGFloat = 12
        static let l: CGFloat = 40
        static let xl: CGFloat = 64
    }

    // MARK: - Shape

    /// One radius, everywhere. No shadows, no gradients — separation comes
    /// from spacing and hairline borders only.
    static let cornerRadius: CGFloat = 14
    static let borderWidth: CGFloat = 1

    // Two shapes, and only two.
    //
    // Chips are `Capsule()`: the onboarding topic chips, the curiosity-gap
    // rows, and the Library filter chips. Everything else — buttons, cards,
    // text fields, option rows — uses `cornerRadius` above. There is no
    // third roundness, which is what the topic chips at ~22 against the
    // filter chips at full capsule used to be.
    //
    // No `pillRadius` constant: `Capsule()` already has no parameters to get
    // wrong, so a token would add indirection without preventing drift.

    /// How much more of Home's leftover vertical space goes below the
    /// circle grid than above it. Greater than 1 lifts the block; the
    /// review's fixed -24pt offset would have fought the ScrollView Home
    /// gained this stage.
    static let homeBottomSpacerPriority: Double = 1.4

    /// Horizontal margin for the reading column, narrowing as text grows so
    /// the measure stays readable rather than dropping to a few words a line.
    static func readingMargin(for step: TextSizeStep) -> CGFloat {
        switch step {
        case .small, .standard: Spacing.m
        case .large: 20
        case .extraLarge: Spacing.s
        }
    }

    /// Additive line spacing for body prose, in points.
    ///
    /// A point value, never a multiplier: `.lineSpacing()` adds to the font's
    /// line height instead of scaling it, so a "1.55" here silently rendered
    /// as 1.71x. `ThemeTypographyTests` asserts it stays in point range.
    static let bodyLineSpacing: CGFloat = 5

    /// Paragraph spacing for body prose. Previously indistinguishable from a
    /// loose line gap.
    static let bodyParagraphSpacing: CGFloat = 16

    /// The dash pattern that marks a locked control. The *only* way locking
    /// is shown on Home: no padlock glyph, no badge, no fill change, so the
    /// circles' size keeps carrying duration and nothing else competes.
    static let lockedDash: [CGFloat] = [5, 4]

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
        /// Opacity for the label of a control that is locked behind Premium.
        /// Recedes without becoming unreadable — a lock the reader can't read
        /// is not an argument for anything.
        static let lockedContentOpacity: Double = 0.45
        /// The same recession, against the accent fill. Near-white text on
        /// the accent loses legibility far faster than dark text on the page
        /// background does, so it needs a gentler reduction to read as
        /// equally recessive — confirmed against the CI screenshot, where
        /// the locked course circle was noticeably fainter than the locked
        /// 15-minute one beside it.
        static let lockedContentOpacityOnAccent: Double = 0.72
        // No `disabledOpacity`, deliberately. Dimming an accent fill to show
        // a disabled state turns muddy in dark mode, where the accent is
        // already close to the background in luminance. Disabled controls
        // use a border instead — see the Save key and Mark complete buttons.
        // The token is gone rather than merely unused so the pattern can't
        // quietly come back.
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


    // MARK: - Home circle sizing

    /// Diameters for the four time windows, in ascending order. Size is the
    /// only thing that communicates duration on Home — nothing else may.
    enum CircleSize {
        // 15 -> 30 was a 1.21x step for a 2x duration difference, so size
        // had stopped carrying the meaning at the top of the range and the
        // accent fill was doing it instead.
        //
        // `one` is not part of that progression. It sits above the grid as its
        // own element rather than as a fifth size, so it is sized to read as a
        // different kind of thing -- small enough that nobody mistakes it for
        // the bottom of a scale.
        static let one: CGFloat = 56
        static let three: CGFloat = 76
        static let seven: CGFloat = 104
        static let fifteen: CGFloat = 132
        static let thirty: CGFloat = 172

        /// Minimum interactive area regardless of visual diameter.
        ///
        /// The 1-minute circle is 56pt, comfortably over this. It is stated
        /// anyway because the gap between the two numbers is now small enough
        /// that shrinking the circle any further would quietly cross it.
        static let minimumTapTarget: CGFloat = 44

        /// The visual diameter for a given window. The only place this
        /// mapping is allowed to exist.
        static func diameter(for window: TimeWindow) -> CGFloat {
            switch window {
            case .one: one
            case .three: three
            case .seven: seven
            case .fifteen: fifteen
            case .thirty: thirty
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
