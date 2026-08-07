import AppKit
import XCTest
@testable import KurottyApp

/// Keystroke routing for both palettes.
///
/// This exists because the original routing was silently dead: the field
/// intercepted keys in `keyDown`, which an `NSSearchField` never receives while
/// it is being edited, so arrow keys and Return did nothing and the only way to
/// pick a row was a double-click. The editing-selector path is the one that
/// actually runs, and it is what these tests pin.
final class PaletteSearchFieldTests: XCTestCase {
    // MARK: - Editing selectors

    func testTheArrowKeysMoveTheSelectionOneRow() {
        XCTAssertEqual(
            PaletteKeyCommand.command(
                forEditingSelector: #selector(NSResponder.moveDown(_:)),
                commandModifierHeld: false
            ),
            .moveSelection(1)
        )
        XCTAssertEqual(
            PaletteKeyCommand.command(
                forEditingSelector: #selector(NSResponder.moveUp(_:)),
                commandModifierHeld: false
            ),
            .moveSelection(-1)
        )
    }

    func testReturnExecutesAndCarriesWhetherCommandWasHeld() {
        // The selector says only that a newline was inserted, so the modifier
        // has to be threaded separately for a palette with two activations.
        XCTAssertEqual(
            PaletteKeyCommand.command(
                forEditingSelector: #selector(NSResponder.insertNewline(_:)),
                commandModifierHeld: false
            ),
            .execute(commandModifierHeld: false)
        )
        XCTAssertEqual(
            PaletteKeyCommand.command(
                forEditingSelector: #selector(NSResponder.insertNewline(_:)),
                commandModifierHeld: true
            ),
            .execute(commandModifierHeld: true)
        )
    }

    func testEscapeCancels() {
        XCTAssertEqual(
            PaletteKeyCommand.command(
                forEditingSelector: #selector(NSResponder.cancelOperation(_:)),
                commandModifierHeld: false
            ),
            .cancel
        )
    }

    func testAnOrdinaryEditingSelectorIsLeftToTheTextField() {
        // Everything the palette does not claim has to fall through, or typing
        // stops working.
        for selector in [
            #selector(NSResponder.deleteBackward(_:)),
            #selector(NSResponder.moveLeft(_:)),
            #selector(NSResponder.moveRight(_:)),
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.selectAll(_:)),
        ] {
            XCTAssertNil(
                PaletteKeyCommand.command(forEditingSelector: selector, commandModifierHeld: false),
                "\(selector) should belong to the text field"
            )
        }
    }

    // MARK: - Key codes

    func testTheKeyCodePathAgreesWithTheEditingSelectorPath() {
        // Both routes reach the same list, so they must not be able to disagree
        // about what a key does.
        let pairs: [(UInt16, Selector)] = [
            (125, #selector(NSResponder.moveDown(_:))),
            (126, #selector(NSResponder.moveUp(_:))),
            (36, #selector(NSResponder.insertNewline(_:))),
            (53, #selector(NSResponder.cancelOperation(_:))),
        ]
        for (keyCode, selector) in pairs {
            XCTAssertEqual(
                PaletteKeyCommand.command(forKeyCode: keyCode, commandModifierHeld: false),
                PaletteKeyCommand.command(forEditingSelector: selector, commandModifierHeld: false),
                "key code \(keyCode) and \(selector) disagree"
            )
        }
    }

    func testTheKeypadEnterKeyExecutesLikeTheMainReturnKey() {
        XCTAssertEqual(
            PaletteKeyCommand.command(forKeyCode: 76, commandModifierHeld: false),
            .execute(commandModifierHeld: false)
        )
    }

    func testAPrintableKeyCodeIsNotAPaletteCommand() {
        // Key code 0 is `a`. If it resolved to anything the field would stop
        // accepting text.
        XCTAssertNil(PaletteKeyCommand.command(forKeyCode: 0, commandModifierHeld: false))
    }

    // MARK: - Wiring

    @MainActor
    func testTheFieldOwnsItsOwnDelegateSoNeitherPaletteHasToWireIt() {
        let field = PaletteSearchField(frame: .zero)
        XCTAssertTrue(field.delegate === field)
    }

    @MainActor
    func testAnEditingSelectorTheFieldClaimsIsNotPassedOnToTheTextField() {
        // Returning `true` is what stops the field editor from also inserting a
        // newline into the query.
        let field = PaletteSearchField(frame: .zero)
        var movedBy: Int?
        field.onMoveSelection = { movedBy = $0 }

        let handled = field.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(movedBy, 1)
    }

    @MainActor
    func testAnUnclaimedEditingSelectorIsHandedBackToTheTextField() {
        let field = PaletteSearchField(frame: .zero)
        let handled = field.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        )
        XCTAssertFalse(handled)
    }
}
