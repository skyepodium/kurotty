import Darwin
import XCTest
@testable import KurottyApp

final class KurottyNotificationBridgeTests: XCTestCase {
    func testPayloadUsesCodexLastAssistantMessageFromJSON() throws {
        let payload = try KurottyNotificationBridgePayload.fromIncomingText(
            """
            {"last-assistant-message":"My name is Codex.","projectPath":"/Users/example/dev"}
            """
        )

        XCTAssertEqual(payload.title, "Alert")
        XCTAssertEqual(payload.subtitle, "")
        XCTAssertEqual(payload.body, "My name is Codex.")
    }

    func testPayloadUsesCodexOutputPreviewFromJSON() throws {
        let payload = try KurottyNotificationBridgePayload.fromIncomingText(
            """
            {"event":"turn-complete","output_preview":"안녕하세요. 무엇을 도와드릴까요?","project_path":"/Users/example/dev"}
            """
        )

        XCTAssertEqual(payload.title, "Alert")
        XCTAssertEqual(payload.subtitle, "")
        XCTAssertEqual(payload.body, "안녕하세요. 무엇을 도와드릴까요?")
    }

    func testPayloadUsesExplicitTitleAndBodyFromJSON() throws {
        let payload = try KurottyNotificationBridgePayload.fromIncomingText(
            """
            {"title":"Codex task finished","subtitle":"dev","body":"Summarized recent commits."}
            """
        )

        XCTAssertEqual(payload.title, "Codex task finished")
        XCTAssertEqual(payload.subtitle, "dev")
        XCTAssertEqual(payload.body, "Summarized recent commits.")
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

    func testBridgeClientHasCommandLineFallbackWhenSocketIsUnavailable() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/KurottyApp/KurottyNotificationBridge.swift"), encoding: .utf8)
        let sendRange = try XCTUnwrap(source.range(of: "try KurottyNotificationBridgeClient.send(text)"))
        let fallbackRange = try XCTUnwrap(source.range(of: "KurottyCommandLineNotificationFallback.deliver(payload)"))

        XCTAssertLessThan(sendRange.lowerBound, fallbackRange.lowerBound)
        XCTAssertTrue(source.contains("command-line fallback delivered"))
        XCTAssertTrue(source.contains("UNUserNotificationCenter.current()"))
        XCTAssertTrue(source.contains("commandLineNotificationTimeoutMS"))
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
