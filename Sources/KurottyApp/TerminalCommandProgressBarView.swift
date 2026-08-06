import AppKit
import KurottyCore
import QuartzCore

/// The bar across the top edge of a pane's terminal that says a command is
/// still running.
///
/// Per pane, never per window: in a split, one busy pane must not imply the
/// whole window is busy. `TerminalCommandProgressPolicy` owns every visibility
/// decision, so this view is only geometry, color, and one repeating
/// `CABasicAnimation`.
///
/// Rendering contract, the same one `AgentActivityIndicatorView` keeps:
/// everything is CALayer state, no `draw(_:)` and no per-frame Swift runs. The
/// only wake-ups this view schedules are the two one-shot transitions the
/// policy predicts — the moment the bar becomes due, and the moment a failed
/// command's bar expires.
@MainActor
final class TerminalCommandProgressBarView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var policy = TerminalCommandProgressPolicy(
        isEnabled: SettingsDefaults.commandProgressIndicatorEnabled,
        appearanceDelaySeconds: DesignTokens.Motion.seconds(
            fromMS: DesignTokens.Motion.commandProgressAppearanceDelayMS
        ),
        failureLingerSeconds: DesignTokens.Motion.seconds(
            fromMS: DesignTokens.Motion.commandProgressFailureLingerMS
        ),
        sweepCeilingSeconds: DesignTokens.Motion.seconds(
            fromMS: DesignTokens.Motion.commandProgressSweepCeilingMS
        )
    )
    private var presentation: TerminalCommandProgressPresentation?
    /// Sweep width the running animation was built for, or `nil` when nothing is
    /// sweeping. A layout pass re-applies the whole presentation, and re-adding
    /// the animation would restart its phase — a visible stutter every time the
    /// window resizes — so the sweep is rebuilt only when its geometry changed.
    private var sweepWidthInFlight: CGFloat?
    private var scheduledEvaluation: DispatchWorkItem?
    private var chromeTheme = DesignTokens.ChromeTheme.dark

    /// Mirror of `NSWorkspace.accessibilityDisplayShouldReduceMotion`, refreshed
    /// from the workspace notification. Settable so both paths can be exercised
    /// without changing a system-wide accessibility setting.
    var prefersReducedMotion: Bool = ChromeMotion.prefersReducedMotion {
        didSet {
            guard prefersReducedMotion != oldValue else {
                return
            }
            applyPresentation()
        }
    }

    /// What the bar is drawing, or `nil` while it is off screen. Read by tests,
    /// which have no other way to observe chrome that owns no model state.
    var presentationForTesting: TerminalCommandProgressPresentation? {
        presentation
    }

    var isSweepingForTesting: Bool {
        ChromeMotion.isCommandProgressSweeping(fillLayer)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
        observeAccessibilityDisplayOptions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: DesignTokens.Component.commandProgressBarHeightPX
        )
    }

    override var isFlipped: Bool {
        true
    }

    /// Applies `terminal.commandProgressIndicatorEnabled`. Live: turning it off
    /// takes a bar that is on screen right now down with it, which is the state
    /// the user is looking at when they reach for the switch.
    func setEnabled(_ isEnabled: Bool) {
        guard policy.isEnabled != isEnabled else {
            return
        }
        policy.isEnabled = isEnabled
        refresh()
    }

    func handle(_ event: TerminalCommandProgressEvent) {
        let now = Date()
        switch event {
        case .commandStarted:
            policy.commandDidStart(at: now)
        case .reported(let report):
            policy.didReceive(report)
        case .commandEnded(let exitCode):
            policy.commandDidEnd(exitCode: exitCode, at: now)
        case .alternateScreenEntered:
            policy.alternateScreenDidActivate()
        case .userDidInteract:
            policy.userDidInteract()
        }
        refresh()
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        applyPresentation()
    }

    override func layout() {
        super.layout()
        applyPresentation()
    }

    private func configureLayers() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        // The fill's own geometry is animated explicitly; letting AppKit also
        // animate it implicitly makes the sweep fight a layout pass.
        ChromeMotion.disableImplicitAnimations(on: trackLayer)
        ChromeMotion.disableImplicitAnimations(on: fillLayer)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(AppLocalization.string(.commandProgressAccessibility))
        isHidden = true
    }

    /// Reduced motion is a live setting, so the bar re-asks whenever the system
    /// posts a change. No `deinit` unregistration: the observer is a zeroing
    /// weak reference, and the pending work item holds `self` weakly, so a
    /// discarded pane leaves nothing behind either way.
    private func observeAccessibilityDisplayOptions() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        prefersReducedMotion = ChromeMotion.prefersReducedMotion
    }

    /// Re-reads the policy and re-arms the single pending wake-up.
    ///
    /// The delay comes from the policy rather than from a tick: with no command
    /// running there is no scheduled work at all.
    private func refresh() {
        let now = Date()
        presentation = policy.presentation(at: now)
        applyPresentation()

        scheduledEvaluation?.cancel()
        scheduledEvaluation = nil
        guard let next = policy.nextPresentationChange(after: now) else {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        scheduledEvaluation = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, next.timeIntervalSince(now)),
            execute: work
        )
    }

    private func applyPresentation() {
        guard let presentation else {
            isHidden = true
            stopSweep()
            setAccessibilityValue(nil)
            return
        }
        isHidden = false
        trackLayer.frame = bounds
        trackLayer.backgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(DesignTokens.Component.commandProgressTrackAlphaRATIO)
            .cgColor
        fillLayer.backgroundColor = fillColor(for: presentation.tone).cgColor

        switch presentation.fill {
        case .fraction(let fraction):
            applyDeterminateFill(fraction: fraction)
            setAccessibilityValue(fraction)
        case .indeterminate:
            applyIndeterminateFill(motion: presentation.motion)
            setAccessibilityValue(nil)
        }
    }

    /// The policy decides whether the bar has anything to animate about; this
    /// view only adds the accessibility setting, which the policy has no
    /// business reading.
    private func applyIndeterminateFill(motion: TerminalCommandProgressPresentation.Motion) {
        guard !prefersReducedMotion, motion == .sweeping else {
            applyStaticIndeterminateFill()
            return
        }
        let sweepWidth = max(
            DesignTokens.Component.commandProgressMinimumFillWidthPX,
            bounds.width * DesignTokens.Component.commandProgressSweepWidthRATIO
        )
        guard sweepWidthInFlight != sweepWidth || !ChromeMotion.isCommandProgressSweeping(fillLayer) else {
            return
        }
        sweepWidthInFlight = sweepWidth
        fillLayer.opacity = 1
        fillLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        fillLayer.bounds = CGRect(x: 0, y: 0, width: sweepWidth, height: bounds.height)
        fillLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ChromeMotion.startCommandProgressSweep(
            on: fillLayer,
            fromX: -sweepWidth / 2,
            toX: bounds.width + sweepWidth / 2,
            prefersReducedMotion: prefersReducedMotion
        )
    }

    /// Every still indeterminate bar — reduced motion, a paused command, a
    /// sweep past its ceiling — gets a full-width bar at a quieter alpha
    /// instead. Still honest: "something is running, nobody said how far
    /// along", with no movement to make. One presentation for all three so the
    /// ceiling introduces no new visual state, and so a reduced-motion user
    /// sees nothing change when it fires.
    private func applyStaticIndeterminateFill() {
        stopSweep()
        fillLayer.opacity = Float(DesignTokens.Component.commandProgressReducedMotionAlphaRATIO)
        setFillFrame(width: bounds.width)
    }

    private func applyDeterminateFill(fraction: Double) {
        stopSweep()
        fillLayer.opacity = 1
        let clamped = min(1, max(0, fraction))
        let width = clamped == 0
            ? 0
            : max(DesignTokens.Component.commandProgressMinimumFillWidthPX, bounds.width * clamped)
        setFillFrame(width: width)
    }

    private func stopSweep() {
        sweepWidthInFlight = nil
        ChromeMotion.stopCommandProgressSweep(on: fillLayer)
    }

    private func setFillFrame(width: CGFloat) {
        fillLayer.anchorPoint = CGPoint(x: 0, y: 0)
        fillLayer.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        fillLayer.position = CGPoint(x: bounds.minX, y: bounds.minY)
    }

    private func fillColor(for tone: TerminalCommandProgressPresentation.Tone) -> NSColor {
        switch tone {
        case .running:
            return chromeTheme.accent
        case .failed:
            return chromeTheme.error
        case .paused:
            return chromeTheme.warning
        }
    }
}
