import AppKit
import KurottyCore

/// Times how long a renderer takes to put a frame on screen.
///
/// A decorator rather than code inside either renderer, so both are measured by
/// the same instrument. Comparing a number Metal computes about itself against a
/// number the HTML renderer computes about itself would be comparing two
/// definitions of "presented" as much as two renderers.
///
/// The interval is from `update(frame:)` to `onPresented`. Both backends report
/// that callback after the frame has actually been composited — Metal from its
/// command buffer's completion handler, the HTML renderer after a double
/// `requestAnimationFrame` — so the same wall clock covers the same span of
/// work.
///
/// Enabled by `KUROTTY_RENDER_LATENCY=1`, which prints a summary every
/// `reportEveryFrameCOUNT` frames. It is a measurement tool and is off by
/// default: an always-on probe would add a timestamp to a path the performance
/// rules ask to keep free of unnecessary work.
@MainActor
final class TerminalRenderLatencyProbe: TerminalAppKitRenderer {
    private enum Metrics {
        /// Frames per printed summary. Small enough to see a change while a TUI
        /// is redrawing, large enough that printing is not itself the workload.
        static let reportEveryFrameCOUNT = 120
        /// Ignored before reporting: the first frames include shell load, atlas
        /// warm-up and, for the web view, the document's first layout. They
        /// describe startup rather than steady state.
        static let warmupFrameCOUNT = 30
        static let microsecondsPerMillisecondRATIO = 1000.0
    }

    static let environmentVariable = "KUROTTY_RENDER_LATENCY"

    private let wrapped: any TerminalAppKitRenderer
    private let label: String
    private var startedAtMicros: UInt64?
    private var samplesMicros: [UInt64] = []
    private var frameCount = 0

    init(wrapping renderer: any TerminalAppKitRenderer, label: String) {
        wrapped = renderer
        self.label = label

        // The probe owns the callback and hands the original one back on, so
        // installing it cannot silently swallow whatever the surface set.
        let forwarded = renderer.onPresented
        wrapped.onPresented = { [weak self] in
            self?.recordPresented()
            forwarded?()
        }

        // Says the probe exists. Without it, a run that produces no report is
        // ambiguous between "the probe is not installed" and "no frames were
        // presented", and those have completely different causes.
        NSLog("render latency [%@] probe installed", label)
    }

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentVariable] == "1"
    }

    // MARK: - Measurement

    private var updateCount = 0

    func update(frame: TerminalFrame) {
        updateCount += 1
        if updateCount == 1 {
            NSLog("render latency [%@] first frame submitted", label)
        }

        // A frame that arrives while one is still in flight replaces the start
        // time rather than nesting: the renderer coalesces, and timing the
        // outer one would report the wait as work.
        startedAtMicros = Self.nowMicros()
        wrapped.update(frame: frame)
    }

    private func recordPresented() {
        guard let started = startedAtMicros else {
            return
        }
        startedAtMicros = nil

        frameCount += 1

        // The first presented frame is worth saying out loud for the same
        // reason as installation: it separates "frames are flowing" from
        // "nothing is being drawn at all".
        if frameCount == 1 {
            NSLog("render latency [%@] first frame presented", label)
        }

        guard frameCount > Metrics.warmupFrameCOUNT else {
            return
        }

        samplesMicros.append(Self.nowMicros() &- started)

        guard samplesMicros.count >= Metrics.reportEveryFrameCOUNT else {
            return
        }

        report()
        samplesMicros.removeAll(keepingCapacity: true)
    }

    private func report() {
        let sorted = samplesMicros.sorted()

        guard let worst = sorted.last, !sorted.isEmpty else {
            return
        }

        let median = sorted[sorted.count / 2]
        let ninetyFifth = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
        let total = sorted.reduce(UInt64(0), &+)

        NSLog(
            "render latency [%@] frames=%d mean=%.2fms p50=%.2fms p95=%.2fms max=%.2fms",
            label,
            sorted.count,
            Double(total) / Double(sorted.count) / Metrics.microsecondsPerMillisecondRATIO,
            Double(median) / Metrics.microsecondsPerMillisecondRATIO,
            Double(ninetyFifth) / Metrics.microsecondsPerMillisecondRATIO,
            Double(worst) / Metrics.microsecondsPerMillisecondRATIO
        )
    }

    private static func nowMicros() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1000
    }

    // MARK: - Forwarding

    var onPresented: (() -> Void)? {
        get { nil }
        set {
            // The surface sets this after construction. Chain rather than
            // replace, or the probe's own timing hook is lost.
            let forwarded = newValue
            wrapped.onPresented = { [weak self] in
                self?.recordPresented()
                forwarded?()
            }
        }
    }

    var rendererView: NSView { wrapped.rendererView }

    var diagnosticRenderingLogEnabled: Bool {
        get { wrapped.diagnosticRenderingLogEnabled }
        set { wrapped.diagnosticRenderingLogEnabled = newValue }
    }

    var diagnosticFullRedrawEnabled: Bool {
        get { wrapped.diagnosticFullRedrawEnabled }
        set { wrapped.diagnosticFullRedrawEnabled = newValue }
    }

    var diagnosticCellBoundaryOverlayEnabled: Bool {
        get { wrapped.diagnosticCellBoundaryOverlayEnabled }
        set { wrapped.diagnosticCellBoundaryOverlayEnabled = newValue }
    }

    var diagnosticBaselineOverlayEnabled: Bool {
        get { wrapped.diagnosticBaselineOverlayEnabled }
        set { wrapped.diagnosticBaselineOverlayEnabled = newValue }
    }

    var diagnosticGlyphQuadOverlayEnabled: Bool {
        get { wrapped.diagnosticGlyphQuadOverlayEnabled }
        set { wrapped.diagnosticGlyphQuadOverlayEnabled = newValue }
    }

    var damageDiagnostics: TerminalRenderDamageDiagnostics { wrapped.damageDiagnostics }

    func applyAppearance(
        font: NSFont,
        backgroundColor: SIMD4<Float>,
        cursorColor: SIMD4<Float>
    ) {
        wrapped.applyAppearance(
            font: font,
            backgroundColor: backgroundColor,
            cursorColor: cursorColor
        )
    }
}
