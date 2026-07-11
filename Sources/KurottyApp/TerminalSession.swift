import Foundation

protocol TerminalSession: AnyObject {
    var onOutput: ((String) -> Void)? { get set }
    var onRawOutput: ((Data) -> Void)? { get set }
    var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }

    func start(workingDirectory requestedWorkingDirectory: String)
    func write(_ text: String)
    func foregroundProcessName() -> String?
    func canReceiveTerminalResponseWithoutEcho() -> Bool
    func resize(columns: Int, rows: Int)
    func stop()
}
