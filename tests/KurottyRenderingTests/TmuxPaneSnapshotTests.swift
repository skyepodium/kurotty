import AppKit
import Foundation
import XCTest
@testable import KurottyApp

final class TmuxPaneSnapshotTests: XCTestCase {
    private final class StubSession: TerminalSession {
        var onOutput: ((String) -> Void)?
        var onRawOutput: ((Data) -> Void)?
        var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
        var onExit: ((Int32) -> Void)?
        var writes: [String] = []

        func start(workingDirectory: String) {}
        func write(_ text: String) { writes.append(text) }
        func foregroundProcessName() -> String? { "tmux" }
        func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    func testStateParserUsesActualTabsAndDecodesAllPendingOctets() throws {
        let stateLine = [
            "pane_id=%7", "pane_width=120", "pane_height=40", "alternate_on=1",
            "alternate_saved_x=9", "alternate_saved_y=4", "cursor_x=17", "cursor_y=8",
            "scroll_region_upper=2", "scroll_region_lower=31", "pane_tabs=3,11,19",
            "cursor_flag=0", "insert_flag=1", "origin_flag=1", "keypad_cursor_flag=1", "keypad_flag=1",
            "wrap_flag=0", "mouse_standard_flag=1", "mouse_button_flag=1", "mouse_any_flag=0",
            "mouse_utf8_flag=1", "mouse_sgr_flag=0", "bracket_paste_flag=1", "pane_key_mode=Ext 2",
            "extended_keys_format=csi-u", "session_attached=2",
        ].joined(separator: "\t")

        let state = try XCTUnwrap(TmuxPaneTerminalState.parse(stateLine, expectedPaneID: "%7"))
        XCTAssertEqual(state.width, 120)
        XCTAssertEqual(state.height, 40)
        XCTAssertTrue(state.alternateOn)
        XCTAssertEqual(state.alternateSavedX, 9)
        XCTAssertEqual(state.alternateSavedY, 4)
        XCTAssertEqual(state.cursorX, 17)
        XCTAssertEqual(state.cursorY, 8)
        XCTAssertEqual(state.tabStops, [3, 11, 19])
        XCTAssertFalse(state.cursorVisible)
        XCTAssertTrue(state.insertMode)
        XCTAssertTrue(state.originMode)
        XCTAssertTrue(state.applicationCursorKeys)
        XCTAssertTrue(state.applicationKeypad)
        XCTAssertFalse(state.wraparound)
        XCTAssertTrue(state.mouseUTF8)
        XCTAssertTrue(state.bracketedPaste)
        XCTAssertEqual(state.paneKeyMode, "Ext 2")
        XCTAssertEqual(state.extendedKeyFormat, .csiU)
        XCTAssertEqual(state.attachedClientCount, 2)

        XCTAssertEqual(
            TmuxPendingOutputDecoder.decode(Data("\\033]0;caf\\303\\251".utf8)),
            Data([0x1b]) + Data("]0;café".utf8)
        )
    }

    func testSnapshotReplayIsBoundedAndOrdersScreensStatePendingThenDeltas() {
        var state = TmuxPaneTerminalState()
        state.paneID = "%1"
        state.alternateOn = true
        state.alternateSavedX = 2
        state.alternateSavedY = 1
        state.cursorX = 4
        state.cursorY = 3
        state.tabStops = [8, 16]
        let currentAlt = Data("CURRENT-ALT".utf8)
        let savedPrimary = Data("SAVED-PRIMARY".utf8)
        let pending = Data("\u{1b}]0;".utf8)
        let snapshot = TmuxPaneSnapshot(
            currentScreen: currentAlt,
            alternateScreen: savedPrimary,
            terminalState: state,
            pendingOutput: pending,
            byteLimit: 4_096
        )

        XCTAssertEqual(snapshot.primaryScreen, savedPrimary)
        XCTAssertEqual(snapshot.alternateScreen, currentAlt)
        XCTAssertLessThanOrEqual(snapshot.replayData.count, 4_096)
        let primaryRange = try! XCTUnwrap(snapshot.replayData.range(of: savedPrimary))
        let altRange = try! XCTUnwrap(snapshot.replayData.range(of: currentAlt))
        let pendingRange = try! XCTUnwrap(snapshot.replayData.range(of: pending))
        XCTAssertLessThan(primaryRange.lowerBound, altRange.lowerBound)
        XCTAssertLessThan(altRange.lowerBound, pendingRange.lowerBound)
        XCTAssertEqual(pendingRange.upperBound, snapshot.replayData.endIndex)

        var pane = TmuxPaneState(id: "%1", outputHistoryByteLimit: 4_096)
        pane.installSnapshot(snapshot)
        pane.appendOutput(Data("title\u{7}".utf8))
        XCTAssertEqual(pane.output.suffix(pending.count + 6), pending + Data("title\u{7}".utf8))
    }

    @MainActor
    func testRestorePlacesCursorMidScreenBeforeSubsequentOutput() {
        let surface = TerminalSurfaceView(frame: .init(x: 0, y: 0, width: 800, height: 500), session: StubSession())
        var state = TmuxPaneTerminalState()
        state.paneID = "%1"
        state.cursorX = 3
        state.cursorY = 2
        state.tabStops = [8, 16]
        let snapshot = TmuxPaneSnapshot(
            currentScreen: Data("first\r\nsecond".utf8),
            alternateScreen: Data(),
            terminalState: state,
            pendingOutput: Data(),
            byteLimit: 4_096
        )

        surface.consumeTmuxRestoreOutputForTesting(snapshot.replayData)
        surface.consumeTmuxRestoreOutputForTesting(Data("X".utf8))
        let restored = surface.tmuxRestoreStateForTesting
        XCTAssertEqual(restored.cursorRow, 2)
        XCTAssertEqual(restored.cursorColumn, 4)
        XCTAssertEqual(Array(restored.visibleLines[2])[3], "X")
    }

    @MainActor
    func testRestoreRebuildsAlternateScreenAndRestoresPrimaryCursorOnExit() {
        let surface = TerminalSurfaceView(frame: .init(x: 0, y: 0, width: 800, height: 500), session: StubSession())
        var state = TmuxPaneTerminalState()
        state.paneID = "%1"
        state.alternateOn = true
        state.alternateSavedX = 2
        state.alternateSavedY = 1
        state.cursorX = 4
        state.cursorY = 0
        state.tabStops = [8]
        let snapshot = TmuxPaneSnapshot(
            currentScreen: Data("ALT".utf8),
            alternateScreen: Data("PRIMARY".utf8),
            terminalState: state,
            pendingOutput: Data(),
            byteLimit: 4_096
        )

        surface.consumeTmuxRestoreOutputForTesting(snapshot.replayData)
        XCTAssertTrue(surface.tmuxRestoreStateForTesting.isUsingAlternateScreen)
        XCTAssertTrue(surface.tmuxRestoreStateForTesting.visibleLines[0].hasPrefix("ALT"))

        surface.consumeTmuxRestoreOutputForTesting(Data("\u{1b}[?1049l".utf8))
        let primary = surface.tmuxRestoreStateForTesting
        XCTAssertFalse(primary.isUsingAlternateScreen)
        XCTAssertTrue(primary.visibleLines[0].hasPrefix("PRIMARY"))
        XCTAssertEqual(primary.cursorRow, 1)
        XCTAssertEqual(primary.cursorColumn, 2)
    }

    @MainActor
    func testRestoreAppliesInsertWrapTabsAndApplicationKeyModes() {
        let surface = TerminalSurfaceView(frame: .init(x: 0, y: 0, width: 800, height: 500), session: StubSession())
        var state = TmuxPaneTerminalState()
        state.paneID = "%1"
        state.insertMode = true
        state.wraparound = false
        state.applicationCursorKeys = true
        state.applicationKeypad = true
        state.tabStops = [3]
        let snapshot = TmuxPaneSnapshot(
            currentScreen: Data(),
            alternateScreen: Data(),
            terminalState: state,
            pendingOutput: Data(),
            byteLimit: 4_096
        )
        surface.consumeTmuxRestoreOutputForTesting(snapshot.replayData)

        var restored = surface.tmuxRestoreStateForTesting
        XCTAssertTrue(restored.insertModeEnabled)
        XCTAssertFalse(restored.wraparoundModeEnabled)
        XCTAssertTrue(restored.applicationCursorKeysEnabled)
        XCTAssertTrue(restored.applicationKeypadEnabled)
        XCTAssertEqual(restored.tabStops.filter { $0 < state.width }, [3])
        XCTAssertTrue(restored.tabStops.contains(80), "default future tab stops survive a narrow snapshot")
        XCTAssertEqual(surface.terminalSequenceForTesting(#selector(NSResponder.moveUp(_:))), "\u{1b}OA")

        surface.consumeTmuxRestoreOutputForTesting(Data("\u{1b}[1;1Habc\u{1b}[1;2HZ".utf8))
        restored = surface.tmuxRestoreStateForTesting
        XCTAssertTrue(restored.visibleLines[0].hasPrefix("aZbc"))

        surface.consumeTmuxRestoreOutputForTesting(Data("\u{1b}[2;1H\tX".utf8))
        restored = surface.tmuxRestoreStateForTesting
        XCTAssertEqual(Array(restored.visibleLines[1])[3], "X")

        let lastColumn = restored.visibleLines[2].count
        surface.consumeTmuxRestoreOutputForTesting(Data("\u{1b}[3;\(lastColumn)HXY".utf8))
        restored = surface.tmuxRestoreStateForTesting
        XCTAssertEqual(Array(restored.visibleLines[2])[lastColumn - 1], "Y")
        XCTAssertEqual(restored.cursorRow, 2)
        XCTAssertEqual(restored.cursorColumn, lastColumn - 1)
    }

    func testAlternateCursorSentinelUses1047WithoutInventingSavedCursor() throws {
        let stateLine = [
            "pane_id=%7", "pane_width=80", "pane_height=24", "alternate_on=1",
            "alternate_saved_x=4294967295", "alternate_saved_y=4294967295",
            "cursor_x=4", "cursor_y=2", "scroll_region_upper=0", "scroll_region_lower=23",
        ].joined(separator: "\t")
        let state = try XCTUnwrap(TmuxPaneTerminalState.parse(stateLine, expectedPaneID: "%7"))
        XCTAssertNil(state.alternateSavedX)
        XCTAssertNil(state.alternateSavedY)

        let snapshot = TmuxPaneSnapshot(
            currentScreen: Data("ALT".utf8),
            alternateScreen: Data("PRIMARY".utf8),
            terminalState: state,
            pendingOutput: Data(),
            byteLimit: 4_096
        )
        XCTAssertNotNil(snapshot.replayData.range(of: Data("\u{1b}[?1047h".utf8)))
        XCTAssertNil(snapshot.replayData.range(of: Data("\u{1b}[?1049h".utf8)))
    }

    @MainActor
    func testAlternateCursorSentinelDoesNotRestoreSyntheticCursorOnExit() throws {
        let surface = TerminalSurfaceView(
            frame: .init(x: 0, y: 0, width: 800, height: 500),
            session: StubSession()
        )
        let stateLine = [
            "pane_id=%7", "pane_width=80", "pane_height=24", "alternate_on=1",
            "alternate_saved_x=4294967295", "alternate_saved_y=4294967295",
            "cursor_x=4", "cursor_y=2", "scroll_region_upper=0", "scroll_region_lower=23",
        ].joined(separator: "\t")
        let state = try XCTUnwrap(TmuxPaneTerminalState.parse(stateLine, expectedPaneID: "%7"))
        let snapshot = TmuxPaneSnapshot(
            currentScreen: Data("ALT".utf8),
            alternateScreen: Data("PRIMARY".utf8),
            terminalState: state,
            pendingOutput: Data(),
            byteLimit: 4_096
        )

        surface.consumeTmuxRestoreOutputForTesting(snapshot.replayData)
        surface.consumeTmuxRestoreOutputForTesting(Data("\u{1b}[?1047l".utf8))
        let restored = surface.tmuxRestoreStateForTesting
        XCTAssertFalse(restored.isUsingAlternateScreen)
        XCTAssertTrue(restored.visibleLines[0].hasPrefix("PRIMARY"))
        XCTAssertEqual(restored.cursorRow, 2)
        XCTAssertEqual(restored.cursorColumn, 4)
    }

    @MainActor
    func testRestoreHonorsOriginModeAndRelativeCursorAddressing() {
        let surface = TerminalSurfaceView(
            frame: .init(x: 0, y: 0, width: 800, height: 500),
            session: StubSession()
        )
        var state = TmuxPaneTerminalState()
        state.paneID = "%1"
        state.height = 24
        state.scrollRegionUpper = 2
        state.scrollRegionLower = 10
        state.originMode = true
        state.cursorX = 5
        state.cursorY = 6
        let snapshot = TmuxPaneSnapshot(
            currentScreen: Data(),
            alternateScreen: Data(),
            terminalState: state,
            pendingOutput: Data(),
            byteLimit: 4_096
        )

        surface.consumeTmuxRestoreOutputForTesting(snapshot.replayData)
        var restored = surface.tmuxRestoreStateForTesting
        XCTAssertTrue(restored.originModeEnabled)
        XCTAssertEqual(restored.cursorRow, 6)
        XCTAssertEqual(restored.cursorColumn, 5)

        surface.consumeTmuxRestoreOutputForTesting(Data("\u{1b}[1;1H".utf8))
        restored = surface.tmuxRestoreStateForTesting
        XCTAssertEqual(restored.cursorRow, 2)
        XCTAssertEqual(restored.cursorColumn, 0)
    }

    @MainActor
    func testRestorePreservesFutureDefaultTabStopsAcrossGrowth() throws {
        let surface = TerminalSurfaceView(
            frame: .init(x: 0, y: 0, width: 260, height: 300),
            session: StubSession()
        )
        surface.layout()
        let narrowColumns = surface.currentTerminalSize.columns
        var state = TmuxPaneTerminalState()
        state.paneID = "%1"
        state.width = narrowColumns
        state.tabStops = [3]
        let snapshot = TmuxPaneSnapshot(
            currentScreen: Data(),
            alternateScreen: Data(),
            terminalState: state,
            pendingOutput: Data(),
            byteLimit: 4_096
        )
        surface.consumeTmuxRestoreOutputForTesting(snapshot.replayData)

        let futureStop = try XCTUnwrap(
            surface.tmuxRestoreStateForTesting.tabStops.filter { $0 >= narrowColumns }.min()
        )
        surface.frame = .init(x: 0, y: 0, width: 900, height: 300)
        surface.layout()
        XCTAssertGreaterThan(surface.currentTerminalSize.columns, futureStop)
        surface.consumeTmuxRestoreOutputForTesting(Data("\u{1b}[1;1H\t\tX".utf8))

        let restored = surface.tmuxRestoreStateForTesting
        XCTAssertEqual(Array(restored.visibleLines[0])[futureStop], "X")
        XCTAssertEqual(restored.cursorColumn, futureStop + 1)
    }

    @MainActor
    func testRestoreAppliesExtendedKeysMouseAndBracketedPasteModes() throws {
        let surface = TerminalSurfaceView(
            frame: .init(x: 0, y: 0, width: 800, height: 500),
            session: StubSession()
        )
        var state = TmuxPaneTerminalState()
        state.paneID = "%1"
        state.paneKeyMode = "Ext 2"
        state.extendedKeyFormat = .csiU
        state.mouseButton = true
        state.mouseUTF8 = true
        state.bracketedPaste = true
        let snapshot = TmuxPaneSnapshot(
            currentScreen: Data(),
            alternateScreen: Data(),
            terminalState: state,
            pendingOutput: Data(),
            byteLimit: 4_096
        )
        surface.consumeTmuxRestoreOutputForTesting(snapshot.replayData)

        let restored = surface.tmuxRestoreStateForTesting
        XCTAssertEqual(restored.modifyOtherKeysMode, 2)
        XCTAssertEqual(restored.extendedKeyFormat, .csiU)
        XCTAssertTrue(restored.bracketedPasteEnabled)
        XCTAssertEqual(restored.mouseTrackingMode, .buttonMotion)
        XCTAssertTrue(restored.mouseUsesUTF8)
        XCTAssertFalse(restored.mouseUsesSGR)

        let event = try keyEvent(
            characters: "\u{1}",
            charactersIgnoringModifiers: "A",
            modifiers: [.shift, .control],
            keyCode: 0
        )
        XCTAssertEqual(surface.terminalSequenceForTesting(event), "\u{1b}[65;6u")
    }

    func testTinyReplayLimitsNeverSplitUtf8OrControlSequences() {
        var state = TmuxPaneTerminalState()
        state.paneID = "%1"
        state.paneKeyMode = "Ext 2"
        let validMinimalReplays: Set<Data> = [
            Data(),
            Data("\u{1b}c".utf8),
            Data("\u{1b}c\u{1b}[3J".utf8),
        ]

        for limit in 0...32 {
            let snapshot = TmuxPaneSnapshot(
                currentScreen: Data("가나다".utf8),
                alternateScreen: Data(),
                terminalState: state,
                pendingOutput: Data("\u{1b}]0;제목\u{7}".utf8),
                byteLimit: limit
            )
            XCTAssertLessThanOrEqual(snapshot.replayData.count, limit)
            XCTAssertNotNil(String(data: snapshot.replayData, encoding: .utf8))
            XCTAssertTrue(validMinimalReplays.contains(snapshot.replayData))
        }
    }

    private func keyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
