import KurottyCore

enum TerminalCoreFactory {
    static func makeDefaultCore(cols: UInt32, rows: UInt32) -> any TerminalCore {
        CoreBridge(cols: cols, rows: rows)
    }
}
