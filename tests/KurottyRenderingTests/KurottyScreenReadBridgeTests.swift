import Foundation
import XCTest
import KurottyCore
@testable import KurottyApp

@MainActor
final class KurottyScreenReadBridgeTests: XCTestCase {
    override func tearDown() {
        TerminalScreenReadRegistry.shared.unregister(paneID: Fixture.paneID)
        super.tearDown()
    }

    func testScreenTextProjectionUsesVisibleCellsOnly() {
        var screen = TerminalScreen(rows: 2, columns: 8)
        screen.set(character: "界", row: 0, column: 0, width: 2)
        screen.set(character: "x", row: 0, column: 2, width: 1)
        screen.set(character: "안", row: 1, column: 0, width: 2)

        XCTAssertEqual(TerminalRenderedScreenText.lines(from: screen.cells), ["界x", "안"])
        XCTAssertEqual(TerminalRenderedScreenText.text(from: screen.cells), "界x\n안")
    }

    func testRegistryRequiresExactPaneIdentifier() {
        TerminalScreenReadRegistry.shared.register(paneID: Fixture.paneID) {
            Fixture.snapshot
        }

        XCTAssertEqual(TerminalScreenReadRegistry.shared.snapshot(for: Fixture.paneID), Fixture.snapshot)
        XCTAssertNil(TerminalScreenReadRegistry.shared.snapshot(for: "other-pane"))
    }

    func testRequestRejectsEmptyPaneIdentifier() {
        XCTAssertThrowsError(try KurottyScreenReadRequest(paneID: " ")) { error in
            XCTAssertEqual(error as? KurottyScreenReadBridgeError, .emptyPaneIdentifier)
        }
    }

    func testShellEnvironmentPublishesCommandSocketAndPaneID() {
        let environment = KurottyScreenReadBridgeEnvironment.shellEnvironment(
            paneIdentifier: Fixture.paneID,
            executablePath: "/Applications/kurotty.app/Contents/MacOS/kurotty",
            socketPath: "/tmp/kurotty-screen-read.sock"
        )

        XCTAssertEqual(
            environment[AppConstants.ScreenRead.bridgeCommandEnvironmentName],
            "/Applications/kurotty.app/Contents/MacOS/kurotty"
        )
        XCTAssertEqual(
            environment[AppConstants.ScreenRead.bridgeSocketEnvironmentName],
            "/tmp/kurotty-screen-read.sock"
        )
        XCTAssertEqual(
            environment[AppConstants.ScreenRead.paneIdentifierEnvironmentName],
            Fixture.paneID
        )
    }

    func testClientRequestEncodingIsBoundedToExplicitPaneID() throws {
        let request = try KurottyScreenReadRequest(paneID: "  \(Fixture.paneID)  ")
        let data = try KurottyScreenReadBridgeClient.encode(request: request)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\"\(Fixture.paneID)\""))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("other-pane"))
    }

    private enum Fixture {
        static let paneID = "pane-A"
        static let snapshot = KurottyScreenReadSnapshot(
            version: KurottyScreenReadSnapshot.currentVersion,
            paneID: paneID,
            rows: 2,
            columns: 8,
            cursorRow: 1,
            cursorColumn: 3,
            scrollbackOffset: 0,
            alternateScreen: false,
            lines: ["one", "two"]
        )
    }
}
