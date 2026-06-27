import Foundation

enum DebugOptions {
    static let ptyLog = flag("--debug-pty-log", env: "KUROTTY_DEBUG_PTY_LOG")
    static let screenDump = flag("--debug-screen-dump", env: "KUROTTY_DEBUG_SCREEN_DUMP")
    static let layout = flag("--debug-layout", env: "KUROTTY_DEBUG_LAYOUT")
    static let fullModelRedraw = flag("--debug-full-model-redraw", env: "KUROTTY_DEBUG_FULL_MODEL_REDRAW")
    static let renderRects = flag("--debug-render-rects", env: "KUROTTY_DEBUG_RENDER_RECTS")
    static let imeRect = flag("--debug-ime-rect", env: "KUROTTY_DEBUG_IME_RECT")
    static let inputClient = flag("--debug-input-client", env: "KUROTTY_DEBUG_INPUT_CLIENT")
    static let cursorCoordinates = flag("--debug-cursor-coordinates", env: "KUROTTY_DEBUG_CURSOR_COORDINATES")

    private static func flag(_ argument: String, env: String) -> Bool {
        if CommandLine.arguments.contains(argument) {
            return true
        }
        let value = ProcessInfo.processInfo.environment[env]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }
}
