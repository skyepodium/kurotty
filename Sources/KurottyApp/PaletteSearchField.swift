import AppKit

/// What a palette does with one keystroke that belongs to the list rather than
/// to the text field.
///
/// Split out from the field so the routing can be asserted without a window:
/// the mapping from an AppKit selector to a palette action is the part that was
/// wrong, and it is pure.
enum PaletteKeyCommand: Equatable {
    case moveSelection(Int)
    case execute(commandModifierHeld: Bool)
    case cancel

    /// AppKit's editing selectors, as the field editor reports them.
    ///
    /// `insertNewline:` covers both Return and Enter; the keypad key produces
    /// the same command, which is why neither is matched by key code here.
    static func command(
        forEditingSelector selector: Selector,
        commandModifierHeld: Bool
    ) -> PaletteKeyCommand? {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            return .moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            return .moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            return .execute(commandModifierHeld: commandModifierHeld)
        case #selector(NSResponder.cancelOperation(_:)):
            return .cancel
        default:
            return nil
        }
    }
}

/// The search field both palettes type into.
///
/// A palette's search field has to give arrow keys and Return away to the list
/// below it while keeping every other key for itself.
///
/// The interception has to happen in `control(_:textView:doCommandBy:)`, not in
/// `keyDown`. While an `NSSearchField` is being edited the first responder is
/// its *field editor*, so key events never reach the control's own `keyDown` —
/// which is why an override there silently does nothing and the list ignores
/// the arrow keys. The field editor turns the keystroke into an editing
/// selector and offers it to the control's delegate first; that is the hook.
///
/// Shared by the command palette and the project file palette so the two cannot
/// drift on what Down does.
final class PaletteSearchField: NSSearchField, NSSearchFieldDelegate {
    var onMoveSelection: ((Int) -> Void)?
    /// Carries whether Command was held, so a palette with a second activation
    /// can tell the two apart. A palette with only one action ignores the flag.
    var onExecuteSelection: ((_ commandModifierHeld: Bool) -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The field is its own delegate. Neither palette needs a delegate of
        // its own, and owning it here is what makes the key routing part of the
        // field rather than something each palette has to remember to wire.
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        // The modifier is read from the event AppKit is currently dispatching:
        // the selector says "a newline was inserted" and carries nothing about
        // which chord produced it.
        let commandModifierHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        guard let command = PaletteKeyCommand.command(
            forEditingSelector: commandSelector,
            commandModifierHeld: commandModifierHeld
        ) else {
            return false
        }
        perform(command)
        return true
    }

    /// Reached only when the field is not being edited — a click on the list
    /// moves first responder, and the arrow keys have to keep working there.
    override func keyDown(with event: NSEvent) {
        guard let command = PaletteKeyCommand.command(
            forKeyCode: event.keyCode,
            commandModifierHeld: event.modifierFlags.contains(.command)
        ) else {
            super.keyDown(with: event)
            return
        }
        perform(command)
    }

    private func perform(_ command: PaletteKeyCommand) {
        switch command {
        case let .moveSelection(offset):
            onMoveSelection?(offset)
        case let .execute(commandModifierHeld):
            onExecuteSelection?(commandModifierHeld)
        case .cancel:
            onCancel?()
        }
    }
}

extension PaletteKeyCommand {
    /// Key codes are used rather than characters because arrow keys have no
    /// stable character and Return has two — the main one and the keypad's.
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
    }

    static func command(forKeyCode keyCode: UInt16, commandModifierHeld: Bool) -> PaletteKeyCommand? {
        switch keyCode {
        case KeyCode.downArrow:
            return .moveSelection(1)
        case KeyCode.upArrow:
            return .moveSelection(-1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return .execute(commandModifierHeld: commandModifierHeld)
        case KeyCode.escape:
            return .cancel
        default:
            return nil
        }
    }
}
