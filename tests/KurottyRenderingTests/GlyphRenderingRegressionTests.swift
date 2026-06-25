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

        let library = try device.makeLibrary(source: testAtlasShaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "glyph_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "glyph_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 32, height: 32, mipmapped: false)
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

private let testAtlasShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct GlyphVertex {
    float2 position;
    float2 uv;
};

struct GlyphInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
    float4 color;
};

struct Uniforms {
    float2 viewport;
};

struct Out {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex Out glyph_vertex(const device GlyphVertex *vertices [[buffer(0)]],
                        const device GlyphInstance *instances [[buffer(1)]],
                        constant Uniforms &uniforms [[buffer(2)]],
                        uint vertex_id [[vertex_id]],
                        uint instance_id [[instance_id]]) {
    GlyphVertex glyph_vertex = vertices[vertex_id];
    GlyphInstance instance = instances[instance_id];
    float2 point = instance.origin + glyph_vertex.position * instance.size;
    Out out;
    out.position = float4((point.x / uniforms.viewport.x) * 2.0 - 1.0,
                          (point.y / uniforms.viewport.y) * 2.0 - 1.0,
                          0.0,
                          1.0);
    out.uv = instance.uvOrigin + glyph_vertex.uv * instance.uvSize;
    out.color = instance.color;
    return out;
}

fragment float4 glyph_fragment(Out in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    return atlas.sample(s, in.uv) * in.color;
}
"""
