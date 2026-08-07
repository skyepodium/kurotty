import AppKit

/// Asks for a name, performs the write, and reports one outcome.
///
/// Split out of `TerminalFileExplorerPanelView` so the panel keeps the tree and
/// the chrome and this keeps the prompt and the filesystem. The panel decides
/// *whether* an action is legal — that needs its selection and its root — and
/// this decides nothing at all: it prompts, calls the writer, and hands back a
/// single outcome for the panel to reconcile the tree against.
@MainActor
struct TerminalFileExplorerEntryActions {
    /// Delivered once per finished action, including a cancelled prompt (which
    /// reports neither a path nor a failure, so the panel leaves the tree
    /// alone). `revealing` is the path a create or rename produced; a trash has
    /// none, because the row it names is exactly what is gone.
    typealias OutcomeHandler = @MainActor (_ revealing: URL?, _ failure: FileExplorerEntryFailure?) -> Void

    private let writer: FileExplorerEntryWriter
    private let onOutcome: OutcomeHandler

    init(writer: FileExplorerEntryWriter, onOutcome: @escaping OutcomeHandler) {
        self.writer = writer
        self.onOutcome = onOutcome
    }

    // MARK: Create

    func promptAndCreate(_ action: FileExplorerEntryAction, in directory: URL) {
        let promptKey: L10nKey = action == .newFolder
            ? .fileExplorerNewFolderPrompt
            : .fileExplorerNewFilePrompt
        guard let typedName = FileExplorerNamePrompt.run(
            messageText: AppLocalization.format(promptKey, directory.lastPathComponent),
            confirmTitle: AppLocalization.string(.fileExplorerCreateConfirm),
            initialName: ""
        ) else {
            return
        }
        create(action, named: typedName, in: directory)
    }

    func create(_ action: FileExplorerEntryAction, named name: String, in directory: URL) {
        report(action == .newFolder
            ? writer.createDirectory(named: name, in: directory)
            : writer.createFile(named: name, in: directory))
    }

    // MARK: Rename

    func promptAndRename(_ url: URL) {
        let currentName = url.lastPathComponent
        guard let typedName = FileExplorerNamePrompt.run(
            messageText: AppLocalization.format(.fileExplorerRenamePrompt, currentName),
            confirmTitle: AppLocalization.string(.fileExplorerRenameConfirm),
            initialName: currentName
        ) else {
            return
        }
        rename(url, to: typedName)
    }

    func rename(_ url: URL, to name: String) {
        report(writer.rename(url, to: name))
    }

    // MARK: Trash

    func moveToTrash(_ url: URL) {
        writer.moveToTrash(url) { failure in
            // Reported either way: a refused trash still has to prove the row
            // is there, and a successful one has to take the row away.
            onOutcome(nil, failure)
        }
    }

    // MARK: Support

    private func report(_ result: Result<URL, FileExplorerEntryFailure>) {
        switch result {
        case let .success(url):
            onOutcome(url, nil)
        case let .failure(failure):
            onOutcome(nil, failure)
        }
    }
}
