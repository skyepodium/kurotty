import Foundation

protocol TerminalSession: AnyObject {
    var onOutput: ((String) -> Void)? { get set }
    var onRawOutput: ((Data) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }

    func start(workingDirectory requestedWorkingDirectory: String)
    func write(_ text: String)
    func canReceiveTerminalResponseWithoutEcho() -> Bool
    func resize(columns: Int, rows: Int)
    func stop()
}

enum TerminalSessionFactory {
    static func makeDefaultSession() -> any TerminalSession {
        #if os(macOS)
        ShellSession()
        #else
        UnsupportedTerminalSession()
        #endif
    }
}
