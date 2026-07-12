import AppKit
import XCTest
@testable import KurottyApp

final class TerminalKeyEncoderTests: XCTestCase {
    func testTabAndShiftTabUseLegacyTerminalSequences() throws {
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try tabEvent()), "\t")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try tabEvent(modifiers: .shift)), "\u{1b}[Z")
    }

    func testPlainArrowsUseCsiSequences() throws {
        for arrow in arrowCases {
            XCTAssertEqual(TerminalKeyEncoder.sequence(for: try arrowEvent(arrow)), arrow.plain)
        }
    }

    func testApplicationCursorPlainArrowsUseSs3Sequences() throws {
        let state = TerminalKeyEncoder.State(applicationCursorKeys: true)

        for arrow in arrowCases {
            XCTAssertEqual(TerminalKeyEncoder.sequence(for: try arrowEvent(arrow), state: state), arrow.application)
        }
    }

    func testShiftArrowsUseXtermModifiedSequences() throws {
        for arrow in arrowCases {
            XCTAssertEqual(
                TerminalKeyEncoder.sequence(for: try arrowEvent(arrow, modifiers: [.shift, .numericPad])),
                arrow.shifted
            )
        }
    }

    func testControlAndShiftControlArrowsUseXtermModifiedSequences() throws {
        for arrow in arrowCases {
            XCTAssertEqual(
                TerminalKeyEncoder.sequence(for: try arrowEvent(arrow, modifiers: [.control, .numericPad])),
                arrow.control
            )
            XCTAssertEqual(
                TerminalKeyEncoder.sequence(for: try arrowEvent(arrow, modifiers: [.shift, .control, .numericPad])),
                arrow.shiftControl
            )
        }
    }

    func testNavigationKeysUseXtermSequences() throws {
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 115, character: NSHomeFunctionKey)), "\u{1b}[H")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 119, character: NSEndFunctionKey)), "\u{1b}[F")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 116, character: NSPageUpFunctionKey)), "\u{1b}[5~")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 121, character: NSPageDownFunctionKey)), "\u{1b}[6~")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 117, character: NSDeleteFunctionKey)), "\u{1b}[3~")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 114, character: NSInsertFunctionKey)), "\u{1b}[2~")
    }

    func testModifiedNavigationKeysUseXtermModifierSuffixes() throws {
        XCTAssertEqual(
            TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 116, character: NSPageUpFunctionKey, modifiers: .shift)),
            "\u{1b}[5;2~"
        )
        XCTAssertEqual(
            TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 121, character: NSPageDownFunctionKey, modifiers: .control)),
            "\u{1b}[6;5~"
        )
        XCTAssertEqual(
            TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 117, character: NSDeleteFunctionKey, modifiers: [.shift, .control])),
            "\u{1b}[3;6~"
        )
        XCTAssertEqual(
            TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 114, character: NSInsertFunctionKey, modifiers: .shift)),
            "\u{1b}[2;2~"
        )
    }

    func testFunctionKeysUseXtermLegacySequences() throws {
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 122, character: NSF1FunctionKey)), "\u{1b}OP")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 120, character: NSF2FunctionKey)), "\u{1b}OQ")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 99, character: NSF3FunctionKey)), "\u{1b}OR")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 118, character: NSF4FunctionKey)), "\u{1b}OS")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 96, character: NSF5FunctionKey)), "\u{1b}[15~")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 111, character: NSF12FunctionKey)), "\u{1b}[24~")
    }

    func testModifiedFunctionKeysUseXtermModifierSuffixes() throws {
        XCTAssertEqual(
            TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 122, character: NSF1FunctionKey, modifiers: .shift)),
            "\u{1b}[1;2P"
        )
        XCTAssertEqual(
            TerminalKeyEncoder.sequence(for: try functionEvent(keyCode: 96, character: NSF5FunctionKey, modifiers: .control)),
            "\u{1b}[15;5~"
        )
    }

    func testControlFallbackIncludesCommonShellHotkeysWhenCharactersAreMissing() throws {
        let expectedByKeyCode: [(UInt16, String)] = [
            (0, "\u{1}"),
            (11, "\u{2}"),
            (8, "\u{3}"),
            (2, "\u{4}"),
            (14, "\u{5}"),
            (3, "\u{6}"),
            (40, "\u{b}"),
            (37, "\u{c}"),
            (31, "\u{f}"),
            (32, "\u{15}"),
            (13, "\u{17}"),
        ]

        for (keyCode, expected) in expectedByKeyCode {
            XCTAssertEqual(
                TerminalKeyEncoder.sequence(for: try keyEvent(characters: "", modifiers: .control, keyCode: keyCode)),
                expected
            )
        }
    }

    func testApplicationKeypadUsesSs3WithoutChangingNormalKeypadInput() throws {
        let keypadOne = try keyEvent(
            characters: "1",
            modifiers: .numericPad,
            keyCode: 83
        )
        let keypadEnter = try keyEvent(
            characters: "\r",
            modifiers: .numericPad,
            keyCode: 76
        )

        XCTAssertNil(TerminalKeyEncoder.sequence(for: keypadOne))
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: keypadEnter), "\r")

        let application = TerminalKeyEncoder.State(applicationKeypad: true)
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: keypadOne, state: application), "\u{1b}Oq")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: keypadEnter, state: application), "\u{1b}OM")
    }

    func testModifyOtherKeysModeTwoSupportsXtermAndCsiUFormats() throws {
        let shiftControlA = try keyEvent(
            characters: "\u{1}",
            modifiers: [.shift, .control],
            charactersIgnoringModifiers: "A",
            keyCode: 0
        )
        let xterm = TerminalKeyEncoder.State(
            modifyOtherKeysMode: 2,
            extendedKeyFormat: .xterm
        )
        XCTAssertEqual(
            TerminalKeyEncoder.sequence(for: shiftControlA, state: xterm),
            "\u{1b}[27;6;65~"
        )
        XCTAssertEqual(
            TerminalKeyEncoder.sequence(for: try tabEvent(modifiers: .shift), state: xterm),
            "\u{1b}[27;2;9~"
        )

        let csiU = TerminalKeyEncoder.State(
            modifyOtherKeysMode: 2,
            extendedKeyFormat: .csiU
        )
        XCTAssertEqual(
            TerminalKeyEncoder.sequence(for: shiftControlA, state: csiU),
            "\u{1b}[65;6u"
        )
    }

    func testModifyOtherKeysModeOnePreservesLegacyMetaControlAndBacktab() throws {
        let state = TerminalKeyEncoder.State(modifyOtherKeysMode: 1)
        let optionA = try keyEvent(
            characters: "å",
            modifiers: .option,
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        let controlA = try keyEvent(
            characters: "\u{1}",
            modifiers: .control,
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )

        XCTAssertEqual(TerminalKeyEncoder.sequence(for: optionA, state: state), "\u{1b}a")
        XCTAssertEqual(TerminalKeyEncoder.sequence(for: controlA, state: state), "\u{1}")
        XCTAssertEqual(
            TerminalKeyEncoder.sequence(for: try tabEvent(modifiers: .shift), state: state),
            "\u{1b}[Z"
        )
    }

    private var arrowCases: [(keyCode: UInt16, character: Int, plain: String, application: String, shifted: String, control: String, shiftControl: String)] {
        [
            (123, NSLeftArrowFunctionKey, "\u{1b}[D", "\u{1b}OD", "\u{1b}[1;2D", "\u{1b}[1;5D", "\u{1b}[1;6D"),
            (124, NSRightArrowFunctionKey, "\u{1b}[C", "\u{1b}OC", "\u{1b}[1;2C", "\u{1b}[1;5C", "\u{1b}[1;6C"),
            (125, NSDownArrowFunctionKey, "\u{1b}[B", "\u{1b}OB", "\u{1b}[1;2B", "\u{1b}[1;5B", "\u{1b}[1;6B"),
            (126, NSUpArrowFunctionKey, "\u{1b}[A", "\u{1b}OA", "\u{1b}[1;2A", "\u{1b}[1;5A", "\u{1b}[1;6A"),
        ]
    }

    private func tabEvent(modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try keyEvent(characters: modifiers.contains(.shift) ? "\u{19}" : "\t", modifiers: modifiers, keyCode: 48)
    }

    private func arrowEvent(
        _ arrow: (keyCode: UInt16, character: Int, plain: String, application: String, shifted: String, control: String, shiftControl: String),
        modifiers: NSEvent.ModifierFlags = .numericPad
    ) throws -> NSEvent {
        try functionEvent(keyCode: arrow.keyCode, character: arrow.character, modifiers: modifiers)
    }

    private func functionEvent(
        keyCode: UInt16,
        character: Int,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let text = String(UnicodeScalar(character)!)
        return try keyEvent(characters: text, modifiers: modifiers, charactersIgnoringModifiers: text, keyCode: keyCode)
    }

    private func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String? = nil,
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
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
