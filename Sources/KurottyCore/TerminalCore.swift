public protocol TerminalCore: AnyObject {
    func feed(_ text: String)
    func recordKeyEvent()
    func recordFramePresented()
    func beginFrame(visibleCells: UInt32) -> UInt32
    func endFrame()
    func lastLatencyMicros() -> UInt64
    func resize(cols: UInt32, rows: UInt32)
    func cell(row: UInt32, col: UInt32) -> UInt8
    func copyRow(_ row: UInt32, into buffer: inout [UInt8]) -> Int
}
