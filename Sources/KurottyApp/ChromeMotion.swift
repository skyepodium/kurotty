import AppKit
import QuartzCore

/// The three places in Kurotty chrome that are allowed to move.
///
/// Motion here is deliberately scarce. Row hover, press, and selection fills,
/// tab add/remove/reorder, text content updates, terminal rendering, search bar
/// appearance, focus rings, theme switches, badge counts, and preferences pane
/// switching must all be instant: a fade on a hover fill makes a list feel
/// laggy, and animated chrome competes with the terminal for attention. Only a
/// state change the user cannot otherwise follow gets animated.
///
/// MIGRATION: these durations belong next to the rest of the design tokens once
/// `DesignTokens.swift` is free; they live here because that file is owned by
/// another agent during this pass.
@MainActor
enum ChromeMotion {
    /// Sidebar section switch. Long enough to read the underline travelling,
    /// short enough that a fast click never queues.
    static let sectionSwitchDurationMS = 160
    /// Each half of the sidebar list crossfade.
    static let sectionListFadeDurationMS = 80
    /// Disclosure chevron rotation.
    static let disclosureRotationDurationMS = 150
    /// Full status-bar value crossfade (out + in).
    static let statusValueCrossfadeDurationMS = 120

    static let disclosureCollapsedRotationDegrees: CGFloat = 0
    static let disclosureExpandedRotationDegrees: CGFloat = 90

    static func seconds(fromMS milliseconds: Int) -> TimeInterval {
        TimeInterval(milliseconds) / 1000
    }

    /// Rotates a disclosure chevron between collapsed (0°) and expanded (90°).
    ///
    /// The rotation happens around the view's own center, so the caller does not
    /// have to reposition the chevron. Pass `animated: false` for the initial
    /// state so a freshly built row does not spin on first display.
    static func rotateDisclosureChevron(_ view: NSView, expanded: Bool, animated: Bool = true) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        centerAnchorPoint(of: layer, in: view)
        let radians = (expanded ? disclosureExpandedRotationDegrees : disclosureCollapsedRotationDegrees)
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
        animation.duration = seconds(fromMS: disclosureRotationDurationMS)
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = transform
        layer.add(animation, forKey: "chromeDisclosureRotation")
    }

    /// Crossfades a status-bar value in place: the old value fades out, the
    /// caller's `apply` swaps the text while the view is invisible, and the new
    /// value fades in. Linear, because a value readout is not a gesture.
    static func crossfadeValueChange(_ view: NSView, apply: @escaping () -> Void) {
        let halfDuration = seconds(fromMS: statusValueCrossfadeDurationMS) / 2
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
/// underline travels, and the lists trade places through opacity only.
///
/// MIGRATION: `TerminalLeftSidebarPanelView` should call
/// `SidebarMotion.animateSectionChange(...)` from its segment action instead of
/// setting the underline frame and `isHidden` directly.
@MainActor
enum SidebarMotion {
    /// Animates a section switch.
    ///
    /// - Parameters:
    ///   - underline: the selection underline under the section strip.
    ///   - toFrame: the underline's frame for the newly selected section; both
    ///     x-position and width animate.
    ///   - outgoing: the list leaving the screen. Faded 1 → 0 over the first
    ///     half of the switch, then hidden.
    ///   - incoming: the list arriving. Unhidden immediately at alpha 0 and
    ///     faded 0 → 1 over the second half.
    static func animateSectionChange(
        underline: NSView?,
        toFrame: NSRect,
        outgoing: NSView?,
        incoming: NSView?,
        completion: (() -> Void)? = nil
    ) {
        let totalDuration = ChromeMotion.seconds(fromMS: ChromeMotion.sectionSwitchDurationMS)
        let fadeDuration = ChromeMotion.seconds(fromMS: ChromeMotion.sectionListFadeDurationMS)

        if let underline {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = totalDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                underline.animator().frame = toFrame
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
