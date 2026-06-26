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
    let defaultForeground: SIMD4<Float>
    let defaultBackground: SIMD4<Float>
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

private struct BackgroundRun {
    let column: Int
    let row: Int
    var width: Int
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

struct TerminalRenderingDiagnostics {
    let backingScaleFactor: CGFloat
    let drawableSize: CGSize
    let cellSizePoints: CGSize
    let cellSizePixels: CGSize
    let glyphAtlasSizePixels: Int
    let lastGlyphRectPixels: CGRect
    let lastGlyphUVOrigin: SIMD2<Float>
    let lastGlyphUVSize: SIMD2<Float>
    let lastGlyphDrawOffsetPoints: SIMD2<Float>
    let pixelSnappingEnabled: Bool
    let linearGlyphSamplingEnabled: Bool
}

final class TerminalMetalView: MTKView, MTKViewDelegate {
    private static let glyphFallbackFontNames = [
        "MesloLGS NF",
        "MesloLGS Nerd Font Mono",
        "Symbols Nerd Font Mono",
        "Hack Nerd Font Mono",
        "JetBrainsMono Nerd Font Mono",
        "FiraCode Nerd Font Mono",
        "SF Mono",
        "Menlo",
    ]

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
    var diagnosticPixelSnappingEnabled = true {
        didSet {
            rebuildAtlasBuffers()
            setNeedsDisplay(bounds)
        }
    }
    var diagnosticLinearGlyphSamplingEnabled = true {
        didSet {
            setNeedsDisplay(bounds)
        }
    }
    var diagnosticRenderingLogEnabled = false

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
    private var atlasBackingScale: CGFloat = 0
    private var lastGlyphRectPixels = CGRect.zero
    private var lastGlyphUVOrigin = SIMD2<Float>.zero
    private var lastGlyphUVSize = SIMD2<Float>.zero
    private var lastGlyphDrawOffsetPoints = SIMD2<Float>.zero
    private var font: NSFont
    private var backgroundColor: SIMD4<Float>
    private var cursorColor: SIMD4<Float>
    private let atlasSize = DesignTokens.Component.glyphAtlasSizePX
    private let glyphSlotWidth = DesignTokens.Component.glyphSlotWidthPX
    private let glyphSlotHeight = DesignTokens.Component.glyphSlotHeightPX
    private var terminalFrame = TerminalFrame(cells: [], backgrounds: [], decorations: [], defaultForeground: DesignTokens.Color.terminalForeground, defaultBackground: DesignTokens.Color.terminalDefaultBackground, dirtyRows: [], dirtyRects: [], isFullDamage: true, cursorColumn: 0, cursorRow: 0, inputOverlayText: "", inputOverlayColumn: 0, inputOverlayRow: 0, markedText: "", columns: 1, visibleRows: 1, cellSize: .zero, padding: .zero)

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
        logRenderingDiagnosticsIfNeeded()
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
        resetAtlasIfBackingScaleChanged()
        rebuildAtlasBuffers()
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

    var renderingDiagnostics: TerminalRenderingDiagnostics {
        let scale = backingScale
        return TerminalRenderingDiagnostics(
            backingScaleFactor: scale,
            drawableSize: drawableSize,
            cellSizePoints: terminalFrame.cellSize,
            cellSizePixels: CGSize(
                width: terminalFrame.cellSize.width * scale,
                height: terminalFrame.cellSize.height * scale
            ),
            glyphAtlasSizePixels: atlasSize,
            lastGlyphRectPixels: lastGlyphRectPixels,
            lastGlyphUVOrigin: lastGlyphUVOrigin,
            lastGlyphUVSize: lastGlyphUVSize,
            lastGlyphDrawOffsetPoints: lastGlyphDrawOffsetPoints,
            pixelSnappingEnabled: diagnosticPixelSnappingEnabled,
            linearGlyphSamplingEnabled: diagnosticLinearGlyphSamplingEnabled
        )
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
        resetAtlasIfBackingScaleChanged()
        resetAtlasIfCellMetricsChanged()
        var instances: [GlyphInstance] = []
        instances.reserveCapacity(terminalFrame.cells.count + terminalFrame.markedText.count)
        for cell in terminalFrame.cells {
            appendGlyphInstance(character: cell.character, column: cell.column, row: cell.row, into: &instances, color: cell.foreground)
        }
        if !terminalFrame.inputOverlayText.isEmpty && terminalFrame.inputOverlayRow >= 0 {
            var column = terminalFrame.inputOverlayColumn
            for character in terminalFrame.inputOverlayText {
                appendGlyphInstance(character: character, column: column, row: terminalFrame.inputOverlayRow, into: &instances, color: terminalFrame.defaultForeground)
                column += character.terminalColumnWidth
            }
        }
        if !terminalFrame.markedText.isEmpty && terminalFrame.cursorRow >= 0 {
            var column = max(0, terminalFrame.cursorColumn - terminalColumnWidth(of: terminalFrame.markedText))
            for character in terminalFrame.markedText {
                appendGlyphInstance(character: character, column: column, row: terminalFrame.cursorRow, into: &instances, color: terminalFrame.defaultForeground)
                column += character.terminalColumnWidth
            }
        }
        atlasInstanceBuffer = instances.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }

        var backgrounds: [GlyphInstance] = []
        let backgroundRuns = mergedBackgroundRuns()
        backgrounds.reserveCapacity(backgroundRuns.count)
        for background in backgroundRuns {
            backgrounds.append(solidInstance(
                column: background.column,
                row: background.row,
                width: background.width,
                height: terminalFrame.cellSize.height,
                yOffset: 0,
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
            decorations.append(solidInstance(
                column: decoration.column,
                row: decoration.row,
                width: max(1, decoration.width),
                height: max(1, backingScale.rounded(.up)),
                yOffset: yOffset,
                color: decoration.color
            ))
        }
        decorationInstanceBuffer = decorations.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }

        var cursor = solidInstance(
            column: max(0, terminalFrame.cursorColumn),
            row: max(0, terminalFrame.cursorRow),
            width: 1,
            height: max(1, terminalFrame.cellSize.height),
            yOffset: 0,
            color: cursorColor,
            overrideWidth: 2
        )
        cursorInstanceBuffer = device.makeBuffer(bytes: &cursor, length: MemoryLayout<GlyphInstance>.stride, options: .storageModeShared)

        var uniforms = TerminalUniforms(
            viewport: SIMD2<Float>(Float(bounds.width), Float(bounds.height)),
            useLinearGlyphSampling: diagnosticLinearGlyphSamplingEnabled ? 1 : 0
        )
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

    private func solidInstance(
        column: Int,
        row: Int,
        width: Int,
        height: CGFloat,
        yOffset: CGFloat,
        color: SIMD4<Float>,
        overrideWidth: CGFloat? = nil
    ) -> GlyphInstance {
        let rect = snappedRect(
            x: terminalFrame.padding.x + CGFloat(column) * terminalFrame.cellSize.width,
            y: bounds.height - terminalFrame.padding.y - terminalFrame.cellSize.height * CGFloat(row + 1) + yOffset,
            width: overrideWidth ?? terminalFrame.cellSize.width * CGFloat(max(1, width)),
            height: height
        )
        return GlyphInstance(
            origin: SIMD2<Float>(Float(rect.origin.x), Float(rect.origin.y)),
            size: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            uvOrigin: .zero,
            uvSize: .zero,
            color: color
        )
    }

    private func mergedBackgroundRuns() -> [BackgroundRun] {
        let sorted = terminalFrame.backgrounds
            .filter { $0.row >= 0 && $0.row < terminalFrame.visibleRows && !$0.color.sameColor(as: terminalFrame.defaultBackground) }
            .sorted {
                if $0.row != $1.row { return $0.row < $1.row }
                return $0.column < $1.column
            }
        var backgroundRuns: [BackgroundRun] = []
        for background in sorted {
            if var last = backgroundRuns.last,
               last.row == background.row,
               last.column + last.width == background.column,
               last.color.sameColor(as: background.color) {
                last.width += 1
                backgroundRuns[backgroundRuns.count - 1] = last
            } else {
                backgroundRuns.append(BackgroundRun(
                    column: background.column,
                    row: background.row,
                    width: 1,
                    color: background.color
                ))
            }
        }
        return backgroundRuns
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
        // Linear atlas sampling must sample texel centers, not slot edges, or neighboring glyphs bleed in.
        let halfTexel = 0.5 / Float(atlasSize)
        let uvOrigin = SIMD2<Float>(
            Float(x) / Float(atlasSize) + halfTexel,
            Float(y) / Float(atlasSize) + halfTexel
        )
        let uvSize = SIMD2<Float>(
            Float(max(0, drawWidthPixels - 1)) / Float(atlasSize),
            Float(max(0, drawHeightPixels - 1)) / Float(atlasSize)
        )
        lastGlyphRectPixels = CGRect(x: x, y: y, width: drawWidthPixels, height: drawHeightPixels)
        lastGlyphUVOrigin = uvOrigin
        lastGlyphUVSize = uvSize
        lastGlyphDrawOffsetPoints = rasterized.drawOffset
        let entry = GlyphAtlasEntry(
            uvOrigin: uvOrigin,
            uvSize: uvSize,
            drawOffset: rasterized.drawOffset,
            drawSize: rasterized.drawSize
        )
        glyphs[key] = entry
        return entry
    }

    private func rasterizeGlyph(_ character: Character, x: Int, y: Int) -> RasterizedGlyph {
        var slot = [UInt8](repeating: 0, count: glyphSlotWidth * glyphSlotHeight * 4)
        let columnWidth = max(1, character.terminalColumnWidth)
        let logicalAdvanceWidth = terminalFrame.cellSize.width * CGFloat(columnWidth)
        let logicalHeight = terminalFrame.cellSize.height
        let scale = atlasScale(forLogicalWidth: logicalAdvanceWidth, logicalHeight: logicalHeight)
        let scaledFont = scaledFont(for: character, scale: scale)
        let string = NSAttributedString(
            string: String(character),
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): scaledFont,
                .foregroundColor: NSColor.white,
            ]
        )
        let line = CTLineCreateWithAttributedString(string)
        var typographicAscent: CGFloat = 0
        var typographicDescent: CGFloat = 0
        var typographicLeading: CGFloat = 0
        let typographicWidth = max(
            1,
            CGFloat(CTLineGetTypographicBounds(line, &typographicAscent, &typographicDescent, &typographicLeading))
        )
        let imageBounds = CTLineGetImageBounds(line, nil)
        let paddingPixels = Int(DesignTokens.Component.glyphSlotPaddingPX)
        guard !imageBounds.isNull, imageBounds.width > 0, imageBounds.height > 0 else {
            return RasterizedGlyph(drawOffset: .zero, drawSize: .zero)
        }

        let pixelWidth = min(glyphSlotWidth, max(1, Int(ceil(imageBounds.width)) + paddingPixels * 2))
        let pixelHeight = min(glyphSlotHeight, max(1, Int(ceil(imageBounds.height)) + paddingPixels * 2))
        let imageLogicalWidth = imageBounds.width / scale
        let desiredInkLeft = columnWidth > 1 ? max(0, (logicalAdvanceWidth - imageLogicalWidth) * 0.5) : imageBounds.minX / scale
        let scaledLogicalHeight = logicalHeight * scale
        let typographicHeight = typographicAscent + typographicDescent
        let verticalInset = max(0, (scaledLogicalHeight - typographicHeight) * 0.5)
        let desiredInkBottom = (verticalInset + typographicDescent + imageBounds.minY) / scale
        let result = RasterizedGlyph(
            drawOffset: SIMD2<Float>(
                Float(desiredInkLeft - CGFloat(paddingPixels) / scale),
                Float(desiredInkBottom - CGFloat(paddingPixels) / scale)
            ),
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

        let baselineX = CGFloat(paddingPixels) - imageBounds.minX
        let baselineY = CGFloat(glyphSlotHeight) - CGFloat(paddingPixels) - imageBounds.maxY
        let availableWidth = max(1, logicalAdvanceWidth * scale)
        let horizontalScale = min(1, availableWidth / typographicWidth)
        context.saveGState()
        context.translateBy(x: baselineX, y: baselineY)
        context.scaleBy(x: horizontalScale, y: 1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()

        for row in 0..<glyphSlotHeight {
            let src = row * glyphSlotWidth * 4
            let dst = ((y + row) * atlasSize + x) * 4
            atlasPixels.replaceSubrange(dst..<(dst + glyphSlotWidth * 4), with: slot[src..<(src + glyphSlotWidth * 4)])
        }
        return result
    }

    private func scaledFont(for character: Character, scale: CGFloat) -> CTFont {
        let pointSize = font.pointSize * scale
        let baseFont = CTFontCreateWithName(font.fontName as CFString, pointSize, nil)
        if Self.fontSupports(character, font: baseFont) {
            return baseFont
        }

        for fontName in Self.glyphFallbackFontNames {
            let candidate = CTFontCreateWithName(fontName as CFString, pointSize, nil)
            if Self.fontSupports(character, font: candidate) {
                return candidate
            }
        }

        let string = String(character) as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        let cascadeFont = CTFontCreateForString(baseFont, string, range)
        if Self.fontSupports(character, font: cascadeFont) {
            return cascadeFont
        }

        return baseFont
    }

    private static func fontSupports(_ character: Character, font: CTFont) -> Bool {
        let utf16 = Array(String(character).utf16)
        guard !utf16.isEmpty else { return false }
        var characters = utf16.map { UniChar($0) }
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        let mapped = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        return mapped && glyphs.contains { $0 != 0 }
    }

    private func resetAtlasIfCellMetricsChanged() {
        guard terminalFrame.cellSize != .zero, terminalFrame.cellSize != atlasCellSize else { return }
        atlasCellSize = terminalFrame.cellSize
        resetAtlas()
    }

    private func resetAtlasIfBackingScaleChanged() {
        let scale = backingScale
        guard atlasBackingScale != scale else { return }
        atlasBackingScale = scale
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
        guard diagnosticPixelSnappingEnabled else { return value }
        // Geometry stays in AppKit points; snapping converts through backing pixels and returns points.
        return round(value * scale) / scale
    }

    private func snappedRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        guard diagnosticPixelSnappingEnabled else {
            return CGRect(x: x, y: y, width: width, height: height)
        }
        let scale = backingScale
        let minX = floor(x * scale) / scale
        let minY = floor(y * scale) / scale
        let maxX = ceil((x + width) * scale) / scale
        let maxY = ceil((y + height) * scale) / scale
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func logRenderingDiagnosticsIfNeeded() {
        guard diagnosticRenderingLogEnabled else { return }
        let diagnostics = renderingDiagnostics
        NSLog(
            "Kurotty render diagnostics: scale=%0.2f drawable=%@ cellPt=%@ cellPx=%@ atlasPx=%d glyphRectPx=%@ uvOrigin=(%0.6f,%0.6f) uvSize=(%0.6f,%0.6f) offsetPt=(%0.3f,%0.3f) snap=%@ linearSampler=%@",
            diagnostics.backingScaleFactor,
            NSStringFromSize(diagnostics.drawableSize),
            NSStringFromSize(diagnostics.cellSizePoints),
            NSStringFromSize(diagnostics.cellSizePixels),
            diagnostics.glyphAtlasSizePixels,
            NSStringFromRect(diagnostics.lastGlyphRectPixels),
            diagnostics.lastGlyphUVOrigin.x,
            diagnostics.lastGlyphUVOrigin.y,
            diagnostics.lastGlyphUVSize.x,
            diagnostics.lastGlyphUVSize.y,
            diagnostics.lastGlyphDrawOffsetPoints.x,
            diagnostics.lastGlyphDrawOffsetPoints.y,
            diagnostics.pixelSnappingEnabled ? "on" : "off",
            diagnostics.linearGlyphSamplingEnabled ? "on" : "off"
        )
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
    let useLinearGlyphSampling: UInt32
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
    uint useLinearGlyphSampling;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct GlyphVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint useLinearGlyphSampling;
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
    out.useLinearGlyphSampling = uniforms.useLinearGlyphSampling;
    return out;
}

fragment float4 terminal_glyph_fragment(GlyphVertexOut in [[stage_in]],
                                        texture2d<float> glyph_atlas [[texture(0)]]) {
    constexpr sampler linear_glyph_sampler(address::clamp_to_edge, filter::linear);
    constexpr sampler nearest_glyph_sampler(address::clamp_to_edge, filter::nearest);
    float4 sample = in.useLinearGlyphSampling == 0
        ? glyph_atlas.sample(nearest_glyph_sampler, in.uv)
        : glyph_atlas.sample(linear_glyph_sampler, in.uv);
    return float4(in.color.rgb, sample.a * in.color.a);
}

fragment float4 terminal_solid_fragment(GlyphVertexOut in [[stage_in]]) {
    return in.color;
}
"""

private extension SIMD4 where Scalar == Float {
    func sameColor(as other: SIMD4<Float>) -> Bool {
        x == other.x && y == other.y && z == other.z && w == other.w
    }
}

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
