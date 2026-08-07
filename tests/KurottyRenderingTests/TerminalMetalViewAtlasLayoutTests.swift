import AppKit
import Metal
import XCTest
@testable import KurottyCore
@testable import KurottyApp

/// Behavioural cover for the glyph atlas: diagnostics defaults, slot geometry,
/// the half-texel UV inset, and font fallback.
///
/// These replace source-text assertions in `GlyphRenderingRegressionTests` that
/// matched the atlas arithmetic character by character — `"let halfTexel = 0.5 /
/// Float(atlasSize)"` and friends. Every one of them failed on a rename and none
/// would have noticed the inset being applied to the wrong axis. The numbers are
/// reachable through `renderingDiagnostics`, so they are checked as numbers.
@MainActor
final class TerminalMetalViewAtlasLayoutTests: XCTestCase {
    private func makeView() throws -> TerminalMetalView {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is not available")
        }
        return TerminalMetalView(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    // MARK: - Diagnostics surface

    /// The renderer ships with every diagnostic overlay off and the CPU fallback
    /// off; only pixel snapping is on. A default that flipped would put debug
    /// overlays, or the slow text-texture path, in front of users.
    func testDiagnosticTogglesShipInTheirSafeDefaultPositions() throws {
        let view = try makeView()

        XCTAssertFalse(view.diagnosticCPUFallbackEnabled)
        XCTAssertFalse(view.diagnosticLinearGlyphSamplingEnabled)
        XCTAssertFalse(view.diagnosticCellBoundaryOverlayEnabled)
        XCTAssertFalse(view.diagnosticBaselineOverlayEnabled)
        XCTAssertFalse(view.diagnosticGlyphQuadOverlayEnabled)
        XCTAssertFalse(view.diagnosticRenderingLogEnabled)
        XCTAssertFalse(view.diagnosticFullRedrawEnabled)
        XCTAssertTrue(view.diagnosticPixelSnappingEnabled)
    }

    /// The CPU text texture is opt-in: it must not be allocated until the
    /// fallback is asked for, or every session pays for a path nobody renders.
    func testCPUTextTextureIsOnlyAllocatedWhenTheFallbackIsEnabled() throws {
        let view = try makeView()
        // The CPU path rasterizes into a texture the size of the view, so it
        // needs a real bounds before it can allocate anything at all.
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertFalse(view.diagnosticCPUTextureIsAllocated)

        view.diagnosticCPUFallbackEnabled = true

        XCTAssertTrue(view.diagnosticCPUTextureIsAllocated)

        view.diagnosticCPUFallbackEnabled = false
        XCTAssertFalse(view.diagnosticCPUTextureIsAllocated)
    }

    func testRenderingDiagnosticsReportTheAtlasAndToggleState() throws {
        let view = try makeView()
        let diagnostics = view.renderingDiagnostics

        XCTAssertEqual(diagnostics.glyphAtlasSizePixels, DesignTokens.Component.glyphAtlasSizePX)
        XCTAssertGreaterThan(diagnostics.backingScaleFactor, 0)
        XCTAssertTrue(diagnostics.pixelSnappingEnabled)
        XCTAssertFalse(diagnostics.linearGlyphSamplingEnabled)

        view.diagnosticLinearGlyphSamplingEnabled = true
        XCTAssertTrue(view.renderingDiagnostics.linearGlyphSamplingEnabled)
    }

    /// The atlas path only claims to be ready once every resource it draws from
    /// exists. A freshly built view that reports ready would draw from nil.
    func testAtlasPathIsNotReportedReadyBeforeItsResourcesExist() throws {
        let view = try makeView()

        XCTAssertEqual(view.isAtlasPathReadyForRendering, view.atlasResourcesAreAvailableForDiagnostics)
        XCTAssertEqual(view.atlasGlyphInstanceCountForDiagnostics, 0)
    }

    // MARK: - Display synchronization

    /// The drawable and the layer's contents scale have to follow the bounds and
    /// the display, on every path that can change either. Dragging a window to a
    /// non-Retina display used to leave a half-resolution drawable behind.
    func testDrawableAndLayerScaleTrackTheBoundsOnEverySynchronizationPath() throws {
        let view = try makeView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let scale = view.renderingDiagnostics.backingScaleFactor

        for synchronize in [view.layout, view.viewDidChangeBackingProperties, view.viewDidMoveToWindow] {
            synchronize()
            XCTAssertEqual(view.drawableSize.width, ceil(200 * scale), accuracy: 0.5)
            XCTAssertEqual(view.drawableSize.height, ceil(100 * scale), accuracy: 0.5)
            XCTAssertEqual(view.layer?.contentsScale, scale)
        }

        view.frame = NSRect(x: 0, y: 0, width: 320, height: 64)
        view.layout()

        XCTAssertEqual(view.drawableSize.width, ceil(320 * scale), accuracy: 0.5)
        XCTAssertEqual(view.drawableSize.height, ceil(64 * scale), accuracy: 0.5)
    }

    /// sRGB on `bgra8Unorm` with straight alpha is the whole colour policy; a
    /// pixel format change silently shifts every rendered colour.
    func testRenderTargetKeepsItsPixelFormatAndColorSpacePolicy() throws {
        let view = try makeView()

        XCTAssertEqual(view.colorPixelFormat, .bgra8Unorm)
        XCTAssertEqual(view.colorspace, CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: - Slot geometry and UVs

    /// UVs address texel centres, not slot edges. Sampling the edge bleeds the
    /// neighbouring glyph in under linear filtering, which is the classic
    /// "ghost stroke on the left of every character" artefact.
    func testGlyphUVOriginIsInsetByHalfATexelOnBothAxes() throws {
        let view = try makeView()
        XCTAssertTrue(view.cacheGlyphForTesting("A"))

        let diagnostics = view.renderingDiagnostics
        let atlasSize = Float(diagnostics.glyphAtlasSizePixels)
        let halfTexel = 0.5 / atlasSize
        let rect = diagnostics.lastGlyphRectPixels

        XCTAssertEqual(diagnostics.lastGlyphUVOrigin.x, Float(rect.minX) / atlasSize + halfTexel, accuracy: 1e-7)
        XCTAssertEqual(diagnostics.lastGlyphUVOrigin.y, Float(rect.minY) / atlasSize + halfTexel, accuracy: 1e-7)
    }

    /// The UV extent is one texel short of the rasterized size for the same
    /// reason: origin and extent together must stay inside the glyph's texels.
    func testGlyphUVSizeStopsOneTexelShortOfTheRasterizedBitmap() throws {
        let view = try makeView()
        XCTAssertTrue(view.cacheGlyphForTesting("W"))

        let diagnostics = view.renderingDiagnostics
        let atlasSize = Float(diagnostics.glyphAtlasSizePixels)
        let rect = diagnostics.lastGlyphRectPixels

        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertEqual(diagnostics.lastGlyphUVSize.x, Float(rect.width - 1) / atlasSize, accuracy: 1e-7)
        XCTAssertEqual(diagnostics.lastGlyphUVSize.y, Float(rect.height - 1) / atlasSize, accuracy: 1e-7)
    }

    /// Ink is padded inside its slot and never runs into the next one, so a
    /// wide or overshooting glyph cannot smear its neighbour.
    func testRasterizedGlyphStaysInsideItsSlotAndInsideTheAtlas() throws {
        let view = try makeView()

        for character in ["A", "한", "界", "─", "█"] as [Character] {
            XCTAssertTrue(view.cacheGlyphForTesting(character), "\(character)")
            let rect = view.renderingDiagnostics.lastGlyphRectPixels
            let atlasSize = CGFloat(view.renderingDiagnostics.glyphAtlasSizePixels)

            XCTAssertEqual(
                rect.minX.truncatingRemainder(dividingBy: CGFloat(DesignTokens.Component.glyphSlotWidthPX)),
                0,
                "\(character) must start on a slot boundary"
            )
            XCTAssertLessThanOrEqual(rect.width, CGFloat(DesignTokens.Component.glyphSlotWidthPX), "\(character)")
            XCTAssertLessThanOrEqual(rect.height, CGFloat(DesignTokens.Component.glyphSlotHeightPX), "\(character)")
            XCTAssertLessThanOrEqual(rect.maxX, atlasSize, "\(character)")
            XCTAssertLessThanOrEqual(rect.maxY, atlasSize, "\(character)")
        }
    }

    /// The atlas has to hold a Codex-style mixed session — ASCII plus box
    /// drawing plus powerline plus a few hundred Hangul syllables — without
    /// evicting anything, or common characters start rendering blank.
    func testAtlasCapacityCoversAMixedTuiAndKoreanSession() throws {
        let view = try makeView()
        XCTAssertGreaterThanOrEqual(view.glyphAtlasSlotCapacityForDiagnostics, 1_000)
    }

    // MARK: - Font fallback

    /// The monospaced system font has no Hangul, no powerline separators and no
    /// Nerd Font glyphs. Without fallback these cache as empty entries and the
    /// prompt renders as blanks.
    func testGlyphsOutsideTheBaseFontStillRasterizeThroughFallback() throws {
        let view = try makeView()

        for character in ["한", "글", "界", "\u{e0b0}", "\u{f015}", "─", "┼"] as [Character] {
            XCTAssertTrue(view.cacheGlyphForTesting(character), "\(character) must reach a fallback font")
            XCTAssertNotNil(view.cachedGlyphSlotForTesting(character), "\(character)")
        }
    }
}
