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
}
