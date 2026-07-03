import Foundation
import XCTest
@testable import KurottyApp

final class AICommandContextBridgeTests: XCTestCase {
    func testDefaultSnapshotIncludesMetadataWithoutOutput() {
        let bridge = AICommandContextBridge()
        let snapshot = bridge.snapshot(
            for: .init(
                command: "swift test",
                output: "build output that should stay out by default",
                cwd: "/Users/example/project",
                exitCode: 0
            ),
            maxEvents: 4,
            maxTextLength: 1_000
        )

        XCTAssertEqual(snapshot.command, "swift test")
        XCTAssertEqual(snapshot.output, "")
        XCTAssertEqual(snapshot.cwd, "/Users/example/project")
        XCTAssertEqual(snapshot.exitCode, 0)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.source, "terminal-command")
        XCTAssertTrue(snapshot.events.first?.text.contains("exitCode: 0") == true)
        XCTAssertTrue(snapshot.events.first?.text.contains("rawOutput: omitted") == true)
        XCTAssertFalse(String(describing: snapshot).contains("build output that should stay out by default"))
        XCTAssertTrue(snapshot.auditNote.contains("raw output omitted by default"))
    }

    func testOutputOptInRequiresApprovalBeforeIncludingRedactedOutput() {
        let bridge = AICommandContextBridge()

        let snapshot = bridge.snapshot(
            for: .init(
                command: "curl https://api.example.test",
                output: "HTTP 200",
                cwd: "/tmp",
                exitCode: 0
            ),
            maxEvents: 8,
            maxTextLength: 2_000,
            options: .init(includeRawOutput: true)
        )

        XCTAssertEqual(snapshot.output, "")
        XCTAssertEqual(snapshot.events.map(\.source), ["terminal-command"])
        XCTAssertTrue(snapshot.events.first?.text.contains("rawOutput: omitted") == true)
        XCTAssertTrue(snapshot.auditNote.contains("approval required"))
    }

    func testApprovedOutputOptInIncludesRedactedOutput() {
        let rawToken = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let bridge = AICommandContextBridge()

        var log = AIContextEventLog(maxEvents: 8, maxTextLength: 2_000)
        let snapshot = bridge.appendSnapshot(
            for: .init(
                command: "curl https://api.example.test",
                output: "github=\(rawToken)\nHTTP 200",
                cwd: "/tmp",
                exitCode: 0
            ),
            to: &log,
            options: .init(includeRawOutput: true, rawOutputApproved: true)
        )

        XCTAssertTrue(snapshot.output.contains("[REDACTED_GITHUB_TOKEN]"))
        XCTAssertFalse(String(describing: snapshot).contains(rawToken))
        XCTAssertEqual(snapshot.events.map(\.source), ["terminal-command", "terminal-output"])
        XCTAssertTrue(snapshot.events.last?.text.contains("[REDACTED_GITHUB_TOKEN]") == true)
        XCTAssertTrue(snapshot.events.first?.text.contains("rawOutput: included") == true)
        XCTAssertTrue(snapshot.auditNote.contains("approved"))
    }

    func testRedactsCommandCwdAndMetadata() {
        let rawAWSKey = "AKIAIOSFODNN7EXAMPLE"
        let bridge = AICommandContextBridge()
        let snapshot = bridge.snapshot(
            for: .init(
                command: "deploy password=command-secret \(rawAWSKey)",
                cwd: "/tmp/api_key=cwd-secret",
                exitCode: 1
            ),
            maxEvents: 4,
            maxTextLength: 2_000
        )

        let exported = String(describing: snapshot)
        XCTAssertFalse(exported.contains(rawAWSKey))
        XCTAssertFalse(exported.contains("command-secret"))
        XCTAssertFalse(exported.contains("cwd-secret"))
        XCTAssertTrue(snapshot.command.contains("[REDACTED_AWS_KEY]"))
        XCTAssertTrue(snapshot.command.contains("password=[REDACTED_SECRET]"))
        XCTAssertTrue(snapshot.cwd.contains("api_key=[REDACTED_SECRET]"))
        XCTAssertTrue(snapshot.events.first?.text.contains("[REDACTED_AWS_KEY]") == true)
    }

    func testCommandSpanInitializerCarriesCwdAndExitCode() {
        let span = TerminalCommandSpan(
            id: 42,
            cwd: "/repo",
            startBoundarySequence: 10,
            endBoundarySequence: 12,
            exitCode: 127,
            promptBoundarySequence: 9,
            outputBoundarySequence: 11,
            commandText: "missing-command"
        )

        let snapshot = AICommandContextBridge().snapshot(
            for: .init(span: span),
            maxEvents: 4,
            maxTextLength: 1_000
        )

        XCTAssertEqual(snapshot.command, "missing-command")
        XCTAssertEqual(snapshot.cwd, "/repo")
        XCTAssertEqual(snapshot.exitCode, 127)
        XCTAssertTrue(snapshot.events.first?.text.contains("exitCode: 127") == true)
    }

    func testCommandSpanSnapshotCarriesStableReferenceWithoutRawOutput() {
        let span = TerminalCommandSpan(
            id: 42,
            cwd: "/repo",
            startBoundarySequence: 10,
            endBoundarySequence: 14,
            exitCode: 0,
            promptBoundarySequence: 9,
            outputBoundarySequence: 12,
            commandText: "swift test"
        )

        let snapshot = AICommandContextBridge().snapshot(
            for: .init(span: span, output: "raw output should stay referenced only"),
            maxEvents: 4,
            maxTextLength: 1_000
        )

        let eventText = snapshot.events.first?.text ?? ""
        XCTAssertTrue(eventText.contains("commandSpanID: 42"))
        XCTAssertTrue(eventText.contains("promptBoundarySequence: 9"))
        XCTAssertTrue(eventText.contains("startBoundarySequence: 10"))
        XCTAssertTrue(eventText.contains("outputBoundarySequence: 12"))
        XCTAssertTrue(eventText.contains("endBoundarySequence: 14"))
        XCTAssertTrue(eventText.contains("rawOutput: omitted"))
        XCTAssertFalse(String(describing: snapshot).contains("raw output should stay referenced only"))
    }

    func testCommandSpanSnapshotCarriesCopyableReferenceLocatorWithoutRawOutput() {
        let rawOutput = "token=raw-secret should stay out"
        let span = TerminalCommandSpan(
            id: 42,
            cwd: "/repo",
            startBoundarySequence: 10,
            endBoundarySequence: 14,
            exitCode: 0,
            promptBoundarySequence: 9,
            outputBoundarySequence: 12,
            commandText: "swift test"
        )

        let snapshot = AICommandContextBridge().snapshot(
            for: .init(span: span, output: rawOutput),
            maxEvents: 4,
            maxTextLength: 1_000
        )

        let eventText = snapshot.events.first?.text ?? ""
        XCTAssertTrue(eventText.contains("commandSpanReference: kurotty-command-span://42?start=10&output=12&end=14"))
        XCTAssertFalse(String(describing: snapshot).contains(rawOutput))
        XCTAssertFalse(String(describing: snapshot).contains("raw-secret"))
    }

    func testApprovalMetadataCarriesTargetAndRedactedContextSummary() {
        let rawToken = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let bridge = AICommandContextBridge()
        let context = AICommandContextBridge.CommandContext(
            command: "deploy token=\(rawToken)",
            output: "raw output should not be summarized",
            cwd: "/tmp/api_key=cwd-secret",
            exitCode: 0
        )

        let metadata = bridge.approvalMetadata(
            for: context,
            actor: "planner-agent",
            targetPaneID: "pane-1",
            targetWorkspaceID: "workspace-7",
            capability: "send-text",
            persistenceScope: .session
        )

        XCTAssertEqual(metadata.actor, "planner-agent")
        XCTAssertEqual(metadata.targetPaneID, "pane-1")
        XCTAssertEqual(metadata.targetWorkspaceID, "workspace-7")
        XCTAssertEqual(metadata.cwd, "/tmp/api_key=[REDACTED_SECRET]")
        XCTAssertEqual(metadata.capability, "send-text")
        XCTAssertEqual(metadata.requestedCapabilities.count, 1)
        XCTAssertEqual(metadata.requestedCapabilities.first?.capability, "send-text")
        XCTAssertEqual(metadata.requestedCapabilities.first?.reason, "explicit approval capability request")
        XCTAssertEqual(metadata.persistenceScope, .session)
        XCTAssertTrue(metadata.contextSummary?.contains("command: deploy token=[REDACTED_SECRET]") == true)
        XCTAssertTrue(metadata.contextSummary?.contains("cwd: /tmp/api_key=[REDACTED_SECRET]") == true)
        XCTAssertTrue(metadata.contextSummary?.contains("exitCode: 0") == true)
        XCTAssertTrue(metadata.contextSummary?.contains("rawOutput: omitted") == true)
        XCTAssertFalse(String(describing: metadata).contains(rawToken))
        XCTAssertFalse(String(describing: metadata).contains("cwd-secret"))
        XCTAssertFalse(String(describing: metadata).contains("raw output should not be summarized"))
    }

    func testApprovalMetadataCarriesCommandOutputReferenceAndPolicy() throws {
        let span = TerminalCommandSpan(
            id: 7,
            cwd: "/repo",
            startBoundarySequence: 20,
            endBoundarySequence: 24,
            exitCode: 1,
            promptBoundarySequence: 19,
            outputBoundarySequence: 22,
            commandText: "swift test"
        )

        let metadata = AICommandContextBridge().approvalMetadata(
            for: .init(span: span, output: "raw failure output"),
            targetPaneID: "pane-token=secret",
            targetWorkspaceID: "workspace-1",
            includesRawOutput: true,
            rawOutputApproved: false,
            secretRedactionEnabled: true
        )

        let commandOutput = try XCTUnwrap(metadata.commandOutput)
        XCTAssertEqual(commandOutput.reference.commandSpanID, 7)
        XCTAssertEqual(commandOutput.reference.targetPaneID, "pane-token=[REDACTED_SECRET]")
        XCTAssertEqual(commandOutput.reference.targetWorkspaceID, "workspace-1")
        XCTAssertEqual(commandOutput.reference.outputBoundarySequence, 22)
        XCTAssertEqual(metadata.contextReferences.map(\.commandSpanID), [7])
        XCTAssertEqual(metadata.contextReferences.first?.targetPaneID, "pane-token=[REDACTED_SECRET]")
        XCTAssertEqual(metadata.requestedCapabilities.first?.capability, "terminal-action")
        XCTAssertEqual(metadata.requestedCapabilities.first?.reference?.commandSpanID, 7)
        XCTAssertEqual(metadata.requestedCapabilities.first?.reference?.targetPaneID, "pane-token=[REDACTED_SECRET]")
        XCTAssertTrue(commandOutput.includesRawOutput)
        XCTAssertFalse(commandOutput.rawOutputApproved)
        XCTAssertTrue(commandOutput.secretRedactionEnabled)
        XCTAssertTrue(commandOutput.explicitApprovalRequired)
        XCTAssertFalse(String(describing: metadata).contains("raw failure output"))
        XCTAssertFalse(String(describing: metadata).contains("pane-token=secret"))
    }

    func testApprovalMetadataDeduplicatesCallerAndDefaultContextReferences() {
        let span = TerminalCommandSpan(
            id: 12,
            cwd: "/repo",
            startBoundarySequence: 30,
            endBoundarySequence: 34,
            exitCode: 0,
            promptBoundarySequence: 29,
            outputBoundarySequence: 32,
            commandText: "swift test"
        )

        let metadata = AICommandContextBridge().approvalMetadata(
            for: .init(span: span),
            targetPaneID: "pane-1",
            targetWorkspaceID: "workspace-7",
            contextReferences: [
                AICommandContextReference(
                    commandSpanID: 12,
                    targetPaneID: "pane-1",
                    targetWorkspaceID: "workspace-7",
                    promptBoundarySequence: 29,
                    startBoundarySequence: 30,
                    outputBoundarySequence: 32,
                    endBoundarySequence: 34
                ),
            ]
        )

        XCTAssertEqual(metadata.contextReferences.count, 1)
        XCTAssertEqual(metadata.contextReferences.first?.commandSpanID, 12)
        XCTAssertEqual(metadata.contextReferences.first?.targetPaneID, "pane-1")
        XCTAssertEqual(metadata.contextReferences.first?.targetWorkspaceID, "workspace-7")
    }

    func testApprovalMetadataBoundsContextSummary() {
        let bridge = AICommandContextBridge()

        let metadata = bridge.approvalMetadata(
            for: .init(command: String(repeating: "x", count: 400), cwd: "/repo"),
            maxContextSummaryLength: 48
        )

        XCTAssertLessThanOrEqual(metadata.contextSummary?.count ?? 0, 48)
    }

    func testApprovalMetadataSanitizesCustomCapabilitiesAndContextReferences() {
        let bridge = AICommandContextBridge()

        let metadata = bridge.approvalMetadata(
            for: .init(command: "git status", cwd: "/repo", exitCode: 0),
            capability: "workspace.inspect",
            requestedCapabilities: [
                AIAgentActionCapabilityRequest(
                    capability: "terminal.sendText token=cap-secret",
                    reference: AICommandContextReference(
                        commandSpanID: 99,
                        targetPaneID: "pane-api_key=pane-secret",
                        targetWorkspaceID: "workspace-password=workspace-secret"
                    ),
                    reason: "send text after reviewing token=reason-secret"
                ),
            ],
            contextReferences: [
                AICommandContextReference(
                    commandSpanID: 98,
                    targetPaneID: "pane-token=ref-secret",
                    targetWorkspaceID: "workspace-2"
                ),
            ]
        )

        XCTAssertEqual(metadata.capability, "workspace.inspect")
        XCTAssertEqual(metadata.requestedCapabilities.first?.capability, "terminal.sendText token=[REDACTED_SECRET]")
        XCTAssertEqual(metadata.requestedCapabilities.first?.reference?.commandSpanID, 99)
        XCTAssertEqual(metadata.requestedCapabilities.first?.reference?.targetPaneID, "pane-api_key=[REDACTED_SECRET]")
        XCTAssertEqual(metadata.requestedCapabilities.first?.reference?.targetWorkspaceID, "workspace-password=[REDACTED_SECRET]")
        XCTAssertEqual(metadata.requestedCapabilities.first?.reason, "send text after reviewing token=[REDACTED_SECRET]")
        XCTAssertEqual(metadata.contextReferences.first?.commandSpanID, 98)
        XCTAssertEqual(metadata.contextReferences.first?.targetPaneID, "pane-token=[REDACTED_SECRET]")
        XCTAssertFalse(String(describing: metadata).contains("cap-secret"))
        XCTAssertFalse(String(describing: metadata).contains("pane-secret"))
        XCTAssertFalse(String(describing: metadata).contains("workspace-secret"))
        XCTAssertFalse(String(describing: metadata).contains("reason-secret"))
        XCTAssertFalse(String(describing: metadata).contains("ref-secret"))
    }
}
