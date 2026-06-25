import AppKit
import CoreText
import CoreGraphics
import Metal
import MetalKit

struct TerminalCell {
    let character: Character
    let column: Int
    let row: Int
    let foreground: SIMD4<Float>
    let background: SIMD4<Float>
}

struct TerminalFrame {
    let cells: [TerminalCell]
    let backgrounds: [TerminalBackground]
    let decorations: [TerminalDecoration]
    let dirtyRows: [Int]
    let dirtyRects: [CGRect]
    let isFullDamage: Bool
    let cursorColumn: Int
    let cursorRow: Int
    let inputOverlayText: String
    let inputOverlayColumn: Int
    let inputOverlayRow: Int
    let markedText: String
    let columns: Int
    let visibleRows: Int
    let cellSize: CGSize
    let padding: CGPoint
}

struct TerminalBackground {
    let column: Int
    let row: Int
    let color: SIMD4<Float>
}

struct TerminalDecoration {
    let column: Int
    let row: Int
    let width: Int
    let kind: Kind
    let color: SIMD4<Float>

    enum Kind {
        case underline
        case strikethrough
    }
}

final class TerminalMetalView: MTKView, MTKViewDelegate {
    var onPresented: (() -> Void)?
    var diagnosticCPUFallbackEnabled = false {
        didSet {
            if diagnosticCPUFallbackEnabled {
                rebuildTextTexture()
            } else {
                texture = nil
            }
            setNeedsDisplay(bounds)
        }
    }

    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let atlasPipeline: MTLRenderPipelineState?
    private let solidPipeline: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var atlasVertexBuffer: MTLBuffer?
    private var atlasInstanceBuffer: MTLBuffer?
    private var backgroundInstanceBuffer: MTLBuffer?
    private var decorationInstanceBuffer: MTLBuffer?
    private var cursorInstanceBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?
    private var texture: MTLTexture?
    private var atlasTexture: MTLTexture?
    private var atlasPixels: [UInt8] = []
    private var glyphs: [String: GlyphAtlasEntry] = [:]
    private var atlasSlot = 0
    private var atlasCellSize = CGSize.zero
    private var font: NSFont
    private var backgroundColor: SIMD4<Float>
    private var cursorColor: SIMD4<Float>
    private let atlasSize = DesignTokens.Component.glyphAtlasSizePX
    private let glyphSlotWidth = DesignTokens.Component.glyphSlotWidthPX
    private let glyphSlotHeight = DesignTokens.Component.glyphSlotHeightPX
    private var terminalFrame = TerminalFrame(cells: [], backgrounds: [], decorations: [], dirtyRows: [], dirtyRects: [], isFullDamage: true, cursorColumn: 0, cursorRow: 0, inputOverlayText: "", inputOverlayColumn: 0, inputOverlayRow: 0, markedText: "", columns: 1, visibleRows: 1, cellSize: .zero, padding: .zero)

    init(
        font: NSFont,
        backgroundColor: SIMD4<Float> = DesignTokens.Color.terminalDefaultBackground,
        cursorColor: SIMD4<Float> = DesignTokens.Color.terminalCursor
    ) {
        self.font = font
        self.backgroundColor = backgroundColor
        self.cursorColor = cursorColor
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.pipeline = TerminalMetalView.makePipeline(device: device)
        let atlasPipelines = TerminalMetalView.makeAtlasPipelines(device: device)
        self.atlasPipeline = atlasPipelines.glyph
        self.solidPipeline = atlasPipelines.solid
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        clearColor = MTLClearColor(
            red: Double(backgroundColor.x),
            green: Double(backgroundColor.y),
            blue: Double(backgroundColor.z),
            alpha: Double(backgroundColor.w)
        )
        enableSetNeedsDisplay = true
        isPaused = true
        delegate = self
        rebuildVertexBuffer()
        rebuildAtlasVertexBuffer()
        initializeAtlas()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(frame: TerminalFrame) {
        terminalFrame = frame
        rebuildAtlasBuffers()
        if diagnosticCPUFallbackEnabled {
            rebuildTextTexture()
        }
        if frame.isFullDamage || frame.dirtyRects.isEmpty {
            setNeedsDisplay(bounds)
        } else {
            for rect in frame.dirtyRects {
                setNeedsDisplay(rect)
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildVertexBuffer()
        if diagnosticCPUFallbackEnabled {
            rebuildTextTexture()
        }
    }

    func applyAppearance(
        font: NSFont,
        backgroundColor: SIMD4<Float>,
        cursorColor: SIMD4<Float>
    ) {
        self.font = font
        self.backgroundColor = backgroundColor
        self.cursorColor = cursorColor
        clearColor = MTLClearColor(
            red: Double(backgroundColor.x),
            green: Double(backgroundColor.y),
            blue: Double(backgroundColor.z),
            alpha: Double(backgroundColor.w)
        )
        resetAtlas()
        rebuildAtlasBuffers()
        if diagnosticCPUFallbackEnabled {
            rebuildTextTexture()
        }
        setNeedsDisplay(bounds)
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

        if diagnosticCPUFallbackEnabled,
           !isAtlasPathReadyForRendering,
           let pipeline,
           let vertexBuffer,
           let texture {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        if isAtlasPathReadyForRendering,
           let atlasPipeline,
           let atlasVertexBuffer,
           let atlasInstanceBuffer,
           let uniformsBuffer,
           let atlasTexture {
            if let solidPipeline,
               let backgroundInstanceBuffer,
               backgroundInstanceCount > 0 {
                encoder.setRenderPipelineState(solidPipeline)
                encoder.setVertexBuffer(atlasVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(backgroundInstanceBuffer, offset: 0, index: 1)
                encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: backgroundInstanceCount)
            }

            encoder.setRenderPipelineState(atlasPipeline)
            encoder.setVertexBuffer(atlasVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(atlasInstanceBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 2)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: atlasInstanceCount)

            if let solidPipeline,
               let decorationInstanceBuffer,
               decorationInstanceCount > 0 {
                encoder.setRenderPipelineState(solidPipeline)
                encoder.setVertexBuffer(atlasVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(decorationInstanceBuffer, offset: 0, index: 1)
                encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: decorationInstanceCount)
            }

            if terminalFrame.cursorRow >= 0,
               let solidPipeline,
               let cursorInstanceBuffer {
                encoder.setRenderPipelineState(solidPipeline)
                encoder.setVertexBuffer(atlasVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(cursorInstanceBuffer, offset: 0, index: 1)
                encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }
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

    var isAtlasPathReadyForRendering: Bool {
        atlasResourcesAreAvailableForDiagnostics && atlasInstanceCount > 0
    }

    var atlasResourcesAreAvailableForDiagnostics: Bool {
        commandQueue != nil &&
            atlasPipeline != nil &&
            solidPipeline != nil &&
            atlasVertexBuffer != nil &&
            uniformsBuffer != nil &&
            atlasTexture != nil
    }

    var atlasGlyphInstanceCountForDiagnostics: Int {
        atlasInstanceCount
    }

    var atlasNonTransparentPixelCountForDiagnostics: Int {
        stride(from: 3, to: atlasPixels.count, by: 4).reduce(0) { count, alphaIndex in
            atlasPixels[alphaIndex] > 0 ? count + 1 : count
        }
    }

    var diagnosticCPUTextureIsAllocated: Bool {
        texture != nil
    }

    var lastFrameDirtyRowsForDiagnostics: [Int] {
        terminalFrame.dirtyRows
    }

    var lastFrameDirtyRectsForDiagnostics: [CGRect] {
        terminalFrame.dirtyRects
    }

    var lastFrameDamageWasFullForDiagnostics: Bool {
        terminalFrame.isFullDamage
    }

    private var atlasInstanceCount: Int {
        guard let atlasInstanceBuffer else { return 0 }
        return atlasInstanceBuffer.length / MemoryLayout<GlyphInstance>.stride
    }

    private var backgroundInstanceCount: Int {
        guard let backgroundInstanceBuffer else { return 0 }
        return backgroundInstanceBuffer.length / MemoryLayout<GlyphInstance>.stride
    }

    private var decorationInstanceCount: Int {
        guard let decorationInstanceBuffer else { return 0 }
        return decorationInstanceBuffer.length / MemoryLayout<GlyphInstance>.stride
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

    private func rebuildAtlasVertexBuffer() {
        let vertices = [
            GlyphVertex(position: SIMD2<Float>(0, 0), uv: SIMD2<Float>(0, 1)),
            GlyphVertex(position: SIMD2<Float>(1, 0), uv: SIMD2<Float>(1, 1)),
            GlyphVertex(position: SIMD2<Float>(0, 1), uv: SIMD2<Float>(0, 0)),
            GlyphVertex(position: SIMD2<Float>(1, 0), uv: SIMD2<Float>(1, 1)),
            GlyphVertex(position: SIMD2<Float>(1, 1), uv: SIMD2<Float>(1, 0)),
            GlyphVertex(position: SIMD2<Float>(0, 1), uv: SIMD2<Float>(0, 0)),
        ]
        atlasVertexBuffer = vertices.withUnsafeBytes { bytes in
            device?.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
    }

    private func initializeAtlas() {
        guard let device else { return }
        atlasPixels = [UInt8](repeating: 0, count: atlasSize * atlasSize * 4)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: atlasSize, height: atlasSize, mipmapped: false)
        descriptor.usage = [.shaderRead]
        atlasTexture = device.makeTexture(descriptor: descriptor)
        uploadAtlas()
    }

    private func rebuildAtlasBuffers() {
        guard let device, bounds.width > 0, bounds.height > 0 else { return }
        resetAtlasIfCellMetricsChanged()
        var instances: [GlyphInstance] = []
        instances.reserveCapacity(terminalFrame.cells.count + terminalFrame.markedText.count)
        for cell in terminalFrame.cells {
            appendGlyphInstance(character: cell.character, column: cell.column, row: cell.row, into: &instances, color: cell.foreground)
        }
        if !terminalFrame.inputOverlayText.isEmpty && terminalFrame.inputOverlayRow >= 0 {
            var column = terminalFrame.inputOverlayColumn
            for character in terminalFrame.inputOverlayText {
                appendGlyphInstance(character: character, column: column, row: terminalFrame.inputOverlayRow, into: &instances)
                column += character.terminalColumnWidth
            }
        }
        if !terminalFrame.markedText.isEmpty && terminalFrame.cursorRow >= 0 {
            var column = max(0, terminalFrame.cursorColumn - terminalColumnWidth(of: terminalFrame.markedText))
            for character in terminalFrame.markedText {
                appendGlyphInstance(character: character, column: column, row: terminalFrame.cursorRow, into: &instances)
                column += character.terminalColumnWidth
            }
        }
        atlasInstanceBuffer = instances.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }

        var backgrounds: [GlyphInstance] = []
        backgrounds.reserveCapacity(terminalFrame.backgrounds.count)
        for background in terminalFrame.backgrounds where background.row >= 0 && background.row < terminalFrame.visibleRows {
            backgrounds.append(GlyphInstance(
                origin: SIMD2<Float>(
                    Float(terminalFrame.padding.x + CGFloat(background.column) * terminalFrame.cellSize.width),
                    Float(bounds.height - terminalFrame.padding.y - terminalFrame.cellSize.height * CGFloat(background.row + 1))
                ),
                size: SIMD2<Float>(Float(terminalFrame.cellSize.width), Float(terminalFrame.cellSize.height)),
                uvOrigin: .zero,
                uvSize: .zero,
                color: background.color
            ))
        }
        backgroundInstanceBuffer = backgrounds.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }

        var decorations: [GlyphInstance] = []
        decorations.reserveCapacity(terminalFrame.decorations.count)
        for decoration in terminalFrame.decorations where decoration.row >= 0 && decoration.row < terminalFrame.visibleRows {
            let yOffset: CGFloat
            switch decoration.kind {
            case .underline:
                yOffset = max(1, terminalFrame.cellSize.height - 3)
            case .strikethrough:
                yOffset = max(1, floor(terminalFrame.cellSize.height * 0.52))
            }
            decorations.append(GlyphInstance(
                origin: SIMD2<Float>(
                    Float(terminalFrame.padding.x + CGFloat(decoration.column) * terminalFrame.cellSize.width),
                    Float(bounds.height - terminalFrame.padding.y - terminalFrame.cellSize.height * CGFloat(decoration.row + 1) + yOffset)
                ),
                size: SIMD2<Float>(
                    Float(terminalFrame.cellSize.width * CGFloat(max(1, decoration.width))),
                    Float(max(1, backingScale.rounded(.up)))
                ),
                uvOrigin: .zero,
                uvSize: .zero,
                color: decoration.color
            ))
        }
        decorationInstanceBuffer = decorations.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }

        var cursor = GlyphInstance(
            origin: SIMD2<Float>(
                Float(terminalFrame.padding.x + CGFloat(max(0, terminalFrame.cursorColumn)) * terminalFrame.cellSize.width),
                Float(bounds.height - terminalFrame.padding.y - terminalFrame.cellSize.height * CGFloat(max(0, terminalFrame.cursorRow) + 1))
            ),
            size: SIMD2<Float>(2, Float(max(1, terminalFrame.cellSize.height))),
            uvOrigin: .zero,
            uvSize: .zero,
            color: cursorColor
        )
        cursorInstanceBuffer = device.makeBuffer(bytes: &cursor, length: MemoryLayout<GlyphInstance>.stride, options: .storageModeShared)

        var uniforms = TerminalUniforms(viewport: SIMD2<Float>(Float(bounds.width), Float(bounds.height)))
        uniformsBuffer = device.makeBuffer(bytes: &uniforms, length: MemoryLayout<TerminalUniforms>.stride, options: .storageModeShared)
    }

    private func appendGlyphInstance(character: Character, column: Int, row: Int, into instances: inout [GlyphInstance], color: SIMD4<Float> = SIMD4<Float>(0.92, 0.92, 0.92, 1)) {
        guard row >= 0, row < terminalFrame.visibleRows else { return }
        let entry = glyphEntry(for: character)
        let scale = backingScale
        let x = pixelAlign(terminalFrame.padding.x + CGFloat(column) * terminalFrame.cellSize.width + CGFloat(entry.drawOffset.x), scale: scale)
        let y = pixelAlign(bounds.height - terminalFrame.padding.y - terminalFrame.cellSize.height * CGFloat(row + 1) + CGFloat(entry.drawOffset.y), scale: scale)
        let origin = SIMD2<Float>(Float(x), Float(y))
        instances.append(GlyphInstance(
            origin: origin,
            size: entry.drawSize,
            uvOrigin: entry.uvOrigin,
            uvSize: entry.uvSize,
            color: color
        ))
    }

    private func glyphEntry(for character: Character) -> GlyphAtlasEntry {
        let key = String(character)
        if let existing = glyphs[key] {
            return existing
        }
        let slotsPerRow = atlasSize / glyphSlotWidth
        let x = (atlasSlot % slotsPerRow) * glyphSlotWidth
        let y = (atlasSlot / slotsPerRow) * glyphSlotHeight
        atlasSlot += 1
        if y + glyphSlotHeight > atlasSize {
            return GlyphAtlasEntry(uvOrigin: .zero, uvSize: .zero, drawOffset: .zero, drawSize: .zero)
        }

        let rasterized = rasterizeGlyph(character, x: x, y: y)
        let scale = atlasScale(forLogicalWidth: CGFloat(rasterized.drawSize.x), logicalHeight: CGFloat(rasterized.drawSize.y))
        let drawWidthPixels = min(glyphSlotWidth, max(1, Int(ceil(CGFloat(rasterized.drawSize.x) * scale))))
        let drawHeightPixels = min(glyphSlotHeight, max(1, Int(ceil(CGFloat(rasterized.drawSize.y) * scale))))
        uploadAtlas(region: MTLRegionMake2D(x, y, glyphSlotWidth, glyphSlotHeight))
        let entry = GlyphAtlasEntry(
            uvOrigin: SIMD2<Float>(
                Float(x) / Float(atlasSize),
                Float(y) / Float(atlasSize)
            ),
            uvSize: SIMD2<Float>(Float(drawWidthPixels) / Float(atlasSize), Float(drawHeightPixels) / Float(atlasSize)),
            drawOffset: rasterized.drawOffset,
            drawSize: rasterized.drawSize
        )
        glyphs[key] = entry
        return entry
    }

    private func rasterizeGlyph(_ character: Character, x: Int, y: Int) -> RasterizedGlyph {
        var slot = [UInt8](repeating: 0, count: glyphSlotWidth * glyphSlotHeight * 4)
        let logicalWidth = terminalFrame.cellSize.width * CGFloat(max(1, character.terminalColumnWidth))
        let logicalHeight = terminalFrame.cellSize.height
        let scale = atlasScale(forLogicalWidth: logicalWidth, logicalHeight: logicalHeight)
        let pixelWidth = min(glyphSlotWidth, max(1, Int(ceil(logicalWidth * scale))))
        let pixelHeight = min(glyphSlotHeight, max(1, Int(ceil(logicalHeight * scale))))
        let result = RasterizedGlyph(
            drawOffset: .zero,
            drawSize: SIMD2<Float>(Float(CGFloat(pixelWidth) / scale), Float(CGFloat(pixelHeight) / scale))
        )
        guard let context = CGContext(
            data: &slot,
            width: glyphSlotWidth,
            height: glyphSlotHeight,
            bitsPerComponent: 8,
            bytesPerRow: glyphSlotWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return result
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        context.fill(CGRect(x: 0, y: 0, width: glyphSlotWidth, height: glyphSlotHeight))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)
        context.interpolationQuality = .high
        context.textMatrix = .identity

        let scaledFont = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
        let string = NSAttributedString(
            string: String(character),
            attributes: [
                .font: scaledFont,
                .foregroundColor: NSColor.white,
            ]
        )
        let line = CTLineCreateWithAttributedString(string)
        let contentHeight = font.ascender - font.descender
        let topInset = max(0, (logicalHeight - contentHeight) * 0.5)
        let baselineFromBottom = ceil((logicalHeight - topInset + font.descender) * scale)
        let glyphWidth = max(1, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        let availableWidth = max(1, logicalWidth * scale)
        let horizontalScale = min(1, availableWidth / glyphWidth)
        context.saveGState()
        context.scaleBy(x: horizontalScale, y: 1)
        context.textPosition = CGPoint(x: 0, y: baselineFromBottom)
        CTLineDraw(line, context)
        context.restoreGState()

        for row in 0..<glyphSlotHeight {
            let src = row * glyphSlotWidth * 4
            let dst = ((y + row) * atlasSize + x) * 4
            atlasPixels.replaceSubrange(dst..<(dst + glyphSlotWidth * 4), with: slot[src..<(src + glyphSlotWidth * 4)])
        }
        return result
    }

    private func resetAtlasIfCellMetricsChanged() {
        guard terminalFrame.cellSize != .zero, terminalFrame.cellSize != atlasCellSize else { return }
        atlasCellSize = terminalFrame.cellSize
        resetAtlas()
    }

    private func resetAtlas() {
        glyphs.removeAll(keepingCapacity: true)
        atlasSlot = 0
        atlasPixels = [UInt8](repeating: 0, count: atlasSize * atlasSize * 4)
        uploadAtlas()
    }

    private func atlasScale(forLogicalWidth logicalWidth: CGFloat, logicalHeight: CGFloat) -> CGFloat {
        let preferredScale = max(backingScale, DesignTokens.Component.glyphAtlasMinimumScale)
        let usableSlotWidth = max(1, CGFloat(glyphSlotWidth) - DesignTokens.Component.glyphSlotPaddingPX * 2)
        let usableSlotHeight = max(1, CGFloat(glyphSlotHeight) - DesignTokens.Component.glyphSlotPaddingPX * 2)
        let widthLimitedScale = usableSlotWidth / max(1, logicalWidth)
        let heightLimitedScale = usableSlotHeight / max(1, logicalHeight)
        return max(backingScale, min(preferredScale, widthLimitedScale, heightLimitedScale))
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func pixelAlign(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        round(value * scale) / scale
    }

    private func uploadAtlas(region: MTLRegion? = nil) {
        guard let atlasTexture, !atlasPixels.isEmpty else { return }
        let uploadRegion = region ?? MTLRegionMake2D(0, 0, atlasSize, atlasSize)
        atlasPixels.withUnsafeBytes { bytes in
            let offset = (uploadRegion.origin.y * atlasSize + uploadRegion.origin.x) * 4
            atlasTexture.replace(
                region: uploadRegion,
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!.advanced(by: offset),
                bytesPerRow: atlasSize * 4
            )
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
            var column = max(0, terminalFrame.cursorColumn - terminalColumnWidth(of: terminalFrame.markedText))
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

    private func terminalColumnWidth(of text: String) -> Int {
        text.reduce(0) { width, character in
            width + character.terminalColumnWidth
        }
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

    private static func makeAtlasPipelines(device: MTLDevice?) -> (glyph: MTLRenderPipelineState?, solid: MTLRenderPipelineState?) {
        guard let device else { return (nil, nil) }
        do {
            let library = try device.makeLibrary(source: metalShaderSource, options: nil)
            guard
                let vertex = library.makeFunction(name: "terminal_glyph_vertex"),
                let glyphFragment = library.makeFunction(name: "terminal_glyph_fragment"),
                let solidFragment = library.makeFunction(name: "terminal_solid_fragment")
            else {
                return (nil, nil)
            }

            let glyphDescriptor = MTLRenderPipelineDescriptor()
            glyphDescriptor.vertexFunction = vertex
            glyphDescriptor.fragmentFunction = glyphFragment
            glyphDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            glyphDescriptor.colorAttachments[0].isBlendingEnabled = true
            glyphDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            glyphDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            glyphDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            glyphDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            let solidDescriptor = MTLRenderPipelineDescriptor()
            solidDescriptor.vertexFunction = vertex
            solidDescriptor.fragmentFunction = solidFragment
            solidDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            return (
                try device.makeRenderPipelineState(descriptor: glyphDescriptor),
                try device.makeRenderPipelineState(descriptor: solidDescriptor)
            )
        } catch {
            NSLog("Kurotty Metal atlas pipeline failed: \(error)")
            return (nil, nil)
        }
    }
}

private struct TexturedVertex {
    let position: SIMD2<Float>
    let uv: SIMD2<Float>
}

private struct GlyphVertex {
    let position: SIMD2<Float>
    let uv: SIMD2<Float>
}

private struct GlyphInstance {
    let origin: SIMD2<Float>
    let size: SIMD2<Float>
    let uvOrigin: SIMD2<Float>
    let uvSize: SIMD2<Float>
    let color: SIMD4<Float>
}

private struct TerminalUniforms {
    let viewport: SIMD2<Float>
}

private struct GlyphAtlasEntry {
    let uvOrigin: SIMD2<Float>
    let uvSize: SIMD2<Float>
    let drawOffset: SIMD2<Float>
    let drawSize: SIMD2<Float>
}

private struct RasterizedGlyph {
    let drawOffset: SIMD2<Float>
    let drawSize: SIMD2<Float>
}

let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct TexturedVertex {
    float2 position;
    float2 uv;
};

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

struct TerminalUniforms {
    float2 viewport;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct GlyphVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
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

vertex GlyphVertexOut terminal_glyph_vertex(const device GlyphVertex *vertices [[buffer(0)]],
                                            const device GlyphInstance *instances [[buffer(1)]],
                                            constant TerminalUniforms &uniforms [[buffer(2)]],
                                            uint vertex_id [[vertex_id]],
                                            uint instance_id [[instance_id]]) {
    GlyphVertex glyph_vertex = vertices[vertex_id];
    GlyphInstance instance = instances[instance_id];
    float2 point = instance.origin + glyph_vertex.position * instance.size;
    float2 ndc = float2((point.x / uniforms.viewport.x) * 2.0 - 1.0,
                       (point.y / uniforms.viewport.y) * 2.0 - 1.0);
    GlyphVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = instance.uvOrigin + glyph_vertex.uv * instance.uvSize;
    out.color = instance.color;
    return out;
}

fragment float4 terminal_glyph_fragment(GlyphVertexOut in [[stage_in]],
                                        texture2d<float> glyph_atlas [[texture(0)]]) {
    constexpr sampler glyph_sampler(address::clamp_to_edge, filter::linear);
    float4 sample = glyph_atlas.sample(glyph_sampler, in.uv);
    return float4(in.color.rgb, sample.a * in.color.a);
}

fragment float4 terminal_solid_fragment(GlyphVertexOut in [[stage_in]]) {
    return in.color;
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
