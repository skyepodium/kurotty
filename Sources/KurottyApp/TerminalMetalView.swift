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
    let columns: Int
    let visibleRows: Int
    let cellSize: CGSize
    let padding: CGPoint
}

final class TerminalMetalView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let glyphAtlas: GlyphAtlas
    private var vertexBuffer: MTLBuffer?
    private var vertices: [TerminalVertex] = []
    private var terminalFrame = TerminalFrame(cells: [], cursorColumn: 0, cursorRow: 0, columns: 1, visibleRows: 1, cellSize: .zero, padding: .zero)

    init(font: NSFont) {
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.pipeline = TerminalMetalView.makePipeline(device: device)
        self.glyphAtlas = GlyphAtlas(device: device, font: font)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        enableSetNeedsDisplay = true
        isPaused = true
        delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(frame: TerminalFrame) {
        self.terminalFrame = frame
        rebuildVertices()
        setNeedsDisplay(bounds)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildVertices()
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

        if let pipeline, let vertexBuffer, let texture = glyphAtlas.texture, !vertices.isEmpty {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func rebuildVertices() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        vertices.removeAll(keepingCapacity: true)
        let viewport = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        let foreground = SIMD4<Float>(0.92, 0.92, 0.92, 1)
        let cursorColor = SIMD4<Float>(0.88, 0.88, 0.88, 1)

        for cell in terminalFrame.cells {
            guard let glyph = glyphAtlas.glyph(for: cell.character) else { continue }
            appendGlyph(cell: cell, glyph: glyph, viewport: viewport, color: foreground)
        }

        appendSolidRect(
            x: Float(terminalFrame.padding.x) + Float(terminalFrame.cursorColumn) * Float(terminalFrame.cellSize.width),
            y: Float(terminalFrame.padding.y) + Float(terminalFrame.cursorRow) * Float(terminalFrame.cellSize.height) + 2,
            width: 2,
            height: Float(terminalFrame.cellSize.height) - 4,
            viewport: viewport,
            color: cursorColor
        )

        guard let device else { return }
        vertexBuffer = vertices.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
    }

    private func appendGlyph(cell: TerminalCell, glyph: Glyph, viewport: SIMD2<Float>, color: SIMD4<Float>) {
        let x = Float(terminalFrame.padding.x) + Float(cell.column) * Float(terminalFrame.cellSize.width) + glyph.offset.x
        let y = Float(terminalFrame.padding.y) + Float(cell.row) * Float(terminalFrame.cellSize.height) + glyph.offset.y
        appendTexturedRect(x: x, y: y, width: glyph.size.x, height: glyph.size.y, uv: glyph.uv, viewport: viewport, color: color)
    }

    private func appendTexturedRect(x: Float, y: Float, width: Float, height: Float, uv: GlyphUV, viewport: SIMD2<Float>, color: SIMD4<Float>) {
        appendQuad(
            positions: rectPositions(x: x, y: y, width: width, height: height, viewport: viewport),
            uvs: [
                SIMD2<Float>(uv.min.x, uv.min.y),
                SIMD2<Float>(uv.max.x, uv.min.y),
                SIMD2<Float>(uv.min.x, uv.max.y),
                SIMD2<Float>(uv.max.x, uv.min.y),
                SIMD2<Float>(uv.max.x, uv.max.y),
                SIMD2<Float>(uv.min.x, uv.max.y),
            ],
            color: color,
            mode: 0
        )
    }

    private func appendSolidRect(x: Float, y: Float, width: Float, height: Float, viewport: SIMD2<Float>, color: SIMD4<Float>) {
        appendQuad(
            positions: rectPositions(x: x, y: y, width: width, height: height, viewport: viewport),
            uvs: Array(repeating: SIMD2<Float>(0, 0), count: 6),
            color: color,
            mode: 1
        )
    }

    private func appendQuad(positions: [SIMD2<Float>], uvs: [SIMD2<Float>], color: SIMD4<Float>, mode: UInt32) {
        for index in 0..<6 {
            vertices.append(TerminalVertex(position: positions[index], uv: uvs[index], color: color, mode: mode))
        }
    }

    private func rectPositions(x: Float, y: Float, width: Float, height: Float, viewport: SIMD2<Float>) -> [SIMD2<Float>] {
        let left = (x / viewport.x) * 2 - 1
        let right = ((x + width) / viewport.x) * 2 - 1
        let top = 1 - (y / viewport.y) * 2
        let bottom = 1 - ((y + height) / viewport.y) * 2
        return [
            SIMD2<Float>(left, top),
            SIMD2<Float>(right, top),
            SIMD2<Float>(left, bottom),
            SIMD2<Float>(right, top),
            SIMD2<Float>(right, bottom),
            SIMD2<Float>(left, bottom),
        ]
    }

    private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
        guard
            let device,
            let library = try? device.makeDefaultLibrary(bundle: .module),
            let vertex = library.makeFunction(name: "terminal_vertex"),
            let fragment = library.makeFunction(name: "terminal_fragment")
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

private struct TerminalVertex {
    let position: SIMD2<Float>
    let uv: SIMD2<Float>
    let color: SIMD4<Float>
    let mode: UInt32
}

private struct Glyph {
    let uv: GlyphUV
    let size: SIMD2<Float>
    let offset: SIMD2<Float>
}

private struct GlyphUV {
    let min: SIMD2<Float>
    let max: SIMD2<Float>
}

private final class GlyphAtlas {
    private let font: NSFont
    private let context: CGContext
    private let textureSize = 1024
    private let cell: Int
    private var nextX = 0
    private var nextY = 0
    private var rowHeight = 0
    private var glyphs: [Character: Glyph] = [:]
    private(set) var texture: MTLTexture?

    init(device: MTLDevice?, font: NSFont) {
        self.font = font
        self.cell = Int(ceil(max(font.ascender - font.descender + font.leading, 18))) * 2
        let colorSpace = CGColorSpaceCreateDeviceGray()
        context = CGContext(
            data: nil,
            width: textureSize,
            height: textureSize,
            bitsPerComponent: 8,
            bytesPerRow: textureSize,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: textureSize, height: textureSize))

        if let device {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: textureSize, height: textureSize, mipmapped: false)
            descriptor.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: descriptor)
        }
    }

    func glyph(for character: Character) -> Glyph? {
        if character == " " { return nil }
        if let glyph = glyphs[character] { return glyph }
        return rasterize(character)
    }

    private func rasterize(_ character: Character) -> Glyph? {
        if nextX + cell >= textureSize {
            nextX = 0
            nextY += rowHeight
            rowHeight = 0
        }
        guard nextY + cell < textureSize else { return nil }

        let origin = CGPoint(x: nextX, y: nextY)
        let text = String(character) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let drawRect = CGRect(x: origin.x, y: origin.y + max(0, CGFloat(cell) - size.height) / 2, width: CGFloat(cell), height: CGFloat(cell))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(in: drawRect, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        uploadTexture()

        let glyph = Glyph(
            uv: GlyphUV(
                min: SIMD2<Float>(Float(origin.x) / Float(textureSize), Float(origin.y) / Float(textureSize)),
                max: SIMD2<Float>(Float(origin.x + CGFloat(cell)) / Float(textureSize), Float(origin.y + CGFloat(cell)) / Float(textureSize))
            ),
            size: SIMD2<Float>(Float(cell), Float(cell)),
            offset: SIMD2<Float>(0, 0)
        )
        glyphs[character] = glyph
        nextX += cell
        rowHeight = max(rowHeight, cell)
        return glyph
    }

    private func uploadTexture() {
        guard let texture, let data = context.data else { return }
        texture.replace(
            region: MTLRegionMake2D(0, 0, textureSize, textureSize),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: textureSize
        )
    }
}
