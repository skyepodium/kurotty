/// The core's production surface. Parsing is deliberately absent: the Zig core
/// parsed every output chunk into a grid nothing ever read, while
/// `TerminalOutputInterpreter` did the parse that actually renders. Keeping
/// `feed` off this protocol is what stops a second parser reappearing on the
/// output path — the surface view holds an `any TerminalCore` and so cannot
/// call it.
public protocol TerminalCore: AnyObject {
    func recordKeyEvent()
    func recordFramePresented()
    func beginFrame(visibleCells: UInt32) -> UInt32
    func endFrame()
    func lastLatencyMicros() -> UInt64
    func resize(cols: UInt32, rows: UInt32)
    func cell(row: UInt32, col: UInt32) -> UInt8
    func copyRow(_ row: UInt32, into buffer: inout [UInt8]) -> Int
}
