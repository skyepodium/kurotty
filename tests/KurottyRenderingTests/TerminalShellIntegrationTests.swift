import XCTest
@testable import KurottyApp

final class TerminalShellIntegrationTests: XCTestCase {
    func testOsc7FileUrlUpdatesCurrentWorkingDirectoryCandidate() {
        var integration = TerminalShellIntegration()

        let event = integration.consumeOsc("7;file://localhost/Users/skye/Project%20One")

        XCTAssertEqual(event, .workingDirectoryChanged("/Users/skye/Project One"))
        XCTAssertEqual(integration.currentWorkingDirectoryCandidate, "/Users/skye/Project One")
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

        XCTAssertEqual(event, .commandEnd(exitCode: 42))
        XCTAssertEqual(integration.currentBoundary, .commandEnd)
        XCTAssertEqual(integration.lastExitCode, 42)
        XCTAssertFalse(integration.isCommandActive)
    }

    func testOsc133CommandEndWithoutValidExitCodeStillEndsCommand() {
        var integration = TerminalShellIntegration()
        _ = integration.consumeOsc("133;B")

        let event = integration.consumeOsc("133;D;not-a-number")

        XCTAssertEqual(event, .commandEnd(exitCode: nil))
        XCTAssertNil(integration.lastExitCode)
        XCTAssertFalse(integration.isCommandActive)
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
}
