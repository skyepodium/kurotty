import AppKit
import KurottyCore
import QuartzCore
import XCTest

@testable import KurottyApp

/// The ground under the terminal pane cards, and the one rule that makes a
/// graded ground possible at all: exactly one view draws it.
///
/// The failure this guards against is not "the gradient is missing" — it is
/// "the gradient is drawn four times". Each split view and each pane card also
/// paints ground, and if any of them keeps a flat fill under a graded theme it
/// covers the grade in its own gutters; if any of them installs its own
/// gradient layer, the grade restarts at that view's top edge and a split shows
/// stacked bands instead of one surface.
@MainActor
final class ChromeGroundGradientTests: XCTestCase {
    private func gradientLayer(in view: NSView) -> CAGradientLayer? {
        view.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
    }

    private func hostView() -> ChromeGroundHostView {
        let view = ChromeGroundHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.wantsLayer = true
        return view
    }

    // MARK: - Which themes are graded

    func testOnlyNacreDeclaresAGroundGradient() {
        XCTAssertNil(DesignTokens.ChromeTheme.dark.groundGradient)
        XCTAssertNil(DesignTokens.ChromeTheme.light.groundGradient)
        XCTAssertNotNil(DesignTokens.ChromeTheme.nacre.groundGradient)
    }

    // MARK: - The host

    func testAGradedThemeInstallsExactlyOneGradientLayerOnTheHost() throws {
        let host = hostView()
        ChromeGroundGradient.apply(.nacre, to: host)

        let gradient = try XCTUnwrap(gradientLayer(in: host))
        XCTAssertEqual(host.layer?.sublayers?.count, 1)
        let colors = try XCTUnwrap(gradient.colors as? [CGColor])
        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(colors[0], DesignTokens.ChromeTheme.nacre.groundGradient?.top.cgColor)
        XCTAssertEqual(colors[1], DesignTokens.ChromeTheme.nacre.groundGradient?.bottom.cgColor)
    }

    /// The grade has to start at the top of the window on both kinds of view.
    ///
    /// This shipped inverted once. A gradient layer's unit y runs bottom-up on
    /// an unflipped view and top-down on a flipped one, so a fixed
    /// `startPoint` is right for exactly one of them — and the ground host is
    /// the unflipped kind, which put the darkest end of the grade against the
    /// tab bar, the one edge the two stops were chosen to make seamless.
    func testTheGradeStartsAtTheTopOfTheWindowWhicheverWayTheHostIsFlipped() throws {
        for host in [hostView(), FlippedGradientHost(frame: NSRect(x: 0, y: 0, width: 400, height: 300))] {
            host.wantsLayer = true
            ChromeGroundGradient.apply(.nacre, to: host)
            let gradient = try XCTUnwrap(gradientLayer(in: host))
            // In layer unit space, y = 0 is the geometric bottom on an
            // unflipped view and the geometric top on a flipped one.
            let expectedStartY: CGFloat = host.isFlipped ? 0 : 1
            XCTAssertEqual(
                gradient.startPoint,
                CGPoint(x: 0.5, y: expectedStartY),
                "isFlipped=\(host.isFlipped) started the grade at the wrong edge"
            )
            XCTAssertEqual(gradient.endPoint, CGPoint(x: 0.5, y: 1 - expectedStartY))
            XCTAssertEqual(gradient.startPoint.x, gradient.endPoint.x, "the grade is vertical, not diagonal")
        }
    }

    /// Re-applying is what happens on every theme change and every UI-scale
    /// broadcast, so it has to replace rather than stack.
    func testReapplyingAGradedThemeDoesNotStackGradientLayers() {
        let host = hostView()
        ChromeGroundGradient.apply(.nacre, to: host)
        ChromeGroundGradient.apply(.nacre, to: host)
        ChromeGroundGradient.apply(.nacre, to: host)

        XCTAssertEqual(host.layer?.sublayers?.count, 1)
    }

    /// Switching away from the graded theme has to take the gradient with it,
    /// or the dark chrome keeps a pale wash behind its panes.
    func testSwitchingToAFlatThemeRemovesTheGradientAndRestoresTheGroundFill() throws {
        let host = hostView()
        ChromeGroundGradient.apply(.nacre, to: host)
        XCTAssertNotNil(gradientLayer(in: host))

        ChromeGroundGradient.apply(.dark, to: host)
        XCTAssertNil(gradientLayer(in: host))
        XCTAssertEqual(
            host.layer?.backgroundColor,
            DesignTokens.ChromeTheme.dark.terminalPaneGround.cgColor
        )
    }

    func testAFlatThemePaintsTheGroundAsABackingColorWithNoSublayer() {
        let host = hostView()
        ChromeGroundGradient.apply(.light, to: host)

        XCTAssertNil(gradientLayer(in: host))
        XCTAssertEqual(
            host.layer?.backgroundColor,
            DesignTokens.ChromeTheme.light.terminalPaneGround.cgColor
        )
    }

    /// A `CAGradientLayer` sublayer does not follow its parent's bounds the way
    /// a backing color does, so the host re-frames it from `layout`. Without
    /// this the grade is stretched or clipped after any window resize.
    func testTheGradientFollowsTheHostBoundsThroughLayout() throws {
        let host = hostView()
        ChromeGroundGradient.apply(.nacre, to: host)
        host.setFrameSize(NSSize(width: 900, height: 640))
        host.layoutSubtreeIfNeeded()

        let gradient = try XCTUnwrap(gradientLayer(in: host))
        XCTAssertEqual(gradient.frame, host.bounds)
    }

    // MARK: - The descendants

    /// The rule the whole design rests on: under a graded theme every other
    /// ground-painting view goes transparent so the host's single grade shows
    /// through the gutters and the card corner cutouts.
    func testDescendantsPaintNothingUnderAGradedThemeAndTheGroundOtherwise() {
        XCTAssertEqual(ChromeGroundGradient.descendantFill(.nacre), .clear)
        XCTAssertEqual(
            ChromeGroundGradient.descendantFill(.dark),
            DesignTokens.ChromeTheme.dark.terminalPaneGround
        )
        XCTAssertEqual(
            ChromeGroundGradient.descendantFill(.light),
            DesignTokens.ChromeTheme.light.terminalPaneGround
        )
    }

    func testASplitViewLeavesItsGroundToTheHostUnderAGradedTheme() throws {
        let split = SplitTerminalView(
            axis: .horizontal,
            pane: nil,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )

        split.applyChromeTheme(.nacre)
        let graded = try XCTUnwrap(split.layer?.backgroundColor)
        XCTAssertEqual(graded.alpha, 0, "a graded ground must not be restated inside the gutters")

        split.applyChromeTheme(.light)
        XCTAssertEqual(
            split.layer?.backgroundColor,
            DesignTokens.ChromeTheme.light.terminalPaneGround.cgColor
        )
    }

    /// The pane card is masked to a rounded rect, so its own layer color is
    /// what shows in the four corner cutouts. Under a graded theme those
    /// cutouts have to show the grade, not a flat patch of it.
    func testAPaneCardLeavesItsCornerCutoutsToTheHostUnderAGradedTheme() throws {
        let pane = TerminalPaneView(frame: .zero, session: GradientStubSession())

        pane.applyChromeTheme(.nacre)
        let graded = try XCTUnwrap(pane.layer?.backgroundColor)
        XCTAssertEqual(graded.alpha, 0)

        pane.applyChromeTheme(.dark)
        XCTAssertEqual(
            pane.layer?.backgroundColor,
            DesignTokens.ChromeTheme.dark.terminalPaneGround.cgColor
        )
    }
}

/// A flipped ground host, which the window does not currently use. It is here
/// because the unit-point rule depends on flippedness and nothing else in the
/// suite would notice if the flipped branch stopped being correct.
private final class FlippedGradientHost: NSView {
    override var isFlipped: Bool { true }
}

private final class GradientStubSession: TerminalSession {
    var onOutput: ((String) -> Void)?
    var onRawOutput: ((Data) -> Void)?
    var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
    var onExit: ((TerminalChildExit) -> Void)?

    func start(workingDirectory: String) {}
    func write(_ text: String) {}
    func foregroundProcessName() -> String? { nil }
    func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
    func resize(columns: Int, rows: Int) {}
    func stop() {}
}
