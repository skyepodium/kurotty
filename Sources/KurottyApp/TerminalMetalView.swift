import AppKit
import CoreGraphics
import Metal
import MetalKit

struct TerminalCell {
    let character: Character
    let column: Int
    let row: Int
}

struct TerminalFrame {
    let cells: [TerminalCell]
    let cursorColumn: Int
    let cursorRow: Int
    let markedText: String
    let columns: Int
    let visibleRows: Int
    let cellSize: CGSize
    let padding: CGPoint
}

final class TerminalMetalView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var texture: MTLTexture?
    private let font: NSFont
    private var terminalFrame = TerminalFrame(cells: [], cursorColumn: 0, cursorRow: 0, markedText: "", columns: 1, visibleRows: 1, cellSize: .zero, padding: .zero)

    init(font: NSFont) {
        self.font = font
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.pipeline = TerminalMetalView.makePipeline(device: device)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        enableSetNeedsDisplay = true
        isPaused = true
        delegate = self
        rebuildVertexBuffer()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(frame: TerminalFrame) {
        terminalFrame = frame
        rebuildTextTexture()
        setNeedsDisplay(bounds)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildVertexBuffer()
        rebuildTextTexture()
    }

    func draw(in view: MTKView) {
        guard
            let drawable = currentDrawable,
            let descriptor = currentRenderPassDescriptor,
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        if let pipeline, let vertexBuffer, let texture {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func rebuildVertexBuffer() {
        let vertices = [
            TexturedVertex(position: SIMD2<Float>(-1,  1), uv: SIMD2<Float>(0, 0)),
            TexturedVertex(position: SIMD2<Float>( 1,  1), uv: SIMD2<Float>(1, 0)),
            TexturedVertex(position: SIMD2<Float>(-1, -1), uv: SIMD2<Float>(0, 1)),
            TexturedVertex(position: SIMD2<Float>( 1,  1), uv: SIMD2<Float>(1, 0)),
            TexturedVertex(position: SIMD2<Float>( 1, -1), uv: SIMD2<Float>(1, 1)),
            TexturedVertex(position: SIMD2<Float>(-1, -1), uv: SIMD2<Float>(0, 1)),
        ]
        vertexBuffer = vertices.withUnsafeBytes { bytes in
            device?.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
    }

    private func rebuildTextTexture() {
        guard let device, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }

        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: bounds.size))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        drawTextIntoCurrentGraphicsContext()
        NSGraphicsContext.restoreGraphicsState()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let newTexture = device.makeTexture(descriptor: descriptor)
        newTexture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        texture = newTexture
    }

    private func drawTextIntoCurrentGraphicsContext() {
        let lineHeight = terminalFrame.cellSize.height
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
            .paragraphStyle: paragraph,
        ]

        var rows = Array(repeating: "", count: max(terminalFrame.visibleRows, 1))
        for cell in terminalFrame.cells where cell.row >= 0 && cell.row < rows.count {
            var row = Array(rows[cell.row])
            while row.count < cell.column {
                row.append(" ")
            }
            if cell.column < row.count {
                row[cell.column] = cell.character
            } else {
                row.append(cell.character)
            }
            rows[cell.row] = String(row)
        }
        if !terminalFrame.markedText.isEmpty && terminalFrame.cursorRow >= 0 && terminalFrame.cursorRow < rows.count {
            var row = Array(rows[terminalFrame.cursorRow])
            var column = terminalFrame.cursorColumn
            for character in terminalFrame.markedText {
                while row.count < column {
                    row.append(" ")
                }
                if column < row.count {
                    row[column] = character
                } else {
                    row.append(character)
                }
                column += 1
            }
            rows[terminalFrame.cursorRow] = String(row)
        }
        for (rowIndex, text) in rows.enumerated() where !text.isEmpty {
            let rect = NSRect(
                x: terminalFrame.padding.x,
                y: bounds.height - terminalFrame.padding.y - lineHeight * CGFloat(rowIndex + 1),
                width: bounds.width - terminalFrame.padding.x * 2,
                height: lineHeight
            )
            (text as NSString).draw(in: rect, withAttributes: attrs)
        }

        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        NSRect(
            x: terminalFrame.padding.x + CGFloat(terminalFrame.cursorColumn) * terminalFrame.cellSize.width,
            y: bounds.height - terminalFrame.padding.y - lineHeight * CGFloat(terminalFrame.cursorRow + 1) + 2,
            width: 2,
            height: max(1, lineHeight - 4)
        ).fill()
    }

    private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
        guard
            let device,
            let library = try? device.makeLibrary(source: metalShaderSource, options: nil),
            let vertex = library.makeFunction(name: "terminal_vertex"),
            let fragment = library.makeFunction(name: "terminal_fragment")
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

private struct TexturedVertex {
    let position: SIMD2<Float>
    let uv: SIMD2<Float>
}

private let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct TexturedVertex {
    float2 position;
    float2 uv;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut terminal_vertex(const device TexturedVertex *vertices [[buffer(0)]],
                                 uint vertex_id [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vertex_id].position, 0.0, 1.0);
    out.uv = vertices[vertex_id].uv;
    return out;
}

fragment float4 terminal_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> terminal_texture [[texture(0)]]) {
    constexpr sampler terminal_sampler(address::clamp_to_edge, filter::nearest);
    return terminal_texture.sample(terminal_sampler, in.uv);
}
"""
