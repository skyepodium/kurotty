import AppKit
import CoreGraphics
@testable import KurottyApp
@testable import KurottyCore
import Metal
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

    func testDrawPassPlanUsesScissorOnlyWhenEverySafetyConditionHolds() {
        let plan = TerminalDrawPassPlan.make(
            cpuFallbackActive: false,
            atlasPathReady: true,
            offscreenTextureAvailable: true,
            pendingFullRedrawRequired: false,
            offscreenContentIsValid: true,
            scissorRectsFitDrawable: true,
            cursorDamageIsCovered: true
        )

        XCTAssertTrue(plan.usesScissor)
        XCTAssertEqual(plan.fullRedrawReason, .none)
        XCTAssertEqual(plan.fullRedrawReason.description, "none")
    }

    func testDrawPassPlanFallsBackToFullRedrawForEveryUnsafeCondition() {
        let unsafeConditions: [(TerminalDrawPassPlan, TerminalDrawPassFullRedrawReason, String)] = [
            (
                TerminalDrawPassPlan.make(
                    cpuFallbackActive: true,
                    atlasPathReady: true,
                    offscreenTextureAvailable: true,
                    pendingFullRedrawRequired: false,
                    offscreenContentIsValid: true,
                    scissorRectsFitDrawable: true,
                    cursorDamageIsCovered: true
                ),
                .cpuFallbackActive,
                "cpu-fallback-active"
            ),
            (
                TerminalDrawPassPlan.make(
                    cpuFallbackActive: false,
                    atlasPathReady: false,
                    offscreenTextureAvailable: true,
                    pendingFullRedrawRequired: false,
                    offscreenContentIsValid: true,
                    scissorRectsFitDrawable: true,
                    cursorDamageIsCovered: true
                ),
                .atlasPathNotReady,
                "atlas-path-not-ready"
            ),
            (
                TerminalDrawPassPlan.make(
                    cpuFallbackActive: false,
                    atlasPathReady: true,
                    offscreenTextureAvailable: false,
                    pendingFullRedrawRequired: false,
                    offscreenContentIsValid: true,
                    scissorRectsFitDrawable: true,
                    cursorDamageIsCovered: true
                ),
                .offscreenTextureUnavailable,
                "offscreen-texture-unavailable"
            ),
            (
                TerminalDrawPassPlan.make(
                    cpuFallbackActive: false,
                    atlasPathReady: true,
                    offscreenTextureAvailable: true,
                    pendingFullRedrawRequired: true,
                    offscreenContentIsValid: true,
                    scissorRectsFitDrawable: true,
                    cursorDamageIsCovered: true
                ),
                .pendingFullRedraw,
                "pending-full-redraw"
            ),
            (
                TerminalDrawPassPlan.make(
                    cpuFallbackActive: false,
                    atlasPathReady: true,
                    offscreenTextureAvailable: true,
                    pendingFullRedrawRequired: false,
                    offscreenContentIsValid: false,
                    scissorRectsFitDrawable: true,
                    cursorDamageIsCovered: true
                ),
                .offscreenContentInvalid,
                "offscreen-content-invalid"
            ),
            (
                TerminalDrawPassPlan.make(
                    cpuFallbackActive: false,
                    atlasPathReady: true,
                    offscreenTextureAvailable: true,
                    pendingFullRedrawRequired: false,
                    offscreenContentIsValid: true,
                    scissorRectsFitDrawable: false,
                    cursorDamageIsCovered: true
                ),
                .scissorRectOutsideDrawable,
                "scissor-rect-outside-drawable"
            ),
            (
                TerminalDrawPassPlan.make(
                    cpuFallbackActive: false,
                    atlasPathReady: true,
                    offscreenTextureAvailable: true,
                    pendingFullRedrawRequired: false,
                    offscreenContentIsValid: true,
                    scissorRectsFitDrawable: true,
                    cursorDamageIsCovered: false
                ),
                .cursorDamageNotCovered,
                "cursor-damage-not-covered"
            ),
        ]

        for (plan, expectedReason, expectedDescription) in unsafeConditions {
            XCTAssertFalse(plan.usesScissor)
            XCTAssertEqual(plan.fullRedrawReason, expectedReason)
            XCTAssertEqual(plan.fullRedrawReason.description, expectedDescription)
        }
    }

    func testMetalScissorRectConversionFlipsBottomUpDamageIntoTopLeftOrigin() {
        let bottomUpRect = TerminalRenderScissorRect(x: 10, y: 40, width: 30, height: 20)
        let converted = TerminalMetalView.metalScissorRect(
            from: bottomUpRect,
            drawableWidthPixels: 100,
            drawableHeightPixels: 100
        )

        XCTAssertEqual(converted?.x, 10)
        XCTAssertEqual(converted?.y, 40)
        XCTAssertEqual(converted?.width, 30)
        XCTAssertEqual(converted?.height, 20)

        let bottomEdgeRect = TerminalRenderScissorRect(x: 0, y: 0, width: 100, height: 10)
        let bottomEdgeConverted = TerminalMetalView.metalScissorRect(
            from: bottomEdgeRect,
            drawableWidthPixels: 100,
            drawableHeightPixels: 100
        )
        XCTAssertEqual(bottomEdgeConverted?.y, 90)
    }

    func testMetalScissorRectConversionRejectsRectsOutsideTheDrawable() {
        let overflowingRects = [
            TerminalRenderScissorRect(x: -1, y: 0, width: 10, height: 10),
            TerminalRenderScissorRect(x: 0, y: -1, width: 10, height: 10),
            TerminalRenderScissorRect(x: 95, y: 0, width: 10, height: 10),
            TerminalRenderScissorRect(x: 0, y: 95, width: 10, height: 10),
            TerminalRenderScissorRect(x: 0, y: 0, width: 0, height: 10),
            TerminalRenderScissorRect(x: 0, y: 0, width: 10, height: 0),
        ]

        for rect in overflowingRects {
            XCTAssertNil(
                TerminalMetalView.metalScissorRect(
                    from: rect,
                    drawableWidthPixels: 100,
                    drawableHeightPixels: 100
                ),
                "rect \(rect) must be rejected so a mismatched plan forces a full redraw"
            )
        }
    }

    func testScissorRectContainmentGuardsCursorDamageCoverage() {
        let rowBand = TerminalRenderScissorRect(x: 0, y: 40, width: 80, height: 40)

        XCTAssertTrue(rowBand.contains(rowBand))
        XCTAssertTrue(rowBand.contains(TerminalRenderScissorRect(x: 10, y: 50, width: 20, height: 10)))
        XCTAssertFalse(rowBand.contains(TerminalRenderScissorRect(x: 10, y: 30, width: 20, height: 20)))
        XCTAssertFalse(rowBand.contains(TerminalRenderScissorRect(x: 70, y: 40, width: 20, height: 40)))
    }

    @MainActor
    func testMetalViewExposesAppliedDrawPassDiagnosticsWithSafeDefaults() {
        let view = TerminalMetalView(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))

        XCTAssertFalse(view.lastDrawUsedScissorForDiagnostics)
        XCTAssertEqual(view.lastDrawScissorRectCountForDiagnostics, 0)
        XCTAssertEqual(view.lastDrawEncodePathForDiagnostics, "none")
        XCTAssertEqual(view.lastDrawFullRedrawReasonForDiagnostics, "none")
    }

    func testDrawAppliesScissorPlanThroughPersistentOffscreenContentTexture() throws {
        let source = try metalViewSourceForDamageDiagnostics()

        XCTAssertTrue(source.contains("encoder.setScissorRect(scissorRect)"))
        XCTAssertTrue(source.contains("private func encodeDamageRegionTerminalContent("))
        XCTAssertTrue(source.contains("private func encodeDamageRegionBackdropFill(using encoder: MTLRenderCommandEncoder)"))
        XCTAssertTrue(source.contains("colorAttachment?.loadAction = plan.usesScissor ? .load : .clear"))
        XCTAssertTrue(source.contains("descriptor.usage = [.renderTarget, .shaderRead]"))
        XCTAssertTrue(source.contains("private var offscreenContentTexture: MTLTexture?"))
        XCTAssertTrue(source.contains("private var offscreenContentIsValid = false"))
        XCTAssertTrue(source.contains("private var pendingRequiresFullRedraw = true"))
        XCTAssertTrue(source.contains("private func invalidateOffscreenContent()"))
        XCTAssertTrue(source.contains("private func cursorDamageIsCoveredByPendingScissorRects() -> Bool"))
        XCTAssertTrue(source.contains("let topOriginY = drawableHeightPixels - (rect.y + rect.height)"))
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

private func metalViewSourceForDamageDiagnostics() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalMetalView.swift")
    return try String(contentsOf: path, encoding: .utf8)
}
