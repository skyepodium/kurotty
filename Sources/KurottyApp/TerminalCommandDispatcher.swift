import AppKit

enum TerminalPaneFocusDirection: Equatable {
    case left
    case right
    case up
    case down
}

enum TerminalCommandDispatcher {
    @MainActor
    static func dispatchWindowCommand(from view: NSView, event: NSEvent) -> Bool {
        guard let command = windowCommand(for: event),
              let controller = view.window?.windowController as? TerminalWindowController
        else {
            return false
        }

        execute(command.action, on: controller)
        return true
    }

    static func windowCommand(for event: NSEvent, registry: TerminalCommandRegistry = .default) -> TerminalCommand? {
        registry.windowCommand(matching: event)
    }

    @MainActor
    private static func execute(_ action: TerminalWindowCommandAction, on controller: TerminalWindowController) {
        switch action {
        case .newTab:
            controller.newTab()
        case .splitVertically:
            controller.splitVertically()
        case .splitHorizontally:
            controller.splitHorizontally()
        case .closeCurrentPane:
            controller.closeCurrentPane()
        case let .focusPane(direction):
            controller.focusPane(direction)
        case .selectPreviousTab:
            controller.selectPreviousTab()
        case .selectNextTab:
            controller.selectNextTab()
        }
    }
}
