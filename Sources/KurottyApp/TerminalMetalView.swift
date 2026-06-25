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
    var onPresented: (() -> Void)?

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
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.onPresented?()
            }
        }
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
        drawCells()
        NSGraphicsContext.restoreGraphicsState()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let nextTexture = device.makeTexture(descriptor: descriptor)
        nextTexture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        texture = nextTexture
    }

    private func drawCells() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
        ]
        for cell in terminalFrame.cells where cell.row >= 0 && cell.row < terminalFrame.visibleRows {
            let rect = cellRect(column: cell.column, row: cell.row, width: cell.character.terminalColumnWidth)
            (String(cell.character) as NSString).draw(in: rect, withAttributes: attrs)
        }

        if !terminalFrame.markedText.isEmpty && terminalFrame.cursorRow >= 0 {
            var column = terminalFrame.cursorColumn
            for character in terminalFrame.markedText {
                (String(character) as NSString).draw(in: cellRect(column: column, row: terminalFrame.cursorRow, width: character.terminalColumnWidth), withAttributes: attrs)
                column += character.terminalColumnWidth
            }
        }

        if terminalFrame.cursorRow >= 0 {
            NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
            NSRect(
                x: terminalFrame.padding.x + CGFloat(max(0, terminalFrame.cursorColumn)) * terminalFrame.cellSize.width,
                y: bounds.height - terminalFrame.padding.y - terminalFrame.cellSize.height * CGFloat(max(0, terminalFrame.cursorRow) + 1) + 2,
                width: 2,
                height: max(1, terminalFrame.cellSize.height - 4)
            ).fill()
        }
    }

    private func cellRect(column: Int, row: Int, width: Int) -> NSRect {
        NSRect(
            x: terminalFrame.padding.x + CGFloat(column) * terminalFrame.cellSize.width,
            y: bounds.height - terminalFrame.padding.y - terminalFrame.cellSize.height * CGFloat(row + 1),
            width: terminalFrame.cellSize.width * CGFloat(max(1, width)),
            height: terminalFrame.cellSize.height
        )
    }

    private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
        guard let device else { return nil }
        do {
            let library = try device.makeLibrary(source: metalShaderSource, options: nil)
            guard
                let vertex = library.makeFunction(name: "terminal_vertex"),
                let fragment = library.makeFunction(name: "terminal_fragment")
            else {
                return nil
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Kurotty Metal pipeline failed: \(error)")
            return nil
        }
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

private extension Character {
    var terminalColumnWidth: Int {
        guard let scalar = unicodeScalars.first else { return 1 }
        let value = scalar.value
        if value == 0 || (value < 32) || (0x7f..<0xa0).contains(value) {
            return 0
        }
        if CharacterSet.nonBaseCharacters.contains(scalar) {
            return 0
        }
        if value >= 0x1100 &&
            (value <= 0x115f ||
             value == 0x2329 || value == 0x232a ||
             (0x2e80...0xa4cf).contains(value) ||
             (0xac00...0xd7a3).contains(value) ||
             (0xf900...0xfaff).contains(value) ||
             (0xfe10...0xfe19).contains(value) ||
             (0xfe30...0xfe6f).contains(value) ||
             (0xff00...0xff60).contains(value) ||
             (0xffe0...0xffe6).contains(value) ||
             (0x1f300...0x1f64f).contains(value) ||
             (0x1f900...0x1f9ff).contains(value)) {
            return 2
        }
        return 1
    }
}
