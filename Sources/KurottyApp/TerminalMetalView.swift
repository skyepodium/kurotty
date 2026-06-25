import Metal
import MetalKit

final class TerminalMetalView: MTKView, MTKViewDelegate {
    private let core: CoreBridge
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let glyphAtlas = GlyphAtlas()
    private let damageTracker = DamageTracker()

    init(core: CoreBridge) {
        self.core = core
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.pipeline = TerminalMetalView.makePipeline(device: device)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.055, alpha: 1)
        enableSetNeedsDisplay = false
        isPaused = false
        delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        damageTracker.markAll(size: size)
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

        _ = glyphAtlas
        _ = damageTracker.consume()
        _ = core.beginFrame(visibleCells: 120 * 40)
        if let pipeline {
            encoder.setRenderPipelineState(pipeline)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [core] _ in
            core.recordFramePresented()
            core.endFrame()
        }
        commandBuffer.commit()
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
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

final class GlyphAtlas {
    private(set) var pressure: Float = 0
}

final class DamageTracker {
    private var dirty = true

    func markAll(size: CGSize) {
        _ = size
        dirty = true
    }

    func consume() -> Bool {
        defer { dirty = false }
        return dirty
    }
}
