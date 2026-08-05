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
    static func makeDefaultRenderer(
        font: NSFont,
        backgroundColor: SIMD4<Float>,
        cursorColor: SIMD4<Float>
    ) -> any TerminalAppKitRenderer {
        TerminalMetalView(
            font: font,
            backgroundColor: backgroundColor,
            cursorColor: cursorColor
        )
    }
}
