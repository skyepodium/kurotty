import AppKit

enum TerminalPaneFocusDirection: Equatable {
    case left
    case right
    case up
    case down
}

struct TerminalCommandReplayApproval: Equatable {
    let isExplicitlyConfirmed: Bool

    init(isExplicitlyConfirmed: Bool) {
        self.isExplicitlyConfirmed = isExplicitlyConfirmed
    }
}

enum TerminalCommandSpanDispatchContext: Equatable {
    case fold(TerminalCommandFoldCandidate)
    case search(TerminalCommandSearchMetadata)
    case copyReference(TerminalCommandSpanReference)
    case replay(TerminalCommandReplayCandidate, approval: TerminalCommandReplayApproval)
}

struct TerminalCommandSpanDispatchHandlers {
    var fold: (TerminalCommandFoldCandidate) -> Void
    var search: (TerminalCommandSearchMetadata) -> Void
    var copyReference: (TerminalCommandSpanReference) -> Void
    var replay: (TerminalCommandReplayCandidate, TerminalCommandReplayApproval) -> Void

    init(
        fold: @escaping (TerminalCommandFoldCandidate) -> Void = { _ in },
        search: @escaping (TerminalCommandSearchMetadata) -> Void = { _ in },
        copyReference: @escaping (TerminalCommandSpanReference) -> Void = { _ in },
        replay: @escaping (TerminalCommandReplayCandidate, TerminalCommandReplayApproval) -> Void = { _, _ in }
    ) {
        self.fold = fold
        self.search = search
        self.copyReference = copyReference
        self.replay = replay
    }
}

enum TerminalCommandSpanDispatchResult: Equatable {
    case dispatched
    case requiresApproval
    case mismatchedContext
}

enum TerminalCommandDispatcher {
    @MainActor
    static func dispatchWindowCommand(from view: NSView, event: NSEvent) -> Bool {
        guard let command = windowCommand(for: event),
              let controller = view.window?.windowController as? TerminalWindowController
        else {
            return false
        }

        execute(command, on: controller)
        return true
    }

    static func windowCommand(for event: NSEvent, registry: TerminalCommandRegistry = .default) -> TerminalCommand? {
        registry.windowCommand(matching: event)
    }

    static func commandSpanCommand(
        for id: TerminalCommandSpanCommandID,
        registry: TerminalCommandRegistry = .default
    ) -> TerminalCommandSpanCommand? {
        registry.commandSpanCommand(for: id)
    }

    @MainActor
    static func execute(_ command: TerminalCommand, on controller: TerminalWindowController) {
        switch command.action {
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

    static func execute(
        _ command: TerminalCommandSpanCommand,
        context: TerminalCommandSpanDispatchContext,
        handlers: TerminalCommandSpanDispatchHandlers
    ) -> TerminalCommandSpanDispatchResult {
        switch (command.action, context) {
        case let (.foldOutput, .fold(candidate)):
            handlers.fold(candidate)
            return .dispatched
        case let (.searchOutput, .search(metadata)):
            handlers.search(metadata)
            return .dispatched
        case let (.copyReference, .copyReference(reference)):
            handlers.copyReference(reference)
            return .dispatched
        case let (.replay, .replay(candidate, approval)):
            guard command.approvalPolicy == .explicitUserConfirmation,
                  candidate.requiresExplicitUserConfirmation,
                  approval.isExplicitlyConfirmed
            else {
                return .requiresApproval
            }
            handlers.replay(candidate, approval)
            return .dispatched
        default:
            return .mismatchedContext
        }
    }
}
