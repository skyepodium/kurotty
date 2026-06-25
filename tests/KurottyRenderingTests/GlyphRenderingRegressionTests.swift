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

    func testMetalGlyphAtlasInstancedDrawProducesPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal is not available")
        }

        let library = try device.makeLibrary(source: productionMetalShaderSource(), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "terminal_glyph_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "terminal_glyph_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))

        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        atlasDescriptor.usage = [.shaderRead]
        atlasDescriptor.storageMode = .shared
        let atlas = try XCTUnwrap(device.makeTexture(descriptor: atlasDescriptor))
        let atlasPixels = [UInt8](repeating: 255, count: 4 * 4 * 4)
        atlas.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: atlasPixels, bytesPerRow: 4 * 4)

        var vertices = [
            TestGlyphVertex(position: SIMD2<Float>(0, 0), uv: SIMD2<Float>(0, 1)),
            TestGlyphVertex(position: SIMD2<Float>(1, 0), uv: SIMD2<Float>(1, 1)),
            TestGlyphVertex(position: SIMD2<Float>(0, 1), uv: SIMD2<Float>(0, 0)),
            TestGlyphVertex(position: SIMD2<Float>(1, 0), uv: SIMD2<Float>(1, 1)),
            TestGlyphVertex(position: SIMD2<Float>(1, 1), uv: SIMD2<Float>(1, 0)),
            TestGlyphVertex(position: SIMD2<Float>(0, 1), uv: SIMD2<Float>(0, 0)),
        ]
        var instance = TestGlyphInstance(
            origin: SIMD2<Float>(4, 4),
            size: SIMD2<Float>(20, 20),
            uvOrigin: SIMD2<Float>(0, 0),
            uvSize: SIMD2<Float>(1, 1),
            color: SIMD4<Float>(1, 1, 1, 1)
        )
        var uniforms = TestUniforms(viewport: SIMD2<Float>(32, 32))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<TestGlyphVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&instance, length: MemoryLayout<TestGlyphInstance>.stride, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TestUniforms>.stride, index: 2)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var output = [UInt8](repeating: 0, count: 32 * 32 * 4)
        target.getBytes(&output, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
        XCTAssertGreaterThan(output.reduce(0) { $0 + Int($1) }, 32 * 32 * 255)
    }

    func testTerminalMetalViewExposesAtlasDiagnosticsAndOptInCPUFallback() throws {
        let source = try terminalMetalViewSource()
        XCTAssertTrue(source.contains("var diagnosticCPUFallbackEnabled = false"))
        XCTAssertTrue(source.contains("var isAtlasPathReadyForRendering: Bool"))
        XCTAssertTrue(source.contains("var atlasResourcesAreAvailableForDiagnostics: Bool"))
        XCTAssertTrue(source.contains("var atlasGlyphInstanceCountForDiagnostics: Int"))
        XCTAssertTrue(source.contains("var atlasNonTransparentPixelCountForDiagnostics: Int"))
        XCTAssertTrue(source.contains("var diagnosticCPUTextureIsAllocated: Bool"))
        XCTAssertTrue(source.contains("commandQueue != nil &&"))
        XCTAssertTrue(source.contains("atlasVertexBuffer != nil &&"))
        XCTAssertTrue(source.contains("uniformsBuffer != nil &&"))
        XCTAssertTrue(source.contains("atlasTexture != nil"))
        XCTAssertTrue(source.contains("if diagnosticCPUFallbackEnabled,\n           !isAtlasPathReadyForRendering"))
        XCTAssertTrue(source.contains("if diagnosticCPUFallbackEnabled {\n            rebuildTextTexture()"))
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
