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
        XCTAssertEqual(diagnostics.scissorReadiness.description, "full-redraw-fallback")
        XCTAssertFalse(diagnostics.scissorPlanIsReady)
        XCTAssertEqual(diagnostics.scissorRectCount, 0)
        XCTAssertEqual(diagnostics.scissorRects, [])
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
        XCTAssertEqual(diagnostics.scissorReadiness.description, "ready")
        XCTAssertTrue(diagnostics.scissorPlanIsReady)
        XCTAssertEqual(diagnostics.scissorRectCount, 1)
        XCTAssertEqual(diagnostics.scissorRects, [TerminalRenderScissorRect(x: 0, y: 40, width: 80, height: 40)])
    }

    func testDisplayCadenceCandidateCoalescesTouchingDirtyRectsBeforeScheduling() {
        let diagnostics = TerminalRenderDamageDiagnostics.make(
            frame: makeFrame(
                dirtyRects: [
                    TerminalFrameRect(x: 0, y: 20, width: 20, height: 20),
                    TerminalFrameRect(x: 20, y: 20, width: 20, height: 20),
                ],
                isFullDamage: false
            ),
            bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
            backingScale: 2,
            diagnosticFullRedrawEnabled: false,
            scissorDisabled: false
        )

        XCTAssertEqual(diagnostics.redrawDecision.description, "partial")
        XCTAssertEqual(diagnostics.schedulingPolicy.description, "display-cadence-coalescing-candidate")
        XCTAssertEqual(diagnostics.uncoalescedSubmittedDisplayRectCount, 2)
        XCTAssertEqual(diagnostics.scheduledDisplayRectCount, 1)
        XCTAssertEqual(diagnostics.coalescedDisplayRectCount, 1)
        XCTAssertEqual(diagnostics.submittedDisplayRects, [CGRect(x: 0, y: 20, width: 40, height: 20)])
        XCTAssertTrue(diagnostics.canCoalesceAtDisplayCadence)
        XCTAssertEqual(diagnostics.scissorReadiness.description, "ready")
        XCTAssertEqual(diagnostics.scissorRects, [
            TerminalRenderScissorRect(x: 0, y: 40, width: 40, height: 40),
            TerminalRenderScissorRect(x: 40, y: 40, width: 40, height: 40),
        ])
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
        XCTAssertEqual(diagnostics.scissorReadiness.description, "unstable-pixel-bounds")
        XCTAssertFalse(diagnostics.scissorPlanIsReady)
        XCTAssertEqual(diagnostics.scissorRects, [])
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
        XCTAssertEqual(diagnostics.scissorReadiness.description, "scissor-disabled")
        XCTAssertFalse(diagnostics.scissorPlanIsReady)
        XCTAssertEqual(diagnostics.scissorRects, [])
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
        XCTAssertEqual(diagnostics.scissorReadiness.description, "full-redraw-fallback")
        XCTAssertFalse(diagnostics.scissorPlanIsReady)
        XCTAssertEqual(diagnostics.scissorRects, [])
    }

    func testScissorPlanClipsStablePixelBoundsToDrawablePixels() {
        let diagnostics = TerminalRenderDamageDiagnostics.make(
            frame: makeFrame(
                dirtyRects: [TerminalFrameRect(x: 30, y: 10, width: 20, height: 20)],
                isFullDamage: false
            ),
            bounds: CGRect(x: 0, y: 0, width: 40, height: 20),
            backingScale: 2,
            diagnosticFullRedrawEnabled: false,
            scissorDisabled: false
        )

        XCTAssertEqual(diagnostics.scissorReadiness.description, "ready")
        XCTAssertEqual(diagnostics.scissorRects, [TerminalRenderScissorRect(x: 60, y: 20, width: 20, height: 20)])
        XCTAssertEqual(diagnostics.scissorRectCount, 1)
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
