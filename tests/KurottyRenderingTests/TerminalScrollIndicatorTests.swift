import AppKit
import XCTest

@testable import KurottyApp

/// The terminal's scrollback indicator, exercised through its own API rather
/// than through the text of the file that implements it.
///
/// The behaviours worth pinning are: exactly one thing draws in the trailing
/// strip, the thumb maps scrollback position to a frame, it leaves when the
/// view is idle, and it is styled like the rest of the chrome.
@MainActor
final class TerminalScrollIndicatorTests: XCTestCase {
    private let testIdleFadeDelaySeconds: TimeInterval = 0.01

    private func makeCoordinator(
        theme: DesignTokens.ChromeTheme = .dark,
        onNormalizedScrollbackOffsetChange: @escaping (CGFloat) -> Void = { _ in }
    ) -> TerminalScrollIndicatorCoordinator {
        TerminalScrollIndicatorCoordinator(
            chromeTheme: theme,
            idleFadeDelaySeconds: testIdleFadeDelaySeconds,
            onNormalizedScrollbackOffsetChange: onNormalizedScrollbackOffsetChange
        )
    }

    /// Spins the run loop: the idle fade is a real `Timer` plus a real
    /// `NSAnimationContext`, and neither one runs without one.
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 5,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    // MARK: - Only one thing draws

    /// The regression this whole rework exists for: a real `NSScroller` in
    /// `.legacy` style draws its own track and knob, and the hand-rolled thumb
    /// was stacked on top of it, so two scrollbars shared one 12pt strip.
    func testInstallAddsExactlyOneIndicatorViewAndNoNSScroller() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        makeCoordinator().install(in: host)

        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertTrue(host.subviews[0] is ScrollIndicatorThumbView)
        XCTAssertNil(host.subviews.first { $0 is NSScroller })
    }

    // MARK: - Geometry

    func testNoMetricsWhenThereIsNothingToScroll() {
        XCTAssertNil(TerminalScrollIndicatorMetrics.metrics(
            in: NSRect(x: 0, y: 0, width: 400, height: 300),
            visibleRows: 24,
            maxScrollbackOffset: 0,
            scrollbackOffset: 0
        ))
    }

    func testNoMetricsWhenTheSurfaceHasNoHeight() {
        XCTAssertNil(TerminalScrollIndicatorMetrics.metrics(
            in: NSRect(x: 0, y: 0, width: 400, height: 0),
            visibleRows: 24,
            maxScrollbackOffset: 500,
            scrollbackOffset: 10
        ))
    }

    func testThumbTravelsTheFullTrackAcrossTheScrollbackRange() throws {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        let atBottom = try XCTUnwrap(TerminalScrollIndicatorMetrics.metrics(
            in: bounds,
            visibleRows: 24,
            maxScrollbackOffset: 500,
            scrollbackOffset: 0
        ))
        let midway = try XCTUnwrap(TerminalScrollIndicatorMetrics.metrics(
            in: bounds,
            visibleRows: 24,
            maxScrollbackOffset: 500,
            scrollbackOffset: 250
        ))
        let atTop = try XCTUnwrap(TerminalScrollIndicatorMetrics.metrics(
            in: bounds,
            visibleRows: 24,
            maxScrollbackOffset: 500,
            scrollbackOffset: 500
        ))

        XCTAssertEqual(atBottom.thumbFrame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(atTop.thumbFrame.maxY, bounds.height, accuracy: 0.001)
        XCTAssertGreaterThan(midway.thumbFrame.minY, atBottom.thumbFrame.minY)
        XCTAssertLessThan(midway.thumbFrame.minY, atTop.thumbFrame.minY)
        XCTAssertEqual(atBottom.thumbFrame.height, atTop.thumbFrame.height, accuracy: 0.001)
    }

    func testThumbStaysInsideTheTrackAtTheTrailingEdge() throws {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        let metrics = try XCTUnwrap(TerminalScrollIndicatorMetrics.metrics(
            in: bounds,
            visibleRows: 24,
            maxScrollbackOffset: 500,
            scrollbackOffset: 120
        ))

        XCTAssertEqual(metrics.trackFrame.maxX, bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(metrics.trackFrame.width, DesignTokens.Component.terminalScrollerWidthPX)
        XCTAssertTrue(metrics.trackFrame.contains(metrics.thumbFrame))
        XCTAssertEqual(metrics.thumbFrame.width, DesignTokens.Component.terminalScrollerThumbWidthPX)
        XCTAssertEqual(metrics.thumbFrame.midX, metrics.trackFrame.midX, accuracy: 0.001)
    }

    /// A proportional thumb over a deep scrollback is a one-pixel sliver, which
    /// is a position readout nobody can grab.
    func testThumbNeverShrinksBelowTheMinimumGrabbableHeight() throws {
        let metrics = try XCTUnwrap(TerminalScrollIndicatorMetrics.metrics(
            in: NSRect(x: 0, y: 0, width: 400, height: 900),
            visibleRows: 24,
            maxScrollbackOffset: 100_000,
            scrollbackOffset: 50_000
        ))

        XCTAssertGreaterThanOrEqual(
            metrics.thumbFrame.height,
            DesignTokens.Component.terminalScrollerMinThumbHeightPX
        )
    }

    // MARK: - Auto-hide

    func testIndicatorIsOffScreenWhenThereIsNothingToScroll() {
        let coordinator = makeCoordinator()
        coordinator.install(in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))

        coordinator.update(
            bounds: NSRect(x: 0, y: 0, width: 400, height: 300),
            visibleRows: 24,
            maxScrollbackOffset: 0,
            scrollbackOffset: 0
        )

        XCTAssertFalse(coordinator.isIndicatorVisibleForTesting)
    }

    func testIndicatorAppearsOnScrollAndFadesAwayOnceIdle() {
        let coordinator = makeCoordinator()
        coordinator.install(in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))

        coordinator.update(
            bounds: NSRect(x: 0, y: 0, width: 400, height: 300),
            visibleRows: 24,
            maxScrollbackOffset: 500,
            scrollbackOffset: 100
        )
        XCTAssertTrue(coordinator.isIndicatorVisibleForTesting)

        waitUntil(
            { !coordinator.isIndicatorVisibleForTesting },
            "indicator never faded out; it would sit on top of terminal output forever"
        )
    }

    func testIndicatorComesBackWhenScrollingResumes() {
        let coordinator = makeCoordinator()
        coordinator.install(in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        coordinator.update(bounds: bounds, visibleRows: 24, maxScrollbackOffset: 500, scrollbackOffset: 100)
        waitUntil({ !coordinator.isIndicatorVisibleForTesting }, "indicator never faded out")

        coordinator.update(bounds: bounds, visibleRows: 24, maxScrollbackOffset: 500, scrollbackOffset: 220)
        XCTAssertTrue(coordinator.isIndicatorVisibleForTesting)
    }

    /// Following live output reshapes the thumb on every frame while the user's
    /// position stays pinned to the bottom. Treating that as a scroll would make
    /// the indicator strobe through any long build log.
    func testGrowingScrollbackWhileFollowingOutputDoesNotReRevealTheIndicator() {
        let coordinator = makeCoordinator()
        coordinator.install(in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        coordinator.update(bounds: bounds, visibleRows: 24, maxScrollbackOffset: 500, scrollbackOffset: 0)
        waitUntil({ !coordinator.isIndicatorVisibleForTesting }, "indicator never faded out")

        for appended in stride(from: 600, through: 1_200, by: 200) {
            coordinator.update(
                bounds: bounds,
                visibleRows: 24,
                maxScrollbackOffset: appended,
                scrollbackOffset: 0
            )
            XCTAssertFalse(coordinator.isIndicatorVisibleForTesting)
        }
    }

    func testIndicatorStaysUpWhileThePointerHoldsIt() {
        let coordinator = makeCoordinator()
        coordinator.install(in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        coordinator.update(bounds: bounds, visibleRows: 24, maxScrollbackOffset: 500, scrollbackOffset: 100)
        coordinator.thumbViewForTesting.setHoveringForTesting(true)

        let deadline = Date().addingTimeInterval(testIdleFadeDelaySeconds * 20)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(coordinator.isIndicatorVisibleForTesting)

        coordinator.thumbViewForTesting.setHoveringForTesting(false)
        waitUntil(
            { !coordinator.isIndicatorVisibleForTesting },
            "indicator never faded out after the pointer left"
        )
    }

    // MARK: - Chrome consistency

    /// A fixed gray thumb measured about 1.4:1 on a light terminal canvas.
    func testThumbFillFollowsTheActiveChromeTheme() {
        let dark = makeCoordinator(theme: .dark).thumbViewForTesting
        let light = makeCoordinator(theme: .light).thumbViewForTesting

        XCTAssertNotNil(dark.fillColorForTesting)
        XCTAssertNotEqual(dark.fillColorForTesting, light.fillColorForTesting)
        XCTAssertEqual(dark.fillColorForTesting, DesignTokens.ChromeTheme.dark.scrollerThumb.cgColor)
        XCTAssertEqual(light.fillColorForTesting, DesignTokens.ChromeTheme.light.scrollerThumb.cgColor)
    }

    func testThumbFillRespondsToHoverAndDrag() {
        let thumb = makeCoordinator(theme: .light).thumbViewForTesting

        thumb.setHoveringForTesting(true)
        XCTAssertEqual(thumb.fillColorForTesting, DesignTokens.ChromeTheme.light.scrollerThumbHover.cgColor)

        thumb.setDraggingForTesting(true)
        XCTAssertEqual(thumb.fillColorForTesting, DesignTokens.ChromeTheme.light.scrollerThumbActive.cgColor)

        thumb.setDraggingForTesting(false)
        thumb.setHoveringForTesting(false)
        XCTAssertEqual(thumb.fillColorForTesting, DesignTokens.ChromeTheme.light.scrollerThumb.cgColor)
    }

    func testThumbRethemesWhenTheChromeThemeChanges() {
        let coordinator = makeCoordinator(theme: .dark)

        coordinator.setChromeTheme(.light)

        XCTAssertEqual(
            coordinator.thumbViewForTesting.fillColorForTesting,
            DesignTokens.ChromeTheme.light.scrollerThumb.cgColor
        )
    }

    /// The pointing hand means "web link" on macOS; `ChromeIconButton` already
    /// refuses it for the same reason.
    func testThumbUsesTheArrowCursorLikeEveryOtherChromeControl() {
        XCTAssertEqual(makeCoordinator().thumbViewForTesting.indicatorCursor, NSCursor.arrow)
        XCTAssertNotEqual(makeCoordinator().thumbViewForTesting.indicatorCursor, NSCursor.pointingHand)
    }

    /// Every other chrome control snaps between states. Without this the thumb's
    /// hover fill crossfades and its layout moves glide, both of which read as
    /// lag next to the rest of the window.
    func testThumbLayerHasImplicitAnimationsDisabled() throws {
        let layer = try XCTUnwrap(makeCoordinator().thumbViewForTesting.layer)

        for animatedProperty in ["backgroundColor", "position", "bounds"] {
            XCTAssertTrue(
                layer.actions?[animatedProperty] is NSNull,
                "\(animatedProperty) still animates implicitly"
            )
        }
    }
}
