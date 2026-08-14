import AppKit
import QuartzCore

/// Paints the ground the terminal pane cards float on.
///
/// The ground is a flat `terminalPaneGround` fill in every theme that does not
/// declare `ChromeTheme.groundMesh`, which is what it has always been. A theme
/// that does declare one gets a mesh instead — a base plane with a few tints
/// laid over it, drawn once on the window's ground host, spanning the whole
/// content area.
///
/// **A mesh rather than a grade, because a grade can only be one hue.** The
/// ground used to be two stops on a vertical axis, which is the one thing a
/// pearlescent surface never looks like: on nacre the hue travels across the
/// surface while the brightness barely moves. Each tint is its own radial layer
/// fading to nothing at its edge, so three of them overlap into a field no
/// single `CAGradientLayer` can describe.
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
    /// Prefixes the tint sublayers so re-applying a theme replaces them rather
    /// than stacking a second mesh behind the first.
    private static let layerNamePrefix = "kurotty.chrome.groundTint."

    /// Paints `view` as the ground for `theme`. Safe to call on every theme
    /// change: switching to a flat theme removes a gradient installed by a
    /// previous one.
    static func apply(_ theme: DesignTokens.ChromeTheme, to view: NSView) {
        apply(mesh: theme.groundMesh, to: view)
    }

    /// Paints one mesh directly, without a theme around it.
    ///
    /// Separate so a ground can be described and checked on its own: the mesh
    /// is the whole input, and nothing else about a theme reaches this.
    static func apply(mesh: DesignTokens.GroundMesh, to view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        // The base is the backing color rather than a layer of its own: it is
        // what the ground shows where no tint reaches, and it is the color a
        // resize exposes for the frame before the sublayers catch up.
        layer.backgroundColor = mesh.base.cgColor
        removeTintLayers(from: layer)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, tint) in mesh.tints.enumerated() {
            let sublayer = insertTintLayer(into: layer, index: index)
            apply(tint, to: sublayer, bounds: layer.bounds, isFlipped: view.isFlipped)
        }
        CATransaction.commit()
    }

    /// Lays one tint out as an ellipse that fades to nothing at its edge.
    ///
    /// The fade is the whole mechanism: an opaque radial stop would draw a disc
    /// with a visible rim, and what is wanted is a bloom with no edge at all. So
    /// the outer stop is the same color at zero alpha, and three of them
    /// composite into a field rather than into three shapes.
    private static func apply(
        _ tint: DesignTokens.GroundMesh.Tint,
        to layer: CAGradientLayer,
        bounds: CGRect,
        isFlipped: Bool
    ) {
        layer.type = .radial
        layer.colors = [tint.color.cgColor, tint.color.withAlphaComponent(0).cgColor]

        // A layer's unit y runs bottom-up on an unflipped view and top-down on a
        // flipped one, and a tint is placed by where it should appear on screen.
        // Reading the host rather than assuming either convention is what kept
        // the old grade from rendering upside down on half the hierarchy.
        let centerY = isFlipped ? tint.center.y : 1 - tint.center.y
        layer.startPoint = CGPoint(x: tint.center.x, y: centerY)
        layer.endPoint = CGPoint(
            x: tint.center.x + tint.radius.width,
            y: centerY + tint.radius.height
        )
        layer.frame = bounds
    }

    /// The fill every ground-painting descendant of the host should use.
    ///
    /// Clear is not an omission: it is how the host's one field reaches the
    /// gutters between panes and the slivers a card's rounded corners cut out
    /// of itself. Every ramp declares a ground now, so there is no longer a
    /// theme for which a descendant should paint one of its own — a theme that
    /// wants a flat ground says so with `GroundMesh.flat`, and the host still
    /// draws it.
    static let descendantFill = NSColor.clear

    /// Keeps the installed tints on the host's bounds. Called from `layout`,
    /// because a `CAGradientLayer` added as a sublayer does not resize with its
    /// parent the way a backing color does.
    static func layoutGradient(in view: NSView) {
        guard let layer = view.layer else { return }
        let tints = tintLayers(in: layer)
        guard tints.contains(where: { $0.frame != layer.bounds }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tint in tints {
            tint.frame = layer.bounds
        }
        CATransaction.commit()
    }

    fileprivate static func tintLayers(in layer: CALayer) -> [CAGradientLayer] {
        (layer.sublayers ?? []).compactMap { sublayer in
            guard sublayer.name?.hasPrefix(layerNamePrefix) == true else { return nil }
            return sublayer as? CAGradientLayer
        }
    }

    private static func insertTintLayer(into layer: CALayer, index: Int) -> CAGradientLayer {
        let gradient = CAGradientLayer()
        gradient.name = "\(layerNamePrefix)\(index)"
        // `colors` is not one of the keys `ChromeMotion` silences, and a theme
        // switch must be instant like every other one.
        ChromeMotion.disableImplicitAnimations(on: gradient)
        gradient.actions?["colors"] = NSNull()
        layer.insertSublayer(gradient, at: UInt32(index))
        return gradient
    }

    private static func removeTintLayers(from layer: CALayer) {
        for tint in tintLayers(in: layer) {
            tint.removeFromSuperlayer()
        }
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
