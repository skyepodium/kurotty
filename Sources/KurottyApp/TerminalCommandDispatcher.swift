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

/// Approval carried by a quick-command dispatch.
///
/// A quick command is authored by the user, so triggering one from the palette,
/// the context menu, or its own shortcut is itself the explicit act; there is no
/// per-invocation dialog. Anything that was not started by the user directly
/// (restore, automation, replayed state) leaves this false and can never make a
/// command execute.
struct QuickCommandApproval: Equatable {
    let isUserInitiated: Bool

    init(isUserInitiated: Bool) {
        self.isUserInitiated = isUserInitiated
    }
}

enum QuickCommandDispatchResult: Equatable {
    /// Text was written with no trailing newline; the user still presses Return.
    case insertedText(String)
    /// Text plus Return was written: this executed.
    case executedText(String)
    /// An executing command that was not user-initiated. Nothing was written.
    case requiresApproval
    /// The command has no runnable body. Nothing was written.
    case emptyCommand
}

struct QuickCommandDispatchHandlers {
    var sendText: (String) -> Void

    init(sendText: @escaping (String) -> Void = { _ in }) {
        self.sendText = sendText
    }
}

enum TerminalCommandSpanDispatchContext: Equatable {
    case fold(TerminalCommandFoldCandidate)
    case copyReference(TerminalCommandSpanReference)
    case replay(TerminalCommandReplayCandidate, approval: TerminalCommandReplayApproval)
}

struct TerminalCommandSpanDispatchHandlers {
    var fold: (TerminalCommandFoldCandidate) -> Void
    var copyReference: (TerminalCommandSpanReference) -> Void
    var replay: (TerminalCommandReplayCandidate, TerminalCommandReplayApproval) -> Void

    init(
        fold: @escaping (TerminalCommandFoldCandidate) -> Void = { _ in },
        copyReference: @escaping (TerminalCommandSpanReference) -> Void = { _ in },
        replay: @escaping (TerminalCommandReplayCandidate, TerminalCommandReplayApproval) -> Void = { _, _ in }
    ) {
        self.fold = fold
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
        case .findTerminalOutput:
            controller.findTerminalOutput()
        case let .jumpToPrompt(direction):
            controller.jumpToPrompt(direction)
        case .toggleCommandHistoryPanel:
            controller.toggleCommandHistoryPanel()
        case .toggleFileExplorerPanel:
            controller.toggleFileExplorerPanel()
        case .toggleAgentSessionPanel:
            controller.toggleAgentSessionPanel()
        case let .zoomFont(step):
            // The zoom is app-wide, so it does not route through the controller
            // the way the pane and tab commands do.
            TerminalFontZoomCoordinator.shared.apply(step)
        case let .tmuxSwapPane(direction):
            controller.swapTmuxPane(direction)
        case let .tmuxRotateWindow(direction):
            controller.rotateTmuxWindow(direction)
        case .tmuxToggleZoom:
            controller.toggleTmuxZoom()
        case let .tmuxSelectLayout(selection):
            controller.selectTmuxLayout(selection)
        case .tmuxDetachClient:
            controller.detachTmuxClient()
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

    /// The only path from a quick command to a terminal pane.
    ///
    /// Mirrors the replay gate above: a payload that executes is written only
    /// when the approval says the user initiated it, and an insert-only payload
    /// can never carry a newline, so it lands on the prompt without running.
    static func execute(
        quickCommand: QuickCommand,
        approval: QuickCommandApproval,
        handlers: QuickCommandDispatchHandlers
    ) -> QuickCommandDispatchResult {
        guard let payload = QuickCommandNormalizer.dispatchPayload(for: quickCommand) else {
            return .emptyCommand
        }
        guard payload.executes else {
            handlers.sendText(payload.text)
            return .insertedText(payload.text)
        }
        guard approval.isUserInitiated else {
            return .requiresApproval
        }
        handlers.sendText(payload.text)
        return .executedText(payload.text)
    }
}
