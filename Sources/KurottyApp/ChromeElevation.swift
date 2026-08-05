import AppKit

/// Shared shadow ramp for chrome that floats above another surface.
///
/// Every floating surface used to hand-roll its own shadow (the terminal search
/// bar carried `black @ 0.22 / r10 / y-2`), so two overlays at the same
/// conceptual height rendered at different heights. There is exactly one
/// elevation in the app today — a surface that floats over the terminal — so
/// there is exactly one level here.
///
/// MIGRATION: this belongs in `DesignTokens.Elevation` alongside `Space`,
/// `Radius`, and `Type`. It lives here only because `DesignTokens.swift` is
/// owned by another agent during this pass.
enum Elevation {
    /// A surface that floats over the terminal: the search bar today, and any
    /// future popover/HUD that is not a real `NSPanel`.
    ///
    /// Dark chrome needs a deeper, softer shadow than light chrome: on a dark
    /// canvas a shallow shadow is invisible, while on a light canvas the same
    /// shadow reads as smudge.
    struct Shadow {
        let color: NSColor
        let opacity: Float
        let radiusPX: CGFloat
        /// Downward distance in design terms. AppKit's unflipped layer geometry
        /// wants a negative `shadowOffset.height` to push a shadow *down*, so
        /// `apply(to:)` negates this; the token stays positive so the value
        /// matches the spec as written.
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

    /// Picks the floating shadow that matches the active chrome ramp.
    @MainActor
    static func floating(for theme: DesignTokens.ChromeTheme) -> Shadow {
        theme.windowAppearance?.name == .aqua ? floatingLight : floatingDark
    }
}
