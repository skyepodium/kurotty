import Foundation

struct TerminalCommandSpan: Equatable, Identifiable {
    let id: Int
    let cwd: String?
    let startBoundarySequence: Int
    var endBoundarySequence: Int?
    var exitCode: Int?
    var promptBoundarySequence: Int?
    var outputBoundarySequence: Int?
    var commandText: String?
}

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
    private(set) var activeCommandSpan: TerminalCommandSpan?
    private(set) var recentCommandSpans: [TerminalCommandSpan]
    private(set) var boundarySequence: Int
    private var lastPromptBoundarySequence: Int?
    private var nextCommandSpanID: Int
    private var recentCommandSpanLimit: Int

    init(
        currentWorkingDirectoryCandidate: String? = nil,
        currentBoundary: Boundary? = nil,
        isCommandActive: Bool = false,
        lastExitCode: Int? = nil,
        activeCommandSpan: TerminalCommandSpan? = nil,
        recentCommandSpans: [TerminalCommandSpan] = [],
        boundarySequence: Int = 0,
        lastPromptBoundarySequence: Int? = nil,
        nextCommandSpanID: Int = 1,
        recentCommandSpanLimit: Int = 100
    ) {
        self.currentWorkingDirectoryCandidate = currentWorkingDirectoryCandidate
        self.currentBoundary = currentBoundary
        self.isCommandActive = isCommandActive
        self.lastExitCode = lastExitCode
        self.activeCommandSpan = activeCommandSpan
        self.recentCommandSpans = Array(recentCommandSpans.suffix(max(0, recentCommandSpanLimit)))
        self.boundarySequence = boundarySequence
        self.lastPromptBoundarySequence = lastPromptBoundarySequence
        self.nextCommandSpanID = nextCommandSpanID
        self.recentCommandSpanLimit = max(0, recentCommandSpanLimit)
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

    mutating func setActiveCommandText(_ commandText: String?) {
        activeCommandSpan?.commandText = commandText
    }

    func searchRecentCommandSpans(
        cwd: String? = nil,
        exitCode: Int? = nil,
        text: String? = nil
    ) -> [TerminalCommandSpan] {
        recentCommandHistoryNavigator().search(cwd: cwd, exitCode: exitCode, text: text)
    }

    func recentCommandHistoryNavigator() -> TerminalCommandHistoryNavigator {
        TerminalCommandHistoryNavigator(spans: recentCommandSpans)
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
            boundarySequence += 1
            currentBoundary = .promptStart
            isCommandActive = false
            activeCommandSpan = nil
            lastPromptBoundarySequence = boundarySequence
            return .promptStart
        case "B":
            boundarySequence += 1
            currentBoundary = .commandStart
            isCommandActive = true
            activeCommandSpan = TerminalCommandSpan(
                id: nextCommandSpanID,
                cwd: currentWorkingDirectoryCandidate,
                startBoundarySequence: boundarySequence,
                promptBoundarySequence: lastPromptBoundarySequence
            )
            nextCommandSpanID += 1
            return .commandStart
        case "C":
            boundarySequence += 1
            currentBoundary = .outputStart
            activeCommandSpan?.outputBoundarySequence = boundarySequence
            return .outputStart
        case "D":
            boundarySequence += 1
            let exitCode = parts.dropFirst().lazy.compactMap { Int($0) }.first
            currentBoundary = .commandEnd
            isCommandActive = false
            lastExitCode = exitCode
            activeCommandSpan?.endBoundarySequence = boundarySequence
            activeCommandSpan?.exitCode = exitCode
            if let completedSpan = activeCommandSpan {
                appendRecentCommandSpan(completedSpan)
            }
            activeCommandSpan = nil
            return .commandEnd(exitCode: exitCode)
        default:
            return nil
        }
    }

    private mutating func appendRecentCommandSpan(_ span: TerminalCommandSpan) {
        guard recentCommandSpanLimit > 0 else {
            recentCommandSpans.removeAll()
            return
        }

        recentCommandSpans.append(span)
        let overflow = recentCommandSpans.count - recentCommandSpanLimit
        if overflow > 0 {
            recentCommandSpans.removeFirst(overflow)
        }
    }
}
