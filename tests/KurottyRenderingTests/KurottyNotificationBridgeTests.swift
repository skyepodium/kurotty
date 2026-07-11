import Darwin
import XCTest
@testable import KurottyApp

final class KurottyNotificationBridgeTests: XCTestCase {
    func testPayloadUsesGenericMessageFromJSON() throws {
        let payload = try KurottyNotificationBridgePayload.fromIncomingText(
            """
            {"message":"Background work completed.","unrelated":"ignored"}
            """
        )

        XCTAssertEqual(payload.title, "Alert")
        XCTAssertEqual(payload.subtitle, "")
        XCTAssertEqual(payload.body, "Background work completed.")
    }

    func testPayloadUsesGenericSummaryFromJSON() throws {
        let payload = try KurottyNotificationBridgePayload.fromIncomingText(
            """
            {"event":"job-complete","summary":"All checks passed."}
            """
        )

        XCTAssertEqual(payload.title, "Alert")
        XCTAssertEqual(payload.subtitle, "")
        XCTAssertEqual(payload.body, "All checks passed.")
        XCTAssertEqual(payload.event, "job-complete")
    }

    func testPayloadUsesExplicitTitleAndBodyFromJSON() throws {
        let payload = try KurottyNotificationBridgePayload.fromIncomingText(
            """
            {"title":"Build finished","subtitle":"dev","body":"All checks passed."}
            """
        )

        XCTAssertEqual(payload.title, "Build finished")
        XCTAssertEqual(payload.subtitle, "dev")
        XCTAssertEqual(payload.body, "All checks passed.")
    }

    func testVersionedPayloadPreservesProducerNeutralMetadata() throws {
        let payload = try KurottyNotificationBridgePayload.fromIncomingText(
            """
            {"version":1,"event":"task.completed","session_id":"pane-42","duration_ms":2600,"title":"Build finished","subtitle":"workspace","body":"All checks passed."}
            """
        )

        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.event, "task.completed")
        XCTAssertEqual(payload.sessionID, "pane-42")
        XCTAssertEqual(payload.durationMilliseconds, 2600)
        XCTAssertEqual(payload.title, "Build finished")
        XCTAssertEqual(payload.subtitle, "workspace")
        XCTAssertEqual(payload.body, "All checks passed.")
    }

    func testVersionedPayloadRoundTripsThroughBridgeEncoding() throws {
        let original = try KurottyNotificationBridgePayload.fromIncomingText(
            """
            {"version":1,"event":"task.completed","session_id":"arbitrary-producer","duration_ms":18,"body":"Finished."}
            """
        )
        let encoded = try KurottyNotificationBridgeClient.encode(payload: original)
        let decoded = try KurottyNotificationBridgePayload.fromIncomingText(
            try XCTUnwrap(String(data: encoded, encoding: .utf8))
        )

        XCTAssertEqual(decoded, original)
    }

    func testPayloadRejectsUnsupportedVersionAndStructuredEventWithoutBody() {
        XCTAssertThrowsError(
            try KurottyNotificationBridgePayload.fromIncomingText("{\"version\":2,\"body\":\"Finished.\"}")
        ) { error in
            XCTAssertEqual(error as? KurottyNotificationBridgeError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(
            try KurottyNotificationBridgePayload.fromIncomingText("{\"version\":1,\"event\":\"task.completed\"}")
        ) { error in
            XCTAssertEqual(error as? KurottyNotificationBridgeError, .emptyPayload)
        }
    }

    func testPayloadUsesPlainTextAsAlertBody() throws {
        let payload = try KurottyNotificationBridgePayload.fromIncomingText("안녕하세요.무엇을 도와드릴까요?")

        XCTAssertEqual(payload.title, "Alert")
        XCTAssertEqual(payload.subtitle, "")
        XCTAssertEqual(payload.body, "안녕하세요.무엇을 도와드릴까요?")
    }

    func testPayloadRejectsEmptyNotificationText() {
        XCTAssertThrowsError(try KurottyNotificationBridgePayload.fromIncomingText("   \n\t  "))
    }

    func testSocketPathUsesStableUserScopedLocation() throws {
        let socketPath = try KurottyNotificationBridgeSocketLocation.defaultSocketPath()

        XCTAssertEqual(socketPath.lastPathComponent, "notify.sock")
        XCTAssertTrue(socketPath.path.contains("Kurotty"))
        XCTAssertFalse(socketPath.path.contains("/dev/tty"))
    }

    func testShellEnvironmentUsesResolvedBundleExecutableAndUserScopedSocket() {
        let environment = KurottyNotificationBridgeEnvironment.shellEnvironment(
            executablePath: "/tmp/Kurotty Test.app/Contents/MacOS/kurotty",
            socketPath: "/tmp/kurotty-user/notify.sock"
        )

        XCTAssertEqual(environment["KUROTTY_NOTIFY_COMMAND"], "/tmp/Kurotty Test.app/Contents/MacOS/kurotty")
        XCTAssertEqual(environment["KUROTTY_NOTIFY_SOCKET"], "/tmp/kurotty-user/notify.sock")
    }

    func testShellEnvironmentRejectsMissingExecutableOrSocket() {
        XCTAssertTrue(KurottyNotificationBridgeEnvironment.shellEnvironment(
            executablePath: nil,
            socketPath: "/tmp/notify.sock"
        ).isEmpty)
        XCTAssertTrue(KurottyNotificationBridgeEnvironment.shellEnvironment(
            executablePath: "/tmp/kurotty",
            socketPath: nil
        ).isEmpty)
    }

    func testSocketProbeDistinguishesLiveSocketFromStalePath() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("kts-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let liveSocketPath = directory.appendingPathComponent("live.sock").path
        let staleSocketPath = directory.appendingPathComponent("stale.sock").path
        let descriptor = try makeListeningSocket(at: liveSocketPath)
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(atPath: liveSocketPath)
        }
        FileManager.default.createFile(atPath: staleSocketPath, contents: Data())

        XCTAssertTrue(KurottyNotificationBridgeSocketProbe.isReachable(path: liveSocketPath))
        XCTAssertFalse(KurottyNotificationBridgeSocketProbe.isReachable(path: staleSocketPath))
    }

    func testBridgeServerChecksLiveSocketBeforeRemovingPath() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/KurottyApp/KurottyNotificationBridge.swift"), encoding: .utf8)
        let probeRange = try XCTUnwrap(source.range(of: "KurottyNotificationBridgeSocketProbe.isReachable(path: path.path)"))
        let removeRange = try XCTUnwrap(source.range(of: "FileManager.default.removeItem(at: path)"))

        XCTAssertLessThan(probeRange.lowerBound, removeRange.lowerBound)
        XCTAssertTrue(source.contains("bridge socket active elsewhere path="))
        XCTAssertTrue(source.contains("scheduleBridgeClaimRetry()"))
    }

    func testBridgeClientDoesNotBypassKurottyWhenSocketIsUnavailable() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/KurottyApp/KurottyNotificationBridge.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("try KurottyNotificationBridgeClient.send(text)"))
        XCTAssertFalse(source.contains("KurottyCommandLineNotificationFallback"))
        XCTAssertFalse(source.contains("display notification"))
        XCTAssertFalse(source.contains("UNUserNotificationCenter.current()"))
    }

    private func makeListeningSocket(at path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KurottyNotificationBridgeError.socketUnavailable
        }
        do {
            var address = try testUnixAddress(path: path)
            let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(descriptor, sockaddrPointer, length)
                }
            }
            guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
                throw KurottyNotificationBridgeError.socketUnavailable
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func testUnixAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw KurottyNotificationBridgeError.socketPathTooLong
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for index in rawBuffer.indices {
                rawBuffer[index] = 0
            }
            rawBuffer.copyBytes(from: bytes)
        }
        return address
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
