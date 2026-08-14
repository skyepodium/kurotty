import AppKit
import KurottyCore

@MainActor
protocol TerminalAppKitRenderer: TerminalFrameRenderer {
    var rendererView: NSView { get }
    var diagnosticRenderingLogEnabled: Bool { get set }
    var diagnosticFullRedrawEnabled: Bool { get set }
    var diagnosticCellBoundaryOverlayEnabled: Bool { get set }
    var diagnosticBaselineOverlayEnabled: Bool { get set }
    var diagnosticGlyphQuadOverlayEnabled: Bool { get set }
    /// Last frame's damage decision, surfaced through the protocol so the
    /// terminal surface can report it in diagnostics without depending on a
    /// concrete renderer.
    var damageDiagnostics: TerminalRenderDamageDiagnostics { get }

    func applyAppearance(
        font: NSFont,
        backgroundColor: SIMD4<Float>,
        cursorColor: SIMD4<Float>
    )
}

@MainActor
enum TerminalRendererFactory {
    /// Selects the HTML renderer instead of the Metal one.
    ///
    /// An environment variable rather than a settings key while the backend is
    /// being built: a settings key is a user-facing promise that needs a
    /// lifecycle contract and a migration, and this is not ready to make one.
    /// It becomes a setting when the measurements say which backend should be
    /// the default.
    static let htmlRendererVariable = "KUROTTY_HTML_RENDERER"

    static func makeDefaultRenderer(
        font: NSFont,
        backgroundColor: SIMD4<Float>,
        cursorColor: SIMD4<Float>
    ) -> any TerminalAppKitRenderer {
        let useHTML = isHTMLRendererRequested()

        let renderer: any TerminalAppKitRenderer = useHTML
            ? TerminalHTMLView(
                font: font,
                backgroundColor: backgroundColor,
                cursorColor: cursorColor
            )
            : TerminalMetalView(
                font: font,
                backgroundColor: backgroundColor,
                cursorColor: cursorColor
            )

        guard TerminalRenderLatencyProbe.isEnabled() else {
            return renderer
        }

        return TerminalRenderLatencyProbe(
            wrapping: renderer,
            label: useHTML ? "html" : "metal"
        )
    }

    static func isHTMLRendererRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[htmlRendererVariable] else {
            return false
        }
        return raw == "1"
    }
}
