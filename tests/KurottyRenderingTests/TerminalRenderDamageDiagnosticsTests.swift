import CoreGraphics
@testable import KurottyApp
@testable import KurottyCore
import XCTest

final class TerminalRenderDamageDiagnosticsTests: XCTestCase {
    func testFullDamageUsesFallbackAndKeepsCoalescingDisabled() {
        let diagnostics = TerminalRenderDamageDiagnostics.make(
            frame: makeFrame(dirtyRects: [rowRect(0)], isFullDamage: true),
            bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
            backingScale: 2,
            diagnosticFullRedrawEnabled: false,
            scissorDisabled: false
        )

        XCTAssertEqual(diagnostics.redrawDecision.description, "full")
        XCTAssertEqual(diagnostics.schedulingPolicy.description, "full-redraw-fallback")
        XCTAssertEqual(diagnostics.coalescingFallbackReason.description, "full-damage-frame")
        XCTAssertFalse(diagnostics.canCoalesceAtDisplayCadence)
        XCTAssertEqual(diagnostics.submittedDisplayRects, [CGRect(x: 0, y: 0, width: 80, height: 40)])
        XCTAssertEqual(diagnostics.stablePixelBounds, [])
        XCTAssertEqual(diagnostics.stablePixelBoundCount, 0)
    }

    func testPartialDamageCanBeMarkedAsDisplayCadenceCoalescingCandidateWhenPixelBoundsAreStable() {
        let diagnostics = TerminalRenderDamageDiagnostics.make(
            frame: makeFrame(dirtyRects: [rowRect(1)], isFullDamage: false),
            bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
            backingScale: 2,
            diagnosticFullRedrawEnabled: false,
            scissorDisabled: false
        )

        XCTAssertEqual(diagnostics.redrawDecision.description, "partial")
        XCTAssertEqual(diagnostics.schedulingPolicy.description, "display-cadence-coalescing-candidate")
        XCTAssertEqual(diagnostics.coalescingFallbackReason.description, "none")
        XCTAssertTrue(diagnostics.canCoalesceAtDisplayCadence)
        XCTAssertEqual(diagnostics.submittedDisplayRects, [CGRect(x: 0, y: 20, width: 40, height: 20)])
        XCTAssertEqual(diagnostics.stablePixelBounds, [TerminalFramePixelRect(x: 0, y: 40, width: 80, height: 40)])
        XCTAssertEqual(diagnostics.stablePixelBoundCount, 1)
    }

    func testPartialDamageFallsBackToImmediatePolicyWhenPixelBoundsAreUnstable() {
        let diagnostics = TerminalRenderDamageDiagnostics.make(
            frame: makeFrame(
                dirtyRects: [TerminalFrameRect(x: 0, y: 0, width: 0, height: 20)],
                isFullDamage: false
            ),
            bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
            backingScale: 2,
            diagnosticFullRedrawEnabled: false,
            scissorDisabled: false
        )

        XCTAssertEqual(diagnostics.redrawDecision.description, "partial")
        XCTAssertEqual(diagnostics.schedulingPolicy.description, "immediate-partial-redraw")
        XCTAssertEqual(diagnostics.coalescingFallbackReason.description, "unstable-pixel-bounds")
        XCTAssertFalse(diagnostics.canCoalesceAtDisplayCadence)
        XCTAssertEqual(diagnostics.stablePixelBounds, [])
        XCTAssertEqual(diagnostics.stablePixelBoundCount, 0)
    }

    func testPartialDamageReportsScissorDisabledAsCoalescingFallbackReason() {
        let diagnostics = TerminalRenderDamageDiagnostics.make(
            frame: makeFrame(dirtyRects: [rowRect(1)], isFullDamage: false),
            bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
            backingScale: 2,
            diagnosticFullRedrawEnabled: false,
            scissorDisabled: true
        )

        XCTAssertEqual(diagnostics.redrawDecision.description, "partial")
        XCTAssertEqual(diagnostics.schedulingPolicy.description, "immediate-partial-redraw")
        XCTAssertEqual(diagnostics.coalescingFallbackReason.description, "scissor-disabled")
        XCTAssertFalse(diagnostics.canCoalesceAtDisplayCadence)
        XCTAssertEqual(diagnostics.stablePixelBounds, [TerminalFramePixelRect(x: 0, y: 40, width: 80, height: 40)])
        XCTAssertEqual(diagnostics.stablePixelBoundCount, 1)
    }

    func testDiagnosticFullRedrawReportsForcedFallbackWithoutEnablingPartialRepaint() {
        let diagnostics = TerminalRenderDamageDiagnostics.make(
            frame: makeFrame(dirtyRects: [rowRect(1)], isFullDamage: false),
            bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
            backingScale: 2,
            diagnosticFullRedrawEnabled: true,
            scissorDisabled: false
        )

        XCTAssertEqual(diagnostics.redrawDecision.description, "full")
        XCTAssertEqual(diagnostics.schedulingPolicy.description, "full-redraw-fallback")
        XCTAssertEqual(diagnostics.coalescingFallbackReason.description, "diagnostic-full-redraw")
        XCTAssertFalse(diagnostics.canCoalesceAtDisplayCadence)
        XCTAssertEqual(diagnostics.submittedDisplayRects, [CGRect(x: 0, y: 0, width: 80, height: 40)])
        XCTAssertEqual(diagnostics.stablePixelBounds, [])
        XCTAssertEqual(diagnostics.stablePixelBoundCount, 0)
    }

    private func makeFrame(
        dirtyRects: [TerminalFrameRect],
        isFullDamage: Bool
    ) -> TerminalFrame {
        TerminalFrame(
            cells: [],
            backgrounds: [],
            decorations: [],
            defaultForeground: .zero,
            defaultBackground: .zero,
            dirtyRows: dirtyRects.isEmpty ? [] : [0],
            dirtyRects: dirtyRects,
            isFullDamage: isFullDamage,
            cursorColumn: 0,
            cursorRow: 0,
            cursorBlinkOn: true,
            markedTextColumn: 0,
            markedText: "",
            markedTextSelectedRange: .none,
            columns: 4,
            visibleRows: 2,
            cellSize: TerminalFrameSize(width: 10, height: 20),
            padding: .zero
        )
    }

    private func rowRect(_ row: Int) -> TerminalFrameRect {
        TerminalFrameRect(x: 0, y: Double(row * 20), width: 40, height: 20)
    }
}
