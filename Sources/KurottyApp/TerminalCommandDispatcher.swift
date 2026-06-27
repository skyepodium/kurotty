import AppKit

enum TerminalCommandDispatcher {
    @MainActor
    static func dispatchWindowCommand(from view: NSView, event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasOnlyCommandModifiers = flags.subtracting([.command, .shift]).isEmpty
        guard hasCommand,
              hasOnlyCommandModifiers,
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              let controller = view.window?.windowController as? TerminalWindowController
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
}
