import AppKit
import XCTest
@testable import KurottyApp

final class TerminalTextInputRouterTests: XCTestCase {
    @MainActor
    func testPromptInputViewInvalidatesWhenMarkedTextStartsBeforeCommit() throws {
        let view = TerminalInputView(core: CoreBridge(cols: 80, rows: 24))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 96)

        view.setMarkedText("ㅇ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(view.hasMarkedText())

        let source = try terminalInputViewSource()
        let setMarkedTextStart = try XCTUnwrap(source.range(of: "func setMarkedText"))
        let unmarkTextStart = try XCTUnwrap(source.range(of: "func unmarkText"))
        let setMarkedTextSource = source[setMarkedTextStart.lowerBound..<unmarkTextStart.lowerBound]
        XCTAssertTrue(setMarkedTextSource.contains("needsDisplay = true"))
    }

    func testPromptInputViewNewlineCommandSendsCarriageReturn() throws {
        let source = try terminalInputViewSource()
        let doCommandStart = try XCTUnwrap(source.range(of: "override func doCommand"))
        let setMarkedTextStart = try XCTUnwrap(source.range(of: "func setMarkedText"))
        let doCommandSource = source[doCommandStart.lowerBound..<setMarkedTextStart.lowerBound]

        XCTAssertTrue(doCommandSource.contains("case #selector(insertNewline(_:)):\n            core.feed(\"\\r\")"))
        XCTAssertFalse(doCommandSource.contains("case #selector(insertNewline(_:)):\n            core.feed(\"\\n\")"))
    }

    func testReturnUsesTerminalEnterAction() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\r")
    }

    func testShiftReturnUsesLineFeedInsteadOfTerminalEnterAction() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\n")
    }

    @MainActor
    func testShiftReturnBypassesTextInputContextWhenNoCompositionIsActive() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        XCTAssertFalse(TerminalTextInputRouter.handleKeyDown(event, in: NSView(), hasMarkedText: false))
    }

    func testKeypadEnterUsesTerminalEnterActionWithNumericPadFlag() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .numericPad,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 76
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\r")
    }

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

    private func terminalInputViewSource() throws -> String {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/KurottyApp/TerminalInputView.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }
}
