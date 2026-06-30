import Foundation

private enum UnsupportedTerminalSessionConstants {
    static let message = "Terminal sessions are not supported on this platform.\n"
    static let exitStatus: Int32 = 1
}

final class UnsupportedTerminalSession: TerminalSession {
    var onOutput: ((String) -> Void)?
    var onRawOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    func start(workingDirectory requestedWorkingDirectory: String) {
        onOutput?(UnsupportedTerminalSessionConstants.message)
        onExit?(UnsupportedTerminalSessionConstants.exitStatus)
    }

    func write(_ text: String) {}

    func canReceiveTerminalResponseWithoutEcho() -> Bool {
        false
    }

    func resize(columns: Int, rows: Int) {}

    func stop() {}
}
