import Foundation

private enum UnsupportedTerminalSessionConstants {
    static let unknownPlatformName = "this platform"
    static let exitStatus: Int32 = 1

    static func message(platformName: String) -> String {
        "Terminal sessions are not supported on \(platformName).\n"
    }
}

final class UnsupportedTerminalSession: TerminalSession {
    var onOutput: ((String) -> Void)?
    var onRawOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let platformName: String

    init(platformName: String = UnsupportedTerminalSessionConstants.unknownPlatformName) {
        self.platformName = platformName
    }

    func start(workingDirectory requestedWorkingDirectory: String) {
        onOutput?(UnsupportedTerminalSessionConstants.message(platformName: platformName))
        onExit?(UnsupportedTerminalSessionConstants.exitStatus)
    }

    func write(_ text: String) {}

    func canReceiveTerminalResponseWithoutEcho() -> Bool {
        false
    }

    func resize(columns: Int, rows: Int) {}

    func stop() {}
}
