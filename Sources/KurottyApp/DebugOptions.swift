import Foundation

enum DebugOptions {
    static let ptyLog = flag("--debug-pty-log", env: "KUROTTY_DEBUG_PTY_LOG")
    static let screenDump = flag("--debug-screen-dump", env: "KUROTTY_DEBUG_SCREEN_DUMP")
    static let layout = flag("--debug-layout", env: "KUROTTY_DEBUG_LAYOUT")
    static let fullModelRedraw = flag("--debug-full-model-redraw", env: "KUROTTY_DEBUG_FULL_MODEL_REDRAW")
    static let noDamage = flag("--debug-no-damage", env: "KUROTTY_DEBUG_NO_DAMAGE")
    static let noScissor = flag("--debug-no-scissor", env: "KUROTTY_DEBUG_NO_SCISSOR")
    static let vtParser = flag("--debug-vt-parser", env: "KUROTTY_DEBUG_VT_PARSER")
    static let cursorLog = flag("--debug-cursor-log", env: "KUROTTY_DEBUG_CURSOR_LOG")
    static let renderRects = flag("--debug-render-rects", env: "KUROTTY_DEBUG_RENDER_RECTS")
    static let dirtyRects = flag("--debug-dirty-rects", env: "KUROTTY_DEBUG_DIRTY_RECTS")
    static let backgroundRuns = flag("--debug-background-runs", env: "KUROTTY_DEBUG_BACKGROUND_RUNS")
    static let cursorCell = flag("--debug-cursor-cell", env: "KUROTTY_DEBUG_CURSOR_CELL")
    static let scrollRegion = flag("--debug-scroll-region", env: "KUROTTY_DEBUG_SCROLL_REGION")
    static let imeRect = flag("--debug-ime-rect", env: "KUROTTY_DEBUG_IME_RECT")
    static let inputClient = flag("--debug-input-client", env: "KUROTTY_DEBUG_INPUT_CLIENT")
    static let cursorCoordinates = flag("--debug-cursor-coordinates", env: "KUROTTY_DEBUG_CURSOR_COORDINATES")
    static let testNotification = flag("--debug-test-notification", env: "KUROTTY_DEBUG_TEST_NOTIFICATION")
    static let showHistoryPanel = flag("--debug-show-history-panel", env: "KUROTTY_DEBUG_SHOW_HISTORY_PANEL")
    static let seedHistory = flag("--debug-seed-history", env: "KUROTTY_DEBUG_SEED_HISTORY")
    static let showExplorerPanel = flag("--debug-show-explorer-panel", env: "KUROTTY_DEBUG_SHOW_EXPLORER_PANEL")
    static let openEditorFilePath = value("--debug-open-editor-file", env: "KUROTTY_DEBUG_OPEN_EDITOR_FILE")

    private static func value(_ argument: String, env: String) -> String? {
        if let index = CommandLine.arguments.firstIndex(of: argument),
           CommandLine.arguments.indices.contains(index + 1) {
            return CommandLine.arguments[index + 1]
        }
        let value = ProcessInfo.processInfo.environment[env]
        return (value?.isEmpty ?? true) ? nil : value
    }

    private static func flag(_ argument: String, env: String) -> Bool {
        if CommandLine.arguments.contains(argument) {
            return true
        }
        let value = ProcessInfo.processInfo.environment[env]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }
}
