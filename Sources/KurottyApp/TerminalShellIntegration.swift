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

struct TerminalCommandOutputRange: Equatable {
    let startBoundarySequence: Int
    let endBoundarySequence: Int
}

struct TerminalCommandFoldCandidate: Equatable {
    let spanID: TerminalCommandSpan.ID
    let outputRange: TerminalCommandOutputRange
}

struct TerminalCommandReplayCandidate: Equatable {
    let spanID: TerminalCommandSpan.ID
    let commandText: String
    let cwd: String?
    let exitCode: Int?
    let requiresExplicitUserConfirmation: Bool
}

struct TerminalCommandSearchMetadata: Equatable {
    let spanID: TerminalCommandSpan.ID
    let cwd: String?
    let exitCode: Int?
    let commandText: String?
    let startBoundarySequence: Int
    let endBoundarySequence: Int?
    let outputRange: TerminalCommandOutputRange?
    let isFoldable: Bool
    let isReplayable: Bool
}

struct TerminalShellIntegrationCapabilityDescriptor: Equatable {
    enum PassiveOSCSequence: Equatable {
        case osc7
        case osc133
    }

    enum Shell: Equatable {
        case bash
        case zsh
        case fish
    }

    enum OptInCapability: Equatable {
        case workingDirectoryTracking
        case commandBoundaryTracking
    }

    enum InstallationMode: Equatable {
        case manualSnippet
    }

    struct OptInSnippetDescriptor: Equatable {
        let shell: Shell
        let installationMode: InstallationMode
        let capabilities: [OptInCapability]
        let snippet: String
        let isEnabledByDefault: Bool
        let requiresInstaller: Bool
    }

    let passiveOSCSequences: [PassiveOSCSequence]
    let optInSnippetDescriptors: [OptInSnippetDescriptor]
    let requiresShellScriptInstallation: Bool
}

extension TerminalCommandSpan {
    var outputRange: TerminalCommandOutputRange? {
        guard let outputBoundarySequence,
              let endBoundarySequence,
              outputBoundarySequence < endBoundarySequence
        else {
            return nil
        }

        return TerminalCommandOutputRange(
            startBoundarySequence: outputBoundarySequence,
            endBoundarySequence: endBoundarySequence
        )
    }

    var foldCandidate: TerminalCommandFoldCandidate? {
        guard let outputRange else {
            return nil
        }

        return TerminalCommandFoldCandidate(spanID: id, outputRange: outputRange)
    }

    var replayCandidate: TerminalCommandReplayCandidate? {
        guard let commandText = commandText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !commandText.isEmpty,
              endBoundarySequence != nil
        else {
            return nil
        }

        return TerminalCommandReplayCandidate(
            spanID: id,
            commandText: commandText,
            cwd: cwd,
            exitCode: exitCode,
            requiresExplicitUserConfirmation: true
        )
    }

    var searchMetadata: TerminalCommandSearchMetadata {
        let outputRange = outputRange
        return TerminalCommandSearchMetadata(
            spanID: id,
            cwd: cwd,
            exitCode: exitCode,
            commandText: commandText,
            startBoundarySequence: startBoundarySequence,
            endBoundarySequence: endBoundarySequence,
            outputRange: outputRange,
            isFoldable: outputRange != nil,
            isReplayable: replayCandidate != nil
        )
    }
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

    var capabilityDescriptor: TerminalShellIntegrationCapabilityDescriptor {
        TerminalShellIntegrationCapabilityDescriptor(
            passiveOSCSequences: [.osc7, .osc133],
            optInSnippetDescriptors: Self.optInSnippetDescriptors,
            requiresShellScriptInstallation: false
        )
    }

    private static let workingDirectorySnippetCapabilities: [TerminalShellIntegrationCapabilityDescriptor.OptInCapability] = [
        .workingDirectoryTracking,
    ]

    private static let commandBoundarySnippetCapabilities: [TerminalShellIntegrationCapabilityDescriptor.OptInCapability] = [
        .workingDirectoryTracking,
        .commandBoundaryTracking,
    ]

    private static let optInSnippetDescriptors: [TerminalShellIntegrationCapabilityDescriptor.OptInSnippetDescriptor] = [
        TerminalShellIntegrationCapabilityDescriptor.OptInSnippetDescriptor(
            shell: .bash,
            installationMode: .manualSnippet,
            capabilities: workingDirectorySnippetCapabilities,
            snippet: """
            __kurotty_urlencoded_pwd() {
              local path="${PWD//%/%25}"
              path="${path// /%20}"
              path="${path//\\#/%23}"
              path="${path//\\?/%3F}"
              printf '%s' "$path"
            }
            __kurotty_osc7() { printf '\\033]7;file://localhost%s\\007' "$(__kurotty_urlencoded_pwd)"; }
            PROMPT_COMMAND="__kurotty_osc7${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
            """,
            isEnabledByDefault: false,
            requiresInstaller: false
        ),
        TerminalShellIntegrationCapabilityDescriptor.OptInSnippetDescriptor(
            shell: .zsh,
            installationMode: .manualSnippet,
            capabilities: commandBoundarySnippetCapabilities,
            snippet: """
            __kurotty_urlencoded_pwd() {
              local path="${PWD//%/%25}"
              path="${path// /%20}"
              path="${path//\\#/%23}"
              path="${path//\\?/%3F}"
              printf '%s' "$path"
            }
            __kurotty_osc133() { printf '\\033]133;%s\\007' "$1"; }
            __kurotty_osc7() { printf '\\033]7;file://localhost%s\\007' "$(__kurotty_urlencoded_pwd)"; }
            __kurotty_precmd() { local status_code=$?; __kurotty_osc133 "D;$status_code"; __kurotty_osc7; __kurotty_osc133 A; }
            __kurotty_preexec() { __kurotty_osc133 B; __kurotty_osc133 C; }
            precmd_functions+=(__kurotty_precmd)
            preexec_functions+=(__kurotty_preexec)
            """,
            isEnabledByDefault: false,
            requiresInstaller: false
        ),
        TerminalShellIntegrationCapabilityDescriptor.OptInSnippetDescriptor(
            shell: .fish,
            installationMode: .manualSnippet,
            capabilities: commandBoundarySnippetCapabilities,
            snippet: """
            function __kurotty_urlencoded_pwd
              set -l path (string replace -a '%' '%25' -- $PWD)
              set path (string replace -a ' ' '%20' -- $path)
              set path (string replace -a '#' '%23' -- $path)
              set path (string replace -a '?' '%3F' -- $path)
              printf '%s' $path
            end
            function __kurotty_osc133; printf '\\033]133;%s\\007' $argv[1]; end
            function __kurotty_osc7; printf '\\033]7;file://localhost%s\\007' (__kurotty_urlencoded_pwd); end
            function __kurotty_prompt --on-event fish_prompt; set -l status_code $status; __kurotty_osc133 "D;$status_code"; __kurotty_osc7; __kurotty_osc133 A; end
            function __kurotty_preexec --on-event fish_preexec; __kurotty_osc133 B; __kurotty_osc133 C; end
            """,
            isEnabledByDefault: false,
            requiresInstaller: false
        ),
    ]

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
