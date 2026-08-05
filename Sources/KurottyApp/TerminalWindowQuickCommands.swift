import AppKit

/// Quick-command integration for the terminal window: the window controller is
/// the one object in the app that owns a focused pane, so it is the only
/// `QuickCommandSendTarget`. Every surface (palette, context menu, editor)
/// reaches a pane through `QuickCommandInvoker`, never directly.
///
/// Extracted from `TerminalWindowController` for the same reason as the
/// sidebar integrations: the controller stays focused on tab/window behavior.
extension TerminalWindowController: QuickCommandSendTarget {
    /// OSC 7 working directory of the pane that would receive the text. `nil`
    /// when no pane reports one, which makes directory-scoped quick commands
    /// invisible rather than guessing a directory for them.
    var quickCommandWorkingDirectory: String? {
        guard let surface = currentSplitView()?.activeTerminalSurface() else {
            return nil
        }
        let path = surface.workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Already-approved bytes from `QuickCommandInvoker`; the dispatcher's
    /// approval gate ran before this is reached. Focus returns to the pane so
    /// the user can keep typing where the text landed.
    func sendQuickCommandText(_ text: String) {
        sendTextToActivePane(text)
        currentSplitView()?.focusFirstPane()
    }

    /// Single entry point for every surface that resolves a quick command by
    /// id. Returns the dispatcher's result so a caller can tell "no such
    /// command" apart from "the gate refused".
    @discardableResult
    func invokeQuickCommand(withID id: String) -> QuickCommandDispatchResult? {
        guard let command = QuickCommandStore.shared.command(withID: id) else {
            return nil
        }
        return QuickCommandInvoker.invoke(command, target: self)
    }
}
