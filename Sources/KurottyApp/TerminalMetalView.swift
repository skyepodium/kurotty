import AppKit
import CoreText
import CoreGraphics
import KurottyCore
import Metal
import MetalKit

private extension TerminalFrameRect {
    var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}

private extension TerminalFrameSize {
    var cgSize: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    var cgWidth: CGFloat { CGFloat(width) }
    var cgHeight: CGFloat { CGFloat(height) }
}

private extension TerminalFramePoint {
    var cgX: CGFloat { CGFloat(x) }
    var cgY: CGFloat { CGFloat(y) }
}

private struct MainQueuePresentationCallback: @unchecked Sendable {
    let run: () -> Void
}

private struct BackgroundRun {
    let column: Int
    let row: Int
    var width: Int
    let color: SIMD4<Float>
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

struct TerminalRenderScissorRect: Equatable, CustomStringConvertible {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var description: String {
        "{x:\(x),y:\(y),w:\(width),h:\(height)}"
    }
}

struct TerminalRenderDamageDiagnostics {
    enum RedrawDecision: CustomStringConvertible {
        case full
        case partial

        var description: String {
            switch self {
            case .full:
                "full"
            case .partial:
                "partial"
            }
        }
    }

    enum SchedulingPolicy: CustomStringConvertible {
        case fullRedrawFallback
        case displayCadenceCoalescingCandidate
        case immediatePartialRedraw

        var description: String {
            switch self {
            case .fullRedrawFallback:
                "full-redraw-fallback"
            case .displayCadenceCoalescingCandidate:
                "display-cadence-coalescing-candidate"
            case .immediatePartialRedraw:
                "immediate-partial-redraw"
            }
        }
    }

    enum CoalescingFallbackReason: CustomStringConvertible {
        case none
        case diagnosticFullRedraw
        case fullDamageFrame
        case emptyDirtyRects
        case scissorDisabled
        case unstablePixelBounds

        var description: String {
            switch self {
            case .none:
                "none"
            case .diagnosticFullRedraw:
                "diagnostic-full-redraw"
            case .fullDamageFrame:
                "full-damage-frame"
            case .emptyDirtyRects:
                "empty-dirty-rects"
            case .scissorDisabled:
                "scissor-disabled"
            case .unstablePixelBounds:
                "unstable-pixel-bounds"
            }
        }
    }

    enum ScissorReadiness: Equatable, CustomStringConvertible {
        case ready
        case fullRedrawFallback
        case scissorDisabled
        case unstablePixelBounds

        var description: String {
            switch self {
            case .ready:
                "ready"
            case .fullRedrawFallback:
                "full-redraw-fallback"
            case .scissorDisabled:
                "scissor-disabled"
            case .unstablePixelBounds:
                "unstable-pixel-bounds"
            }
        }
    }

    let redrawDecision: RedrawDecision
    let schedulingPolicy: SchedulingPolicy
    let dirtyRectCount: Int
    let scissorDisabled: Bool
    let submittedDisplayRects: [CGRect]
    let uncoalescedSubmittedDisplayRectCount: Int
    let scheduledDisplayRectCount: Int
    let coalescedDisplayRectCount: Int
    let canCoalesceAtDisplayCadence: Bool
    let coalescingFallbackReason: CoalescingFallbackReason
    let stablePixelBounds: [TerminalFramePixelRect]
    let stablePixelBoundCount: Int
    let scissorReadiness: ScissorReadiness
    let scissorRects: [TerminalRenderScissorRect]
    let scissorRectCount: Int

    var scissorPlanIsReady: Bool {
        scissorReadiness == .ready && !scissorRects.isEmpty
    }

    static let empty = TerminalRenderDamageDiagnostics(
        redrawDecision: .full,
        schedulingPolicy: .fullRedrawFallback,
        dirtyRectCount: 0,
        scissorDisabled: false,
        submittedDisplayRects: [],
        uncoalescedSubmittedDisplayRectCount: 0,
        scheduledDisplayRectCount: 0,
        coalescedDisplayRectCount: 0,
        canCoalesceAtDisplayCadence: false,
        coalescingFallbackReason: .emptyDirtyRects,
        stablePixelBounds: [],
        stablePixelBoundCount: 0,
        scissorReadiness: .fullRedrawFallback,
        scissorRects: [],
        scissorRectCount: 0
    )

    static func make(
        frame: TerminalFrame,
        bounds: CGRect,
        backingScale: CGFloat,
        diagnosticFullRedrawEnabled: Bool,
        scissorDisabled: Bool
    ) -> TerminalRenderDamageDiagnostics {
        let displaySize = TerminalFrameSize(width: Double(bounds.width), height: Double(bounds.height))
        let policy = frame.damageMetadata.redrawPolicy(
            scale: Double(backingScale),
            clipTo: displaySize,
            diagnosticFullRedrawEnabled: diagnosticFullRedrawEnabled,
            scissorDisabled: scissorDisabled
        )
        let uncoalescedSubmittedDisplayRects = policy.redrawDecision == .full ? [bounds] : frame.dirtyRects.map(\.cgRect)
        let submittedDisplayRects = policy.canCoalesceAtDisplayCadence
            ? coalescedDisplayRects(uncoalescedSubmittedDisplayRects)
            : uncoalescedSubmittedDisplayRects
        let scissorReadiness = scissorReadiness(from: policy)
        let scissorRects = scissorReadiness == .ready
            ? makeScissorRects(
                from: policy.stablePixelBounds,
                drawableSize: CGSize(
                    width: ceil(bounds.width * backingScale),
                    height: ceil(bounds.height * backingScale)
                )
            )
            : []
        return TerminalRenderDamageDiagnostics(
            redrawDecision: redrawDecision(from: policy.redrawDecision),
            schedulingPolicy: schedulingPolicy(from: policy.schedulingPolicy),
            dirtyRectCount: frame.dirtyRects.count,
            scissorDisabled: scissorDisabled,
            submittedDisplayRects: submittedDisplayRects,
            uncoalescedSubmittedDisplayRectCount: uncoalescedSubmittedDisplayRects.count,
            scheduledDisplayRectCount: submittedDisplayRects.count,
            coalescedDisplayRectCount: max(0, uncoalescedSubmittedDisplayRects.count - submittedDisplayRects.count),
            canCoalesceAtDisplayCadence: policy.canCoalesceAtDisplayCadence,
            coalescingFallbackReason: coalescingFallbackReason(from: policy.coalescingFallbackReason),
            stablePixelBounds: policy.stablePixelBounds,
            stablePixelBoundCount: policy.stablePixelBoundCount,
            scissorReadiness: scissorRects.isEmpty && scissorReadiness == .ready ? .unstablePixelBounds : scissorReadiness,
            scissorRects: scissorRects,
            scissorRectCount: scissorRects.count
        )
    }

    private static func scissorReadiness(from policy: TerminalFrameDamageRedrawPolicy) -> ScissorReadiness {
        switch policy.coalescingFallbackReason {
        case .none:
            policy.redrawDecision == .partial ? .ready : .fullRedrawFallback
        case .scissorDisabled:
            .scissorDisabled
        case .unstablePixelBounds:
            .unstablePixelBounds
        case .diagnosticFullRedraw, .fullDamageFrame, .emptyDirtyRects:
            .fullRedrawFallback
        }
    }

    private static func makeScissorRects(
        from pixelBounds: [TerminalFramePixelRect],
        drawableSize: CGSize
    ) -> [TerminalRenderScissorRect] {
        let drawableWidth = max(0, Int(drawableSize.width.rounded(.up)))
        let drawableHeight = max(0, Int(drawableSize.height.rounded(.up)))
        guard drawableWidth > 0, drawableHeight > 0 else { return [] }
        return pixelBounds.compactMap { rect in
            let (rectMaxX, overflowX) = rect.x.addingReportingOverflow(rect.width)
            let (rectMaxY, overflowY) = rect.y.addingReportingOverflow(rect.height)
            guard !overflowX, !overflowY else { return nil }
            let minX = max(0, min(drawableWidth, rect.x))
            let minY = max(0, min(drawableHeight, rect.y))
            let maxX = max(0, min(drawableWidth, rectMaxX))
            let maxY = max(0, min(drawableHeight, rectMaxY))
            let width = maxX - minX
            let height = maxY - minY
            guard width > 0, height > 0 else { return nil }
            return TerminalRenderScissorRect(x: minX, y: minY, width: width, height: height)
        }
    }

    private static func redrawDecision(from decision: TerminalFrameRedrawDecision) -> RedrawDecision {
        switch decision {
        case .full:
            .full
        case .partial:
            .partial
        }
    }

    private static func schedulingPolicy(from policy: TerminalFrameDamageSchedulingPolicy) -> SchedulingPolicy {
        switch policy {
        case .fullRedrawFallback:
            .fullRedrawFallback
        case .displayCadenceCoalescingCandidate:
            .displayCadenceCoalescingCandidate
        case .immediatePartialRedraw:
            .immediatePartialRedraw
        }
    }

    private static func coalescingFallbackReason(
        from reason: TerminalFrameCoalescingFallbackReason
    ) -> CoalescingFallbackReason {
        switch reason {
        case .none:
            .none
        case .diagnosticFullRedraw:
            .diagnosticFullRedraw
        case .fullDamageFrame:
            .fullDamageFrame
        case .emptyDirtyRects:
            .emptyDirtyRects
        case .scissorDisabled:
            .scissorDisabled
        case .unstablePixelBounds:
            .unstablePixelBounds
        }
    }

    private static func coalescedDisplayRects(_ rects: [CGRect]) -> [CGRect] {
        let sortedRects = rects
            .filter { !$0.isNull && !$0.isEmpty }
            .sorted {
                if $0.minY != $1.minY { return $0.minY < $1.minY }
                return $0.minX < $1.minX
            }
        guard var current = sortedRects.first else { return [] }

        var coalescedRects: [CGRect] = []
        for rect in sortedRects.dropFirst() {
            if Self.canCoalesceDisplayRects(current, rect) {
                current = current.union(rect)
            } else {
                coalescedRects.append(current)
                current = rect
            }
        }
        coalescedRects.append(current)
        return coalescedRects
    }

    private static func canCoalesceDisplayRects(_ first: CGRect, _ second: CGRect) -> Bool {
        first.maxX >= second.minX &&
            second.maxX >= first.minX &&
            first.maxY >= second.minY &&
            second.maxY >= first.minY
    }
}

final class TerminalMetalView: MTKView, MTKViewDelegate, TerminalAppKitRenderer {
    private static let renderTargetPixelFormat: MTLPixelFormat = .bgra8Unorm
    private static let glyphAtlasPixelFormat: MTLPixelFormat = .rgba8Unorm
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
    var diagnosticLinearGlyphSamplingEnabled = false {
        didSet {
            rebuildAtlasBuffers()
            setNeedsDisplay(bounds)
        }
    }
    var diagnosticCellBoundaryOverlayEnabled = false {
        didSet {
            rebuildAtlasBuffers()
            setNeedsDisplay(bounds)
        }
    }
    var diagnosticBaselineOverlayEnabled = false {
        didSet {
            rebuildAtlasBuffers()
            setNeedsDisplay(bounds)
        }
    }
    var diagnosticGlyphQuadOverlayEnabled = false {
        didSet {
            rebuildAtlasBuffers()
            setNeedsDisplay(bounds)
        }
    }
    var diagnosticFullRedrawEnabled = false {
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
    private var debugOverlayInstanceBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?
    private var texture: MTLTexture?
    private var atlasTexture: MTLTexture?
    private var atlasPixels: [UInt8] = []
    private var glyphs: [String: GlyphAtlasEntry] = [:]
    private var atlasSlot = 0
    private var atlasCellSize = TerminalFrameSize.zero
    private var atlasBackingScale: CGFloat = 0
    private var windowScreenObserver: NSObjectProtocol?
    private var isSynchronizingDisplay = false
    private var lastGlyphRectPixels = CGRect.zero
    private var lastGlyphUVOrigin = SIMD2<Float>.zero
    private var lastGlyphUVSize = SIMD2<Float>.zero
    private var lastGlyphDrawOffsetPoints = SIMD2<Float>.zero
    private var lastAtlasBufferSignature: Int?
    private var lastFontCellMetricsInput: FontCellMetricsInput?
    private var font: NSFont
    private var backgroundColor: SIMD4<Float>
    private var cursorColor: SIMD4<Float>
    private var renderFrameIndex: UInt64 = 0
    private let atlasSize = DesignTokens.Component.glyphAtlasSizePX
    private let glyphSlotWidth = DesignTokens.Component.glyphSlotWidthPX
    private let glyphSlotHeight = DesignTokens.Component.glyphSlotHeightPX
    private var fontCellMetrics: FontCellMetrics = .empty
    private var terminalFrame = TerminalFrame(cells: [], backgrounds: [], decorations: [], defaultForeground: DesignTokens.Color.terminalForeground, defaultBackground: DesignTokens.Color.terminalDefaultBackground, dirtyRows: [], dirtyRects: [], isFullDamage: true, cursorColumn: 0, cursorRow: 0, cursorBlinkOn: true, markedTextColumn: 0, markedText: "", markedTextSelectedRange: .none, columns: 1, visibleRows: 1, cellSize: .zero, padding: .zero)
    private var lastDamageDiagnostics = TerminalRenderDamageDiagnostics.empty
    private var lastPixelProbeDiagnostics: [TerminalPixelProbe] = []

    override var isOpaque: Bool {
        true
    }

    var rendererView: NSView { self }

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
        colorPixelFormat = TerminalMetalView.renderTargetPixelFormat
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        framebufferOnly = true
        layer?.isOpaque = true
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
        rebuildFontCellMetrics()
        initializeAtlas()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.isOpaque = true
        observeWindowScreenChanges()
        synchronizeBackingScaleAndDrawableSize()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        removeWindowScreenObserver()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizeBackingScaleAndDrawableSize()
    }

    override func layout() {
        super.layout()
        synchronizeBackingScaleAndDrawableSize()
    }

    func update(frame: TerminalFrame) {
        terminalFrame = frame
        rebuildFontCellMetrics()
        synchronizeBackingScaleAndDrawableSize()
        let shouldRebuildAtlasBuffers = atlasBuffersNeedRebuild(for: frame)
        if shouldRebuildAtlasBuffers {
            rebuildAtlasBuffers()
        }
        logRenderingDiagnosticsIfNeeded()
        if diagnosticCPUFallbackEnabled {
            rebuildTextTexture()
        }
        let damageDiagnostics = TerminalRenderDamageDiagnostics.make(
            frame: frame,
            bounds: bounds,
            backingScale: backingScale,
            diagnosticFullRedrawEnabled: diagnosticFullRedrawEnabled,
            scissorDisabled: DebugOptions.noScissor
        )
        lastDamageDiagnostics = damageDiagnostics
        let submittedDisplayRects = damageDiagnostics.submittedDisplayRects
        for rect in submittedDisplayRects {
            setNeedsDisplay(rect)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        synchronizeBackingScaleAndDrawableSize()
        rebuildVertexBuffer()
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
        rebuildFontCellMetrics()
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
            let commandBuffer = commandQueue?.makeCommandBuffer()
        else {
            return
        }
        configureRenderPassDescriptor(descriptor)
        logFrameStartIfNeeded(descriptor: descriptor)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
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

            if terminalFrame.cursorBlinkOn,
               terminalFrame.cursorRow >= 0,
               let solidPipeline,
               let cursorInstanceBuffer {
                encoder.setRenderPipelineState(solidPipeline)
                encoder.setVertexBuffer(atlasVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(cursorInstanceBuffer, offset: 0, index: 1)
                encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }

            if let solidPipeline,
               let debugOverlayInstanceBuffer,
               debugOverlayInstanceCount > 0 {
                encoder.setRenderPipelineState(solidPipeline)
                encoder.setVertexBuffer(atlasVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(debugOverlayInstanceBuffer, offset: 0, index: 1)
                encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: debugOverlayInstanceCount)
            }
        }

        encoder.endEncoding()
        let presentedCompletionHandler = Self.makePresentedCompletionHandler(onPresented)
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler(presentedCompletionHandler)
        commandBuffer.commit()
        renderFrameIndex &+= 1
    }

    nonisolated private static func makePresentedCompletionHandler(
        _ onPresented: (() -> Void)?
    ) -> MTLCommandBufferHandler {
        let callback = onPresented.map { MainQueuePresentationCallback(run: $0) }
        return { _ in
            guard let callback else {
                return
            }
            DispatchQueue.main.async {
                callback.run()
            }
        }
    }

    var isAtlasPathReadyForRendering: Bool {
        // Background and cursor quads must still draw on frames where the grid has
        // no visible glyphs; glyph count is only a text draw concern.
        atlasResourcesAreAvailableForDiagnostics
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
            cellSizePoints: terminalFrame.cellSize.cgSize,
            cellSizePixels: CGSize(
                width: terminalFrame.cellSize.cgWidth * scale,
                height: terminalFrame.cellSize.cgHeight * scale
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

    var damageDiagnostics: TerminalRenderDamageDiagnostics {
        lastDamageDiagnostics
    }

    var pixelProbeDiagnostics: [TerminalPixelProbe] {
        lastPixelProbeDiagnostics
    }

    var lastFrameDirtyRowsForDiagnostics: [Int] {
        terminalFrame.dirtyRows
    }

    var lastFrameDirtyRectsForDiagnostics: [CGRect] {
        terminalFrame.dirtyRects.map(\.cgRect)
    }

    var lastFrameDamageWasFullForDiagnostics: Bool {
        terminalFrame.isFullDamage
    }

    var lastSubmittedDisplayRectsForDiagnostics: [CGRect] {
        lastDamageDiagnostics.submittedDisplayRects
    }

    var lastFrameScissorWasDisabledForDiagnostics: Bool {
        lastDamageDiagnostics.scissorDisabled
    }

    var lastFrameCanCoalesceAtDisplayCadenceForDiagnostics: Bool {
        lastDamageDiagnostics.canCoalesceAtDisplayCadence
    }

    var lastFrameCoalescingFallbackReasonForDiagnostics: String {
        lastDamageDiagnostics.coalescingFallbackReason.description
    }

    var lastFrameStablePixelBoundCountForDiagnostics: Int {
        lastDamageDiagnostics.stablePixelBoundCount
    }

    var lastFrameScissorReadinessForDiagnostics: String {
        lastDamageDiagnostics.scissorReadiness.description
    }

    var lastFrameScissorPlanIsReadyForDiagnostics: Bool {
        lastDamageDiagnostics.scissorPlanIsReady
    }

    var lastFrameScissorRectsForDiagnostics: [TerminalRenderScissorRect] {
        lastDamageDiagnostics.scissorRects
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

    private var debugOverlayInstanceCount: Int {
        guard let debugOverlayInstanceBuffer else { return 0 }
        return debugOverlayInstanceBuffer.length / MemoryLayout<GlyphInstance>.stride
    }

    private func configureRenderPassDescriptor(_ descriptor: MTLRenderPassDescriptor) {
        let colorAttachment = descriptor.colorAttachments[0]
        colorAttachment?.loadAction = .clear
        colorAttachment?.storeAction = .store
        colorAttachment?.clearColor = clearColor
    }

    private func logFrameStartIfNeeded(descriptor: MTLRenderPassDescriptor) {
        guard diagnosticRenderingLogEnabled else { return }
        let colorAttachment = descriptor.colorAttachments[0]
        NSLog(
            "Kurotty render frame: index=%llu fullRedraw=%@ redrawDecision=%@ schedulingPolicy=%@ coalesceAtDisplayCadence=%@ coalescingFallbackReason=%@ dirtyRects=%d submittedDisplayRects=%@ uncoalescedSubmittedDisplayRects=%d scheduledDisplayRects=%d coalescedDisplayRects=%d stablePixelBoundCount=%d stablePixelBounds=%@ scissorReadiness=%@ scissorPlanReady=%@ scissorRects=%@ noScissor=%@ drawable=%@ viewport=%@ loadAction=%@ storeAction=%@ clearColor=(%0.4f,%0.4f,%0.4f,%0.4f) background=(%0.4f,%0.4f,%0.4f,%0.4f) colorPixelFormat=%@ layerColorSpace=%@ solidBlend=disabled glyphBlend=straight-alpha",
            renderFrameIndex,
            diagnosticFullRedrawEnabled ? "yes" : "no",
            damageDiagnostics.redrawDecision.description,
            damageDiagnostics.schedulingPolicy.description,
            damageDiagnostics.canCoalesceAtDisplayCadence ? "yes" : "no",
            damageDiagnostics.coalescingFallbackReason.description,
            damageDiagnostics.dirtyRectCount,
            damageDiagnostics.submittedDisplayRects.map { NSStringFromRect($0) }.joined(separator: " | "),
            damageDiagnostics.uncoalescedSubmittedDisplayRectCount,
            damageDiagnostics.scheduledDisplayRectCount,
            damageDiagnostics.coalescedDisplayRectCount,
            damageDiagnostics.stablePixelBoundCount,
            damageDiagnostics.stablePixelBounds.map { "{x:\($0.x),y:\($0.y),w:\($0.width),h:\($0.height)}" }.joined(separator: " | "),
            damageDiagnostics.scissorReadiness.description,
            damageDiagnostics.scissorPlanIsReady ? "yes" : "no",
            damageDiagnostics.scissorRects.map(\.description).joined(separator: " | "),
            damageDiagnostics.scissorDisabled ? "yes" : "no",
            NSStringFromSize(drawableSize),
            NSStringFromSize(drawableSize),
            "\(colorAttachment?.loadAction ?? .dontCare)",
            "\(colorAttachment?.storeAction ?? .dontCare)",
            clearColor.red,
            clearColor.green,
            clearColor.blue,
            clearColor.alpha,
            backgroundColor.x,
            backgroundColor.y,
            backgroundColor.z,
            backgroundColor.w,
            "\(Self.renderTargetPixelFormat)",
            colorspace?.name as String? ?? "nil"
        )
        if DebugOptions.renderRects {
            let cursorRect = inputCursorRect(row: max(0, terminalFrame.cursorRow))
            NSLog(
                "Kurotty render rects: cursorRectPx=%@ cursorRectPt=%@ backgrounds=%d glyphs=%d cursor=(col:%d,row:%d) fullRedraw=%@",
                NSStringFromRect(physicalPixelRect(cursorRect)),
                NSStringFromRect(cursorRect),
                backgroundInstanceCount,
                atlasInstanceCount,
                terminalFrame.cursorColumn,
                terminalFrame.cursorRow,
                diagnosticFullRedrawEnabled ? "yes" : "no"
            )
        }
        if DebugOptions.dirtyRects || DebugOptions.cursorCell {
            NSLog(
                "Kurotty model rects: dirtyRows=%@ dirtyRects=%@ submittedDisplayRects=%@ cursorCell=(%d,%d) noScissor=%@",
                terminalFrame.dirtyRows.map(String.init).joined(separator: ","),
                terminalFrame.dirtyRects.map { NSStringFromRect($0.cgRect) }.joined(separator: " | "),
                damageDiagnostics.submittedDisplayRects.map { NSStringFromRect($0) }.joined(separator: " | "),
                terminalFrame.cursorRow,
                terminalFrame.cursorColumn,
                damageDiagnostics.scissorDisabled ? "yes" : "no"
            )
        }
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

    private func updateSharedBuffer<T>(_ buffer: inout MTLBuffer?, with values: [T]) {
        guard let device else {
            buffer = nil
            return
        }
        let byteCount = values.count * MemoryLayout<T>.stride
        guard byteCount > 0 else {
            buffer = nil
            return
        }
        if buffer?.length != byteCount {
            buffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
        }
        guard let target = buffer?.contents() else {
            buffer = nil
            return
        }
        values.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            target.copyMemory(from: source, byteCount: byteCount)
        }
    }

    private func updateSharedBuffer<T>(_ buffer: inout MTLBuffer?, with value: inout T) {
        guard let device else {
            buffer = nil
            return
        }
        let byteCount = MemoryLayout<T>.stride
        if buffer?.length != byteCount {
            buffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
        }
        guard let target = buffer?.contents() else {
            buffer = nil
            return
        }
        withUnsafeBytes(of: &value) { bytes in
            guard let source = bytes.baseAddress else { return }
            target.copyMemory(from: source, byteCount: byteCount)
        }
    }

    private func initializeAtlas() {
        guard let device else { return }
        atlasPixels = [UInt8](repeating: 0, count: atlasSize * atlasSize * 4)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.glyphAtlasPixelFormat, width: atlasSize, height: atlasSize, mipmapped: false)
        descriptor.usage = [.shaderRead]
        atlasTexture = device.makeTexture(descriptor: descriptor)
        uploadAtlas()
    }

    private func rebuildAtlasBuffers() {
        guard device != nil, bounds.width > 0, bounds.height > 0 else { return }
        resetAtlasIfBackingScaleChanged()
        resetAtlasIfCellMetricsChanged()
        var instances: [GlyphInstance] = []
        var glyphDebugRects: [CGRect] = []
        var pixelProbes: [TerminalPixelProbe] = []
        instances.reserveCapacity(terminalFrame.cells.count + terminalFrame.markedText.count)
        for cell in terminalFrame.cells {
            guard !isCellCoveredByMarkedText(cell) else { continue }
            appendGlyphInstance(
                character: cell.character,
                column: cell.column,
                row: cell.row,
                into: &instances,
                debugRects: &glyphDebugRects,
                pixelProbes: &pixelProbes,
                color: cell.foreground
            )
        }
        if !terminalFrame.markedText.isEmpty && terminalFrame.cursorRow >= 0 {
            var column = terminalFrame.markedTextColumn
            var utf16Offset = 0
            for character in terminalFrame.markedText {
                appendGlyphInstance(
                    character: character,
                    column: column,
                    row: terminalFrame.cursorRow,
                    into: &instances,
                    debugRects: &glyphDebugRects,
                    pixelProbes: &pixelProbes,
                    color: markedTextColor(for: character, utf16Offset: utf16Offset)
                )
                column += character.terminalColumnWidth
                utf16Offset += String(character).utf16.count
            }
        }
        updateSharedBuffer(&atlasInstanceBuffer, with: instances)

        let backgroundRuns = mergedBackgroundRuns()
        if DebugOptions.backgroundRuns {
            NSLog(
                "Kurotty background runs: count=%d runs=%@",
                backgroundRuns.count,
                backgroundRuns.map { "row:\($0.row) col:\($0.column) width:\($0.width) color:\($0.color.debugRGB)" }.joined(separator: " | ")
            )
        }
        var backgrounds: [GlyphInstance] = []
        backgrounds.reserveCapacity(backgroundRuns.count)
        for background in backgroundRuns {
            backgrounds.append(solidInstance(
                column: background.column,
                row: background.row,
                width: background.width,
                height: terminalFrame.cellSize.cgHeight,
                yOffset: 0,
                color: background.color
            ))
        }
        updateSharedBuffer(&backgroundInstanceBuffer, with: backgrounds)

        var decorations: [GlyphInstance] = []
        decorations.reserveCapacity(terminalFrame.decorations.count)
        for decoration in terminalFrame.decorations where decoration.row >= 0 && decoration.row < terminalFrame.visibleRows {
            switch decoration.kind {
            case let .boxDrawing(left, right, up, down):
                appendBoxDrawingDecorationInstances(
                    column: decoration.column,
                    row: decoration.row,
                    left: left,
                    right: right,
                    up: up,
                    down: down,
                    color: decoration.color,
                    to: &decorations
                )
                continue
            case let .blockElement(x, y, width, height):
                decorations.append(blockElementInstance(
                    column: decoration.column,
                    row: decoration.row,
                    x: x,
                    y: y,
                    width: width,
                    height: height,
                    color: decoration.color
                ))
                continue
            case .underline, .strikethrough:
                break
            }

            let yOffset: CGFloat
            switch decoration.kind {
            case .underline:
                yOffset = physicalPixelsToPoints(CGFloat(fontCellMetrics.underlinePositionPixels))
            case .strikethrough:
                yOffset = pixelAlign(terminalFrame.cellSize.cgHeight * 0.52, scale: backingScale)
            case .boxDrawing, .blockElement:
                continue
            }
            decorations.append(solidInstance(
                column: decoration.column,
                row: decoration.row,
                width: max(1, decoration.width),
                height: physicalPixelsToPoints(CGFloat(fontCellMetrics.underlineThicknessPixels)),
                yOffset: yOffset,
                color: decoration.color
            ))
        }
        updateSharedBuffer(&decorationInstanceBuffer, with: decorations)

        var cursor = solidInstance(
            column: max(0, terminalFrame.cursorColumn),
            row: max(0, terminalFrame.cursorRow),
            width: 1,
            height: physicalPixelsToPoints(CGFloat(fontCellMetrics.cursorHeightPixels)),
            yOffset: 0,
            color: cursorColor,
            overrideWidth: physicalPixelsToPoints(CGFloat(AppConstants.Terminal.cursorWidthPX))
        )
        updateSharedBuffer(&cursorInstanceBuffer, with: &cursor)
        rebuildDebugOverlayBuffer(glyphDebugRects: glyphDebugRects)
        lastPixelProbeDiagnostics = pixelProbes

        var uniforms = TerminalUniforms(
            viewport: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            useLinearGlyphSampling: diagnosticLinearGlyphSamplingEnabled ? 1 : 0
        )
        updateSharedBuffer(&uniformsBuffer, with: &uniforms)
        lastAtlasBufferSignature = makeAtlasBufferSignature(for: terminalFrame)
    }

    private func atlasBuffersNeedRebuild(for frame: TerminalFrame) -> Bool {
        let nextSignature = makeAtlasBufferSignature(for: frame)
        return nextSignature != lastAtlasBufferSignature
    }

    private func makeAtlasBufferSignature(for frame: TerminalFrame) -> Int {
        var hasher = Hasher()
        hasher.combine(frame.cells.count)
        for cell in frame.cells {
            hasher.combine(cell.character)
            hasher.combine(cell.column)
            hasher.combine(cell.row)
            combineColor(cell.foreground, into: &hasher)
            combineColor(cell.background, into: &hasher)
        }
        hasher.combine(frame.backgrounds.count)
        for background in frame.backgrounds {
            hasher.combine(background.column)
            hasher.combine(background.row)
            combineColor(background.color, into: &hasher)
        }
        hasher.combine(frame.decorations.count)
        for decoration in frame.decorations {
            hasher.combine(decoration.column)
            hasher.combine(decoration.row)
            hasher.combine(decoration.width)
            combineDecorationKind(decoration.kind, into: &hasher)
            combineColor(decoration.color, into: &hasher)
        }
        combineColor(frame.defaultForeground, into: &hasher)
        combineColor(frame.defaultBackground, into: &hasher)
        frame.dirtyRows.forEach { hasher.combine($0) }
        for rect in frame.dirtyRects {
            hasher.combine(rect.x)
            hasher.combine(rect.y)
            hasher.combine(rect.width)
            hasher.combine(rect.height)
        }
        hasher.combine(frame.isFullDamage)
        hasher.combine(frame.cursorColumn)
        hasher.combine(frame.cursorRow)
        hasher.combine(frame.cursorBlinkOn)
        combineColor(cursorColor, into: &hasher)
        hasher.combine(frame.markedTextColumn)
        hasher.combine(frame.markedText)
        hasher.combine(frame.markedTextSelectedRange.location)
        hasher.combine(frame.markedTextSelectedRange.length)
        hasher.combine(frame.columns)
        hasher.combine(frame.visibleRows)
        hasher.combine(frame.cellSize.width)
        hasher.combine(frame.cellSize.height)
        hasher.combine(frame.padding.x)
        hasher.combine(frame.padding.y)
        hasher.combine(bounds.size.width)
        hasher.combine(bounds.size.height)
        hasher.combine(backingScale)
        hasher.combine(drawableSize.width)
        hasher.combine(drawableSize.height)
        combineFontCellMetrics(fontCellMetrics, into: &hasher)
        hasher.combine(diagnosticPixelSnappingEnabled)
        hasher.combine(diagnosticLinearGlyphSamplingEnabled)
        hasher.combine(diagnosticCellBoundaryOverlayEnabled)
        hasher.combine(diagnosticBaselineOverlayEnabled)
        hasher.combine(diagnosticGlyphQuadOverlayEnabled)
        return hasher.finalize()
    }

    private func combineColor(_ color: SIMD4<Float>, into hasher: inout Hasher) {
        hasher.combine(color.x)
        hasher.combine(color.y)
        hasher.combine(color.z)
        hasher.combine(color.w)
    }

    private func combineDecorationKind(_ kind: TerminalDecoration.Kind, into hasher: inout Hasher) {
        switch kind {
        case .underline:
            hasher.combine(0)
        case .strikethrough:
            hasher.combine(1)
        case let .boxDrawing(left, right, up, down):
            hasher.combine(2)
            hasher.combine(left)
            hasher.combine(right)
            hasher.combine(up)
            hasher.combine(down)
        case let .blockElement(x, y, width, height):
            hasher.combine(3)
            hasher.combine(x)
            hasher.combine(y)
            hasher.combine(width)
            hasher.combine(height)
        }
    }

    private func combineFontCellMetrics(_ metrics: FontCellMetrics, into hasher: inout Hasher) {
        hasher.combine(metrics.fixedCellWidth)
        hasher.combine(metrics.fixedCellHeight)
        hasher.combine(metrics.ascenderPixels)
        hasher.combine(metrics.descenderPixels)
        hasher.combine(metrics.leadingPixels)
        hasher.combine(metrics.baselineOffsetPixels)
        hasher.combine(metrics.underlinePositionPixels)
        hasher.combine(metrics.underlineThicknessPixels)
        hasher.combine(metrics.cursorHeightPixels)
        hasher.combine(metrics.cellWidthPixels)
        hasher.combine(metrics.cellHeightPixels)
    }

    private func appendGlyphInstance(
        character: Character,
        column: Int,
        row: Int,
        into instances: inout [GlyphInstance],
        debugRects: inout [CGRect],
        pixelProbes: inout [TerminalPixelProbe],
        color: SIMD4<Float> = SIMD4<Float>(0.92, 0.92, 0.92, 1)
    ) {
        guard row >= 0, row < terminalFrame.visibleRows else { return }
        let entry = glyphEntry(for: character)
        let cellOrigin = physicalPixelCellOrigin(column: column, row: row)
        let pixelSize = entry.pixelSize
        let glyphRect = CGRect(
            x: CGFloat(cellOrigin.x + entry.bearingXPixels),
            y: CGFloat(canonicalBaselinePixelY(forRow: row) - entry.bearingYPixels),
            width: CGFloat(pixelSize.width),
            height: CGFloat(pixelSize.height)
        )
        let cellRect = CGRect(
            x: CGFloat(cellOrigin.x),
            y: CGFloat(cellOrigin.y),
            width: CGFloat(entry.cellWidthPixels),
            height: CGFloat(entry.cellHeightPixels)
        )
        let dirtyRect = diagnosticDirtyRectPixels(for: cellRect.union(glyphRect))
        pixelProbes.append(TerminalPixelProbe.make(
            cellRect: cellRect,
            glyphRect: glyphRect,
            dirtyRect: dirtyRect,
            scissorRect: DebugOptions.noScissor ? nil : dirtyRect,
            backingScale: backingScale
        ))
        if diagnosticGlyphQuadOverlayEnabled {
            let origin = physicalPixelsToPoints(CGPoint(
                x: CGFloat(cellOrigin.x + entry.bearingXPixels),
                y: CGFloat(canonicalBaselinePixelY(forRow: row) - entry.bearingYPixels)
            ))
            debugRects.append(CGRect(origin: origin, size: CGSize(width: CGFloat(entry.drawSize.x), height: CGFloat(entry.drawSize.y))))
        }
        instances.append(GlyphInstance(
            origin: SIMD2<Float>(Float(cellOrigin.x + entry.bearingXPixels), Float(canonicalBaselinePixelY(forRow: row) - entry.bearingYPixels)),
            size: SIMD2<Float>(Float(pixelSize.width), Float(pixelSize.height)),
            uvOrigin: entry.uvOrigin,
            uvSize: entry.uvSize,
            color: color
        ))
    }

    private func diagnosticDirtyRectPixels(for probeRect: CGRect) -> CGRect? {
        let dirtyRects = terminalFrame.dirtyRects.map { physicalPixelRect($0.cgRect) }
        if terminalFrame.isFullDamage || dirtyRects.isEmpty {
            return physicalPixelRect(bounds)
        }
        return dirtyRects.first { $0.intersects(probeRect) }
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
        let pointRect = CGRect(
            x: terminalFrame.padding.cgX + CGFloat(column) * terminalFrame.cellSize.cgWidth,
            y: bounds.height - terminalFrame.padding.cgY - terminalFrame.cellSize.cgHeight * CGFloat(row + 1) + yOffset,
            width: overrideWidth ?? terminalFrame.cellSize.cgWidth * CGFloat(max(1, width)),
            height: height
        )
        let rect = physicalPixelRect(pointRect)
        return GlyphInstance(
            origin: SIMD2<Float>(Float(rect.origin.x), Float(rect.origin.y)),
            size: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            uvOrigin: .zero,
            uvSize: .zero,
            color: color
        )
    }

    private func blockElementInstance(
        column: Int,
        row: Int,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        color: SIMD4<Float>
    ) -> GlyphInstance {
        let cellX = terminalFrame.padding.cgX + CGFloat(column) * terminalFrame.cellSize.cgWidth
        let cellY = bounds.height - terminalFrame.padding.cgY - terminalFrame.cellSize.cgHeight * CGFloat(row + 1)
        return solidInstance(rect: CGRect(
            x: cellX + terminalFrame.cellSize.cgWidth * CGFloat(x),
            y: cellY + terminalFrame.cellSize.cgHeight * CGFloat(y),
            width: terminalFrame.cellSize.cgWidth * CGFloat(width),
            height: terminalFrame.cellSize.cgHeight * CGFloat(height)
        ), color: color)
    }

    private func rebuildDebugOverlayBuffer(glyphDebugRects: [CGRect]) {
        guard self.device != nil else { return }
        var overlays: [GlyphInstance] = []
        let onePixel = physicalPixelsToPoints(1)
        if diagnosticCellBoundaryOverlayEnabled {
            let color = SIMD4<Float>(0.18, 0.55, 1, 0.55)
            for row in 0...terminalFrame.visibleRows {
                overlays.append(debugSolidInstance(
                    rect: CGRect(
                        x: terminalFrame.padding.cgX,
                        y: bounds.height - terminalFrame.padding.cgY - terminalFrame.cellSize.cgHeight * CGFloat(row),
                        width: terminalFrame.cellSize.cgWidth * CGFloat(max(1, terminalFrame.columns)),
                        height: onePixel
                    ),
                    color: color
                ))
            }
            for column in 0...terminalFrame.columns {
                overlays.append(debugSolidInstance(
                    rect: CGRect(
                        x: terminalFrame.padding.cgX + terminalFrame.cellSize.cgWidth * CGFloat(column),
                        y: bounds.height - terminalFrame.padding.cgY - terminalFrame.cellSize.cgHeight * CGFloat(max(1, terminalFrame.visibleRows)),
                        width: onePixel,
                        height: terminalFrame.cellSize.cgHeight * CGFloat(max(1, terminalFrame.visibleRows))
                    ),
                    color: color
                ))
            }
        }
        if diagnosticBaselineOverlayEnabled {
            let color = SIMD4<Float>(1, 0.55, 0.1, 0.75)
            let baselineOffset = physicalPixelsToPoints(CGFloat(fontCellMetrics.baselineOffsetPixels))
            for row in 0..<terminalFrame.visibleRows {
                overlays.append(debugSolidInstance(
                    rect: CGRect(
                        x: terminalFrame.padding.cgX,
                        y: bounds.height - terminalFrame.padding.cgY - terminalFrame.cellSize.cgHeight * CGFloat(row + 1) + baselineOffset,
                        width: terminalFrame.cellSize.cgWidth * CGFloat(max(1, terminalFrame.columns)),
                        height: onePixel
                    ),
                    color: color
                ))
            }
        }
        if diagnosticGlyphQuadOverlayEnabled {
            let color = SIMD4<Float>(1, 0.1, 0.65, 0.75)
            for rect in glyphDebugRects {
                overlays.append(debugSolidInstance(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: onePixel), color: color))
                overlays.append(debugSolidInstance(rect: CGRect(x: rect.minX, y: rect.maxY - onePixel, width: rect.width, height: onePixel), color: color))
                overlays.append(debugSolidInstance(rect: CGRect(x: rect.minX, y: rect.minY, width: onePixel, height: rect.height), color: color))
                overlays.append(debugSolidInstance(rect: CGRect(x: rect.maxX - onePixel, y: rect.minY, width: onePixel, height: rect.height), color: color))
            }
        }
        updateSharedBuffer(&debugOverlayInstanceBuffer, with: overlays)
    }

    private func debugSolidInstance(rect pointRect: CGRect, color: SIMD4<Float>) -> GlyphInstance {
        let rect = physicalPixelRect(pointRect)
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

    private func inputCursorRect(row: Int) -> CGRect {
        CGRect(
            x: terminalFrame.padding.cgX + CGFloat(max(0, terminalFrame.cursorColumn)) * terminalFrame.cellSize.cgWidth,
            y: bounds.height - terminalFrame.padding.cgY - terminalFrame.cellSize.cgHeight * CGFloat(row + 1),
            width: physicalPixelsToPoints(CGFloat(AppConstants.Terminal.cursorWidthPX)),
            height: terminalFrame.cellSize.cgHeight
        )
    }

    private func appendBoxDrawingDecorationInstances(
        column: Int,
        row: Int,
        left: Bool,
        right: Bool,
        up: Bool,
        down: Bool,
        color: SIMD4<Float>,
        to instances: inout [GlyphInstance]
    ) {
        let lineThickness = physicalPixelsToPoints(CGFloat(fontCellMetrics.underlineThicknessPixels))
        let cellX = terminalFrame.padding.cgX + CGFloat(column) * terminalFrame.cellSize.cgWidth
        let cellY = bounds.height - terminalFrame.padding.cgY - terminalFrame.cellSize.cgHeight * CGFloat(row + 1)
        let centerX = pixelAlign(cellX + (terminalFrame.cellSize.cgWidth - lineThickness) * 0.5, scale: backingScale)
        let centerY = pixelAlign(cellY + (terminalFrame.cellSize.cgHeight - lineThickness) * 0.5, scale: backingScale)
        if left {
            instances.append(solidInstance(rect: CGRect(
                x: cellX,
                y: centerY,
                width: centerX - cellX + lineThickness,
                height: lineThickness
            ), color: color))
        }
        if right {
            let cellMaxX = cellX + terminalFrame.cellSize.cgWidth
            instances.append(solidInstance(rect: CGRect(
                x: centerX,
                y: centerY,
                width: cellMaxX - centerX,
                height: lineThickness
            ), color: color))
        }
        if up {
            let cellMaxY = cellY + terminalFrame.cellSize.cgHeight
            instances.append(solidInstance(rect: CGRect(
                x: centerX,
                y: centerY,
                width: lineThickness,
                height: cellMaxY - centerY
            ), color: color))
        }
        if down {
            instances.append(solidInstance(rect: CGRect(
                x: centerX,
                y: cellY,
                width: lineThickness,
                height: centerY - cellY + lineThickness
            ), color: color))
        }
    }

    private func solidInstance(rect pointRect: CGRect, color: SIMD4<Float>) -> GlyphInstance {
        let rect = physicalPixelRect(pointRect)
        return GlyphInstance(
            origin: SIMD2<Float>(Float(rect.origin.x), Float(rect.origin.y)),
            size: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            uvOrigin: .zero,
            uvSize: .zero,
            color: color
        )
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
            return GlyphAtlasEntry.empty(metrics: fontCellMetrics)
        }

        let rasterized = rasterizeGlyph(character, x: x, y: y)
        let drawWidthPixels = rasterized.pixelSize.width
        let drawHeightPixels = rasterized.pixelSize.height
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
            drawSize: rasterized.drawSize,
            pixelSize: rasterized.pixelSize,
            bearingXPixels: rasterized.bearingXPixels,
            bearingYPixels: rasterized.bearingYPixels,
            advancePixels: rasterized.advancePixels,
            cellWidthPixels: rasterized.cellWidthPixels,
            cellHeightPixels: rasterized.cellHeightPixels,
            baselineOffsetPixels: rasterized.baselineOffsetPixels
        )
        glyphs[key] = entry
        return entry
    }

    private func rasterizeGlyph(_ character: Character, x: Int, y: Int) -> RasterizedGlyph {
        var slotMask = [UInt8](repeating: 0, count: glyphSlotWidth * glyphSlotHeight)
        let columnWidth = max(1, character.terminalColumnWidth)
        let logicalAdvanceWidth = terminalFrame.cellSize.cgWidth * CGFloat(columnWidth)
        let logicalHeight = terminalFrame.cellSize.cgHeight
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
            return RasterizedGlyph.empty(metrics: fontCellMetrics)
        }

        let canonicalMetrics = fontCellMetrics
        let bitmapMinXPixels = floor(imageBounds.minX) - CGFloat(paddingPixels)
        let bitmapMaxXPixels = ceil(imageBounds.maxX) + CGFloat(paddingPixels)
        let pixelWidth = min(glyphSlotWidth, max(1, Int(bitmapMaxXPixels - bitmapMinXPixels)))
        let pixelHeight = min(glyphSlotHeight, max(1, Int(ceil(imageBounds.height)) + paddingPixels * 2))
        let desiredInkLeft: CGFloat = 0
        // CoreText metrics are fractional pixels after scaling. Snap the atlas draw origin so
        // bitmap rasterization and the later Metal quad share one canonical row baseline.
        let unsnappedBaselineY = CGFloat(glyphSlotHeight) - CGFloat(paddingPixels) - imageBounds.maxY
        let baselineX = round(-bitmapMinXPixels)
        let baselineY = round(unsnappedBaselineY)
        let baselineDeltaX = (baselineX + bitmapMinXPixels) / scale
        let glyphCanvasBaselineY = canonicalMetrics.baselineOffsetPixels
        let bitmapBottomPixels = glyphSlotHeight - pixelHeight
        let bearingXPixels = Int(round(desiredInkLeft * scale - baselineX))
        let bearingYPixels = max(0, Int(round(baselineY - CGFloat(bitmapBottomPixels))))
        let result = RasterizedGlyph(
            drawOffset: SIMD2<Float>(
                Float(desiredInkLeft + baselineDeltaX - CGFloat(paddingPixels) / scale),
                Float((CGFloat(glyphCanvasBaselineY - bearingYPixels)) / scale)
            ),
            drawSize: SIMD2<Float>(Float(CGFloat(pixelWidth) / scale), Float(CGFloat(pixelHeight) / scale)),
            pixelSize: PixelSize(width: pixelWidth, height: pixelHeight),
            bearingXPixels: bearingXPixels,
            bearingYPixels: bearingYPixels,
            advancePixels: canonicalMetrics.cellWidthPixels * columnWidth,
            cellWidthPixels: canonicalMetrics.cellWidthPixels * columnWidth,
            cellHeightPixels: canonicalMetrics.cellHeightPixels,
            baselineOffsetPixels: canonicalMetrics.baselineOffsetPixels
        )
        guard let context = CGContext(
            data: &slotMask,
            width: glyphSlotWidth,
            height: glyphSlotHeight,
            bitsPerComponent: 8,
            bytesPerRow: glyphSlotWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return result
        }
        // Keep the atlas as an alpha mask. Using an RGBA CoreGraphics target can
        // leak fallback-font color/background pixels around Hangul glyphs.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: glyphSlotWidth, height: glyphSlotHeight))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.interpolationQuality = .high
        context.textMatrix = .identity
        context.setFillColor(CGColor(gray: 1, alpha: 1))

        let availableWidth = max(1, logicalAdvanceWidth * scale)
        let horizontalScale = min(1, availableWidth / typographicWidth)
        context.saveGState()
        context.translateBy(x: baselineX, y: baselineY)
        context.scaleBy(x: horizontalScale, y: 1)
        // Fill glyph outlines into the alpha mask. CTLineDraw can introduce
        // fallback-font backing pixels for Hangul IME text; glyph paths keep the
        // atlas transparent outside actual ink.
        if !drawGlyphPaths(from: line, in: context) {
            context.textPosition = .zero
            CTLineDraw(line, context)
        }
        context.restoreGState()

        for row in 0..<glyphSlotHeight {
            let src = row * glyphSlotWidth
            let dst = ((y + row) * atlasSize + x) * 4
            for column in 0..<glyphSlotWidth {
                let alpha = slotMask[src + column]
                let pixel = dst + column * 4
                atlasPixels[pixel] = 255
                atlasPixels[pixel + 1] = 255
                atlasPixels[pixel + 2] = 255
                atlasPixels[pixel + 3] = alpha
            }
        }
        return result
    }

    private func drawGlyphPaths(from line: CTLine, in context: CGContext) -> Bool {
        let runs = CTLineGetGlyphRuns(line) as NSArray
        var drewAnyPath = false
        for runValue in runs {
            guard CFGetTypeID(runValue as CFTypeRef) == CTRunGetTypeID() else {
                return false
            }
            let run = unsafeDowncast(runValue as AnyObject, to: CTRun.self)
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let fontValue = attributes[kCTFontAttributeName as String] else {
                return false
            }
            guard CFGetTypeID(fontValue as CFTypeRef) == CTFontGetTypeID() else {
                return false
            }
            let runFont = unsafeDowncast(fontValue as AnyObject, to: CTFont.self)
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<glyphCount {
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else {
                    return false
                }
                context.saveGState()
                context.translateBy(x: positions[index].x, y: positions[index].y)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()
                drewAnyPath = true
            }
        }
        return drewAnyPath
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

    @discardableResult
    private func resetAtlasIfBackingScaleChanged() -> Bool {
        let scale = backingScale
        guard atlasBackingScale != scale else { return false }
        atlasBackingScale = scale
        resetAtlas()
        return true
    }

    private func resetAtlas() {
        glyphs.removeAll(keepingCapacity: true)
        atlasSlot = 0
        atlasPixels = [UInt8](repeating: 0, count: atlasSize * atlasSize * 4)
        uploadAtlas()
    }

    private func synchronizeBackingScaleAndDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard !isSynchronizingDisplay else { return }
        isSynchronizingDisplay = true
        defer { isSynchronizingDisplay = false }
        let scale = backingScale
        let scaledDrawableSize = CGSize(
            width: max(1, ceil(bounds.width * scale)),
            height: max(1, ceil(bounds.height * scale))
        )
        layer?.contentsScale = scale
        let previousDrawableSize = drawableSize
        if drawableSize != scaledDrawableSize {
            drawableSize = scaledDrawableSize
        }
        let atlasInvalidated = resetAtlasIfBackingScaleChanged()
        let drawableChanged = previousDrawableSize != scaledDrawableSize
        guard atlasInvalidated || drawableChanged else { return }

        // Display transfers can change both AppKit point scale and Metal drawable
        // pixels. Rebuild dependent buffers immediately so the next frame cannot use
        // a Retina atlas or viewport on a 1x external monitor.
        rebuildFontCellMetrics()
        rebuildVertexBuffer()
        rebuildAtlasBuffers()
        if diagnosticCPUFallbackEnabled {
            rebuildTextTexture()
        }
        logDisplaySynchronization(
            scale: scale,
            drawableChanged: drawableChanged,
            atlasInvalidated: atlasInvalidated
        )
        setNeedsDisplay(bounds)
    }

    private func observeWindowScreenChanges() {
        removeWindowScreenObserver()
        guard let window else { return }
        windowScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.synchronizeBackingScaleAndDrawableSize()
            }
        }
    }

    private func removeWindowScreenObserver() {
        guard let windowScreenObserver else { return }
        NotificationCenter.default.removeObserver(windowScreenObserver)
        self.windowScreenObserver = nil
    }

    private func logDisplaySynchronization(scale: CGFloat, drawableChanged: Bool, atlasInvalidated: Bool) {
        guard diagnosticRenderingLogEnabled || drawableChanged || atlasInvalidated else { return }
        NSLog(
            "Kurotty display sync: screen=%@ scale=%0.2f contentsScale=%0.2f drawable=%@ viewport=%@ bounds=%@ atlasScale=%0.2f atlasPx=%d glyphTexturePixelFormat=%@ drawablePixelFormat=%@ sampler=nearest blend=straight-alpha sourceAlpha/oneMinusSourceAlpha colorSpacePolicy=sRGB values on bgra8Unorm font=%@ fontSize=%0.2f ascentPx=%d descentPx=%d leadingPx=%d fixedCellPt=(%0.2f,%0.2f) fixedCellPx=(%d,%d) baselinePx=%d firstRowBaselinePx=%d cursorHeightPx=%d underlinePx=(%d,%d) projectionRebuild=%@ atlasInvalidate=%@ glyphCacheInvalidate=%@",
            window?.screen?.localizedName ?? "unknown",
            scale,
            layer?.contentsScale ?? 0,
            NSStringFromSize(drawableSize),
            NSStringFromSize(drawableSize),
            NSStringFromRect(bounds),
            atlasScale(forLogicalWidth: max(1, terminalFrame.cellSize.cgWidth), logicalHeight: max(1, terminalFrame.cellSize.cgHeight)),
            atlasSize,
            "\(Self.glyphAtlasPixelFormat)",
            "\(Self.renderTargetPixelFormat)",
            font.fontName,
            font.pointSize,
            fontCellMetrics.ascenderPixels,
            fontCellMetrics.descenderPixels,
            fontCellMetrics.leadingPixels,
            fontCellMetrics.fixedCellWidth,
            fontCellMetrics.fixedCellHeight,
            fontCellMetrics.cellWidthPixels,
            fontCellMetrics.cellHeightPixels,
            fontCellMetrics.baselineOffsetPixels,
            terminalFrame.visibleRows > 0 ? canonicalBaselinePixelY(forRow: 0) : 0,
            fontCellMetrics.cursorHeightPixels,
            fontCellMetrics.underlinePositionPixels,
            fontCellMetrics.underlineThicknessPixels,
            drawableChanged ? "yes" : "no",
            atlasInvalidated ? "yes" : "no",
            atlasInvalidated ? "yes" : "no"
        )
    }

    private func atlasScale(forLogicalWidth logicalWidth: CGFloat, logicalHeight: CGFloat) -> CGFloat {
        let preferredScale = max(1, backingScale * DesignTokens.Component.glyphAtlasOversampleScale)
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

    private func physicalPixelRect(_ pointRect: CGRect) -> CGRect {
        let scale = backingScale
        let pixelRect = pointRect.applying(CGAffineTransform(scaleX: scale, y: scale))
        guard diagnosticPixelSnappingEnabled else { return pixelRect }
        let minX = floor(pixelRect.minX)
        let minY = floor(pixelRect.minY)
        let maxX = ceil(pixelRect.maxX)
        let maxY = ceil(pixelRect.maxY)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func physicalPixelPoint(_ point: CGPoint) -> CGPoint {
        let scale = backingScale
        let pixelPoint = CGPoint(x: point.x * scale, y: point.y * scale)
        guard diagnosticPixelSnappingEnabled else { return pixelPoint }
        return CGPoint(x: round(pixelPoint.x), y: round(pixelPoint.y))
    }

    private func physicalPixelsToPoints(_ pixels: CGFloat) -> CGFloat {
        pixels / max(1, backingScale)
    }

    private func physicalPixelsToPoints(_ point: CGPoint) -> CGPoint {
        let scale = max(1, backingScale)
        return CGPoint(x: point.x / scale, y: point.y / scale)
    }

    private func physicalPixelCellOrigin(column: Int, row: Int) -> PixelPoint {
        let pointOrigin = CGPoint(
            x: terminalFrame.padding.cgX + CGFloat(column) * terminalFrame.cellSize.cgWidth,
            y: bounds.height - terminalFrame.padding.cgY - terminalFrame.cellSize.cgHeight * CGFloat(row + 1)
        )
        let origin = physicalPixelPoint(pointOrigin)
        return PixelPoint(x: Int(origin.x), y: Int(origin.y))
    }

    private func canonicalBaselinePointY(forRow row: Int) -> CGFloat {
        physicalPixelsToPoints(CGFloat(canonicalBaselinePixelY(forRow: row)))
    }

    private func canonicalBaselinePixelY(forRow row: Int) -> Int {
        physicalPixelCellOrigin(column: 0, row: row).y + fontCellMetrics.baselineOffsetPixels
    }

    private func rebuildFontCellMetrics() {
        let input = FontCellMetricsInput(
            fontName: font.fontName,
            pointSize: font.pointSize,
            cellSize: terminalFrame.cellSize,
            backingScale: backingScale
        )
        guard input != lastFontCellMetricsInput else { return }
        lastFontCellMetricsInput = input
        fontCellMetrics = FontCellMetrics(font: font, cellSize: terminalFrame.cellSize.cgSize, scale: backingScale)
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
        if let probe = lastPixelProbeDiagnostics.first(where: { $0.reasonCode != .contained }) ?? lastPixelProbeDiagnostics.first {
            NSLog(
                "Kurotty pixel probe: reason=%@ cellPx=%@ glyphPx=%@ dirtyPx=%@ scissorPx=%@ scale=%0.2f flags=(glyphCell:%@ glyphDirty:%@ glyphScissor:%@ cellDirty:%@ cellScissor:%@ fractional:%@ emptyGlyph:%@)",
                probe.summary,
                NSStringFromRect(probe.cellRect),
                NSStringFromRect(probe.glyphRect),
                probe.dirtyRect.map { NSStringFromRect($0) } ?? "nil",
                probe.scissorRect.map { NSStringFromRect($0) } ?? "nil",
                probe.backingScale,
                probe.clippingFlags.glyphExceedsCellBounds ? "yes" : "no",
                probe.clippingFlags.glyphExceedsDirtyRect ? "yes" : "no",
                probe.clippingFlags.glyphExceedsScissorRect ? "yes" : "no",
                probe.clippingFlags.cellExceedsDirtyRect ? "yes" : "no",
                probe.clippingFlags.cellExceedsScissorRect ? "yes" : "no",
                probe.clippingFlags.fractionalPixelEdges ? "yes" : "no",
                probe.clippingFlags.emptyGlyphRect ? "yes" : "no"
            )
        }
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
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
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

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.glyphAtlasPixelFormat, width: width, height: height, mipmapped: false)
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
            guard !isCellCoveredByMarkedText(cell) else { continue }
            let rect = cellRect(column: cell.column, row: cell.row, width: cell.character.terminalColumnWidth)
            (String(cell.character) as NSString).draw(in: rect, withAttributes: attrs)
        }

        if !terminalFrame.markedText.isEmpty && terminalFrame.cursorRow >= 0 {
            var column = terminalFrame.markedTextColumn
            var utf16Offset = 0
            for character in terminalFrame.markedText {
                let color = markedTextColor(for: character, utf16Offset: utf16Offset)
                let markedAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor(
                        calibratedRed: CGFloat(color.x),
                        green: CGFloat(color.y),
                        blue: CGFloat(color.z),
                        alpha: CGFloat(color.w)
                    ),
                ]
                (String(character) as NSString).draw(in: cellRect(column: column, row: terminalFrame.cursorRow, width: character.terminalColumnWidth), withAttributes: markedAttrs)
                column += character.terminalColumnWidth
                utf16Offset += String(character).utf16.count
            }
        }

        if terminalFrame.cursorBlinkOn, terminalFrame.cursorRow >= 0 {
            NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
            NSRect(
                x: terminalFrame.padding.cgX + CGFloat(max(0, terminalFrame.cursorColumn)) * terminalFrame.cellSize.cgWidth,
                y: bounds.height - terminalFrame.padding.cgY - terminalFrame.cellSize.cgHeight * CGFloat(max(0, terminalFrame.cursorRow) + 1),
                width: physicalPixelsToPoints(CGFloat(AppConstants.Terminal.cursorWidthPX)),
                height: terminalFrame.cellSize.cgHeight
            ).fill()
        }
    }

    private func cellRect(column: Int, row: Int, width: Int) -> NSRect {
        NSRect(
            x: terminalFrame.padding.cgX + CGFloat(column) * terminalFrame.cellSize.cgWidth,
            y: bounds.height - terminalFrame.padding.cgY - terminalFrame.cellSize.cgHeight * CGFloat(row + 1),
            width: terminalFrame.cellSize.cgWidth * CGFloat(max(1, width)),
            height: terminalFrame.cellSize.cgHeight
        )
    }

    private func terminalColumnWidth(of text: String) -> Int {
        text.reduce(0) { width, character in
            width + character.terminalColumnWidth
        }
    }

    private func isCellCoveredByMarkedText(_ cell: TerminalCell) -> Bool {
        guard !terminalFrame.markedText.isEmpty,
              terminalFrame.cursorRow >= 0,
              cell.row == terminalFrame.cursorRow
        else {
            return false
        }

        let markedTextEndColumn = min(
            terminalFrame.columns,
            terminalFrame.markedTextColumn + terminalColumnWidth(of: terminalFrame.markedText)
        )
        let markedTextRange = terminalFrame.markedTextColumn..<markedTextEndColumn
        guard !markedTextRange.isEmpty else { return false }

        let cellEndColumn = min(
            terminalFrame.columns,
            cell.column + max(1, cell.character.terminalColumnWidth)
        )
        let cellRange = cell.column..<cellEndColumn
        return cellRange.overlaps(markedTextRange)
    }

    private func markedTextColor(for character: Character, utf16Offset: Int) -> SIMD4<Float> {
        guard terminalFrame.markedTextSelectedRange.location != TerminalTextSelectionRange.notFound,
              terminalFrame.markedTextSelectedRange.length > 0
        else {
            return terminalFrame.defaultForeground
        }
        let characterRange = NSRange(location: utf16Offset, length: String(character).utf16.count)
        return Self.intersects(characterRange, terminalFrame.markedTextSelectedRange)
            ? TerminalSelectionStyle.foregroundColor
            : terminalFrame.defaultForeground
    }

    private static func intersects(_ lhs: NSRange, _ rhs: TerminalTextSelectionRange) -> Bool {
        let lhsEnd = lhs.location + lhs.length
        let rhsEnd = rhs.location + rhs.length
        return lhs.location < rhsEnd && rhs.location < lhsEnd
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
            descriptor.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
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
            glyphDescriptor.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
            glyphDescriptor.colorAttachments[0].isBlendingEnabled = true
            glyphDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            glyphDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            glyphDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            glyphDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            let solidDescriptor = MTLRenderPipelineDescriptor()
            solidDescriptor.vertexFunction = vertex
            solidDescriptor.fragmentFunction = solidFragment
            solidDescriptor.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
            solidDescriptor.colorAttachments[0].isBlendingEnabled = false

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
    let pixelSize: PixelSize
    let bearingXPixels: Int
    let bearingYPixels: Int
    let advancePixels: Int
    let cellWidthPixels: Int
    let cellHeightPixels: Int
    let baselineOffsetPixels: Int

    static func empty(metrics: FontCellMetrics) -> GlyphAtlasEntry {
        GlyphAtlasEntry(
            uvOrigin: .zero,
            uvSize: .zero,
            drawOffset: .zero,
            drawSize: .zero,
            pixelSize: PixelSize(width: 0, height: 0),
            bearingXPixels: 0,
            bearingYPixels: 0,
            advancePixels: metrics.cellWidthPixels,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels,
            baselineOffsetPixels: metrics.baselineOffsetPixels
        )
    }
}

private struct RasterizedGlyph {
    let drawOffset: SIMD2<Float>
    let drawSize: SIMD2<Float>
    let pixelSize: PixelSize
    let bearingXPixels: Int
    let bearingYPixels: Int
    let advancePixels: Int
    let cellWidthPixels: Int
    let cellHeightPixels: Int
    let baselineOffsetPixels: Int

    static func empty(metrics: FontCellMetrics) -> RasterizedGlyph {
        RasterizedGlyph(
            drawOffset: .zero,
            drawSize: .zero,
            pixelSize: PixelSize(width: 0, height: 0),
            bearingXPixels: 0,
            bearingYPixels: 0,
            advancePixels: metrics.cellWidthPixels,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels,
            baselineOffsetPixels: metrics.baselineOffsetPixels
        )
    }
}

private struct PixelSize {
    let width: Int
    let height: Int
}

private struct PixelPoint {
    let x: Int
    let y: Int
}

private struct FontCellMetricsInput: Equatable {
    let fontName: String
    let pointSize: CGFloat
    let cellSize: TerminalFrameSize
    let backingScale: CGFloat
}

private struct FontCellMetrics {
    let fixedCellWidth: CGFloat
    let fixedCellHeight: CGFloat
    let ascenderPixels: Int
    let descenderPixels: Int
    let leadingPixels: Int
    let baselineOffsetPixels: Int
    let underlinePositionPixels: Int
    let underlineThicknessPixels: Int
    let cursorHeightPixels: Int
    let cellWidthPixels: Int
    let cellHeightPixels: Int

    static let empty = FontCellMetrics(
        fixedCellWidth: 0,
        fixedCellHeight: 0,
        ascenderPixels: 0,
        descenderPixels: 0,
        leadingPixels: 0,
        baselineOffsetPixels: 0,
        underlinePositionPixels: 0,
        underlineThicknessPixels: 1,
        cursorHeightPixels: 1,
        cellWidthPixels: 1,
        cellHeightPixels: 1
    )

    init(
        fixedCellWidth: CGFloat,
        fixedCellHeight: CGFloat,
        ascenderPixels: Int,
        descenderPixels: Int,
        leadingPixels: Int,
        baselineOffsetPixels: Int,
        underlinePositionPixels: Int,
        underlineThicknessPixels: Int,
        cursorHeightPixels: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int
    ) {
        self.fixedCellWidth = fixedCellWidth
        self.fixedCellHeight = fixedCellHeight
        self.ascenderPixels = ascenderPixels
        self.descenderPixels = descenderPixels
        self.leadingPixels = leadingPixels
        self.baselineOffsetPixels = baselineOffsetPixels
        self.underlinePositionPixels = underlinePositionPixels
        self.underlineThicknessPixels = underlineThicknessPixels
        self.cursorHeightPixels = cursorHeightPixels
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
    }

    init(font: NSFont, cellSize: CGSize, scale: CGFloat) {
        let safeScale = max(1, scale)
        let widthPixels = max(1, Int(round(cellSize.width * safeScale)))
        let heightPixels = max(1, Int(round(cellSize.height * safeScale)))
        let descenderPixels = max(0, Int(round(abs(font.descender) * safeScale)))
        let underlineThicknessPixels = max(1, Int(round(font.underlineThickness * safeScale)))
        let underlinePositionPixels = max(
            0,
            min(
                heightPixels - underlineThicknessPixels,
                Int(round((abs(font.descender) + font.underlinePosition) * safeScale))
            )
        )
        self.init(
            fixedCellWidth: cellSize.width,
            fixedCellHeight: cellSize.height,
            ascenderPixels: Int(round(font.ascender * safeScale)),
            descenderPixels: descenderPixels,
            leadingPixels: Int(round(font.leading * safeScale)),
            baselineOffsetPixels: descenderPixels,
            underlinePositionPixels: underlinePositionPixels,
            underlineThicknessPixels: underlineThicknessPixels,
            cursorHeightPixels: heightPixels,
            cellWidthPixels: widthPixels,
            cellHeightPixels: heightPixels
        )
    }
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
    float4 sample = in.useLinearGlyphSampling != 0
        ? glyph_atlas.sample(linear_glyph_sampler, in.uv)
        : glyph_atlas.sample(nearest_glyph_sampler, in.uv);
    return float4(in.color.rgb, sample.a * in.color.a);
}

fragment float4 terminal_solid_fragment(GlyphVertexOut in [[stage_in]]) {
    return in.color;
}
"""
