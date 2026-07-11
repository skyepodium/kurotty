import XCTest
@testable import KurottyApp

final class TerminalShellIntegrationTests: XCTestCase {
    func testOsc7FileUrlUpdatesCurrentWorkingDirectoryCandidate() {
        var integration = TerminalShellIntegration()

        let event = integration.consumeOsc("7;file://localhost/Users/skye/Project%20One")

        XCTAssertEqual(event, .workingDirectoryChanged("/Users/skye/Project One"))
        XCTAssertEqual(integration.currentWorkingDirectoryCandidate, "/Users/skye/Project One")
    }

    func testOsc7FileUrlDecodesReservedPathCharactersEmittedBySnippets() {
        var integration = TerminalShellIntegration()

        let event = integration.consumeOsc("7;file://localhost/tmp/a%23b%3Fc%25d%20e")

        XCTAssertEqual(event, .workingDirectoryChanged("/tmp/a#b?c%d e"))
        XCTAssertEqual(integration.currentWorkingDirectoryCandidate, "/tmp/a#b?c%d e")
    }

    func testOsc7RejectsInvalidAndNonFileUrlsWithoutMutation() {
        var integration = TerminalShellIntegration(currentWorkingDirectoryCandidate: "/before")

        XCTAssertNil(integration.consumeOsc("7;https://example.com/tmp"))
        XCTAssertNil(integration.consumeOsc("7;not a url"))
        XCTAssertNil(integration.consumeOsc("7;file://remote.example.com/tmp"))

        XCTAssertEqual(integration.currentWorkingDirectoryCandidate, "/before")
    }

    func testOsc133PromptStartMarksPromptBoundaryAndClearsCommandState() {
        var integration = TerminalShellIntegration()
        _ = integration.consumeOsc("133;B")

        let event = integration.consumeOsc("133;A")

        XCTAssertEqual(event, .promptStart)
        XCTAssertEqual(integration.currentBoundary, .promptStart)
        XCTAssertFalse(integration.isCommandActive)
        XCTAssertNil(integration.activeCommandSpan)
    }

    func testOsc133CommandStartMarksCommandActive() {
        var integration = TerminalShellIntegration()

        let event = integration.consumeOsc("133;B")

        XCTAssertEqual(event, .commandStart)
        XCTAssertEqual(integration.currentBoundary, .commandStart)
        XCTAssertTrue(integration.isCommandActive)
    }

    func testOsc133OutputStartMarksOutputBoundary() {
        var integration = TerminalShellIntegration()

        let event = integration.consumeOsc("133;C")

        XCTAssertEqual(event, .outputStart)
        XCTAssertEqual(integration.currentBoundary, .outputStart)
    }

    func testOsc133CommandEndExtractsExitCode() {
        var integration = TerminalShellIntegration()
        _ = integration.consumeOsc("133;B")

        let event = integration.consumeOsc("133;D;42")

        guard case .commandEnd(let context)? = event else {
            return XCTFail("Expected commandEnd event, got \(String(describing: event))")
        }
        XCTAssertEqual(context.exitCode, 42)
        XCTAssertEqual(integration.currentBoundary, .commandEnd)
        XCTAssertEqual(integration.lastExitCode, 42)
        XCTAssertFalse(integration.isCommandActive)
    }

    func testOsc133CommandEndWithoutValidExitCodeStillEndsCommand() {
        var integration = TerminalShellIntegration()
        _ = integration.consumeOsc("133;B")

        let event = integration.consumeOsc("133;D;not-a-number")

        guard case .commandEnd(let context)? = event else {
            return XCTFail("Expected commandEnd event, got \(String(describing: event))")
        }
        XCTAssertNil(context.exitCode)
        XCTAssertNil(integration.lastExitCode)
        XCTAssertFalse(integration.isCommandActive)
    }

    func testOsc133CommandEndReturnsCompletionContextFromCommandSpan() throws {
        var integration = TerminalShellIntegration(currentWorkingDirectoryCandidate: "/Users/skye/project")

        _ = integration.consumeOsc("133;A")
        _ = integration.consumeOsc("133;B")
        integration.setActiveCommandText("swift test")
        _ = integration.consumeOsc("133;C")
        let event = integration.consumeOsc("133;D;0")

        guard case .commandEnd(let context)? = event else {
            return XCTFail("Expected commandEnd event, got \(String(describing: event))")
        }
        XCTAssertEqual(context.commandText, "swift test")
        XCTAssertEqual(context.cwd, "/Users/skye/project")
        XCTAssertEqual(context.exitCode, 0)
        XCTAssertNotNil(context.duration)
        XCTAssertEqual(context.span.reference.spanID, 1)
        XCTAssertEqual(context.span.outputRange, TerminalCommandOutputRange(startBoundarySequence: 3, endBoundarySequence: 4))
    }

    func testCommandCompletionNotificationContentUsesCommandMetadata() {
        let context = TerminalCommandCompletionContext(
            span: TerminalCommandSpan(
                id: 9,
                cwd: "/Users/skye/project",
                startBoundarySequence: 2,
                endBoundarySequence: 4,
                exitCode: 1,
                promptBoundarySequence: 1,
                outputBoundarySequence: 3,
                commandText: "swift test"
            ),
            exitCode: 1,
            duration: 2.5
        )

        let content = TerminalCommandCompletionNotificationContent.make(from: context)

        XCTAssertEqual(content.title, "Command failed")
        XCTAssertEqual(content.subtitle, "swift test")
        XCTAssertEqual(content.body, "Exit code: 1\nDuration: 2.5s\nDirectory: /Users/skye/project")
        XCTAssertEqual(content.exitCode, 1)
        XCTAssertEqual(content.duration, 2.5)
        XCTAssertEqual(content.cwd, "/Users/skye/project")
    }

    func testUnknownOscSequencesDoNotMutateState() {
        var integration = TerminalShellIntegration(currentWorkingDirectoryCandidate: "/before")
        _ = integration.consumeOsc("133;B")
        let snapshot = integration

        XCTAssertNil(integration.consumeOsc("999;payload"))
        XCTAssertNil(integration.consumeOsc("133;Z;payload"))

        XCTAssertEqual(integration, snapshot)
    }

    func testOsc133LifecycleProducesCompletedCommandSpanWithCwd() throws {
        var integration = TerminalShellIntegration()

        _ = integration.consumeOsc("7;file://localhost/Users/skye/project")
        _ = integration.consumeOsc("133;A")
        _ = integration.consumeOsc("133;B")
        let activeSpan = try XCTUnwrap(integration.activeCommandSpan)
        _ = integration.consumeOsc("133;C")
        _ = integration.consumeOsc("133;D;7")

        XCTAssertNil(integration.activeCommandSpan)
        let span = try XCTUnwrap(integration.recentCommandSpans.first)
        XCTAssertEqual(span.id, activeSpan.id)
        XCTAssertEqual(span.cwd, "/Users/skye/project")
        XCTAssertEqual(span.startBoundarySequence, 2)
        XCTAssertEqual(span.promptBoundarySequence, 1)
        XCTAssertEqual(span.outputBoundarySequence, 3)
        XCTAssertEqual(span.endBoundarySequence, 4)
        XCTAssertEqual(span.exitCode, 7)
        XCTAssertNil(span.commandText)
    }

    func testCompletedCommandSpanExposesFoldReplayAndSearchMetadataWithoutOutput() throws {
        var integration = TerminalShellIntegration()

        completeCommand(
            cwd: "/Users/skye/project",
            commandText: "swift test --filter TerminalShellIntegrationTests",
            exitCode: 0,
            in: &integration
        )

        let span = try XCTUnwrap(integration.recentCommandSpans.first)
        let outputRange = try XCTUnwrap(span.outputRange)
        XCTAssertEqual(outputRange.startBoundarySequence, 3)
        XCTAssertEqual(outputRange.endBoundarySequence, 4)

        let foldCandidate = try XCTUnwrap(span.foldCandidate)
        XCTAssertEqual(foldCandidate.spanID, span.id)
        XCTAssertEqual(foldCandidate.reference, span.reference)
        XCTAssertEqual(foldCandidate.outputRange, outputRange)

        let replayCandidate = try XCTUnwrap(span.replayCandidate)
        XCTAssertEqual(replayCandidate.spanID, span.id)
        XCTAssertEqual(replayCandidate.reference, span.reference)
        XCTAssertEqual(replayCandidate.commandText, "swift test --filter TerminalShellIntegrationTests")
        XCTAssertEqual(replayCandidate.cwd, "/Users/skye/project")
        XCTAssertTrue(replayCandidate.requiresExplicitUserConfirmation)

        let searchMetadata = span.searchMetadata
        XCTAssertEqual(searchMetadata.spanID, span.id)
        XCTAssertEqual(searchMetadata.reference, span.reference)
        XCTAssertEqual(searchMetadata.cwd, "/Users/skye/project")
        XCTAssertEqual(searchMetadata.exitCode, 0)
        XCTAssertEqual(searchMetadata.commandText, "swift test --filter TerminalShellIntegrationTests")
        XCTAssertTrue(searchMetadata.isFoldable)
        XCTAssertTrue(searchMetadata.isReplayable)
    }

    func testReplayCandidateRequiresNonEmptyCompletedCommandText() throws {
        var integration = TerminalShellIntegration()

        completeCommand(commandText: "   ", exitCode: 0, in: &integration)

        let span = try XCTUnwrap(integration.recentCommandSpans.first)
        XCTAssertNil(span.replayCandidate)
        XCTAssertFalse(span.searchMetadata.isReplayable)
    }

    func testDefaultShellIntegrationPolicyIsPassiveAndDoesNotRequireScriptInstallation() {
        let integration = TerminalShellIntegration()

        XCTAssertFalse(integration.capabilityDescriptor.requiresShellScriptInstallation)
        XCTAssertEqual(integration.capabilityDescriptor.passiveOSCSequences, [.osc7, .osc133])
        XCTAssertFalse(integration.capabilityDescriptor.optInSnippetDescriptors.contains { $0.isEnabledByDefault })
        XCTAssertEqual(integration.sessionEvidence, TerminalShellIntegrationSessionEvidence())
    }

    func testZshBootstrapUsesBundledResourcesAndPreservesUserZDOTDIR() throws {
        let resources = try XCTUnwrap(TerminalShellIntegrationBootstrap.bundledResourceDirectory)

        let configuration = TerminalShellIntegrationBootstrap.configuration(
            shellPath: "/bin/zsh",
            environment: ["ZDOTDIR": "/tmp/user-zdotdir"],
            resourceDirectory: resources
        )

        XCTAssertEqual(configuration.argumentZero, "-zsh")
        XCTAssertEqual(configuration.arguments, ["-i"])
        XCTAssertEqual(configuration.environment["KUROTTY_ZSH_ZDOTDIR"], "/tmp/user-zdotdir")
        XCTAssertEqual(configuration.environment["ZDOTDIR"], resources.appendingPathComponent("zsh").path)
        XCTAssertTrue(configuration.automaticallyInjectsCommandBoundaries)
        let bootstrapSource = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/KurottyApp/TerminalShellIntegrationBootstrap.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(bootstrapSource.contains("/Users/"))
        XCTAssertFalse(bootstrapSource.contains("/Applications/"))
    }

    func testSupportedShellBootstrapsResolveOnlyFromProvidedResourceDirectory() throws {
        let resources = try XCTUnwrap(TerminalShellIntegrationBootstrap.bundledResourceDirectory)

        let bash = TerminalShellIntegrationBootstrap.configuration(
            shellPath: "/bin/bash",
            environment: [:],
            resourceDirectory: resources
        )
        let fish = TerminalShellIntegrationBootstrap.configuration(
            shellPath: "/opt/homebrew/bin/fish",
            environment: ["XDG_DATA_DIRS": "/usr/local/share:/usr/share"],
            resourceDirectory: resources
        )

        XCTAssertEqual(bash.arguments, ["--rcfile", resources.appendingPathComponent("bash/kurotty.bash").path, "-i"])
        XCTAssertTrue(bash.automaticallyInjectsCommandBoundaries)
        XCTAssertEqual(
            fish.environment["XDG_DATA_DIRS"],
            "\(resources.appendingPathComponent("fish").path):/usr/local/share:/usr/share"
        )
        XCTAssertTrue(fish.automaticallyInjectsCommandBoundaries)
    }

    func testUnknownShellFallsBackWithoutChangingEnvironment() {
        let configuration = TerminalShellIntegrationBootstrap.configuration(
            shellPath: "/usr/local/bin/custom-shell",
            environment: ["HOME": "/tmp/home"],
            resourceDirectory: URL(fileURLWithPath: "/tmp/resources")
        )

        XCTAssertEqual(configuration.argumentZero, "-custom-shell")
        XCTAssertEqual(configuration.arguments, ["-i"])
        XCTAssertEqual(configuration.environment, [:])
        XCTAssertFalse(configuration.automaticallyInjectsCommandBoundaries)
    }

    func testCapabilityDescriptorExposesInstallFreeOnboardingSteps() {
        let descriptor = TerminalShellIntegration().capabilityDescriptor

        XCTAssertEqual(
            descriptor.onboardingSteps,
            [
                TerminalShellIntegrationCapabilityDescriptor.OnboardingStep(
                    title: "Works without setup",
                    detail: "Kurotty loads bundled OSC 7 and OSC 133 integration for zsh, bash, and fish without modifying your shell files.",
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
        )
    }

    func testSessionEvidenceRecordsObservedOptInSignalsSeparatelyFromDescriptors() {
        var integration = TerminalShellIntegration()

        _ = integration.consumeOsc("7;file://localhost/Users/skye/project")
        XCTAssertEqual(integration.sessionEvidence.observedPassiveOSCSequences, [.osc7])
        XCTAssertEqual(integration.sessionEvidence.observedOptInCapabilities, [])
        XCTAssertTrue(integration.capabilityDescriptor.optInSnippetDescriptors.allSatisfy { !$0.isEnabledByDefault })

        _ = integration.consumeOsc("133;A")
        _ = integration.consumeOsc("133;B")
        _ = integration.consumeOsc("133;C")
        _ = integration.consumeOsc("133;D;0")

        XCTAssertEqual(integration.sessionEvidence.observedPassiveOSCSequences, [.osc7, .osc133])
        XCTAssertEqual(
            integration.sessionEvidence.observedOptInCapabilities,
            [.commandBoundaryTracking]
        )
        XCTAssertEqual(integration.sessionEvidence.completedCommandSpanReferences.first?.spanID, 1)
    }

    func testSessionSummaryExposesEvidenceRowsForUIAuditAndAIWithoutRawOutput() {
        var integration = TerminalShellIntegration()

        _ = integration.consumeOsc("7;file://localhost/Users/skye/project")
        _ = integration.consumeOsc("133;A")
        _ = integration.consumeOsc("133;B")
        integration.setActiveCommandText("swift test")
        _ = integration.consumeOsc("133;C")
        _ = integration.consumeOsc("133;D;0")

        XCTAssertEqual(
            integration.sessionSummary.evidenceRows,
            [
                TerminalShellIntegrationEvidenceRow(
                    source: .passiveOSC,
                    label: "OSC 7",
                    detail: "working directory signal observed",
                    exposesRawCommandOutput: false,
                    isAvailableToUI: true,
                    isAvailableToAudit: true,
                    isAvailableToAI: true
                ),
                TerminalShellIntegrationEvidenceRow(
                    source: .passiveOSC,
                    label: "OSC 133",
                    detail: "command boundary signal observed",
                    exposesRawCommandOutput: false,
                    isAvailableToUI: true,
                    isAvailableToAudit: true,
                    isAvailableToAI: true
                ),
                TerminalShellIntegrationEvidenceRow(
                    source: .optInShellIntegration,
                    label: "Command Boundary Tracking",
                    detail: "1 completed command span reference available",
                    exposesRawCommandOutput: false,
                    isAvailableToUI: true,
                    isAvailableToAudit: true,
                    isAvailableToAI: true
                ),
            ]
        )
    }

    func testSessionSummarySeparatesBaselineSupportFromOptInEvidence() {
        var integration = TerminalShellIntegration()

        XCTAssertEqual(
            integration.sessionSummary,
            TerminalShellIntegrationSessionSummary(
                baselineSupport: TerminalShellIntegrationSessionSummary.BaselineSupport(
                    supportedPassiveOSCSequences: [.osc7, .osc133],
                    observedPassiveOSCSequences: []
                ),
                optInIntegration: TerminalShellIntegrationSessionSummary.OptInIntegration(
                    supportedSnippetCapabilities: [.workingDirectoryTracking, .commandBoundaryTracking],
                    observedCapabilities: [],
                    completedCommandSpanReferences: [],
                    installedWorkingDirectorySupportObserved: false,
                    installedCommandBoundarySupportObserved: false
                )
            )
        )

        _ = integration.consumeOsc("7;file://localhost/Users/skye/project")

        XCTAssertEqual(integration.sessionSummary.baselineSupport.observedPassiveOSCSequences, [.osc7])
        XCTAssertEqual(integration.sessionSummary.optInIntegration.observedCapabilities, [])
        XCTAssertFalse(integration.sessionSummary.optInIntegration.installedWorkingDirectorySupportObserved)
        XCTAssertFalse(integration.sessionSummary.optInIntegration.installedCommandBoundarySupportObserved)
    }

    func testSessionSummaryRequiresCompletedCommandSpanForInstalledCommandBoundaryEvidence() {
        var integration = TerminalShellIntegration()

        _ = integration.consumeOsc("133;A")
        _ = integration.consumeOsc("133;B")

        XCTAssertEqual(integration.sessionSummary.baselineSupport.observedPassiveOSCSequences, [.osc133])
        XCTAssertEqual(integration.sessionSummary.optInIntegration.observedCapabilities, [])
        XCTAssertFalse(integration.sessionSummary.optInIntegration.installedCommandBoundarySupportObserved)

        _ = integration.consumeOsc("133;C")
        _ = integration.consumeOsc("133;D;0")

        XCTAssertEqual(
            integration.sessionSummary.optInIntegration.observedCapabilities,
            [.commandBoundaryTracking]
        )
        XCTAssertTrue(integration.sessionSummary.optInIntegration.installedCommandBoundarySupportObserved)
        XCTAssertEqual(integration.sessionSummary.optInIntegration.completedCommandSpanReferences.first?.spanID, 1)
    }

    func testOptInShellIntegrationSnippetDescriptorsCoverSupportedShellsWithoutInstaller() {
        let descriptor = TerminalShellIntegration().capabilityDescriptor

        XCTAssertEqual(
            descriptor.optInSnippetDescriptors.map(\.shell),
            [.bash, .zsh, .fish]
        )

        for snippetDescriptor in descriptor.optInSnippetDescriptors {
            XCTAssertEqual(snippetDescriptor.installationMode, .manualSnippet)
            XCTAssertFalse(snippetDescriptor.requiresInstaller)
            XCTAssertFalse(snippetDescriptor.isEnabledByDefault)
            XCTAssertTrue(snippetDescriptor.snippet.contains("]7;file://localhost"))
            XCTAssertTrue(snippetDescriptor.snippet.contains("%25"))
            XCTAssertTrue(snippetDescriptor.snippet.contains("%23"))
            XCTAssertTrue(snippetDescriptor.snippet.contains("%3F"))
            XCTAssertFalse(snippetDescriptor.snippet.localizedCaseInsensitiveContains("output"))
        }

        let snippetsByShell = Dictionary(uniqueKeysWithValues: descriptor.optInSnippetDescriptors.map { ($0.shell, $0) })
        XCTAssertEqual(snippetsByShell[.bash]?.capabilities, [.workingDirectoryTracking])
        XCTAssertFalse(snippetsByShell[.bash]?.snippet.contains("trap '__kurotty_preexec' DEBUG") == true)
        XCTAssertFalse(snippetsByShell[.bash]?.snippet.contains("]133;") == true)
        XCTAssertEqual(snippetsByShell[.zsh]?.capabilities, [.workingDirectoryTracking, .commandBoundaryTracking])
        XCTAssertTrue(snippetsByShell[.zsh]?.snippet.contains("]133;") == true)
        XCTAssertEqual(snippetsByShell[.fish]?.capabilities, [.workingDirectoryTracking, .commandBoundaryTracking])
        XCTAssertTrue(snippetsByShell[.fish]?.snippet.contains("]133;") == true)
    }

    func testRecentCommandHistoryIsBounded() {
        var integration = TerminalShellIntegration(recentCommandSpanLimit: 2)

        completeCommand(exitCode: 0, in: &integration)
        completeCommand(exitCode: 1, in: &integration)
        completeCommand(exitCode: 2, in: &integration)

        XCTAssertEqual(integration.recentCommandSpans.map(\.exitCode), [1, 2])
    }

    func testCommandSpanSearchFiltersByCwdExitCodeAndTextWhenPresent() {
        var integration = TerminalShellIntegration()

        completeCommand(cwd: "/repo/a", commandText: "swift test", exitCode: 0, in: &integration)
        completeCommand(cwd: "/repo/b", commandText: "swift build", exitCode: 1, in: &integration)
        completeCommand(cwd: "/repo/a", commandText: nil, exitCode: 1, in: &integration)

        XCTAssertEqual(
            integration.searchRecentCommandSpans(cwd: "/repo/a").map(\.commandText),
            ["swift test", nil]
        )
        XCTAssertEqual(
            integration.searchRecentCommandSpans(exitCode: 1).map(\.cwd),
            ["/repo/b", "/repo/a"]
        )
        XCTAssertEqual(
            integration.searchRecentCommandSpans(text: "BUILD").map(\.cwd),
            ["/repo/b"]
        )
        XCTAssertEqual(
            integration.searchRecentCommandSpans(cwd: "/repo/a", exitCode: 1, text: "swift").count,
            0
        )
    }

    func testRecentCommandHistoryNavigatorNavigatesCompletedSpans() throws {
        var integration = TerminalShellIntegration()

        completeCommand(commandText: "first", exitCode: 0, in: &integration)
        completeCommand(commandText: "second", exitCode: 1, in: &integration)

        let latest = try XCTUnwrap(integration.recentCommandHistoryNavigator().latest())
        let previous = try XCTUnwrap(integration.recentCommandHistoryNavigator().previous(from: latest.id))

        XCTAssertEqual(latest.commandText, "second")
        XCTAssertEqual(previous.commandText, "first")
    }

    private func completeCommand(
        cwd: String? = nil,
        commandText: String? = nil,
        exitCode: Int,
        in integration: inout TerminalShellIntegration
    ) {
        if let cwd {
            _ = integration.consumeOsc("7;file://localhost\(cwd)")
        }
        _ = integration.consumeOsc("133;A")
        _ = integration.consumeOsc("133;B")
        integration.setActiveCommandText(commandText)
        _ = integration.consumeOsc("133;C")
        _ = integration.consumeOsc("133;D;\(exitCode)")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
