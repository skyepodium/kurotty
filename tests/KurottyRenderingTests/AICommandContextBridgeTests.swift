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
}
