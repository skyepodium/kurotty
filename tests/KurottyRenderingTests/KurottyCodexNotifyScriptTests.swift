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

    func testInstalledAppBundlesCodexNotifyWrapperAtStableResourcePath() throws {
        let installSource = try repositoryFile("scripts/install-app.sh")
        let packageSource = try repositoryFile("scripts/package-release.sh")
        let verifySource = try repositoryFile("scripts/verify-icon-bundle.sh")
        let readme = try repositoryFile("README.md")

        XCTAssertTrue(installSource.contains("CODEX_NOTIFY_WRAPPER=\"$APP_BUNDLE/Contents/Resources/kurotty-codex-notify.mjs\""))
        XCTAssertTrue(installSource.contains("cp \"$ROOT_DIR/scripts/kurotty-codex-notify.mjs\" \"$CODEX_NOTIFY_WRAPPER\""))
        XCTAssertTrue(packageSource.contains("cp \"$ROOT_DIR/scripts/kurotty-codex-notify.mjs\" \"$APP_BUNDLE/Contents/Resources/kurotty-codex-notify.mjs\""))
        XCTAssertTrue(verifySource.contains("Contents/Resources/kurotty-codex-notify.mjs"))
        XCTAssertTrue(readme.contains("/Applications/kurotty.app/Contents/Resources/kurotty-codex-notify.mjs"))
        XCTAssertFalse(readme.contains("/path/to/kurotty/scripts/kurotty-codex-notify.mjs"))
    }

    func testBundledCodexNotifyWrapperDefaultsToSiblingAppExecutable() throws {
        let node = try nodeExecutableURL()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-codex-bundle-\(UUID().uuidString)", isDirectory: true)
        let appURL = directory.appendingPathComponent("kurotty.app", isDirectory: true)
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let macOSURL = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let wrapperURL = resourcesURL.appendingPathComponent("kurotty-codex-notify.mjs")
        let executableURL = macOSURL.appendingPathComponent("kurotty")
        let invocationURL = directory.appendingPathComponent("invocation.txt")
        let logURL = directory.appendingPathComponent("notify.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: scriptURL(), to: wrapperURL)
        try """
        #!/usr/bin/env bash
        printf '%s\n' "$0" "$@" > "\(invocationURL.path)"
        exit 0
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let process = Process()
        process.executableURL = node
        process.arguments = [
            wrapperURL.path,
            #"{"type":"agent-turn-complete","cwd":"/Users/example/dev","last-assistant-message":"Bundled wrapper path test"}"#,
        ]
        process.environment = [
            "KUROTTY_NOTIFY_CHAIN_OMX": "0",
            "KUROTTY_CODEX_NOTIFY_LOG_PATH": logURL.path,
        ]

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let invocation = try String(contentsOf: invocationURL, encoding: .utf8)
        XCTAssertTrue(invocation.contains(executableURL.path))
        XCTAssertTrue(invocation.contains("--notify-json"))
        let logData = try Data(contentsOf: logURL)
        let logObject = try XCTUnwrap(JSONSerialization.jsonObject(with: logData) as? [String: Any])
        let loggedCommand = try XCTUnwrap(logObject["command"] as? String)
        XCTAssertEqual(
            URL(fileURLWithPath: loggedCommand).resolvingSymlinksInPath().path,
            executableURL.resolvingSymlinksInPath().path
        )
    }

    func testCodexNotifyWrapperRunsPreviousNotifyAfterKurottyDelivery() throws {
        let node = try nodeExecutableURL()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-codex-chain-\(UUID().uuidString)", isDirectory: true)
        let orderURL = directory.appendingPathComponent("order.txt")
        let logURL = directory.appendingPathComponent("notify.jsonl")
        let kurottyURL = directory.appendingPathComponent("fake-kurotty")
        let previousURL = directory.appendingPathComponent("fake-previous")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        #!/usr/bin/env bash
        printf 'kurotty\\n' >> "\(orderURL.path)"
        exit 0
        """.write(to: kurottyURL, atomically: true, encoding: .utf8)
        try """
        #!/usr/bin/env bash
        printf 'previous:%s\\n' "$*" >> "\(orderURL.path)"
        exit 0
        """.write(to: previousURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kurottyURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: previousURL.path)

        let previousCommandData = try JSONSerialization.data(withJSONObject: [previousURL.path, "turn-ended"])
        let previousCommand = String(data: previousCommandData, encoding: .utf8)!
        let payload = #"{"type":"agent-turn-complete","cwd":"/Users/example/dev","last-assistant-message":"Chain order test"}"#

        let process = Process()
        process.executableURL = node
        process.arguments = [
            scriptURL().path,
            "--previous-notify",
            previousCommand,
            payload,
        ]
        process.environment = [
            "KUROTTY_NOTIFY_COMMAND": kurottyURL.path,
            "KUROTTY_NOTIFY_CHAIN_OMX": "0",
            "KUROTTY_CODEX_NOTIFY_LOG_PATH": logURL.path,
        ]

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let order = try String(contentsOf: orderURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(order.first, "kurotty")
        XCTAssertEqual(order.dropFirst().first?.hasPrefix("previous:turn-ended "), true)
        XCTAssertEqual(order.dropFirst().first?.contains(payload), true)

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("kurotty_notify_sent"))
        XCTAssertTrue(log.contains("previous_notify_sent"))
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

    private func repositoryFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
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
