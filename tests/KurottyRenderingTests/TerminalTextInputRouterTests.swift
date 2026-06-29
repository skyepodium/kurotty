import AppKit
import XCTest
@testable import KurottyApp

final class TerminalTextInputRouterTests: XCTestCase {
    func testControlBUsesKeyCodeFallbackWhenCharactersAreMissing() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 11
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\u{2}")
    }

    func testControlBStillUsesCharacterPathWhenCharactersAreAvailable() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{2}",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\u{2}")
    }

    func testControlKeyFallbackDoesNotRunForCommandOrOptionChords() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 11
        ))

        XCTAssertNil(TerminalTextInputRouter.terminalControlText(for: event))
    }

    func testControlKeyFallbackDoesNotGuessNonPrefixLetters() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 8
        ))

        XCTAssertNil(TerminalTextInputRouter.terminalControlText(for: event))
    }

}
