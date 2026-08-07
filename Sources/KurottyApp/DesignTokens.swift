import AppKit
import KurottyCore
import simd

enum DesignTokens {
    /// Chrome theme = one full instance of the semantic color ramp.
    ///
    /// Every role below is theme-owned. Status colors in particular must not be
    /// shared between themes: the dark `success` (`#5FD08A`) measures about
    /// 1.6:1 on a white light-theme surface, so light needs its own darker
    /// status hues. The legacy role names (`windowBackground`,
    /// `activeTabBackground`, `textMuted`, ...) are kept as computed aliases
    /// onto the ramp so existing chrome call sites read the same tokens.
    @MainActor
    struct ChromeTheme {
        // MARK: Surfaces, back to front
        let surfaceCanvas: NSColor
        let surfaceChrome: NSColor
        let surfaceSidebar: NSColor
        let surfaceRaised: NSColor

        // MARK: Separation
        let hairline: NSColor
        let borderStrong: NSColor

        // MARK: Text ranks
        let textPrimary: NSColor
        let textSecondary: NSColor
        let textTertiary: NSColor

        // MARK: Accent and status
        let accent: NSColor
        let success: NSColor
        let warning: NSColor
        let error: NSColor
        /// Low and high stops of the single-hue sequential ramp the daily usage
        /// strip interpolates between.
        let usageRampLow: NSColor
        let usageRampHigh: NSColor

        // MARK: Interaction fills
        /// Selected-row wash. Chromatic, derived from `accent`.
        let selectionFill: NSColor
        /// Hover wash. Deliberately achromatic so hover can never be confused
        /// with selection.
        let hoverFill: NSColor
        /// Mouse-down wash, achromatic and one step stronger than hover.
        let pressFill: NSColor
        /// Keyboard-focus ring stroke for the focused list.
        let focusRing: NSColor

        let windowAppearance: NSAppearance?

        /// Top-to-bottom stops for the ground the pane cards float on, or `nil`
        /// when the ground is a flat fill.
        ///
        /// A terminal background is one color — the grid is filled from
        /// `TerminalColorSettings.background` and Metal paints every cell with
        /// it — so a "gradient theme" cannot mean a graded grid without pane
        /// transparency, which Kurotty does not have. What it can mean is this:
        /// the ground *around* the cards is graded, the cards themselves are
        /// the user's flat theme background, and the two never mix.
        ///
        /// Only the window's ground host draws it. The split views and the pane
        /// cards go transparent instead of restating it, so the grade runs
        /// once across the whole content area rather than restarting inside
        /// every gutter — which is what a per-view gradient would do, and which
        /// reads as banding rather than as one surface.
        let groundGradient: (top: NSColor, bottom: NSColor)?

        // MARK: Scrollback indicator
        //
        // The indicator floats over the terminal canvas rather than over chrome,
        // so it has to be theme-owned like every status hue. The one fixed gray
        // it used to carry measured 1.37:1 on the light canvas — an indicator
        // nobody can see — so all three states are derived from the theme's own
        // primary ink and clear the WCAG non-text floor in both ramps.

        /// Thumb at rest.
        var scrollerThumb: NSColor {
            textPrimary.withAlphaComponent(Color.scrollerThumbRestAlphaRATIO)
        }

        /// Thumb under the pointer.
        var scrollerThumbHover: NSColor {
            textPrimary.withAlphaComponent(Color.scrollerThumbHoverAlphaRATIO)
        }

        /// Thumb while it is being dragged.
        var scrollerThumbActive: NSColor {
            textPrimary.withAlphaComponent(Color.scrollerThumbActiveAlphaRATIO)
        }

        // MARK: Legacy role aliases

        var windowBackground: NSColor { surfaceCanvas }
        var topChromeBackground: NSColor { surfaceChrome }
        var activeTabBackground: NSColor { surfaceRaised }
        var inactiveTabBackground: NSColor { surfaceChrome }
        var inactiveTabHoverBackground: NSColor { surfaceSidebar }
        /// The pane header is the top edge of a card that floats on
        /// `terminalPaneGround`, so it cannot be the ground's own surface: at
        /// `surfaceChrome` the card had no visible top and the rounded corners
        /// cut into a color identical to what was behind them. One step up is
        /// enough to give the card an edge without turning the header into a
        /// second piece of chrome.
        var paneHeaderBackground: NSColor { surfaceSidebar }
        var paneHeaderHoverBackground: NSColor { surfaceRaised }
        var borderHairline: NSColor { hairline }
        var divider: NSColor { hairline }
        var textMuted: NSColor { textTertiary }
        var activeIndicator: NSColor { accent }
        var activeStatusDot: NSColor { success }
        /// Purple has been purged from chrome; an idle dot is simply quiet text.
        var inactiveStatusDot: NSColor {
            textTertiary.withAlphaComponent(Color.inactiveStatusDotAlphaRATIO)
        }
        var activeBorder: NSColor {
            accent.withAlphaComponent(Color.activeBorderAlphaRATIO)
        }

        // MARK: Terminal pane ground
        //
        // The ground a terminal pane card floats on. It is the chrome surface,
        // not the canvas, and deliberately so: the tab bar above it is already
        // `surfaceChrome`, so the two fuse into one continuous plane and the
        // card is the only thing on it. That is what removed the hairline under
        // the tab bar — a rule between two identical colors is a stray line.
        //
        // The ground cannot be chosen to sit "under" the card, because the card
        // is filled with the user's terminal background and its luminance is
        // theirs. A light theme reads raised on this ground and a very dark one
        // reads recessed; both read as a distinct surface, which is the whole
        // job. This is also why no pane drop shadow exists: a shadow asserts an
        // elevation direction that is only right half the time.
        var terminalPaneGround: NSColor { surfaceChrome }

        /// Chrome follows the terminal theme by name first and by luminance
        /// second.
        ///
        /// Luminance alone cannot express Nacre: its background is light, so
        /// the fallback would hand it the neutral light ramp and the tint —
        /// the half of the theme that lives outside the grid — would never
        /// appear. A named preset owns its chrome; anything else, custom
        /// palettes included, still gets the light/dark decision it always got.
        static func theme(for settings: AppSettings) -> ChromeTheme {
            if TerminalThemePreset.canonicalName(settings.terminal.theme) == TerminalThemePreset.nacreName {
                return .nacre
            }
            return settings.terminal.colors.backgroundColor.isLightTerminalBackground ? .light : .dark
        }

        static let dark = ChromeTheme(
            surfaceCanvas: Color.Dark.surfaceCanvas,
            surfaceChrome: Color.Dark.surfaceChrome,
            surfaceSidebar: Color.Dark.surfaceSidebar,
            surfaceRaised: Color.Dark.surfaceRaised,
            hairline: Color.Dark.hairline,
            borderStrong: Color.Dark.borderStrong,
            textPrimary: Color.Dark.textPrimary,
            textSecondary: Color.Dark.textSecondary,
            textTertiary: Color.Dark.textTertiary,
            accent: Color.Dark.accent,
            success: Color.Dark.success,
            warning: Color.Dark.warning,
            error: Color.Dark.error,
            usageRampLow: Color.Dark.usageRampLow,
            usageRampHigh: Color.Dark.usageRampHigh,
            selectionFill: Color.Dark.selectionFill,
            hoverFill: Color.Dark.hoverFill,
            pressFill: Color.Dark.pressFill,
            focusRing: Color.Dark.focusRing,
            windowAppearance: NSAppearance(named: .darkAqua),
            groundGradient: nil
        )

        static let light = ChromeTheme(
            surfaceCanvas: Color.Light.surfaceCanvas,
            surfaceChrome: Color.Light.surfaceChrome,
            surfaceSidebar: Color.Light.surfaceSidebar,
            surfaceRaised: Color.Light.surfaceRaised,
            hairline: Color.Light.hairline,
            borderStrong: Color.Light.borderStrong,
            textPrimary: Color.Light.textPrimary,
            textSecondary: Color.Light.textSecondary,
            textTertiary: Color.Light.textTertiary,
            accent: Color.Light.accent,
            success: Color.Light.success,
            warning: Color.Light.warning,
            error: Color.Light.error,
            usageRampLow: Color.Light.usageRampLow,
            usageRampHigh: Color.Light.usageRampHigh,
            selectionFill: Color.Light.selectionFill,
            hoverFill: Color.Light.hoverFill,
            pressFill: Color.Light.pressFill,
            focusRing: Color.Light.focusRing,
            windowAppearance: NSAppearance(named: .aqua),
            groundGradient: nil
        )

        static let nacre = ChromeTheme(
            surfaceCanvas: Color.Nacre.surfaceCanvas,
            surfaceChrome: Color.Nacre.surfaceChrome,
            surfaceSidebar: Color.Nacre.surfaceSidebar,
            surfaceRaised: Color.Nacre.surfaceRaised,
            hairline: Color.Nacre.hairline,
            borderStrong: Color.Nacre.borderStrong,
            textPrimary: Color.Nacre.textPrimary,
            textSecondary: Color.Nacre.textSecondary,
            textTertiary: Color.Nacre.textTertiary,
            accent: Color.Nacre.accent,
            success: Color.Nacre.success,
            warning: Color.Nacre.warning,
            error: Color.Nacre.error,
            usageRampLow: Color.Nacre.usageRampLow,
            usageRampHigh: Color.Nacre.usageRampHigh,
            selectionFill: Color.Nacre.selectionFill,
            hoverFill: Color.Nacre.hoverFill,
            pressFill: Color.Nacre.pressFill,
            focusRing: Color.Nacre.focusRing,
            windowAppearance: NSAppearance(named: .aqua),
            groundGradient: (
                top: Color.Nacre.groundGradientTop,
                bottom: Color.Nacre.groundGradientBottom
            )
        )
    }

    enum Color {
        /// Alpha applied to `textTertiary` for an idle status dot.
        static let inactiveStatusDotAlphaRATIO: CGFloat = 0.55
        /// Alpha applied to `accent` for an active-surface border.
        static let activeBorderAlphaRATIO: CGFloat = 0.40
        /// Alpha applied to `accent` for the keyboard-focus ring.
        static let focusRingAlphaRATIO: CGFloat = 0.55
        /// Alphas applied to `textPrimary` for the three scrollback-indicator
        /// states. The resting value is the floor: below it the thumb stops
        /// clearing 3:1 against the canvas and the indicator reads as a smudge.
        static let scrollerThumbRestAlphaRATIO: CGFloat = 0.50
        static let scrollerThumbHoverAlphaRATIO: CGFloat = 0.65
        static let scrollerThumbActiveAlphaRATIO: CGFloat = 0.80
        /// Alpha for a prompt-rail mark that stands for successful commands.
        /// Below the failure alpha on purpose: the rail's job is to make a
        /// failure findable in a column of green, so the two must not weigh the
        /// same. A failed mark always draws opaque.
        static let promptRailSuccessAlphaRATIO: CGFloat = 0.70
        /// Alpha range a successful cluster interpolates across once the rail is
        /// in its heat regime. The floor is the point where a mark is still
        /// visible against the canvas; anything quieter is a rail with holes in
        /// it that are not real gaps.
        static let promptRailHeatMinAlphaRATIO: CGFloat = 0.25
        static let promptRailHeatMaxAlphaRATIO: CGFloat = 0.85

        /// Dark ramp. Hex values are sRGB and are built with
        /// `NSColor(srgbRed:…)`; a generic-RGB constructor does not reproduce
        /// the specified hex on screen.
        enum Dark {
            static let surfaceCanvas = NSColor.designTokenSRGB(0x16_16_18)
            static let surfaceChrome = NSColor.designTokenSRGB(0x1C_1C_1E)
            static let surfaceSidebar = NSColor.designTokenSRGB(0x20_20_22)
            static let surfaceRaised = NSColor.designTokenSRGB(0x26_26_2A)
            static let hairline = NSColor.designTokenSRGB(0x2E_2E_32)
            static let borderStrong = NSColor.designTokenSRGB(0x3C_3C_42)
            static let textPrimary = NSColor.designTokenSRGB(0xF2_F2_F4)
            static let textSecondary = NSColor.designTokenSRGB(0xA8_A8_AE)
            /// Near-neutral, a whisper cool. The ramp began blue (`#16181D`
            /// through `#262A31`), which read as a cold film; correcting it to a
            /// warm neutral overshot and read yellow, most visibly in the text
            /// ranks where the cast reached R-B +7. These sit where Apple's own
            /// greys sit -- `#1D1D1F`, `#F5F5F7` -- which is close enough to
            /// neutral that no hue reads at all. This rank has no headroom — it is
            /// the lightest value still clearing AA 4.5 on `surfaceRaised`, the
            /// selected tab, where a title has to be read.
            static let textTertiary = NSColor.designTokenSRGB(0x90_90_97)
            static let accent = NSColor.designTokenSRGB(0x0A_84_FF)
            static let success = NSColor.designTokenSRGB(0x5F_D0_8A)
            /// Sequential ramp for the daily usage strip, low -> high. One warm
            /// hue, rising in chroma, not the `error` step: a heavy day is a
            /// magnitude, not a fault, and reusing a status colour for it would
            /// make the two mean the same thing. Both stops clear 3:1 against
            /// `surfaceSidebar`, the ground the strip is drawn on.
            static let usageRampLow = NSColor.designTokenSRGB(0x85_85_8C)
            static let usageRampHigh = NSColor.designTokenSRGB(0xE0_65_5C)
            static let warning = NSColor.designTokenSRGB(0xE0_A9_4F)
            static let error = NSColor.designTokenSRGB(0xE8_75_6E)

            static let selectionFillAlphaRATIO: CGFloat = 0.24
            static let hoverFillAlphaRATIO: CGFloat = 0.06
            static let pressFillAlphaRATIO: CGFloat = 0.10

            static let selectionFill = accent.withAlphaComponent(selectionFillAlphaRATIO)
            static let hoverFill = NSColor.designTokenSRGB(0xFF_FF_FF, alpha: hoverFillAlphaRATIO)
            static let pressFill = NSColor.designTokenSRGB(0xFF_FF_FF, alpha: pressFillAlphaRATIO)
            static let focusRing = accent.withAlphaComponent(focusRingAlphaRATIO)
        }

        /// Light ramp. Status hues are darkened versions of the dark ramp so
        /// they stay legible on white; sharing the dark values would drop
        /// `success` to roughly 1.6:1 against `surfaceCanvas`.
        enum Light {
            static let surfaceCanvas = NSColor.designTokenSRGB(0xFF_FF_FF)
            static let surfaceChrome = NSColor.designTokenSRGB(0xF0_F0_F2)
            static let surfaceSidebar = NSColor.designTokenSRGB(0xF5_F5_F7)
            static let surfaceRaised = NSColor.designTokenSRGB(0xFF_FF_FF)
            static let hairline = NSColor.designTokenSRGB(0xE4_E4_E7)
            static let borderStrong = NSColor.designTokenSRGB(0xD0_D0_D5)
            static let textPrimary = NSColor.designTokenSRGB(0x1D_1D_1F)
            static let textSecondary = NSColor.designTokenSRGB(0x4E_4E_52)
            /// Warm-neutral, matching the dark ramp. Light chrome has no room
            /// to spend on a quiet rank: this is the lightest value that still
            /// clears AA 4.5 on every light surface, and it sits far enough
            /// below `textSecondary` that the two read as different ranks —
            /// they were 1.2:1 apart before, which looked like one rank twice.
            static let textTertiary = NSColor.designTokenSRGB(0x6A_6A_70)
            static let accent = NSColor.designTokenSRGB(0x00_71_E3)
            static let success = NSColor.designTokenSRGB(0x17_72_45)
            /// Light counterpart of the usage ramp. On a light ground a
            /// sequential scale runs light -> dark, so the stops darken as the
            /// day gets heavier rather than brightening.
            static let usageRampLow = NSColor.designTokenSRGB(0x86_86_8B)
            static let usageRampHigh = NSColor.designTokenSRGB(0xA0_2D_22)
            static let warning = NSColor.designTokenSRGB(0x8A_53_00)
            static let error = NSColor.designTokenSRGB(0xC0_27_1F)

            static let selectionFillAlphaRATIO: CGFloat = 0.14
            static let hoverFillAlphaRATIO: CGFloat = 0.05
            static let pressFillAlphaRATIO: CGFloat = 0.09

            static let selectionFill = accent.withAlphaComponent(selectionFillAlphaRATIO)
            static let hoverFill = NSColor.designTokenSRGB(0x00_00_00, alpha: hoverFillAlphaRATIO)
            static let pressFill = NSColor.designTokenSRGB(0x00_00_00, alpha: pressFillAlphaRATIO)
            static let focusRing = accent.withAlphaComponent(focusRingAlphaRATIO)
        }

        /// Nacre ramp. The one chrome ramp that is *tinted* rather than
        /// near-neutral.
        ///
        /// The dark and light ramps separate their surfaces by lightness alone,
        /// which is why every boundary in them is grey on grey and each step
        /// has to be paid for out of a contrast budget. This ramp separates by
        /// hue instead: a blue-lavender ground with neutral-to-white surfaces
        /// on it. `surfaceRaised` is pure white and the ground is two steps
        /// down *and* visibly blue, so a selected tab or a selected row reads as
        /// a white card on colored ground with no hairline doing the work.
        ///
        /// The tint stops at the chrome. It never reaches the cell grid — that
        /// belongs entirely to `TerminalColorSettings.nacre`, unmodified — for
        /// the same reason the pane ground is not allowed to bleed into the
        /// pane: a wash under text is a wash the user did not choose for their
        /// text.
        enum Nacre {
            static let surfaceCanvas = NSColor.designTokenSRGB(0xEF_F2_FC)
            static let surfaceChrome = NSColor.designTokenSRGB(0xE4_E9_F7)
            static let surfaceSidebar = NSColor.designTokenSRGB(0xF4_F5_FC)
            static let surfaceRaised = NSColor.designTokenSRGB(0xFF_FF_FF)
            static let hairline = NSColor.designTokenSRGB(0xD3_D9_EE)
            static let borderStrong = NSColor.designTokenSRGB(0xB6_BE_DB)
            /// Deeper than the terminal's own ink. Chrome text has to clear
            /// 11.7:1 on `surfaceChrome`, which is a full two steps darker than
            /// the light ramp's chrome surface, so this rank cannot simply
            /// mirror `TerminalColorSettings.nacre.foreground`.
            static let textPrimary = NSColor.designTokenSRGB(0x21_1F_31)
            static let textSecondary = NSColor.designTokenSRGB(0x4C_4B_63)
            /// The rank with no headroom, as in every ramp — but here the floor
            /// is set by the *bottom* of the ground gradient rather than by a
            /// flat surface, which is a darker ground than any token names.
            static let textTertiary = NSColor.designTokenSRGB(0x5B_5A_73)
            static let accent = NSColor.designTokenSRGB(0x2F_55_C8)
            static let success = NSColor.designTokenSRGB(0x1E_6B_3D)
            /// Light-style sequential ramp: a heavier day darkens rather than
            /// brightens, because the ground it is drawn on is light.
            static let usageRampLow = NSColor.designTokenSRGB(0x6C_6A_80)
            static let usageRampHigh = NSColor.designTokenSRGB(0xA0_30_1F)
            static let warning = NSColor.designTokenSRGB(0x87_54_0A)
            static let error = NSColor.designTokenSRGB(0xB3_2B_22)

            static let selectionFillAlphaRATIO: CGFloat = 0.14
            static let hoverFillAlphaRATIO: CGFloat = 0.05
            static let pressFillAlphaRATIO: CGFloat = 0.09

            static let selectionFill = accent.withAlphaComponent(selectionFillAlphaRATIO)
            static let hoverFill = NSColor.designTokenSRGB(0x00_00_00, alpha: hoverFillAlphaRATIO)
            static let pressFill = NSColor.designTokenSRGB(0x00_00_00, alpha: pressFillAlphaRATIO)
            static let focusRing = accent.withAlphaComponent(focusRingAlphaRATIO)

            /// Top and bottom stops of the ground gradient.
            ///
            /// The top stop *is* `surfaceChrome`, and that is the whole reason
            /// the gradient can exist without breaking the plane. The tab bar
            /// is flat `surfaceChrome` and the pane ground starts at the same
            /// value directly beneath it, so the two still read as one
            /// continuous surface — the property the pane-card work was built
            /// on — and the grade only becomes visible further down, away from
            /// the seam.
            /// The depth of the grade is set by how far the bottom stop can go
            /// before `textTertiary` stops clearing AA on it — 4.60:1 here,
            /// which is the binding constraint and the reason the ramp's
            /// quietest rank is darker than the light ramp's.
            static let groundGradientTop = surfaceChrome
            static let groundGradientBottom = NSColor.designTokenSRGB(0xCB_D7_F0)
        }

        // MARK: Theme-neutral chrome

        static let paneDropTargetBorder = NSColor(srgbRed: 53.0 / 255.0, green: 201.0 / 255.0, blue: 201.0 / 255.0, alpha: 0.72)
        static let paneDropTargetBackground = NSColor(srgbRed: 53.0 / 255.0, green: 201.0 / 255.0, blue: 201.0 / 255.0, alpha: 0.08)
        static let inputStatusBackground = Dark.surfaceRaised
        static let cyanTerminalAccent = NSColor(srgbRed: 53.0 / 255.0, green: 201.0 / 255.0, blue: 201.0 / 255.0, alpha: 1)

        // MARK: Dark-ramp aliases for chrome that has no theme at the call site

        static let windowBackground = Dark.surfaceCanvas
        static let topChromeBackground = Dark.surfaceChrome
        static let activeTabBackground = Dark.surfaceRaised
        static let inactiveTabBackground = Dark.surfaceChrome
        static let inactiveTabHoverBackground = Dark.surfaceSidebar
        static let paneHeaderBackground = Dark.surfaceChrome
        static let paneHeaderHoverBackground = Dark.surfaceSidebar
        static let borderHairline = Dark.hairline
        static let divider = Dark.hairline
        static let textPrimary = Dark.textPrimary
        static let textSecondary = Dark.textSecondary
        static let textMuted = Dark.textTertiary
        static let accentBlue = Dark.accent
        static let successGreen = Dark.success
        static let warningOrange = Dark.warning
        static let errorRed = Dark.error

        static let terminalBackground = NSColor(
            srgbRed: 34.0 / 255.0,
            green: 37.0 / 255.0,
            blue: 43.0 / 255.0,
            alpha: 1
        )
        static let terminalForeground = TerminalColorDefaults.foreground
        static let terminalCursor = TerminalColorDefaults.cursor
        static let terminalDefaultBackground = TerminalColorDefaults.background

        static let ansiNormal = TerminalPalette.ansiNormal
        static let ansiBright = TerminalPalette.ansiBright
    }

    /// Whole-chrome text scale, as a percentage.
    ///
    /// Kurotty could already resize terminal *content* two ways — the terminal
    /// font-size setting and per-window zoom — and neither touches the app's own
    /// chrome, so the sidebar, tabs, status bar, pane headers, palette, and
    /// settings surface were stuck at one size for every user and every display.
    /// This is the one number that moves them, and only them: terminal and
    /// editor content keep their own sizes.
    ///
    /// The scale is applied when a font or a metric is *built*, not when the
    /// ramp is declared, which is why every scaled token in this file is a
    /// computed `var`. A `static let` would freeze whatever the scale happened
    /// to be the first time it was touched, and the setting would appear to
    /// work until the first relaunch-free change.
    ///
    /// Ownership: `AppSettingsStore` is the only writer. It installs the value
    /// on load and again on save, before the change notification fans out, so
    /// every surface that re-lays itself out in response is already reading the
    /// new scale. Nothing else may call `setPercent`, and there is nothing to
    /// tear down: the state is one clamped `Double`.
    enum UIScale {
        /// The bounds live in `SettingsDefaults` beside every other clamp the
        /// normalizer applies, so the settings file and the tokens can never
        /// disagree about what a legal scale is. The reasoning for the range is
        /// there too.
        static let defaultPercent = SettingsDefaults.uiTextScalePercent
        static let minimumPercent = SettingsDefaults.minimumUITextScalePercent
        static let maximumPercent = SettingsDefaults.maximumUITextScalePercent
        /// One notch of the Settings slider. Five points moves the 13pt row rung
        /// by about two thirds of a point, which is the smallest step that reads
        /// as a change rather than as noise.
        static let stepPercent: Double = 5

        /// Live value behind a lock rather than on the main actor.
        /// `Typography.Role.font` and every `Component` metric are nonisolated
        /// and have to stay that way — pinning them to `@MainActor` would force
        /// an isolation change on call sites that are correct today, which is
        /// exactly what this seam exists to avoid.
        private final class Storage: @unchecked Sendable {
            private let lock = NSLock()
            private var stored = UIScale.defaultPercent

            var percent: Double {
                get {
                    lock.lock()
                    defer { lock.unlock() }
                    return stored
                }
                set {
                    lock.lock()
                    stored = newValue
                    lock.unlock()
                }
            }
        }

        private static let storage = Storage()

        static var percent: Double { storage.percent }

        /// Installs the value carried by the settings file. Clamps rather than
        /// rejects: a hand-edited file must not be able to put the chrome at 5%,
        /// and the settings normalizer has already clamped anything that came
        /// through it.
        static func setPercent(_ value: Double) {
            storage.percent = clamped(value)
        }

        /// Forwards to the settings layer so the tokens and the file on disk
        /// can never disagree about what a legal scale is.
        static func clamped(_ value: Double) -> Double {
            SettingsDefaults.clampedUITextScalePercent(value)
        }

        private static var factor: CGFloat { CGFloat(percent / defaultPercent) }

        /// Scales a type or glyph point size. Deliberately unrounded: snapped to
        /// whole points, an 11pt rung would sit still for three notches of the
        /// slider and then jump.
        static func scaledPointSize(_ sizePT: CGFloat) -> CGFloat {
            sizePT * factor
        }

        /// Scales a box metric that has to hold scaled type — a row height, a
        /// header, a badge, a column reserved for a label. Rounded to a whole
        /// point, because a row that lands on a half pixel blurs the hairline
        /// under it.
        static func scaledMetric(_ valuePX: CGFloat) -> CGFloat {
            (valuePX * factor).rounded()
        }
    }

    /// The chrome type ramp.
    ///
    /// Naming note: the spec calls this scale `DesignTokens.Type`. `Type` is not
    /// usable as a nested type name in Swift — `DesignTokens.Type` always parses
    /// as the metatype of `DesignTokens`, so member lookup fails. The ramp
    /// therefore lives in the existing `Typography` namespace, which is where
    /// the retired `*FontSizePT` constants used to sit.
    ///
    /// Every chrome label takes a `Role`. Call sites must not pass a weight of
    /// their own: a role is the single place where size, weight, line height,
    /// tracking, and font design are decided together.
    enum Typography {
        /// One rung of the ramp.
        struct Role: Equatable, Sendable {
            /// Which system font family the role renders in. Monospaced digits
            /// are their own case because a changing number must not reflow the
            /// label that holds it.
            enum FontDesign: Sendable {
                case system
                case monospaced
                case monospacedDigit
            }

            /// The ramp as specified, before the user's UI text scale. The
            /// spec values are what the ramp *is*; `sizePT` is what anything
            /// drawing with it should read.
            let baseSizePT: CGFloat
            let weight: NSFont.Weight
            let baseLineHeightPX: CGFloat
            let baseTracking: CGFloat
            let design: FontDesign

            init(
                sizePT: CGFloat,
                weight: NSFont.Weight,
                lineHeightPX: CGFloat,
                tracking: CGFloat = 0,
                design: FontDesign = .system
            ) {
                baseSizePT = sizePT
                self.weight = weight
                baseLineHeightPX = lineHeightPX
                baseTracking = tracking
                self.design = design
            }

            /// Point size after the UI text scale. Computed rather than stored
            /// so the scale reaches every consumer of a role — `font`,
            /// `symbolConfiguration`, and the handful of surfaces that read
            /// `sizePT` to build a font of their own — without any of them
            /// having to learn that a scale exists.
            var sizePT: CGFloat { UIScale.scaledPointSize(baseSizePT) }

            var lineHeightPX: CGFloat { UIScale.scaledMetric(baseLineHeightPX) }

            /// Letter spacing is a point value like the size, so it moves with
            /// it: fixed tracking under scaled caps reads as too tight.
            var tracking: CGFloat { UIScale.scaledPointSize(baseTracking) }

            var font: NSFont {
                switch design {
                case .system:
                    return NSFont.systemFont(ofSize: sizePT, weight: weight)
                case .monospaced:
                    return NSFont.monospacedSystemFont(ofSize: sizePT, weight: weight)
                case .monospacedDigit:
                    return NSFont.monospacedDigitSystemFont(ofSize: sizePT, weight: weight)
                }
            }

            /// The same role expressed as an SF Symbol configuration, so a glyph
            /// beside a label inherits the label's size and weight.
            var symbolConfiguration: NSImage.SymbolConfiguration {
                NSImage.SymbolConfiguration(pointSize: sizePT, weight: symbolWeight)
            }

            /// Applies font, color, and tracking to a label. Roles with tracking
            /// must go through an attributed string: `NSTextField` has no kerning
            /// property of its own.
            @MainActor
            func apply(to field: NSTextField, color: NSColor) {
                field.font = font
                field.textColor = color
                guard tracking != 0 else {
                    return
                }
                field.attributedStringValue = attributedString(field.stringValue, color: color)
            }

            @MainActor
            func attributedString(_ text: String, color: NSColor) -> NSAttributedString {
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: font,
                        .foregroundColor: color,
                        .kern: tracking,
                    ]
                )
            }

            private var symbolWeight: NSFont.Weight { weight }
        }

        static let windowTitle = Role(sizePT: 13, weight: .semibold, lineHeightPX: 18)
        static let tabLabel = Role(sizePT: 13, weight: .medium, lineHeightPX: 18)
        static let tabLabelSel = Role(sizePT: 13, weight: .semibold, lineHeightPX: 18)
        /// Uppercased at the call site; tracking opens the caps back up.
        static let sectionHeader = Role(sizePT: 12, weight: .semibold, lineHeightPX: 16, tracking: 0.55)
        static let rowTitle = Role(sizePT: 13, weight: .regular, lineHeightPX: 18)
        static let rowTitleSel = Role(sizePT: 13, weight: .medium, lineHeightPX: 18)
        static let rowSecondary = Role(sizePT: 12, weight: .regular, lineHeightPX: 16)
        static let badge = Role(sizePT: 11, weight: .medium, lineHeightPX: 15)
        static let statusBar = Role(sizePT: 12, weight: .regular, lineHeightPX: 16)
        static let statusBarNum = Role(
            sizePT: 12,
            weight: .medium,
            lineHeightPX: 16,
            design: .monospacedDigit
        )
        static let monoBody = Role(sizePT: 13, weight: .regular, lineHeightPX: 18, design: .monospaced)
        /// Editor line-number gutter. Monospaced digits so a jump from line 9 to
        /// line 10 cannot shift the column.
        static let monoGutter = Role(
            sizePT: 11,
            weight: .regular,
            lineHeightPX: 15,
            design: .monospacedDigit
        )
        static let paneHeader = Role(sizePT: 12, weight: .medium, lineHeightPX: 16)
        /// Text inside a chrome control that is not a list row: the search
        /// query field and the editor's empty-state placeholder. One rung above
        /// `rowTitle` because an input surface is not dense data.
        static let controlLabel = Role(sizePT: 13, weight: .regular, lineHeightPX: 18)

        // MARK: Preferences rungs
        //
        // The chrome ramp stops at `windowTitle` (13pt) because chrome is
        // dense. A settings window is a document surface and needs a larger
        // title and body rung, so those four rungs live here rather than being
        // borrowed from the dense end of the scale.
        static let prefsTitle = Role(sizePT: 20, weight: .semibold, lineHeightPX: 26)
        static let prefsSection = Role(sizePT: 13, weight: .semibold, lineHeightPX: 18)
        static let prefsBody = Role(sizePT: 12, weight: .regular, lineHeightPX: 16)
        static let prefsCaption = Role(sizePT: 11, weight: .regular, lineHeightPX: 15)

        static let terminalFontSizePT: CGFloat = 15
        /// One ⌘+ / ⌘- press. Against the 8...48 bounds this gives 40 steps,
        /// fine enough that a single press reads as an adjustment rather than
        /// a jump.
        static let terminalFontZoomStepPT: Double = 1
        static let codeEditorFontSizePT: CGFloat = 13
        static let codeEditorGutterFontSizePT: CGFloat = 11
    }

    /// Shadow ramp for chrome that floats above another surface.
    ///
    /// Every floating surface used to hand-roll its own shadow (the terminal
    /// search bar carried `black @ 0.22 / r10 / y-2`), so two overlays at the
    /// same conceptual height rendered at different heights. There are two
    /// heights: a surface floating over the terminal, and a selected sidebar row
    /// lifted a hair off the panel it sits in.
    enum Elevation {
        /// A surface that floats over the terminal: the search bar today, and
        /// any future popover/HUD that is not a real `NSPanel`.
        ///
        /// Dark chrome needs a deeper, softer shadow than light chrome: on a
        /// dark canvas a shallow shadow is invisible, while on a light canvas
        /// the same shadow reads as smudge.
        struct Shadow: Equatable {
            let color: NSColor
            let opacity: Float
            let radiusPX: CGFloat
            /// Downward distance in design terms. AppKit's unflipped layer
            /// geometry wants a negative `shadowOffset.height` to push a shadow
            /// *down*, so `apply(to:)` negates this; the token stays positive so
            /// the value matches the spec as written.
            let downwardOffsetPX: CGFloat

            func apply(to layer: CALayer) {
                layer.shadowColor = color.cgColor
                layer.shadowOpacity = opacity
                layer.shadowRadius = radiusPX
                layer.shadowOffset = NSSize(width: 0, height: -downwardOffsetPX)
            }
        }

        static let floatingDark = Shadow(
            color: .black,
            opacity: 0.28,
            radiusPX: 16,
            downwardOffsetPX: 4
        )

        static let floatingLight = Shadow(
            color: .black,
            opacity: 0.14,
            radiusPX: 12,
            downwardOffsetPX: 3
        )

        /// The pill under a selected sidebar row.
        ///
        /// Deliberately a fraction of `floating`. The reference this came from
        /// puts a wide, soft shadow under a 40pt row in a list of twenty; the
        /// same blur under a 26pt pill in a list of four hundred reads as a
        /// smudge, and the smudge is repeated every time the selection moves.
        /// The radius is small enough that the shadow stays inside the row's
        /// own gutter rather than washing the rows above and below it.
        ///
        /// Light chrome leans on this hardest: its raised surface is white on
        /// near-white — about 1.08:1 — so without a shadow the pill is not an
        /// object at all. Dark chrome gets its lift from the surface step and
        /// only needs the shadow to seat the pill.
        static let sidebarSelectedRowDark = Shadow(
            color: .black,
            opacity: 0.42,
            radiusPX: 3,
            downwardOffsetPX: 1
        )

        static let sidebarSelectedRowLight = Shadow(
            color: .black,
            opacity: 0.16,
            radiusPX: 3,
            downwardOffsetPX: 1
        )

        /// Picks the floating shadow that matches the active chrome ramp.
        @MainActor
        static func floating(for theme: DesignTokens.ChromeTheme) -> Shadow {
            isLight(theme) ? floatingLight : floatingDark
        }

        @MainActor
        static func sidebarSelectedRow(for theme: DesignTokens.ChromeTheme) -> Shadow {
            isLight(theme) ? sidebarSelectedRowLight : sidebarSelectedRowDark
        }

        @MainActor
        private static func isLight(_ theme: DesignTokens.ChromeTheme) -> Bool {
            theme.windowAppearance?.name == .aqua
        }
    }

    /// Durations for the only chrome state changes that are allowed to move.
    ///
    /// Motion here is deliberately scarce. Row hover, press, and selection
    /// fills, tab add/remove/reorder, text content updates, terminal rendering,
    /// search bar appearance, focus rings, theme switches, badge counts, and
    /// preferences pane switching must all be instant. `ChromeMotion` and
    /// `SidebarMotion` are the behaviour helpers that read these tokens.
    enum Motion {
        /// Sidebar section switch. Long enough to read the selection pill
        /// travelling, short enough that a fast click never queues.
        static let sectionSwitchDurationMS = 160
        /// Each half of the sidebar list crossfade.
        static let sectionListFadeDurationMS = 80
        /// Disclosure chevron rotation.
        static let disclosureRotationDurationMS = 150
        /// Full status-bar value crossfade (out + in).
        static let statusValueCrossfadeDurationMS = 120
        /// Scrollback indicator idle fade. The one chrome fade that is not
        /// optional: the indicator is an overlay on top of terminal output, so
        /// an indicator that never leaves is a permanent stripe over the last
        /// column of every line. Long enough that a paused reader still sees
        /// where they are, short enough that it is gone before they read on.
        static let scrollIndicatorIdleDelayMS = 900
        static let scrollIndicatorFadeDurationMS = 220
        /// How long a command has to run before its pane shows a progress bar.
        /// 500ms sits between the two numbers that matter: below ~100ms a
        /// response reads as instant, and at ~1s the user starts to notice the
        /// wait. The bar has to already be on screen when that attention
        /// arrives, and every command that finishes before a human could
        /// perceive a delay — `ls`, `cd`, a small `git status` — stays silent.
        static let commandProgressAppearanceDelayMS = 500
        /// One pass of the indeterminate sweep. Matched to the agent activity
        /// spinner so two ambient "still working" cues in the same pane do not
        /// beat against each other.
        static let commandProgressSweepDurationMS = 1_100
        /// How long a failed command's bar stays up after the prompt returns.
        /// Only ever applies to a bar the user could already see, so it reports
        /// an outcome rather than announcing one.
        static let commandProgressFailureLingerMS = 1_600
        /// How long an indeterminate bar may sweep before it holds still.
        ///
        /// One minute is where a wait stops being one. Below it the user is
        /// sitting through the command and the motion is doing its job; past
        /// it they have gone to read the output, or to another window, and a
        /// sweep that has repeated itself fifty times has said everything it
        /// can. The bar stays — Kurotty has had no OSC 133 `D` and must not
        /// imply one — but it stops claiming that progress is happening right
        /// now, which is the part nothing backs up.
        static let commandProgressSweepCeilingMS = 60_000

        static let disclosureCollapsedRotationDegrees: CGFloat = 0
        static let disclosureExpandedRotationDegrees: CGFloat = 90

        static func seconds(fromMS milliseconds: Int) -> TimeInterval {
            TimeInterval(milliseconds) / 1000
        }
    }

    /// Layout rhythm. Every chrome gap, inset, and pad in the window shell picks
    /// one of these six steps; ad-hoc point values are the thing this scale
    /// exists to prevent.
    enum Space {
        static let x1PX: CGFloat = 4
        static let x2PX: CGFloat = 6
        static let x3PX: CGFloat = 8
        static let x4PX: CGFloat = 12
        static let x5PX: CGFloat = 16
        static let x6PX: CGFloat = 24

        /// Exempt from the scale: these are cell-grid alignment for the terminal
        /// surface, not layout rhythm, so they must not be rounded onto a step.
        ///
        /// They are also the terminal's corner clearance. The pane is a rounded
        /// card now, so the grid has to stop short of the arc or the corner
        /// cells get shaved; these four numbers are the only thing standing
        /// between a glyph and the mask. Every one of them must stay at or above
        /// `TerminalPaneCard.minimumGridInsetPX` — `TerminalPaneCardGeometryTests`
        /// measures that against the real cell rects rather than trusting it.
        /// The horizontal pair went 6 -> 8 for exactly that reason, which also
        /// made the terminal's own margin square.
        static let terminalTopPX: CGFloat = 8
        static let terminalLeftPX: CGFloat = 8
        static let terminalBottomPX: CGFloat = 8
        static let terminalRightPX: CGFloat = 8
        static let preferencesInsetPX: CGFloat = 24
        static let preferencesGapPX: CGFloat = 14
    }

    /// Corner-radius scale. `fullPX` is the pill radius; a control only earns it
    /// when its shape is the meaning (a status pill), never for data.
    enum Radius {
        static let xsPX: CGFloat = 4
        static let smPX: CGFloat = 6
        static let mdPX: CGFloat = 8
        static let lgPX: CGFloat = 12
        static let fullPX: CGFloat = 999
    }

    // MARK: - Terminal pane card
    //
    // The terminal pane is a rounded card inset from the window edge, sitting
    // on `ChromeTheme.terminalPaneGround`. One shape, one gutter, one ground —
    // the panes read as separate surfaces, so the hairlines that used to do
    // that job are gone.
    //
    // What was deliberately left out: a drop shadow (see `terminalPaneGround`
    // for why the elevation direction is not knowable), a border on the card
    // (it would put back the hairline the rounding just removed), and a radius
    // above `Radius.lgPX` (a terminal is dense; a bigger arc starts eating the
    // first and last cell of the top and bottom rows instead of empty margin).
    //
    // This is also the decision that settles the tab grammar. A Safari-style
    // tab is merged: it shares an edge with the content, which is how it says
    // "this tab is that document". A tab in Kurotty does not contain a
    // document, it contains a split tree — a merged tab in a four-way split
    // would share its edge with a gutter, and with a sidebar open it would have
    // to merge past a column that is not the content. So the tab stays a pill
    // on the chrome plane (`TerminalTabItemView`, radius on all four corners,
    // inset inside the bar), associated with the card by sitting on the same
    // ground rather than by touching it. Merged tabs and inset cards are
    // mutually exclusive and the cards win; a tab that almost touches the card
    // would only read as a misalignment.

    /// Geometry of the terminal pane card and the ground around it.
    ///
    /// Nothing here scales with `UIScale`: a corner radius and a gutter are
    /// shapes in the window, not containers for type.
    enum TerminalPaneCard {
        /// Corner radius of the pane card. The largest step on the scale and
        /// the ceiling for this surface — see `minimumGridInsetPX` for what
        /// raising it would cost.
        static let cornerRadiusPX = Radius.lgPX

        /// Gap between the window's chrome edges and the outermost card. The
        /// ground shows through here, which is the whole effect.
        static let groundInsetPX = Space.x3PX

        /// Gap between two adjacent cards in a split. This is the split
        /// divider's full thickness — the divider no longer draws a line, so
        /// the band it reserves *is* the gutter, and it stays wide enough to
        /// grab for a resize drag.
        static let gutterPX = Component.terminalSplitDividerHitAreaPX

        /// How far a rounded corner of radius 1 cuts into the content rect,
        /// measured along one axis.
        ///
        /// The corner arc is centred at `(r, r)`. A point `(p, p)` inset from
        /// the card's corner is inside the arc when `sqrt(2) * (r - p) <= r`,
        /// which solves to `p >= r * (1 - 1/sqrt(2))`. That is this ratio.
        static let cornerContentInsetRATIO: CGFloat = 1 - 1 / 2.squareRoot()

        /// Smallest terminal grid inset that keeps the corner cells whole.
        ///
        /// This is the number that makes the rounding safe. Masking the layer
        /// would shave the corner glyphs; instead the grid stops short, so the
        /// arc only ever cuts through padding. `Space.terminal*PX` are all at or
        /// above this, and because those insets are subtracted *before* the
        /// columns/rows division in `TerminalSurfaceView.terminalMetrics()`, the
        /// size reported to the PTY already accounts for the corners.
        static var minimumGridInsetPX: CGFloat {
            cornerRadiusPX * cornerContentInsetRATIO
        }
    }

    /// Component metrics.
    ///
    /// Every metric here is one of two kinds, and which kind it is decides
    /// whether `UIScale` touches it:
    ///
    /// - **Type-coupled**: the value exists because a piece of type or a glyph
    ///   has to fit inside it — row and header heights, badge boxes, columns
    ///   reserved for a label, glyph point sizes, panel padding around scaled
    ///   rows. These are computed `var`s built through `UIScale.scaledMetric`
    ///   (or `scaledPointSize` for a glyph), because a 13pt row that grows to
    ///   20pt inside a fixed 30px box clips, which makes the type scale useless.
    /// - **Fixed**: the value is not a container for type — strokes and
    ///   hairlines, status dots, meters, corner radii, the `Space` rhythm steps,
    ///   traffic-light clearance the system owns, and the geometry of
    ///   system-drawn controls whose title font AppKit picks rather than the
    ///   ramp. Scaling a 1px hairline or a 6px status dot makes chrome look
    ///   broken, not larger.
    enum Component {
        /// The side of the square the menu-bar extra's mark is drawn in.
        /// Outside `Icon.SizeClass` and outside the UI text scale on purpose:
        /// the ramp exists so chrome glyphs track the chrome type beside them,
        /// and there is no Kurotty type beside this one. It sits in a bar whose
        /// height macOS fixes, so a mark that grew with Kurotty's own scale
        /// would be clipped by a bar Kurotty does not control. 18pt is the box
        /// macOS gives a menu-bar image, and the mark fills it edge to edge
        /// because it is a solid head rather than a stroked glyph — a stroked
        /// SF Symbol at the same 18 would read heavier.
        static let menuBarExtraMarkSizePT: CGFloat = 18

        /// Quick Commands editor window layout.
        static let quickCommandEditorWidthPX: CGFloat = 620
        static let quickCommandEditorHeightPX: CGFloat = 460
        static let quickCommandEditorPaddingPX: CGFloat = 16
        static let quickCommandEditorRowSpacingPX: CGFloat = 8
        static let quickCommandEditorSectionSpacingPX: CGFloat = 12
        static let quickCommandTableHeightPX: CGFloat = 170
        static let quickCommandTableRowHeightPX: CGFloat = 22
        static let quickCommandCommandTextHeightPX: CGFloat = 74
        static let quickCommandFieldLabelWidthPX: CGFloat = 120
        static let quickCommandNameColumnWidthPX: CGFloat = 200
        static let quickCommandScopeColumnWidthPX: CGFloat = 190
        static let quickCommandActionColumnWidthPX: CGFloat = 160
        static let quickCommandToolbarButtonWidthPX: CGFloat = 32

        static let commandPaletteWidthPX: CGFloat = 680
        static let commandPaletteHeightPX: CGFloat = 500
        /// A palette row is one command name over its shortcut, so it grows with
        /// the ramp; the window around it does not, which is the same trade the
        /// user already accepts when they zoom any list.
        static var commandPaletteRowHeightPX: CGFloat { UIScale.scaledMetric(34) }

        /// Project file palette. The window borrows the command palette's frame
        /// so the two read as one surface invoked two ways, but the row is
        /// taller: a file row is a name over its directory, which is two lines
        /// where a command row is one.
        static let projectFilePaletteWidthPX = commandPaletteWidthPX
        static let projectFilePaletteHeightPX = commandPaletteHeightPX
        static var projectFilePaletteRowHeightPX: CGFloat { UIScale.scaledMetric(44) }
        /// Height of the footer strip that names the scan source and the result
        /// count. Fixed so the list does not resize when the text under it goes
        /// from one count to another.
        static var projectFilePaletteFooterHeightPX: CGFloat { UIScale.scaledMetric(18) }
        static let projectFilePaletteInsetPX = Space.x5PX
        static let projectFilePaletteGapPX = Space.x4PX
        static let projectFilePaletteRowInsetXPX = Space.x3PX
        static let projectFilePaletteRowLineGapPX: CGFloat = 1

        /// Getting Started tab. Sized against the settings surface rather than
        /// the window: it is the same kind of read-once page, and a full-bleed
        /// column of prose at terminal width is unreadable.
        static let gettingStartedContentMaxWidthPX = preferencesContentMaxWidthPX
        static let gettingStartedInsetPX = Space.x6PX
        static let gettingStartedRowGapPX = Space.x5PX
        static let gettingStartedRowInsetPX = Space.x4PX
        static let gettingStartedRowGutterPX = Space.x4PX
        static let gettingStartedTextGapPX = Space.x1PX
        static let gettingStartedHeaderGapPX = Space.x6PX
        static let gettingStartedRowCornerRadiusPX = Radius.mdPX
        /// Fixed width for the state glyph column so every row's title starts on
        /// the same x, whichever of the three marks it carries.
        static var gettingStartedGutterWidthPX: CGFloat { UIScale.scaledMetric(20) }

        /// Settings surface geometry. Settings is a center tab, not a window, so
        /// these are the size the surface is designed against and the frame the
        /// hosted view starts at before the tab stretches it — not a window
        /// size. Every button is the macOS regular control height of 28.
        static let preferencesWidthPX: CGFloat = 720
        static let preferencesHeightPX: CGFloat = 852
        /// The content column is elastic: it takes whatever width the tab gives
        /// it and stops here. Past this width the right-aligned label column and
        /// its control drift so far apart that the pair stops reading as one
        /// row, which is the failure mode of a full-bleed settings page.
        static let preferencesContentMaxWidthPX: CGFloat = 720
        static var preferencesSidebarWidthPX: CGFloat { UIScale.scaledMetric(184) }
        static var preferencesControlWidthPX: CGFloat { UIScale.scaledMetric(220) }
        static var preferencesStatusHeightPX: CGFloat { UIScale.scaledMetric(16) }
        /// Buttons, steppers, and color wells stay fixed. AppKit draws these
        /// with the system control font, which the ramp does not own, so a
        /// scaled box around an unscaled title is a fat bezel rather than a
        /// larger control.
        static let preferencesButtonWidthPX: CGFloat = 84
        static let preferencesButtonHeightPX: CGFloat = 28
        static var preferencesTextFieldWidthPX: CGFloat { UIScale.scaledMetric(160) }
        static var preferencesNumericFieldWidthPX: CGFloat { UIScale.scaledMetric(96) }
        /// Reserved slot for a value a slider writes rather than a field the
        /// user types into, so the row cannot shuffle as the readout goes from
        /// two digits to three.
        static var preferencesValueReadoutWidthPX: CGFloat { UIScale.scaledMetric(48) }
        /// Top bar of the settings tab: the page title over the nav column and
        /// the query field over the content column, on one line, above a
        /// hairline. Sized like a toolbar rather than a card header because it
        /// is chrome for the whole surface.
        static var preferencesHeaderHeightPX: CGFloat { UIScale.scaledMetric(52) }
        static var preferencesHeaderSearchWidthPX: CGFloat { UIScale.scaledMetric(320) }
        static var preferencesNavRowHeightPX: CGFloat { UIScale.scaledMetric(32) }
        static let preferencesNavInsetXPX = Space.x4PX
        static let preferencesNavTopInsetPX = Space.x5PX
        /// Trailing air inside the nav column, so a nav row never touches the
        /// divider that separates it from the content.
        static let preferencesNavTrailingInsetPX: CGFloat = 28
        static var preferencesLabelColumnWidthPX: CGFloat { UIScale.scaledMetric(150) }
        static let preferencesColorWellSizePX: CGFloat = 34
        static let preferencesAnsiColumnCount = 4
        /// Title-to-subtitle gap inside one settings heading. Below `Space.x1PX`
        /// on purpose: these two lines are one label pair, not two rows, and a
        /// full step would break them apart.
        static let preferencesHeadingLineGapPX: CGFloat = 2
        /// Settings search. The query field sits in the sidebar between the
        /// window heading and the category list, so its bottom gap is a control
        /// gap rather than the section gap that separates it from the heading.
        static let preferencesSearchFieldBottomGapPX = Space.x3PX
        static let preferencesSearchEmptyStateTopGapPX = Space.x6PX
        static let preferencesSearchEmptyStateGapPX = Space.x3PX
        static var preferencesSearchEmptyStateIconPointSizePT: CGFloat { UIScale.scaledPointSize(18) }
        /// Theme preview card. The sample draws in the terminal's own font at
        /// the terminal's own size, so everything below is expressed relative to
        /// that font rather than as fixed offsets: a preview with baked-in 13pt
        /// metrics shows nothing when the font size changes.
        static let preferencesThemePreviewHeightPX: CGFloat = 176
        static let preferencesThemePreviewCornerRadiusPX = Radius.mdPX
        static let preferencesThemePreviewInsetPX = Space.x5PX
        /// Row pitch as a multiple of the point size, matching the loose
        /// leading a terminal grid uses.
        static let preferencesThemePreviewLineHeightRATIO: CGFloat = 1.6
        /// Gap between the sample prompt's two segments, in advance widths, so
        /// it scales with the font instead of stranding the path at a fixed
        /// offset.
        static let preferencesThemePreviewPromptGapCELLS: CGFloat = 2
        static let preferencesThemePreviewSwatchHeightPX = Space.x1PX
        static let preferencesThemePreviewSwatchBottomInsetPX = Space.x4PX
        static let preferencesThemePreviewSwatchMinWidthPX = Space.x3PX
        static let settingsEditorFontSizePT: CGFloat = 12
        static let glyphAtlasSizePX = 4096
        static let glyphSlotWidthPX = 128
        static let glyphSlotHeightPX = 128
        static let glyphAtlasOversampleScale: CGFloat = 1
        static let glyphSlotPaddingPX: CGFloat = 6
        static let partialRedrawPendingScissorRectBudgetCount = 64
        static let terminalScrollerWidthPX: CGFloat = 12
        static let terminalScrollerThumbWidthPX: CGFloat = 9
        static let terminalScrollerMinThumbHeightPX: CGFloat = 32
        static let terminalScrollerMinKnobProportion: CGFloat = 0.05
        /// Prompt navigator rail. Half the scroll indicator's width and flush to
        /// the trailing edge, with the indicator track pushed inboard by exactly
        /// this much: the two never share a pixel, which is the whole reason
        /// this is a second strip rather than a second thing drawn in the first.
        static let terminalPromptRailWidthPX: CGFloat = 6
        /// Minimum pitch between two marks. The rail can never draw more than
        /// `trackHeight / this` marks, so the count of marks is bounded by the
        /// track and not by the session, and the 2pt of clear track between
        /// neighbours is what keeps a busy rail from fusing into a stripe.
        static let terminalPromptRailSlotHeightPX: CGFloat = 5
        static let terminalPromptRailMarkerHeightPX: CGFloat = 3
        /// Inset applied to a mark that stands for exactly one command, so a
        /// lone command reads narrower than a stack of them at a glance.
        static let terminalPromptRailSingletonInsetPX: CGFloat = 1.5
        /// Commands per mark above which counting them by eye is hopeless and
        /// the rail switches to a density wash. Eight is where a cluster stops
        /// being a short list the popover can show in full.
        static let terminalPromptRailClusterFanoutLIMIT = 8
        /// How far off a mark a click may land and still count, in slots. The
        /// mark is 3pt tall in a 6pt strip; requiring a hit on the mark itself
        /// would make the rail feel broken.
        static let terminalPromptRailHitToleranceSLOTS: CGFloat = 1.5
        /// Commands the hover popover lists before it stops and reports a
        /// remainder. Past this the popover is taller than the thing it
        /// describes.
        static let terminalPromptRailPopoverEntryLIMIT = 6
        /// Marks the popover gathers around the pointer before trimming to the
        /// entry limit. More than one so a hover between two marks describes
        /// both.
        static let terminalPromptRailPopoverClusterLIMIT = 4
        static var terminalPromptRailPopoverWidthPX: CGFloat { UIScale.scaledMetric(300) }
        static var terminalPromptRailPopoverRowHeightPX: CGFloat { UIScale.scaledMetric(20) }
        static let terminalPromptRailPopoverInsetPX = Space.x3PX
        static let terminalPromptRailPopoverGapPX = Space.x2PX
        static let terminalPreciseScrollMultiplierRATIO: CGFloat = 1.5
        static let terminalDiscreteScrollRowsPerTick = 2
        static var terminalSearchWidthPX: CGFloat { UIScale.scaledMetric(340) }
        /// 40, down from 44: a 28pt query field with `x2` of vertical air is a
        /// floating bar, not a toolbar. The corner radius is `Radius.lgPX`
        /// rather than a one-off 10.
        static var terminalSearchHeightPX: CGFloat { UIScale.scaledMetric(40) }
        static let terminalSearchInsetPX: CGFloat = 12
        static let terminalSearchStackLeadingInsetPX = Space.x3PX
        static let terminalSearchStackTrailingInsetPX = Space.x2PX
        static let terminalSearchStackSpacingPX = Space.x1PX
        static let terminalSearchStackVerticalInsetPX = Space.x2PX
        static var terminalSearchQueryHeightPX: CGFloat { UIScale.scaledMetric(28) }
        static var terminalSearchMinimumQueryWidthPX: CGFloat { UIScale.scaledMetric(120) }
        static var terminalSearchMinimumResultCountWidthPX: CGFloat { UIScale.scaledMetric(44) }
        static var terminalSearchButtonSidePX: CGFloat { UIScale.scaledMetric(24) }
        /// The query field is slightly translucent so the bar reads as one
        /// floating surface rather than a field pasted onto a card.
        static let terminalSearchFieldFillAlphaRATIO: CGFloat = 0.9
        static var terminalTabBarHeightPX: CGFloat { UIScale.scaledMetric(38) }
        static let terminalTopBarCornerRadiusPX: CGFloat = 0
        static let terminalTabBarHorizontalInsetPX: CGFloat = 0
        /// Fixed: this is where macOS puts the traffic lights, not where our
        /// type ends. Scaling it would slide the first tab away from a window
        /// button that has not moved.
        static let terminalTrafficLightClearancePX: CGFloat = 78
        static let terminalTabBarSideButtonInsetPX = Space.x3PX
        static var terminalTabHeightPX: CGFloat { UIScale.scaledMetric(28) }
        static var sidebarToggleSizePX: CGFloat { UIScale.scaledMetric(26) }
        static let sidebarDividerGrabPaddingPX = Space.x1PX
        static let sidebarToggleEdgeInsetPX = Space.x3PX
        /// An open panel keeps its toggle tinted like a selected control, so
        /// the bar reads as on/off state rather than as two plain buttons.
        static let sidebarToggleActiveTintAlphaRATIO: CGFloat = 0.82
        static let sidebarToggleActiveFillAlphaRATIO: CGFloat = 0.10
        /// Hover on an already-open toggle: the same accent wash, one step
        /// deeper. Deliberately not `terminalTabButtonHoverAlphaRATIO`, which
        /// is a tab's chromatic hover and is stronger than this control's own
        /// selected fill -- pointing at a toggle should not look louder than
        /// selecting it.
        static let sidebarToggleActiveHoverFillAlphaRATIO: CGFloat = 0.16
        /// Both bounds hold a tab title, so both move with it: a tab pinned to
        /// 120 at 175% truncates every title to two words.
        static var terminalTabMinWidthPX: CGFloat { UIScale.scaledMetric(120) }
        static var terminalTabMaxWidthPX: CGFloat { UIScale.scaledMetric(240) }
        static var terminalTabPlusWidthPX: CGFloat { UIScale.scaledMetric(26) }
        /// Close affordance: a 20x20 hit target carrying a 10pt glyph. 18x18 was
        /// below the comfortable pointer target for a control this small.
        static var terminalTabCloseWidthPX: CGFloat { UIScale.scaledMetric(20) }
        /// Tab add/close hover is the one chrome hover allowed to be chromatic:
        /// it marks a tab action rather than a row.
        static let terminalTabButtonHoverAlphaRATIO: CGFloat = 0.18
        static let terminalTabStackGapPX = Space.x1PX
        static let terminalTabStackInsetTopPX = Space.x1PX
        static let terminalTabStackInsetLeftPX = Space.x3PX
        static let terminalTabStackInsetBottomPX = Space.x1PX
        static let terminalTabStackInsetRightPX = Space.x3PX
        /// Selected tabs are marked by an accent rail across the tab's top edge,
        /// not by an outline: a border reads as a box, a rail reads as "current".
        static let terminalTabTopRailHeightPX: CGFloat = 2
        static let terminalTabTitleLeadingPX = Space.x4PX
        static let terminalTabTitleCloseGapPX = Space.x2PX
        static let terminalTabCloseTrailingPX = Space.x3PX
        static let commandHistoryPanelDefaultWidthPX: CGFloat = 350
        static let commandHistoryPanelMinWidthPX: CGFloat = 200
        static let commandHistoryPanelMaxWidthPX: CGFloat = 460
        static let commandHistoryPanelCornerRadiusPX: CGFloat = 0
        /// Panel padding is the air between a scaled row and the panel edge, so
        /// it grows with the rows. The intra-row gaps below stay on the `Space`
        /// rhythm: those are the grid the chrome is drawn on, not boxes holding
        /// type.
        static var commandHistoryPanelInsetXPX: CGFloat { UIScale.scaledMetric(Space.x4PX) }
        static var commandHistoryPanelInsetYPX: CGFloat { UIScale.scaledMetric(Space.x4PX) }
        /// Gap between two stacked bands of a sidebar panel: the search field,
        /// the agent-session summary strips, and the list. Named for what it
        /// separates rather than for the section header it used to sit under —
        /// these panels no longer draw one.
        static let sidebarPanelBandGapPX = Space.x5PX
        /// Air above the search pill in a left-sidebar section.
        ///
        /// Smaller than the panel's own inset because the section strip above
        /// already contributes `leftSidebarSectionStripBottomGapPX`; the two
        /// together are the gap the user sees. These panels no longer draw a
        /// title of their own — the strip is the title — so this is the whole
        /// distance from the strip to the field.
        static let sidebarPanelTopGapPX = Space.x3PX
        /// The directory node is this list's section header, so it takes the
        /// vertical rhythm the reference sidebars spend on every row — and only
        /// it does. A history panel holds ten or so directories and hundreds of
        /// commands: air above the ten costs a fraction of a row, while the same
        /// air on the hundreds would push a third of the list off screen.
        ///
        /// The air is dead space above the header's content, not padding around
        /// it: the row's highlight is inset past it (`highlightTopInsetPX`), so
        /// what the user sees is a gap between groups rather than a tall row.
        static let commandHistoryGroupRowTopAirPX = Space.x4PX
        static var commandHistoryGroupContentHeightPX: CGFloat { UIScale.scaledMetric(32) }
        static var commandHistoryGroupRowHeightPX: CGFloat {
            commandHistoryGroupContentHeightPX + commandHistoryGroupRowTopAirPX
        }
        static var commandHistoryCommandRowHeightPX: CGFloat { UIScale.scaledMetric(30) }
        /// Fixed: a status dot is a mark, not a container. It reads as a dot at
        /// 6px and as a blob at 11.
        static let commandHistoryStatusDotSizePX: CGFloat = 6
        static let commandHistoryRowInsetXPX = Space.x3PX
        /// Status dot to command text, and folder icon to group name.
        static let commandHistoryRowGapPX = Space.x3PX
        static var commandHistoryTimeLabelMinWidthPX: CGFloat { UIScale.scaledMetric(32) }
        static var commandHistoryBadgeHeightPX: CGFloat { UIScale.scaledMetric(16) }
        static let commandHistoryBadgeTextInsetXPX = Space.x2PX
        static var commandHistoryBadgeMinWidthPX: CGFloat { UIScale.scaledMetric(18) }
        static var commandHistoryGroupIconPointSizePT: CGFloat { UIScale.scaledPointSize(12) }
        static var commandHistoryDisclosurePointSizePT: CGFloat { UIScale.scaledPointSize(9) }
        static var commandHistoryDisclosureBoxSizePX: CGFloat { UIScale.scaledMetric(16) }
        static var commandHistoryEmptyStateIconPointSizePT: CGFloat { UIScale.scaledPointSize(18) }
        static let commandHistoryEmptyStateGapPX = Space.x3PX
        /// Empty-state art sits one step quieter than the text ramp alone would
        /// make it, so an empty list never competes with a full one. Shared by
        /// all three sidebar sections. The icon may take an alpha because it is
        /// decorative: the label beside it carries the whole message, so the
        /// glyph is exempt from the non-text contrast floor.
        static let sidebarEmptyStateIconAlphaRATIO: CGFloat = 0.66
        /// The label may not. Opacity multiplies straight through the contrast
        /// ratio, so the old 0.72 turned `textTertiary` — a rank that clears AA
        /// by design — into 2.8:1 copy that is the only text on the screen when
        /// it appears. Quieting an empty state is now the type ramp's job
        /// (`rowTitle` in the quietest text rank), not the compositor's.
        static let sidebarEmptyStateLabelAlphaRATIO: CGFloat = 1
        /// One outline level has to read as one level; 6pt did not.
        static let commandHistoryOutlineIndentationPX = Space.x4PX
        static let commandHistoryDefaultExpandedGroupCount = 3
        static let commandHistoryBadgeBackgroundAlphaRATIO: CGFloat = 0.10
        static let fileExplorerPanelDefaultWidthPX: CGFloat = 350
        /// The terminal column never shrinks past this. Sidebars are allowed to
        /// take space from it, but not to erase it: a zero-width terminal is a
        /// broken window, not a narrow one.
        static let terminalColumnMinWidthPX: CGFloat = 240
        static let fileExplorerPanelMinWidthPX: CGFloat = 210
        static let fileExplorerPanelMaxWidthPX: CGFloat = 460
        static let fileExplorerPanelCornerRadiusPX: CGFloat = 0
        static var fileExplorerPanelInsetXPX: CGFloat { UIScale.scaledMetric(Space.x4PX) }
        static var fileExplorerPanelInsetYPX: CGFloat { UIScale.scaledMetric(Space.x4PX) }
        static let fileExplorerHeaderGapPX = Space.x1PX
        static let fileExplorerControlGapPX = Space.x3PX
        static var fileExplorerRefreshButtonSizePX: CGFloat { UIScale.scaledMetric(24) }
        static var fileExplorerRowHeightPX: CGFloat { UIScale.scaledMetric(26) }
        static let fileExplorerRowInsetXPX = Space.x3PX
        static let fileExplorerRowGapPX = Space.x2PX
        static let fileExplorerOutlineIndentationPX = Space.x4PX
        static var fileExplorerRowIconPointSizePT: CGFloat { UIScale.scaledPointSize(13) }
        /// Fixed-width git column: a dot in a reserved slot cannot shift the row
        /// beside it, which the old `M`/`U`/`⊘` letters did every repaint. The
        /// slot and its dot are both fixed — the column carries a mark, not
        /// type, and a scaled column would only push the filename left.
        static let fileExplorerGitSlotSizePX: CGFloat = 14
        static let fileExplorerGitDotSizePX: CGFloat = 5
        static var fileExplorerGitConflictPointSizePT: CGFloat { UIScale.scaledPointSize(10) }
        static let fileExplorerFolderIconAlphaRATIO: CGFloat = 0.85
        static let fileExplorerDimmedTextAlphaRATIO: CGFloat = 0.50
        /// Agent-provenance column, sitting immediately before the git column.
        /// A hollow ring rather than a second filled dot: git already owns the
        /// filled-dot vocabulary, and shape separates the two states faster
        /// than a fourth dot color would.
        static let fileExplorerAgentSlotSizePX: CGFloat = 12
        static let fileExplorerAgentRingDiameterPX: CGFloat = 6
        static let fileExplorerAgentRingLineWidthPX: CGFloat = 1.5
        static let fileExplorerAgentRingAlphaRATIO: CGFloat = 0.90
        /// Inline notice for a create, rename, or trash that did not happen.
        /// It sits between the search pill and the tree and collapses to
        /// nothing when there is no message, so a panel with no failure keeps
        /// exactly the layout it had before this feature existed. The row is a
        /// sentence, so its padding scales with the type ramp around it.
        static var fileExplorerActionErrorPaddingYPX: CGFloat { UIScale.scaledMetric(Space.x2PX) }
        /// The name field in the create/rename prompt. Both dimensions hold
        /// type, so both scale: a 24px field with a 20pt ramp clips its own
        /// text, and a fixed 240px field truncates a filename the user can
        /// still read at a larger size.
        static var fileExplorerNamePromptFieldWidthPX: CGFloat { UIScale.scaledMetric(260) }
        static var fileExplorerNamePromptFieldHeightPX: CGFloat { UIScale.scaledMetric(24) }

        // MARK: Shared sidebar search pill

        /// One pill shape for all three sidebar sections. A solid raised fill
        /// (not a translucent wash) is what makes it read as a control instead
        /// of a smudge over whatever happens to be behind it.
        static var sidebarSearchPillHeightPX: CGFloat { UIScale.scaledMetric(28) }
        static let sidebarSearchPillTextInsetXPX = Space.x3PX
        static let sidebarSearchPillEdgeInsetXPX = Space.x2PX
        static let sidebarSearchIconGapPX = Space.x2PX
        static var sidebarSearchIconPointSizePT: CGFloat { UIScale.scaledPointSize(11) }
        static var sidebarSearchClearGlyphPointSizePT: CGFloat { UIScale.scaledPointSize(11) }
        static var sidebarSearchClearHitSizePX: CGFloat { UIScale.scaledMetric(20) }
        static let sidebarSearchPillBorderWidthPX: CGFloat = 1
        static let sidebarSearchPillFocusRingWidthPX: CGFloat = 2
        static let sidebarSearchPillFocusRingOutsetPX: CGFloat = 1
        // Agent-session sidebar. Shared metrics (search pill, badges, row
        // highlight, indentation) intentionally reuse the commandHistory*
        // tokens so both left-panel sections stay pixel-identical.
        /// Two stacked lines of type, so it moves with both of them.
        static var agentSessionRowHeightPX: CGFloat { UIScale.scaledMetric(42) }
        static var agentSessionRowTextGapPY: CGFloat { UIScale.scaledMetric(2) }
        static var agentSessionAgentIconPointSizePT: CGFloat { UIScale.scaledPointSize(12) }
        static var agentSessionEmptyStateIconPointSizePT: CGFloat { UIScale.scaledPointSize(18) }
        static let agentSessionDefaultExpandedGroupCount = 3
        // Context-window meter on a session row. One bar, no ticks, no label:
        // the exact numbers live in the row tooltip, so the bar only has to
        // carry "roughly how full" at a glance without competing with the
        // title beside it. Fixed for the same reason a status dot is: the bar is
        // a mark, and it carries the same "roughly how full" at any type size.
        static let agentContextMeterWidthPX: CGFloat = 26
        static let agentContextMeterHeightPX: CGFloat = 3
        /// Unfilled remainder. Low enough to read as a groove rather than a
        /// second value.
        static let agentContextMeterTrackAlphaRATIO: CGFloat = 0.16
        /// Filled portion at rest. Recessive ink, not the accent: the accent is
        /// reserved for focus and selection.
        static let agentContextMeterFillAlphaRATIO: CGFloat = 0.50
        /// Filled portion once the window is under pressure, and while the row
        /// is selected. The only state that earns extra contrast.
        static let agentContextMeterEmphasisAlphaRATIO: CGFloat = 0.90
        // Read-only agent transcript viewer. Flat inline rows: a tool run is one
        // line that expands in place, so detail rows are indented rather than
        // boxed.
        static var agentTranscriptRowInsetXPX: CGFloat { UIScale.scaledMetric(14) }
        static var agentTranscriptRowInsetYPX: CGFloat { UIScale.scaledMetric(4) }
        static var agentTranscriptDetailInsetXPX: CGFloat { UIScale.scaledMetric(30) }
        static var agentTranscriptHeaderTopPaddingPX: CGFloat { UIScale.scaledMetric(10) }
        /// The transcript is a read-only chrome panel, not an editable document,
        /// so its three rungs follow the chrome scale rather than the editor's
        /// own font-size setting.
        static var agentTranscriptBodyFontSizePT: CGFloat { UIScale.scaledPointSize(12) }
        static var agentTranscriptHeaderFontSizePT: CGFloat { UIScale.scaledPointSize(10) }
        static var agentTranscriptMonospacedFontSizePT: CGFloat { UIScale.scaledPointSize(11) }
        static let agentTranscriptDetailBackgroundAlphaRATIO: CGFloat = 0.06
        static let agentTranscriptDiffBackgroundAlphaRATIO: CGFloat = 0.10

        // MARK: Rendered Markdown inside a transcript text row
        //
        // A message an agent wrote is a document, not a list row, so these are
        // document metrics: a heading ramp, paragraph leading, list indents.
        // They still sit on the chrome scale rather than the editor's font-size
        // setting, for the same reason the three rungs above do — the
        // transcript is a read-only panel the user is not editing.

        /// Heading ramp indexed by level 1...6. Levels 4 and up share the body
        /// size and are separated by weight alone: an agent that reaches `####`
        /// is nesting, not shouting, and six visibly different sizes inside a
        /// chat row reads as noise.
        static var agentTranscriptHeadingFontSizesPT: [CGFloat] {
            [17, 15, 13, 12, 12, 12].map(UIScale.scaledPointSize)
        }
        /// Air above a heading that follows other prose. There is deliberately
        /// no matching value below it: a heading belongs to the block under it.
        static var agentTranscriptHeadingSpacingBeforePX: CGFloat { UIScale.scaledMetric(10) }
        static var agentTranscriptParagraphSpacingPX: CGFloat { UIScale.scaledMetric(7) }
        /// Indent added per list nesting level.
        static var agentTranscriptListIndentPX: CGFloat { UIScale.scaledMetric(14) }
        /// Column reserved for `•` or `12.`, wide enough that a two-digit
        /// ordinal does not push its text out of alignment with its neighbours.
        static var agentTranscriptListMarkerColumnPX: CGFloat { UIScale.scaledMetric(20) }
        /// Gap between two segments of one rendered message — prose, then a
        /// code block, then more prose.
        static var agentTranscriptBlockSpacingPX: CGFloat { UIScale.scaledMetric(8) }
        /// Block-quote rule. Fixed, like every other stroke.
        static let agentTranscriptQuoteBarWidthPX: CGFloat = 2
        static var agentTranscriptQuoteIndentPX: CGFloat { UIScale.scaledMetric(12) }
        static var agentTranscriptCodeBlockPaddingXPX: CGFloat { UIScale.scaledMetric(10) }
        static var agentTranscriptCodeBlockPaddingYPX: CGFloat { UIScale.scaledMetric(7) }
        static let agentTranscriptCodeBlockCornerRadiusPX = Radius.smPX
        /// Fixed leading inside a code block. Code is set as lines, so its
        /// height must be an exact multiple of this: the block sizes itself
        /// arithmetically from its line count instead of asking the text system,
        /// which is what lets a non-wrapping block have a knowable height.
        static var agentTranscriptCodeLineHeightPX: CGFloat { UIScale.scaledMetric(15) }
        static var agentTranscriptCodeLanguageFontSizePT: CGFloat { UIScale.scaledPointSize(9) }
        static let agentTranscriptCodeBackgroundAlphaRATIO: CGFloat = 0.06
        static let agentTranscriptInlineCodeBackgroundAlphaRATIO: CGFloat = 0.09
        static var agentTranscriptTableCellPaddingXPX: CGFloat { UIScale.scaledMetric(8) }
        static var agentTranscriptTableCellPaddingYPX: CGFloat { UIScale.scaledMetric(4) }
        /// Floor a column is shrunk to before the table gives up on natural
        /// widths and splits the row evenly. Below this a column holds about
        /// four characters and reads as a stripe rather than data.
        static var agentTranscriptTableMinimumColumnWidthPX: CGFloat { UIScale.scaledMetric(44) }
        static let agentTranscriptTableHeaderBackgroundAlphaRATIO: CGFloat = 0.07
        /// Vertical air around a `---` rule.
        static var agentTranscriptRuleSpacingPX: CGFloat { UIScale.scaledMetric(6) }
        // Shared three-state row highlight. Command history, agent sessions,
        // and the file explorer all paint through
        // `TerminalSidebarRowHighlight`, so the geometry lives once here.
        static let sidebarRowHighlightInsetXPX = Space.x1PX
        static let sidebarRowHighlightInsetYPX: CGFloat = 2
        static let sidebarRowHighlightCornerRadiusPX = Radius.smPX
        static let sidebarRowSelectionRailWidthPX: CGFloat = 2
        /// Hairline around a selected row's pill. Fixed: a stroke is not a
        /// container for type.
        static let sidebarRowSelectionBorderWidthPX: CGFloat = 1
        static let sidebarRowSelectionRailCornerRadiusPX: CGFloat = 1
        static let sidebarRowFocusRingWidthPX: CGFloat = 2
        static let sidebarRowFocusRingOutsetPX: CGFloat = 1
        /// Reserved column for a row's leading glyph, in every sidebar list.
        ///
        /// The glyphs are not the same width: at 13pt `folder` measures 19pt and
        /// `doc` 15pt, so an explorer tree drawn to each icon's intrinsic width
        /// shifts its filename column by up to 4pt depending on what kind of
        /// thing the row is. This is the same defect the git column already
        /// fixed with a fixed slot; the leading column simply never got one.
        static var sidebarRowIconSlotWidthPX: CGFloat { UIScale.scaledMetric(20) }
        /// Reserved column for a command row's status dot.
        ///
        /// Narrower than the icon slot by exactly one outline level, because a
        /// command row is one level below the directory row that owns it: the
        /// two columns then land on the same x, and the panel reads as one text
        /// column with a mark in front of it rather than two ragged ones. The
        /// alignment used to hold by accident — a 6pt dot and a 12pt folder icon
        /// happened to differ by about the indentation — and any change to
        /// either glyph broke it silently.
        static var sidebarRowStatusSlotWidthPX: CGFloat {
            max(
                commandHistoryStatusDotSizePX,
                sidebarRowIconSlotWidthPX - commandHistoryOutlineIndentationPX
            )
        }

        // MARK: Shared sidebar keyboard hint
        //
        // The badge that tells the user which key jumps to the filter field.
        // A hint, so it is the quietest thing in the pill and leaves as soon as
        // the field is doing anything: focused or holding a query.
        static var sidebarSearchHintBadgeHeightPX: CGFloat { UIScale.scaledMetric(16) }
        static var sidebarSearchHintBadgeMinWidthPX: CGFloat { UIScale.scaledMetric(16) }
        static let sidebarSearchHintBadgeTextInsetXPX = Space.x2PX
        static let sidebarSearchHintBadgeGapPX = Space.x2PX
        static let sidebarSearchHintBadgeBorderWidthPX: CGFloat = 1
        /// The key the badge advertises, and the key the lists route. One
        /// constant so the label and the binding cannot disagree.
        static let sidebarSearchHintKeyCharacter: Character = "/"

        // MARK: Left-sidebar section strip
        //
        // A custom two-item strip, not `NSSegmentedControl`. AppKit has no legal
        // 22pt segmented-control height, so the old control rendered squashed
        // and needed `setWidth(0…)` plus compression-resistance workarounds to
        // stay inside the panel at all.
        static var leftSidebarSectionStripHeightPX: CGFloat { UIScale.scaledMetric(30) }
        static let leftSidebarSectionStripTopInsetPX = Space.x3PX
        static let leftSidebarSectionStripInsetXPX = Space.x4PX
        static let leftSidebarSectionStripBottomGapPX = Space.x3PX
        // The strip's selection geometry — pill inset, radius, rail thickness,
        // focus ring — is deliberately not tokenised here. It is the sidebar
        // row's geometry (`sidebarRowHighlight*`, `sidebarRowSelection*`),
        // because the strip now uses the row's selection device rather than an
        // underline of its own. A second set of numbers for the same object is
        // how the two drifted apart in the first place.
        static let imagePreviewInsetPX = Space.x6PX
        /// 40, down from 44: four digits fit at 11pt with `x3` of trailing air.
        /// The gutter draws in `Typography.monoGutter`, which is a chrome rung,
        /// so the column that holds it has to move with it even though the
        /// editor body beside it keeps its own font-size setting.
        static var codeEditorGutterWidthPX: CGFloat { UIScale.scaledMetric(40) }
        static let codeEditorGutterLabelTrailingPX = Space.x3PX
        static let codeEditorTextInsetXPX: CGFloat = 6
        static let codeEditorTextInsetYPX: CGFloat = 8
        /// The path bar is a real 28pt bar with a hairline bottom edge, not a
        /// label floating in a vertical inset.
        static var codeEditorPathBarHeightPX: CGFloat { UIScale.scaledMetric(28) }
        static let codeEditorPathBarInsetXPX = Space.x4PX
        /// Off the icon ramp on purpose: the breadcrumb chevron has to sit
        /// inside 11pt type without becoming the loudest thing in the bar.
        static var codeEditorBreadcrumbSeparatorPointSizePT: CGFloat { UIScale.scaledPointSize(8) }
        static let paneDropTargetBorderWidthPX: CGFloat = 2
        static var terminalPaneChromeHeightPX: CGFloat { UIScale.scaledMetric(28) }
        static var terminalPaneChromeCloseWidthPX: CGFloat { UIScale.scaledMetric(24) }
        static let terminalPaneChromeDotSizePX: CGFloat = 6
        static let terminalPaneChromeDotInsetXPX = Space.x4PX
        /// The active pane is marked on its header's leading edge. A full-width
        /// bottom bar reads as a divider between header and terminal; a leading
        /// rail reads as "this pane".
        static let terminalPaneChromeActiveRailWidthPX: CGFloat = 2

        // MARK: Child-exit banner
        //
        // The banner floats over the dead terminal instead of replacing it:
        // whatever the shell printed on its way out is usually the reason the
        // user is looking at the pane at all. Top-leading so it never lands on
        // the search bar, which owns the top-trailing corner.
        static let childExitBannerInsetPX = Space.x4PX
        static var childExitBannerMaxWidthPX: CGFloat { UIScale.scaledMetric(360) }
        static let childExitBannerPaddingXPX = Space.x4PX
        static let childExitBannerPaddingYPX = Space.x3PX
        /// Title to detail line. One label pair, so below a full step.
        static let childExitBannerTextGapPX: CGFloat = 2
        static let childExitBannerTextButtonGapPX = Space.x3PX
        static let childExitBannerButtonGapPX = Space.x2PX
        static let childExitBannerCornerRadiusPX = Radius.mdPX

        // MARK: Command progress bar
        //
        // A bar across the top edge of the pane's terminal, driven by OSC 133
        // command boundaries and OSC 9;4 reports. Ambient status: thick enough
        // to read as a bar rather than a window border, and it never takes
        // layout space from the terminal grid. Well inside
        // `terminalSearchInsetPX`, so the search bar clears it.
        static let commandProgressBarHeightPX: CGFloat = 4
        /// Unfilled remainder, on the same footing as the agent context meter's
        /// groove: low enough to read as a track rather than a second value.
        static let commandProgressTrackAlphaRATIO: CGFloat = 0.16
        /// Width of the sweeping segment, as a fraction of the pane width. Wide
        /// enough to see at this height, narrow enough that its travel reads as
        /// motion rather than as a bar growing.
        static let commandProgressSweepWidthRATIO: CGFloat = 0.30
        /// A determinate bar never renders thinner than this, so a real report
        /// of 1% is still visible instead of rounding away to nothing.
        static let commandProgressMinimumFillWidthPX: CGFloat = 2
        /// Alpha for the static bar shown instead of the sweep when the user has
        /// asked the system to reduce motion. Quieter than the moving segment
        /// because a full-width bar that never moves would otherwise read as a
        /// permanent rule across the pane.
        static let commandProgressReducedMotionAlphaRATIO: CGFloat = 0.45

        static let agentActivityIndicatorSizePX: CGFloat = 12
        static let agentActivityIndicatorDotSizePX: CGFloat = 6
        static let agentActivityIndicatorRingWidthPX: CGFloat = 1.5
        static let agentActivityIndicatorSpinSeconds: CFTimeInterval = 1.1
        static let agentActivityIndicatorArcRatio: CGFloat = 0.75
        static let agentActivityIndicatorArcAlphaRATIO: CGFloat = 0.85
        static let terminalPaneDragPreviewMinWidthPX: CGFloat = 220
        static let terminalPaneDragPreviewMaxWidthPX: CGFloat = 420
        static let terminalPaneDragPreviewTextInsetXPX = Space.x4PX
        static let terminalPaneDragPreviewTextInsetYPX = Space.x3PX
        /// Width of the band between two pane cards. Read through
        /// `TerminalPaneCard.gutterPX`, which is what the split view asks for:
        /// the band is the gutter now, not a hit area wrapped around a rule.
        /// The rule it used to carry (`terminalSplitDividerLinePX`) is gone —
        /// the rounding separates the panes.
        static let terminalSplitDividerHitAreaPX = Space.x3PX
        static let hairlinePX: CGFloat = 1
        static let ptyOutputCoalescingDelaySeconds: TimeInterval = 0.006

        /// Bottom status bar. Nested rather than flattened with a `statusBar`
        /// prefix because the bar owns a full sub-layout (segments, badges,
        /// popovers, responsive breakpoints) and prefixing every member would
        /// make the call sites unreadable. Domain values that the bar happens
        /// to use — percent thresholds, byte scale, process-walk bounds,
        /// sampling and kill timing — are not design tokens and live in
        /// `AppConstants.StatusBar`.
        /// Rate-limit quota meters. A meter is a track and a fill, not a
        /// container for type, so every geometry value here is fixed: a 4px
        /// track scaled to 7px stops reading as a hairline rule and starts
        /// reading as a broken progress bar. Only `rowHeightPX` moves, because
        /// it is a slot the agent label and percentage sit in.
        enum AgentQuota {
            static var rowHeightPX: CGFloat { UIScale.scaledMetric(30) }
            static let meterTrackHeightPX: CGFloat = 4
            static let meterTrackCornerRadiusPX: CGFloat = 2
            /// Floor on the fill so a window with a fraction of a percent spent
            /// still shows something; a fill thinner than this anti-aliases
            /// away and reads as zero.
            static let meterMinimumFillWidthPX: CGFloat = 2
            static let meterTrackAlphaRATIO: CGFloat = 0.9
            static let sectionRowGapPX = Space.x2PX
            static let labelMeterGapPX = Space.x1PX
            /// Slot reserved for the right-aligned percentage so a meter does
            /// not resize as the number crosses 10% or 100%.
            static var percentWidthPX: CGFloat { UIScale.scaledMetric(34) }
            /// The status bar carries the meter as a glyph-sized token beside
            /// its number, not as a full-width bar.
            static let statusBarMeterWidthPX: CGFloat = 22
        }

        enum StatusBar {
            static var heightPX: CGFloat { UIScale.scaledMetric(24) }
            static let horizontalInsetPX = Space.x4PX
            static let segmentGroupGapPX = Space.x4PX
            static let segmentPaddingXPX = Space.x2PX
            static let segmentCornerRadiusPX = Radius.xsPX
            /// A `var`, not a `let`: as a stored constant this would capture the
            /// scale that happened to be installed the first time any status-bar
            /// code ran, and then never move again.
            static var fontSizePT: CGFloat { Typography.statusBar.sizePT }
            static var iconPointSizePT: CGFloat { UIScale.scaledPointSize(11) }
            static let dotSizePX: CGFloat = 6
            static let hollowRingLineWidthPX: CGFloat = 1.5
            static let hollowRingAlphaRATIO: CGFloat = 0.55
            static let dotGlyphGapPX = Space.x1PX
            static let glyphLabelGapPX = Space.x2PX
            static let labelDetailGapPX = Space.x2PX
            static let iconValueGapPX = Space.x1PX
            static let metricGapPX = Space.x4PX
            // Every width below is a slot reserved for a label or a number, so
            // all of them move with the type inside them.
            static var agentLabelMaxWidthPX: CGFloat { UIScale.scaledMetric(160) }
            static var agentDetailMaxWidthPX: CGFloat { UIScale.scaledMetric(96) }
            /// Branch names get less room than the agent label: the segment is
            /// a locator, and the full path lives in the tooltip and popover.
            static var worktreeLabelMaxWidthPX: CGFloat { UIScale.scaledMetric(140) }
            static var worktreeRowBranchMaxWidthPX: CGFloat { UIScale.scaledMetric(150) }
            static var memoryValueMinWidthPX: CGFloat { UIScale.scaledMetric(48) }
            static var cpuValueMinWidthPX: CGFloat { UIScale.scaledMetric(40) }
            static var spinnerSizePX: CGFloat { UIScale.scaledMetric(12) }
            static var badgeHeightPX: CGFloat { UIScale.scaledMetric(14) }
            static let badgeTextInsetXPX = Space.x1PX
            static let badgeCornerRadiusPX: CGFloat = 3
            static var badgeFontSizePT: CGFloat { UIScale.scaledPointSize(9) }
            static let hoverFillAlphaRATIO: CGFloat = 0.07
            static let pressFillAlphaRATIO: CGFloat = 0.14
            static var popoverWidthPX: CGFloat { UIScale.scaledMetric(320) }
            static let popoverInsetPX = Space.x4PX
            static var popoverRowHeightPX: CGFloat { UIScale.scaledMetric(22) }
            static let popoverRowGapPX = Space.x1PX
            static let popoverMaximumRowCount = 12
            /// Responsive-truncation breakpoints, widest first. These decide
            /// when a segment stops fitting, so they move with the type that
            /// stops fitting: pinned, the bar would keep promising a detail
            /// label at 175% that no longer has room to render.
            static var agentDetailBreakpointPX: CGFloat { UIScale.scaledMetric(560) }
            static var cpuMetricBreakpointPX: CGFloat { UIScale.scaledMetric(440) }
            static var agentLabelBreakpointPX: CGFloat { UIScale.scaledMetric(340) }
            static var iconOnlyBreakpointPX: CGFloat { UIScale.scaledMetric(240) }
        }
    }
}

extension NSColor {
    /// Builds a ramp color from an sRGB hex triplet.
    ///
    /// The design ramp is specified in sRGB hex. The generic-RGB constructor
    /// builds a color in a different space, which renders a visibly different
    /// value, so every design token color goes through this sRGB constructor.
    static func designTokenSRGB(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        let maxChannelValue: CGFloat = 255
        let redShift: UInt32 = 16
        let greenShift: UInt32 = 8
        let channelMask: UInt32 = 0xFF
        return NSColor(
            srgbRed: CGFloat((hex >> redShift) & channelMask) / maxChannelValue,
            green: CGFloat((hex >> greenShift) & channelMask) / maxChannelValue,
            blue: CGFloat(hex & channelMask) / maxChannelValue,
            alpha: alpha
        )
    }

    /// Builds a color from a `#RRGGBB` string out of the user's terminal
    /// palette, parsed by the same parser the renderer uses and placed in the
    /// same space the renderer submits to Metal.
    ///
    /// A calibrated- or generic-RGB constructor renders a visibly different
    /// value for the same hex, so any AppKit surface that has to agree with the
    /// terminal — the settings theme preview above all — must come through
    /// here. `nil` for anything that is not a six-digit triplet, so callers can
    /// tell "unset" from black.
    static func terminalPaletteSRGB(_ hex: String) -> NSColor? {
        guard let components = ColorHexParser.components(hex) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat(components.x),
            green: CGFloat(components.y),
            blue: CGFloat(components.z),
            alpha: CGFloat(components.w)
        )
    }

    /// The `#RRGGBB` spelling of this color in sRGB, the inverse of
    /// `terminalPaletteSRGB`. Round-tripping through a device space instead
    /// would rewrite the user's palette with shifted values the first time they
    /// touched a color well.
    var terminalPaletteHex: String {
        guard let srgb = usingColorSpace(.sRGB) else {
            return ColorHexParser.blackHex
        }
        let maxChannelValue: CGFloat = 255
        return String(
            format: "#%02X%02X%02X",
            Int(round(srgb.redComponent * maxChannelValue)),
            Int(round(srgb.greenComponent * maxChannelValue)),
            Int(round(srgb.blueComponent * maxChannelValue))
        )
    }
}

extension SIMD4 where Scalar == Float {
    var cgColor: CGColor {
        CGColor(
            red: CGFloat(x),
            green: CGFloat(y),
            blue: CGFloat(z),
            alpha: CGFloat(w)
        )
    }

    var isLightTerminalBackground: Bool {
        (0.2126 * x + 0.7152 * y + 0.0722 * z) > 0.5
    }
}
