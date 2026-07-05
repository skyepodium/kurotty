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

    func testProductionDamageDiagnosticsExposeSubmittedAreaAndFallbackMetadata() {
        let partial = TerminalRenderDamageDiagnostics.make(
            frame: makeFrame(dirtyRects: [rowRect(1)], isFullDamage: false),
            bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
            backingScale: 2,
            diagnosticFullRedrawEnabled: false,
            scissorDisabled: false
        )
        let fallback = TerminalRenderDamageDiagnostics.make(
            frame: makeFrame(dirtyRects: [rowRect(1)], isFullDamage: true),
            bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
            backingScale: 2,
            diagnosticFullRedrawEnabled: false,
            scissorDisabled: false
        )

        XCTAssertEqual(partial.submittedDisplayArea, 800)
        XCTAssertEqual(partial.fullDisplayArea, 3_200)
        XCTAssertEqual(partial.submittedDisplayAreaRatio, 0.25)
        XCTAssertFalse(partial.usedFullRedrawFallback)
        XCTAssertEqual(partial.debugMetadataSummary, "decision=partial policy=display-cadence-coalescing-candidate fallback=none dirtyRects=1 submittedRects=1 submittedArea=800.00/3200.00 ratio=0.2500 stablePixelBounds=1 scissorDisabled=false")

        XCTAssertEqual(fallback.submittedDisplayArea, 3_200)
        XCTAssertEqual(fallback.submittedDisplayAreaRatio, 1)
        XCTAssertTrue(fallback.usedFullRedrawFallback)
        XCTAssertTrue(fallback.debugMetadataSummary.contains("fallback=full-damage-frame"))
        XCTAssertTrue(fallback.debugMetadataSummary.contains("ratio=1.0000"))
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
