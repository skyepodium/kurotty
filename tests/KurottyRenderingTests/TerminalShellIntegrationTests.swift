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
}
