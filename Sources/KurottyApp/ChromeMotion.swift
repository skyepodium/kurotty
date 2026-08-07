import AppKit
import QuartzCore

/// The few places in Kurotty chrome that are allowed to move.
///
/// Motion here is deliberately scarce. Row hover, press, and selection fills,
/// tab add/remove/reorder, text content updates, terminal rendering, search bar
/// appearance, focus rings, theme switches, badge counts, and preferences pane
/// switching must all be instant: a fade on a hover fill makes a list feel
/// laggy, and animated chrome competes with the terminal for attention. Only a
/// state change the user cannot otherwise follow gets animated — the command
/// progress sweep is the one case where the movement *is* the information,
/// because "still running" has nothing else to show.
///
/// The durations themselves are design tokens and live in
/// `DesignTokens.Motion`; this enum is the behaviour that reads them.
@MainActor
enum ChromeMotion {
    /// Rotates a disclosure chevron between collapsed (0°) and expanded (90°).
    ///
    /// The rotation happens around the view's own center, so the caller does not
    /// have to reposition the chevron. Pass `animated: false` for the initial
    /// state so a freshly built row does not spin on first display.
    static func rotateDisclosureChevron(_ view: NSView, expanded: Bool, animated: Bool = true) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        centerAnchorPoint(of: layer, in: view)
        let radians = (expanded ? DesignTokens.Motion.disclosureExpandedRotationDegrees : DesignTokens.Motion.disclosureCollapsedRotationDegrees)
            * .pi / 180
        let transform = CATransform3DMakeRotation(radians, 0, 0, 1)
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = transform
            CATransaction.commit()
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.transform ?? layer.transform
        animation.toValue = transform
        animation.duration = DesignTokens.Motion.seconds(fromMS: DesignTokens.Motion.disclosureRotationDurationMS)
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = transform
        layer.add(animation, forKey: "chromeDisclosureRotation")
    }

    /// Crossfades a status-bar value in place: the old value fades out, the
    /// caller's `apply` swaps the text while the view is invisible, and the new
    /// value fades in. Linear, because a value readout is not a gesture.
    static func crossfadeValueChange(_ view: NSView, apply: @escaping () -> Void) {
        let halfDuration = DesignTokens.Motion.seconds(fromMS: DesignTokens.Motion.statusValueCrossfadeDurationMS) / 2
        NSAnimationContext.runAnimationGroup { context in
            context.duration = halfDuration
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            view.animator().alphaValue = 0
        } completionHandler: {
            apply()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = halfDuration
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                view.animator().alphaValue = 1
            }
        }
    }

    /// Whether the user has asked the system to reduce motion.
    ///
    /// Read at the moment a decision is made rather than cached: the setting is
    /// live, and macOS posts
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` when it
    /// flips, so a chrome view that observes that notification and re-asks here
    /// is always current.
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Sweeps a pane's command progress bar across its track, forever, until
    /// `stopCommandProgressSweep` removes it.
    ///
    /// Core Animation owns every frame. A `Timer` repainting on the main queue
    /// would run for the whole life of a twenty-minute build, competing with the
    /// terminal it is reporting on — the one surface in the app that must never
    /// lose main-queue time.
    ///
    /// `prefersReducedMotion` is a parameter, not a read inside the body, so the
    /// suppression is exercisable without changing a system-wide accessibility
    /// setting. When it is on, nothing is added at all: the caller renders a
    /// static bar instead, and there is no animation left anywhere to leak
    /// through.
    static func startCommandProgressSweep(
        on layer: CALayer,
        fromX: CGFloat,
        toX: CGFloat,
        prefersReducedMotion: Bool = ChromeMotion.prefersReducedMotion
    ) {
        guard !prefersReducedMotion else {
            return
        }
        let animation = CABasicAnimation(keyPath: Sweep.positionKeyPath)
        animation.fromValue = fromX
        animation.toValue = toX
        animation.duration = DesignTokens.Motion.seconds(
            fromMS: DesignTokens.Motion.commandProgressSweepDurationMS
        )
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.repeatCount = .greatestFiniteMagnitude
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Sweep.animationKey)
    }

    static func stopCommandProgressSweep(on layer: CALayer) {
        layer.removeAnimation(forKey: Sweep.animationKey)
    }

    /// Whether `layer` is currently sweeping. Exposed because an animation a
    /// caller added is not otherwise observable by name.
    static func isCommandProgressSweeping(_ layer: CALayer) -> Bool {
        layer.animation(forKey: Sweep.animationKey) != nil
    }

    private enum Sweep {
        static let animationKey = "dev.kurotty.commandProgress.sweep"
        static let positionKeyPath = "position.x"
    }

    /// Turns off implicit CALayer animation for the properties that AppKit
    /// otherwise animates behind your back. Any layer-backed chrome view that
    /// repaints a fill or moves during layout should call this once.
    static func disableImplicitAnimations(on layer: CALayer) {
        layer.actions = [
            "backgroundColor": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "borderColor": NSNull(),
            "contents": NSNull(),
        ]
    }

    private static func centerAnchorPoint(of layer: CALayer, in view: NSView) {
        let center = CGPoint(x: 0.5, y: 0.5)
        guard layer.anchorPoint != center else { return }
        layer.anchorPoint = center
        layer.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }
}

/// Left-sidebar section switch, factored out of the section strip so the strip
/// (owned elsewhere) only has to hand over the views.
///
/// The two lists are peers, not a navigation stack, so there is no horizontal
/// slide: sliding would claim a spatial relationship that does not exist. The
/// selection pill travels, and the lists trade places through opacity only.
///
/// `TerminalLeftSidebarPanelView` drives this from its section-strip action.
@MainActor
enum SidebarMotion {
    /// Animates a section switch.
    ///
    /// - Parameters:
    ///   - selectionPill: the raised pill behind the selected section tab.
    ///   - toFrame: the pill's frame for the newly selected section; both
    ///     x-position and width animate.
    ///   - outgoing: the list leaving the screen. Faded 1 → 0 over the first
    ///     half of the switch, then hidden.
    ///   - incoming: the list arriving. Unhidden immediately at alpha 0 and
    ///     faded 0 → 1 over the second half.
    static func animateSectionChange(
        selectionPill: NSView?,
        toFrame: NSRect,
        outgoing: NSView?,
        incoming: NSView?,
        completion: (() -> Void)? = nil
    ) {
        let totalDuration = DesignTokens.Motion.seconds(fromMS: DesignTokens.Motion.sectionSwitchDurationMS)
        let fadeDuration = DesignTokens.Motion.seconds(fromMS: DesignTokens.Motion.sectionListFadeDurationMS)

        if let selectionPill {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = totalDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                selectionPill.animator().frame = toFrame
            }
        }

        incoming?.alphaValue = 0
        incoming?.isHidden = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            outgoing?.animator().alphaValue = 0
        } completionHandler: {
            outgoing?.isHidden = true
            outgoing?.alphaValue = 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                incoming?.animator().alphaValue = 1
            } completionHandler: {
                completion?()
            }
        }
    }
}
