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

        XCTAssertEqual(commandByID[.findTerminalOutput]?.title, "Find Terminal Output")
        XCTAssertEqual(commandByID[.findTerminalOutput]?.category, .navigation)
        XCTAssertEqual(commandByID[.findTerminalOutput]?.shortcut?.keyEquivalent, "f")
        XCTAssertEqual(commandByID[.findTerminalOutput]?.shortcut?.modifiers, [.command])

        XCTAssertEqual(commandByID[.focusPaneLeft]?.title, "Focus Pane Left")
        XCTAssertEqual(commandByID[.focusPaneLeft]?.category, .navigation)
        XCTAssertEqual(commandByID[.focusPaneLeft]?.shortcut?.keyCode, 123)
        XCTAssertEqual(commandByID[.focusPaneLeft]?.shortcut?.modifiers, [.command])
    }

    func testDefaultWindowCommandIDsAreUnique() {
        let ids = TerminalCommandRegistry.default.windowCommands.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTmuxControlRegistryAddsAdvancedCommandsWithoutChangingDefaultRegistry() {
        let defaultIDs = Set(TerminalCommandRegistry.default.windowCommands.map(\.id))
        let tmuxCommands = TerminalCommandRegistry.tmuxControl.windowCommands
        let tmuxIDs = Set(tmuxCommands.map(\.id))

        XCTAssertFalse(defaultIDs.contains(.tmuxToggleZoom))
        XCTAssertTrue(tmuxIDs.contains(.tmuxToggleZoom))
        XCTAssertTrue(tmuxIDs.contains(.tmuxSwapPanePrevious))
        XCTAssertTrue(tmuxIDs.contains(.tmuxRotateWindowNext))
        XCTAssertTrue(tmuxIDs.contains(.tmuxEvenHorizontalLayout))
        XCTAssertTrue(tmuxIDs.contains(.tmuxDetachClient))
        XCTAssertEqual(tmuxIDs.count, tmuxCommands.count)
    }

    func testDefaultCommandSpanCommandsExposeStableMetadata() {
        let commands = TerminalCommandRegistry.default.commandSpanCommands
        let commandByID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })

        XCTAssertEqual(commandByID[.foldOutput]?.title, "Fold Command Output")
        XCTAssertEqual(commandByID[.foldOutput]?.category, .commandSpans)
        XCTAssertEqual(commandByID[.foldOutput]?.action, .foldOutput)
        XCTAssertEqual(commandByID[.foldOutput]?.approvalPolicy, .some(.none))
        XCTAssertTrue(commandByID[.foldOutput]?.searchTokens.contains("collapse command output") == true)

        XCTAssertEqual(commandByID[.copyReference]?.title, "Copy Command Reference")
        XCTAssertEqual(commandByID[.copyReference]?.category, .commandSpans)
        XCTAssertEqual(commandByID[.copyReference]?.action, .copyReference)
        XCTAssertEqual(commandByID[.copyReference]?.approvalPolicy, .some(.none))
        XCTAssertTrue(commandByID[.copyReference]?.searchTokens.contains("copy span reference") == true)

        XCTAssertEqual(commandByID[.replay]?.title, "Replay Command")
        XCTAssertEqual(commandByID[.replay]?.category, .commandSpans)
        XCTAssertEqual(commandByID[.replay]?.action, .replay)
        XCTAssertEqual(commandByID[.replay]?.approvalPolicy, .explicitUserConfirmation)
        XCTAssertTrue(commandByID[.replay]?.searchTokens.contains("rerun command") == true)
    }

    func testDefaultCommandSpanCommandIDsAreUnique() {
        let ids = TerminalCommandRegistry.default.commandSpanCommands.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testShortcutLookupFindsDefaultCommands() throws {
        let registry = TerminalCommandRegistry.default

        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("t", modifiers: .command))?.id, .newTab)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("d", modifiers: .command))?.id, .splitVertically)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("D", modifiers: [.command, .shift], charactersIgnoringModifiers: "d"))?.id, .splitHorizontally)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("w", modifiers: .command))?.id, .closeCurrentPane)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("f", modifiers: .command))?.id, .findTerminalOutput)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("W", modifiers: [.command, .shift], charactersIgnoringModifiers: "w"))?.id, .closeCurrentPane)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("{", modifiers: [.command, .shift], charactersIgnoringModifiers: "["))?.id, .selectPreviousTab)
        XCTAssertEqual(registry.windowCommand(matching: try keyEvent("}", modifiers: [.command, .shift], charactersIgnoringModifiers: "]"))?.id, .selectNextTab)
        XCTAssertEqual(registry.windowCommand(matching: try arrowEvent(keyCode: 123, modifiers: .command))?.id, .focusPaneLeft)
        XCTAssertEqual(registry.windowCommand(matching: try arrowEvent(keyCode: 124, modifiers: [.command, .option, .numericPad]))?.id, .focusPaneRight)
    }

    func testShortcutLookupIgnoresCapsLockState() throws {
        let registry = TerminalCommandRegistry.default

        XCTAssertEqual(
            registry.windowCommand(matching: try keyEvent("t", modifiers: [.capsLock, .command]))?.id,
            .newTab
        )
        XCTAssertEqual(
            registry.windowCommand(matching: try keyEvent("f", modifiers: [.capsLock, .command]))?.id,
            .findTerminalOutput
        )
        XCTAssertEqual(
            registry.windowCommand(
                matching: try keyEvent(
                    "D",
                    modifiers: [.capsLock, .command, .shift],
                    charactersIgnoringModifiers: "d"
                )
            )?.id,
            .splitHorizontally
        )
        XCTAssertEqual(
            registry.windowCommand(
                matching: try arrowEvent(
                    keyCode: 123,
                    modifiers: [.capsLock, .command, .numericPad]
                )
            )?.id,
            .focusPaneLeft
        )
    }

    func testDispatcherUsesRegistryCommandMapping() throws {
        XCTAssertEqual(TerminalCommandDispatcher.windowCommand(for: try keyEvent("t", modifiers: .command))?.id, .newTab)
        XCTAssertEqual(TerminalCommandDispatcher.windowCommand(for: try keyEvent("f", modifiers: .command))?.action, .findTerminalOutput)
        XCTAssertEqual(TerminalCommandDispatcher.windowCommand(for: try keyEvent("d", modifiers: .command))?.action, .splitVertically)
        XCTAssertEqual(TerminalCommandDispatcher.windowCommand(for: try keyEvent("D", modifiers: [.command, .shift], charactersIgnoringModifiers: "d"))?.action, .splitHorizontally)
        XCTAssertEqual(TerminalCommandDispatcher.windowCommand(for: try arrowEvent(keyCode: 126, modifiers: [.command, .numericPad]))?.action, .focusPane(.up))
    }

    func testCommandSpanLookupUsesRegistryCommandMapping() {
        let registry = TerminalCommandRegistry.default

        XCTAssertEqual(registry.commandSpanCommand(for: .foldOutput)?.title, "Fold Command Output")
        XCTAssertEqual(registry.commandSpanCommand(for: .copyReference)?.approvalPolicy, .some(.none))
        XCTAssertEqual(registry.commandSpanCommand(for: .replay)?.approvalPolicy, .explicitUserConfirmation)
    }

    func testCommandSpanDispatcherRequiresReplayConfirmationMetadataBeforeHandler() {
        let replay = TerminalCommandRegistry.default.commandSpanCommand(for: .replay)!
        let candidate = TerminalCommandReplayCandidate(
            spanID: 9,
            reference: TerminalCommandSpanReference(
                spanID: 9,
                startBoundarySequence: 20,
                endBoundarySequence: 24
            ),
            commandText: "swift test",
            cwd: "/repo",
            exitCode: 0,
            requiresExplicitUserConfirmation: true
        )
        var replayedCommands: [String] = []
        let handlers = TerminalCommandSpanDispatchHandlers(
            replay: { candidate, approval in
                replayedCommands.append("\(candidate.commandText):\(approval.isExplicitlyConfirmed)")
            }
        )

        let blocked = TerminalCommandDispatcher.execute(
            replay,
            context: .replay(candidate, approval: .init(isExplicitlyConfirmed: false)),
            handlers: handlers
        )
        let dispatched = TerminalCommandDispatcher.execute(
            replay,
            context: .replay(candidate, approval: .init(isExplicitlyConfirmed: true)),
            handlers: handlers
        )

        XCTAssertEqual(blocked, .requiresApproval)
        XCTAssertEqual(dispatched, .dispatched)
        XCTAssertEqual(replayedCommands, ["swift test:true"])
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
