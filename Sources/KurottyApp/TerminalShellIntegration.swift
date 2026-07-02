import Foundation

struct TerminalShellIntegration: Equatable {
    enum Boundary: Equatable {
        case promptStart
        case commandStart
        case outputStart
        case commandEnd
    }

    enum Event: Equatable {
        case workingDirectoryChanged(String)
        case promptStart
        case commandStart
        case outputStart
        case commandEnd(exitCode: Int?)
    }

    var currentWorkingDirectoryCandidate: String?
    private(set) var currentBoundary: Boundary?
    private(set) var isCommandActive: Bool
    private(set) var lastExitCode: Int?

    init(
        currentWorkingDirectoryCandidate: String? = nil,
        currentBoundary: Boundary? = nil,
        isCommandActive: Bool = false,
        lastExitCode: Int? = nil
    ) {
        self.currentWorkingDirectoryCandidate = currentWorkingDirectoryCandidate
        self.currentBoundary = currentBoundary
        self.isCommandActive = isCommandActive
        self.lastExitCode = lastExitCode
    }

    @discardableResult
    mutating func consumeOsc(_ command: String) -> Event? {
        let parts = command.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }

        switch parts[0] {
        case "7":
            return consumeOsc7(String(parts[1]))
        case "133":
            return consumeOsc133(String(parts[1]))
        default:
            return nil
        }
    }

    private mutating func consumeOsc7(_ payload: String) -> Event? {
        guard let url = URL(string: payload),
              url.isFileURL,
              Self.isLocalFileURLHost(url.host)
        else {
            return nil
        }

        currentWorkingDirectoryCandidate = url.path
        return .workingDirectoryChanged(url.path)
    }

    private static func isLocalFileURLHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else {
            return true
        }
        return host == "localhost"
    }

    private mutating func consumeOsc133(_ payload: String) -> Event? {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard let subcommand = parts.first else {
            return nil
        }

        switch subcommand {
        case "A":
            currentBoundary = .promptStart
            isCommandActive = false
            return .promptStart
        case "B":
            currentBoundary = .commandStart
            isCommandActive = true
            return .commandStart
        case "C":
            currentBoundary = .outputStart
            return .outputStart
        case "D":
            let exitCode = parts.dropFirst().lazy.compactMap { Int($0) }.first
            currentBoundary = .commandEnd
            isCommandActive = false
            lastExitCode = exitCode
            return .commandEnd(exitCode: exitCode)
        default:
            return nil
        }
    }
}
