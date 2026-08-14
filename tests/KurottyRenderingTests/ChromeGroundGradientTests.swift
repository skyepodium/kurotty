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

    /// Every ramp carries its own ground now, and each one meets the tab bar
    /// at its own chrome plane. That base is not decoration: it is the colour
    /// the top edge of the ground shows, so a base that is not `surfaceChrome`
    /// puts a seam under the tabs.
    func testEveryRampGroundsItselfOnItsOwnChromePlane() {
        for (name, theme) in [
            ("dark", DesignTokens.ChromeTheme.dark),
            ("light", DesignTokens.ChromeTheme.light),
            ("nacre", DesignTokens.ChromeTheme.nacre),
        ] {
            XCTAssertEqual(
                theme.groundMesh.base, theme.surfaceChrome,
                "\(name) must meet the tab bar at its chrome plane"
            )
            XCTAssertFalse(theme.groundMesh.tints.isEmpty, "\(name) declares no tints")
        }
    }

    // MARK: - The host

    /// One layer per tint, and each one fades to nothing at its own edge.
    ///
    /// The fade is the mechanism rather than a nicety: an opaque outer stop
    /// would draw a disc with a rim, and three discs are not a pearlescent
    /// field. The outer stop is therefore the same colour at zero alpha.
    func testAMeshInstallsOneFadingLayerPerTint() throws {
        let host = hostView()
        let mesh = DesignTokens.ChromeTheme.nacre.groundMesh
        ChromeGroundGradient.apply(.nacre, to: host)

        XCTAssertEqual(host.layer?.sublayers?.count, mesh.tints.count)
        XCTAssertEqual(host.layer?.backgroundColor, mesh.base.cgColor)

        for (index, tint) in mesh.tints.enumerated() {
            let layer = try XCTUnwrap(host.layer?.sublayers?[index] as? CAGradientLayer)
            let colors = try XCTUnwrap(layer.colors as? [CGColor])
            XCTAssertEqual(layer.type, .radial)
            XCTAssertEqual(colors.first, tint.color.cgColor)
            XCTAssertEqual(colors.last?.alpha, 0, "a tint that does not fade draws a rim")
        }
    }

    /// A tint lands on the same part of the window on both kinds of view.
    ///
    /// This shipped inverted once, back when the ground was a single grade: a
    /// layer's unit y runs bottom-up on an unflipped view and top-down on a
    /// flipped one, so a fixed point is right for exactly one of them. The mesh
    /// has the same hazard three times over — a cool tint meant for the top-left
    /// arrives at the bottom-left instead, and the ground is upside down without
    /// looking obviously broken.
    func testATintLandsOnTheSameCornerWhicheverWayTheHostIsFlipped() throws {
        let mesh = DesignTokens.ChromeTheme.nacre.groundMesh
        let cool = try XCTUnwrap(mesh.tints.first)

        for host in [hostView(), FlippedGradientHost(frame: NSRect(x: 0, y: 0, width: 400, height: 300))] {
            host.wantsLayer = true
            ChromeGroundGradient.apply(.nacre, to: host)
            let tint = try XCTUnwrap(gradientLayer(in: host))

            // The mesh states centres from the top-left, the way the design
            // does. On an unflipped layer that has to be mirrored.
            let expectedY = host.isFlipped ? cool.center.y : 1 - cool.center.y
            XCTAssertEqual(
                tint.startPoint,
                CGPoint(x: cool.center.x, y: expectedY),
                "isFlipped=\(host.isFlipped) put the tint on the wrong edge"
            )
            XCTAssertEqual(
                tint.endPoint,
                CGPoint(x: cool.center.x + cool.radius.width, y: expectedY + cool.radius.height)
            )
        }
    }

    /// Re-applying is what happens on every theme change and every UI-scale
    /// broadcast, so it has to replace rather than stack.
    func testReapplyingAThemeDoesNotStackMeshesBehindEachOther() {
        let host = hostView()
        ChromeGroundGradient.apply(.nacre, to: host)
        ChromeGroundGradient.apply(.nacre, to: host)
        ChromeGroundGradient.apply(.nacre, to: host)

        XCTAssertEqual(
            host.layer?.sublayers?.count,
            DesignTokens.ChromeTheme.nacre.groundMesh.tints.count
        )
    }

    /// Switching themes has to take the previous mesh with it, or the dark
    /// chrome keeps Nacre's pale wash behind its panes.
    func testSwitchingThemesReplacesTheMeshRatherThanLayeringOnIt() throws {
        let host = hostView()
        ChromeGroundGradient.apply(.nacre, to: host)
        ChromeGroundGradient.apply(.dark, to: host)

        let dark = DesignTokens.ChromeTheme.dark.groundMesh
        XCTAssertEqual(host.layer?.sublayers?.count, dark.tints.count)
        XCTAssertEqual(host.layer?.backgroundColor, dark.base.cgColor)

        let first = try XCTUnwrap(host.layer?.sublayers?.first as? CAGradientLayer)
        let colors = try XCTUnwrap(first.colors as? [CGColor])
        XCTAssertEqual(colors.first, dark.tints[0].color.cgColor)
    }

    /// A theme that wants no tint says so with an empty mesh, and the host still
    /// owns the ground. There is no second path for it to take.
    func testAThemeWithNoTintsPaintsItsPlaneAndNothingElse() {
        let host = hostView()
        let flat = DesignTokens.GroundMesh.flat(DesignTokens.Color.Dark.surfaceChrome)
        ChromeGroundGradient.apply(mesh: flat, to: host)

        XCTAssertEqual(host.layer?.sublayers?.count ?? 0, 0)
        XCTAssertEqual(host.layer?.backgroundColor, flat.base.cgColor)
    }

    /// A `CAGradientLayer` sublayer does not follow its parent's bounds the way
    /// a backing color does, so the host re-frames it from `layout`. Without
    /// this the grade is stretched or clipped after any window resize.
    func testEveryTintFollowsTheHostBoundsThroughLayout() throws {
        let host = hostView()
        ChromeGroundGradient.apply(.nacre, to: host)
        host.setFrameSize(NSSize(width: 900, height: 640))
        host.layoutSubtreeIfNeeded()

        let tints = try XCTUnwrap(host.layer?.sublayers?.compactMap { $0 as? CAGradientLayer })
        XCTAssertFalse(tints.isEmpty)
        for tint in tints {
            XCTAssertEqual(tint.frame, host.bounds)
        }
    }

    // MARK: - The descendants

    /// The rule the whole design rests on: every other ground-painting view
    /// goes transparent so the host's single field shows through the gutters
    /// between panes and the slivers the card corners cut out.
    func testDescendantsPaintNoGroundOfTheirOwn() {
        XCTAssertEqual(ChromeGroundGradient.descendantFill, .clear)
    }

    func testASplitViewLeavesItsGroundToTheHost() throws {
        let split = SplitTerminalView(
            axis: .horizontal,
            pane: nil,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )

        for theme in [DesignTokens.ChromeTheme.nacre, .light, .dark] {
            split.applyChromeTheme(theme)
            let fill = try XCTUnwrap(split.layer?.backgroundColor)
            XCTAssertEqual(fill.alpha, 0, "the ground must not be restated inside the gutters")
        }
    }

    /// The pane card is masked to a rounded rect, so its own layer colour is
    /// what shows in the four corner cutouts. Those cutouts have to show the
    /// host's field, not a flat patch of it.
    func testAPaneCardLeavesItsCornerCutoutsToTheHost() throws {
        let pane = TerminalPaneView(frame: .zero, session: GradientStubSession())

        for theme in [DesignTokens.ChromeTheme.nacre, .light, .dark] {
            pane.applyChromeTheme(theme)
            let fill = try XCTUnwrap(pane.layer?.backgroundColor)
            XCTAssertEqual(fill.alpha, 0)
        }
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
