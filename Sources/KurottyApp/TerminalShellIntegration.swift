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

struct TerminalCommandSpanReference: Equatable {
    let spanID: TerminalCommandSpan.ID
    let startBoundarySequence: Int
    let endBoundarySequence: Int?
}

struct TerminalCommandOutputRange: Equatable {
    let startBoundarySequence: Int
    let endBoundarySequence: Int
}

struct TerminalCommandFoldCandidate: Equatable {
    let spanID: TerminalCommandSpan.ID
    let reference: TerminalCommandSpanReference
    let outputRange: TerminalCommandOutputRange
}

struct TerminalCommandReplayCandidate: Equatable {
    let spanID: TerminalCommandSpan.ID
    let reference: TerminalCommandSpanReference
    let commandText: String
    let cwd: String?
    let exitCode: Int?
    let requiresExplicitUserConfirmation: Bool
}

struct TerminalCommandSearchMetadata: Equatable {
    let spanID: TerminalCommandSpan.ID
    let reference: TerminalCommandSpanReference
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
    enum PassiveOSCSequence: Equatable, Hashable {
        case osc7
        case osc133
    }

    enum Shell: Equatable {
        case bash
        case zsh
        case fish
    }

    enum OptInCapability: Equatable, Hashable {
        case workingDirectoryTracking
        case commandBoundaryTracking
    }

    enum InstallationMode: Equatable {
        case manualSnippet
    }

    enum OnboardingCommandID: Equatable {
        case showShellIntegrationSnippets
    }

    struct OptInSnippetDescriptor: Equatable {
        let shell: Shell
        let installationMode: InstallationMode
        let capabilities: [OptInCapability]
        let snippet: String
        let isEnabledByDefault: Bool
        let requiresInstaller: Bool
    }

    struct OnboardingStep: Equatable {
        let title: String
        let detail: String
        let commandID: OnboardingCommandID?
        let requiresInstaller: Bool
    }

    let passiveOSCSequences: [PassiveOSCSequence]
    let optInSnippetDescriptors: [OptInSnippetDescriptor]
    let onboardingSteps: [OnboardingStep]
    let requiresShellScriptInstallation: Bool
}

struct TerminalShellIntegrationSessionEvidence: Equatable {
    private(set) var observedPassiveOSCSequences: [TerminalShellIntegrationCapabilityDescriptor.PassiveOSCSequence]
    private(set) var observedOptInCapabilities: [TerminalShellIntegrationCapabilityDescriptor.OptInCapability]
    private(set) var completedCommandSpanReferences: [TerminalCommandSpanReference]

    init(
        observedPassiveOSCSequences: [TerminalShellIntegrationCapabilityDescriptor.PassiveOSCSequence] = [],
        observedOptInCapabilities: [TerminalShellIntegrationCapabilityDescriptor.OptInCapability] = [],
        completedCommandSpanReferences: [TerminalCommandSpanReference] = []
    ) {
        self.observedPassiveOSCSequences = []
        self.observedOptInCapabilities = []
        self.completedCommandSpanReferences = completedCommandSpanReferences
        for sequence in observedPassiveOSCSequences {
            recordObservedPassiveOSCSequence(sequence)
        }
        for capability in observedOptInCapabilities {
            recordObservedOptInCapability(capability)
        }
    }

    mutating func recordObservedPassiveOSCSequence(
        _ sequence: TerminalShellIntegrationCapabilityDescriptor.PassiveOSCSequence
    ) {
        appendIfMissing(sequence, to: &observedPassiveOSCSequences)
    }

    mutating func recordObservedOptInCapability(
        _ capability: TerminalShellIntegrationCapabilityDescriptor.OptInCapability
    ) {
        appendIfMissing(capability, to: &observedOptInCapabilities)
    }

    mutating func replaceCompletedCommandSpanReferences(_ references: [TerminalCommandSpanReference]) {
        completedCommandSpanReferences = references
    }

    private func appendIfMissing<T: Equatable>(_ value: T, to values: inout [T]) {
        if !values.contains(value) {
            values.append(value)
        }
    }
}

struct TerminalShellIntegrationSessionSummary: Equatable {
    struct BaselineSupport: Equatable {
        let supportedPassiveOSCSequences: [TerminalShellIntegrationCapabilityDescriptor.PassiveOSCSequence]
        let observedPassiveOSCSequences: [TerminalShellIntegrationCapabilityDescriptor.PassiveOSCSequence]
    }

    struct OptInIntegration: Equatable {
        let supportedSnippetCapabilities: [TerminalShellIntegrationCapabilityDescriptor.OptInCapability]
        let observedCapabilities: [TerminalShellIntegrationCapabilityDescriptor.OptInCapability]
        let completedCommandSpanReferences: [TerminalCommandSpanReference]
        let installedWorkingDirectorySupportObserved: Bool
        let installedCommandBoundarySupportObserved: Bool
    }

    let baselineSupport: BaselineSupport
    let optInIntegration: OptInIntegration

    var evidenceRows: [TerminalShellIntegrationEvidenceRow] {
        var rows: [TerminalShellIntegrationEvidenceRow] = baselineSupport.observedPassiveOSCSequences.map { sequence in
            TerminalShellIntegrationEvidenceRow(
                source: .passiveOSC,
                label: sequence.evidenceLabel,
                detail: sequence.evidenceDetail,
                exposesRawCommandOutput: false,
                isAvailableToUI: true,
                isAvailableToAudit: true,
                isAvailableToAI: true
            )
        }

        if optInIntegration.installedCommandBoundarySupportObserved {
            rows.append(
                TerminalShellIntegrationEvidenceRow(
                    source: .optInShellIntegration,
                    label: "Command Boundary Tracking",
                    detail: "\(optInIntegration.completedCommandSpanReferences.count) completed command span reference\(optInIntegration.completedCommandSpanReferences.count == 1 ? "" : "s") available",
                    exposesRawCommandOutput: false,
                    isAvailableToUI: true,
                    isAvailableToAudit: true,
                    isAvailableToAI: true
                )
            )
        }

        return rows
    }
}

struct TerminalShellIntegrationEvidenceRow: Equatable {
    enum Source: Equatable {
        case passiveOSC
        case optInShellIntegration
    }

    let source: Source
    let label: String
    let detail: String
    let exposesRawCommandOutput: Bool
    let isAvailableToUI: Bool
    let isAvailableToAudit: Bool
    let isAvailableToAI: Bool
}

private extension TerminalShellIntegrationCapabilityDescriptor.PassiveOSCSequence {
    var evidenceLabel: String {
        switch self {
        case .osc7:
            return "OSC 7"
        case .osc133:
            return "OSC 133"
        }
    }

    var evidenceDetail: String {
        switch self {
        case .osc7:
            return "working directory signal observed"
        case .osc133:
            return "command boundary signal observed"
        }
    }
}

extension TerminalCommandSpan {
    var reference: TerminalCommandSpanReference {
        TerminalCommandSpanReference(
            spanID: id,
            startBoundarySequence: startBoundarySequence,
            endBoundarySequence: endBoundarySequence
        )
    }

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

        return TerminalCommandFoldCandidate(spanID: id, reference: reference, outputRange: outputRange)
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
            reference: reference,
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
            reference: reference,
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
    private(set) var sessionEvidence: TerminalShellIntegrationSessionEvidence
    private(set) var boundarySequence: Int
    private var lastPromptBoundarySequence: Int?
    private var nextCommandSpanID: Int
    private var recentCommandSpanLimit: Int

    var capabilityDescriptor: TerminalShellIntegrationCapabilityDescriptor {
        TerminalShellIntegrationCapabilityDescriptor(
            passiveOSCSequences: [.osc7, .osc133],
            optInSnippetDescriptors: Self.optInSnippetDescriptors,
            onboardingSteps: Self.onboardingSteps,
            requiresShellScriptInstallation: false
        )
    }

    var sessionSummary: TerminalShellIntegrationSessionSummary {
        let completedSpans = recentCommandSpans
        let installedCommandBoundarySupportObserved = !completedSpans.isEmpty
        let installedWorkingDirectorySupportObserved = sessionEvidence.observedOptInCapabilities.contains(.workingDirectoryTracking)
        var observedCapabilities: [TerminalShellIntegrationCapabilityDescriptor.OptInCapability] = []

        if installedWorkingDirectorySupportObserved {
            observedCapabilities.append(.workingDirectoryTracking)
        }
        if installedCommandBoundarySupportObserved {
            observedCapabilities.append(.commandBoundaryTracking)
        }

        return TerminalShellIntegrationSessionSummary(
            baselineSupport: TerminalShellIntegrationSessionSummary.BaselineSupport(
                supportedPassiveOSCSequences: capabilityDescriptor.passiveOSCSequences,
                observedPassiveOSCSequences: sessionEvidence.observedPassiveOSCSequences
            ),
            optInIntegration: TerminalShellIntegrationSessionSummary.OptInIntegration(
                supportedSnippetCapabilities: Self.supportedOptInSnippetCapabilities,
                observedCapabilities: observedCapabilities,
                completedCommandSpanReferences: sessionEvidence.completedCommandSpanReferences,
                installedWorkingDirectorySupportObserved: installedWorkingDirectorySupportObserved,
                installedCommandBoundarySupportObserved: installedCommandBoundarySupportObserved
            )
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

    private static var supportedOptInSnippetCapabilities: [TerminalShellIntegrationCapabilityDescriptor.OptInCapability] {
        var capabilities: [TerminalShellIntegrationCapabilityDescriptor.OptInCapability] = []
        for descriptor in optInSnippetDescriptors {
            for capability in descriptor.capabilities where !capabilities.contains(capability) {
                capabilities.append(capability)
            }
        }
        return capabilities
    }

    private static let onboardingSteps: [TerminalShellIntegrationCapabilityDescriptor.OnboardingStep] = [
        TerminalShellIntegrationCapabilityDescriptor.OnboardingStep(
            title: "Works without setup",
            detail: "Kurotty passively detects OSC 7 working-directory updates and OSC 133 command boundaries when your shell already emits them.",
            commandID: nil,
            requiresInstaller: false
        ),
        TerminalShellIntegrationCapabilityDescriptor.OnboardingStep(
            title: "Enable richer command UX",
            detail: "Copy an opt-in shell snippet for fold, replay, search, and command-reference actions without installing a helper.",
            commandID: .showShellIntegrationSnippets,
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
        sessionEvidence: TerminalShellIntegrationSessionEvidence = TerminalShellIntegrationSessionEvidence(),
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
        self.sessionEvidence = sessionEvidence
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
        sessionEvidence.recordObservedPassiveOSCSequence(.osc7)
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
            recordObservedOSC133CommandBoundary()
            boundarySequence += 1
            currentBoundary = .promptStart
            isCommandActive = false
            activeCommandSpan = nil
            lastPromptBoundarySequence = boundarySequence
            return .promptStart
        case "B":
            recordObservedOSC133CommandBoundary()
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
            recordObservedOSC133CommandBoundary()
            boundarySequence += 1
            currentBoundary = .outputStart
            activeCommandSpan?.outputBoundarySequence = boundarySequence
            return .outputStart
        case "D":
            recordObservedOSC133CommandBoundary()
            boundarySequence += 1
            let exitCode = parts.dropFirst().lazy.compactMap { Int($0) }.first
            currentBoundary = .commandEnd
            isCommandActive = false
            lastExitCode = exitCode
            activeCommandSpan?.endBoundarySequence = boundarySequence
            activeCommandSpan?.exitCode = exitCode
            if let completedSpan = activeCommandSpan {
                appendRecentCommandSpan(completedSpan)
                sessionEvidence.replaceCompletedCommandSpanReferences(recentCommandSpans.map(\.reference))
            }
            activeCommandSpan = nil
            return .commandEnd(exitCode: exitCode)
        default:
            return nil
        }
    }

    private mutating func recordObservedOSC133CommandBoundary() {
        sessionEvidence.recordObservedPassiveOSCSequence(.osc133)
        sessionEvidence.recordObservedOptInCapability(.commandBoundaryTracking)
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
