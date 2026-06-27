import AppKit
import CryptoKit
import Metal
import XCTest

final class GlyphRenderingRegressionTests: XCTestCase {
    func testPromptGlyphSnapshotHash() throws {
        let width = 640
        let height = 96
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
            XCTFail("failed to create bitmap context")
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
        ]
        ("skyepodium ~/dev/kurotty 하이" as NSString).draw(at: NSPoint(x: 8, y: 48), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        let digest = SHA256.hash(data: Data(pixels))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(digest, "81cd14e8f75dfe52d74d533fd2ebbca411cccadfe78e65968748ce0f1119390d")
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

    func testMetalGlyphLayoutSeparatesCanonicalCellMetricsFromBitmapBounds() throws {
        let source = try terminalMetalViewSource()

        XCTAssertTrue(source.contains("private struct FontCellMetrics"))
        XCTAssertTrue(source.contains("private var fontCellMetrics: FontCellMetrics"))
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
        XCTAssertTrue(source.contains("let underlinePositionPixels = max(0, descenderPixels - underlineThicknessPixels)"))
        XCTAssertTrue(source.contains("yOffset = physicalPixelsToPoints(CGFloat(fontCellMetrics.underlinePositionPixels))"))
        XCTAssertFalse(source.contains("underlinePositionPixels: max(0, heightPixels - 2)"))
        XCTAssertTrue(source.contains("height: terminalFrame.cellSize.height\n            ).fill()"))
        XCTAssertFalse(source.contains("height: max(1, terminalFrame.cellSize.height - 4)"))
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

    func testPrintableHangulPreservesExistingTuiInputBackground() throws {
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(surfaceSource.contains("let printableStyle = styleForPrintableWrite(row: cursorRow, column: cursorColumn, width: width)"))
        XCTAssertTrue(surfaceSource.contains("screen.set(character: character, row: cursorRow, column: cursorColumn, width: width, style: printableStyle)"))
        XCTAssertTrue(surfaceSource.contains("private func styleForPrintableWrite(row: Int, column: Int, width: Int) -> TerminalTextStyle"))
        XCTAssertTrue(surfaceSource.contains("currentStyle.effectiveBackground.sameColor(as: terminalDefaultStyle.background)"))
        XCTAssertTrue(surfaceSource.contains("existingNonDefaultBackground(row: row, column: column, width: width)"))
        XCTAssertTrue(surfaceSource.contains("style.background = existingBackground"))
    }

    func testMarkedTextStartsAtCursorColumnInAtlasAndFallbackRenderers() throws {
        let source = try terminalMetalViewSource()
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("let markedTextColumn: Int"))
        XCTAssertTrue(source.contains("var column = terminalFrame.markedTextColumn"))
        XCTAssertTrue(surfaceSource.contains("markedTextColumn: cursorColumn"))
        XCTAssertTrue(surfaceSource.contains("cursorColumn: min(cursorColumn + markedText.string.terminalColumnWidth"))
        XCTAssertFalse(source.contains("terminalFrame.cursorColumn - terminalColumnWidth(of: terminalFrame.markedText)"))
    }

    func testMarkedTextCompositionDoesNotPersistSelectionBackgrounds() throws {
        let source = try terminalMetalViewSource()
        let surfaceSource = try terminalSurfaceViewSource()
        let routerSource = try terminalTextInputRouterSource()

        XCTAssertTrue(source.contains("let markedTextSelectedRange: NSRange"))
        XCTAssertTrue(source.contains("markedTextColor(for: character, utf16Offset: utf16Offset)"))
        XCTAssertTrue(source.contains("NSIntersectionRange(characterRange, terminalFrame.markedTextSelectedRange).length > 0"))
        XCTAssertTrue(surfaceSource.contains("markedTextSelectedRange: NSRange(location: NSNotFound, length: 0)"))
        XCTAssertTrue(surfaceSource.contains("private var markedTextAnchor: TerminalCellPosition?"))
        XCTAssertTrue(surfaceSource.contains("private func markMarkedTextDirty()"))
        XCTAssertTrue(routerSource.contains("precomposedStringWithCanonicalMapping"))
        XCTAssertTrue(surfaceSource.contains("TerminalTextInputRouter.committedText(from: string)"))
        XCTAssertTrue(surfaceSource.contains("unmarkText()\n        guard !text.isEmpty else { return }\n        TerminalTextInputRouter.logPTYWrite(text, source: \"insertText\")\n        send(text)"))
        XCTAssertFalse(surfaceSource.contains("appendMarkedTextSelectionBackgrounds(to: &backgrounds)"))
        XCTAssertFalse(surfaceSource.contains("private func selectedMarkedTextRange()"))
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
        XCTAssertTrue(surfaceSource.contains("inputContext?.discardMarkedText()"))
        XCTAssertTrue(inputSource.contains("inputContext?.discardMarkedText()"))
    }

    func testTextKeyDownIsConsumedByAppKitTextInterpreterWithoutRawFallback() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let inputSource = try terminalInputViewSource()
        let routerSource = try terminalTextInputRouterSource()

        for source in [surfaceSource, inputSource] {
            XCTAssertTrue(source.contains("if TerminalTextInputRouter.handleKeyDown(event, in: self, hasMarkedText: hasMarkedText()) {\n            return\n        }\n        if handleTerminalControlKey(event)"))
            XCTAssertTrue(source.contains("TerminalTextInputRouter.logInsertText(text, replacementRange: replacementRange)"))
            XCTAssertTrue(source.contains("TerminalTextInputRouter.logPTYWrite(text, source: \"insertText\")"))
            XCTAssertFalse(source.contains("TerminalTextInputRouter.consumePendingText"))
        }
        XCTAssertTrue(routerSource.contains("if view.inputContext?.handleEvent(event) == true"))
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
        XCTAssertTrue(source.contains("updateMetalFrame()"))
    }

    func testTerminalSurfaceSnapsCellMetricsToPhysicalPixels() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("private var currentBackingScale: CGFloat"))
        XCTAssertTrue(source.contains("let scale = currentBackingScale"))
        XCTAssertTrue(source.contains("let lineHeight = snapMetricToPhysicalPixels(rawLineHeight, scale: scale)"))
        XCTAssertTrue(source.contains("let width = snapMetricToPhysicalPixels(rawWidth, scale: scale)"))
        XCTAssertTrue(source.contains("private func snapMetricToPhysicalPixels(_ value: CGFloat, scale: CGFloat) -> CGFloat"))
        XCTAssertTrue(source.contains("ceil(value * scale) / scale"))
        XCTAssertTrue(source.contains("cellSize: CGSize(width: width, height: lineHeight)"))
    }

    func testGlyphAtlasUsesFontFallbackForPromptSymbols() throws {
        let source = try terminalMetalViewSource()
        XCTAssertTrue(source.contains("private static let glyphFallbackFontNames"))
        XCTAssertTrue(source.contains("private func scaledFont(for character: Character, scale: CGFloat) -> CTFont"))
        XCTAssertTrue(source.contains("CTFontCreateForString"))
        XCTAssertTrue(source.contains("fontSupports(character"))
        XCTAssertTrue(source.contains("Symbols Nerd Font Mono"))
        XCTAssertTrue(source.contains("MesloLGS NF"))
    }

    func testTerminalFrameCarriesTrackedDamageDiagnostics() throws {
        let metalSource = try terminalMetalViewSource()
        XCTAssertTrue(metalSource.contains("let dirtyRows: [Int]"))
        XCTAssertTrue(metalSource.contains("let dirtyRects: [CGRect]"))
        XCTAssertTrue(metalSource.contains("let isFullDamage: Bool"))
        XCTAssertTrue(metalSource.contains("let defaultForeground: SIMD4<Float>"))
        XCTAssertTrue(metalSource.contains("let defaultBackground: SIMD4<Float>"))
        XCTAssertTrue(metalSource.contains("terminalFrame.defaultForeground"))
        XCTAssertTrue(metalSource.contains("var lastFrameDirtyRowsForDiagnostics: [Int]"))
        XCTAssertTrue(metalSource.contains("var lastFrameDirtyRectsForDiagnostics: [CGRect]"))
        XCTAssertTrue(metalSource.contains("var lastFrameDamageWasFullForDiagnostics: Bool"))
        XCTAssertTrue(metalSource.contains("var diagnosticFullRedrawEnabled = true"))
        XCTAssertTrue(metalSource.contains("if diagnosticFullRedrawEnabled || frame.isFullDamage || frame.dirtyRects.isEmpty"))
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
        XCTAssertTrue(source.contains("screen.set(character: character, row: cursorRow, column: cursorColumn, width: width, style: printableStyle)"))
        XCTAssertTrue(source.contains("markDirty(row: cursorRow)\n            cursorColumn += width"))
        XCTAssertFalse(source.contains("screen.insertCharacters(row: cursorRow, column: cursorColumn, count: width"))
    }

    func testFullModelRedrawFlagControlsDirtyRectInvalidation() throws {
        let metalSource = try terminalMetalViewSource()
        let surfaceSource = try terminalSurfaceViewSource()
        let debugSource = try debugOptionsSource()

        XCTAssertTrue(debugSource.contains("static let fullModelRedraw = flag(\"--debug-full-model-redraw\", env: \"KUROTTY_DEBUG_FULL_MODEL_REDRAW\")"))
        XCTAssertTrue(debugSource.contains("static let noDamage = flag(\"--debug-no-damage\", env: \"KUROTTY_DEBUG_NO_DAMAGE\")"))
        XCTAssertTrue(debugSource.contains("static let noScissor = flag(\"--debug-no-scissor\", env: \"KUROTTY_DEBUG_NO_SCISSOR\")"))
        XCTAssertTrue(surfaceSource.contains("metalView.diagnosticFullRedrawEnabled = true"))
        XCTAssertTrue(metalSource.contains("var diagnosticFullRedrawEnabled = true {\n        didSet {\n            setNeedsDisplay(bounds)\n        }\n    }"))
        XCTAssertTrue(metalSource.contains("if diagnosticFullRedrawEnabled || frame.isFullDamage || frame.dirtyRects.isEmpty {\n            setNeedsDisplay(bounds)\n        } else {\n            for rect in frame.dirtyRects {\n                setNeedsDisplay(rect)\n            }\n        }"))
        XCTAssertTrue(metalSource.contains("var lastFrameDamageWasFullForDiagnostics: Bool {\n        terminalFrame.isFullDamage\n    }"))
        XCTAssertTrue(metalSource.contains("fullRedraw=%@"))
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

        XCTAssertTrue(surfaceSource.contains("for character in text {"))
        XCTAssertTrue(surfaceSource.contains("if parserState == .normal && character.isTerminalPrintableGrapheme"))
        XCTAssertTrue(surfaceSource.contains("appendPrintable(String(character))"))
        XCTAssertFalse(surfaceSource.contains("for scalar in text.unicodeScalars {\n            if consumeControl(scalar)"))
        XCTAssertTrue(surfaceSource.contains("private var firstBaseScalarForTerminalWidth: UnicodeScalar?"))
    }

    func testHangulAndCombiningWidthUseClusterPolicyInSurfaceAndMetal() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let metalSource = try terminalMetalViewSource()

        for source in [surfaceSource, metalSource] {
            XCTAssertTrue(source.contains("let widthScalar = firstBaseScalarForTerminalWidth ?? unicodeScalars.first"))
            XCTAssertTrue(source.contains("if unicodeScalars.allSatisfy({ CharacterSet.nonBaseCharacters.contains($0) })"))
            XCTAssertTrue(source.contains("(0xac00...0xd7a3).contains(value)"))
            XCTAssertTrue(source.contains("return 2"))
        }
    }

    func testCombiningMarksAndContinuationOverwriteDoNotLeaveSplitHangulCells() throws {
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(surfaceSource.contains("screen.appendCombining(character: character, row: cursorRow, before: cursorColumn)"))
        XCTAssertTrue(surfaceSource.contains("private mutating func clearWideCellIfNeeded(row: Int, column: Int, style: TerminalTextStyle)"))
        XCTAssertTrue(surfaceSource.contains("guard cells[row][column].isContinuation else { return }"))
        XCTAssertTrue(surfaceSource.contains("cells[row][column - 1] = TerminalScreenCell(style: style)"))
        XCTAssertTrue(surfaceSource.contains("cells[row][column + 1] = TerminalScreenCell(style: style)"))
        XCTAssertTrue(surfaceSource.contains("let merged = String(cells[row][leadColumn].character) + String(character)"))
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
        let tokens = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/KurottyApp/DesignTokens.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private let verticalScroller = NSScroller(frame: .zero)"))
        XCTAssertTrue(source.contains("verticalScroller.target = self"))
        XCTAssertTrue(source.contains("verticalScroller.action = #selector(scrollerDidChange(_:))"))
        XCTAssertTrue(source.contains("@objc private func scrollerDidChange(_ sender: NSScroller)"))
        XCTAssertTrue(source.contains("verticalScroller.knobProportion"))
        XCTAssertTrue(source.contains("verticalScroller.doubleValue = max(0, min(1, 1 - CGFloat(scrollbackOffset) / CGFloat(maxOffset)))"))
        XCTAssertTrue(source.contains("private let scrollThumbView = ScrollIndicatorThumbView(frame: .zero)"))
        XCTAssertTrue(source.contains("scrollThumbView.layer?.backgroundColor = DesignTokens.Color.scrollerThumb.cgColor"))
        XCTAssertTrue(source.contains("let normalizedOffset = max(0, min(1, CGFloat(scrollbackOffset) / CGFloat(maxOffset)))"))
        XCTAssertTrue(source.contains("scrollThumbView.frame = NSRect("))
        XCTAssertTrue(source.contains("scrollbackOffset = nextOffset"))
        XCTAssertTrue(tokens.contains("terminalScrollerWidthPX"))
        XCTAssertTrue(tokens.contains("terminalScrollerThumbWidthPX"))
        XCTAssertTrue(tokens.contains("terminalScrollerMinThumbHeightPX"))
        XCTAssertTrue(tokens.contains("scrollerThumb"))
    }

    func testPtyOutputDoesNotForceFollowWhenUserIsViewingScrollback() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("let scrollbackCountBeforeOutput = scrollbackRows.count"))
        XCTAssertTrue(source.contains("let shouldFollowOutput = scrollbackOffset == 0"))
        XCTAssertTrue(source.contains("if shouldFollowOutput {\n            scrollbackOffset = 0\n        }"))
        XCTAssertTrue(source.contains("let appendedScrollbackCount = max(0, scrollbackRows.count - scrollbackCountBeforeOutput)"))
        XCTAssertTrue(source.contains("scrollbackOffset = min(scrollbackRows.count, scrollbackOffset + appendedScrollbackCount)\n            markFullDamage()"))
        XCTAssertFalse(source.contains("if !text.isEmpty {\n            scrollbackOffset = 0\n        }"))
        XCTAssertTrue(source.contains("updateScrollIndicator()"))
    }

    func testScreenRegionMutatorsPreserveRowsOutsideRegion() throws {
        let source = try terminalSurfaceViewSource()

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

        XCTAssertTrue(shellSource.contains("FileManager.default.homeDirectoryForCurrentUser.path"))
        XCTAssertFalse(shellSource.contains("AppConstants.Shell.defaultWorkingDirectory"))
        XCTAssertFalse(shellSource.contains("strdup(\"-f\")"))
        XCTAssertFalse(shellSource.contains("setenv(\"ZDOTDIR\","))
        XCTAssertFalse(shellSource.contains("zshrcContents"))
        XCTAssertTrue(shellSource.contains("setenv(\"HISTFILE\""))
        XCTAssertTrue(shellSource.contains("let shellName = URL(fileURLWithPath: shell).lastPathComponent"))
        XCTAssertTrue(shellSource.contains("strdup(\"-\\(shellName)\")"))
        XCTAssertTrue(shellSource.contains("let interactive = strdup(\"-i\")"))
        XCTAssertTrue(shellSource.contains("unsetenv(\"ZDOTDIR\")"))
        XCTAssertFalse(shellSource.contains("compinit -d"))
        XCTAssertTrue(shellSource.contains("POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD"))
        XCTAssertTrue(shellSource.contains("ZSH_DISABLE_COMPFIX"))
        XCTAssertTrue(shellSource.contains("unsetenv(\"NO_COLOR\")"))
    }

    func testSettingsOwnWindowSizeAndMenuDoesNotDuplicateSettings() throws {
        let menuSource = try mainMenuSource()
        XCTAssertFalse(menuSource.contains("settingsMenuItem.title = \"Settings\""))
        XCTAssertTrue(menuSource.contains("appMenu.addItem(NSMenuItem(title: \"Settings...\""))

        let settingsSource = try appSettingsSource()
        XCTAssertTrue(settingsSource.contains("static let schemaVersion = 4"))
        XCTAssertTrue(settingsSource.contains("var theme: String"))
        XCTAssertTrue(settingsSource.contains("TerminalThemePreset.lighttyName"))
        XCTAssertTrue(settingsSource.contains("static let lightty = TerminalColorSettings"))
        XCTAssertTrue(settingsSource.contains("foreground: \"#202124\""))
        XCTAssertTrue(settingsSource.contains("background: \"#FFFFFF\""))
        XCTAssertTrue(settingsSource.contains("cursor: \"#111111\""))
        XCTAssertTrue(settingsSource.contains("\"#AFA7F5\""))
        XCTAssertTrue(settingsSource.contains("\"#AB4634\""))
        XCTAssertTrue(settingsSource.contains("\"#55C236\""))
        XCTAssertTrue(settingsSource.contains("\"#E59C26\""))
        XCTAssertTrue(settingsSource.contains("\"#4FC3C7\""))
        XCTAssertTrue(settingsSource.contains("\"#D99518\""))
        XCTAssertTrue(settingsSource.contains("\"#CF75D3\""))
        XCTAssertTrue(settingsSource.contains("\"#35B9BD\""))
        XCTAssertTrue(settingsSource.contains("normalizeTheme(&next)"))

        let surfaceSource = try terminalSurfaceViewSource()
        XCTAssertTrue(surfaceSource.contains("dimmed(weighted, against: background)"))
        XCTAssertTrue(surfaceSource.contains("luminance(background) > 0.5"))
        XCTAssertTrue(surfaceSource.contains("dimBlendAmount(for: color)"))
        XCTAssertTrue(surfaceSource.contains("chroma(color) > 0.08"))
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
        XCTAssertTrue(surfaceSource.contains("case \"c\":"))
        XCTAssertTrue(surfaceSource.contains("send(\"\\u{1b}[?1;2c\")"))

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
        XCTAssertTrue(windowSource.contains("AppSettingsStore.didChangeNotification"))
        XCTAssertTrue(windowSource.contains("@objc private func settingsDidChange(_ notification: Notification)"))
        XCTAssertTrue(windowSource.contains("setContentSize(NSSize(width: settings.window.width, height: settings.window.height))"))
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
        XCTAssertTrue(windowSource.contains("private let tabBarView = NSView()"))
        XCTAssertTrue(windowSource.contains("private let tabStackView = NSStackView()"))
        XCTAssertTrue(windowSource.contains("tabBarView.layer?.backgroundColor = DesignTokens.Color.topChromeBackground.cgColor"))
        XCTAssertTrue(windowSource.contains("tabBarView.layer?.borderColor = DesignTokens.Color.borderHairline.cgColor"))
        XCTAssertTrue(windowSource.contains("tabBarHeightConstraint?.constant = tabView.numberOfTabViewItems > 1"))
        XCTAssertTrue(windowSource.contains("tabBarView.isHidden = tabView.numberOfTabViewItems <= 1"))
        XCTAssertTrue(windowSource.contains("makeTabItemView(title: item.label, index: index, isSelected:"))
        XCTAssertTrue(windowSource.contains("private final class TerminalTabItemView: NSView"))
        XCTAssertTrue(windowSource.contains("ChromeIconButton(title: \"+\""))
        XCTAssertTrue(windowSource.contains("private let closeButton = ChromeIconButton(title: \"×\""))
        XCTAssertTrue(windowSource.contains("override func updateTrackingAreas()"))
        XCTAssertTrue(windowSource.contains("override func mouseEntered(with event: NSEvent)"))
        XCTAssertTrue(windowSource.contains("override func mouseExited(with event: NSEvent)"))
        XCTAssertTrue(windowSource.contains("private func updateAppearance()"))
        XCTAssertTrue(windowSource.contains("layer?.cornerRadius = DesignTokens.Component.terminalTabCornerRadiusPX"))
        XCTAssertTrue(windowSource.contains("DesignTokens.Color.accentBlue.cgColor"))
        XCTAssertTrue(windowSource.contains("DesignTokens.Color.activeTabBackground"))
        XCTAssertTrue(windowSource.contains("DesignTokens.Color.inactiveTabHoverBackground"))
        XCTAssertTrue(windowSource.contains("onSelect: { [weak self] in self?.selectTab(at: index) }"))
        XCTAssertTrue(windowSource.contains("onClose: { [weak self] in self?.closeTab(at: index) }"))
        XCTAssertTrue(windowSource.contains("private func selectTab(at index: Int)"))
        XCTAssertTrue(windowSource.contains("private func closeTab(at index: Int)"))
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
        XCTAssertTrue(designSource.contains("topChromeBackground"))
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
        XCTAssertTrue(surfaceSource.contains("updateWorkingDirectory(fromOsc7: payload)"))
        XCTAssertTrue(surfaceSource.contains("publishTitle()"))
        XCTAssertTrue(surfaceSource.contains("displayTitle()"))
        XCTAssertTrue(surfaceSource.contains("URL(string: payload)"))

        XCTAssertTrue(paneSource.contains("var terminalSurface: TerminalSurfaceView"))
        XCTAssertTrue(splitSource.contains("var primaryTerminalSurface: TerminalSurfaceView?"))
        XCTAssertTrue(splitSource.contains("func containsTerminalSurface(_ surface: TerminalSurfaceView) -> Bool"))
    }

    func testFocusedTerminalDispatchesWindowShortcutsBeforePtyInput() throws {
        let dispatcherSource = try terminalCommandDispatcherSource()
        XCTAssertTrue(dispatcherSource.contains("enum TerminalPaneFocusDirection"))
        XCTAssertTrue(dispatcherSource.contains("case left"))
        XCTAssertTrue(dispatcherSource.contains("case right"))
        XCTAssertTrue(dispatcherSource.contains("case up"))
        XCTAssertTrue(dispatcherSource.contains("case down"))
        XCTAssertTrue(dispatcherSource.contains("flags.subtracting([.command, .option, .numericPad, .function]).isEmpty"))
        XCTAssertTrue(dispatcherSource.contains("paneFocusDirection(forKeyCode: event.keyCode)"))
        XCTAssertTrue(dispatcherSource.contains("case 123:"))
        XCTAssertTrue(dispatcherSource.contains("case 124:"))
        XCTAssertTrue(dispatcherSource.contains("case 125:"))
        XCTAssertTrue(dispatcherSource.contains("case 126:"))
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

    func testEscapeKeyIsSentToTerminalFromAppKitCancelOperation() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let inputSource = try terminalInputViewSource()

        XCTAssertTrue(surfaceSource.contains("case #selector(cancelOperation(_:)):\n            resetMarkedTextForInputSourceChange()\n            send(\"\\u{1b}\")"))
        XCTAssertTrue(inputSource.contains("case #selector(cancelOperation(_:)):\n            resetMarkedTextForInputSourceChange()\n            core.feed(\"\\u{1b}\")"))
        XCTAssertTrue(surfaceSource.contains("case 0x5b:\n        return \"\\u{1b}\""))
        XCTAssertTrue(inputSource.contains("case 0x5b:\n        return \"\\u{1b}\""))
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
        XCTAssertTrue(splitSource.contains("override func drawDivider(in rect: NSRect)"))
        XCTAssertTrue(splitSource.contains("DesignTokens.Color.divider.setFill()"))
        XCTAssertTrue(splitSource.contains("setPosition(position, ofDividerAt: dividerIndex)"))
        XCTAssertTrue(splitSource.contains("let position = totalLength * CGFloat(dividerIndex + 1) / CGFloat(count)"))

        let paneSource = try terminalPaneViewSource()
        XCTAssertTrue(paneSource.contains("private let chromeView = PaneChromeView()"))
        XCTAssertTrue(paneSource.contains("private let activeIndicatorView = NSView()"))
        XCTAssertTrue(paneSource.contains("private let statusDotView = NSView()"))
        XCTAssertTrue(paneSource.contains("private let titleField = NSTextField(labelWithString: \"~ (-zsh)\")"))
        XCTAssertTrue(paneSource.contains("private let closeButton = ChromeIconButton(title: \"×\""))
        XCTAssertTrue(paneSource.contains("var closeRequested: ((TerminalPaneView) -> Void)?"))
        XCTAssertTrue(paneSource.contains("var focusChanged: ((TerminalPaneView) -> Void)?"))
        XCTAssertTrue(paneSource.contains("private final class PaneChromeView: NSView"))
        XCTAssertTrue(paneSource.contains("var onHoverChanged: ((Bool) -> Void)?"))
        XCTAssertTrue(paneSource.contains("var onSelect: (() -> Void)?"))
        XCTAssertTrue(paneSource.contains("chromeView.onSelect = { [weak self] in"))
        XCTAssertTrue(paneSource.contains("private func updateChromeAppearance()"))
        XCTAssertTrue(paneSource.contains("activeIndicatorView.isHidden = !isChromeActive"))
        XCTAssertTrue(paneSource.contains("statusDotView.layer?.backgroundColor = (isChromeActive"))
        XCTAssertTrue(paneSource.contains("DesignTokens.Color.paneHeaderBackground"))
        XCTAssertTrue(paneSource.contains("DesignTokens.Color.paneHeaderHoverBackground"))
        XCTAssertTrue(paneSource.contains("chromeView.layer?.borderColor = DesignTokens.Color.borderHairline.cgColor"))
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
        let metalSource = try terminalMetalViewSource()

        XCTAssertTrue(debugSource.contains("--debug-pty-log"))
        XCTAssertTrue(debugSource.contains("--debug-screen-dump"))
        XCTAssertTrue(debugSource.contains("--debug-layout"))
        XCTAssertTrue(debugSource.contains("--debug-full-model-redraw"))
        XCTAssertTrue(debugSource.contains("--debug-render-rects"))
        XCTAssertTrue(debugSource.contains("--debug-ime-rect"))
        XCTAssertTrue(debugSource.contains("--debug-input-client"))
        XCTAssertTrue(debugSource.contains("--debug-cursor-coordinates"))
        XCTAssertTrue(surfaceSource.contains("Kurotty PTY raw: bytes=%@ decoded=%@"))
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

    func testTerminalNotificationsCoverShellExitAndItermOsc9() throws {
        let shellSource = try shellSessionSource()
        let surfaceSource = try terminalSurfaceViewSource()
        let notifierSource = try terminalNotifierSource()
        let readmeSource = try readmeSource()

        XCTAssertTrue(shellSource.contains("var onExit: ((Int32) -> Void)?"))
        XCTAssertTrue(shellSource.contains("private var waitSource: DispatchSourceProcess?"))
        XCTAssertTrue(shellSource.contains("DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit"))
        XCTAssertTrue(shellSource.contains("waitpid(pid, &status, WNOHANG)"))

        XCTAssertTrue(surfaceSource.contains("private let notifier = TerminalNotifier.shared"))
        XCTAssertTrue(surfaceSource.contains("shell.onExit = { [weak self] status in"))
        XCTAssertTrue(surfaceSource.contains("self?.notifyShellDidExit(status: status)"))
        XCTAssertTrue(surfaceSource.contains("case \"9\":"))
        XCTAssertTrue(surfaceSource.contains("notifyItermOsc9(payload)"))

        XCTAssertTrue(notifierSource.contains("import UserNotifications"))
        XCTAssertTrue(notifierSource.contains("final class TerminalNotifier"))
        XCTAssertTrue(notifierSource.contains("Bundle.main.bundleURL.pathExtension == \"app\""))
        XCTAssertTrue(notifierSource.contains("UNUserNotificationCenter.current()"))
        XCTAssertTrue(notifierSource.contains("guard !didRequestAuthorization, let center else { return }"))
        XCTAssertTrue(notifierSource.contains("guard !NSApp.isActive, let center else { return }"))
        XCTAssertTrue(notifierSource.contains("UNNotificationRequest("))

        XCTAssertTrue(readmeSource.contains("iTerm2-compatible notifications"))
        XCTAssertTrue(readmeSource.contains("printf '\\e]9;Build finished\\a'"))
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

private func terminalWindowControllerSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalWindowController.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func appDelegateSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/AppDelegate.swift")
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

private func terminalCommandDispatcherSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalCommandDispatcher.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func splitTerminalViewSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/SplitTerminalView.swift")
    return try String(contentsOf: path, encoding: .utf8)
}
