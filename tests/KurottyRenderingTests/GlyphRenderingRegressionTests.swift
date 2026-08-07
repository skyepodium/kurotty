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
        XCTAssertTrue(surfaceSource.contains("cursorBlinkOn: TerminalCursorPresentationPolicy.shouldRenderBlinkPhase("))
        XCTAssertTrue(surfaceSource.contains("isFocusedForUser: isTerminalFocusedForUser"))
        XCTAssertTrue(surfaceSource.contains("if isTerminalFocusedForUser {\n            startCursorBlinking()"))
        XCTAssertTrue(surfaceSource.contains("updateCursorBlinkStateForFocus()\n        reportTerminalFocusIfNeeded()"))
        XCTAssertTrue(surfaceSource.contains("stopCursorBlinking(showCursor: true)"))
        XCTAssertTrue(constantsSource.contains("cursorBlinkIntervalSeconds"))
    }

    /// Kept as a source-text assertion, deliberately.
    ///
    /// Cursor height and underline placement come from `fontCellMetrics`, which
    /// is a private struct on `TerminalMetalView`, and both only become visible
    /// as pixels inside a GPU draw against a real drawable. Nothing in
    /// `renderingDiagnostics` reports either, so there is no value a test can
    /// read. What is guarded is that the cursor fills the whole cell height
    /// rather than an ad-hoc `cellHeight - 4`, and that the underline sits at
    /// the font's own `underlinePosition` rather than a fixed offset from the
    /// bottom — both were regressions once.
    ///
    /// The behavioural replacement would be a `fontCellMetrics` accessor
    /// alongside the other `...ForDiagnostics` properties; until that exists
    /// this stays.
    func testCursorAndUnderlineGeometryComeFromTheFontsOwnMetrics() throws {
        let source = try terminalMetalViewSource()

        XCTAssertTrue(source.contains("height: physicalPixelsToPoints(CGFloat(fontCellMetrics.cursorHeightPixels))"))
        XCTAssertTrue(source.contains("font.underlinePosition"))
        XCTAssertTrue(source.contains("yOffset = physicalPixelsToPoints(CGFloat(fontCellMetrics.underlinePositionPixels))"))
        XCTAssertFalse(source.contains("underlinePositionPixels: max(0, heightPixels - 2)"))
        XCTAssertFalse(source.contains("height: max(1, terminalFrame.cellSize.cgHeight - 4)"))
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

    @MainActor
    func testGlyphAtlasEvictsLeastRecentlyUsedSlotAndReRasterizesEvictedGlyphs() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is not available")
        }

        let view = TerminalMetalView(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        let capacity = view.glyphAtlasSlotCapacityForDiagnostics
        XCTAssertGreaterThanOrEqual(capacity, 1_000)

        let firstHangulSyllableScalarValue: UInt32 = 0xAC00
        func hangulCharacter(_ index: Int) -> Character {
            Character(UnicodeScalar(firstHangulSyllableScalarValue + UInt32(index))!)
        }

        view.beginGlyphUsageFrameForTesting()
        for index in 0..<capacity {
            XCTAssertTrue(view.cacheGlyphForTesting(hangulCharacter(index)))
        }
        XCTAssertEqual(view.glyphAtlasCachedGlyphCountForDiagnostics, capacity)
        XCTAssertEqual(view.glyphAtlasEvictionCountForDiagnostics, 0)
        let victim = hangulCharacter(0)
        let victimSlot = try XCTUnwrap(view.cachedGlyphSlotForTesting(victim))

        // Touch every glyph except the victim on a later frame so the LRU choice is deterministic.
        view.beginGlyphUsageFrameForTesting()
        for index in 1..<capacity {
            view.cacheGlyphForTesting(hangulCharacter(index))
        }

        view.beginGlyphUsageFrameForTesting()
        let overflowCharacter = hangulCharacter(capacity)
        XCTAssertTrue(view.cacheGlyphForTesting(overflowCharacter))
        XCTAssertEqual(view.glyphAtlasEvictionCountForDiagnostics, 1)
        XCTAssertNil(view.cachedGlyphSlotForTesting(victim))
        XCTAssertEqual(view.cachedGlyphSlotForTesting(overflowCharacter), victimSlot)

        // The evicted glyph must re-rasterize on next use instead of staying blank forever.
        view.beginGlyphUsageFrameForTesting()
        XCTAssertTrue(view.cacheGlyphForTesting(victim))
        XCTAssertEqual(view.glyphAtlasEvictionCountForDiagnostics, 2)
        XCTAssertNotNil(view.cachedGlyphSlotForTesting(victim))
        XCTAssertEqual(view.glyphAtlasCachedGlyphCountForDiagnostics, capacity)

        // Pathological case: every slot is used by the frame currently being built.
        // The renderer must fall back to a safe empty entry and count the exhaustion.
        view.beginGlyphUsageFrameForTesting()
        for key in view.cachedGlyphKeysForTesting {
            guard let character = key.first, key.count == 1 else { continue }
            view.cacheGlyphForTesting(character)
        }
        XCTAssertEqual(view.glyphAtlasEvictionExhaustionCountForDiagnostics, 0)
        XCTAssertFalse(view.cacheGlyphForTesting(hangulCharacter(capacity + 1)))
        XCTAssertEqual(view.glyphAtlasEvictionExhaustionCountForDiagnostics, 1)
        XCTAssertEqual(view.glyphAtlasCachedGlyphCountForDiagnostics, capacity)
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
        XCTAssertTrue(surfaceSource.contains("if let sequence = TerminalKeyEncoder.sequence(for: selector, state: terminalKeyEncoderState) {\n            flushAccumulatedCommittedText()\n            clearCommittedMarkedTextPrefix()\n            pendingMarkedTextAnchor = nil\n            send(sequence)\n        }"))
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
        // discardMarkedText must never run synchronously inside the global
        // keyboardSelectionDidChange notification; the surface defers it.
        XCTAssertTrue(surfaceSource.contains("DispatchQueue.main.async { [weak self] in\n            self?.inputContext?.discardMarkedText()"))
        XCTAssertFalse(inputSource.contains("inputContext?.discardMarkedText()"))
        XCTAssertTrue(surfaceSource.contains("re-enters AppKit/IMK"))
        XCTAssertTrue(inputSource.contains("re-enter the IME service once per split pane"))
    }

    func testInputSourceChangeCommitsLivePreedit() throws {
        let surfaceSource = try terminalSurfaceViewSource()

        // Switching input source with a live composition must commit the preedit
        // to the PTY before any keystroke on the new source can be written, and
        // IMK's late duplicate commit for the dead composition must be swallowed.
        XCTAssertTrue(surfaceSource.contains("private func commitPendingCompositionForInputSourceChange() {"))
        XCTAssertTrue(surfaceSource.contains("let pendingComposition = committedMarkedTextPrefix + markedText.string"))
        XCTAssertTrue(surfaceSource.contains("let isActiveInputClient = window?.firstResponder === self"))
        XCTAssertTrue(surfaceSource.contains("sendCommittedText(pendingComposition, source: \"inputSourceChange\")"))
        XCTAssertTrue(surfaceSource.contains("inputSourceChangeCommitToSuppress = pendingComposition"))
        // The notification can arrive after the first keystroke on the new
        // source, so keyDown re-checks the input source while composing.
        XCTAssertTrue(surfaceSource.contains("if hasMarkedText(), markedTextInputSourceID != inputContext?.selectedKeyboardInputSource {\n            commitPendingCompositionForInputSourceChange()\n        }"))
        XCTAssertTrue(surfaceSource.contains("if text == suppressed, !hasMarkedText() {"))
        XCTAssertTrue(surfaceSource.contains("markedTextInputSourceID = inputContext?.selectedKeyboardInputSource"))
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
        XCTAssertTrue(routerSource.contains("view.inputContext?.handleEvent(event)"))
        XCTAssertTrue(routerSource.contains("view.interpretKeyEvents([event])"))
        XCTAssertLessThan(
            try XCTUnwrap(routerSource.range(of: "view.inputContext?.handleEvent(event)")).lowerBound,
            try XCTUnwrap(routerSource.range(of: "view.interpretKeyEvents([event])")).lowerBound
        )
        XCTAssertTrue(routerSource.contains("static let textInputKeys: Set<UInt16>"))
        XCTAssertTrue(routerSource.contains("return KeyCode.textInputKeys.contains(event.keyCode)"))
        XCTAssertTrue(routerSource.contains("if hasMarkedText {\n            return true\n        }"))
        XCTAssertTrue(routerSource.contains("flags.contains(.command) || flags.contains(.control)"))
        XCTAssertTrue(routerSource.contains("Kurotty input-client:"))
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

    func testTerminalMetalViewCompletionHandlerDoesNotCaptureMainActorStateOnMetalQueue() throws {
        let metalSource = try terminalMetalViewSource()
        let drawSource = try functionBody(named: "draw", in: metalSource)

        XCTAssertTrue(metalSource.contains("private static func makePresentedCompletionHandler"))
        XCTAssertTrue(drawSource.contains("let presentedCompletionHandler = Self.makePresentedCompletionHandler(onPresented)"))
        XCTAssertTrue(drawSource.contains("commandBuffer.addCompletedHandler(presentedCompletionHandler)"))
        XCTAssertFalse(drawSource.contains("commandBuffer.addCompletedHandler { [weak self]"))
        XCTAssertFalse(drawSource.contains("self?.onPresented?()"))
    }

    /// Kept as a source-text assertion, deliberately.
    ///
    /// A TUI's repaint arrives as several PTY reads: clear the region, then
    /// write it back. Rendering each read on arrival shows the cleared frame,
    /// which is the flicker this guards. The observable difference is a frame
    /// that exists for one display interval and is then overwritten — the
    /// renderer keeps no frame history, so nothing after the fact distinguishes
    /// "coalesced" from "rendered twice, quickly".
    ///
    /// Reduced to the two statements that carry the contract. The deferred
    /// flush itself is exercised (not asserted) by
    /// `TerminalSurfaceScrollbackFollowTests`, which drives the same async
    /// output path end to end. The behavioural replacement is a rendered-frame
    /// counter on the renderer.
    func testPtyOutputIsCoalescedBeforeRendering() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("private func enqueueOutput(_ text: String)"))
        XCTAssertTrue(source.contains("DispatchQueue.main.asyncAfter"))
        // The direct `appendOutput` call from the read callback is what
        // reintroduces per-read rendering.
        XCTAssertFalse(source.contains("self?.appendOutput(text)"))
    }

    func testTrailingNonDefaultBackgroundCellsAreRendered() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let metalSource = try terminalMetalViewSource()

        XCTAssertTrue(surfaceSource.contains("private func shouldRenderBackground(for cell: TerminalScreenCell) -> Bool"))
        XCTAssertTrue(surfaceSource.contains("guard !cell.style.effectiveBackground.sameColor(as: terminalDefaultStyle.background) else"))
        XCTAssertTrue(surfaceSource.contains("cell.style == .default"))
        XCTAssertFalse(surfaceSource.contains("cell.character == \" \", !cell.isContinuation, cell.style == .default"))
        XCTAssertTrue(surfaceSource.contains("renderedBackground = cell.style.effectiveBackground"))
        XCTAssertTrue(surfaceSource.contains("color: renderedBackground"))
        XCTAssertTrue(metalSource.contains(".filter { $0.row >= 0 && $0.row < terminalFrame.visibleRows && !$0.color.sameColor(as: terminalFrame.defaultBackground) }"))
        XCTAssertTrue(metalSource.contains("last.column + last.width == background.column"))
        XCTAssertTrue(metalSource.contains("last.width += 1"))
        XCTAssertFalse(metalSource.contains("backgroundRunsExcludingInputLine"))
    }

    /// Kept as a source-text assertion, deliberately.
    ///
    /// Each `DebugOptions` flag is a `static let` resolved from `CommandLine`
    /// and the environment at process load, and the `flag(_:env:)` helper that
    /// resolves it is private. By the time a test runs, the value is already
    /// fixed, so no test can observe which argument or environment variable a
    /// flag reads. What is being pinned is the spelling of the documented
    /// `--debug-*` switches and `KUROTTY_DEBUG_*` variables — a renamed switch
    /// silently stops working for anyone following the docs.
    ///
    /// The redraw behaviour these flags select is covered behaviourally by
    /// `TerminalRenderDamageDiagnosticsTests`, so only the spellings remain.
    func testDocumentedDebugSwitchesKeepTheirArgumentAndEnvironmentSpelling() throws {
        let debugSource = try debugOptionsSource()

        XCTAssertTrue(debugSource.contains("static let fullModelRedraw = flag(\"--debug-full-model-redraw\", env: \"KUROTTY_DEBUG_FULL_MODEL_REDRAW\")"))
        XCTAssertTrue(debugSource.contains("static let noDamage = flag(\"--debug-no-damage\", env: \"KUROTTY_DEBUG_NO_DAMAGE\")"))
        XCTAssertTrue(debugSource.contains("static let noScissor = flag(\"--debug-no-scissor\", env: \"KUROTTY_DEBUG_NO_SCISSOR\")"))
        XCTAssertTrue(debugSource.contains("static let scrollRegion = flag(\"--debug-scroll-region\", env: \"KUROTTY_DEBUG_SCROLL_REGION\")"))
    }

    /// Kept as source-text assertions, deliberately.
    ///
    /// Both are per-frame allocation contracts. `TerminalMetalView` exposes no
    /// allocation or rebuild counter, and Metal reports none either, so there is
    /// no value a test can read that differs between "reused the buffer" and
    /// "allocated a new one every frame" — the only observable difference is
    /// throughput, and this suite has no timing harness. Reduced to the two
    /// statements that actually matter; the per-field `hasher.combine` lines the
    /// signature test used to pin were implementation detail.
    ///
    /// The behavioural replacement is a frame-allocation counter on the view,
    /// or the benchmark target the roadmap wants.
    func testPerFrameRendererWorkIsGuardedAgainstReallocationAndRedundantRebuilds() throws {
        let metalSource = try terminalMetalViewSource()
        let uploadSource = try functionBody(named: "uploadPendingInstanceBuffersIfNeeded", in: metalSource)
        let dirtySource = try functionBody(named: "atlasBuffersNeedRebuild", in: metalSource)

        // Instance buffers are memcpy'd into, not reallocated, once the byte
        // length is stable.
        XCTAssertFalse(uploadSource.contains("makeBuffer(bytes:"))
        // The atlas rebuild is gated on a signature of the render inputs, and
        // reading the signature must not also commit it — that would make every
        // frame look unchanged.
        XCTAssertTrue(dirtySource.contains("return nextSignature != lastAtlasBufferSignature"))
        XCTAssertFalse(dirtySource.contains("lastAtlasBufferSignature = nextSignature"))
    }

    func testShellSessionStartsInHomeWithInteractiveZshUsability() throws {
        let shellSource = try shellSessionSource()
        let sessionSource = try terminalSessionSource()
        let surfaceSource = try terminalSurfaceViewSource()

        XCTAssertTrue(sessionSource.contains("protocol TerminalSession: AnyObject"))
        XCTAssertFalse(shellSource.contains("protocol TerminalSession"))
        XCTAssertTrue(shellSource.contains("final class DarwinPTYTerminalSession: TerminalSession, TerminalShellLaunchConfigurable, TerminalShellProcessIdentifying, TerminalSessionInputBackpressureReporting, @unchecked Sendable"))
        // The status bar's right segment has no processes to sample unless the
        // PTY session publishes its child pid through the optional seam.
        XCTAssertTrue(shellSource.contains("var shellProcessIdentifier: pid_t { childPid }"))
        XCTAssertTrue(shellSource.contains("foregroundProcessGroup: tcgetpgrp(master)"))
        XCTAssertTrue(shellSource.contains("killpg(processGroup, SIGWINCH)"))
        XCTAssertTrue(shellSource.contains("#if os(macOS)"))
        XCTAssertTrue(shellSource.contains("import Darwin"))
        XCTAssertTrue(surfaceSource.contains("private let shell: any TerminalSession"))
        XCTAssertTrue(surfaceSource.contains("self.init(frame: frameRect, session: TerminalSessionFactory.makeDefaultSession())"))
        XCTAssertFalse(surfaceSource.contains("private let shell = DarwinPTYTerminalSession()"))
        XCTAssertFalse(surfaceSource.contains("DarwinPTYTerminalSession()"))
        XCTAssertTrue(shellSource.contains("FileManager.default.homeDirectoryForCurrentUser.path"))
        XCTAssertTrue(shellSource.contains("func start(workingDirectory requestedWorkingDirectory: String)"))
        XCTAssertTrue(shellSource.contains("let workingDirectory = ShellSettings.normalizedWorkingDirectory(requestedWorkingDirectory)"))
        XCTAssertTrue(shellSource.contains("TerminalShellIntegrationBootstrap.bundledConfiguration(shellPath: shellPath)"))
        XCTAssertTrue(shellSource.contains("launchConfiguration: launchConfiguration"))
        XCTAssertFalse(shellSource.contains("AppConstants.Shell.defaultWorkingDirectory"))
        XCTAssertFalse(shellSource.contains("strdup(\"-f\")"))
        XCTAssertFalse(shellSource.contains("setenv(\"ZDOTDIR\","))
        XCTAssertFalse(shellSource.contains("zshrcContents"))
        // HISTFILE is now per-project and check-before-set: a user-configured
        // HISTFILE must survive, and the global file is only the fallback.
        XCTAssertTrue(shellSource.contains("setenv(\"HISTFILE\", perProjectHistoryFilePath, 1)"))
        XCTAssertTrue(shellSource.contains("} else if mayExportGlobalHistoryFallback {"))
        XCTAssertTrue(shellSource.contains("TerminalShellHistoryEnvironment.resolvedHistoryFilePath("))
        XCTAssertTrue(shellSource.contains("inheritedHistoryFile: inheritedHistoryFile"))
        XCTAssertTrue(shellSource.contains("if chdir(workingDirectory) == 0"))
        XCTAssertTrue(shellSource.contains("actualWorkingDirectory = homeDirectory"))
        XCTAssertTrue(shellSource.contains("setenv(\"PWD\", actualWorkingDirectory, 1)"))
        XCTAssertTrue(shellSource.contains("([launchConfiguration.argumentZero] + launchConfiguration.arguments)"))
        XCTAssertTrue(shellSource.contains("for (key, value) in launchConfiguration.environment"))
        XCTAssertFalse(shellSource.contains("unsetenv(\"ZDOTDIR\")"))
        XCTAssertTrue(shellSource.contains("setenv(\"TERM_PROGRAM\""))
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

    func testShellSessionDrainsFinalPTYOutputBeforeReportingChildExit() throws {
        let shellSource = try shellSessionSource()
        guard let handlerRange = shellSource.range(of: "private func handleChildExit(_ pid: pid_t)"),
              let nextFunctionRange = shellSource.range(
                  of: "private func scheduleOutputDrain()",
                  range: handlerRange.upperBound..<shellSource.endIndex
              )
        else {
            return XCTFail("missing child-exit handler boundaries")
        }
        let handler = shellSource[handlerRange.lowerBound..<nextFunctionRange.lowerBound]
        guard let drainRange = handler.range(of: "drainOutput(master, mode: .final)"),
              let exitRange = handler.range(of: "self?.onExit?(exitStatus)")
        else {
            return XCTFail("child exit must drain final PTY output before notifying observers")
        }

        XCTAssertLessThan(drainRange.lowerBound, exitRange.lowerBound)
    }

    func testTerminalSurfacePreservesFinalOutputBeforeTmuxTransportExit() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        guard let outputRange = surfaceSource.range(of: "shell.onOutput = { [weak self] text in"),
              let exitRange = surfaceSource.range(of: "shell.onExit = { [weak self] status in"),
              let runtimeRange = surfaceSource.range(
                  of: "shell.onRuntimeEvent = { [weak self] event in",
                  range: exitRange.upperBound..<surfaceSource.endIndex
              )
        else {
            return XCTFail("terminal surface must install ordered output and exit callbacks")
        }

        XCTAssertLessThan(outputRange.lowerBound, exitRange.lowerBound)
        let callbackSource = surfaceSource[outputRange.lowerBound..<runtimeRange.lowerBound]
        XCTAssertEqual(callbackSource.components(separatedBy: "DispatchQueue.main.async").count - 1, 2)
    }

    func testShellSessionEnqueuesPTYWritesOffCallerThread() throws {
        let shellSource = try shellSessionSource()

        XCTAssertTrue(shellSource.contains("private var pendingInput = Data()"))
        XCTAssertTrue(shellSource.contains("private var pendingInputStartIndex = 0"))
        XCTAssertTrue(shellSource.contains("private var isInputDrainScheduled = false"))
        XCTAssertTrue(shellSource.contains("private func enqueueInput(_ data: Data)"))
        XCTAssertTrue(shellSource.contains("private func drainInput()"))
        XCTAssertTrue(shellSource.contains("private func writeInputChunk(_ fd: Int32) -> Bool"))
        XCTAssertTrue(shellSource.contains("private func compactPendingInputIfNeeded()"))
        // Pending output moved to TerminalPendingOutputBuffer, whose retention
        // and drop accounting are covered by behavioural tests instead.
        XCTAssertTrue(shellSource.contains("readQueue.async { [weak self] in"))
        XCTAssertTrue(shellSource.contains("self?.enqueueInput(data)"))
        XCTAssertTrue(shellSource.contains("scheduleOutputDrain()"))
        XCTAssertTrue(shellSource.contains("readQueue.asyncAfter(deadline: .now() + .microseconds(Int(AppConstants.Shell.ptyWriteRetryDelayMicros)))"))
        XCTAssertFalse(shellSource.contains("Darwin.write(master"))
        XCTAssertFalse(shellSource.contains("usleep(AppConstants.Shell.ptyWriteRetryDelayMicros)"))
        XCTAssertFalse(shellSource.contains("pendingInput.removeFirst"))
        XCTAssertFalse(shellSource.contains("pendingOutput.removeFirst"))
    }

    /// What survives from `testSettingsOwnWindowSizeAndMenuDoesNotDuplicateSettings`,
    /// which had grown into a sixty-assertion grab-bag covering the menu, the
    /// settings schema, the light palette, the theme remap, and four VT
    /// capability replies.
    ///
    /// Everything with a runtime witness moved out:
    /// - the light palette and the theme remap, to `TerminalThemeApplicationTests`
    /// - window size clamping, already covered by `AppSettingsBehaviorTests`
    /// - style and colour remapping, already covered by `AppSettingsBehaviorTests`
    ///   and `BoundedScrollbackRowsTests`
    /// - CPR, DA and the OSC colour queries, already covered by
    ///   `TerminalCapabilityRepliesTests`
    ///
    /// Left here: the schema version as a value, and the two menu facts. The
    /// menu is only reachable through `MainMenu.install(target: AppDelegate)`,
    /// which mutates `NSApp.mainMenu` and needs a real app delegate; there is
    /// no `makeMenu()` factory to call. That seam is the behavioural
    /// replacement, and `MenuBarExtraTests` shows what the test would look like
    /// once it exists.
    func testSettingsIsOneMenuItemAndTheSchemaVersionIsPinned() throws {
        XCTAssertEqual(SettingsDefaults.schemaVersion, 22)

        let menuSource = try mainMenuSource()
        XCTAssertTrue(menuSource.contains("appMenu.addItem(NSMenuItem(title: AppLocalization.string(.settings)"))
        // The old hand-titled duplicate must not come back alongside it.
        XCTAssertFalse(menuSource.contains("settingsMenuItem.title = \"Settings\""))
    }

    func testAppMenuIncludesNativeAboutPanelWithVersionAndIcon() throws {
        let menuSource = try mainMenuSource()
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.format(.about, AppConstants.Bundle.displayName), action: #selector(AppDelegate.showAboutPanel), keyEquivalent: \"\")"))
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
        XCTAssertTrue(appDelegateSource.contains("AppLocalization.string(.updateUnavailableTitle)"))
        XCTAssertTrue(appDelegateSource.contains("AppLocalization.string(.updateUnavailableMessage)"))
        XCTAssertTrue(appDelegateSource.contains("alert.addButton(withTitle: AppLocalization.string(.ok))"))
        XCTAssertFalse(appDelegateSource.contains("showReleaseURL()"))
        XCTAssertFalse(appDelegateSource.contains("NSWorkspace.shared.open(url)"))

        let menuSource = try mainMenuSource()
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.checkForUpdates), action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: \"\")"))

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
        XCTAssertTrue(packageReleaseSource.contains("SPARKLE_PUBLIC_KEY=\"${KUROTTY_SPARKLE_PUBLIC_KEY:-}\""))
        XCTAssertTrue(installSource.contains("SPARKLE_PUBLIC_KEY=\"${KUROTTY_SPARKLE_PUBLIC_KEY:-}\""))
        XCTAssertTrue(installSource.contains("Skipping Sparkle metadata: KUROTTY_SPARKLE_PUBLIC_KEY is not set."))
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

    func testPreferencesGUIUsesBoundedScrollableSections() throws {
        let preferencesSource = try preferencesViewSource()

        XCTAssertTrue(preferencesSource.contains("private lazy var detailScrollView = NSScrollView()"))
        XCTAssertTrue(preferencesSource.contains("documentView.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor)"))
        XCTAssertTrue(preferencesSource.contains("section(title:"))
        XCTAssertFalse(preferencesSource.contains("NSTextView"))
    }

    func testPreferencesGUIAutosavesTypedSettingsAndExposesThemePreview() throws {
        let preferencesSource = try preferencesViewSource()
        let previewSource = try preferencesThemePreviewViewSource()

        XCTAssertTrue(preferencesSource.contains("try store.save(snapshot)"))
        XCTAssertTrue(preferencesSource.contains("scheduleAutosave()"))
        XCTAssertTrue(preferencesSource.contains("themePopup.addItems"))
        XCTAssertTrue(preferencesSource.contains("settings.terminal.theme = TerminalThemePreset.customName"))
        XCTAssertTrue(preferencesSource.contains("lazy var previewView = PreferencesThemePreviewView()"))
        XCTAssertTrue(previewSource.contains("draw(\"$ git status\""))
        XCTAssertTrue(previewSource.contains("colors.ansi"))
        XCTAssertFalse(preferencesSource.contains("schemaVersion"))
        XCTAssertFalse(preferencesSource.contains("NSButton(title: \"Save\""))
        XCTAssertFalse(preferencesSource.contains("NSButton(title: \"Reload\""))
    }

    // The settings window this file used to assert on (centered, activated,
    // brought to front) no longer exists: settings is a center tab, and
    // `PreferencesSettingsTabTests` covers opening and revealing it for real.

    func testTerminalWindowCommandsExposeTabAndSplitShortcuts() throws {
        let menuSource = try mainMenuSource()
        XCTAssertTrue(menuSource.contains("let fileMenu = NSMenu(title: AppLocalization.string(.shell))"))
        XCTAssertFalse(menuSource.contains("NSMenu(title: \"File\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.newTab), action: #selector(AppDelegate.newTab), keyEquivalent: \"t\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.closePaneOrTab), action: #selector(AppDelegate.closeCurrentPane), keyEquivalent: \"w\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.splitVertically), action: #selector(AppDelegate.splitVertically), keyEquivalent: \"d\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.splitHorizontally), action: #selector(AppDelegate.splitHorizontally), keyEquivalent: \"D\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.previousTab), action: #selector(AppDelegate.selectPreviousTab), keyEquivalent: \"[\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.nextTab), action: #selector(AppDelegate.selectNextTab), keyEquivalent: \"]\")"))
        XCTAssertTrue(menuSource.contains("title: AppLocalization.string(.findTerminalOutput)"))
        XCTAssertTrue(menuSource.contains("action: #selector(AppDelegate.findTerminalOutput)"))
        XCTAssertTrue(menuSource.contains("keyEquivalent: \"f\""))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.commandPalette) + \"...\", action: #selector(AppDelegate.openCommandPalette), keyEquivalent: \"P\")"))
        XCTAssertFalse(menuSource.contains("NSMenuItem(title: \"Close Pane\""))
        XCTAssertFalse(menuSource.contains("NSMenuItem(title: \"Enter Copy Mode\""))
        XCTAssertFalse(menuSource.contains("NSMenuItem(title: \"Quick Terminal\""))
        XCTAssertFalse(menuSource.contains("NSMenuItem(title: \"Save Workspace Snapshot\""))

        let delegateSource = try appDelegateSource()
        XCTAssertTrue(delegateSource.contains("@objc func closeCurrentTab()"))
        XCTAssertTrue(delegateSource.contains("@objc func closeCurrentPane()"))
        XCTAssertTrue(delegateSource.contains("@objc func selectNextTab()"))
        XCTAssertTrue(delegateSource.contains("@objc func selectPreviousTab()"))
        XCTAssertTrue(delegateSource.contains("@objc func findTerminalOutput()"))
    }

    func testCommandPaletteUsesExpandedWindowSizeTokens() throws {
        let paletteSource = try commandPaletteWindowControllerSource()
        let designSource = try designTokensSource()

        XCTAssertTrue(designSource.contains("static let commandPaletteWidthPX: CGFloat = 680"))
        XCTAssertTrue(designSource.contains("static let commandPaletteHeightPX: CGFloat = 500"))
        XCTAssertTrue(paletteSource.contains("width: DesignTokens.Component.commandPaletteWidthPX"))
        XCTAssertTrue(paletteSource.contains("height: DesignTokens.Component.commandPaletteHeightPX"))
    }

    func testMainMenuHidesEditMenuWhileKeepingEditingShortcuts() throws {
        let menuSource = try mainMenuSource()

        XCTAssertTrue(menuSource.contains("editMenuItem.isHidden = true"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.cut), action: #selector(NSText.cut(_:)), keyEquivalent: \"x\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.copy), action: #selector(NSText.copy(_:)), keyEquivalent: \"c\")"))
        XCTAssertTrue(menuSource.contains("NSMenuItem(title: AppLocalization.string(.paste), action: #selector(NSText.paste(_:)), keyEquivalent: \"v\")"))
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
        // Dropped 2026-08: the tab bar's bottom hairline was retired when the
        // ground below it became the same chrome surface, so the rule was a
        // border between a surface and itself.
        // The chrome bar hosts the sidebar toggles, so it no longer collapses with a single tab.
        XCTAssertTrue(windowSource.contains("tabBarHeightConstraint?.constant = DesignTokens.Component.terminalTabBarHeightPX"))
        XCTAssertTrue(windowSource.contains("tabBarView.isHidden = false"))
        XCTAssertTrue(windowSource.contains("makeTabItemView(title: item.label, index: index, isSelected:"))
        XCTAssertTrue(windowSource.contains("final class TerminalTabItemView: NSView"))
        // Re-pointed 2026-08: the tab add/close affordances were text glyphs
        // ("+" / "×") typed into a button title. They are now SF Symbols from
        // the shared `IconSymbol` registry, so they scale with the icon ramp
        // and carry a real accessibility label instead of punctuation. The
        // assertions are kept (rather than deleted) so a silent regression back
        // to a typed glyph still fails. The accent hover wash they deliberately
        // keep is now a named token rather than an inline 0.18.
        XCTAssertTrue(windowSource.contains("symbolName: IconSymbol.add"))
        XCTAssertTrue(windowSource.contains("symbolName: IconSymbol.close"))
        XCTAssertFalse(windowSource.contains("ChromeIconButton(title:"))
        XCTAssertTrue(windowSource.contains("addButton.applyChromeTheme(chromeTheme)"))
        XCTAssertTrue(windowSource.contains("closeButton.applyChromeTheme(chromeTheme)"))
        XCTAssertTrue(windowSource.contains("DesignTokens.Component.terminalTabButtonHoverAlphaRATIO"))
        XCTAssertEqual(DesignTokens.Component.terminalTabButtonHoverAlphaRATIO, 0.18)
        XCTAssertTrue(try chromeIconButtonSource().contains("override func resetCursorRects()"))
        // Icon-only controls use a hand cursor so their hover state reads as
        // actionable before the tooltip delay completes.
        XCTAssertTrue(try chromeIconButtonSource().contains("addCursorRect(bounds, cursor: .pointingHand)"))
        XCTAssertTrue(windowSource.contains("override func updateTrackingAreas()"))
        XCTAssertTrue(windowSource.contains("override func mouseEntered(with event: NSEvent)"))
        XCTAssertTrue(windowSource.contains("override func mouseExited(with event: NSEvent)"))
        XCTAssertTrue(windowSource.contains("let location = convert(event.locationInWindow, from: nil)"))
        XCTAssertTrue(windowSource.contains("guard !bounds.contains(location) else { return }"))
        XCTAssertTrue(windowSource.contains("private func updateAppearance()"))
        // Re-pointed: the tab radius moved onto the shared `Radius` scale, the
        // selected outline was replaced by an accent top rail, and hover uses
        // a stronger tab-specific achromatic wash so it stays visible without
        // borrowing the accent's meaning. An unselected tab has no resting fill.
        XCTAssertTrue(windowSource.contains("layer?.cornerRadius = DesignTokens.Radius.mdPX"))
        XCTAssertTrue(windowSource.contains("selected ? chromeTheme.surfaceRaised : .clear"))
        XCTAssertFalse(windowSource.contains("selectionRailView"))
        XCTAssertTrue(windowSource.contains("Self.hoverOverlayColor(for: chromeTheme).cgColor"))
        XCTAssertEqual(DesignTokens.Component.terminalTabHoverFillAlphaRATIO, 0.10)
        XCTAssertTrue(windowSource.contains("selected ? chromeTheme.surfaceRaised : .clear"))
        XCTAssertFalse(windowSource.contains("terminalTabShadow"))
        XCTAssertTrue(windowSource.contains("onSelect: { [weak self] in self?.selectTab(at: index) }"))
        XCTAssertTrue(windowSource.contains("onClose: { [weak self] in self?.closeTab(at: index) }"))
        XCTAssertTrue(windowSource.contains("private func selectTab(at index: Int)"))
        XCTAssertTrue(windowSource.contains("private func closeTab(at index: Int)"))
        XCTAssertTrue(windowSource.contains("closeButtonAlpha: closeButton.alphaValue"))
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
        XCTAssertTrue(designSource.contains("terminalTabMinWidthPX"))
        XCTAssertTrue(designSource.contains("terminalTabMaxWidthPX"))
        XCTAssertTrue(designSource.contains("terminalTabPlusWidthPX"))
        XCTAssertTrue(designSource.contains("terminalTabCloseWidthPX"))
        XCTAssertTrue(designSource.contains("terminalTabStackGapPX"))
        XCTAssertTrue(designSource.contains("terminalTabStackInsetTopPX"))
        // The shadow tokens were dead: `terminalTabShadowOpacity` was 0.
        XCTAssertFalse(designSource.contains("terminalTabShadowOpacity"))
        XCTAssertTrue(windowSource.contains("private let topBarSeparatorView = NSView()"))
        XCTAssertTrue(windowSource.contains("topBarSeparatorView.heightAnchor.constraint"))
        XCTAssertTrue(designSource.contains("topChromeBackground"))
        // The ramp's own hex values belong to DesignTokenColorRampTests, which
        // asserts them through resolved sRGB components rather than by matching
        // this file's text; pinning them here made a tab-bar test fail on every
        // palette change. The `calibratedRed:` guard stays because it is a
        // repo-wide construction rule, not a value.
        XCTAssertFalse(designSource.contains("calibratedRed"))
        XCTAssertTrue(designSource.contains("activeTabBackground"))
        XCTAssertTrue(designSource.contains("inactiveTabBackground"))
        XCTAssertTrue(designSource.contains("accent: NSColor"))
        // Purple is a syntax color only; it must not reappear as a chrome role.
        XCTAssertFalse(designSource.contains("accentPurple"))
        XCTAssertTrue(designSource.contains("borderHairline"))
    }

    func testTerminalSurfacePublishesOscTitleAndDirectoryForTabs() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let interpreterSource = try terminalOutputInterpreterSource()
        let paneSource = try terminalPaneViewSource()
        let splitSource = try splitTerminalViewSource()

        XCTAssertTrue(surfaceSource.contains("static let titleDidChangeNotification"))
        XCTAssertTrue(surfaceSource.contains("static let focusDidChangeNotification"))
        XCTAssertTrue(surfaceSource.contains("static let titleNotificationKey"))
        XCTAssertTrue(surfaceSource.contains("override func becomeFirstResponder() -> Bool"))
        XCTAssertTrue(interpreterSource.contains("case \"0\", \"1\", \"2\":"))
        XCTAssertTrue(interpreterSource.contains("case \"7\":"))
        XCTAssertTrue(interpreterSource.contains("var shellIntegration = TerminalShellIntegration("))
        XCTAssertTrue(surfaceSource.contains("private func dispatchTerminalIntegrationOsc(_ command: String) -> TerminalOSCDispatcher.Event"))
        XCTAssertTrue(surfaceSource.contains("TerminalOSCDispatcher("))
        XCTAssertTrue(surfaceSource.contains("TerminalOSC52Policy(policy: securityPolicy)"))
        XCTAssertTrue(surfaceSource.contains("shellIntegration = dispatcher.shellIntegration"))
        // Re-pointed with the OSC 7 host capture: the event now carries a
        // `TerminalWorkingDirectoryLocation` (path plus remote host) instead
        // of a bare path string.
        XCTAssertTrue(interpreterSource.contains("if case let .shellIntegration(.workingDirectoryChanged(location)) = terminalEvent"))
        XCTAssertTrue(interpreterSource.contains("currentWorkingDirectory = location.path"))
        XCTAssertTrue(interpreterSource.contains("currentWorkingDirectoryRemoteHost = location.remoteHost"))
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
                of: "private func layoutOnlyTabDescriptors("
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
        // Was a source-text match on the literal key code 123. The registry now
        // names its arrow key codes, and the binding is worth asserting through
        // the registry rather than through the text that builds it.
        let focusPaneLeft = TerminalCommandRegistry.default.windowCommands.first { $0.id == .focusPaneLeft }
        XCTAssertEqual(focusPaneLeft?.shortcut?.keyCode, 123)
        XCTAssertEqual(focusPaneLeft?.shortcut?.modifiers, .command)
        XCTAssertTrue(dispatcherSource.contains("controller.focusPane(direction)"))
        XCTAssertTrue(dispatcherSource.contains("controller.newTab()"))
        XCTAssertTrue(dispatcherSource.contains("controller.splitVertically()"))
        XCTAssertTrue(dispatcherSource.contains("controller.splitHorizontally()"))
        XCTAssertTrue(dispatcherSource.contains("controller.closeCurrentPane()"))
        XCTAssertTrue(dispatcherSource.contains("controller.selectPreviousTab()"))
        XCTAssertTrue(dispatcherSource.contains("controller.selectNextTab()"))
        XCTAssertTrue(dispatcherSource.contains("controller.findTerminalOutput()"))

        let surfaceSource = try terminalSurfaceViewSource()
        XCTAssertTrue(surfaceSource.contains("TerminalCommandDispatcher.dispatchWindowCommand(from: self, event: event)"))

        let inputSource = try terminalInputViewSource()
        XCTAssertTrue(inputSource.contains("TerminalCommandDispatcher.dispatchWindowCommand(from: self, event: event)"))
    }

    func testLegacyTmuxPrefixMenuIsNotExposed() throws {
        let constantsSource = try appConstantsSource()
        XCTAssertFalse(constantsSource.contains("enum Tmux"))

        let menuSource = try mainMenuSource()
        XCTAssertFalse(menuSource.contains("AppConstants.Tmux"))

        let delegateSource = try appDelegateSource()
        XCTAssertFalse(delegateSource.contains("@objc func tmux"))
        XCTAssertFalse(delegateSource.contains("sendTmuxSequence"))
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
        XCTAssertTrue(inputSource.contains("if let commandControlText = TerminalTextInputRouter.commandShortcutControlText(for: event) {\n            resetMarkedTextForInputSourceChange()\n            send(commandControlText)\n            return true\n        }"))
    }

    func testEscapeKeyIsSentToTerminalFromAppKitCancelOperation() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let inputSource = try terminalInputViewSource()
        let routerSource = try terminalTextInputRouterSource()
        let encoderSource = try terminalKeyEncoderSource()

        XCTAssertTrue(surfaceSource.contains("if selector == #selector(cancelOperation(_:)) {\n            resetMarkedTextForInputSourceChange()\n        }"))
        XCTAssertTrue(inputSource.contains("if selector == #selector(cancelOperation(_:)) {\n            resetMarkedTextForInputSourceChange()\n        }"))
        XCTAssertTrue(encoderSource.contains("case #selector(NSResponder.cancelOperation(_:)):\n            return \"\\u{1b}\""))
        XCTAssertTrue(surfaceSource.contains("TerminalKeyEncoder.sequence(for: event, state: terminalKeyEncoderState)"))
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
        XCTAssertTrue(surfaceSource.contains("TerminalKeyEncoder.sequence(for: selector, state: terminalKeyEncoderState)"))
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
        XCTAssertTrue(splitSource.contains("func configurePane(_ pane: TerminalPaneView)"))
        XCTAssertTrue(splitSource.contains("pane.closeRequested = { [weak self] pane in"))
        XCTAssertTrue(splitSource.contains("pane.focusChanged = { [weak self] _ in"))
        XCTAssertTrue(splitSource.contains("func refreshPaneChrome()"))
        XCTAssertTrue(splitSource.contains("pane.setChromeVisible(isVisible)"))
        XCTAssertTrue(splitSource.contains("pane.setChromeActive(pane.ownsFirstResponder)"))
        XCTAssertTrue(splitSource.contains("guard paneCount > 1 else"))
        XCTAssertTrue(splitSource.contains("func focusFirstPane()"))
        XCTAssertTrue(splitSource.contains("override var dividerThickness: CGFloat"))
        XCTAssertTrue(splitSource.contains("func applyChromeTheme(_ theme: DesignTokens.ChromeTheme)"))
        XCTAssertTrue(splitSource.contains("override func drawDivider(in rect: NSRect)"))
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
        // Re-pointed 2026-08 alongside the tab close button: the pane header's
        // "×" text glyph became the shared `IconSymbol.close` SF Symbol, and
        // the button now takes its whole color ramp from the active theme so
        // press and focus follow a light theme instead of the dark ramp. Kept
        // rather than deleted so a revert to a typed glyph still fails.
        XCTAssertTrue(paneSource.contains("symbolName: IconSymbol.close"))
        XCTAssertFalse(paneSource.contains("ChromeIconButton(title:"))
        XCTAssertTrue(paneSource.contains("closeButton.applyChromeTheme(chromeTheme)"))
        XCTAssertTrue(try chromeIconButtonSource().contains("override func updateTrackingAreas()"))
        XCTAssertTrue(try chromeIconButtonSource().contains("override func mouseEntered(with event: NSEvent)"))
        XCTAssertTrue(try chromeIconButtonSource().contains("override func mouseExited(with event: NSEvent)"))
        XCTAssertTrue(try chromeIconButtonSource().contains("let location = convert(event.locationInWindow, from: nil)"))
        XCTAssertTrue(try chromeIconButtonSource().contains("guard !bounds.contains(location) else { return }"))
        XCTAssertTrue(try chromeIconButtonSource().contains("override func resetCursorRects()"))
        // All top-chrome icon buttons share the same hand cursor affordance.
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
        // Re-pointed 2026-08: the header is the top of the pane card now, so it
        // takes `paneHeaderBackground` (one surface above the ground) instead of
        // `surfaceChrome`, which was the ground's own color. Hover is still the
        // achromatic wash and the separation is still a bottom hairline.
        XCTAssertTrue(paneSource.contains("chromeHoverOverlayColor = isChromeHovered ? chromeTheme.hoverFill : .clear"))
        XCTAssertTrue(paneSource.contains("chromeBottomEdgeView.layer?.backgroundColor = chromeTheme.hairline.cgColor"))
        // The active marker is a leading rail, not a full-width bottom bar.
        XCTAssertTrue(paneSource.contains("terminalPaneChromeActiveRailWidthPX"))
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

        XCTAssertTrue(splitSource.contains("var needsInitialRebalance = false"))
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
        XCTAssertTrue(windowSource.contains("let paneDragCoordinator: TerminalPaneDragCoordinator"))
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
        let interpreterSource = try terminalOutputInterpreterSource()
        let modelSource = try terminalModelSource()

        XCTAssertTrue(modelSource.contains("struct TerminalLinkRange: Equatable"))
        XCTAssertTrue(modelSource.contains("static func findAll(in cells: [TerminalScreenCell], row: Int) -> [TerminalLinkRange]"))
        XCTAssertTrue(surfaceSource.contains("override func mouseMoved(with event: NSEvent)"))
        XCTAssertTrue(surfaceSource.contains("override func flagsChanged(with event: NSEvent)"))
        XCTAssertTrue(surfaceSource.contains(".mouseMoved"))
        // Link activation now requires Cmd so plain clicks and drags keep
        // reaching selection; the modifier is what makes a link swallow a click.
        XCTAssertTrue(surfaceSource.contains("if event.modifierFlags.contains(.command), let link = linkRange(at: position)"))
        XCTAssertTrue(surfaceSource.contains("if reportTerminalMouseEvent(.press(.left), with: event)"))
        XCTAssertTrue(interpreterSource.contains("mouseReportingState.set(decPrivateMode: value, enabled: enabled)"))
        XCTAssertTrue(surfaceSource.contains("!event.modifierFlags.contains(.shift)"))
        XCTAssertTrue(surfaceSource.contains("let linkRanges = visibleLinkRanges("))
        XCTAssertTrue(surfaceSource.contains("private func linkRange(at position: TerminalCellPosition) -> TerminalLinkRange?"))
        XCTAssertTrue(surfaceSource.contains("hoveredLinkRange?.contains(row: row, column: column)"))
        XCTAssertTrue(surfaceSource.contains("private func presentOpenLinkDialog(for link: TerminalLinkRange)"))
        XCTAssertTrue(surfaceSource.contains("NSWorkspace.shared.open(url)"))
        XCTAssertTrue(surfaceSource.contains("messageText = AppLocalization.string(.openLinkQuestion)"))
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

    func testTerminalNotificationsUseExplicitProtocolsWithoutScreenQuiescenceInference() throws {
        let shellSource = try shellSessionSource()
        let surfaceSource = try terminalSurfaceViewSource()
        let interpreterSource = try terminalOutputInterpreterSource()
        let notifierSource = try terminalNotifierSource()
        let appDelegateSource = try appDelegateSource()
        let readmeSource = try readmeSource()

        XCTAssertTrue(shellSource.contains("var onExit: ((TerminalChildExit) -> Void)?"))
        XCTAssertTrue(shellSource.contains("private var waitSource: DispatchSourceProcess?"))
        XCTAssertTrue(shellSource.contains("DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit"))
        XCTAssertTrue(shellSource.contains("waitpid(pid, &status, WNOHANG)"))

        XCTAssertTrue(surfaceSource.contains("private let notifier = TerminalNotifier.shared"))
        XCTAssertTrue(surfaceSource.contains("private var submittedCommandRecorder = TerminalSubmittedCommandRecorder()"))
        XCTAssertTrue(surfaceSource.contains("private var lastSubmittedCommandText: String?"))
        XCTAssertFalse(surfaceSource.contains("backgroundTask"))
        XCTAssertFalse(surfaceSource.contains("BackgroundTask"))
        XCTAssertTrue(surfaceSource.contains("private func send(_ text: String, recordsUserActivity: Bool = true)"))
        XCTAssertTrue(surfaceSource.contains("recordUserInput(text)"))
        XCTAssertTrue(surfaceSource.contains("recordSubmittedInputText(text)"))
        XCTAssertTrue(surfaceSource.contains("submittedCommandRecorder.consume(text)"))
        XCTAssertFalse(surfaceSource.contains("TerminalBackgroundTaskTrackingPolicy.shouldTrackSubmittedInput("))
        XCTAssertFalse(surfaceSource.contains("recordOutputForBackgroundTask(text)"))
        XCTAssertFalse(surfaceSource.contains("private func appendBackgroundTaskOutputText(_ text: String)"))
        XCTAssertFalse(surfaceSource.contains("latestVisibleNotificationSummary"))
        XCTAssertFalse(surfaceSource.contains("TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: lines)"))
        XCTAssertFalse(surfaceSource.contains("scheduleBackgroundTaskIdleCheck()"))
        XCTAssertFalse(surfaceSource.contains("notifyBackgroundTaskIfIdle(inputSequence: inputSequence)"))
        XCTAssertFalse(surfaceSource.contains("TerminalActivityCompletionTracker"))
        XCTAssertFalse(surfaceSource.contains("scheduleActivityCompletionIfNeeded(outputByteCount:"))
        XCTAssertFalse(surfaceSource.contains("activityCompletionQuietIntervalSeconds"))
        XCTAssertFalse(surfaceSource.contains("notifier.notifyActivityFinished("))
        XCTAssertFalse(surfaceSource.contains("latestVisibleNotificationSummary"))
        XCTAssertTrue(surfaceSource.contains("guard shouldDeliverUserNotification else"))
        XCTAssertTrue(surfaceSource.contains("private var shouldDeliverUserNotification: Bool"))
        XCTAssertTrue(surfaceSource.contains("!isTerminalFocusedForUser"))
        XCTAssertTrue(surfaceSource.contains("private var isTerminalFocusedForUser: Bool"))
        XCTAssertTrue(surfaceSource.contains("isApplicationActive: NSApp.isActive"))
        XCTAssertTrue(surfaceSource.contains("isKeyWindow: window?.isKeyWindow == true"))
        XCTAssertTrue(surfaceSource.contains("isFirstResponder: window?.firstResponder === self"))
        let recorderSource = try terminalSubmittedCommandRecorderSource()
        XCTAssertTrue(recorderSource.contains("TerminalSubmittedCommandSummary.notificationBody(from: pendingText)"))
        XCTAssertFalse(surfaceSource.contains("TerminalBackgroundTaskNotificationContent.make("))
        XCTAssertFalse(surfaceSource.contains("notifier.notifyBackgroundTaskCompleted(content: content)"))
        XCTAssertTrue(interpreterSource.contains("sendTerminalResponse(cursorPositionReport())"))
        XCTAssertTrue(interpreterSource.contains("sendTerminalResponse(response)"))
        XCTAssertFalse(surfaceSource.contains("notifyShellDidExit"))
        XCTAssertTrue(surfaceSource.contains("shell.onExit = { [weak self] status in"))
        XCTAssertTrue(surfaceSource.contains("transportDidExit(status: status.status.shellExitCode)"))
        XCTAssertTrue(interpreterSource.contains("handleDesktopNotificationEvent(terminalEvent)"))
        XCTAssertTrue(surfaceSource.contains("guard case .desktopNotification(let content) = event"))
        XCTAssertTrue(surfaceSource.contains("content: content.addingFallbackSubtitle(notificationSessionTitle())"))
        XCTAssertTrue(interpreterSource.contains("case 7:"))
        XCTAssertTrue(surfaceSource.contains("ringTerminalBell()"))
        XCTAssertTrue(surfaceSource.contains("private func ringTerminalBell() {\n        NSSound.beep()"))
        XCTAssertTrue(surfaceSource.contains("notifier.notifyBell()"))
        XCTAssertFalse(surfaceSource.contains("contentForBell"))
        XCTAssertTrue(interpreterSource.contains("handleTerminalIntegrationEvent(terminalEvent)"))
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
        XCTAssertTrue(notifierSource.contains("func notifyTerminalNotification(content: TerminalNotificationPayload.Content)"))
        XCTAssertTrue(notifierSource.contains("identifierPrefix(for: content.source)"))
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

        XCTAssertTrue(readmeSource.contains("terminal-generated notifications"))
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
        let resourceBundleSource = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/KurottyApp/KurottyResourceBundle.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(resourceBundleSource.contains("Bundle.main.resourceURL"))
        XCTAssertTrue(resourceBundleSource.contains("return Bundle.module"))
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
        // The version comes from the tag now, so there is no file to pin and no
        // release number to keep out of the README.
        XCTAssertTrue(installSource.contains("source \"$ROOT_DIR/scripts/version.sh\""))
        XCTAssertTrue(installSource.contains("VERSION=\"$(kurotty_resolve_version"))
        XCTAssertTrue(packageSource.contains("VERSION=\"$(kurotty_resolve_version"))
        XCTAssertTrue(installSource.contains("<string>$VERSION</string>"))
        XCTAssertTrue(packageSource.contains("BUILD_ARCHES=(arm64 x86_64)"))
        XCTAssertTrue(packageSource.contains("STRIP_TOOL=\"${STRIP_TOOL:-strip}\""))
        // The version-file lines they pinned are gone; ReleaseVersionResolutionTests
        // runs scripts/version.sh for real instead of matching its text.
        XCTAssertTrue(packageSource.contains("source \"$ROOT_DIR/scripts/version.sh\""))
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
        // Detaching moved into scripts/dmg-style.sh, which retries before it
        // forces: Finder can still hold the styled volume for a moment.
        XCTAssertTrue(packageSource.contains("detach_kurotty_dmg"))
        XCTAssertTrue(packageSource.contains("scripts/verify-icon-bundle.sh"))
        XCTAssertTrue(packageSource.contains("codesign --force --deep --options runtime --sign \"$SIGN_IDENTITY\" \"$APP_BUNDLE\""))
        XCTAssertTrue(packageSource.contains("codesign --force --deep --sign - \"$APP_BUNDLE\""))
        XCTAssertTrue(packageSource.contains("xcrun notarytool submit"))
        XCTAssertTrue(packageSource.contains("xcrun stapler staple"))
        XCTAssertTrue(packageSource.contains("scripts/verify-release-artifact.sh"))
        XCTAssertTrue(packageSource.contains("KUROTTY_REQUIRE_NOTARIZATION"))
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

        XCTAssertTrue(releaseWorkflowSource.contains("on:"))
        XCTAssertTrue(releaseWorkflowSource.contains("tags:"))
        XCTAssertTrue(releaseWorkflowSource.contains("'v*'"))
        XCTAssertTrue(releaseWorkflowSource.contains("fetch-depth: 0"))
        XCTAssertTrue(releaseWorkflowSource.contains("git branch --contains HEAD -r | grep -E '(^|[ /])main$'"))
        XCTAssertTrue(releaseWorkflowSource.contains("./scripts/package-release.sh \"${VERSION#v}\""))
        XCTAssertTrue(releaseWorkflowSource.contains("Verify packaged release artifact"))
        XCTAssertTrue(releaseWorkflowSource.contains("./scripts/verify-release-artifact.sh"))
        XCTAssertLessThan(
            try XCTUnwrap(releaseWorkflowSource.range(of: "Verify packaged release artifact")).lowerBound,
            try XCTUnwrap(releaseWorkflowSource.range(of: "Upload GitHub release")).lowerBound
        )
        XCTAssertTrue(releaseWorkflowSource.contains("dist/kurotty-*-macos-universal.dmg"))
        XCTAssertTrue(releaseWorkflowSource.contains("dist/kurotty-macos-universal.dmg"))
        XCTAssertTrue(releaseWorkflowSource.contains("dist/appcast.xml"))
        XCTAssertTrue(releaseWorkflowSource.contains("KUROTTY_SPARKLE_PRIVATE_KEY: ${{ secrets.KUROTTY_SPARKLE_PRIVATE_KEY }}"))
        XCTAssertTrue(releaseWorkflowSource.contains("softprops/action-gh-release"))

        XCTAssertTrue(agentsSource.contains("The git tag is the single source of truth"))
        XCTAssertTrue(agentsSource.contains("Do not hardcode future release numbers"))
        XCTAssertTrue(agentsSource.contains("stable direct-download alias `kurotty-macos-universal.dmg`"))
        XCTAssertTrue(agentsSource.contains("The installed app About panel must display the bundle `Info.plist` version"))
        XCTAssertTrue(agentsSource.contains("`scripts/verify-release-artifact.sh` is a mandatory publication gate"))
        XCTAssertTrue(agentsSource.contains("`--release-artifact-smoke-test` is an app-owned installed-layout contract"))
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
        XCTAssertTrue(inputSource.contains("init(core: any TerminalCore, send: @escaping (String) -> Void)"))
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

        // Deliberately the concrete bridge, not `any TerminalCore`: `feed` is no
        // longer a protocol requirement, precisely so no production path can
        // reach the Zig parser. This is the one remaining caller, and it exists
        // to prove the shipped dylib still loads and copies rows.
        let core = CoreBridge(cols: 5, rows: 2)
        core.feed("abcde")
        core.feed("xy")
        var firstRow = [UInt8](repeating: 0, count: 5)
        var secondRow = [UInt8](repeating: 0, count: 3)

        XCTAssertEqual(core.copyRow(0, into: &firstRow), 5)
        XCTAssertEqual(String(decoding: firstRow, as: UTF8.self), "abcde")
        XCTAssertEqual(core.copyRow(1, into: &secondRow), 3)
        XCTAssertEqual(String(decoding: secondRow, as: UTF8.self), "xy ")
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

private func terminalSubmittedCommandRecorderSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalSubmittedCommandRecorder.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalOutputInterpreterSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalOutputInterpreter.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalModelSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalModel.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalRenderFrameSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyCore/TerminalRenderFrame.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalDiagnosticsSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalDiagnostics.swift")
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

private func terminalSessionSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalSession.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func mainMenuSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/MainMenu.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func commandPaletteWindowControllerSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/CommandPaletteWindowController.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func appConstantsSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/AppConstants.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func preferencesViewSource() throws -> String {
    // PreferencesView was split into panes/controls files; the source-shape
    // assertions cover the whole family.
    try appSource("PreferencesView.swift")
        + appSource("PreferencesViewPanes.swift")
        + appSource("PreferencesViewControls.swift")
}

private func preferencesThemePreviewViewSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/PreferencesThemePreviewView.swift")
    return try String(contentsOf: path, encoding: .utf8)
}

private func terminalWindowControllerSource() throws -> String {
    // The drop-target and tab-item views were split into their own files; the
    // source-shape assertions cover the whole family.
    try appSource("TerminalWindowController.swift")
        + appSource("TerminalTabItemView.swift")
        + appSource("TerminalPaneDropTargetView.swift")
}

private func appSource(_ fileName: String) throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/").appendingPathComponent(fileName)
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
    // The tmux projection and focus navigation were split into their own
    // files; the source-shape assertions cover the whole family.
    try appSource("SplitTerminalView.swift")
        + appSource("SplitTerminalViewTmuxLayout.swift")
        + appSource("SplitTerminalViewFocus.swift")
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
