import Foundation
import XCTest
@testable import KurottyApp

final class AIContextLayerTests: XCTestCase {
    func testRedactorMasksCommonSecretShapes() {
        let rawAWSKey = "AKIAIOSFODNN7EXAMPLE"
        let rawGitHubToken = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let rawOpenAIToken = "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789"
        let rawBearer = "bearer-token-abcdefghijklmnopqrstuvwxyz"

        let input = """
        aws=\(rawAWSKey)
        github=\(rawGitHubToken)
        openai=\(rawOpenAIToken)
        password=hunter2 token=plain-token api_key=plain-api-key
        Authorization: Bearer \(rawBearer)
        """

        let redacted = AIContextRedactor().redacted(input)

        XCTAssertFalse(redacted.contains(rawAWSKey))
        XCTAssertFalse(redacted.contains(rawGitHubToken))
        XCTAssertFalse(redacted.contains(rawOpenAIToken))
        XCTAssertFalse(redacted.contains(rawBearer))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains("plain-token"))
        XCTAssertFalse(redacted.contains("plain-api-key"))

        XCTAssertTrue(redacted.contains("[REDACTED_AWS_KEY]"))
        XCTAssertTrue(redacted.contains("[REDACTED_GITHUB_TOKEN]"))
        XCTAssertTrue(redacted.contains("[REDACTED_OPENAI_TOKEN]"))
        XCTAssertTrue(redacted.contains("password=[REDACTED_SECRET]"))
        XCTAssertTrue(redacted.contains("token=[REDACTED_SECRET]"))
        XCTAssertTrue(redacted.contains("api_key=[REDACTED_SECRET]"))
        XCTAssertTrue(redacted.contains("Authorization: Bearer [REDACTED_BEARER_TOKEN]"))
    }

    func testEventLogEnforcesMaxEventCountAndTextLength() {
        var log = AIContextEventLog(maxEvents: 2, maxTextLength: 12)

        log.record(source: "first-source", text: "first event should be dropped")
        log.record(source: "second-source-should-be-capped", text: "second event should be capped")
        log.record(source: "third-source-should-be-capped", text: "third event should be capped")

        let snapshot = log.snapshot(
            command: "echo very-long-command-text",
            output: "very-long-output-text",
            cwd: "/very/long/current/working/directory",
            exitCode: 0,
            auditSource: "agent-integration-test",
            auditNote: "raw terminal context export"
        )

        XCTAssertEqual(snapshot.events.count, 2)
        XCTAssertEqual(snapshot.events.map(\.source), ["second-sourc", "third-source"])
        XCTAssertEqual(snapshot.events.map(\.text), ["second event", "third event "])
        XCTAssertEqual(snapshot.command, "echo very-lo")
        XCTAssertEqual(snapshot.output, "very-long-ou")
        XCTAssertEqual(snapshot.cwd, "/very/long/c")
        XCTAssertEqual(snapshot.auditSource, "agent-integr")
        XCTAssertEqual(snapshot.auditNote, "raw terminal")
    }

    func testEventLogBoundsInputBeforeRedactionWhileRedactingSecretsCrossingCap() {
        let rawToken = "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789"
        var log = AIContextEventLog(maxEvents: 1, maxTextLength: 32)

        let output = String(repeating: "x", count: 23) + " " + rawToken + String(repeating: "y", count: 50_000)
        log.record(source: "terminal-output", text: output)

        let snapshot = log.snapshot(
            command: output,
            output: output,
            cwd: "/tmp",
            exitCode: nil,
            auditSource: "ai-context-v0-test",
            auditNote: "bounded redaction"
        )

        XCTAssertLessThanOrEqual(snapshot.output.count, 32)
        XCTAssertLessThanOrEqual(snapshot.command.count, 32)
        XCTAssertFalse(String(describing: snapshot).contains(rawToken))
        XCTAssertTrue(snapshot.output.contains("[REDACT"))
    }

    func testSnapshotDescriptionDoesNotExposeRawSecrets() {
        let rawAWSKey = "AKIAIOSFODNN7EXAMPLE"
        let rawGitHubToken = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let rawOpenAIToken = "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789"
        let rawBearer = "bearer-token-abcdefghijklmnopqrstuvwxyz"

        var log = AIContextEventLog(maxEvents: 4, maxTextLength: 200)
        log.record(source: "terminal-output", text: "token=event-secret \(rawGitHubToken)")

        let snapshot = log.snapshot(
            command: "deploy password=command-secret \(rawAWSKey)",
            output: "Authorization: Bearer \(rawBearer)\nopenai=\(rawOpenAIToken)",
            cwd: "/tmp/api_key=cwd-secret",
            exitCode: 1,
            auditSource: "ai-context-v0-test",
            auditNote: "redacted terminal snapshot for future agent integrations"
        )

        let exported = String(describing: snapshot)

        XCTAssertFalse(exported.contains(rawAWSKey))
        XCTAssertFalse(exported.contains(rawGitHubToken))
        XCTAssertFalse(exported.contains(rawOpenAIToken))
        XCTAssertFalse(exported.contains(rawBearer))
        XCTAssertFalse(exported.contains("command-secret"))
        XCTAssertFalse(exported.contains("event-secret"))
        XCTAssertFalse(exported.contains("cwd-secret"))

        XCTAssertTrue(exported.contains("auditSource=ai-context-v0-test"))
        XCTAssertTrue(exported.contains("auditNote=redacted terminal snapshot for future agent integrations"))
        XCTAssertTrue(exported.contains("[REDACTED_AWS_KEY]"))
        XCTAssertTrue(exported.contains("[REDACTED_GITHUB_TOKEN]"))
        XCTAssertTrue(exported.contains("[REDACTED_OPENAI_TOKEN]"))
        XCTAssertTrue(exported.contains("[REDACTED_BEARER_TOKEN]"))
    }
}
