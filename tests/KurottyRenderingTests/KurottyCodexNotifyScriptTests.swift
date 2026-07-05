import Foundation
import XCTest

final class KurottyCodexNotifyScriptTests: XCTestCase {
    func testCodexNotifyScriptUsesExplicitBridgeNotTTYGuessing() throws {
        let source = try String(contentsOf: scriptURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("--notify-json"))
        XCTAssertTrue(source.contains("KUROTTY_NOTIFY_WRAPPER_SENT"))
        XCTAssertTrue(source.contains("last-assistant-message"))
        XCTAssertFalse(source.contains("/dev/tty"))
        XCTAssertFalse(source.contains("/dev/ttys"))
    }

    func testCodexNotifyScriptDryRunHandlesUnmanagedCwdTurnCompletePayload() throws {
        let node = try nodeExecutableURL()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-codex-notify-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let payload = """
        {"type":"agent-turn-complete","cwd":"/Users/example/dev","thread-id":"thread-1","turn-id":"turn-1","last-assistant-message":"안녕하세요. 무엇을 도와드릴까요?"}
        """
        let process = Process()
        process.executableURL = node
        process.arguments = [scriptURL().path, payload]
        process.environment = [
            "KUROTTY_NOTIFY_DRY_RUN": "1",
            "KUROTTY_NOTIFY_CHAIN_OMX": "0",
            "KUROTTY_CODEX_NOTIFY_LOG_PATH": logURL.path,
        ]

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("kurotty_notify_dry_run"))
        XCTAssertTrue(log.contains("Session dev #1: 안녕하세요. 무엇을 도와드릴까요?"))
    }

    private func scriptURL() -> URL {
        repositoryRoot()
            .appendingPathComponent("scripts")
            .appendingPathComponent("kurotty-codex-notify.mjs")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func nodeExecutableURL() throws -> URL {
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw XCTSkip("Node.js is not available for the Codex notify wrapper dry-run test.")
    }
}
