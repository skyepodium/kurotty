import AppKit
import CryptoKit
@testable import KurottyCore
@testable import KurottyApp
import Metal
import XCTest

final class GlyphRenderingRegressionTests: XCTestCase {
    func testPromptGlyphSnapshotDrawsPromptTextIncludingHangul() throws {
        let width = 640
        let height = 96
        let promptPixels = try renderPromptSnapshot("skyepodium ~/dev/kurotty 하이", width: width, height: height)
        let asciiPixels = try renderPromptSnapshot("skyepodium ~/dev/kurotty", width: width, height: height)

        XCTAssertGreaterThan(nonBackgroundByteCount(in: promptPixels), 0)
        XCTAssertNotEqual(SHA256.hash(data: Data(promptPixels)), SHA256.hash(data: Data(asciiPixels)))
    }

    private func renderPromptSnapshot(_ text: String, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("failed to create bitmap context")
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
        ]
        (text as NSString).draw(at: NSPoint(x: 8, y: 48), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        return pixels
    }

    private func nonBackgroundByteCount(in pixels: [UInt8]) -> Int {
        pixels.filter { $0 != 0 }.count
    }

    func testOffscreenTerminalFrameSnapshotUsesProductionAtlasShader() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal is not available")
        }

        let library = try device.makeLibrary(source: productionMetalShaderSource(), options: nil)
        let glyphPipeline = try makeGlyphPipeline(device: device, library: library)
        let solidPipeline = try makeSolidPipeline(device: device, library: library)

        let frame = TestTerminalFrame(
            size: SIMD2<Int>(96, 64),
            cellSize: SIMD2<Float>(10, 16),
            padding: SIMD2<Float>(8, 8),
            cells: [
                TestFrameCell(column: 1, row: 0, color: SIMD4<Float>(0.92, 0.92, 0.92, 1), atlasSlot: 0),
                TestFrameCell(column: 2, row: 0, color: SIMD4<Float>(0.42, 0.86, 0.62, 1), atlasSlot: 1),
                TestFrameCell(column: 3, row: 1, color: SIMD4<Float>(0.94, 0.68, 0.35, 1), atlasSlot: 2),
            ],
            backgrounds: [
                TestFrameQuad(column: 2, row: 0, width: 2, heightPX: 16, color: SIMD4<Float>(0.08, 0.12, 0.22, 1)),
                TestFrameQuad(column: 0, row: 2, width: 6, heightPX: 16, color: SIMD4<Float>(0.14, 0.10, 0.18, 1)),
            ],
            decorations: [
                TestFrameQuad(column: 1, row: 0, width: 2, heightPX: 2, yOffsetPX: 13, color: SIMD4<Float>(0.42, 0.86, 0.62, 1)),
                TestFrameQuad(column: 3, row: 1, width: 1, heightPX: 2, yOffsetPX: 8, color: SIMD4<Float>(0.94, 0.68, 0.35, 1)),
            ],
            cursor: TestFrameQuad(column: 5, row: 1, width: 1, heightPX: 16, color: SIMD4<Float>(0.49, 0.83, 0.99, 1))
        )

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.size.x,
            height: frame.size.y,
            mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))

        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 12, height: 4, mipmapped: false)
        atlasDescriptor.usage = [.shaderRead]
        atlasDescriptor.storageMode = .shared
        let atlas = try XCTUnwrap(device.makeTexture(descriptor: atlasDescriptor))
        atlas.replace(
            region: MTLRegionMake2D(0, 0, 12, 4),
            mipmapLevel: 0,
            withBytes: deterministicAtlasPixels(),
            bytesPerRow: 12 * 4
        )

        let vertices = unitQuadVertices()
        var uniforms = TestUniforms(
            viewport: SIMD2<Float>(Float(frame.size.x), Float(frame.size.y)),
            useLinearGlyphSampling: 1
        )
        let backgroundInstances = frame.backgrounds.map { frame.solidInstance(for: $0) }
        let glyphInstances = frame.cells.map { frame.glyphInstance(for: $0) }
        let decorationInstances = frame.decorations.map { frame.solidInstance(for: $0) }
        var cursorInstance = frame.solidInstance(for: frame.cursor)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))

        encoder.setRenderPipelineState(solidPipeline)
        setVertexArrayBytes(vertices, on: encoder, index: 0)
        setVertexArrayBytes(backgroundInstances, on: encoder, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TestUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: backgroundInstances.count)

        encoder.setRenderPipelineState(glyphPipeline)
        setVertexArrayBytes(vertices, on: encoder, index: 0)
        setVertexArrayBytes(glyphInstances, on: encoder, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TestUniforms>.stride, index: 2)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: glyphInstances.count)

        encoder.setRenderPipelineState(solidPipeline)
        setVertexArrayBytes(vertices, on: encoder, index: 0)
        setVertexArrayBytes(decorationInstances, on: encoder, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TestUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: decorationInstances.count)
        encoder.setVertexBytes(&cursorInstance, length: MemoryLayout<TestGlyphInstance>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var output = [UInt8](repeating: 0, count: frame.size.x * frame.size.y * 4)
        target.getBytes(&output, bytesPerRow: frame.size.x * 4, from: MTLRegionMake2D(0, 0, frame.size.x, frame.size.y), mipmapLevel: 0)

        XCTAssertGreaterThan(nonBlackPixelCount(in: output), 0)
        XCTAssertEqual(pixel(atX: 28, y: 47, width: frame.size.x, in: output), TestPixel(b: 46, g: 26, r: 36, a: 255))
        XCTAssertEqual(pixel(atX: 58, y: 31, width: frame.size.x, in: output), TestPixel(b: 252, g: 212, r: 125, a: 255))

        let digest = SHA256.hash(data: Data(output))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(digest, "96f0d5d9e24f0406b1d3ddd744abee09187cc34e65f2ca246ea3668a93413c09")
    }

    func testTerminalMetalViewExposesAtlasDiagnosticsAndOptInCPUFallback() throws {
        let source = try terminalMetalViewSource()
        XCTAssertTrue(source.contains("var diagnosticCPUFallbackEnabled = false"))
        XCTAssertTrue(source.contains("var diagnosticPixelSnappingEnabled = true"))
        XCTAssertTrue(source.contains("var diagnosticLinearGlyphSamplingEnabled = false"))
        XCTAssertTrue(source.contains("var diagnosticCellBoundaryOverlayEnabled = false"))
        XCTAssertTrue(source.contains("var diagnosticBaselineOverlayEnabled = false"))
        XCTAssertTrue(source.contains("var diagnosticGlyphQuadOverlayEnabled = false"))
        XCTAssertTrue(source.contains("var diagnosticRenderingLogEnabled = false"))
        XCTAssertTrue(source.contains("var isAtlasPathReadyForRendering: Bool"))
        XCTAssertTrue(source.contains("var atlasResourcesAreAvailableForDiagnostics: Bool"))
        XCTAssertTrue(source.contains("var atlasGlyphInstanceCountForDiagnostics: Int"))
        XCTAssertTrue(source.contains("var atlasNonTransparentPixelCountForDiagnostics: Int"))
        XCTAssertTrue(source.contains("var renderingDiagnostics: TerminalRenderingDiagnostics"))
        XCTAssertTrue(source.contains("let backingScaleFactor: CGFloat"))
        XCTAssertTrue(source.contains("let drawableSize: CGSize"))
        XCTAssertTrue(source.contains("let cellSizePoints: CGSize"))
        XCTAssertTrue(source.contains("let cellSizePixels: CGSize"))
        XCTAssertTrue(source.contains("let glyphAtlasSizePixels: Int"))
        XCTAssertTrue(source.contains("let lastGlyphRectPixels: CGRect"))
        XCTAssertTrue(source.contains("let lastGlyphUVOrigin: SIMD2<Float>"))
        XCTAssertTrue(source.contains("let lastGlyphUVSize: SIMD2<Float>"))
        XCTAssertTrue(source.contains("let lastGlyphDrawOffsetPoints: SIMD2<Float>"))
        XCTAssertTrue(source.contains("Kurotty render diagnostics: scale="))
        XCTAssertTrue(source.contains("var diagnosticCPUTextureIsAllocated: Bool"))
        XCTAssertTrue(source.contains("commandQueue != nil &&"))
        XCTAssertTrue(source.contains("atlasVertexBuffer != nil &&"))
        XCTAssertTrue(source.contains("uniformsBuffer != nil &&"))
        XCTAssertTrue(source.contains("atlasTexture != nil"))
        XCTAssertTrue(source.contains("atlasResourcesAreAvailableForDiagnostics"))
        XCTAssertFalse(source.contains("atlasResourcesAreAvailableForDiagnostics && atlasInstanceCount > 0"))
        XCTAssertTrue(source.contains("if diagnosticCPUFallbackEnabled,\n           !isAtlasPathReadyForRendering"))
        XCTAssertTrue(source.contains("if diagnosticCPUFallbackEnabled {\n            rebuildTextTexture()"))
    }

    func testAtlasUVsUseHalfTexelInsetAndGeometryUsesPixelSnapping() throws {
        let source = try terminalMetalViewSource()
        let tokenSource = try designTokensSource()
        XCTAssertTrue(source.contains("let halfTexel = 0.5 / Float(atlasSize)"))
        XCTAssertTrue(source.contains("Float(x) / Float(atlasSize) + halfTexel"))
        XCTAssertTrue(source.contains("Float(max(0, drawWidthPixels - 1)) / Float(atlasSize)"))
        XCTAssertTrue(source.contains("snappedRect("))
        XCTAssertTrue(source.contains("backgroundRuns"))
        XCTAssertTrue(source.contains("sameColor(as:"))
        XCTAssertTrue(source.contains("pixelAlign("))
        XCTAssertTrue(source.contains("physicalPixelRect("))
        XCTAssertTrue(source.contains("pointRect.applying(CGAffineTransform(scaleX: scale, y: scale))"))
        XCTAssertTrue(source.contains("let bitmapMinXPixels = floor(imageBounds.minX) - CGFloat(paddingPixels)"))
        XCTAssertTrue(source.contains("let unsnappedBaselineY = CGFloat(glyphSlotHeight) - CGFloat(paddingPixels) - imageBounds.maxY"))
        XCTAssertTrue(source.contains("let baselineDeltaX = (baselineX + bitmapMinXPixels) / scale"))
        XCTAssertTrue(source.contains("let glyphCanvasBaselineY = canonicalMetrics.baselineOffsetPixels"))
        XCTAssertTrue(source.contains("let bearingYPixels = max(0, Int(round(baselineY - CGFloat(bitmapBottomPixels))))"))
        XCTAssertFalse(source.contains("let baselineDeltaY = (baselineY - unsnappedBaselineY) / scale"))
        XCTAssertFalse(source.contains("let snappedInkBottom = (imageBounds.minY + baselineY) / scale"))
        XCTAssertTrue(source.contains("physicalPixelsToPoints(1)"))
        XCTAssertTrue(source.contains("overrideWidth: physicalPixelsToPoints(CGFloat(AppConstants.Terminal.cursorWidthPX))"))
        XCTAssertTrue(source.contains("let pixelSize: PixelSize"))
        XCTAssertTrue(source.contains("let drawWidthPixels = rasterized.pixelSize.width"))
        XCTAssertTrue(source.contains("let drawHeightPixels = rasterized.pixelSize.height"))
        XCTAssertTrue(source.contains("private func physicalPixelPoint(_ point: CGPoint) -> CGPoint"))
        XCTAssertTrue(source.contains("viewport: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))"))
        XCTAssertFalse(source.contains("viewport: SIMD2<Float>(Float(bounds.width), Float(bounds.height))"))
        XCTAssertTrue(tokenSource.contains("glyphAtlasOversampleScale"))
        XCTAssertTrue(source.contains("backingScale * DesignTokens.Component.glyphAtlasOversampleScale"))
        XCTAssertFalse(source.contains("glyphAtlasMinimumScale"))
    }

    func testBoxDrawingGlyphsRenderAsPixelAlignedLineQuads() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let metalSource = try terminalMetalViewSource()
        let frameSource = try terminalRenderFrameSource()

        XCTAssertTrue(surfaceSource.contains("private func appendBoxDrawingDecoration"))
        XCTAssertTrue(surfaceSource.contains("private func appendBlockElementDecoration"))
        XCTAssertTrue(surfaceSource.contains("if appendBoxDrawingDecoration("))
        XCTAssertTrue(surfaceSource.contains("if appendBlockElementDecoration("))
        XCTAssertTrue(surfaceSource.contains("continue"))
        XCTAssertTrue(frameSource.contains("case boxDrawing(left: Bool, right: Bool, up: Bool, down: Bool)"))
        XCTAssertTrue(frameSource.contains("case blockElement(x: Double, y: Double, width: Double, height: Double)"))
        XCTAssertTrue(metalSource.contains("appendBoxDrawingDecorationInstances"))
        XCTAssertTrue(metalSource.contains("blockElementInstance("))
        XCTAssertTrue(metalSource.contains("if left"))
        XCTAssertTrue(metalSource.contains("if right"))
        XCTAssertTrue(metalSource.contains("if up"))
        XCTAssertTrue(metalSource.contains("if down"))
        XCTAssertTrue(surfaceSource.contains("case \"┌\", \"╭\":"))
        XCTAssertTrue(surfaceSource.contains("case \"┘\", \"╯\":"))
        XCTAssertTrue(surfaceSource.contains("case \"┼\":"))
    }

    func testInactivePaneCursorRemainsVisibleWhileFocusedPaneBlinks() throws {
        let metalSource = try terminalMetalViewSource()
        let surfaceSource = try terminalSurfaceViewSource()
        let frameSource = try terminalRenderFrameSource()
        let constantsSource = try appConstantsSource()

        XCTAssertTrue(frameSource.contains("let cursorBlinkOn: Bool"))
        XCTAssertTrue(metalSource.contains("if terminalFrame.cursorBlinkOn,\n               terminalFrame.cursorRow >= 0"))
        XCTAssertTrue(metalSource.contains("if terminalFrame.cursorBlinkOn, terminalFrame.cursorRow >= 0"))
        XCTAssertFalse(metalSource.contains("cursorIsActive"))

        XCTAssertTrue(surfaceSource.contains("private var cursorBlinkOn = true"))
        XCTAssertTrue(surfaceSource.contains("private var cursorBlinkTimer: Timer?"))
        XCTAssertTrue(surfaceSource.contains("cursorBlinkOn: window?.firstResponder !== self || cursorBlinkOn"))
        XCTAssertTrue(surfaceSource.contains("stopCursorBlinking(showCursor: true)"))
        XCTAssertTrue(constantsSource.contains("cursorBlinkIntervalSeconds"))
    }

    func testMetalGlyphLayoutSeparatesCanonicalCellMetricsFromBitmapBounds() throws {
        let source = try terminalMetalViewSource()

        XCTAssertTrue(source.contains("private struct FontCellMetrics"))
        XCTAssertTrue(source.contains("private var fontCellMetrics: FontCellMetrics"))
        XCTAssertTrue(source.contains("private var lastFontCellMetricsInput: FontCellMetricsInput?"))
        XCTAssertTrue(source.contains("guard input != lastFontCellMetricsInput else { return }"))
        XCTAssertTrue(source.contains("let baselineOffsetPixels: Int"))
        XCTAssertTrue(source.contains("let cellWidthPixels: Int"))
        XCTAssertTrue(source.contains("let cellHeightPixels: Int"))
        XCTAssertTrue(source.contains("let cursorHeightPixels: Int"))
        XCTAssertTrue(source.contains("private func rebuildFontCellMetrics()"))
        XCTAssertTrue(source.contains("private func canonicalBaselinePointY(forRow row: Int) -> CGFloat"))
        XCTAssertTrue(source.contains("let cellOrigin = physicalPixelCellOrigin(column: column, row: row)"))
        XCTAssertTrue(source.contains("origin: SIMD2<Float>(Float(cellOrigin.x + entry.bearingXPixels), Float(canonicalBaselinePixelY(forRow: row) - entry.bearingYPixels))"))
        XCTAssertTrue(source.contains("let canonicalMetrics = fontCellMetrics"))
        XCTAssertTrue(source.contains("baselineOffsetPixels: canonicalMetrics.baselineOffsetPixels"))
        XCTAssertTrue(source.contains("cellWidthPixels: canonicalMetrics.cellWidthPixels * columnWidth"))
        XCTAssertTrue(source.contains("cellHeightPixels: canonicalMetrics.cellHeightPixels"))
        XCTAssertTrue(source.contains("let glyphCanvasBaselineY = canonicalMetrics.baselineOffsetPixels"))
        XCTAssertFalse(source.contains("let desiredInkBottom ="))
        XCTAssertFalse(source.contains("verticalInset + typographicDescent + imageBounds.minY"))
        XCTAssertFalse(source.contains("bounds.height - terminalFrame.padding.y - terminalFrame.cellSize.height * CGFloat(row + 1) + CGFloat(entry.drawOffset.y)"))
    }

    func testCursorAndDebugBaselineUseCanonicalCellMetrics() throws {
        let source = try terminalMetalViewSource()

        XCTAssertTrue(source.contains("height: physicalPixelsToPoints(CGFloat(fontCellMetrics.cursorHeightPixels))"))
        XCTAssertTrue(source.contains("let baselineOffset = physicalPixelsToPoints(CGFloat(fontCellMetrics.baselineOffsetPixels))"))
        XCTAssertTrue(source.contains("font.underlinePosition"))
        XCTAssertTrue(source.contains("yOffset = physicalPixelsToPoints(CGFloat(fontCellMetrics.underlinePositionPixels))"))
        XCTAssertFalse(source.contains("underlinePositionPixels: max(0, heightPixels - 2)"))
        XCTAssertFalse(source.contains("let underlinePositionPixels = max(0, descenderPixels - underlineThicknessPixels)"))
        XCTAssertTrue(source.contains("height: terminalFrame.cellSize.cgHeight\n            ).fill()"))
        XCTAssertFalse(source.contains("height: max(1, terminalFrame.cellSize.height - 4)"))
        XCTAssertFalse(source.contains("height: max(1, terminalFrame.cellSize.cgHeight - 4)"))
        XCTAssertFalse(source.contains("+ 2,\n                width: 2,"))
    }

    func testGlyphSamplerAndBlendConfigurationFavorSharpStraightAlphaText() throws {
        let source = try terminalMetalViewSource()

        XCTAssertTrue(source.contains("var diagnosticLinearGlyphSamplingEnabled = false"))
        XCTAssertTrue(source.contains("constexpr sampler nearest_glyph_sampler(address::clamp_to_edge, filter::nearest)"))
        XCTAssertTrue(source.contains("? glyph_atlas.sample(linear_glyph_sampler, in.uv)"))
        XCTAssertTrue(source.contains(": glyph_atlas.sample(nearest_glyph_sampler, in.uv)"))
        XCTAssertTrue(source.contains("return float4(in.color.rgb, sample.a * in.color.a);"))
        XCTAssertTrue(source.contains("sourceRGBBlendFactor = .sourceAlpha"))
        XCTAssertTrue(source.contains("destinationRGBBlendFactor = .oneMinusSourceAlpha"))
        XCTAssertTrue(source.contains("sourceAlphaBlendFactor = .one"))
        XCTAssertTrue(source.contains("destinationAlphaBlendFactor = .oneMinusSourceAlpha"))
        XCTAssertTrue(source.contains("let width = max(1, Int(ceil(bounds.width * scale)))"))
        XCTAssertTrue(source.contains("let height = max(1, Int(ceil(bounds.height * scale)))"))
        XCTAssertTrue(source.contains("MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.glyphAtlasPixelFormat"))
    }

    func testKoreanGlyphPassLeavesTransparentAtlasPixelsOnTerminalBackground() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal is not available")
        }

        let library = try device.makeLibrary(source: productionMetalShaderSource(), options: nil)
        let glyphPipeline = try makeGlyphPipeline(device: device, library: library)
        let solidPipeline = try makeSolidPipeline(device: device, library: library)

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 16,
            height: 16,
            mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))

        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        atlasDescriptor.usage = [.shaderRead]
        atlasDescriptor.storageMode = .shared
        let atlas = try XCTUnwrap(device.makeTexture(descriptor: atlasDescriptor))
        atlas.replace(
            region: MTLRegionMake2D(0, 0, 4, 4),
            mipmapLevel: 0,
            withBytes: koreanGlyphAlphaOnlyAtlasPixels(),
            bytesPerRow: 4 * 4
        )

        let vertices = unitQuadVertices()
        var uniforms = TestUniforms(viewport: SIMD2<Float>(16, 16), useLinearGlyphSampling: 0)
        var background = TestGlyphInstance(
            origin: SIMD2<Float>(0, 0),
            size: SIMD2<Float>(16, 16),
            uvOrigin: .zero,
            uvSize: .zero,
            color: SIMD4<Float>(0.10, 0.22, 0.34, 1)
        )
        var glyph = TestGlyphInstance(
            origin: SIMD2<Float>(0, 0),
            size: SIMD2<Float>(16, 16),
            uvOrigin: .zero,
            uvSize: SIMD2<Float>(1, 1),
            color: SIMD4<Float>(0.90, 0.86, 0.72, 1)
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))

        encoder.setRenderPipelineState(solidPipeline)
        setVertexArrayBytes(vertices, on: encoder, index: 0)
        encoder.setVertexBytes(&background, length: MemoryLayout<TestGlyphInstance>.stride, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TestUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

        encoder.setRenderPipelineState(glyphPipeline)
        setVertexArrayBytes(vertices, on: encoder, index: 0)
        encoder.setVertexBytes(&glyph, length: MemoryLayout<TestGlyphInstance>.stride, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TestUniforms>.stride, index: 2)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var output = [UInt8](repeating: 0, count: 16 * 16 * 4)
        target.getBytes(&output, bytesPerRow: 16 * 4, from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0)

        XCTAssertEqual(pixel(atX: 1, y: 1, width: 16, in: output), TestPixel(b: 87, g: 56, r: 26, a: 255))
        XCTAssertEqual(pixel(atX: 8, y: 8, width: 16, in: output), TestPixel(b: 184, g: 219, r: 229, a: 255))
        XCTAssertNotEqual(pixel(atX: 1, y: 1, width: 16, in: output), TestPixel(b: 184, g: 219, r: 229, a: 255))
    }

    func testKoreanGlyphAtlasIsTransparentAndBackgroundsComeFromCells() throws {
        let metalSource = try terminalMetalViewSource()
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(metalSource.contains("var slotMask = [UInt8](repeating: 0, count: glyphSlotWidth * glyphSlotHeight)"))
        XCTAssertTrue(metalSource.contains("space: CGColorSpaceCreateDeviceGray()"))
        XCTAssertTrue(metalSource.contains("bitmapInfo: CGImageAlphaInfo.none.rawValue"))
        XCTAssertTrue(metalSource.contains("context.setFillColor(CGColor(gray: 0, alpha: 1))"))
        XCTAssertTrue(metalSource.contains("context.fill(CGRect(x: 0, y: 0, width: glyphSlotWidth, height: glyphSlotHeight))"))
        XCTAssertTrue(metalSource.contains("context.setAllowsFontSmoothing(false)"))
        XCTAssertTrue(metalSource.contains("drawGlyphPaths(from: line, in: context)"))
        XCTAssertTrue(metalSource.contains("CTFontCreatePathForGlyph"))
        XCTAssertTrue(metalSource.contains("atlasPixels[pixel + 3] = alpha"))
        XCTAssertTrue(metalSource.contains("return float4(in.color.rgb, sample.a * in.color.a);"))
        XCTAssertFalse(metalSource.contains("return sample * in.color;"))
        XCTAssertTrue(surfaceSource.contains("backgrounds.append(TerminalBackground(column: column, row: row, color: cell.style.effectiveBackground))"))
        XCTAssertFalse(surfaceSource.contains("guard !cell.isContinuation else { continue }\n                let position = TerminalCellPosition(row: row, column: column)"))
    }

    func testGlyphAtlasHasEnoughSlotsForMixedTuiAndKoreanText() throws {
        let tokens = try designTokensSource()
        let atlasSize = try integerConstant(named: "glyphAtlasSizePX", in: tokens)
        let slotWidth = try integerConstant(named: "glyphSlotWidthPX", in: tokens)
        let slotHeight = try integerConstant(named: "glyphSlotHeightPX", in: tokens)

        let capacity = (atlasSize / slotWidth) * (atlasSize / slotHeight)

        XCTAssertGreaterThanOrEqual(
            capacity,
            1_000,
            "Codex-style TUI output mixes ASCII, box drawing, powerline, and many Korean syllables; the atlas must not return empty glyphs after a few hundred unique characters."
        )
    }

    func testPureTerminalModelAndStyleFilesStayAppKitFree() throws {
        let modelSource = try terminalModelSource()
        let styleSource = try terminalTextStyleSource()
        let colorUtilitiesSource = try terminalColorUtilitiesSource()
        let designSource = try designTokensSource()

        XCTAssertFalse(modelSource.contains("import AppKit"))
        XCTAssertFalse(modelSource.contains("import CoreGraphics"))
        XCTAssertFalse(modelSource.contains("CGSize"))
        XCTAssertFalse(modelSource.contains("CGPoint"))
        XCTAssertFalse(modelSource.contains("CGRect"))
        XCTAssertFalse(modelSource.contains("CGFloat"))
        XCTAssertFalse(styleSource.contains("import AppKit"))
        XCTAssertFalse(colorUtilitiesSource.contains("import AppKit"))
        XCTAssertFalse(styleSource.contains("DesignTokens.Color.ansi"))
        XCTAssertTrue(colorUtilitiesSource.contains("enum TerminalPalette"))
        XCTAssertTrue(styleSource.contains("TerminalPalette.ansiColor"))
        XCTAssertTrue(designSource.contains("TerminalPalette.ansiNormal"))
        XCTAssertTrue(designSource.contains("TerminalPalette.ansiBright"))
    }

    func testKurottyCoreSourceFilesStayFreeOfAppKitAndPlatformAdapters() throws {
        for (filename, source) in try kurottyCoreSourceFiles() {
            XCTAssertFalse(source.contains("import AppKit"), "\(filename) must stay AppKit-free")
            XCTAssertFalse(source.contains("import Darwin"), "\(filename) must stay Darwin-free")
            XCTAssertFalse(source.contains("import Metal"), "\(filename) must stay Metal-free")
            XCTAssertFalse(source.contains("ShellSession"), "\(filename) must not reference app shell adapters")
            XCTAssertFalse(source.contains("DarwinPTYTerminalSession"), "\(filename) must not reference Darwin shell adapters")
            XCTAssertFalse(source.contains("CoreBridge"), "\(filename) must not reference the dynamic ABI loader")
            XCTAssertFalse(source.contains("TerminalAppKitRenderer"), "\(filename) must not reference AppKit renderer adapters")
        }
    }

    func testSessionFactoryChoosesPlatformGuardedAdapters() throws {
        let factorySource = try terminalSessionFactorySource()
        let adapterSource = try terminalSessionAdapterSource()
        let shellSource = try shellSessionSource()
        let unsupportedSource = try unsupportedTerminalSessionSource()

        XCTAssertTrue(factorySource.contains("DefaultTerminalSessionAdapter.makeSession()"))
        XCTAssertFalse(factorySource.contains("#if os(macOS)"))
        XCTAssertFalse(factorySource.contains("DarwinPTYTerminalSession()"))
        XCTAssertFalse(factorySource.contains("UnsupportedTerminalSession()"))
        XCTAssertTrue(adapterSource.contains("#if os(macOS)"))
        XCTAssertTrue(adapterSource.contains("DarwinTerminalSessionAdapter.makeSession()"))
        XCTAssertTrue(adapterSource.contains("#elseif os(Linux)"))
        XCTAssertTrue(adapterSource.contains("#elseif os(Windows)"))
        XCTAssertTrue(adapterSource.contains("DarwinPTYTerminalSession()"))
        XCTAssertTrue(adapterSource.contains("UnsupportedTerminalSessionAdapter.makeSession(platformName: TerminalSessionPlatformNames.linux)"))
        XCTAssertTrue(adapterSource.contains("UnsupportedTerminalSessionAdapter.makeSession(platformName: TerminalSessionPlatformNames.windows)"))
        XCTAssertTrue(shellSource.hasPrefix("#if os(macOS)\n"))
        XCTAssertTrue(shellSource.contains("import Darwin"))
        XCTAssertFalse(unsupportedSource.contains("import AppKit"))
        XCTAssertFalse(unsupportedSource.contains("import Darwin"))
    }

    func testZigCorePublicModuleOnlyExposesPurePtyBoundaryTypes() throws {
        let coreSource = try zigCoreSource()

        XCTAssertTrue(coreSource.contains("pub const PtyDimensions = @import(\"pty.zig\").PtyDimensions"))
        XCTAssertTrue(coreSource.contains("pub const PtyResizeRequest = @import(\"pty.zig\").PtyResizeRequest"))
        XCTAssertTrue(coreSource.contains("pub const PtySizeDiagnostic = @import(\"pty.zig\").PtySizeDiagnostic"))
        XCTAssertFalse(coreSource.contains("pub const Pty ="))
        XCTAssertFalse(coreSource.contains("pub const PtyConfig"))
    }

    func testRenderFrameContractStaysOutOfMetalViewAndPlatformTypes() throws {
        let frameSource = try terminalRenderFrameSource()
        let metalSource = try terminalMetalViewSource()

        XCTAssertTrue(frameSource.contains("struct TerminalFrame"))
        XCTAssertFalse(metalSource.contains("struct TerminalFrame"))
        XCTAssertFalse(frameSource.contains("import AppKit"))
        XCTAssertFalse(frameSource.contains("import Metal"))
        XCTAssertFalse(frameSource.contains("import MetalKit"))
        XCTAssertFalse(frameSource.contains("NSRange"))
        XCTAssertFalse(frameSource.contains("CGRect"))
        XCTAssertFalse(frameSource.contains("CGSize"))
        XCTAssertFalse(frameSource.contains("CGFloat"))
        XCTAssertFalse(frameSource.contains("import Foundation"))
        XCTAssertTrue(frameSource.contains("let width: Double"))
        XCTAssertTrue(frameSource.contains("let height: Double"))
    }

    func testPortableKurottyCoreTypesAreUsableDirectly() {
        let style = TerminalTextStyle(
            foreground: TerminalPalette.ansiColor(2, bright: false),
            background: .zero,
            bold: true
        )
        let frame = TerminalFrame(
            cells: [
                TerminalCell(
                    character: "K",
                    column: 0,
                    row: 0,
                    foreground: style.effectiveForeground,
                    background: style.effectiveBackground
                ),
            ],
            backgrounds: [
                TerminalBackground(column: 0, row: 0, color: style.effectiveBackground),
            ],
            decorations: [
                TerminalDecoration(
                    column: 0,
                    row: 0,
                    width: 1,
                    kind: .blockElement(x: 0, y: 0, width: 1, height: 0.5),
                    color: style.effectiveForeground
                ),
            ],
            defaultForeground: style.foreground,
            defaultBackground: style.background,
            dirtyRows: [0],
            dirtyRects: [TerminalFrameRect(x: 0, y: 0, width: 10, height: 20)],
            isFullDamage: false,
            cursorColumn: 0,
            cursorRow: 0,
            cursorBlinkOn: true,
            markedTextColumn: 0,
            markedText: "",
            markedTextSelectedRange: .none,
            columns: 1,
            visibleRows: 1,
            cellSize: TerminalFrameSize(width: 10, height: 20),
            padding: .zero
        )

        XCTAssertEqual("한".terminalColumnWidth, 2)
        XCTAssertEqual(frame.decorations.count, 1)
        XCTAssertEqual(frame.dirtyRects.first?.height, 20)
    }

    func testPrintableWritesReplacePreviousCellStyleInsteadOfPreservingPromptFragments() throws {
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(surfaceSource.contains("screen.set(character: character, row: cursorRow, column: cursorColumn, width: width, style: currentStyle)"))
        XCTAssertFalse(surfaceSource.contains("styleForPrintableWrite"))
        XCTAssertFalse(surfaceSource.contains("existingPersistentBackground"))
        XCTAssertFalse(surfaceSource.contains("shouldPreserveExistingBackground"))
        XCTAssertFalse(surfaceSource.contains("style.background = existingBackground"))
    }

    func testMarkedTextStartsAtCursorColumnInAtlasAndFallbackRenderers() throws {
        let source = try terminalMetalViewSource()
        let frameSource = try terminalRenderFrameSource()
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(frameSource.contains("let markedTextColumn: Int"))
        XCTAssertTrue(frameSource.contains("public struct TerminalPreeditRenderRange: Equatable, Sendable"))
        XCTAssertTrue(frameSource.contains("public var markedTextRenderRange: TerminalPreeditRenderRange?"))
        XCTAssertTrue(source.contains("private func markedTextRenderPlan()"))
        XCTAssertTrue(source.contains("var column = markedTextPlan.range.startColumn"))
        XCTAssertTrue(surfaceSource.contains("private func renderedMarkedTextPosition(visibleStartRow: Int, compositionText: String) -> TerminalCellPosition?"))
        XCTAssertTrue(surfaceSource.contains("let compositionText = textInputOverlayText()"))
        XCTAssertTrue(surfaceSource.contains("let markedTextPosition = renderedMarkedTextPosition(visibleStartRow: visibleStartRow, compositionText: compositionText)"))
        XCTAssertTrue(surfaceSource.contains("let contentRow = scrollbackRows.count + anchor.row"))
        XCTAssertTrue(surfaceSource.contains("row: contentRow - visibleStartRow"))
        XCTAssertTrue(surfaceSource.contains("let displayCursorColumn = markedTextPosition?.column ?? cursorColumn"))
        XCTAssertTrue(surfaceSource.contains("markedTextColumn: displayCursorColumn"))
        XCTAssertTrue(surfaceSource.contains("cursorColumn: min(displayCursorColumn + compositionText.terminalColumnWidth"))
        XCTAssertFalse(source.contains("terminalFrame.cursorColumn - terminalColumnWidth(of: terminalFrame.markedText)"))
        XCTAssertFalse(source.contains("var column = terminalFrame.markedTextColumn"))
    }

    func testMarkedTextMasksOnlyCompositionCells() throws {
        let source = try terminalMetalViewSource()

        XCTAssertTrue(source.contains("private func isCellCoveredByMarkedText(_ cell: TerminalCell) -> Bool"))
        XCTAssertTrue(source.contains("guard !isCellCoveredByMarkedText(cell) else { continue }"))
        XCTAssertTrue(source.contains("let markedTextRange = terminalFrame.markedTextRenderRange?.cellRange"))
        XCTAssertFalse(source.contains("let markedTextRange = terminalFrame.markedTextColumn..<terminalFrame.columns"))
        XCTAssertFalse(source.contains("terminalFrame.markedTextColumn + terminalColumnWidth(of: terminalFrame.markedText)"))
        XCTAssertTrue(source.contains("return cellRange.overlaps(markedTextRange)"))
    }

    func testMarkedTextCompositionDoesNotPersistSelectionBackgrounds() throws {
        let source = try terminalMetalViewSource()
        let surfaceSource = try terminalSurfaceViewSource()
        let frameSource = try terminalRenderFrameSource()
        let routerSource = try terminalTextInputRouterSource()
        let encoderSource = try terminalKeyEncoderSource()

        XCTAssertTrue(frameSource.contains("let markedTextSelectedRange: TerminalTextSelectionRange"))
        XCTAssertTrue(source.contains("markedTextColor(for: character, utf16Offset: utf16Offset)"))
        XCTAssertTrue(source.contains("Self.intersects(characterRange, terminalFrame.markedTextSelectedRange)"))
        XCTAssertTrue(surfaceSource.contains("markedTextSelectedRange: markedTextSelectionRange(committedPrefix: committedMarkedTextPrefix)"))
        XCTAssertTrue(surfaceSource.contains("private var markedTextAnchor: TerminalCellPosition?"))
        XCTAssertTrue(surfaceSource.contains("private var pendingMarkedTextAnchor: TerminalCellPosition?"))
        XCTAssertTrue(surfaceSource.contains("private var committedMarkedTextPrefix = \"\""))
        XCTAssertTrue(surfaceSource.contains("private var committedMarkedTextPrefixAnchor: TerminalCellPosition?"))
        XCTAssertTrue(surfaceSource.contains("private func markMarkedTextDirty()"))
        XCTAssertTrue(surfaceSource.contains("recordPendingMarkedTextAnchor(afterCommitting: text)"))
        XCTAssertTrue(surfaceSource.contains("private func advancedTerminalPosition(from position: TerminalCellPosition, by text: String) -> TerminalCellPosition"))
        XCTAssertTrue(surfaceSource.contains("markedTextAnchor = pendingMarkedTextAnchor ?? TerminalCellPosition(row: cursorRow, column: cursorColumn)"))
        XCTAssertTrue(surfaceSource.contains("pendingMarkedTextAnchor = nil"))
        XCTAssertTrue(surfaceSource.contains("pendingMarkedTextAnchor = nil\n        markDirty(row: cursorRow)"))
        XCTAssertTrue(surfaceSource.contains("if let sequence = TerminalKeyEncoder.sequence(for: selector) {\n            clearCommittedMarkedTextPrefix()\n            pendingMarkedTextAnchor = nil\n            send(sequence)\n        }"))
        XCTAssertTrue(encoderSource.contains("case #selector(NSResponder.deleteBackward(_:)):\n            return \"\\u{7f}\""))
        XCTAssertTrue(routerSource.contains("precomposedStringWithCanonicalMapping"))
        XCTAssertTrue(surfaceSource.contains("TerminalTextInputRouter.committedText(from: string)"))
        XCTAssertTrue(surfaceSource.contains("recordPendingMarkedTextAnchor(afterCommitting: text)\n        clearMarkedText(renderFrame: false)\n        guard !text.isEmpty else { return }"))
        XCTAssertFalse(surfaceSource.contains("appendMarkedTextSelectionBackgrounds(to: &backgrounds)"))
        XCTAssertFalse(surfaceSource.contains("private func selectedMarkedTextRange()"))
    }

    func testMarkedTextFramesAreCoalescedDuringKeyDownLikeGhostty() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let metalSource = try terminalMetalViewSource()
        let keyDownSource = try sourceSlice(
            in: surfaceSource,
            from: "override func keyDown(with event: NSEvent)",
            to: "override func performKeyEquivalent"
        )
        let setMarkedTextSource = try sourceSlice(
            in: surfaceSource,
            from: "func setMarkedText",
            to: "func unmarkText"
        )
        let insertTextSource = try sourceSlice(
            in: surfaceSource,
            from: "func insertText",
            to: "override func doCommand"
        )

        XCTAssertTrue(surfaceSource.contains("private var textInputEventDepth = 0"))
        XCTAssertTrue(surfaceSource.contains("private var needsDeferredTextInputFrame = false"))
        XCTAssertTrue(surfaceSource.contains("private var isTextInputRendererFrameScheduled = false"))
        XCTAssertTrue(surfaceSource.contains("private var keyTextAccumulator: [String]?"))
        XCTAssertTrue(surfaceSource.contains("private func performTextInputTransaction<Result>(_ body: () -> Result) -> Result"))
        XCTAssertTrue(surfaceSource.contains("private func requestTextInputRendererFrame()"))
        XCTAssertTrue(surfaceSource.contains("DispatchQueue.main.async"))
        XCTAssertTrue(surfaceSource.contains("sendCommittedText(text, source: \"keyTextAccumulator\")"))
        XCTAssertTrue(keyDownSource.contains("performTextInputTransaction"))
        XCTAssertTrue(setMarkedTextSource.contains("guard !attr.string.isEmpty else"))
        XCTAssertTrue(setMarkedTextSource.contains("requestTextInputRendererFrame()"))
        XCTAssertFalse(setMarkedTextSource.contains("updateRendererFrame()"))
        XCTAssertTrue(insertTextSource.contains("if var committedText = keyTextAccumulator"))
        XCTAssertTrue(insertTextSource.contains("committedText.append(text)"))
        XCTAssertTrue(insertTextSource.contains("clearMarkedText(renderFrame: false)"))
        XCTAssertFalse(insertTextSource.contains("clearMarkedText(renderFrame: shouldRenderClearFrame)"))
        XCTAssertTrue(surfaceSource.contains("guard !committedMarkedTextPrefix.isEmpty else"))
        XCTAssertFalse(insertTextSource.contains("unmarkText()"))
        XCTAssertTrue(metalSource.contains("private var markedTextCursorColumn: Int?"))
        XCTAssertTrue(metalSource.contains("range.cursorColumn(in: terminalFrame.markedText"))
    }

    func testCommandPaletteWiresExecutableCommandSpanActionsToActiveSurface() throws {
        let appDelegateSource = try appDelegateSource()
        let windowSource = try terminalWindowControllerSource()
        let splitSource = try splitTerminalViewSource()
        let paneSource = try terminalPaneViewSource()
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(appDelegateSource.contains("TerminalCommandSpanPaletteActions.registryForPalette"))
        XCTAssertTrue(appDelegateSource.contains("commandSpanExecutor: { [weak terminalController] command in"))
        XCTAssertTrue(windowSource.contains("func commandSpanPaletteCommands() -> [TerminalCommandSpanCommand]"))
        XCTAssertTrue(windowSource.contains("func executeCommandSpanPaletteCommand(_ command: TerminalCommandSpanCommand) -> Bool"))
        XCTAssertTrue(splitSource.contains("func commandSpanPaletteCommands() -> [TerminalCommandSpanCommand]"))
        XCTAssertTrue(splitSource.contains("func executeCommandSpanPaletteCommand(_ command: TerminalCommandSpanCommand) -> Bool"))
        XCTAssertTrue(paneSource.contains("func commandSpanPaletteCommands() -> [TerminalCommandSpanCommand]"))
        XCTAssertTrue(paneSource.contains("func executeCommandSpanPaletteCommand(_ command: TerminalCommandSpanCommand) -> Bool"))
        XCTAssertTrue(surfaceSource.contains("func commandSpanPaletteCommands() -> [TerminalCommandSpanCommand]"))
        XCTAssertTrue(surfaceSource.contains("func executeCommandSpanPaletteCommand(_ command: TerminalCommandSpanCommand) -> Bool"))
        XCTAssertTrue(surfaceSource.contains("copyCommandSpanReference(span.locatorString)"))
        XCTAssertTrue(surfaceSource.contains("sendText(\"\\(candidate.commandText)\\n\")"))
    }

    func testCommittedTextUsesOnlyConfirmedIMETextBeforePtySend() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let inputSource = try terminalInputViewSource()
        let routerSource = try terminalTextInputRouterSource()

        XCTAssertTrue(routerSource.contains("static func committedText(from string: Any) -> String"))
        XCTAssertTrue(routerSource.contains("precomposedStringWithCanonicalMapping"))
        XCTAssertFalse(routerSource.contains("composingCompatibilityHangulJamo"))
        XCTAssertFalse(routerSource.contains("pendingCompatibilityJamo"))
        XCTAssertFalse(routerSource.contains("isOnlyHangulCompatibilityJamo"))
        XCTAssertTrue(surfaceSource.contains("TerminalTextInputRouter.committedText(from: string)"))
        XCTAssertTrue(inputSource.contains("TerminalTextInputRouter.committedText(from: string)"))
        XCTAssertTrue(surfaceSource.contains("NSTextInputContext.keyboardSelectionDidChangeNotification"))
        XCTAssertTrue(inputSource.contains("NSTextInputContext.keyboardSelectionDidChangeNotification"))
        XCTAssertFalse(surfaceSource.contains("inputContext?.discardMarkedText()"))
        XCTAssertFalse(inputSource.contains("inputContext?.discardMarkedText()"))
        XCTAssertTrue(surfaceSource.contains("re-enters\n        // AppKit/IMK synchronously"))
        XCTAssertTrue(inputSource.contains("re-enter the IME service once per split pane"))
    }

    func testTextKeyDownIsConsumedByAppKitTextInterpreterWithoutRawFallback() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let inputSource = try terminalInputViewSource()
        let routerSource = try terminalTextInputRouterSource()

        for source in [surfaceSource, inputSource] {
            XCTAssertTrue(source.contains("if performTextInputTransaction({\n            TerminalTextInputRouter.handleKeyDown(event, in: self, hasMarkedText: hasMarkedText())\n        }) {\n            return\n        }\n        if handleTerminalControlKey(event)"))
            XCTAssertTrue(source.contains("TerminalTextInputRouter.logInsertText(text, replacementRange: replacementRange)"))
            XCTAssertTrue(source.contains("sendCommittedText(text, source: \"insertText\")"))
            XCTAssertTrue(source.contains("sendCommittedText(text, source: \"keyTextAccumulator\")"))
            XCTAssertFalse(source.contains("TerminalTextInputRouter.consumePendingText"))
        }
        XCTAssertFalse(routerSource.contains("inputContext?.handleEvent"))
        XCTAssertTrue(routerSource.contains("view.interpretKeyEvents([event])"))
        XCTAssertTrue(routerSource.contains("if hasMarkedText {\n            return true\n        }"))
        XCTAssertTrue(routerSource.contains("flags.contains(.command) || flags.contains(.control)"))
        XCTAssertTrue(routerSource.contains("Kurotty input-client:"))
    }

    func testGlyphAtlasPadsBitmapBoundsBeforeDrawingInk() throws {
        let source = try terminalMetalViewSource()

        XCTAssertTrue(source.contains("let bitmapMinXPixels = floor(imageBounds.minX) - CGFloat(paddingPixels)"))
        XCTAssertTrue(source.contains("let bitmapMaxXPixels = ceil(imageBounds.maxX) + CGFloat(paddingPixels)"))
        XCTAssertTrue(source.contains("let pixelWidth = min(glyphSlotWidth, max(1, Int(bitmapMaxXPixels - bitmapMinXPixels)))"))
        XCTAssertTrue(source.contains("let desiredInkLeft: CGFloat = 0"))
        XCTAssertFalse(source.contains("(logicalAdvanceWidth - imageLogicalWidth) * 0.5"))
        XCTAssertTrue(source.contains("let baselineX = round(-bitmapMinXPixels)"))
        XCTAssertFalse(source.contains("let unsnappedBaselineX = CGFloat(paddingPixels) - imageBounds.minX"))
    }

    func testMetalViewIncludesPixelSnappedDebugOverlays() throws {
        let source = try terminalMetalViewSource()

        XCTAssertTrue(source.contains("private var debugOverlayInstanceBuffer: MTLBuffer?"))
        XCTAssertTrue(source.contains("private func rebuildDebugOverlayBuffer(glyphDebugRects: [CGRect])"))
        XCTAssertTrue(source.contains("diagnosticCellBoundaryOverlayEnabled"))
        XCTAssertTrue(source.contains("diagnosticBaselineOverlayEnabled"))
        XCTAssertTrue(source.contains("diagnosticGlyphQuadOverlayEnabled"))
        XCTAssertTrue(source.contains("debugSolidInstance(rect:"))
        XCTAssertTrue(source.contains("let onePixel = physicalPixelsToPoints(1)"))
        XCTAssertTrue(source.contains("debugOverlayInstanceCount > 0"))
        XCTAssertTrue(source.contains("encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: debugOverlayInstanceCount)"))
    }

    func testMetalViewResynchronizesWhenDisplayBackingScaleChanges() throws {
        let source = try terminalMetalViewSource()

        XCTAssertTrue(source.contains("override func viewDidMoveToWindow()"))
        XCTAssertTrue(source.contains("override func viewDidChangeBackingProperties()"))
        XCTAssertTrue(source.contains("private func synchronizeBackingScaleAndDrawableSize()"))
        XCTAssertTrue(source.contains("private var windowScreenObserver: NSObjectProtocol?"))
        XCTAssertTrue(source.contains("NSWindow.didChangeScreenNotification"))
        XCTAssertTrue(source.contains("let scaledDrawableSize = CGSize("))
        XCTAssertTrue(source.contains("drawableSize = scaledDrawableSize"))
        XCTAssertTrue(source.contains("layer?.contentsScale = scale"))
        XCTAssertTrue(source.contains("let atlasInvalidated = resetAtlasIfBackingScaleChanged()"))
        XCTAssertTrue(source.contains("colorspace = CGColorSpace(name: CGColorSpace.sRGB)"))
        XCTAssertTrue(source.contains("rebuildVertexBuffer()"))
        XCTAssertTrue(source.contains("logDisplaySynchronization("))
        XCTAssertTrue(source.contains("resetAtlasIfBackingScaleChanged()"))
        XCTAssertTrue(source.contains("colorPixelFormat = TerminalMetalView.renderTargetPixelFormat"))
        XCTAssertTrue(source.contains("static let renderTargetPixelFormat: MTLPixelFormat = .bgra8Unorm"))
        XCTAssertTrue(source.contains("static let glyphAtlasPixelFormat: MTLPixelFormat = .rgba8Unorm"))
        XCTAssertTrue(source.contains("colorSpacePolicy=sRGB values on bgra8Unorm"))
        XCTAssertTrue(source.contains("sampler=nearest"))
        XCTAssertTrue(source.contains("blend=straight-alpha sourceAlpha/oneMinusSourceAlpha"))
    }

    func testTerminalSurfaceRecomputesMetricsWhenWindowScreenChanges() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("private var windowScreenObserver: NSObjectProtocol?"))
        XCTAssertTrue(source.contains("NSWindow.didChangeScreenNotification"))
        XCTAssertTrue(source.contains("override func viewDidChangeBackingProperties()"))
        XCTAssertTrue(source.contains("private func handleDisplayConfigurationChanged()"))
        XCTAssertTrue(source.contains("markFullDamage()"))
        XCTAssertTrue(source.contains("syncSizeWithView()"))
        XCTAssertTrue(source.contains("updateRendererFrame()"))
    }

    func testTerminalSurfaceUsesRendererProtocolFactoryInsteadOfMetalViewDirectly() throws {
        let rendererSource = try terminalRendererSource()
        let frameRendererSource = try terminalFrameRendererSource()
        let metalSource = try terminalMetalViewSource()
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(frameRendererSource.contains("protocol TerminalFrameRenderer: AnyObject"))
        XCTAssertTrue(frameRendererSource.contains("func update(frame: TerminalFrame)"))
        XCTAssertFalse(frameRendererSource.contains("import AppKit"))
        XCTAssertFalse(frameRendererSource.contains("NSView"))
        XCTAssertFalse(frameRendererSource.contains("NSFont"))
        XCTAssertTrue(rendererSource.contains("protocol TerminalAppKitRenderer: TerminalFrameRenderer"))
        XCTAssertTrue(rendererSource.contains("var rendererView: NSView { get }"))
        XCTAssertTrue(rendererSource.contains("func applyAppearance("))
        XCTAssertTrue(rendererSource.contains("enum TerminalRendererFactory"))
        XCTAssertTrue(rendererSource.contains("static func makeDefaultRenderer("))
        XCTAssertTrue(rendererSource.contains(") -> any TerminalAppKitRenderer"))
        XCTAssertTrue(rendererSource.contains("TerminalMetalView("))
        XCTAssertTrue(metalSource.contains("final class TerminalMetalView: MTKView, MTKViewDelegate, TerminalAppKitRenderer"))
        XCTAssertTrue(metalSource.contains("var rendererView: NSView { self }"))
        XCTAssertTrue(surfaceSource.contains("private let renderer: any TerminalAppKitRenderer"))
        XCTAssertTrue(surfaceSource.contains("TerminalRendererFactory.makeDefaultRenderer("))
        XCTAssertTrue(surfaceSource.contains("let rendererView = renderer.rendererView"))
        XCTAssertTrue(surfaceSource.contains("rendererFramePresented()"))
        XCTAssertTrue(surfaceSource.contains("renderer.update(frame: TerminalFrame("))
        XCTAssertTrue(surfaceSource.contains("renderer.applyAppearance("))
        XCTAssertFalse(surfaceSource.contains("private let renderer: any TerminalRenderer"))
        XCTAssertFalse(surfaceSource.contains("private let metalView"))
        XCTAssertFalse(surfaceSource.contains("TerminalMetalView("))
        XCTAssertFalse(surfaceSource.contains("metalView."))
        XCTAssertFalse(surfaceSource.contains("metalFramePresented()"))
    }

    func testTerminalSurfaceSnapsCellMetricsToPhysicalPixels() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("private var currentBackingScale: CGFloat"))
        XCTAssertTrue(source.contains("let scale = currentBackingScale"))
        XCTAssertTrue(source.contains("let lineHeight = snapMetricToPhysicalPixels(rawLineHeight, scale: scale)"))
        XCTAssertTrue(source.contains("let width = snapMetricToPhysicalPixels(rawWidth, scale: scale)"))
        XCTAssertFalse(source.contains("ceil((\"0\" as NSString).size(withAttributes: [.font: font]).width)"))
        XCTAssertTrue(source.contains("private func snapMetricToPhysicalPixels(_ value: CGFloat, scale: CGFloat) -> CGFloat"))
        XCTAssertTrue(source.contains("ceil(value * scale) / scale"))
        XCTAssertTrue(source.contains("cellSize: TerminalFrameSize(width: Double(width), height: Double(lineHeight))"))
    }

    func testGlyphAtlasUsesFontFallbackForPromptSymbols() throws {
        let source = try terminalMetalViewSource()
        XCTAssertTrue(source.contains("private static let glyphFallbackFontNames"))
        XCTAssertTrue(source.contains("private static let cjkGlyphFallbackFontNames"))
        XCTAssertTrue(source.contains("private func scaledFont(for character: Character, scale: CGFloat) -> CTFont"))
        XCTAssertTrue(source.contains("CTFontCreateForString"))
        XCTAssertTrue(source.contains("fontSupports(character"))
        XCTAssertTrue(source.contains("isCJKGlyph(character) ? Self.cjkGlyphFallbackFontNames + Self.glyphFallbackFontNames"))
        XCTAssertTrue(source.contains("\"Apple SD Gothic Neo\""))
        XCTAssertTrue(source.contains("\"AppleGothic\""))
        XCTAssertTrue(source.contains("Symbols Nerd Font Mono"))
        XCTAssertTrue(source.contains("MesloLGS NF"))
    }

    func testTerminalFrameCarriesTrackedDamageDiagnostics() throws {
        let metalSource = try terminalMetalViewSource()
        let frameSource = try terminalRenderFrameSource()
        XCTAssertTrue(frameSource.contains("let dirtyRows: [Int]"))
        XCTAssertTrue(frameSource.contains("let dirtyRects: [TerminalFrameRect]"))
        XCTAssertTrue(frameSource.contains("let isFullDamage: Bool"))
        XCTAssertTrue(frameSource.contains("let defaultForeground: SIMD4<Float>"))
        XCTAssertTrue(frameSource.contains("let defaultBackground: SIMD4<Float>"))
        XCTAssertTrue(metalSource.contains("terminalFrame.defaultForeground"))
        XCTAssertTrue(metalSource.contains("var lastFrameDirtyRowsForDiagnostics: [Int]"))
        XCTAssertTrue(metalSource.contains("var lastFrameDirtyRectsForDiagnostics: [CGRect]"))
        XCTAssertTrue(metalSource.contains("var lastFrameDamageWasFullForDiagnostics: Bool"))
        XCTAssertTrue(metalSource.contains("var diagnosticFullRedrawEnabled = false"))
        XCTAssertTrue(metalSource.contains("let policy = frame.damageMetadata.redrawPolicy("))
        XCTAssertTrue(metalSource.contains("let uncoalescedSubmittedDisplayRects = policy.redrawDecision == .full ? [bounds] : frame.dirtyRects.map(\\.cgRect)"))
        XCTAssertTrue(metalSource.contains("let submittedDisplayRects = policy.canCoalesceAtDisplayCadence"))
        XCTAssertTrue(metalSource.contains("let submittedDisplayRects = damageDiagnostics.submittedDisplayRects"))
        XCTAssertTrue(metalSource.contains("setNeedsDisplay(rect)"))
        XCTAssertTrue(metalSource.contains("!$0.color.sameColor(as: terminalFrame.defaultBackground)"))
        XCTAssertFalse(metalSource.contains("private struct InputLineLayout"))
        XCTAssertFalse(metalSource.contains("inputLineBackgroundInstanceBuffer"))
        XCTAssertFalse(metalSource.contains("backgroundRunsExcludingInputLine"))
        XCTAssertFalse(metalSource.contains("inputLineLayout(from:"))
        XCTAssertFalse(metalSource.contains("isInputLineBackgroundColor"))
        XCTAssertFalse(metalSource.contains("cursorTouchesInputRun"))
        XCTAssertTrue(metalSource.contains("let backgroundRuns = mergedBackgroundRuns()"))
        XCTAssertTrue(metalSource.contains("Kurotty render rects: cursorRectPx=%@"))

        let surfaceSource = try terminalSurfaceViewSource()
        XCTAssertTrue(surfaceSource.contains("private var pendingDirtyRows = Set<Int>()"))
        XCTAssertTrue(surfaceSource.contains("private var pendingFullDamage = true"))
        XCTAssertTrue(surfaceSource.contains("private func shouldRenderBackground(for cell: TerminalScreenCell) -> Bool"))
        XCTAssertTrue(surfaceSource.contains("cell.style == .default"))
        XCTAssertTrue(surfaceSource.contains("cell.style.effectiveBackground.sameColor(as: terminalDefaultStyle.background)"))
        XCTAssertTrue(surfaceSource.contains("private func markDirty(row: Int)"))
        XCTAssertTrue(surfaceSource.contains("private func markFullDamage()"))
        XCTAssertTrue(surfaceSource.contains("private func consumePendingDamage(metrics: TerminalMetrics) -> TerminalFrameDamage"))
        XCTAssertTrue(surfaceSource.contains("dirtyRows: damage.rows"))
        XCTAssertTrue(surfaceSource.contains("dirtyRects: damage.rects"))
        XCTAssertTrue(surfaceSource.contains("isFullDamage: damage.isFull"))
        XCTAssertTrue(surfaceSource.contains("defaultForeground: terminalDefaultStyle.foreground"))
        XCTAssertTrue(surfaceSource.contains("screen.clear(row: cursorRow, from: cursorColumn, through: screen.columns - 1, style: currentStyle)"))
        XCTAssertTrue(surfaceSource.contains("screen.clear(row: cursorRow, from: 0, through: cursorColumn, style: currentStyle)"))
        XCTAssertTrue(surfaceSource.contains("screen.clear(row: cursorRow, style: currentStyle)"))
        XCTAssertFalse(surfaceSource.contains("screen.clear(row: cursorRow, from: cursorColumn, through: screen.columns - 1)\n"))
    }

    func testTerminalMetalViewExposesDamageInvalidationDiagnostics() throws {
        let metalSource = try terminalMetalViewSource()
        let updateSource = try functionBody(named: "update", in: metalSource)
        let logSource = try functionBody(named: "logFrameStartIfNeeded", in: metalSource)

        XCTAssertTrue(metalSource.contains("struct TerminalRenderDamageDiagnostics"))
        XCTAssertTrue(metalSource.contains("let redrawDecision: RedrawDecision"))
        XCTAssertTrue(metalSource.contains("let dirtyRectCount: Int"))
        XCTAssertTrue(metalSource.contains("let scissorDisabled: Bool"))
        XCTAssertTrue(metalSource.contains("let submittedDisplayRects: [CGRect]"))
        XCTAssertTrue(metalSource.contains("let schedulingPolicy: SchedulingPolicy"))
        XCTAssertTrue(metalSource.contains("let canCoalesceAtDisplayCadence: Bool"))
        XCTAssertTrue(metalSource.contains("let coalescingFallbackReason: CoalescingFallbackReason"))
        XCTAssertTrue(metalSource.contains("let stablePixelBounds: [TerminalFramePixelRect]"))
        XCTAssertTrue(metalSource.contains("let stablePixelBoundCount: Int"))
        XCTAssertTrue(metalSource.contains("struct TerminalRenderScissorRect"))
        XCTAssertTrue(metalSource.contains("let scissorReadiness: ScissorReadiness"))
        XCTAssertTrue(metalSource.contains("let scissorRects: [TerminalRenderScissorRect]"))
        XCTAssertTrue(metalSource.contains("var scissorPlanIsReady: Bool"))
        XCTAssertTrue(metalSource.contains("var damageDiagnostics: TerminalRenderDamageDiagnostics"))
        XCTAssertTrue(metalSource.contains("var lastSubmittedDisplayRectsForDiagnostics: [CGRect]"))
        XCTAssertTrue(metalSource.contains("var lastFrameScissorWasDisabledForDiagnostics: Bool"))
        XCTAssertTrue(metalSource.contains("var lastFrameCanCoalesceAtDisplayCadenceForDiagnostics: Bool"))
        XCTAssertTrue(metalSource.contains("var lastFrameCoalescingFallbackReasonForDiagnostics: String"))
        XCTAssertTrue(metalSource.contains("var lastFrameStablePixelBoundCountForDiagnostics: Int"))
        XCTAssertTrue(metalSource.contains("var lastFrameScissorReadinessForDiagnostics: String"))
        XCTAssertTrue(metalSource.contains("var lastFrameScissorPlanIsReadyForDiagnostics: Bool"))
        XCTAssertTrue(metalSource.contains("var lastFrameScissorRectsForDiagnostics: [TerminalRenderScissorRect]"))
        XCTAssertTrue(updateSource.contains("TerminalRenderDamageDiagnostics.make("))
        XCTAssertTrue(updateSource.contains("let submittedDisplayRects = damageDiagnostics.submittedDisplayRects"))
        XCTAssertTrue(updateSource.contains("for rect in submittedDisplayRects {\n            setNeedsDisplay(rect)"))
        XCTAssertTrue(logSource.contains("redrawDecision=%@"))
        XCTAssertTrue(logSource.contains("schedulingPolicy=%@"))
        XCTAssertTrue(logSource.contains("coalesceAtDisplayCadence=%@"))
        XCTAssertTrue(logSource.contains("coalescingFallbackReason=%@"))
        XCTAssertTrue(logSource.contains("submittedDisplayRects=%@"))
        XCTAssertTrue(logSource.contains("stablePixelBoundCount=%d"))
        XCTAssertTrue(logSource.contains("scissorReadiness=%@"))
        XCTAssertTrue(logSource.contains("scissorPlanReady=%@"))
        XCTAssertTrue(logSource.contains("scissorRects=%@"))
        XCTAssertTrue(logSource.contains("damageDiagnostics.dirtyRectCount"))
        XCTAssertTrue(logSource.contains("damageDiagnostics.scissorDisabled ? \"yes\" : \"no\""))
    }

    func testTerminalMetalViewCompletionHandlerDoesNotCaptureMainActorStateOnMetalQueue() throws {
        let metalSource = try terminalMetalViewSource()
        let drawSource = try functionBody(named: "draw", in: metalSource)

        XCTAssertTrue(metalSource.contains("private static func makePresentedCompletionHandler"))
        XCTAssertTrue(drawSource.contains("let presentedCompletionHandler = Self.makePresentedCompletionHandler(onPresented)"))
        XCTAssertTrue(drawSource.contains("commandBuffer.addCompletedHandler(presentedCompletionHandler)"))
        XCTAssertFalse(drawSource.contains("commandBuffer.addCompletedHandler { [weak self]"))
        XCTAssertFalse(drawSource.contains("self?.onPresented?()"))
    }

    func testPtyOutputIsCoalescedBeforeRenderingToAvoidTransientClearedRows() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("private var pendingOutputText = \"\""))
        XCTAssertTrue(source.contains("private var isOutputFlushScheduled = false"))
        XCTAssertTrue(source.contains("self?.enqueueOutput(text)"))
        XCTAssertTrue(source.contains("private func enqueueOutput(_ text: String)"))
        XCTAssertTrue(source.contains("DispatchQueue.main.asyncAfter"))
        XCTAssertTrue(source.contains("appendOutput(text)"))
        XCTAssertFalse(source.contains("self?.appendOutput(text)"))
    }

    func testEraseLineUsesActiveStyleForClearedCells() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("screen.clear(row: cursorRow, from: cursorColumn, through: screen.columns - 1, style: currentStyle)"))
        XCTAssertTrue(source.contains("screen.clear(row: cursorRow, from: 0, through: cursorColumn, style: currentStyle)"))
        XCTAssertTrue(source.contains("screen.clear(row: cursorRow, style: currentStyle)"))
        XCTAssertFalse(source.contains("screen.clear(row: cursorRow, from: cursorColumn, through: screen.columns - 1)\n"))
        XCTAssertFalse(source.contains("screen.clear(row: cursorRow, from: 0, through: cursorColumn)\n"))
        XCTAssertFalse(source.contains("screen.clear(row: cursorRow)\n"))
    }

    func testTrailingNonDefaultBackgroundCellsAreRendered() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let metalSource = try terminalMetalViewSource()

        XCTAssertTrue(surfaceSource.contains("private func shouldRenderBackground(for cell: TerminalScreenCell) -> Bool"))
        XCTAssertTrue(surfaceSource.contains("guard !cell.style.effectiveBackground.sameColor(as: terminalDefaultStyle.background) else"))
        XCTAssertTrue(surfaceSource.contains("cell.style == .default"))
        XCTAssertFalse(surfaceSource.contains("cell.character == \" \", !cell.isContinuation, cell.style == .default"))
        XCTAssertTrue(surfaceSource.contains("backgrounds.append(TerminalBackground(column: column, row: row, color: cell.style.effectiveBackground))"))
        XCTAssertTrue(metalSource.contains(".filter { $0.row >= 0 && $0.row < terminalFrame.visibleRows && !$0.color.sameColor(as: terminalFrame.defaultBackground) }"))
        XCTAssertTrue(metalSource.contains("last.column + last.width == background.column"))
        XCTAssertTrue(metalSource.contains("last.width += 1"))
        XCTAssertFalse(metalSource.contains("backgroundRunsExcludingInputLine"))
    }

    func testCursorMovementAllowsPrintableOverwriteAtMovedPosition() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("case \"D\":\n            cursorColumn = max(0, cursorColumn - parsed.value(at: 0, default: 1))"))
        XCTAssertTrue(source.contains("case \"G\", \"`\":\n            cursorColumn = min(screen.columns - 1, max(0, parsed.value(at: 0, default: 1) - 1))"))
        XCTAssertTrue(source.contains("case \"H\", \"f\":\n            cursorRow = min(screen.rows - 1, max(0, parsed.value(at: 0, default: 1) - 1))\n            cursorColumn = min(screen.columns - 1, max(0, parsed.value(at: 1, default: 1) - 1))"))
        XCTAssertTrue(source.contains("screen.set(character: character, row: cursorRow, column: cursorColumn, width: width, style: currentStyle)"))
        XCTAssertTrue(source.contains("markDirty(row: cursorRow)\n            cursorColumn += width"))
        XCTAssertFalse(source.contains("screen.insertCharacters(row: cursorRow, column: cursorColumn, count: width"))
    }

    func testTmuxStatusRedrawSupportsRepeatPrecedingGraphicCharacter() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let screenSource = try terminalScreenSource()

        XCTAssertTrue(surfaceSource.contains("case \"b\":\n            let written = screen.repeatPrecedingGraphicCharacter(row: cursorRow, column: cursorColumn, count: parsed.value(at: 0, default: 1))"))
        XCTAssertTrue(surfaceSource.contains("cursorColumn = min(screen.columns, cursorColumn + written)"))
        XCTAssertTrue(surfaceSource.contains("markDirty(row: cursorRow)"))
        XCTAssertTrue(screenSource.contains("mutating func repeatPrecedingGraphicCharacter(row: Int, column: Int, count: Int) -> Int"))
        XCTAssertTrue(screenSource.contains("source.character.terminalColumnWidth == 1"))
        XCTAssertTrue(screenSource.contains("style: source.style"))
    }

    func testTmuxStatusRedrawSupportsEraseCharacter() throws {
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(surfaceSource.contains("case \"X\":\n            let count = max(1, parsed.value(at: 0, default: 1))"))
        XCTAssertTrue(surfaceSource.contains("screen.clear(row: cursorRow, from: cursorColumn, through: cursorColumn + count - 1, style: currentStyle)"))
        XCTAssertTrue(surfaceSource.contains("markDirty(row: cursorRow)"))
    }

    func testFullModelRedrawFlagControlsDirtyRectInvalidation() throws {
        let metalSource = try terminalMetalViewSource()
        let surfaceSource = try terminalSurfaceViewSource()
        let debugSource = try debugOptionsSource()

        XCTAssertTrue(debugSource.contains("static let fullModelRedraw = flag(\"--debug-full-model-redraw\", env: \"KUROTTY_DEBUG_FULL_MODEL_REDRAW\")"))
        XCTAssertTrue(debugSource.contains("static let noDamage = flag(\"--debug-no-damage\", env: \"KUROTTY_DEBUG_NO_DAMAGE\")"))
        XCTAssertTrue(debugSource.contains("static let noScissor = flag(\"--debug-no-scissor\", env: \"KUROTTY_DEBUG_NO_SCISSOR\")"))
        XCTAssertTrue(surfaceSource.contains("renderer.diagnosticFullRedrawEnabled = DebugOptions.fullModelRedraw || AppConstants.Rendering.forceFullModelRedrawUntilDamageIsVerified"))
        XCTAssertTrue(metalSource.contains("var diagnosticFullRedrawEnabled = false {\n        didSet {\n            setNeedsDisplay(bounds)\n        }\n    }"))
        XCTAssertTrue(metalSource.contains("TerminalRenderDamageDiagnostics.make("))
        XCTAssertTrue(metalSource.contains("diagnosticFullRedrawEnabled: diagnosticFullRedrawEnabled"))
        XCTAssertTrue(metalSource.contains("scissorDisabled: scissorDisabled"))
        XCTAssertTrue(metalSource.contains("frame.damageMetadata.redrawPolicy("))
        XCTAssertTrue(metalSource.contains("policy.redrawDecision == .full ? [bounds] : frame.dirtyRects.map(\\.cgRect)"))
        XCTAssertTrue(metalSource.contains("for rect in submittedDisplayRects {\n            setNeedsDisplay(rect)\n        }"))
        XCTAssertTrue(metalSource.contains("var lastFrameDamageWasFullForDiagnostics: Bool {\n        terminalFrame.isFullDamage\n    }"))
        XCTAssertTrue(metalSource.contains("fullRedraw=%@"))
    }

    func testPerFrameMetalInstanceBuffersReuseStorageWhenByteLengthIsStable() throws {
        let metalSource = try terminalMetalViewSource()
        let atlasBufferSource = try functionBody(named: "rebuildAtlasBuffers", in: metalSource)

        XCTAssertTrue(metalSource.contains("private func updateSharedBuffer<T>(_ buffer: inout MTLBuffer?, with values: [T])"))
        XCTAssertTrue(metalSource.contains("private func updateSharedBuffer<T>(_ buffer: inout MTLBuffer?, with value: inout T)"))
        XCTAssertTrue(atlasBufferSource.contains("updateSharedBuffer(&atlasInstanceBuffer, with: instances)"))
        XCTAssertTrue(atlasBufferSource.contains("updateSharedBuffer(&backgroundInstanceBuffer, with: backgrounds)"))
        XCTAssertTrue(atlasBufferSource.contains("updateSharedBuffer(&decorationInstanceBuffer, with: decorations)"))
        XCTAssertTrue(atlasBufferSource.contains("updateSharedBuffer(&cursorInstanceBuffer, with: &cursor)"))
        XCTAssertTrue(atlasBufferSource.contains("updateSharedBuffer(&uniformsBuffer, with: &uniforms)"))
        XCTAssertFalse(atlasBufferSource.contains("makeBuffer(bytes:"))
    }

    func testMetalViewSkipsAtlasBufferRebuildWhenRenderInputsAreUnchanged() throws {
        let metalSource = try terminalMetalViewSource()
        let updateSource = try functionBody(named: "update", in: metalSource)
        let dirtySource = try functionBody(named: "atlasBuffersNeedRebuild", in: metalSource)
        let signatureSource = try functionBody(named: "makeAtlasBufferSignature", in: metalSource)

        XCTAssertTrue(metalSource.contains("private var lastAtlasBufferSignature: Int?"))
        XCTAssertTrue(updateSource.contains("let shouldRebuildAtlasBuffers = atlasBuffersNeedRebuild(for: frame)"))
        XCTAssertTrue(updateSource.contains("if shouldRebuildAtlasBuffers {\n            rebuildAtlasBuffers()\n        }"))
        XCTAssertFalse(updateSource.contains("synchronizeBackingScaleAndDrawableSize()\n        rebuildAtlasBuffers()"))
        XCTAssertTrue(dirtySource.contains("let nextSignature = makeAtlasBufferSignature(for: frame)"))
        XCTAssertTrue(dirtySource.contains("return nextSignature != lastAtlasBufferSignature"))
        XCTAssertFalse(dirtySource.contains("lastAtlasBufferSignature = nextSignature"))
        XCTAssertTrue(metalSource.contains("lastAtlasBufferSignature = makeAtlasBufferSignature(for: terminalFrame)"))
        XCTAssertTrue(signatureSource.contains("hasher.combine(frame.cursorColumn)"))
        XCTAssertTrue(signatureSource.contains("hasher.combine(frame.cursorRow)"))
        XCTAssertTrue(signatureSource.contains("hasher.combine(frame.cursorBlinkOn)"))
        XCTAssertTrue(signatureSource.contains("hasher.combine(frame.markedTextColumn)"))
        XCTAssertTrue(signatureSource.contains("hasher.combine(frame.markedText)"))
        XCTAssertTrue(signatureSource.contains("hasher.combine(frame.markedTextSelectedRange.location)"))
        XCTAssertTrue(signatureSource.contains("hasher.combine(backingScale)"))
        XCTAssertTrue(signatureSource.contains("hasher.combine(drawableSize.width)"))
        XCTAssertTrue(signatureSource.contains("hasher.combine(diagnosticPixelSnappingEnabled)"))
        XCTAssertTrue(signatureSource.contains("hasher.combine(diagnosticLinearGlyphSamplingEnabled)"))
        XCTAssertTrue(signatureSource.contains("return hasher.finalize()"))
    }

    func testScrollRegionIsTrackedForTuiStatusAndInputRows() throws {
        let source = try terminalSurfaceViewSource()
        let debugSource = try debugOptionsSource()

        XCTAssertTrue(source.contains("private var scrollRegionTop = 0"))
        XCTAssertTrue(source.contains("private var scrollRegionBottom = AppConstants.Terminal.defaultRows - 1"))
        XCTAssertTrue(source.contains("case \"r\":\n            setScrollRegion(parsed)"))
        XCTAssertTrue(source.contains("private func setScrollRegion(_ parsed: CsiParameters)"))
        XCTAssertTrue(source.contains("cursorRow = 0\n        cursorColumn = 0\n        markFullDamage()"))
        XCTAssertTrue(source.contains("resetScrollRegion()"))
        XCTAssertTrue(source.contains("Kurotty scroll region %@: top=%d bottom=%d rows=%d cursor=(%d,%d)"))
        XCTAssertTrue(debugSource.contains("static let scrollRegion = flag(\"--debug-scroll-region\", env: \"KUROTTY_DEBUG_SCROLL_REGION\")"))
    }

    func testScrollOperationsRespectActiveScrollRegion() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("if cursorRow >= scrollRegionTop && cursorRow == scrollRegionBottom"))
        XCTAssertTrue(source.contains("screen.scrollUpRegion(top: scrollRegionTop, bottom: scrollRegionBottom, style: currentStyle)"))
        XCTAssertTrue(source.contains("screen.scrollDownRegion(top: scrollRegionTop, bottom: scrollRegionBottom, style: currentStyle)"))
        XCTAssertTrue(source.contains("screen.scrollUpRegion(top: scrollRegionTop, bottom: scrollRegionBottom, count: parsed.value(at: 0, default: 1), style: currentStyle)"))
        XCTAssertTrue(source.contains("screen.scrollDownRegion(top: scrollRegionTop, bottom: scrollRegionBottom, count: parsed.value(at: 0, default: 1), style: currentStyle)"))
        XCTAssertTrue(source.contains("screen.insertLines(at: cursorRow, bottom: bottom, count: count, style: currentStyle)"))
        XCTAssertTrue(source.contains("screen.deleteLines(at: cursorRow, bottom: bottom, count: count, style: currentStyle)"))
        XCTAssertFalse(source.contains("case \"S\":\n            screen.scrollUp(count: parsed.value(at: 0, default: 1))"))
        XCTAssertFalse(source.contains("case \"T\":\n            screen.scrollDown(count: parsed.value(at: 0, default: 1))"))
    }

    func testPtyPrintableTextUsesGraphemeClustersInsteadOfUnicodeScalars() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let textWidthSource = try terminalTextWidthSource()

        XCTAssertTrue(surfaceSource.contains("for character in text {"))
        XCTAssertTrue(surfaceSource.contains("if parserState == .normal && character.isTerminalPrintableGrapheme"))
        XCTAssertTrue(surfaceSource.contains("appendPrintable(String(character))"))
        XCTAssertFalse(surfaceSource.contains("for scalar in text.unicodeScalars {\n            if consumeControl(scalar)"))
        XCTAssertTrue(textWidthSource.contains("private var firstBaseScalarForTerminalWidth: UnicodeScalar?"))
    }

    func testHangulAndCombiningWidthUseClusterPolicyInSurfaceAndMetal() throws {
        let textWidthSource = try terminalTextWidthSource()
        let surfaceSource = try terminalSurfaceViewSource()
        let metalSource = try terminalMetalViewSource()

        XCTAssertTrue(surfaceSource.contains("character.terminalColumnWidth"))
        XCTAssertTrue(metalSource.contains("column += character.terminalColumnWidth"))
        XCTAssertTrue(textWidthSource.contains("let widthScalar = firstBaseScalarForTerminalWidth ?? unicodeScalars.first"))
        XCTAssertTrue(textWidthSource.contains("if unicodeScalars.allSatisfy({ CharacterSet.nonBaseCharacters.contains($0) })"))
        XCTAssertTrue(textWidthSource.contains("(0xac00...0xd7a3).contains(value)"))
        XCTAssertTrue(textWidthSource.contains("return 2"))
    }

    func testCombiningMarksAndContinuationOverwriteDoNotLeaveSplitHangulCells() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let screenSource = try terminalScreenSource()

        XCTAssertTrue(surfaceSource.contains("screen.appendCombining(character: character, row: cursorRow, before: cursorColumn)"))
        XCTAssertTrue(screenSource.contains("private mutating func clearWideCellIfNeeded(row: Int, column: Int, style: TerminalTextStyle)"))
        XCTAssertTrue(screenSource.contains("guard cells[row][column].isContinuation else { return }"))
        XCTAssertTrue(screenSource.contains("cells[row][column + 1] = TerminalScreenCell(style: style)"))
        XCTAssertFalse(screenSource.contains("if column > 0 && cells[row][column - 1].isContinuation"))
        XCTAssertTrue(screenSource.contains("let merged = String(cells[row][leadColumn].character) + String(character)"))
    }

    func testTopAnchoredScrollRegionFeedsTerminalScrollback() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("private func shouldAppendScrollbackForActiveScrollRegion() -> Bool"))
        XCTAssertTrue(source.contains("scrollRegionTop == 0"))
        XCTAssertFalse(source.contains("!isUsingAlternateScreen && scrollRegionTop == 0"))
        XCTAssertTrue(source.contains("if shouldAppendScrollbackForActiveScrollRegion() {\n                appendScrollback(rows: removed)\n            }"))
        XCTAssertFalse(source.contains("guard !isUsingAlternateScreen else { return }\n        scrollbackRows.append(contentsOf: rows)"))
        XCTAssertFalse(source.contains("scrollRegionTop == 0 && scrollRegionBottom == screen.rows - 1"))
    }

    func testNativeScrollerReflectsTerminalScrollbackOffset() throws {
        let source = try terminalSurfaceViewSource()
        let coordinatorSource = try terminalScrollIndicatorCoordinatorSource()
        let tokens = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/KurottyApp/DesignTokens.swift"),
            encoding: .utf8
        )
        let thumbSource = try scrollIndicatorThumbViewSource()

        XCTAssertTrue(source.contains("private lazy var scrollIndicatorCoordinator = TerminalScrollIndicatorCoordinator"))
        XCTAssertTrue(source.contains("scrollIndicatorCoordinator.install(in: self)"))
        XCTAssertTrue(coordinatorSource.contains("private let scroller = NSScroller(frame: .zero)"))
        XCTAssertTrue(coordinatorSource.contains("scroller.target = self"))
        XCTAssertTrue(coordinatorSource.contains("scroller.action = #selector(scrollerDidChange(_:))"))
        XCTAssertTrue(coordinatorSource.contains("@objc private func scrollerDidChange(_ sender: NSScroller)"))
        XCTAssertTrue(coordinatorSource.contains("scroller.knobProportion"))
        XCTAssertTrue(source.contains("let maxOffset = maxScrollbackOffset()"))
        XCTAssertTrue(source.contains("private func maxScrollbackOffset(visibleRows: Int? = nil) -> Int"))
        XCTAssertTrue(source.contains("return max(0, contentRowCount - visibleCount)"))
        XCTAssertTrue(coordinatorSource.contains("let contentRows = visibleRows + maxScrollbackOffset"))
        XCTAssertTrue(coordinatorSource.contains("let proportionalKnob = CGFloat(visibleRows) / CGFloat(contentRows)"))
        XCTAssertTrue(coordinatorSource.contains("let minimumHeightKnob = DesignTokens.Component.terminalScrollerMinThumbHeightPX / trackHeight"))
        XCTAssertTrue(coordinatorSource.contains("DesignTokens.Component.terminalScrollerMinKnobProportion"))
        XCTAssertTrue(coordinatorSource.contains("scroller.knobProportion = knobProportion"))
        XCTAssertTrue(coordinatorSource.contains("scroller.doubleValue = max(0, min(1, 1 - CGFloat(scrollbackOffset) / CGFloat(maxScrollbackOffset)))"))
        XCTAssertTrue(coordinatorSource.contains("private let thumbView = ScrollIndicatorThumbView(frame: .zero)"))
        XCTAssertTrue(thumbSource.contains("private func updateAppearance()"))
        XCTAssertTrue(thumbSource.contains("color = DesignTokens.Color.scrollerThumb"))
        XCTAssertTrue(coordinatorSource.contains("let normalizedOffset = max(CGFloat.zero, min(CGFloat(1), CGFloat(scrollbackOffset) / CGFloat(maxScrollbackOffset)))"))
        XCTAssertTrue(coordinatorSource.contains("thumbView.frame = NSRect("))
        XCTAssertTrue(source.contains("scrollbackOffset = nextOffset"))
        XCTAssertTrue(coordinatorSource.contains("thumbView.onDragNormalizedOffset = { [weak self] normalizedOffset in"))
        XCTAssertTrue(source.contains("private func setScrollbackOffset(fromNormalizedOffset normalizedOffset: CGFloat)"))
        XCTAssertTrue(thumbSource.contains("override func mouseDragged(with event: NSEvent)"))
        XCTAssertTrue(thumbSource.contains("DesignTokens.Color.scrollerThumbHover"))
        XCTAssertTrue(thumbSource.contains("DesignTokens.Color.scrollerThumbActive"))
        XCTAssertTrue(tokens.contains("terminalScrollerWidthPX"))
        XCTAssertTrue(tokens.contains("terminalScrollerThumbWidthPX"))
        XCTAssertTrue(tokens.contains("terminalScrollerMinThumbHeightPX"))
        XCTAssertTrue(tokens.contains("terminalScrollerMinKnobProportion"))
        XCTAssertTrue(tokens.contains("scrollerThumb"))
        XCTAssertTrue(tokens.contains("scrollerThumbHover"))
        XCTAssertTrue(tokens.contains("scrollerThumbActive"))
    }

    func testPtyOutputDoesNotForceFollowWhenUserIsViewingScrollback() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("private var scrollbackRowsAppendedDuringOutput = 0"))
        XCTAssertTrue(source.contains("scrollbackRowsAppendedDuringOutput = 0"))
        XCTAssertTrue(source.contains("let shouldFollowOutput = scrollbackOffset == 0"))
        XCTAssertTrue(source.contains("if shouldFollowOutput {\n            scrollbackOffset = 0\n        }"))
        XCTAssertTrue(source.contains("let appendedScrollbackCount = scrollbackRowsAppendedDuringOutput"))
        XCTAssertTrue(source.contains("scrollbackOffset = min(maxScrollbackOffset(), scrollbackOffset + appendedScrollbackCount)\n            markFullDamage()"))
        XCTAssertFalse(source.contains("if !text.isEmpty {\n            scrollbackOffset = 0\n        }"))
        XCTAssertTrue(source.contains("updateScrollIndicator()"))
    }

    func testUserInputReturnsScrollbackToLiveCursorPosition() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("private func followLiveOutputForUserInput()"))
        XCTAssertTrue(source.contains("guard scrollbackOffset != 0 else { return }"))
        XCTAssertTrue(source.contains("scrollbackOffset = 0\n        markFullDamage()\n        updateScrollIndicator()\n        updateRendererFrame()"))
        XCTAssertTrue(source.contains("if recordsUserActivity {\n            followLiveOutputForUserInput()\n            recordKeyboardSelectionInputStartIfNeeded(for: text)\n            recordUserInput(text)\n        }"))
    }

    func testMarkedTextStartReturnsScrollbackToLiveCursorPosition() throws {
        let source = try terminalSurfaceViewSource()
        let setMarkedTextStart = try XCTUnwrap(source.range(of: "func setMarkedText"))
        let unmarkTextStart = try XCTUnwrap(source.range(of: "func unmarkText"))
        let setMarkedTextSource = source[setMarkedTextStart.lowerBound..<unmarkTextStart.lowerBound]

        XCTAssertTrue(setMarkedTextSource.contains("followLiveOutputForUserInput()"))
    }

    func testScrollbackTrimmingUsesBoundedRowStore() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let boundedScrollbackSource = try boundedScrollbackRowsSource()

        XCTAssertTrue(surfaceSource.contains("private var scrollbackRows = BoundedScrollbackRows()"))
        XCTAssertTrue(surfaceSource.contains("scrollbackRows.append(contentsOf: rows, limit: maxScrollbackRows)"))
        XCTAssertTrue(boundedScrollbackSource.contains("struct BoundedScrollbackRows"))
        XCTAssertTrue(boundedScrollbackSource.contains("mutating func append(contentsOf newRows: [[TerminalScreenCell]], limit: Int) -> Int"))
        XCTAssertTrue(boundedScrollbackSource.contains("func row(at index: Int) -> [TerminalScreenCell]?"))
        XCTAssertTrue(boundedScrollbackSource.contains("private mutating func compactStorageIfNeeded()"))
        XCTAssertFalse(surfaceSource.contains("scrollbackRows.rows + screen.cells"))
        XCTAssertFalse(boundedScrollbackSource.contains("Array(scrollbackRows.dropFirst"))
        XCTAssertFalse(boundedScrollbackSource.contains("scrollbackRows.removeFirst"))
        XCTAssertFalse(boundedScrollbackSource.contains("var rows: [[TerminalScreenCell]] {"))
    }

    func testSelectionTracksContentRowsWhenScrollingScrollback() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("private func visibleRowStartIndex(limit: Int) -> Int"))
        XCTAssertTrue(source.contains("let visibleStartRow = visibleRowStartIndex(limit: metrics.size.rows)"))
        XCTAssertTrue(source.contains("let position = TerminalCellPosition(row: visibleStartRow + row, column: column)"))
        XCTAssertTrue(source.contains("visibleRowStartIndex(limit: metrics.size.rows) + visibleRow"))
        XCTAssertFalse(source.contains("let position = TerminalCellPosition(row: row, column: column)"))
    }

    func testScreenRegionMutatorsPreserveRowsOutsideRegion() throws {
        let source = try terminalScreenSource()

        XCTAssertTrue(source.contains("mutating func scrollUpRegion(top: Int, bottom: Int, count: Int = 1, style: TerminalTextStyle = .default)"))
        XCTAssertTrue(source.contains("mutating func scrollDownRegion(top: Int, bottom: Int, count: Int = 1, style: TerminalTextStyle = .default)"))
        XCTAssertTrue(source.contains("mutating func insertLines(at row: Int, bottom: Int, count: Int, style: TerminalTextStyle = .default)"))
        XCTAssertTrue(source.contains("mutating func deleteLines(at row: Int, bottom: Int, count: Int, style: TerminalTextStyle = .default)"))
        XCTAssertTrue(source.contains("private func normalizedRegion(top: Int, bottom: Int) -> ClosedRange<Int>?"))
        XCTAssertTrue(source.contains("guard start <= end, start < columns, end >= 0 else { return }"))
        XCTAssertTrue(source.contains("cells.insert(\n            contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: amount),\n            at: region.upperBound - amount + 1\n        )"))
    }

    func testShellSessionStartsInHomeWithInteractiveZshUsability() throws {
        let shellSource = try shellSessionSource()
        let sessionSource = try terminalSessionSource()
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(sessionSource.contains("protocol TerminalSession: AnyObject"))
        XCTAssertFalse(shellSource.contains("protocol TerminalSession"))
        XCTAssertTrue(shellSource.contains("final class DarwinPTYTerminalSession: TerminalSession, @unchecked Sendable"))
        XCTAssertTrue(shellSource.contains("#if os(macOS)"))
        XCTAssertTrue(shellSource.contains("import Darwin"))
        XCTAssertTrue(surfaceSource.contains("private let shell: any TerminalSession = TerminalSessionFactory.makeDefaultSession()"))
        XCTAssertFalse(surfaceSource.contains("private let shell = DarwinPTYTerminalSession()"))
        XCTAssertFalse(surfaceSource.contains("DarwinPTYTerminalSession()"))
        XCTAssertTrue(shellSource.contains("FileManager.default.homeDirectoryForCurrentUser.path"))
        XCTAssertTrue(shellSource.contains("func start(workingDirectory requestedWorkingDirectory: String)"))
        XCTAssertTrue(shellSource.contains("let workingDirectory = ShellSettings.normalizedWorkingDirectory(requestedWorkingDirectory)"))
        XCTAssertTrue(shellSource.contains("runChildShell(workingDirectory: workingDirectory)"))
        XCTAssertFalse(shellSource.contains("AppConstants.Shell.defaultWorkingDirectory"))
        XCTAssertFalse(shellSource.contains("strdup(\"-f\")"))
        XCTAssertFalse(shellSource.contains("setenv(\"ZDOTDIR\","))
        XCTAssertFalse(shellSource.contains("zshrcContents"))
        XCTAssertTrue(shellSource.contains("setenv(\"HISTFILE\""))
        XCTAssertTrue(shellSource.contains("if chdir(workingDirectory) == 0"))
        XCTAssertTrue(shellSource.contains("actualWorkingDirectory = homeDirectory"))
        XCTAssertTrue(shellSource.contains("setenv(\"PWD\", actualWorkingDirectory, 1)"))
        XCTAssertTrue(shellSource.contains("let shellName = URL(fileURLWithPath: shell).lastPathComponent"))
        XCTAssertTrue(shellSource.contains("strdup(\"-\\(shellName)\")"))
        XCTAssertTrue(shellSource.contains("let interactive = strdup(\"-i\")"))
        XCTAssertTrue(shellSource.contains("unsetenv(\"ZDOTDIR\")"))
        XCTAssertFalse(shellSource.contains("compinit -d"))
        XCTAssertTrue(shellSource.contains("POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD"))
        XCTAssertTrue(shellSource.contains("ZSH_DISABLE_COMPFIX"))
        XCTAssertTrue(shellSource.contains("unsetenv(\"NO_COLOR\")"))
    }

    func testShellSessionReusesPTYReadBuffer() throws {
        let shellSource = try shellSessionSource()

        XCTAssertTrue(shellSource.contains("private var readBuffer = [UInt8](repeating: 0, count: AppConstants.Shell.ptyReadBufferSizeBytes)"))
        XCTAssertTrue(shellSource.contains("readBuffer.withUnsafeMutableBytes"))
        XCTAssertFalse(shellSource.contains("while true {\n            var buffer = [UInt8](repeating: 0, count: AppConstants.Shell.ptyReadBufferSizeBytes)"))
    }

    func testShellSessionEnqueuesPTYWritesOffCallerThread() throws {
        let shellSource = try shellSessionSource()

        XCTAssertTrue(shellSource.contains("private var pendingInput = Data()"))
        XCTAssertTrue(shellSource.contains("private var pendingInputStartIndex = 0"))
        XCTAssertTrue(shellSource.contains("private var pendingOutputStartIndex = 0"))
        XCTAssertTrue(shellSource.contains("private var isInputDrainScheduled = false"))
        XCTAssertTrue(shellSource.contains("private func enqueueInput(_ data: Data)"))
        XCTAssertTrue(shellSource.contains("private func drainInput()"))
        XCTAssertTrue(shellSource.contains("private func writeInputChunk(_ fd: Int32) -> Bool"))
        XCTAssertTrue(shellSource.contains("private func compactPendingInputIfNeeded()"))
        XCTAssertTrue(shellSource.contains("private func compactPendingOutputIfNeeded()"))
        XCTAssertTrue(shellSource.contains("readQueue.async { [weak self] in"))
        XCTAssertTrue(shellSource.contains("self?.enqueueInput(data)"))
        XCTAssertTrue(shellSource.contains("scheduleOutputDrain()"))
        XCTAssertTrue(shellSource.contains("readQueue.asyncAfter(deadline: .now() + .microseconds(Int(AppConstants.Shell.ptyWriteRetryDelayMicros)))"))
        XCTAssertFalse(shellSource.contains("Darwin.write(master"))
        XCTAssertFalse(shellSource.contains("usleep(AppConstants.Shell.ptyWriteRetryDelayMicros)"))
        XCTAssertFalse(shellSource.contains("pendingInput.removeFirst"))
        XCTAssertFalse(shellSource.contains("pendingOutput.removeFirst"))
    }

    func testSettingsOwnWindowSizeAndMenuDoesNotDuplicateSettings() throws {
        let menuSource = try mainMenuSource()
        XCTAssertFalse(menuSource.contains("settingsMenuItem.title = \"Settings\""))
        XCTAssertTrue(menuSource.contains("appMenu.addItem(NSMenuItem(title: \"Settings...\""))

        let settingsSource = try appSettingsSource()
        let settingsDefaultsSource = try settingsDefaultsSource()
        XCTAssertTrue(settingsDefaultsSource.contains("public static let schemaVersion = 9"))
        XCTAssertTrue(settingsSource.contains("static let schemaVersion = SettingsDefaults.schemaVersion"))
        XCTAssertTrue(settingsSource.contains("var shell: ShellSettings"))
        XCTAssertTrue(settingsSource.contains("workingDirectory: Defaults.shellWorkingDirectory"))
        XCTAssertTrue(settingsSource.contains("struct ShellSettings: Codable, Equatable"))
        XCTAssertTrue(settingsSource.contains("var workingDirectory: String"))
        XCTAssertTrue(settingsSource.contains("decodeIfPresent(ShellSettings.self, forKey: .shell) ?? .default"))
        XCTAssertFalse(settingsSource.contains("next.shell.workingDirectory = ShellSettings.normalizedWorkingDirectory(next.shell.workingDirectory)"))
        XCTAssertTrue(settingsSource.contains("var theme: String"))
        XCTAssertTrue(settingsSource.contains("TerminalThemePreset.lighttyName"))
        XCTAssertTrue(settingsSource.contains("static let lightty = TerminalColorSettings"))
        XCTAssertTrue(settingsSource.contains("foreground: \"#202124\""))
        XCTAssertTrue(settingsSource.contains("background: \"#FFFFFF\""))
        XCTAssertTrue(settingsSource.contains("cursor: \"#111111\""))
        XCTAssertTrue(settingsSource.contains("\"#AFA7F5\""))
        XCTAssertTrue(settingsSource.contains("\"#AB4634\""))
        XCTAssertTrue(settingsSource.contains("\"#55C236\""))
        XCTAssertTrue(settingsSource.contains("\"#9A4DB4\""))
        XCTAssertTrue(settingsSource.contains("\"#4FC3C7\""))
        XCTAssertTrue(settingsSource.contains("\"#A452BD\""))
        XCTAssertTrue(settingsSource.contains("\"#CF75D3\""))
        XCTAssertTrue(settingsSource.contains("\"#35B9BD\""))
        XCTAssertTrue(settingsSource.contains("normalizeTheme(&next, sourceSchemaVersion: sourceSchemaVersion)"))

        let surfaceSource = try terminalSurfaceViewSource()
        let textStyleSource = try terminalTextStyleSource()
        XCTAssertTrue(surfaceSource.contains("shell.start(workingDirectory: settings.shell.workingDirectory)"))
        XCTAssertTrue(surfaceSource.contains("let previousDefaultStyle = terminalDefaultStyle"))
        XCTAssertTrue(surfaceSource.contains("let previousAnsiColors = terminalAnsiColors"))
        XCTAssertTrue(surfaceSource.contains("let colorMap = TerminalStyleColorMap("))
        XCTAssertTrue(surfaceSource.contains("screen.remapColors(colorMap)"))
        XCTAssertTrue(surfaceSource.contains("scrollbackRows.remapColors(colorMap)"))
        XCTAssertTrue(surfaceSource.contains("screen.remapStyle(from: previousDefaultStyle, to: terminalDefaultStyle)"))
        XCTAssertTrue(surfaceSource.contains("scrollbackRows.remapStyle(from: previousDefaultStyle, to: terminalDefaultStyle)"))
        XCTAssertTrue(textStyleSource.contains("struct TerminalStyleColorMap"))
        XCTAssertTrue(textStyleSource.contains("func remapForeground(_ color: SIMD4<Float>)"))
        XCTAssertTrue(textStyleSource.contains("func remapBackground(_ color: SIMD4<Float>)"))
        XCTAssertTrue(textStyleSource.contains("dimmed(weighted, against: background)"))
        XCTAssertTrue(textStyleSource.contains("luminance(background) > 0.5"))
        XCTAssertTrue(textStyleSource.contains("dimBlendAmount(for: color)"))
        XCTAssertTrue(textStyleSource.contains("chroma(color) > 0.08"))
        XCTAssertTrue(surfaceSource.contains("if terminalDefaultStyle.isLightBackground, index >= 250"))
        XCTAssertTrue(surfaceSource.contains("private func lightThemeGray(_ index: Int)"))
        XCTAssertTrue(surfaceSource.contains("205 + (clamped - 250) * 6"))
        XCTAssertTrue(surfaceSource.contains("guard !parsed.isPrivate else { break }"))
        XCTAssertTrue(surfaceSource.contains("private var oscBuffer = \"\""))
        XCTAssertTrue(surfaceSource.contains("executeOsc(oscBuffer)"))
        XCTAssertTrue(surfaceSource.contains("case \"10\":"))
        XCTAssertTrue(surfaceSource.contains("case \"11\":"))
        XCTAssertTrue(surfaceSource.contains("rgb:"))
        XCTAssertTrue(surfaceSource.contains("terminalOscColor"))
        XCTAssertTrue(surfaceSource.contains("case \"n\":"))
        XCTAssertTrue(surfaceSource.contains("cursorPositionReport"))
        XCTAssertTrue(surfaceSource.contains("if !parsed.isPrivate, parsed.value(at: 0, default: 0) == 6"))
        XCTAssertTrue(surfaceSource.contains("case \"c\":"))
        XCTAssertTrue(surfaceSource.contains("TerminalDeviceAttributes.response(for: parsed)"))
        XCTAssertTrue(surfaceSource.contains("private func sendTerminalResponse(_ text: String)"))
        XCTAssertTrue(surfaceSource.contains("shell.canReceiveTerminalResponseWithoutEcho()"))

        XCTAssertTrue(settingsSource.contains("var window: WindowSettings"))
        XCTAssertTrue(settingsSource.contains("struct WindowSettings: Codable, Equatable"))
        XCTAssertTrue(settingsSource.contains("width: Defaults.windowWidth"))
        XCTAssertTrue(settingsSource.contains("height: Defaults.windowHeight"))
        XCTAssertTrue(settingsSource.contains("decodeIfPresent(WindowSettings.self, forKey: .window) ?? .default"))
        XCTAssertTrue(settingsSource.contains("next.window.width = min("))
        XCTAssertTrue(settingsSource.contains("next.window.height = min("))

        let windowSource = try terminalWindowControllerSource()
        XCTAssertTrue(windowSource.contains("AppSettingsStore.shared.load()"))
        XCTAssertTrue(windowSource.contains("contentRect: NSRect(x: 0, y: 0, width: settings.window.width, height: settings.window.height)"))
        XCTAssertTrue(windowSource.contains("private var chromeTheme: DesignTokens.ChromeTheme"))
        XCTAssertTrue(windowSource.contains("DesignTokens.ChromeTheme.theme(for: settings)"))
        XCTAssertTrue(windowSource.contains("window?.appearance = chromeTheme.windowAppearance"))
        XCTAssertTrue(windowSource.contains("private func applyChromeThemeToTabSplits(_ theme: DesignTokens.ChromeTheme)"))
        XCTAssertTrue(windowSource.contains("splitView.applyChromeTheme(theme)"))
        XCTAssertTrue(windowSource.contains("AppSettingsStore.didChangeNotification"))
        XCTAssertTrue(windowSource.contains("@objc private func settingsDidChange(_ notification: Notification)"))
        XCTAssertTrue(windowSource.contains("setContentSize(NSSize(width: settings.window.width, height: settings.window.height))"))
    }

    func testAppMenuIncludesNativeAboutPanelWithVersionAndIcon() throws {
        let menuSource = try mainMenuSource()
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: \"About \\(AppConstants.Bundle.displayName)\", action: #selector(AppDelegate.showAboutPanel), keyEquivalent: \"\")"))
        XCTAssertTrue(menuSource.contains("appMenu.addItem(.separator())"))

        let appDelegateSource = try appDelegateSource()
        XCTAssertTrue(appDelegateSource.contains("@objc func showAboutPanel()"))
        XCTAssertTrue(appDelegateSource.contains("NSApp.orderFrontStandardAboutPanel(options:"))
        XCTAssertTrue(appDelegateSource.contains(".applicationName: AppConstants.Bundle.displayName"))
        XCTAssertTrue(appDelegateSource.contains("options[.applicationIcon] = image"))
        XCTAssertTrue(appDelegateSource.contains(".version: AppConstants.Bundle.displayVersion(bundle: Bundle.main)"))

        let constantsSource = try appConstantsSource()
        XCTAssertTrue(constantsSource.contains("static let developmentVersion = \"development\""))
        XCTAssertTrue(constantsSource.contains("static let developmentBuild = \"dev\""))
        XCTAssertTrue(constantsSource.contains("static func displayVersion(bundle: Foundation.Bundle = .main) -> String"))
        XCTAssertTrue(constantsSource.contains("CFBundleShortVersionString"))
        XCTAssertTrue(constantsSource.contains("CFBundleVersion"))
    }

    func testAppMenuAndBundleMetadataWireSparkleUpdates() throws {
        let packageSource = try packageManifestSource()
        XCTAssertTrue(packageSource.contains(".package(url: \"https://github.com/sparkle-project/Sparkle\", from: \"2.9.3\")"))
        XCTAssertTrue(packageSource.contains(".product(name: \"Sparkle\", package: \"Sparkle\")"))

        let updateControllerSource = try updateControllerSource()
        XCTAssertTrue(updateControllerSource.contains("import Sparkle"))
        XCTAssertTrue(updateControllerSource.contains("private var updaterController: SPUStandardUpdaterController?"))
        XCTAssertTrue(updateControllerSource.contains("static func isConfigured(bundle: Bundle = .main) -> Bool"))
        XCTAssertTrue(updateControllerSource.contains("AppConstants.Bundle.sparklePublicKeyInfoKey"))
        XCTAssertTrue(updateControllerSource.contains("if isConfigured(bundle: bundle) {"))
        XCTAssertTrue(updateControllerSource.contains("startingUpdater: true"))
        XCTAssertTrue(updateControllerSource.contains("func checkForUpdates(_ sender: Any?)"))

        let appDelegateSource = try appDelegateSource()
        XCTAssertTrue(appDelegateSource.contains("private let updateController = UpdateController()"))
        XCTAssertTrue(appDelegateSource.contains("var canCheckForUpdates: Bool"))
        XCTAssertTrue(appDelegateSource.contains("@objc func checkForUpdates(_ sender: Any?)"))
        XCTAssertTrue(appDelegateSource.contains("updateController.checkForUpdates(sender)"))
        XCTAssertTrue(appDelegateSource.contains("자동 업데이트를 사용할 수 없습니다"))
        XCTAssertTrue(appDelegateSource.contains("정식 배포 빌드에서는 업데이트를 자동으로 내려받고 설치합니다."))
        XCTAssertTrue(appDelegateSource.contains("alert.addButton(withTitle: \"확인\")"))
        XCTAssertFalse(appDelegateSource.contains("showReleaseURL()"))
        XCTAssertFalse(appDelegateSource.contains("NSWorkspace.shared.open(url)"))

        let menuSource = try mainMenuSource()
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: \"Check for Updates...\", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: \"\")"))

        let constantsSource = try appConstantsSource()
        XCTAssertTrue(constantsSource.contains("static let sparkleFeedURL = \"https://github.com/skyepodium/kurotty/releases/latest/download/appcast.xml\""))
        XCTAssertTrue(constantsSource.contains("static let sparklePublicKeyInfoKey = \"SUPublicEDKey\""))
        XCTAssertTrue(constantsSource.contains("static let sparklePublicKeyEnvironmentName = \"KUROTTY_SPARKLE_PUBLIC_KEY\""))
        XCTAssertTrue(constantsSource.contains("static let sparkleFeedURLEnvironmentName = \"KUROTTY_SPARKLE_FEED_URL\""))
        XCTAssertFalse(constantsSource.contains("sparkleReleasesPageURL"))

        let installSource = try installAppScriptSource()
        XCTAssertTrue(installSource.contains("mkdir -p \"$APP_BUNDLE/Contents/MacOS\" \"$APP_BUNDLE/Contents/Resources\" \"$APP_BUNDLE/Contents/Frameworks\""))
        XCTAssertTrue(installSource.contains("cp -R \"$BUILD_DIR/Sparkle.framework\" \"$APP_BUNDLE/Contents/Frameworks/Sparkle.framework\""))
        XCTAssertTrue(installSource.contains("install_name_tool -add_rpath \"@executable_path/../Frameworks\" \"$APP_BUNDLE/Contents/MacOS/kurotty\""))
        XCTAssertTrue(installSource.contains("SPARKLE_FEED_URL=\"${KUROTTY_SPARKLE_FEED_URL:-https://github.com/skyepodium/kurotty/releases/latest/download/appcast.xml}\""))
        XCTAssertTrue(installSource.contains("<key>SUFeedURL</key>"))
        XCTAssertTrue(installSource.contains("<string>$SPARKLE_FEED_URL</string>"))
        XCTAssertTrue(installSource.contains("<key>SUPublicEDKey</key>"))
        XCTAssertTrue(installSource.contains("<string>$SPARKLE_PUBLIC_KEY</string>"))
        XCTAssertTrue(installSource.contains("<key>SUEnableAutomaticChecks</key>"))
        XCTAssertTrue(installSource.contains("<key>SUAutomaticallyUpdate</key>"))
        XCTAssertTrue(installSource.contains("<key>SUAllowsAutomaticUpdates</key>"))

        let packageReleaseSource = try scriptSource(named: "package-release")
        XCTAssertTrue(packageReleaseSource.contains("mkdir -p \"$DIST_DIR\" \"$WORK_DIR\" \"$APP_BUNDLE/Contents/MacOS\" \"$APP_BUNDLE/Contents/Resources\" \"$APP_BUNDLE/Contents/Frameworks\""))
        XCTAssertTrue(packageReleaseSource.contains("cp -R \"$swift_bin_path/Sparkle.framework\" \"$APP_BUNDLE/Contents/Frameworks/Sparkle.framework\""))
        XCTAssertTrue(packageReleaseSource.contains("install_name_tool -add_rpath \"@executable_path/../Frameworks\" \"$APP_BUNDLE/Contents/MacOS/kurotty\""))
        XCTAssertTrue(packageReleaseSource.contains("SPARKLE_PUBLIC_KEY=\"${KUROTTY_SPARKLE_PUBLIC_KEY:-11d8W6utP7UYrBIN+uA7cLTjBTrBn4vPG1OWTr2fV6A=}\""))
        XCTAssertTrue(installSource.contains("SPARKLE_PUBLIC_KEY=\"${KUROTTY_SPARKLE_PUBLIC_KEY:-11d8W6utP7UYrBIN+uA7cLTjBTrBn4vPG1OWTr2fV6A=}\""))
        XCTAssertTrue(packageReleaseSource.contains("SPARKLE_PRIVATE_KEY=\"${KUROTTY_SPARKLE_PRIVATE_KEY:-}\""))
        XCTAssertTrue(packageReleaseSource.contains("SPARKLE_ARTIFACT_GENERATE_APPCAST=\"$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast\""))
        XCTAssertTrue(packageReleaseSource.contains("generate_sparkle_appcast()"))
        XCTAssertTrue(packageReleaseSource.contains("resolve_sparkle_generate_appcast()"))
        XCTAssertTrue(packageReleaseSource.contains("find \"$WORK_DIR\" \"$ROOT_DIR/.build\""))
        XCTAssertTrue(packageReleaseSource.contains("\"$SPARKLE_GENERATE_APPCAST\" --ed-key-file - \"$archives_dir\""))
        XCTAssertTrue(packageReleaseSource.contains("SPARKLE_CONFIGURED_UPDATES=\"1\""))
        XCTAssertTrue(packageReleaseSource.contains("if [[ -z \"$SPARKLE_PUBLIC_KEY\" ]]; then"))
        XCTAssertTrue(packageReleaseSource.contains("Skipping Sparkle metadata/appcast: KUROTTY_SPARKLE_PUBLIC_KEY is not set."))
        XCTAssertTrue(packageReleaseSource.contains("xcodebuild -project \"$ROOT_DIR/.build/checkouts/Sparkle/Sparkle.xcodeproj\""))
        XCTAssertTrue(packageReleaseSource.contains("-scheme generate_appcast"))
        XCTAssertTrue(packageReleaseSource.contains("<key>SUFeedURL</key>"))
        XCTAssertTrue(packageReleaseSource.contains("SUPublicEDKey"))
        XCTAssertTrue(packageReleaseSource.contains("<key>SUEnableAutomaticChecks</key>"))
        XCTAssertTrue(packageReleaseSource.contains("<key>SUAutomaticallyUpdate</key>"))
        XCTAssertTrue(packageReleaseSource.contains("<key>SUAllowsAutomaticUpdates</key>"))
        XCTAssertTrue(packageReleaseSource.contains("generate_appcast"))
    }

    func testSettingsEditorAvoidsUnboundedTextLayout() throws {
        let preferencesSource = try preferencesWindowControllerSource()

        XCTAssertTrue(preferencesSource.contains("textView.isHorizontallyResizable = false"))
        XCTAssertTrue(preferencesSource.contains("textView.textContainer?.widthTracksTextView = true"))
        XCTAssertTrue(preferencesSource.contains("textView.textContainer?.heightTracksTextView = false"))
        XCTAssertFalse(preferencesSource.contains("textContainer?.containerSize = NSSize(\n            width: CGFloat.greatestFiniteMagnitude"))
    }

    func testSettingsEditorAutosavesValidEditsWithoutManualSaveOrReloadButtons() throws {
        let preferencesSource = try preferencesWindowControllerSource()

        XCTAssertTrue(preferencesSource.contains("NSTextViewDelegate"))
        XCTAssertTrue(preferencesSource.contains("textView.delegate = self"))
        XCTAssertTrue(preferencesSource.contains("func textDidChange(_ notification: Notification)"))
        XCTAssertTrue(preferencesSource.contains("scheduleAutosave()"))
        XCTAssertTrue(preferencesSource.contains("try store.save(rawJSON: textView.string)"))
        XCTAssertFalse(preferencesSource.contains("NSButton(title: \"Save\""))
        XCTAssertFalse(preferencesSource.contains("NSButton(title: \"Reload\""))
        XCTAssertFalse(preferencesSource.contains("#selector(saveToDisk)"))
        XCTAssertFalse(preferencesSource.contains("#selector(reloadFromDisk)"))
    }

    func testTerminalWindowCommandsExposeTabAndSplitShortcuts() throws {
        let menuSource = try mainMenuSource()
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: \"New Tab\", action: #selector(AppDelegate.newTab), keyEquivalent: \"t\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: \"Close Pane or Tab\", action: #selector(AppDelegate.closeCurrentPane), keyEquivalent: \"w\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: \"Split Vertically\", action: #selector(AppDelegate.splitVertically), keyEquivalent: \"d\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: \"Split Horizontally\", action: #selector(AppDelegate.splitHorizontally), keyEquivalent: \"D\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: \"Previous Tab\", action: #selector(AppDelegate.selectPreviousTab), keyEquivalent: \"[\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: \"Next Tab\", action: #selector(AppDelegate.selectNextTab), keyEquivalent: \"]\")"))

        let delegateSource = try appDelegateSource()
        XCTAssertTrue(delegateSource.contains("@objc func closeCurrentTab()"))
        XCTAssertTrue(delegateSource.contains("@objc func closeCurrentPane()"))
        XCTAssertTrue(delegateSource.contains("@objc func selectNextTab()"))
        XCTAssertTrue(delegateSource.contains("@objc func selectPreviousTab()"))
    }

    func testTerminalWindowShowsVisibleTabBarWhenMultipleTabsExist() throws {
        let windowSource = try terminalWindowControllerSource()
        let designSource = try designTokensSource()

        XCTAssertTrue(windowSource.contains("final class TerminalWindowController: NSWindowController, NSTabViewDelegate"))
        XCTAssertTrue(windowSource.contains("window?.appearance = chromeTheme.windowAppearance"))
        XCTAssertTrue(windowSource.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertTrue(windowSource.contains("private let tabBarView = NSView()"))
        XCTAssertTrue(windowSource.contains("private let tabStackView = NSStackView()"))
        XCTAssertTrue(windowSource.contains("tabBarView.layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor"))
        XCTAssertTrue(windowSource.contains("tabBarView.layer?.borderColor = chromeTheme.borderHairline.cgColor"))
        XCTAssertTrue(windowSource.contains("tabBarHeightConstraint?.constant = tabView.numberOfTabViewItems > 1"))
        XCTAssertTrue(windowSource.contains("tabBarView.isHidden = tabView.numberOfTabViewItems <= 1"))
        XCTAssertTrue(windowSource.contains("makeTabItemView(title: item.label, index: index, isSelected:"))
        XCTAssertTrue(windowSource.contains("private final class TerminalTabItemView: NSView"))
        XCTAssertTrue(windowSource.contains("ChromeIconButton(title: \"+\""))
        XCTAssertTrue(windowSource.contains("private let closeButton = ChromeIconButton(title: \"×\""))
        XCTAssertTrue(windowSource.contains("addButton.hoverBackgroundColor = chromeTheme.activeIndicator.withAlphaComponent(0.18)"))
        XCTAssertTrue(windowSource.contains("closeButton.hoverBackgroundColor = chromeTheme.activeIndicator.withAlphaComponent(0.18)"))
        XCTAssertTrue(try chromeIconButtonSource().contains("override func resetCursorRects()"))
        XCTAssertTrue(try chromeIconButtonSource().contains("addCursorRect(bounds, cursor: .pointingHand)"))
        XCTAssertTrue(windowSource.contains("override func updateTrackingAreas()"))
        XCTAssertTrue(windowSource.contains("override func mouseEntered(with event: NSEvent)"))
        XCTAssertTrue(windowSource.contains("override func mouseExited(with event: NSEvent)"))
        XCTAssertTrue(windowSource.contains("let location = convert(event.locationInWindow, from: nil)"))
        XCTAssertTrue(windowSource.contains("guard !bounds.contains(location) else { return }"))
        XCTAssertTrue(windowSource.contains("private func updateAppearance()"))
        XCTAssertTrue(windowSource.contains("layer?.cornerRadius = DesignTokens.Component.terminalTabCornerRadiusPX"))
        XCTAssertTrue(windowSource.contains("chromeTheme.activeIndicator.cgColor"))
        XCTAssertTrue(windowSource.contains("chromeTheme.activeTabBackground"))
        XCTAssertTrue(windowSource.contains("chromeTheme.inactiveTabHoverBackground"))
        XCTAssertTrue(windowSource.contains("onSelect: { [weak self] in self?.selectTab(at: index) }"))
        XCTAssertTrue(windowSource.contains("onClose: { [weak self] in self?.closeTab(at: index) }"))
        XCTAssertTrue(windowSource.contains("private func selectTab(at index: Int)"))
        XCTAssertTrue(windowSource.contains("private func closeTab(at index: Int)"))
        XCTAssertTrue(windowSource.contains("if closeButton.frame.contains(location)"))
        XCTAssertTrue(windowSource.contains("onClose()"))
        XCTAssertTrue(windowSource.contains("return"))
        XCTAssertTrue(windowSource.contains("@objc private func newTabButtonPressed(_ sender: NSButton)"))
        XCTAssertTrue(windowSource.contains("tabView.selectTabViewItem(at: index)"))
        XCTAssertTrue(windowSource.contains("private func observeTerminalTitles()"))
        XCTAssertTrue(windowSource.contains("@objc private func terminalTitleDidChange(_ notification: Notification)"))
        XCTAssertTrue(windowSource.contains("private func tabItem(containing surface: TerminalSurfaceView) -> NSTabViewItem?"))
        XCTAssertTrue(windowSource.contains("TerminalSurfaceView.titleDidChangeNotification"))
        XCTAssertTrue(windowSource.contains("TerminalSurfaceView.titleNotificationKey"))
        XCTAssertTrue(windowSource.contains("window?.title = tabViewItem?.label ?? AppConstants.Bundle.displayName"))

        XCTAssertTrue(designSource.contains("terminalTabBarHeightPX"))
        XCTAssertTrue(designSource.contains("terminalTabHeightPX"))
        XCTAssertTrue(designSource.contains("terminalTabCornerRadiusPX"))
        XCTAssertTrue(designSource.contains("terminalTabMinWidthPX"))
        XCTAssertTrue(designSource.contains("terminalTabMaxWidthPX"))
        XCTAssertTrue(designSource.contains("terminalTabPlusWidthPX"))
        XCTAssertTrue(designSource.contains("terminalTabCloseWidthPX"))
        XCTAssertTrue(designSource.contains("terminalTabStackGapPX"))
        XCTAssertTrue(designSource.contains("terminalTabStackInsetTopPX"))
        XCTAssertTrue(designSource.contains("terminalTabBorderWidthPX"))
        XCTAssertTrue(designSource.contains("terminalTabSelectedBarHeightPX"))
        XCTAssertTrue(designSource.contains("topChromeBackground"))
        XCTAssertTrue(designSource.contains("31.0 / 255.0"))
        XCTAssertTrue(designSource.contains("34.0 / 255.0"))
        XCTAssertTrue(designSource.contains("43.0 / 255.0"))
        XCTAssertTrue(designSource.contains("activeTabBackground"))
        XCTAssertTrue(designSource.contains("inactiveTabBackground"))
        XCTAssertTrue(designSource.contains("accentBlue"))
        XCTAssertTrue(designSource.contains("accentPurple"))
        XCTAssertTrue(designSource.contains("borderHairline"))
    }

    func testTerminalSurfacePublishesOscTitleAndDirectoryForTabs() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let paneSource = try terminalPaneViewSource()
        let splitSource = try splitTerminalViewSource()

        XCTAssertTrue(surfaceSource.contains("static let titleDidChangeNotification"))
        XCTAssertTrue(surfaceSource.contains("static let focusDidChangeNotification"))
        XCTAssertTrue(surfaceSource.contains("static let titleNotificationKey"))
        XCTAssertTrue(surfaceSource.contains("override func becomeFirstResponder() -> Bool"))
        XCTAssertTrue(surfaceSource.contains("case \"0\", \"1\", \"2\":"))
        XCTAssertTrue(surfaceSource.contains("case \"7\":"))
        XCTAssertTrue(surfaceSource.contains("private var shellIntegration = TerminalShellIntegration("))
        XCTAssertTrue(surfaceSource.contains("private func dispatchTerminalIntegrationOsc(_ command: String) -> TerminalOSCDispatcher.Event"))
        XCTAssertTrue(surfaceSource.contains("TerminalOSCDispatcher("))
        XCTAssertTrue(surfaceSource.contains("TerminalOSC52Policy(policy: securityPolicy)"))
        XCTAssertTrue(surfaceSource.contains("shellIntegration = dispatcher.shellIntegration"))
        XCTAssertTrue(surfaceSource.contains("if case let .shellIntegration(.workingDirectoryChanged(path)) = integrationEvent"))
        XCTAssertTrue(surfaceSource.contains("currentWorkingDirectory = path"))
        XCTAssertTrue(surfaceSource.contains("publishTitle()"))
        XCTAssertTrue(surfaceSource.contains("displayTitle()"))

        XCTAssertTrue(paneSource.contains("var terminalSurface: TerminalSurfaceView"))
        XCTAssertTrue(splitSource.contains("var primaryTerminalSurface: TerminalSurfaceView?"))
        XCTAssertTrue(splitSource.contains("func containsTerminalSurface(_ surface: TerminalSurfaceView) -> Bool"))
    }

    func testLayoutOnlyWorkspaceSnapshotDoesNotPersistRuntimeTitles() throws {
        let windowSource = try terminalWindowControllerSource()
        let paneSource = try terminalPaneViewSource()
        let workspaceDescriptorSource = try XCTUnwrap(
            windowSource.range(
                of: "private func layoutOnlyTabDescriptors()"
            ).flatMap { start in
                windowSource.range(of: "private func tabID", range: start.upperBound..<windowSource.endIndex).map { end in
                    String(windowSource[start.lowerBound..<end.lowerBound])
                }
            }
        )

        XCTAssertTrue(windowSource.contains("func layoutOnlyWorkspaceDescriptor() -> WorkspaceSnapshotCoordinator.WorkspaceDescriptor"))
        XCTAssertTrue(windowSource.contains("title: nil"))
        XCTAssertFalse(windowSource.contains("title: window?.title"))
        XCTAssertFalse(workspaceDescriptorSource.contains("title: item.label"))
        XCTAssertTrue(paneSource.contains("func layoutOnlyDescriptor(id: String) -> WorkspaceSnapshotCoordinator.PaneDescriptor"))
        XCTAssertFalse(paneSource.contains("title: displayTitle"))
    }

    func testFocusedTerminalDispatchesWindowShortcutsBeforePtyInput() throws {
        let dispatcherSource = try terminalCommandDispatcherSource()
        let registrySource = try terminalCommandRegistrySource()
        XCTAssertTrue(dispatcherSource.contains("enum TerminalPaneFocusDirection"))
        XCTAssertTrue(dispatcherSource.contains("case left"))
        XCTAssertTrue(dispatcherSource.contains("case right"))
        XCTAssertTrue(dispatcherSource.contains("case up"))
        XCTAssertTrue(dispatcherSource.contains("case down"))
        XCTAssertTrue(dispatcherSource.contains("windowCommand(for: event)"))
        XCTAssertTrue(dispatcherSource.contains("TerminalCommandRegistry = .default"))
        XCTAssertTrue(registrySource.contains("enum TerminalWindowCommandID"))
        XCTAssertTrue(registrySource.contains("case newTab = \"window.newTab\""))
        XCTAssertTrue(registrySource.contains("case focusPaneLeft = \"window.focusPane.left\""))
        XCTAssertTrue(registrySource.contains("TerminalCommandShortcut(keyEquivalent: \"t\", modifiers: .command)"))
        XCTAssertTrue(registrySource.contains("TerminalCommandShortcut(keyEquivalent: \"d\", modifiers: .command)"))
        XCTAssertTrue(registrySource.contains("TerminalCommandShortcut(keyEquivalent: \"d\", modifiers: [.command, .shift])"))
        XCTAssertTrue(registrySource.contains("TerminalCommandShortcut(keyCode: 123, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras)"))
        XCTAssertTrue(dispatcherSource.contains("controller.focusPane(direction)"))
        XCTAssertTrue(dispatcherSource.contains("controller.newTab()"))
        XCTAssertTrue(dispatcherSource.contains("controller.splitVertically()"))
        XCTAssertTrue(dispatcherSource.contains("controller.splitHorizontally()"))
        XCTAssertTrue(dispatcherSource.contains("controller.closeCurrentPane()"))
        XCTAssertTrue(dispatcherSource.contains("controller.selectPreviousTab()"))
        XCTAssertTrue(dispatcherSource.contains("controller.selectNextTab()"))

        let surfaceSource = try terminalSurfaceViewSource()
        XCTAssertTrue(surfaceSource.contains("TerminalCommandDispatcher.dispatchWindowCommand(from: self, event: event)"))

        let inputSource = try terminalInputViewSource()
        XCTAssertTrue(inputSource.contains("TerminalCommandDispatcher.dispatchWindowCommand(from: self, event: event)"))
    }

    func testTmuxPrefixCommandsAreExposedThroughMenuAndActivePane() throws {
        let constantsSource = try appConstantsSource()
        XCTAssertTrue(constantsSource.contains("enum Tmux"))
        XCTAssertTrue(constantsSource.contains("static let prefix = \"\\u{2}\""))
        XCTAssertTrue(constantsSource.contains("static let newWindowSequence = \"\\u{2}c\""))
        XCTAssertTrue(constantsSource.contains("static let splitHorizontallySequence = \"\\u{2}\\\"\""))
        XCTAssertTrue(constantsSource.contains("static let splitVerticallySequence = \"\\u{2}%\""))
        XCTAssertTrue(constantsSource.contains("static let previousWindowSequence = \"\\u{2}p\""))
        XCTAssertTrue(constantsSource.contains("static let nextWindowSequence = \"\\u{2}n\""))
        XCTAssertTrue(constantsSource.contains("static let detachClientSequence = \"\\u{2}d\""))
        XCTAssertTrue(constantsSource.contains("static let attachOrCreateSessionCommand = \"tmux new-session -A -s kurotty\\r\""))
        XCTAssertTrue(constantsSource.contains("static let listSessionsCommand = \"tmux list-sessions\\r\""))
        XCTAssertTrue(constantsSource.contains("static let applyKurottyThemeCommand = ["))
        XCTAssertTrue(constantsSource.contains("tmux set-option status-style bg=\\(themeStatusBackgroundColor),fg=\\(themeStatusForegroundColor)"))
        XCTAssertTrue(constantsSource.contains("tmux set-option status-justify left"))
        XCTAssertTrue(constantsSource.contains("tmux set-option window-status-format ''"))
        XCTAssertTrue(constantsSource.contains("tmux set-option window-status-current-format ''"))
        XCTAssertTrue(constantsSource.contains("tmux set-option status-left '[#S] #{window_index}:#{window_name}#{window_flags} '"))
        XCTAssertTrue(constantsSource.contains("tmux set-option status-right ' %H:%M '"))
        XCTAssertFalse(constantsSource.contains("tmux set-option -g"))

        let menuSource = try mainMenuSource()
        XCTAssertTrue(menuSource.contains("NSMenu(title: AppConstants.Tmux.menuTitle)"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppConstants.Tmux.attachOrCreateSessionMenuTitle, action: #selector(AppDelegate.tmuxAttachOrCreateSession), keyEquivalent: \"t\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppConstants.Tmux.listSessionsMenuTitle, action: #selector(AppDelegate.tmuxListSessions), keyEquivalent: \"l\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppConstants.Tmux.applyKurottyThemeMenuTitle, action: #selector(AppDelegate.tmuxApplyKurottyTheme), keyEquivalent: \"p\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppConstants.Tmux.newWindowMenuTitle, action: #selector(AppDelegate.tmuxNewWindow), keyEquivalent: \"n\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppConstants.Tmux.splitHorizontallyMenuTitle, action: #selector(AppDelegate.tmuxSplitHorizontally), keyEquivalent: \"d\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppConstants.Tmux.splitVerticallyMenuTitle, action: #selector(AppDelegate.tmuxSplitVertically), keyEquivalent: \"d\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppConstants.Tmux.previousWindowMenuTitle, action: #selector(AppDelegate.tmuxPreviousWindow), keyEquivalent: \"[\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppConstants.Tmux.nextWindowMenuTitle, action: #selector(AppDelegate.tmuxNextWindow), keyEquivalent: \"]\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppConstants.Tmux.detachClientMenuTitle, action: #selector(AppDelegate.tmuxDetachClient), keyEquivalent: \"w\")"))
        XCTAssertTrue(menuSource.contains("attachTmux.keyEquivalentModifierMask = [.command, .option]"))
        XCTAssertTrue(menuSource.contains("listTmux.keyEquivalentModifierMask = [.command, .option]"))
        XCTAssertTrue(menuSource.contains("applyTmuxTheme.keyEquivalentModifierMask = [.command, .option]"))
        XCTAssertTrue(menuSource.contains("newTmuxWindow.keyEquivalentModifierMask = [.command, .option]"))
        XCTAssertTrue(menuSource.contains("horizontalTmuxSplit.keyEquivalentModifierMask = [.command, .option, .shift]"))
        XCTAssertTrue(menuSource.contains("verticalTmuxSplit.keyEquivalentModifierMask = [.command, .option]"))
        XCTAssertTrue(menuSource.contains("previousTmuxWindow.keyEquivalentModifierMask = [.command, .option]"))
        XCTAssertTrue(menuSource.contains("nextTmuxWindow.keyEquivalentModifierMask = [.command, .option]"))
        XCTAssertTrue(menuSource.contains("detachTmux.keyEquivalentModifierMask = [.command, .option]"))

        let delegateSource = try appDelegateSource()
        XCTAssertTrue(delegateSource.contains("@objc func tmuxAttachOrCreateSession()"))
        XCTAssertTrue(delegateSource.contains("sendTextToActivePane(AppConstants.Tmux.attachOrCreateSessionCommand)"))
        XCTAssertTrue(delegateSource.contains("@objc func tmuxListSessions()"))
        XCTAssertTrue(delegateSource.contains("sendTextToActivePane(AppConstants.Tmux.listSessionsCommand)"))
        XCTAssertTrue(delegateSource.contains("@objc func tmuxApplyKurottyTheme()"))
        XCTAssertTrue(delegateSource.contains("sendTextToActivePane(AppConstants.Tmux.applyKurottyThemeCommand)"))
        XCTAssertTrue(delegateSource.contains("@objc func tmuxNewWindow()"))
        XCTAssertTrue(delegateSource.contains("sendTmuxSequence(AppConstants.Tmux.newWindowSequence)"))
        XCTAssertTrue(delegateSource.contains("@objc func tmuxSplitHorizontally()"))
        XCTAssertTrue(delegateSource.contains("sendTmuxSequence(AppConstants.Tmux.splitHorizontallySequence)"))
        XCTAssertTrue(delegateSource.contains("@objc func tmuxSplitVertically()"))
        XCTAssertTrue(delegateSource.contains("sendTmuxSequence(AppConstants.Tmux.splitVerticallySequence)"))
        XCTAssertTrue(delegateSource.contains("@objc func tmuxPreviousWindow()"))
        XCTAssertTrue(delegateSource.contains("sendTmuxSequence(AppConstants.Tmux.previousWindowSequence)"))
        XCTAssertTrue(delegateSource.contains("@objc func tmuxNextWindow()"))
        XCTAssertTrue(delegateSource.contains("sendTmuxSequence(AppConstants.Tmux.nextWindowSequence)"))
        XCTAssertTrue(delegateSource.contains("@objc func tmuxDetachClient()"))
        XCTAssertTrue(delegateSource.contains("sendTmuxSequence(AppConstants.Tmux.detachClientSequence)"))

        let windowSource = try terminalWindowControllerSource()
        XCTAssertTrue(windowSource.contains("func sendTextToActivePane(_ text: String)"))
        XCTAssertTrue(windowSource.contains("currentSplitView()?.sendTextToActivePane(text)"))

        let splitSource = try splitTerminalViewSource()
        XCTAssertTrue(splitSource.contains("func sendTextToActivePane(_ text: String)"))
        XCTAssertTrue(splitSource.contains("activePane() ?? firstPane()"))
        XCTAssertTrue(splitSource.contains("pane.sendText(text)"))

        let paneSource = try terminalPaneViewSource()
        XCTAssertTrue(paneSource.contains("func sendText(_ text: String)"))
        XCTAssertTrue(paneSource.contains("terminalSurfaceView.sendText(text)"))

        let surfaceSource = try terminalSurfaceViewSource()
        XCTAssertTrue(surfaceSource.contains("func sendText(_ text: String)"))
        XCTAssertTrue(surfaceSource.contains("send(text)"))
    }

    func testOnlyFocusedTerminalHandlesPasteKeyEquivalent() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        XCTAssertTrue(surfaceSource.contains("guard window?.firstResponder === self else"))
        XCTAssertTrue(surfaceSource.contains("return handleCommandKey(event) || handleKeyEquivalentTerminalControl(event) || super.performKeyEquivalent(with: event)"))
        XCTAssertTrue(surfaceSource.contains("private func handleKeyEquivalentTerminalControl(_ event: NSEvent) -> Bool"))
        XCTAssertTrue(surfaceSource.contains("if let commandControlText = TerminalTextInputRouter.commandShortcutControlText(for: event) {\n            resetMarkedTextForInputSourceChange()\n            send(commandControlText)\n            return true\n        }"))
        XCTAssertTrue(surfaceSource.contains("guard !hasMarkedText() else"))

        let inputSource = try terminalInputViewSource()
        XCTAssertTrue(inputSource.contains("guard window?.firstResponder === self else"))
        XCTAssertTrue(inputSource.contains("return handleCommandKey(event) || handleKeyEquivalentTerminalControl(event) || super.performKeyEquivalent(with: event)"))
        XCTAssertTrue(inputSource.contains("private func handleKeyEquivalentTerminalControl(_ event: NSEvent) -> Bool"))
        XCTAssertTrue(inputSource.contains("if let commandControlText = TerminalTextInputRouter.commandShortcutControlText(for: event) {\n            resetMarkedTextForInputSourceChange()\n            core.feed(commandControlText)\n            return true\n        }"))
    }

    func testEscapeKeyIsSentToTerminalFromAppKitCancelOperation() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let inputSource = try terminalInputViewSource()
        let routerSource = try terminalTextInputRouterSource()
        let encoderSource = try terminalKeyEncoderSource()

        XCTAssertTrue(surfaceSource.contains("if selector == #selector(cancelOperation(_:)) {\n            resetMarkedTextForInputSourceChange()\n        }"))
        XCTAssertTrue(inputSource.contains("if selector == #selector(cancelOperation(_:)) {\n            resetMarkedTextForInputSourceChange()\n        }"))
        XCTAssertTrue(encoderSource.contains("case #selector(NSResponder.cancelOperation(_:)):\n            return \"\\u{1b}\""))
        XCTAssertTrue(surfaceSource.contains("TerminalTextInputRouter.terminalControlText(for: event)"))
        XCTAssertTrue(inputSource.contains("TerminalTextInputRouter.terminalControlText(for: event)"))
        XCTAssertTrue(routerSource.contains("case 0x5b:\n            return \"\\u{1b}\""))
    }

    func testCommandShortcutsAndShiftArrowsUseTerminalControlFallbacks() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let inputSource = try terminalInputViewSource()
        let routerSource = try terminalTextInputRouterSource()
        let encoderSource = try terminalKeyEncoderSource()
        let registrySource = try terminalCommandRegistrySource()

        XCTAssertTrue(routerSource.contains("static func latinKeyEquivalent(for event: NSEvent) -> String?"))
        XCTAssertTrue(routerSource.contains("static func commandShortcutControlText(for event: NSEvent) -> String?"))
        XCTAssertTrue(encoderSource.contains("32: \"u\""))
        XCTAssertTrue(encoderSource.contains("31: \"o\""))
        XCTAssertTrue(registrySource.contains("TerminalTextInputRouter.latinKeyEquivalent(for: event)"))

        XCTAssertTrue(surfaceSource.contains("TerminalTextInputRouter.commandShortcutControlText(for: event)"))
        XCTAssertTrue(inputSource.contains("TerminalTextInputRouter.commandShortcutControlText(for: event)"))
        XCTAssertTrue(surfaceSource.contains("TerminalKeyEncoder.sequence(for: selector)"))
        XCTAssertTrue(inputSource.contains("TerminalKeyEncoder.sequence(for: selector)"))
        XCTAssertTrue(encoderSource.contains("case #selector(NSResponder.moveUpAndModifySelection(_:)):\n            return \"\\u{1b}[1;2A\""))
        XCTAssertTrue(encoderSource.contains("case #selector(NSResponder.moveDownAndModifySelection(_:)):\n            return \"\\u{1b}[1;2B\""))
        XCTAssertTrue(encoderSource.contains("case #selector(NSResponder.moveRightAndModifySelection(_:)):\n            return \"\\u{1b}[1;2C\""))
        XCTAssertTrue(encoderSource.contains("case #selector(NSResponder.moveLeftAndModifySelection(_:)):\n            return \"\\u{1b}[1;2D\""))
        XCTAssertTrue(surfaceSource.contains("private func extendKeyboardSelection(rowDelta: Int, columnDelta: Int)"))
        XCTAssertTrue(surfaceSource.contains("private var keyboardSelectionInputStart: TerminalCellPosition?"))
        XCTAssertTrue(surfaceSource.contains("recordKeyboardSelectionInputStartIfNeeded(for: text)"))
        XCTAssertTrue(surfaceSource.contains("let inputStart = keyboardSelectionInputStart ?? liveCursorPosition"))
        XCTAssertTrue(surfaceSource.contains("let minimumColumn = nextRow == inputStart.row ? inputStart.column : 0"))

        for source in [surfaceSource, inputSource] {
            XCTAssertFalse(source.contains("\\u{1b}[1;2A"))
            XCTAssertFalse(source.contains("\\u{1b}[1;2B"))
            XCTAssertFalse(source.contains("\\u{1b}[1;2C"))
            XCTAssertFalse(source.contains("\\u{1b}[1;2D"))
        }
    }

    func testSplitViewTargetsActivePaneAndRebalancesDividers() throws {
        let splitSource = try splitTerminalViewSource()
        XCTAssertTrue(splitSource.contains("pane.ownsFirstResponder"))
        XCTAssertTrue(splitSource.contains("func closeActivePane() -> Bool"))
        XCTAssertTrue(splitSource.contains("func focusPane(_ direction: TerminalPaneFocusDirection)"))
        XCTAssertTrue(splitSource.contains("private func nearestPane("))
        XCTAssertTrue(splitSource.contains("private func paneFocusCandidates() -> [PaneFocusCandidate]"))
        XCTAssertTrue(splitSource.contains("appendPaneFocusCandidates(from: self, into: &candidates)"))
        XCTAssertTrue(splitSource.contains("pane.convert(pane.bounds, to: self)"))
        XCTAssertTrue(splitSource.contains("let overlapPenalty: CGFloat = overlapsPerpendicularAxis ? 0 : 10_000"))
        XCTAssertTrue(splitSource.contains("guard candidateCenter.y < activeCenter.y else { return nil }"))
        XCTAssertTrue(splitSource.contains("guard candidateCenter.y > activeCenter.y else { return nil }"))
        XCTAssertTrue(splitSource.contains("private func configurePane(_ pane: TerminalPaneView)"))
        XCTAssertTrue(splitSource.contains("pane.closeRequested = { [weak self] pane in"))
        XCTAssertTrue(splitSource.contains("pane.focusChanged = { [weak self] _ in"))
        XCTAssertTrue(splitSource.contains("private func refreshPaneChrome()"))
        XCTAssertTrue(splitSource.contains("pane.setChromeVisible(isVisible)"))
        XCTAssertTrue(splitSource.contains("pane.setChromeActive(pane.ownsFirstResponder)"))
        XCTAssertTrue(splitSource.contains("guard paneCount > 1 else"))
        XCTAssertTrue(splitSource.contains("func focusFirstPane()"))
        XCTAssertTrue(splitSource.contains("override var dividerThickness: CGFloat"))
        XCTAssertTrue(splitSource.contains("DesignTokens.Component.terminalSplitDividerHitAreaPX"))
        XCTAssertTrue(splitSource.contains("func applyChromeTheme(_ theme: DesignTokens.ChromeTheme)"))
        XCTAssertTrue(splitSource.contains("override func drawDivider(in rect: NSRect)"))
        XCTAssertTrue(splitSource.contains("chromeTheme.divider.setFill()"))
        XCTAssertTrue(splitSource.contains("setPosition(position, ofDividerAt: dividerIndex)"))
        XCTAssertTrue(splitSource.contains("let dividerLength = dividerThickness * CGFloat(count - 1)"))
        XCTAssertTrue(splitSource.contains("let paneLength = (totalLength - dividerLength) / CGFloat(count)"))
        XCTAssertTrue(splitSource.contains("let position = paneLength * CGFloat(dividerIndex + 1) + dividerThickness * CGFloat(dividerIndex)"))
        XCTAssertTrue(splitSource.contains("func split(direction: TerminalPaneSplitDirection)"))
        XCTAssertTrue(splitSource.contains("private func splitGroupAsUnit(direction: TerminalPaneSplitDirection) -> Bool"))
        XCTAssertTrue(splitSource.contains("let axis = direction.axis"))
        XCTAssertTrue(splitSource.contains("guard arrangedSubviews.count > 1, isVertical != (axis == .vertical) else"))
        XCTAssertTrue(splitSource.contains("let existingGroup = SplitTerminalView(axis: currentAxis, pane: nil, paneDragCoordinator: paneDragCoordinator)"))
        XCTAssertTrue(splitSource.contains("moveCurrentArrangedSubviews(to: existingGroup)"))
        XCTAssertTrue(splitSource.contains("if direction.insertsAfterActivePane"))
        XCTAssertTrue(splitSource.contains("addArrangedSubview(existingGroup)"))
        XCTAssertTrue(splitSource.contains("addArrangedSubview(newPane)"))
        XCTAssertTrue(splitSource.contains("insertArrangedSubview(newPane, at: insertionIndex)"))
        XCTAssertTrue(splitSource.contains("arrangedSubviews.allSatisfy({ $0 is TerminalPaneView })"))

        let paneSource = try terminalPaneViewSource()
        XCTAssertTrue(paneSource.contains("private let chromeView = PaneChromeView()"))
        XCTAssertTrue(paneSource.contains("private let activeIndicatorView = NSView()"))
        XCTAssertTrue(paneSource.contains("private let statusDotView = NSView()"))
        XCTAssertTrue(paneSource.contains("private let titleField = NSTextField(labelWithString: \"~ (-zsh)\")"))
        XCTAssertTrue(paneSource.contains("private let closeButton = ChromeIconButton(title: \"×\""))
        XCTAssertTrue(try chromeIconButtonSource().contains("override func updateTrackingAreas()"))
        XCTAssertTrue(try chromeIconButtonSource().contains("override func mouseEntered(with event: NSEvent)"))
        XCTAssertTrue(try chromeIconButtonSource().contains("override func mouseExited(with event: NSEvent)"))
        XCTAssertTrue(try chromeIconButtonSource().contains("let location = convert(event.locationInWindow, from: nil)"))
        XCTAssertTrue(try chromeIconButtonSource().contains("guard !bounds.contains(location) else { return }"))
        XCTAssertTrue(try chromeIconButtonSource().contains("override func resetCursorRects()"))
        XCTAssertTrue(try chromeIconButtonSource().contains("addCursorRect(bounds, cursor: .pointingHand)"))
        XCTAssertTrue(paneSource.contains("func applyChromeTheme(_ theme: DesignTokens.ChromeTheme)"))
        XCTAssertTrue(paneSource.contains("var closeRequested: ((TerminalPaneView) -> Void)?"))
        XCTAssertTrue(paneSource.contains("var focusChanged: ((TerminalPaneView) -> Void)?"))
        XCTAssertTrue(paneSource.contains("private final class PaneChromeView: NSView"))
        XCTAssertTrue(paneSource.contains("var onHoverChanged: ((Bool) -> Void)?"))
        XCTAssertTrue(paneSource.contains("var onSelect: (() -> Void)?"))
        XCTAssertTrue(paneSource.contains("chromeView.onSelect = { [weak self] in"))
        XCTAssertTrue(paneSource.contains("private func updateChromeAppearance()"))
        XCTAssertTrue(paneSource.contains("activeIndicatorView.isHidden = !isChromeActive"))
        XCTAssertTrue(paneSource.contains("statusDotView.layer?.backgroundColor = (isChromeActive"))
        XCTAssertTrue(paneSource.contains("chromeTheme.paneHeaderBackground"))
        XCTAssertTrue(paneSource.contains("chromeTheme.paneHeaderHoverBackground"))
        XCTAssertTrue(paneSource.contains("chromeTheme.borderHairline"))
        XCTAssertTrue(paneSource.contains("override func mouseDown(with event: NSEvent)"))
        XCTAssertTrue(paneSource.contains("private func observeTerminalTitle()"))
        XCTAssertTrue(paneSource.contains("private func observeTerminalFocus()"))
        XCTAssertTrue(paneSource.contains("@objc private func terminalFocusDidChange(_ notification: Notification)"))
        XCTAssertTrue(paneSource.contains("name: TerminalSurfaceView.titleDidChangeNotification"))
        XCTAssertTrue(paneSource.contains("object: terminalSurfaceView"))
        XCTAssertTrue(paneSource.contains("titleField.stringValue = title"))
        XCTAssertTrue(paneSource.contains("func setChromeVisible(_ isVisible: Bool)"))
        XCTAssertTrue(paneSource.contains("func setChromeActive(_ isActive: Bool)"))
        XCTAssertTrue(paneSource.contains("@objc private func closeButtonPressed(_ sender: NSButton)"))
    }

    func testNestedSplitRebalancesAfterItReceivesBounds() throws {
        let splitSource = try splitTerminalViewSource()

        XCTAssertTrue(splitSource.contains("private var needsInitialRebalance = false"))
        XCTAssertTrue(splitSource.contains("override func layout()"))
        XCTAssertTrue(splitSource.contains("if needsInitialRebalance"))
        XCTAssertTrue(splitSource.contains("needsInitialRebalance = false"))
        XCTAssertTrue(splitSource.contains("nestedSplit.needsInitialRebalance = true"))
        XCTAssertTrue(splitSource.contains("nestedSplit.rebalanceDividers()"))
    }

    func testNestedPaneCloseCollapsesRedundantSplitWrappers() throws {
        let splitSource = try splitTerminalViewSource()

        XCTAssertTrue(splitSource.contains("private func rootSplitView() -> SplitTerminalView"))
        XCTAssertTrue(splitSource.contains("rootSplitView().closePaneFromChrome(pane)"))
        XCTAssertTrue(splitSource.contains("private func closePaneFromChrome(_ pane: TerminalPaneView)"))
        XCTAssertTrue(splitSource.contains("private func remove(_ pane: TerminalPaneView) -> Bool"))
        XCTAssertTrue(splitSource.contains("collapseChildSplitIfNeeded(splitView, at: index)"))
        XCTAssertTrue(splitSource.contains("private func collapseChildSplitIfNeeded(_ splitView: SplitTerminalView, at index: Int)"))
        XCTAssertTrue(splitSource.contains("guard splitView.arrangedSubviews.count == 1 else"))
        XCTAssertTrue(splitSource.contains("insertArrangedSubview(remainingSubview, at: min(index, arrangedSubviews.count))"))
    }

    func testPaneChromeDragDetachesAndReattachesPanesAcrossWindows() throws {
        let paneSource = try terminalPaneViewSource()
        let splitSource = try splitTerminalViewSource()
        let windowSource = try terminalWindowControllerSource()
        let dragSource = try terminalPaneDragCoordinatorSource()
        let designSource = try designTokensSource()

        XCTAssertTrue(paneSource.contains("var detachDragRequested: ((TerminalPaneView, NSEvent) -> Void)?"))
        XCTAssertTrue(paneSource.contains("chromeView.onDragRequested = { [weak self] event in"))
        XCTAssertTrue(paneSource.contains("func beginDraggingPane(_ pane: TerminalPaneView, with event: NSEvent)"))
        XCTAssertTrue(paneSource.contains("override func mouseDragged(with event: NSEvent)"))
        XCTAssertTrue(paneSource.contains("abs(event.locationInWindow.x - mouseDownLocationInWindow.x)"))

        XCTAssertTrue(splitSource.contains("func detachPaneForDrag(_ pane: TerminalPaneView) -> TerminalPaneView?"))
        XCTAssertTrue(splitSource.contains("guard paneCount > 1 else"))
        XCTAssertTrue(splitSource.contains("configureDetachedPaneForReuse(pane)"))
        XCTAssertTrue(splitSource.contains("func appendDetachedPaneAsTabRoot(_ pane: TerminalPaneView)"))

        XCTAssertTrue(windowSource.contains("private let dropTargetView = TerminalPaneDropTargetView()"))
        XCTAssertTrue(windowSource.contains("private let paneDragCoordinator: TerminalPaneDragCoordinator"))
        XCTAssertTrue(windowSource.contains("dropTargetView.onPaneDrop = { [weak self] in"))
        XCTAssertTrue(windowSource.contains("dropTargetView.onPaneCanDrop = { [weak self] in"))
        XCTAssertTrue(windowSource.contains("func attachDraggedPaneAsTab(_ pane: TerminalPaneView)"))
        XCTAssertTrue(windowSource.contains("convenience init(detachedPane pane: TerminalPaneView, paneDragCoordinator: TerminalPaneDragCoordinator)"))
        XCTAssertTrue(windowSource.contains("DesignTokens.Color.paneDropTargetBorder.cgColor"))
        XCTAssertTrue(windowSource.contains("DesignTokens.Component.paneDropTargetBorderWidthPX"))

        XCTAssertTrue(dragSource.contains("final class TerminalPaneDragCoordinator: NSObject, NSDraggingSource"))
        XCTAssertTrue(dragSource.contains("static let pasteboardType = NSPasteboard.PasteboardType(\"dev.kurotty.terminal-pane\")"))
        XCTAssertFalse(dragSource.contains("static let shared = TerminalPaneDragCoordinator()"))
        XCTAssertTrue(dragSource.contains("func moveDraggedPaneToTab(in controller: TerminalWindowController) -> Bool"))
        XCTAssertTrue(dragSource.contains("func canMoveDraggedPane(to controller: TerminalWindowController) -> Bool"))
        XCTAssertTrue(dragSource.contains("func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation)"))
        XCTAssertTrue(dragSource.contains("detachDraggedPaneToNewWindow(at: screenPoint)"))
        XCTAssertTrue(dragSource.contains("moveDraggedPaneToTab(in controller: TerminalWindowController)"))
        XCTAssertTrue(dragSource.contains("TerminalWindowController(detachedPane: detachedPane, paneDragCoordinator: self)"))

        XCTAssertTrue(designSource.contains("paneDropTargetBorder"))
        XCTAssertTrue(designSource.contains("paneDropTargetBackground"))
        XCTAssertTrue(designSource.contains("paneDropTargetBorderWidthPX"))
    }

    func testTerminalLinksShowHtmlStyleHoverAffordanceAndOpenWithConfirmation() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let modelSource = try terminalModelSource()

        XCTAssertTrue(modelSource.contains("struct TerminalLinkRange: Equatable"))
        XCTAssertTrue(modelSource.contains("static func findAll(in cells: [TerminalScreenCell], row: Int) -> [TerminalLinkRange]"))
        XCTAssertTrue(surfaceSource.contains("override func mouseMoved(with event: NSEvent)"))
        XCTAssertTrue(surfaceSource.contains("override func flagsChanged(with event: NSEvent)"))
        XCTAssertTrue(surfaceSource.contains(".mouseMoved"))
        XCTAssertFalse(surfaceSource.contains("guard event.modifierFlags.contains(.command) else"))
        XCTAssertFalse(surfaceSource.contains("event.modifierFlags.contains(.command), let link = linkRange(at: position)"))
        XCTAssertTrue(surfaceSource.contains("if let link = linkRange(at: position)"))
        XCTAssertTrue(surfaceSource.contains("TerminalLinkRange.findAll(in: sourceRow, row: row)"))
        XCTAssertTrue(surfaceSource.contains("private func linkRange(at position: TerminalCellPosition) -> TerminalLinkRange?"))
        XCTAssertTrue(surfaceSource.contains("hoveredLinkRange?.contains(row: row, column: column)"))
        XCTAssertTrue(surfaceSource.contains("private func presentOpenLinkDialog(for link: TerminalLinkRange)"))
        XCTAssertTrue(surfaceSource.contains("NSWorkspace.shared.open(url)"))
        XCTAssertTrue(surfaceSource.contains("messageText = \"Open Link?\""))
    }

    func testMetalDrawConfiguresExplicitFullFrameClearAndOpaqueBackgroundPipeline() throws {
        let metalSource = try terminalMetalViewSource()

        XCTAssertTrue(metalSource.contains("private func configureRenderPassDescriptor(_ descriptor: MTLRenderPassDescriptor)"))
        XCTAssertTrue(metalSource.contains("colorAttachment?.loadAction = .clear"))
        XCTAssertTrue(metalSource.contains("colorAttachment?.storeAction = .store"))
        XCTAssertTrue(metalSource.contains("colorAttachment?.clearColor = clearColor"))
        XCTAssertTrue(metalSource.contains("configureRenderPassDescriptor(descriptor)"))
        XCTAssertTrue(metalSource.contains("logFrameStartIfNeeded(descriptor: descriptor)"))
        XCTAssertTrue(metalSource.contains("fullRedraw=%@"))
        XCTAssertTrue(metalSource.contains("clearColor=(%0.4f,%0.4f,%0.4f,%0.4f)"))
        XCTAssertTrue(metalSource.contains("Kurotty render rects: cursorRectPx=%@"))
        XCTAssertTrue(metalSource.contains("solidDescriptor.colorAttachments[0].isBlendingEnabled = false"))
        XCTAssertTrue(metalSource.contains("glyphBlend=straight-alpha"))
    }

    func testDebugFlagsAndScreenDumpInstrumentationAreAvailable() throws {
        let debugPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/KurottyApp/DebugOptions.swift")
        let debugSource = try String(contentsOf: debugPath, encoding: .utf8)
        let surfaceSource = try terminalSurfaceViewSource()
        let diagnosticsSource = try terminalDiagnosticsSource()
        let metalSource = try terminalMetalViewSource()

        XCTAssertTrue(debugSource.contains("--debug-pty-log"))
        XCTAssertTrue(debugSource.contains("--debug-screen-dump"))
        XCTAssertTrue(debugSource.contains("--debug-layout"))
        XCTAssertTrue(debugSource.contains("--debug-full-model-redraw"))
        XCTAssertTrue(debugSource.contains("--debug-render-rects"))
        XCTAssertTrue(debugSource.contains("--debug-ime-rect"))
        XCTAssertTrue(debugSource.contains("--debug-input-client"))
        XCTAssertTrue(debugSource.contains("--debug-cursor-coordinates"))
        XCTAssertTrue(surfaceSource.contains("TerminalRawPtyLogMetadata(data: data)"))
        XCTAssertTrue(diagnosticsSource.contains("struct TerminalRawPtyLogMetadata"))
        XCTAssertFalse(surfaceSource.contains("Kurotty PTY raw: bytes=%@ decoded=%@"))
        XCTAssertFalse(surfaceSource.contains("hexDump(data)"))
        XCTAssertFalse(surfaceSource.contains("escapedText(data)"))
        XCTAssertTrue(surfaceSource.contains("Kurotty screen dump: frame=%llu"))
        XCTAssertTrue(surfaceSource.contains("Kurotty IME firstRect:"))
        XCTAssertTrue(surfaceSource.contains("bgRuns=%@ fgRuns=%@"))
        XCTAssertTrue(metalSource.contains("DebugOptions.renderRects"))
    }

    func testTerminalSurfaceFirstRectUsesRendererCursorCoordinatesForIME() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect"))
        XCTAssertTrue(source.contains("actualRange?.pointee = selectedRange()"))
        XCTAssertTrue(source.contains("let localRect = currentCursorCellRectInViewCoordinates()"))
        XCTAssertTrue(source.contains("let windowRect = convert(localRect, to: nil)"))
        XCTAssertTrue(source.contains("window?.convertToScreen(windowRect) ?? .zero"))
        XCTAssertTrue(source.contains("static func cursorCellRectInViewCoordinates("))
        XCTAssertTrue(source.contains("boundsHeight - padding.top - CGFloat(clampedRow + 1) * cellSize.height"))
        XCTAssertTrue(source.contains("x: padding.left + CGFloat(clampedColumn) * cellSize.width"))
        XCTAssertFalse(source.contains("y: padding.top + CGFloat(cursorRow + 1) * metrics.cellSize.height"))
    }

    func testTerminalInputIsRenderedOnlyFromScreenBuffer() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let metalSource = try terminalMetalViewSource()

        XCTAssertFalse(surfaceSource.contains("inputOverlayText"))
        XCTAssertFalse(surfaceSource.contains("inputOverlayColumn"))
        XCTAssertFalse(surfaceSource.contains("inputOverlayRow"))
        XCTAssertFalse(surfaceSource.contains("pendingOverlayEcho"))
        XCTAssertFalse(surfaceSource.contains("shouldClearInputOverlay"))
        XCTAssertFalse(metalSource.contains("inputOverlayText"))
        XCTAssertFalse(metalSource.contains("inputOverlayColumn"))
        XCTAssertFalse(metalSource.contains("inputOverlayRow"))
    }

    func testTerminalNotificationsOnlyUseExplicitTerminalNotificationProtocols() throws {
        let shellSource = try shellSessionSource()
        let surfaceSource = try terminalSurfaceViewSource()
        let notifierSource = try terminalNotifierSource()
        let appDelegateSource = try appDelegateSource()
        let readmeSource = try readmeSource()

        XCTAssertTrue(shellSource.contains("var onExit: ((Int32) -> Void)?"))
        XCTAssertTrue(shellSource.contains("private var waitSource: DispatchSourceProcess?"))
        XCTAssertTrue(shellSource.contains("DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit"))
        XCTAssertTrue(shellSource.contains("waitpid(pid, &status, WNOHANG)"))

        XCTAssertTrue(surfaceSource.contains("private let notifier = TerminalNotifier.shared"))
        XCTAssertTrue(surfaceSource.contains("private var pendingSubmittedInputText = \"\""))
        XCTAssertTrue(surfaceSource.contains("private var lastSubmittedCommandText: String?"))
        XCTAssertFalse(surfaceSource.contains("backgroundTask"))
        XCTAssertFalse(surfaceSource.contains("BackgroundTask"))
        XCTAssertTrue(surfaceSource.contains("private func send(_ text: String, recordsUserActivity: Bool = true)"))
        XCTAssertTrue(surfaceSource.contains("recordUserInput(text)"))
        XCTAssertTrue(surfaceSource.contains("recordSubmittedInputText(text)"))
        XCTAssertTrue(surfaceSource.contains("captureSubmittedCommandTextIfNeeded()"))
        XCTAssertFalse(surfaceSource.contains("TerminalBackgroundTaskTrackingPolicy.shouldTrackSubmittedInput("))
        XCTAssertFalse(surfaceSource.contains("recordOutputForBackgroundTask(text)"))
        XCTAssertFalse(surfaceSource.contains("private func appendBackgroundTaskOutputText(_ text: String)"))
        XCTAssertFalse(surfaceSource.contains("latestVisibleNotificationSummary"))
        XCTAssertFalse(surfaceSource.contains("TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: lines)"))
        XCTAssertFalse(surfaceSource.contains("scheduleBackgroundTaskIdleCheck()"))
        XCTAssertFalse(surfaceSource.contains("notifyBackgroundTaskIfIdle(inputSequence: inputSequence)"))
        XCTAssertTrue(surfaceSource.contains("guard shouldDeliverUserNotification else"))
        XCTAssertTrue(surfaceSource.contains("private var shouldDeliverUserNotification: Bool"))
        XCTAssertTrue(surfaceSource.contains("!isTerminalFocusedForUser"))
        XCTAssertTrue(surfaceSource.contains("private var isTerminalFocusedForUser: Bool"))
        XCTAssertTrue(surfaceSource.contains("NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self"))
        XCTAssertTrue(surfaceSource.contains("TerminalSubmittedCommandSummary.notificationBody(from: pendingSubmittedInputText)"))
        XCTAssertFalse(surfaceSource.contains("TerminalBackgroundTaskNotificationContent.make("))
        XCTAssertFalse(surfaceSource.contains("notifier.notifyBackgroundTaskCompleted(content: content)"))
        XCTAssertTrue(surfaceSource.contains("sendTerminalResponse(cursorPositionReport())"))
        XCTAssertTrue(surfaceSource.contains("sendTerminalResponse(response)"))
        XCTAssertFalse(surfaceSource.contains("notifyShellDidExit"))
        XCTAssertFalse(surfaceSource.contains("shell.onExit = { [weak self] status in"))
        XCTAssertTrue(surfaceSource.contains("case \"9\":"))
        XCTAssertTrue(surfaceSource.contains("notifyItermOsc9(payload)"))
        XCTAssertTrue(surfaceSource.contains("case \"777\":"))
        XCTAssertTrue(surfaceSource.contains("notifyOSC777(payload)"))
        XCTAssertTrue(surfaceSource.contains("notifier.notifyItermOsc9(message: payload)"))
        XCTAssertTrue(surfaceSource.contains("notifier.notifyOSC777(payload: payload)"))
        XCTAssertTrue(surfaceSource.contains("handleTerminalIntegrationEvent(integrationEvent)"))
        XCTAssertTrue(surfaceSource.contains("shellIntegration.setActiveCommandText(lastSubmittedCommandText)"))
        XCTAssertTrue(surfaceSource.contains("notifyCommandFinishedIfNeeded(context)"))
        XCTAssertTrue(surfaceSource.contains("notifier.notifyCommandFinished(content: TerminalCommandCompletionNotificationContent.make(from: context))"))
        XCTAssertFalse(surfaceSource.contains("detectCodexTaskStateInScreen"))
        XCTAssertFalse(surfaceSource.contains("codexTaskIsRunning"))
        XCTAssertFalse(surfaceSource.contains("isCodexBusyScreen"))
        XCTAssertFalse(surfaceSource.contains("isCodexIdleScreen"))
        XCTAssertFalse(surfaceSource.contains("isCodexIdlePromptLine"))
        XCTAssertFalse(surfaceSource.contains("extractCodexCompletionSummary"))
        XCTAssertFalse(surfaceSource.contains("notifyCodexTaskCompleted("))

        XCTAssertTrue(notifierSource.contains("import UserNotifications"))
        XCTAssertTrue(notifierSource.contains("import os"))
        XCTAssertTrue(notifierSource.contains("final class TerminalNotifier"))
        XCTAssertFalse(notifierSource.contains("final class TerminalNotifier: NSObject, UNUserNotificationCenterDelegate"))
        XCTAssertTrue(notifierSource.contains("private let notificationDelegate = TerminalNotificationDelegate()"))
        XCTAssertTrue(notifierSource.contains("private final class TerminalNotificationDelegate: NSObject, UNUserNotificationCenterDelegate"))
        XCTAssertFalse(notifierSource.contains("@MainActor\nfinal class TerminalNotifier"))
        XCTAssertTrue(notifierSource.contains("private let terminalNotificationLogger = Logger(subsystem: \"dev.kurotty.app\", category: \"notifications\")"))
        XCTAssertTrue(notifierSource.contains("Bundle.main.bundleURL.pathExtension == \"app\""))
        XCTAssertTrue(notifierSource.contains("UNUserNotificationCenter.current()"))
        XCTAssertTrue(notifierSource.contains("center.delegate = notificationDelegate"))
        XCTAssertTrue(notifierSource.contains("guard !didRequestAuthorization, let center else { return }"))
        XCTAssertTrue(notifierSource.contains("Self.requestAuthorizationCallbacks(on: center)"))
        XCTAssertTrue(notifierSource.contains("private nonisolated static func requestAuthorizationCallbacks(on center: UNUserNotificationCenter)"))
        XCTAssertTrue(notifierSource.contains("private nonisolated static func enqueue(_ request: UNNotificationRequest, on center: UNUserNotificationCenter)"))
        XCTAssertTrue(notifierSource.contains("getNotificationSettings"))
        XCTAssertTrue(notifierSource.contains("authorization failed error="))
        XCTAssertTrue(notifierSource.contains("enqueue identifier="))
        XCTAssertFalse(notifierSource.contains("skipped outside app bundle metadata="))
        XCTAssertTrue(notifierSource.contains("deliverDevelopmentNotification(title: title, subtitle: subtitle, body: body, metadata: metadata)"))
        XCTAssertTrue(notifierSource.contains("AppConstants.Notifications.developmentNotificationExecutablePath"))
        XCTAssertTrue(notifierSource.contains("process.arguments = [\"-e\", script]"))
        XCTAssertTrue(notifierSource.contains("development fallback enqueue metadata="))
        XCTAssertTrue(notifierSource.contains("TerminalNotificationLogMetadata("))
        XCTAssertTrue(notifierSource.contains("subtitle: subtitle"))
        XCTAssertFalse(notifierSource.contains("title=%@ body=%@"))
        XCTAssertTrue(notifierSource.contains("delivered request identifier="))
        XCTAssertTrue(notifierSource.contains("func notifyTestNotification()"))
        XCTAssertFalse(notifierSource.contains("func notifyBackgroundTaskCompleted(content: TerminalBackgroundTaskNotificationContent)"))
        XCTAssertTrue(notifierSource.contains("func notifyCommandFinished(content: TerminalCommandCompletionNotificationContent)"))
        XCTAssertTrue(notifierSource.contains("AppConstants.Notifications.commandCompletionIdentifierPrefix"))
        XCTAssertTrue(notifierSource.contains("TerminalNotificationPayload.contentFromOSC9Payload(message)"))
        XCTAssertTrue(notifierSource.contains("func notifyOSC777(payload: String)"))
        XCTAssertTrue(notifierSource.contains("TerminalNotificationPayload.contentFromOSC777Payload(payload)"))
        XCTAssertTrue(notifierSource.contains("content.subtitle = subtitle"))
        XCTAssertFalse(notifierSource.contains("func notifyBackgroundTaskCompleted(summary: String)"))
        XCTAssertFalse(notifierSource.contains("AppConstants.Notifications.backgroundTaskIdentifierPrefix"))
        XCTAssertFalse(notifierSource.contains("func notifyShellDidExit"))
        XCTAssertFalse(notifierSource.contains("shellExitIdentifierPrefix"))
        XCTAssertFalse(notifierSource.contains("shellExitSuccessBody"))
        XCTAssertFalse(notifierSource.contains("func notifyCodexTaskCompleted"))
        XCTAssertFalse(notifierSource.contains("Session \\(sessionTitle): \\(trimmedPrompt)"))
        XCTAssertTrue(notifierSource.contains("content.interruptionLevel = .timeSensitive"))
        XCTAssertFalse(notifierSource.contains("guard !NSApp.isActive"))
        XCTAssertTrue(notifierSource.contains("willPresent notification: UNNotification"))
        XCTAssertTrue(notifierSource.contains("will present identifier="))
        XCTAssertTrue(notifierSource.contains("completionHandler([.banner, .list, .sound])"))
        XCTAssertEqual(notifierSource.components(separatedBy: "completionHandler([.banner, .list, .sound])").count - 1, 1)
        XCTAssertTrue(notifierSource.contains("didReceive response: UNNotificationResponse"))
        XCTAssertFalse(notifierSource.contains("Task { @MainActor in"))
        XCTAssertFalse(notifierSource.contains("Task { await MainActor.run"))
        XCTAssertTrue(notifierSource.contains("DispatchQueue.main.async"))
        XCTAssertTrue(notifierSource.contains("focusExistingTerminalWindow"))
        XCTAssertTrue(notifierSource.contains("response.actionIdentifier == UNNotificationDefaultActionIdentifier"))
        XCTAssertTrue(notifierSource.contains("completionHandler()"))
        XCTAssertLessThan(
            notifierSource.range(of: "completionHandler()", options: .backwards)!.lowerBound,
            notifierSource.range(of: "focusExistingTerminalWindow")!.lowerBound
        )
        XCTAssertTrue(notifierSource.contains("notification response identifier="))
        XCTAssertTrue(notifierSource.contains("UNNotificationRequest("))
        XCTAssertTrue(appDelegateSource.contains("@objc func focusExistingTerminalWindow()"))
        XCTAssertTrue(appDelegateSource.contains("activeTerminalWindowController?.window?.makeKeyAndOrderFront(nil)"))
        XCTAssertEqual(appDelegateSource.components(separatedBy: "openNewWindow()").count - 1, 2)
        XCTAssertTrue(try appConstantsSource().contains("static let defaultTitle = \"Kurotty\""))
        XCTAssertFalse(try appConstantsSource().contains("codexFinishedTitle"))
        XCTAssertFalse(try appConstantsSource().contains("codexFailedTitle"))
        XCTAssertFalse(try appConstantsSource().contains("codexNeedsInputTitle"))
        XCTAssertFalse(try appConstantsSource().contains("backgroundTaskIdentifierPrefix"))
        XCTAssertFalse(try appConstantsSource().contains("backgroundTaskSummaryMaxCharacters"))
        XCTAssertFalse(try appConstantsSource().contains("backgroundTaskFinishedBody"))
        XCTAssertFalse(try appConstantsSource().contains("backgroundTaskOutputCaptureMaxCharacters"))
        XCTAssertFalse(try appConstantsSource().contains("backgroundTaskInputCaptureMaxCharacters"))
        XCTAssertFalse(try appConstantsSource().contains("backgroundTaskIdleSeconds"))
        XCTAssertTrue(try appConstantsSource().contains("static let osc777IdentifierPrefix"))
        XCTAssertTrue(try appConstantsSource().contains("static let commandCompletionIdentifierPrefix"))
        XCTAssertTrue(try appConstantsSource().contains("static let commandInputCaptureMaxCharacters"))
        XCTAssertTrue(try appConstantsSource().contains("static let commandSummaryMaxCharacters"))
        XCTAssertTrue(try appConstantsSource().contains("static let terminalNotificationMaxCharacters"))
        XCTAssertFalse(try appConstantsSource().contains("shellExitIdentifierPrefix"))
        XCTAssertFalse(try appConstantsSource().contains("shellExitSuccessBody"))
        XCTAssertFalse(try appConstantsSource().contains("shellExitFailureBodyPrefix"))
        XCTAssertFalse(try appConstantsSource().contains("codexTaskCompletedBody"))
        XCTAssertTrue(try debugOptionsSource().contains("static let testNotification"))

        XCTAssertTrue(readmeSource.contains("iTerm2-compatible notifications"))
        XCTAssertFalse(readmeSource.contains("printf '\\e]9;Task finished\\a'"))
    }

    func testInstalledAppUsesMultiResolutionIcnsForSystemIconSurfaces() throws {
        let installSource = try installAppScriptSource()
        let iconsetSource = try scriptSource(named: "iconset")
        let appDelegateSource = try appDelegateSource()
        let constantsSource = try appConstantsSource()

        XCTAssertTrue(installSource.contains("ICONSET_DIR=\"$APP_BUNDLE/Contents/Resources/kurotty.iconset\""))
        XCTAssertTrue(installSource.contains("source \"$ROOT_DIR/scripts/iconset.sh\""))
        XCTAssertTrue(installSource.contains("create_kurotty_iconset \"$ROOT_DIR/kurotty.png\" \"$ICONSET_DIR\""))
        XCTAssertFalse(installSource.contains("cp \"$ROOT_DIR/kurotty.png\" \"$APP_BUNDLE/Contents/Resources/kurotty.png\""))
        XCTAssertTrue(installSource.contains("zig build -Doptimize=ReleaseFast"))
        XCTAssertTrue(installSource.contains("cp \"$ROOT_DIR/zig-out/lib/libkurotty_core.dylib\" \"$APP_BUNDLE/Contents/Resources/libkurotty_core.dylib\""))
        XCTAssertTrue(iconsetSource.contains("icon_16x16.png"))
        XCTAssertTrue(iconsetSource.contains("icon_512x512@2x.png"))
        XCTAssertTrue(installSource.contains("iconutil -c icns \"$ICONSET_DIR\" -o \"$APP_BUNDLE/Contents/Resources/kurotty.icns\""))
        XCTAssertTrue(installSource.contains("<string>kurotty.icns</string>"))
        XCTAssertTrue(installSource.contains("codesign --force --deep --sign - \"$APP_BUNDLE\""))
        XCTAssertTrue(installSource.contains("LaunchServices.framework/Support/lsregister"))
        XCTAssertTrue(installSource.contains("\"$LSREGISTER\" -f \"$INSTALLED_APP\""))
        XCTAssertTrue(installSource.contains("\"$ROOT_DIR/scripts/verify-icon-bundle.sh\" \"$INSTALLED_APP\""))
        XCTAssertTrue(try scriptSource(named: "verify-icon-bundle").contains("icon verification passed"))
        XCTAssertTrue(try scriptSource(named: "verify-icon-bundle").contains("CFBundleIconFile must be kurotty.icns"))
        XCTAssertTrue(try scriptSource(named: "verify-icon-bundle").contains("RESOURCE_BUNDLE=\"Kurotty_KurottyApp.bundle\""))
        XCTAssertTrue(try scriptSource(named: "verify-icon-bundle").contains("$RESOURCE_BUNDLE/kurotty.png"))
        XCTAssertTrue(try scriptSource(named: "verify-icon-bundle").contains("icon_512x512@2x.png"))
        XCTAssertTrue(try scriptSource(named: "verify-icon-bundle").contains("installed .icns must not be resized"))
        XCTAssertTrue(appDelegateSource.contains("Bundle.main.url("))
        XCTAssertTrue(appDelegateSource.contains("withExtension: AppConstants.Bundle.installedIconExtension"))
        XCTAssertTrue(appDelegateSource.contains("if !loadedIcon.isInstalledIcon"))
        XCTAssertTrue(appDelegateSource.contains("Installed"))
        XCTAssertTrue(appDelegateSource.contains("do not inherit a"))
        XCTAssertTrue(constantsSource.contains("static let installedIconExtension = \"icns\""))
    }

    func testReleasePackagingProducesUniversalDmgAndChecksumFromVerifiedAppBundle() throws {
        let packageSource = try scriptSource(named: "package-release")
        let installSource = try scriptSource(named: "install-app")
        let readmeSource = try readmeSource()
        let releaseWorkflowSource = try workflowSource(named: "release")
        let agentsSource = try agentsSource()
        let versionSource = try versionSource()
        let releaseVersion = versionSource.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(versionSource.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9.-]+\n?$"#, options: .regularExpression) != nil)
        XCTAssertTrue(installSource.contains("VERSION_FILE=\"$ROOT_DIR/VERSION\""))
        XCTAssertTrue(installSource.contains("VERSION=\"$(tr -d '[:space:]' < \"$VERSION_FILE\")\""))
        XCTAssertTrue(installSource.contains("<string>$VERSION</string>"))
        XCTAssertTrue(packageSource.contains("BUILD_ARCHES=(arm64 x86_64)"))
        XCTAssertTrue(packageSource.contains("STRIP_TOOL=\"${STRIP_TOOL:-strip}\""))
        XCTAssertTrue(packageSource.contains("VERSION_FILE=\"$ROOT_DIR/VERSION\""))
        XCTAssertTrue(packageSource.contains(#"VERSION="${1:-$(tr -d '[:space:]' < "$VERSION_FILE")}""#))
        XCTAssertTrue(packageSource.contains("source \"$ROOT_DIR/scripts/iconset.sh\""))
        XCTAssertTrue(packageSource.contains("swift build -c release --triple \"$triple\" --scratch-path \"$scratch_path\""))
        XCTAssertTrue(packageSource.contains("\"$STRIP_TOOL\" -x \"$zig_prefix/lib/libkurotty_core.dylib\""))
        XCTAssertTrue(packageSource.contains("lipo -create"))
        XCTAssertTrue(packageSource.contains("\"$STRIP_TOOL\" -x \"$APP_BUNDLE/Contents/MacOS/kurotty\""))
        XCTAssertTrue(packageSource.contains("\"$STRIP_TOOL\" -x \"$APP_BUNDLE/Contents/Resources/libkurotty_core.dylib\""))
        XCTAssertTrue(packageSource.contains("lipo -info \"$APP_BUNDLE/Contents/MacOS/kurotty\""))
        XCTAssertTrue(packageSource.contains("create_kurotty_iconset \"$ROOT_DIR/kurotty.png\" \"$ICONSET_DIR\""))
        XCTAssertFalse(packageSource.contains("cp \"$ROOT_DIR/kurotty.png\" \"$APP_BUNDLE/Contents/Resources/kurotty.png\""))
        XCTAssertTrue(packageSource.contains("DMG_NAME=\"kurotty-$VERSION-macos-universal.dmg\""))
        XCTAssertTrue(packageSource.contains("DMG_LATEST_NAME=\"kurotty-macos-universal.dmg\""))
        XCTAssertTrue(packageSource.contains("APPCAST_WORK_DIR=\"$WORK_DIR/appcast\""))
        XCTAssertTrue(packageSource.contains("\"$DIST_DIR\"/kurotty-*-macos-universal.dmg"))
        XCTAssertTrue(packageSource.contains("\"$DIST_DIR/appcast.xml\""))
        XCTAssertTrue(packageSource.contains("cp \"$DMG_PATH\" \"$APPCAST_WORK_DIR/$DMG_NAME\""))
        XCTAssertTrue(packageSource.contains("resolve_sparkle_generate_appcast"))
        XCTAssertTrue(packageSource.contains("generate_sparkle_appcast \"$APPCAST_WORK_DIR\""))
        XCTAssertTrue(packageSource.contains("cp \"$APPCAST_WORK_DIR/appcast.xml\" \"$DIST_DIR/appcast.xml\""))
        XCTAssertTrue(packageSource.contains("cp \"$DMG_PATH\" \"$DMG_LATEST_PATH\""))
        XCTAssertTrue(packageSource.contains("hdiutil create"))
        XCTAssertTrue(packageSource.contains("hdiutil attach"))
        XCTAssertTrue(packageSource.contains("ln -s /Applications \"$DMG_ROOT/Applications\""))
        XCTAssertTrue(packageSource.contains("hdiutil detach"))
        XCTAssertTrue(packageSource.contains("scripts/verify-icon-bundle.sh"))
        XCTAssertTrue(packageSource.contains("codesign --force --deep --options runtime --sign \"$SIGN_IDENTITY\" \"$APP_BUNDLE\""))
        XCTAssertTrue(packageSource.contains("codesign --force --deep --sign - \"$APP_BUNDLE\""))
        XCTAssertTrue(packageSource.contains("xcrun notarytool submit"))
        XCTAssertTrue(packageSource.contains("xcrun stapler staple"))
        XCTAssertTrue(packageSource.contains("shasum -a 256 \"$DMG_NAME\" \"$DMG_LATEST_NAME\""))
        XCTAssertTrue(packageSource.contains("SHA256SUMS"))
        XCTAssertLessThan(
            try XCTUnwrap(packageSource.range(of: "if [[ \"$SPARKLE_CONFIGURED_UPDATES\" == \"1\" ]]")).lowerBound,
            try XCTUnwrap(packageSource.range(of: "cp \"$DMG_PATH\" \"$DMG_LATEST_PATH\"")).lowerBound
        )
        XCTAssertTrue(packageSource.contains("KUROTTY_KEEP_RELEASE_WORKDIR"))
        XCTAssertTrue(packageSource.contains("rm -rf \"$WORK_DIR\"/swift-* \"$WORK_DIR\"/zig-* \"$ICONSET_DIR\" \"$DMG_ROOT\" \"$DMG_RW\" \"$APPCAST_WORK_DIR\""))

        XCTAssertTrue(readmeSource.contains("GitHub Releases"))
        XCTAssertTrue(readmeSource.contains("[Download](#download)"))
        XCTAssertTrue(readmeSource.contains("## Download"))
        XCTAssertTrue(readmeSource.contains("https://github.com/skyepodium/kurotty/releases/latest/download/kurotty-macos-universal.dmg"))
        XCTAssertTrue(readmeSource.contains("kurotty-macos-universal.dmg"))
        XCTAssertTrue(readmeSource.contains("curl -fL -o kurotty-macos-universal.dmg"))
        XCTAssertTrue(readmeSource.contains("./scripts/package-release.sh"))
        XCTAssertTrue(readmeSource.contains("Intel and Apple Silicon Macs"))
        XCTAssertFalse(readmeSource.contains("kurotty-<version>-macos-universal.dmg"))
        XCTAssertFalse(readmeSource.contains("shasum -a 256 -c SHA256SUMS"))
        XCTAssertFalse(readmeSource.contains("git tag \"v$(cat VERSION)\""))
        XCTAssertFalse(readmeSource.contains(releaseVersion))

        XCTAssertTrue(releaseWorkflowSource.contains("on:"))
        XCTAssertTrue(releaseWorkflowSource.contains("tags:"))
        XCTAssertTrue(releaseWorkflowSource.contains("'v*'"))
        XCTAssertTrue(releaseWorkflowSource.contains("fetch-depth: 0"))
        XCTAssertTrue(releaseWorkflowSource.contains("git branch --contains HEAD -r | grep -E '(^|[ /])main$'"))
        XCTAssertTrue(releaseWorkflowSource.contains("./scripts/package-release.sh \"${VERSION#v}\""))
        XCTAssertTrue(releaseWorkflowSource.contains("dist/kurotty-*-macos-universal.dmg"))
        XCTAssertTrue(releaseWorkflowSource.contains("dist/kurotty-macos-universal.dmg"))
        XCTAssertTrue(releaseWorkflowSource.contains("dist/appcast.xml"))
        XCTAssertTrue(releaseWorkflowSource.contains("KUROTTY_SPARKLE_PRIVATE_KEY: ${{ secrets.KUROTTY_SPARKLE_PRIVATE_KEY }}"))
        XCTAssertTrue(releaseWorkflowSource.contains("softprops/action-gh-release"))

        XCTAssertTrue(agentsSource.contains("`VERSION` is the single source of truth"))
        XCTAssertTrue(agentsSource.contains("Do not hardcode future release numbers"))
        XCTAssertTrue(agentsSource.contains("stable direct-download alias `kurotty-macos-universal.dmg`"))
        XCTAssertTrue(agentsSource.contains("The installed app About panel must display the bundle `Info.plist` version"))
    }

    func testCoreBridgeDoesNotUseCurrentDirectoryFallbacksInAppBundleMode() throws {
        let source = try coreBridgeSource()
        let coreSource = try terminalCoreSource()
        let surfaceSource = try terminalSurfaceViewSource()
        let inputSource = try terminalInputViewSource()

        XCTAssertTrue(coreSource.contains("public protocol TerminalCore: AnyObject"))
        XCTAssertTrue(coreSource.contains("func copyRow(_ row: UInt32, into buffer: inout [UInt8]) -> Int"))
        XCTAssertTrue(source.contains("final class CoreBridge: TerminalCore,"))
        XCTAssertTrue(source.contains("TerminalCoreCompatibilityDiagnosing,"))
        XCTAssertTrue(source.contains("TerminalCoreMutationSourceDiagnosing,"))
        XCTAssertTrue(source.contains("@unchecked Sendable"))
        XCTAssertTrue(source.contains("let copyRow: CopyRowFn"))
        XCTAssertTrue(source.contains("kurotty_terminal_copy_row"))
        XCTAssertTrue(surfaceSource.contains("private let core: any TerminalCore = TerminalCoreFactory.makeDefaultCore("))
        XCTAssertFalse(surfaceSource.contains("CoreBridge("))
        XCTAssertTrue(inputSource.contains("private let core: any TerminalCore"))
        XCTAssertTrue(inputSource.contains("init(core: any TerminalCore)"))
        XCTAssertTrue(source.contains("static let appBundleExtension = \"app\""))
        XCTAssertTrue(source.contains("Bundle.main.bundleURL.pathExtension == CoreLibraryPath.appBundleExtension"))
        XCTAssertTrue(source.contains("Bundle.main.url(forResource: CoreLibraryPath.dylibName, withExtension: CoreLibraryPath.dylibExtension)"))
        XCTAssertTrue(source.contains("Bundle.main.privateFrameworksURL"))

        guard let appModeRange = source.range(of: "private static func appBundleDylibCandidates() -> [String]") else {
            XCTFail("missing packaged app dylib candidate builder")
            return
        }
        guard let devModeRange = source.range(of: "private static func developmentDylibCandidates() -> [String]") else {
            XCTFail("missing development dylib candidate builder")
            return
        }

        let appModeSource = String(source[appModeRange.lowerBound..<devModeRange.lowerBound])
        XCTAssertFalse(appModeSource.contains("FileManager.default.currentDirectoryPath"))
        XCTAssertFalse(appModeSource.contains("\"./zig-out/lib/libkurotty_core.dylib\""))
        XCTAssertFalse(appModeSource.contains("\"zig-out/lib/libkurotty_core.dylib\""))

        let devModeSource = String(source[devModeRange.lowerBound...])
        XCTAssertTrue(devModeSource.contains("#filePath"))
        XCTAssertTrue(devModeSource.contains("repositoryRootURL()"))
        XCTAssertFalse(devModeSource.contains("FileManager.default.currentDirectoryPath"))
    }

    func testCoreBridgeCopiesRowsThroughZigAbi() throws {
        let dylibPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("zig-out/lib/libkurotty_core.dylib")
            .path
        guard FileManager.default.fileExists(atPath: dylibPath) else {
            throw XCTSkip("zig build has not produced libkurotty_core.dylib")
        }

        let core: any TerminalCore = TerminalCoreFactory.makeDefaultCore(cols: 5, rows: 2)
        core.feed("abcde")
        core.feed("xy")
        var firstRow = [UInt8](repeating: 0, count: 5)
        var secondRow = [UInt8](repeating: 0, count: 3)

        XCTAssertEqual(core.copyRow(0, into: &firstRow), 5)
        XCTAssertEqual(String(decoding: firstRow, as: UTF8.self), "abcde")
        XCTAssertEqual(core.copyRow(1, into: &secondRow), 3)
        XCTAssertEqual(String(decoding: secondRow, as: UTF8.self), "xy ")
    }

    func testTerminalCoreProtocolDoesNotDependOnAppFactoryTypes() throws {
        let coreSource = try terminalCoreSource()
        let factorySource = try terminalCoreFactorySource()

        XCTAssertTrue(coreSource.contains("public protocol TerminalCore: AnyObject"))
        XCTAssertFalse(coreSource.contains("CoreBridge"))
        XCTAssertFalse(coreSource.contains("TerminalCoreFactory"))
        XCTAssertFalse(coreSource.contains("makeDefaultCore"))
        XCTAssertTrue(factorySource.contains("import KurottyCore"))
        XCTAssertTrue(factorySource.contains("enum TerminalCoreFactory"))
        XCTAssertTrue(factorySource.contains("static func makeDefaultCore(cols: UInt32, rows: UInt32) -> any TerminalCore"))
        XCTAssertTrue(factorySource.contains("CoreBridge(cols: cols, rows: rows)"))
    }

    func testTerminalSessionProtocolDoesNotDependOnAppFactoryTypes() throws {
        let sessionSource = try terminalSessionSource()
        let factorySource = try terminalSessionFactorySource()
        let adapterSource = try terminalSessionAdapterSource()

        XCTAssertTrue(sessionSource.contains("protocol TerminalSession: AnyObject"))
        XCTAssertFalse(sessionSource.contains("DarwinPTYTerminalSession"))
        XCTAssertFalse(sessionSource.contains("UnsupportedTerminalSession"))
        XCTAssertFalse(sessionSource.contains("TerminalSessionFactory"))
        XCTAssertFalse(sessionSource.contains("makeDefaultSession"))
        XCTAssertTrue(factorySource.contains("enum TerminalSessionFactory"))
        XCTAssertTrue(factorySource.contains("static func makeDefaultSession() -> any TerminalSession"))
        XCTAssertTrue(factorySource.contains("DefaultTerminalSessionAdapter.makeSession()"))
        XCTAssertFalse(factorySource.contains("#if os(macOS)"))
        XCTAssertFalse(factorySource.contains("DarwinPTYTerminalSession()"))
        XCTAssertFalse(factorySource.contains("UnsupportedTerminalSession()"))

        XCTAssertTrue(adapterSource.contains("protocol TerminalSessionAdapter"))
        XCTAssertTrue(adapterSource.contains("enum DefaultTerminalSessionAdapter"))
        XCTAssertTrue(adapterSource.contains("#if os(macOS)"))
        XCTAssertTrue(adapterSource.contains("DarwinTerminalSessionAdapter.makeSession()"))
        XCTAssertTrue(adapterSource.contains("#elseif os(Linux)"))
        XCTAssertTrue(adapterSource.contains("UnsupportedTerminalSessionAdapter.makeSession(platformName: TerminalSessionPlatformNames.linux)"))
        XCTAssertTrue(adapterSource.contains("#elseif os(Windows)"))
        XCTAssertTrue(adapterSource.contains("UnsupportedTerminalSessionAdapter.makeSession(platformName: TerminalSessionPlatformNames.windows)"))
        XCTAssertTrue(adapterSource.contains("struct DarwinTerminalSessionAdapter: TerminalSessionAdapter"))
        XCTAssertTrue(adapterSource.contains("DarwinPTYTerminalSession()"))
        XCTAssertTrue(adapterSource.contains("struct UnsupportedTerminalSessionAdapter: TerminalSessionAdapter"))
    }
}

private struct TestGlyphVertex {
    let position: SIMD2<Float>
    let uv: SIMD2<Float>
}

private struct TestGlyphInstance {
    let origin: SIMD2<Float>
    let size: SIMD2<Float>
    let uvOrigin: SIMD2<Float>
    let uvSize: SIMD2<Float>
    let color: SIMD4<Float>
}

private struct TestUniforms {
    let viewport: SIMD2<Float>
    let useLinearGlyphSampling: UInt32
}

private struct TestTerminalFrame {
    let size: SIMD2<Int>
    let cellSize: SIMD2<Float>
    let padding: SIMD2<Float>
    let cells: [TestFrameCell]
    let backgrounds: [TestFrameQuad]
    let decorations: [TestFrameQuad]
    let cursor: TestFrameQuad

    func glyphInstance(for cell: TestFrameCell) -> TestGlyphInstance {
        let x = padding.x + Float(cell.column) * cellSize.x
        let y = Float(size.y) - padding.y - cellSize.y * Float(cell.row + 1)
        return TestGlyphInstance(
            origin: SIMD2<Float>(x, y),
            size: SIMD2<Float>(cellSize.x, cellSize.y),
            uvOrigin: SIMD2<Float>(Float(cell.atlasSlot * 4) / 12, 0),
            uvSize: SIMD2<Float>(4.0 / 12.0, 1),
            color: cell.color
        )
    }

    func solidInstance(for quad: TestFrameQuad) -> TestGlyphInstance {
        let x = padding.x + Float(quad.column) * cellSize.x
        let y = Float(size.y) - padding.y - cellSize.y * Float(quad.row + 1) + Float(quad.yOffsetPX)
        return TestGlyphInstance(
            origin: SIMD2<Float>(x, y),
            size: SIMD2<Float>(cellSize.x * Float(quad.width), Float(quad.heightPX)),
            uvOrigin: .zero,
            uvSize: .zero,
            color: quad.color
        )
    }
}

private struct TestFrameCell {
    let column: Int
    let row: Int
    let color: SIMD4<Float>
    let atlasSlot: Int
}

private struct TestFrameQuad {
    let column: Int
    let row: Int
    let width: Int
    let heightPX: Int
    var yOffsetPX = 0
    let color: SIMD4<Float>
}

private struct TestPixel: Equatable {
    let b: UInt8
    let g: UInt8
    let r: UInt8
    let a: UInt8
}

private func unitQuadVertices() -> [TestGlyphVertex] {
    [
        TestGlyphVertex(position: SIMD2<Float>(0, 0), uv: SIMD2<Float>(0, 1)),
        TestGlyphVertex(position: SIMD2<Float>(1, 0), uv: SIMD2<Float>(1, 1)),
        TestGlyphVertex(position: SIMD2<Float>(0, 1), uv: SIMD2<Float>(0, 0)),
        TestGlyphVertex(position: SIMD2<Float>(1, 0), uv: SIMD2<Float>(1, 1)),
        TestGlyphVertex(position: SIMD2<Float>(1, 1), uv: SIMD2<Float>(1, 0)),
        TestGlyphVertex(position: SIMD2<Float>(0, 1), uv: SIMD2<Float>(0, 0)),
    ]
}

private func deterministicAtlasPixels() -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: 12 * 4 * 4)
    for y in 0..<4 {
        for x in 0..<12 {
            let slot = x / 4
            let localX = x % 4
            let alpha: UInt8
            switch slot {
            case 0:
                alpha = localX == y ? 255 : 0
            case 1:
                alpha = (localX + y).isMultiple(of: 2) ? 255 : 96
            default:
                alpha = localX == 1 || y == 2 ? 255 : 32
            }
            let index = (y * 12 + x) * 4
            pixels[index] = 255
            pixels[index + 1] = 255
            pixels[index + 2] = 255
            pixels[index + 3] = alpha
        }
    }
    return pixels
}

private func koreanGlyphAlphaOnlyAtlasPixels() -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
    for y in 0..<4 {
        for x in 0..<4 {
            let index = (y * 4 + x) * 4
            pixels[index] = 255
            pixels[index + 1] = 255
            pixels[index + 2] = 255
            pixels[index + 3] = (1...2).contains(x) && (1...2).contains(y) ? 255 : 0
        }
    }
    return pixels
}

private func makeGlyphPipeline(device: MTLDevice, library: MTLLibrary) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "terminal_glyph_vertex"))
    descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "terminal_glyph_fragment"))
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try device.makeRenderPipelineState(descriptor: descriptor)
}

private func makeSolidPipeline(device: MTLDevice, library: MTLLibrary) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "terminal_glyph_vertex"))
    descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "terminal_solid_fragment"))
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
}

private func nonBlackPixelCount(in pixels: [UInt8]) -> Int {
    stride(from: 0, to: pixels.count, by: 4).reduce(0) { count, index in
        pixels[index] > 0 || pixels[index + 1] > 0 || pixels[index + 2] > 0 ? count + 1 : count
    }
}

private func pixel(atX x: Int, y: Int, width: Int, in pixels: [UInt8]) -> TestPixel {
    let index = (y * width + x) * 4
    return TestPixel(
        b: pixels[index],
        g: pixels[index + 1],
        r: pixels[index + 2],
        a: pixels[index + 3]
    )
}

private func setVertexArrayBytes<T>(_ values: [T], on encoder: MTLRenderCommandEncoder, index: Int) {
    values.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        encoder.setVertexBytes(baseAddress, length: bytes.count, index: index)
    }
}

private func productionMetalShaderSource() throws -> String {
    let source = try terminalMetalViewSource()
    guard let assignmentRange = source.range(of: "let metalShaderSource = \"\"\"") else {
        XCTFail("missing production Metal shader source")
        return ""
    }
    let shaderStart = assignmentRange.upperBound
    guard let shaderEnd = source[shaderStart...].range(of: "\"\"\"")?.lowerBound else {
        XCTFail("unterminated production Metal shader source")
        return ""
    }
    return String(source[shaderStart..<shaderEnd])
}

private func terminalMetalViewSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalMetalView.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func functionBody(named name: String, in source: String) throws -> String {
    guard let signatureRange = source.range(of: "func \(name)") else {
        XCTFail("missing function \(name)")
        return ""
    }
    guard let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{") else {
        XCTFail("missing opening brace for function \(name)")
        return ""
    }

    var depth = 0
    var index = openingBrace
    while index < source.endIndex {
        let character = source[index]
        if character == "{" {
            depth += 1
        } else if character == "}" {
            depth -= 1
            if depth == 0 {
                return String(source[openingBrace...index])
            }
        }
        index = source.index(after: index)
    }

    XCTFail("missing closing brace for function \(name)")
    return ""
}

private func kurottyCoreSourceFiles() throws -> [(filename: String, source: String)] {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyCore")
    let urls = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    return try urls.map { url in
        (url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))
    }
}

private func designTokensSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/DesignTokens.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalSurfaceViewSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalSurfaceView.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func boundedScrollbackRowsSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/BoundedScrollbackRows.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalModelSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalModel.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalScreenSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyCore/TerminalScreen.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalRenderFrameSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyCore/TerminalRenderFrame.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalRendererSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalRenderer.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalFrameRendererSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyCore/TerminalFrameRenderer.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func zigCoreSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("src/core.zig")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalTextStyleSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyCore/TerminalTextStyle.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalColorUtilitiesSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyCore/TerminalColorUtilities.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalTextWidthSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyCore/TerminalTextWidth.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalDiagnosticsSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalDiagnostics.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func scrollIndicatorThumbViewSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/ScrollIndicatorThumbView.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalScrollIndicatorCoordinatorSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalScrollIndicatorCoordinator.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func integerConstant(named name: String, in source: String) throws -> Int {
    let pattern = #"static let \#(name)\s*=\s*([0-9_]+)"#
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    let match = try XCTUnwrap(regex.firstMatch(in: source, range: range))
    let valueRange = try XCTUnwrap(Range(match.range(at: 1), in: source))
    return try XCTUnwrap(Int(source[valueRange].replacingOccurrences(of: "_", with: "")))
}

private func debugOptionsSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/DebugOptions.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func shellSessionSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/ShellSession.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalSessionSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalSession.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalSessionFactorySource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalSessionFactory.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalSessionAdapterSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalSessionAdapter.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func unsupportedTerminalSessionSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/UnsupportedTerminalSession.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func mainMenuSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/MainMenu.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func appSettingsSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/AppSettings.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func settingsDefaultsSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyCore/SettingsDefaults.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func appConstantsSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/AppConstants.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func preferencesWindowControllerSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/PreferencesWindowController.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalWindowControllerSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalWindowController.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalPaneDragCoordinatorSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalPaneDragCoordinator.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func appDelegateSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/AppDelegate.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func updateControllerSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/UpdateController.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func packageManifestSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Package.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func installAppScriptSource() throws -> String {
    try scriptSource(named: "install-app")
}

private func scriptSource(named name: String) throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("scripts/\(name).sh")
    return try String(contentsOf: path, encoding: .utf8)
}

private func workflowSource(named name: String) throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".github/workflows/\(name).yml")
    return try String(contentsOf: path, encoding: .utf8)
}

private func agentsSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("AGENTS.md")
    return try String(contentsOf: path, encoding: .utf8)
}

private func versionSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("VERSION")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalInputViewSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalInputView.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalTextInputRouterSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalTextInputRouter.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func sourceSlice(in source: String, from startPattern: String, to endPattern: String) throws -> Substring {
    let start = try XCTUnwrap(source.range(of: startPattern))
    let end = try XCTUnwrap(source.range(of: endPattern, range: start.upperBound..<source.endIndex))
    return source[start.lowerBound..<end.lowerBound]
}

private func terminalKeyEncoderSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalKeyEncoder.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalNotifierSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalNotifier.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func readmeSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("README.md")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalPaneViewSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalPaneView.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func chromeIconButtonSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/ChromeIconButton.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalCommandDispatcherSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalCommandDispatcher.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalCommandRegistrySource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalCommandRegistry.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func splitTerminalViewSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/SplitTerminalView.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func coreBridgeSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/CoreBridge.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalCoreSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyCore/TerminalCore.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalCoreFactorySource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalCoreFactory.swift")
    return try String(contentsOf: path, encoding: .utf8)
}
