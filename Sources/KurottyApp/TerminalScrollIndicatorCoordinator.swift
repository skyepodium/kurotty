import AppKit

/// Where the scrollback indicator sits for a given scroll position.
///
/// Split out of the coordinator because this is the part worth pinning down:
/// the mapping from scrollback offset to thumb frame is pure arithmetic, and
/// keeping it free of AppKit means it can be exercised without a window.
struct TerminalScrollIndicatorMetrics: Equatable {
    /// The full-height strip the indicator lives in, flush to the trailing edge.
    let trackFrame: NSRect
    /// The thumb, centered in the track.
    let thumbFrame: NSRect

    /// Returns `nil` when there is nothing to scroll. That is the signal to
    /// take the indicator off screen entirely rather than draw a thumb that
    /// fills the whole track and cannot move.
    ///
    /// - Parameter trailingInsetPX: width already claimed at the trailing edge
    ///   by the prompt navigator rail. The track slides inboard by exactly that
    ///   much rather than sharing it: two things drawing in one strip is the
    ///   bug this file was rewritten to remove, and the rail is not allowed to
    ///   reintroduce it in a new shape.
    static func metrics(
        in bounds: NSRect,
        visibleRows: Int,
        maxScrollbackOffset: Int,
        scrollbackOffset: Int,
        trailingInsetPX: CGFloat = 0
    ) -> TerminalScrollIndicatorMetrics? {
        guard maxScrollbackOffset > 0, bounds.height > 0, visibleRows > 0 else {
            return nil
        }

        let trackWidth = DesignTokens.Component.terminalScrollerWidthPX
        let trailingInset = max(0, min(trailingInsetPX, max(0, bounds.width - trackWidth)))
        let trackFrame = NSRect(
            x: max(0, bounds.width - trackWidth - trailingInset),
            y: 0,
            width: trackWidth,
            height: bounds.height
        )

        let trackHeight = max(CGFloat(1), trackFrame.height)
        let contentRows = visibleRows + maxScrollbackOffset
        let proportionalKnob = CGFloat(visibleRows) / CGFloat(contentRows)
        // A proportional thumb over a 100k-row scrollback is a sliver, so the
        // thumb also has an absolute floor in points and a floor as a fraction
        // of the track; whichever is largest wins.
        let minimumHeightKnob = DesignTokens.Component.terminalScrollerMinThumbHeightPX / trackHeight
        let knobProportion = min(
            CGFloat(1),
            max(
                DesignTokens.Component.terminalScrollerMinKnobProportion,
                minimumHeightKnob,
                proportionalKnob
            )
        )

        let thumbWidth = DesignTokens.Component.terminalScrollerThumbWidthPX
        let thumbHeight = min(trackHeight, trackHeight * knobProportion)
        let maxTravel = max(CGFloat.zero, trackHeight - thumbHeight)
        let normalizedOffset = max(
            CGFloat.zero,
            min(CGFloat(1), CGFloat(scrollbackOffset) / CGFloat(maxScrollbackOffset))
        )
        let thumbFrame = NSRect(
            x: trackFrame.minX + (trackFrame.width - thumbWidth) / 2,
            y: trackFrame.minY + maxTravel * normalizedOffset,
            width: thumbWidth,
            height: thumbHeight
        )
        return TerminalScrollIndicatorMetrics(trackFrame: trackFrame, thumbFrame: thumbFrame)
    }
}

/// The terminal's scrollback indicator.
///
/// There is exactly one view here on purpose. This used to install a real
/// `NSScroller` in `.legacy` style — which draws its own track and knob — and
/// then stack a hand-rolled thumb on top of it, so two scrollbars rendered in
/// the same 12pt strip and neither one owned the pixels.
///
/// The indicator is an overlay, not a reserved gutter: it appears when the
/// scroll position moves and fades back out once the view goes idle, so it is
/// not permanently covering the last column of terminal output.
@MainActor
final class TerminalScrollIndicatorCoordinator: NSObject {
    private let thumbView = ScrollIndicatorThumbView(frame: .zero)
    private let onNormalizedScrollbackOffsetChange: (CGFloat) -> Void
    private let idleFadeDelaySeconds: TimeInterval
    private let observesSettingsChanges: Bool
    private var chromeTheme: DesignTokens.ChromeTheme
    private var lastMetrics: TerminalScrollIndicatorMetrics?
    private var idleFadeTimer: Timer?

    /// - Parameters:
    ///   - chromeTheme: pass a theme to pin the indicator to it; the app passes
    ///     nothing and the coordinator tracks the terminal background setting
    ///     the same way `ChromeTheme.theme(for:)` does.
    ///   - idleFadeDelaySeconds: how long the indicator stays up after the last
    ///     scroll. Injectable so a test does not have to wait out the real one.
    init(
        chromeTheme: DesignTokens.ChromeTheme? = nil,
        idleFadeDelaySeconds: TimeInterval = DesignTokens.Motion.seconds(
            fromMS: DesignTokens.Motion.scrollIndicatorIdleDelayMS
        ),
        onNormalizedScrollbackOffsetChange: @escaping (CGFloat) -> Void
    ) {
        self.onNormalizedScrollbackOffsetChange = onNormalizedScrollbackOffsetChange
        self.idleFadeDelaySeconds = idleFadeDelaySeconds
        self.observesSettingsChanges = chromeTheme == nil
        self.chromeTheme = chromeTheme ?? Self.resolvedChromeTheme()
        super.init()
        configureThumbView()
        guard observesSettingsChanges else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func install(in view: NSView) {
        view.addSubview(thumbView)
    }

    func layout(
        in bounds: NSRect,
        visibleRows: Int,
        maxScrollbackOffset: Int,
        scrollbackOffset: Int,
        trailingInsetPX: CGFloat = 0
    ) {
        update(
            bounds: bounds,
            visibleRows: visibleRows,
            maxScrollbackOffset: maxScrollbackOffset,
            scrollbackOffset: scrollbackOffset,
            trailingInsetPX: trailingInsetPX
        )
    }

    func update(
        bounds: NSRect,
        visibleRows: Int,
        maxScrollbackOffset: Int,
        scrollbackOffset: Int,
        trailingInsetPX: CGFloat = 0
    ) {
        guard let metrics = TerminalScrollIndicatorMetrics.metrics(
            in: bounds,
            visibleRows: visibleRows,
            maxScrollbackOffset: maxScrollbackOffset,
            scrollbackOffset: scrollbackOffset,
            trailingInsetPX: trailingInsetPX
        ) else {
            hideIndicator()
            return
        }

        // Reveal on a change of *position* only. Following live output grows the
        // scrollback, which reshapes the thumb every frame while the user's
        // position is still pinned to the bottom; flashing the indicator on that
        // would make it strobe through any long build log.
        let didMovePosition = metrics.thumbFrame.origin != lastMetrics?.thumbFrame.origin
        lastMetrics = metrics
        thumbView.frame = metrics.thumbFrame
        thumbView.needsDisplay = true
        guard didMovePosition else { return }
        revealThenScheduleIdleFade()
    }

    func setChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        thumbView.chromeTheme = theme
    }

    // MARK: - Test seams

    /// The indicator as the user sees it: a hidden or fully faded thumb is not
    /// on screen, and a hidden view also stops swallowing clicks in the strip.
    var isIndicatorVisibleForTesting: Bool {
        !thumbView.isHidden && thumbView.alphaValue > 0
    }

    var thumbViewForTesting: ScrollIndicatorThumbView {
        thumbView
    }

    // MARK: - Visibility

    private func revealThenScheduleIdleFade() {
        idleFadeTimer?.invalidate()
        idleFadeTimer = nil
        thumbView.alphaValue = 1
        thumbView.isHidden = false
        guard !thumbView.isPointerEngaged else { return }
        idleFadeTimer = Timer.scheduledTimer(withTimeInterval: idleFadeDelaySeconds, repeats: false) { [weak self] _ in
            // Timer callbacks are delivered on the main run loop, which is the
            // main actor; the hop keeps that explicit for Swift concurrency.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.fadeOutIndicator()
                }
            }
        }
    }

    private func fadeOutIndicator() {
        idleFadeTimer = nil
        guard !thumbView.isHidden, !thumbView.isPointerEngaged else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.seconds(
                fromMS: DesignTokens.Motion.scrollIndicatorFadeDurationMS
            )
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            thumbView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // A scroll during the fade already put the thumb back at full
            // opacity; hiding it now would drop the state the user just asked
            // for.
            guard let self, self.thumbView.alphaValue == 0 else { return }
            // Hidden rather than parked at alpha 0: an invisible view still
            // hit-tests, and a strip that eats selection drags it does not draw
            // is worse than the scrollbar it replaced. `lastMetrics` is kept, so
            // output arriving under a bottom-pinned view does not re-reveal it.
            self.thumbView.isHidden = true
            self.thumbView.alphaValue = 1
        }
    }

    private func hideIndicator() {
        idleFadeTimer?.invalidate()
        idleFadeTimer = nil
        lastMetrics = nil
        thumbView.isHidden = true
        thumbView.alphaValue = 1
    }

    // MARK: - Wiring

    private func configureThumbView() {
        thumbView.chromeTheme = chromeTheme
        thumbView.layer?.cornerRadius = DesignTokens.Component.terminalScrollerThumbWidthPX / 2
        thumbView.onDragNormalizedOffset = { [weak self] normalizedOffset in
            self?.onNormalizedScrollbackOffsetChange(normalizedOffset)
        }
        thumbView.onPointerEngagementChange = { [weak self] isEngaged in
            guard let self else { return }
            guard isEngaged else {
                self.revealThenScheduleIdleFade()
                return
            }
            self.idleFadeTimer?.invalidate()
            self.idleFadeTimer = nil
            self.thumbView.alphaValue = 1
        }
        thumbView.isHidden = true
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        setChromeTheme(DesignTokens.ChromeTheme.theme(for: settings))
    }

    private static func resolvedChromeTheme() -> DesignTokens.ChromeTheme {
        DesignTokens.ChromeTheme.theme(for: (try? AppSettingsStore.shared.load()) ?? .default)
    }
}
