import AppKit
import QuartzCore

/// Paints the ground the terminal pane cards float on.
///
/// The ground is a flat `terminalPaneGround` fill in every theme that does not
/// declare `ChromeTheme.groundGradient`, which is what it has always been. A
/// theme that does declare one gets a single vertical grade instead — drawn
/// once, on the window's ground host, spanning the whole content area.
///
/// Drawing it once is the entire design. The ground is not one view: the host
/// owns the outer margin, each `SplitTerminalView` owns its gutters, and each
/// `TerminalPaneView` owns the slivers its rounded corners cut out of itself.
/// Giving every one of them its own gradient layer would restart the grade at
/// each view's top edge, and a four-way split would show four ramps stacked
/// into visible bands. So the host draws, and the descendants stop painting
/// ground at all — `descendantFill` hands them `.clear` and the host shows
/// through the gutters and the corner cutouts.
///
/// The grid is untouched by all of this. The card is filled with the user's
/// terminal background and nothing here composites onto it.
@MainActor
enum ChromeGroundGradient {
    /// Identifies the gradient sublayer so re-applying a theme replaces it
    /// rather than stacking a second one behind the first.
    private static let layerName = "kurotty.chrome.groundGradient"

    /// Paints `view` as the ground for `theme`. Safe to call on every theme
    /// change: switching to a flat theme removes a gradient installed by a
    /// previous one.
    static func apply(_ theme: DesignTokens.ChromeTheme, to view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        guard let stops = theme.groundGradient else {
            removeGradientLayer(from: layer)
            layer.backgroundColor = theme.terminalPaneGround.cgColor
            return
        }

        // The gradient layer is opaque and covers the host, so the backing
        // color underneath it would never be seen; it is still set to the top
        // stop rather than left stale, because that is the color a resize
        // exposes for the frame before the sublayer catches up.
        layer.backgroundColor = stops.top.cgColor
        let gradient = existingGradientLayer(in: layer) ?? insertGradientLayer(into: layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = [stops.top.cgColor, stops.bottom.cgColor]
        // A gradient layer's unit y runs bottom-up on an unflipped view and
        // top-down on a flipped one, so "top" is not a fixed unit point. Picking
        // either constant renders the grade inverted on the other kind of view,
        // which puts its darkest end against the tab bar — the one edge the two
        // stops were chosen to make seamless.
        let topUnitY: CGFloat = view.isFlipped ? 0 : 1
        gradient.startPoint = CGPoint(x: 0.5, y: topUnitY)
        gradient.endPoint = CGPoint(x: 0.5, y: 1 - topUnitY)
        gradient.frame = layer.bounds
        CATransaction.commit()
    }

    /// The fill a ground-painting descendant of the gradient host should use.
    ///
    /// `.clear` under a gradient is not an omission: it is how the one grade
    /// reaches the gutters and the card corners. Under a flat theme it is the
    /// ground color, exactly as before.
    static func descendantFill(_ theme: DesignTokens.ChromeTheme) -> NSColor {
        theme.groundGradient == nil ? theme.terminalPaneGround : .clear
    }

    /// Keeps an installed gradient on the host's bounds. Called from `layout`,
    /// because a `CAGradientLayer` added as a sublayer does not resize with its
    /// parent the way a backing color does.
    static func layoutGradient(in view: NSView) {
        guard let layer = view.layer, let gradient = existingGradientLayer(in: layer) else { return }
        guard gradient.frame != layer.bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = layer.bounds
        CATransaction.commit()
    }

    fileprivate static func existingGradientLayer(in layer: CALayer) -> CAGradientLayer? {
        layer.sublayers?.first { $0.name == layerName } as? CAGradientLayer
    }

    private static func insertGradientLayer(into layer: CALayer) -> CAGradientLayer {
        let gradient = CAGradientLayer()
        gradient.name = layerName
        // `colors` is not one of the keys `ChromeMotion` silences, and a theme
        // switch must be instant like every other one.
        ChromeMotion.disableImplicitAnimations(on: gradient)
        gradient.actions?["colors"] = NSNull()
        layer.insertSublayer(gradient, at: 0)
        return gradient
    }

    private static func removeGradientLayer(from layer: CALayer) {
        existingGradientLayer(in: layer)?.removeFromSuperlayer()
    }
}

/// The window's ground host.
///
/// It is a subclass for one reason: a backing color follows its view's bounds
/// for free, and a `CAGradientLayer` sublayer does not. The ground resizes on
/// every window resize, sidebar toggle, and command-history split, so the
/// gradient has to be re-framed from `layout` or it stretches out of the view.
@MainActor
final class ChromeGroundHostView: NSView {
    override func layout() {
        super.layout()
        ChromeGroundGradient.layoutGradient(in: self)
    }
}
