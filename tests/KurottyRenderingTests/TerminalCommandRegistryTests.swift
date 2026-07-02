import AppKit
import XCTest
@testable import KurottyApp

final class TerminalCommandRegistryTests: XCTestCase {
    func testDefaultWindowCommandsExposeStableMetadata() {
        let commands = TerminalCommandRegistry.default.windowCommands
        let commandByID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })

        XCTAssertEqual(commandByID[.newTab]?.title, "New Tab")
        XCTAssertEqual(commandByID[.newTab]?.category, .tabs)
        XCTAssertEqual(commandByID[.newTab]?.shortcut?.keyEquivalent, "t")
        XCTAssertEqual(commandByID[.newTab]?.shortcut?.modifiers, [.command])

        XCTAssertEqual(commandByID[.splitVertically]?.title, "Split Vertically")
        XCTAssertEqual(commandByID[.splitVertically]?.category, .panes)
        XCTAssertEqual(commandByID[.splitVertically]?.shortcut?.keyEquivalent, "d")
        XCTAssertEqual(commandByID[.splitVertically]?.shortcut?.modifiers, [.command])

        XCTAssertEqual(commandByID[.splitHorizontally]?.title, "Split Horizontally")
        XCTAssertEqual(commandByID[.splitHorizontally]?.category, .panes)
        XCTAssertEqual(commandByID[.splitHorizontally]?.shortcut?.keyEquivalent, "d")
        XCTAssertEqual(commandByID[.splitHorizontally]?.shortcut?.modifiers, [.command, .shift])

        XCTAssertEqual(commandByID[.closeCurrentPane]?.title, "Close Pane")
        XCTAssertEqual(commandByID[.closeCurrentPane]?.category, .panes)
        XCTAssertEqual(commandByID[.closeCurrentPane]?.shortcut?.keyEquivalent, "w")
        XCTAssertEqual(commandByID[.closeCurrentPane]?.shortcut?.modifiers, [.command])

        XCTAssertEqual(commandByID[.selectPreviousTab]?.title, "Previous Tab")
        XCTAssertEqual(commandByID[.selectPreviousTab]?.category, .navigation)
        XCTAssertEqual(commandByID[.selectPreviousTab]?.shortcut?.keyEquivalent, "[")
        XCTAssertEqual(commandByID[.selectPreviousTab]?.shortcut?.modifiers, [.command, .shift])

        XCTAssertEqual(commandByID[.selectNextTab]?.title, "Next Tab")
        XCTAssertEqual(commandByID[.selectNextTab]?.category, .navigation)
        XCTAssertEqual(commandByID[.selectNextTab]?.shortcut?.keyEquivalent, "]")
        XCTAssertEqual(commandByID[.selectNextTab]?.shortcut?.modifiers, [.command, .shift])

        XCTAssertEqual(commandByID[.focusPaneLeft]?.title, "Focus Pane Left")
        XCTAssertEqual(commandByID[.focusPaneLeft]?.category, .navigation)
        XCTAssertEqual(commandByID[.focusPaneLeft]?.shortcut?.keyCode, 123)
        XCTAssertEqual(commandByID[.focusPaneLeft]?.shortcut?.modifiers, [.command])
    }

    func testDefaultWindowCommandIDsAreUnique() {
        let ids = TerminalCommandRegistry.default.windowCommands.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testShortcutLookupFindsDefaultCommands() throws {
        let registry = TerminalCommandRegistry.default

        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("t", modifiers: .command))?.id, .newTab)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("d", modifiers: .command))?.id, .splitVertically)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("D", modifiers: [.command, .shift], charactersIgnoringModifiers: "d"))?.id, .splitHorizontally)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("w", modifiers: .command))?.id, .closeCurrentPane)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("W", modifiers: [.command, .shift], charactersIgnoringModifiers: "w"))?.id, .closeCurrentPane)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("{", modifiers: [.command, .shift], charactersIgnoringModifiers: "["))?.id, .selectPreviousTab)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("}", modifiers: [.command, .shift], charactersIgnoringModifiers: "]"))?.id, .selectNextTab)
        XCTAssertEqual(registry.windowCommand(matching: try arrowEvent(keyCode: 123, modifiers: .command))?.id, .focusPaneLeft)
        XCTAssertEqual(registry.windowCommand(matching: try arrowEvent(keyCode: 124, modifiers: [.command, .option, .numericPad]))?.id, .focusPaneRight)
    }

    func testDispatcherUsesRegistryCommandMapping() throws {
        XCTAssertEqual(TerminalCommandDispatcher.windowCommand(for: try keyEvent("t", modifiers: .command))?.id, .newTab)
        XCTAssertEqual(TerminalCommandDispatcher.windowCommand(for: try keyEvent("d", modifiers: .command))?.action, .splitVertically)
        XCTAssertEqual(TerminalCommandDispatcher.windowCommand(for: try keyEvent("D", modifiers: [.command, .shift], charactersIgnoringModifiers: "d"))?.action, .splitHorizontally)
        XCTAssertEqual(TerminalCommandDispatcher.windowCommand(for: try arrowEvent(keyCode: 126, modifiers: [.command, .numericPad]))?.action, .focusPane(.up))
    }

    private func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String? = nil,
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func arrowEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        let character: unichar
        switch keyCode {
        case 123:
            character = unichar(NSLeftArrowFunctionKey)
        case 124:
            character = unichar(NSRightArrowFunctionKey)
        case 125:
            character = unichar(NSDownArrowFunctionKey)
        case 126:
            character = unichar(NSUpArrowFunctionKey)
        default:
            character = 0
        }
        let text = String(UnicodeScalar(character)!)
        return try keyEvent(text, modifiers: modifiers, charactersIgnoringModifiers: text, keyCode: keyCode)
    }
}
