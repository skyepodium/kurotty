import AppKit
import XCTest
@testable import KurottyApp
@testable import KurottyCore

/// Mouse-hide-while-typing policy plus the `keyDown` wiring that applies it.
final class TerminalTypingCursorHidingTests: XCTestCase {
    private enum Fixture {
        static let plainCharacter = "a"
        static let controlCharacter = "\u{03}"
        static let emptyCharacters = ""
    }

    func testOrdinaryTypingHidesTheCursor() {
        XCTAssertTrue(TerminalTypingCursorHiding.shouldHideCursor(
            characters: Fixture.plainCharacter,
            modifierFlags: [],
            isModalPresentationActive: false
        ))
    }

    func testControlCharactersStillCountAsTyping() {
        XCTAssertTrue(TerminalTypingCursorHiding.shouldHideCursor(
            characters: Fixture.controlCharacter,
            modifierFlags: [.control],
            isModalPresentationActive: false
        ))
    }

    func testCommandShortcutsDoNotHideTheCursor() {
        XCTAssertFalse(TerminalTypingCursorHiding.shouldHideCursor(
            characters: Fixture.plainCharacter,
            modifierFlags: [.command],
            isModalPresentationActive: false
        ))
    }

    func testFunctionKeysDoNotHideTheCursor() {
        XCTAssertFalse(TerminalTypingCursorHiding.shouldHideCursor(
            characters: Fixture.plainCharacter,
            modifierFlags: [.function],
            isModalPresentationActive: false
        ))
    }

    func testModalPresentationKeepsTheCursorVisible() {
        XCTAssertFalse(TerminalTypingCursorHiding.shouldHideCursor(
            characters: Fixture.plainCharacter,
            modifierFlags: [],
            isModalPresentationActive: true
        ))
    }

    func testModifierOnlyEventsDoNotHideTheCursor() {
        XCTAssertFalse(TerminalTypingCursorHiding.shouldHideCursor(
            characters: nil,
            modifierFlags: [],
            isModalPresentationActive: false
        ))
        XCTAssertFalse(TerminalTypingCursorHiding.shouldHideCursor(
            characters: Fixture.emptyCharacters,
            modifierFlags: [],
            isModalPresentationActive: false
        ))
    }

    func testFeatureGateDefaultsToEnabled() {
        XCTAssertTrue(TerminalTypingCursorHiding.hideMouseCursorWhileTypingEnabled)
    }

    // MARK: - Source shape

    func testKeyDownHidesTheCursorOnlyAfterCommandKeyHandling() throws {
        let source = try surfaceSource()

        let commandKeyIndex = try XCTUnwrap(source.range(of: "if handleCommandKey(event) {"))
        let hideIndex = try XCTUnwrap(source.range(of: "hideMouseCursorWhileTypingIfNeeded(event)"))

        XCTAssertTrue(
            commandKeyIndex.lowerBound < hideIndex.lowerBound,
            "Command shortcuts must return before the typing cursor hide runs"
        )
    }

    func testCursorHidingUsesTheAppKitHideUntilMouseMovesEntryPoint() throws {
        let source = try surfaceSource()

        XCTAssertTrue(source.contains("NSCursor.setHiddenUntilMouseMoves(true)"))
        XCTAssertTrue(source.contains("TerminalTypingCursorHiding.shouldHideCursor"))
        XCTAssertTrue(source.contains("isModalPresentationActive: isModalPresentationActive"))
    }

    func testFileLinkClicksRouteToAnEditorTabInsteadOfTheOpenLinkDialog() throws {
        let source = try surfaceSource()

        XCTAssertTrue(source.contains("if let fileTarget = link.fileTarget {"))
        XCTAssertTrue(source.contains("openFileLinkInEditorTab(fileTarget)"))
        XCTAssertTrue(source.contains("controller.openEditorTab(for: target.fileURL, line: target.line)"))
    }

    func testLinkHitTestingNeverStatsOnTheMainActor() throws {
        let source = try surfaceSource()

        XCTAssertTrue(source.contains("let context = fileLinkContext()"))
        XCTAssertTrue(source.contains("fileLinkContext: context"))
        XCTAssertFalse(
            source.contains("FileManager.default.fileExists"),
            "Existence checks belong on TerminalPathExistsProbe's utility queue"
        )
    }

    private func surfaceSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KurottyApp/TerminalSurfaceView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
