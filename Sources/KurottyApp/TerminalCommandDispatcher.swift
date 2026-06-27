import AppKit

enum TerminalPaneFocusDirection {
    case left
    case right
    case up
    case down
}

enum TerminalCommandDispatcher {
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
              let characters = event.charactersIgnoringModifiers?.lowercased()
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
        case 123:
            return .left
        case 124:
            return .right
        case 125:
            return .down
        case 126:
            return .up
        default:
            return nil
        }
    }
}
