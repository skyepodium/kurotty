import AppKit

enum TerminalPaneFocusDirection {
    case left
    case right
    case up
    case down
}

enum TerminalCommandDispatcher {
    private enum KeyCode {
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    @MainActor
    static func dispatchWindowCommand(from view: NSView, event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        guard hasCommand,
              let controller = view.window?.windowController as? TerminalWindowController
        else {
            return false
        }

        if flags.subtracting([.command, .option, .numericPad, .function]).isEmpty,
           let direction = paneFocusDirection(forKeyCode: event.keyCode) {
            controller.focusPane(direction)
            return true
        }

        let hasOnlyCommandModifiers = flags.subtracting([.command, .shift]).isEmpty
        guard hasCommand,
              hasOnlyCommandModifiers,
              let characters = TerminalTextInputRouter.latinKeyEquivalent(for: event)
        else {
            return false
        }

        let isShiftPressed = flags.contains(.shift)
        switch characters {
        case "t" where !isShiftPressed:
            controller.newTab()
            return true
        case "d":
            if isShiftPressed {
                controller.splitHorizontally()
            } else {
                controller.splitVertically()
            }
            return true
        case "w":
            if isShiftPressed {
                controller.closeCurrentPane()
            } else {
                controller.closeCurrentPane()
            }
            return true
        case "[" where isShiftPressed:
            controller.selectPreviousTab()
            return true
        case "]" where isShiftPressed:
            controller.selectNextTab()
            return true
        default:
            return false
        }
    }

    private static func paneFocusDirection(forKeyCode keyCode: UInt16) -> TerminalPaneFocusDirection? {
        switch keyCode {
        case KeyCode.leftArrow:
            return .left
        case KeyCode.rightArrow:
            return .right
        case KeyCode.downArrow:
            return .down
        case KeyCode.upArrow:
            return .up
        default:
            return nil
        }
    }
}
