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
        XCTAssertEqual(digest, "53e269239ab234b26c4cf5ec4133c1a9c3db0422e25ad68e3234d70372da9da4")
    }

    func testTerminalMetalViewExposesAtlasDiagnosticsAndOptInCPUFallback() throws {
        let source = try terminalMetalViewSource()
        XCTAssertTrue(source.contains("var diagnosticCPUFallbackEnabled = false"))
        XCTAssertTrue(source.contains("var diagnosticPixelSnappingEnabled = true"))
        XCTAssertTrue(source.contains("var diagnosticLinearGlyphSamplingEnabled = true"))
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
        XCTAssertTrue(source.contains("if diagnosticCPUFallbackEnabled,\n           !isAtlasPathReadyForRendering"))
        XCTAssertTrue(source.contains("if diagnosticCPUFallbackEnabled {\n            rebuildTextTexture()"))
    }

    func testAtlasUVsUseHalfTexelInsetAndGeometryUsesPixelSnapping() throws {
        let source = try terminalMetalViewSource()
        XCTAssertTrue(source.contains("let halfTexel = 0.5 / Float(atlasSize)"))
        XCTAssertTrue(source.contains("Float(x) / Float(atlasSize) + halfTexel"))
        XCTAssertTrue(source.contains("Float(max(0, drawWidthPixels - 1)) / Float(atlasSize)"))
        XCTAssertTrue(source.contains("snappedRect("))
        XCTAssertTrue(source.contains("backgroundRuns"))
        XCTAssertTrue(source.contains("sameColor(as:"))
        XCTAssertTrue(source.contains("pixelAlign("))
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
        XCTAssertTrue(metalSource.contains("let defaultBackground: SIMD4<Float>"))
        XCTAssertTrue(metalSource.contains("var lastFrameDirtyRowsForDiagnostics: [Int]"))
        XCTAssertTrue(metalSource.contains("var lastFrameDirtyRectsForDiagnostics: [CGRect]"))
        XCTAssertTrue(metalSource.contains("var lastFrameDamageWasFullForDiagnostics: Bool"))
        XCTAssertTrue(metalSource.contains("if frame.isFullDamage || frame.dirtyRects.isEmpty"))
        XCTAssertTrue(metalSource.contains("setNeedsDisplay(rect)"))
        XCTAssertTrue(metalSource.contains("!$0.color.sameColor(as: terminalFrame.defaultBackground)"))

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
    }

    func testShellSessionStartsInHomeWithInteractiveZshUsability() throws {
        let shellSource = try shellSessionSource()

        XCTAssertTrue(shellSource.contains("FileManager.default.homeDirectoryForCurrentUser.path"))
        XCTAssertFalse(shellSource.contains("AppConstants.Shell.defaultWorkingDirectory"))
        XCTAssertFalse(shellSource.contains("strdup(\"-f\")"))
        XCTAssertTrue(shellSource.contains("setenv(\"ZDOTDIR\""))
        XCTAssertTrue(shellSource.contains("[[ -r \"$HOME/.zshrc\" ]] && source \"$HOME/.zshrc\""))
        XCTAssertTrue(shellSource.contains("alias ll="))
        XCTAssertTrue(shellSource.contains("autoload -Uz compinit"))
        XCTAssertTrue(shellSource.contains("compinit -d"))
        XCTAssertTrue(shellSource.contains("POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD"))
        XCTAssertTrue(shellSource.contains("ZSH_DISABLE_COMPFIX"))
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
        XCTAssertTrue(settingsSource.contains("background: \"#F7F7F4\""))
        XCTAssertTrue(settingsSource.contains("cursor: \"#111111\""))
        XCTAssertTrue(settingsSource.contains("\"#AFA7F5\""))
        XCTAssertTrue(settingsSource.contains("\"#AB4634\""))
        XCTAssertTrue(settingsSource.contains("\"#55C236\""))
        XCTAssertTrue(settingsSource.contains("\"#ECE848\""))
        XCTAssertTrue(settingsSource.contains("\"#CF75D3\""))
        XCTAssertTrue(settingsSource.contains("normalizeTheme(&next)"))

        let surfaceSource = try terminalSurfaceViewSource()
        XCTAssertTrue(surfaceSource.contains("dimmed(weighted, against: background)"))
        XCTAssertTrue(surfaceSource.contains("luminance(background) > 0.5"))
        XCTAssertTrue(surfaceSource.contains("blend(color, background, amount: 0.48)"))

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

private func makeGlyphPipeline(device: MTLDevice, library: MTLLibrary) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "terminal_glyph_vertex"))
    descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "terminal_glyph_fragment"))
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
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

private func terminalSurfaceViewSource() throws -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KurottyApp/TerminalSurfaceView.swift")
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
