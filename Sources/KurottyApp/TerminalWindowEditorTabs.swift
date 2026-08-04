import AppKit

/// Pure tab-title formatting for editor tabs so the modified marker matches
/// the terminal tab bar rendering and stays testable.
enum TerminalEditorTabTitleFormatter {
    static let modifiedPrefix = TerminalCodeEditorConstants.modifiedDotGlyph + " "

    static func label(fileName: String, isModified: Bool) -> String {
        isModified ? modifiedPrefix + fileName : fileName
    }
}

/// Pure mapping from the three-button unsaved-changes alert to a close
/// decision, so the policy is testable without running a modal alert.
enum TerminalEditorTabClosePolicy {
    enum Decision: Equatable {
        case saveAndClose
        case discardAndClose
        case cancel
    }

    static func decision(for response: NSApplication.ModalResponse) -> Decision {
        switch response {
        case .alertFirstButtonReturn: .saveAndClose
        case .alertSecondButtonReturn: .discardAndClose
        default: .cancel
        }
    }
}

/// Center editor-tab integration: opening a file from the explorer hosts a
/// `TerminalCodeEditorView` in a regular `NSTabViewItem` next to terminal
/// tabs. Every controller path that needs a terminal already guards on
/// `item.view as? SplitTerminalView`, so editor tabs fall through those paths
/// as harmless no-ops.
extension TerminalWindowController {
    /// Opens `url` in a center editor tab, reusing an existing tab that
    /// already shows the same file.
    func openEditorTab(for url: URL) {
        let standardized = url.standardizedFileURL
        if let existing = editorTabItem(for: standardized) {
            tabView.selectTabViewItem(existing)
            updateTabBar()
            return
        }

        let editor = TerminalCodeEditorView()
        editor.applyChromeTheme(chromeTheme)
        let item = NSTabViewItem(identifier: UUID().uuidString)
        item.view = editor
        editor.callbacks = TerminalCodeEditorCallbacks(
            onTitleChanged: { [weak self, weak item, weak editor] _ in
                guard let self, let item, let editor else { return }
                self.updateEditorTabLabel(item, editor: editor)
            },
            onModifiedChanged: { [weak self, weak item, weak editor] _ in
                guard let self, let item, let editor else { return }
                self.updateEditorTabLabel(item, editor: editor)
            }
        )
        editor.load(url: standardized)
        updateEditorTabLabel(item, editor: editor)
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        updateTabBar()
    }

    func editorView(in item: NSTabViewItem) -> TerminalCodeEditorView? {
        item.view as? TerminalCodeEditorView
    }

    var openEditorFileURLs: [URL] {
        (0..<tabView.numberOfTabViewItems).compactMap { index in
            editorView(in: tabView.tabViewItem(at: index))?.fileURL
        }
    }

    private func editorTabItem(for standardizedURL: URL) -> NSTabViewItem? {
        for index in 0..<tabView.numberOfTabViewItems {
            let item = tabView.tabViewItem(at: index)
            guard let editor = editorView(in: item),
                  editor.fileURL?.standardizedFileURL == standardizedURL
            else {
                continue
            }
            return item
        }
        return nil
    }

    private func updateEditorTabLabel(_ item: NSTabViewItem, editor: TerminalCodeEditorView) {
        let fileName = editor.fileURL?.lastPathComponent ?? ""
        item.label = TerminalEditorTabTitleFormatter.label(
            fileName: fileName,
            isModified: editor.isModified
        )
        if item === tabView.selectedTabViewItem {
            window?.title = item.label
        }
        updateTabBar()
    }

    /// Returns `true` when closing may proceed. A dirty editor tab asks the
    /// user to save, discard, or cancel; terminal tabs always proceed.
    func confirmEditorTabCloseIfNeeded(_ item: NSTabViewItem) -> Bool {
        guard let editor = editorView(in: item), editor.isModified else {
            return true
        }
        switch TerminalEditorTabClosePolicy.decision(for: runUnsavedChangesAlert(for: editor)) {
        case .saveAndClose:
            editor.save()
            return true
        case .discardAndClose:
            return true
        case .cancel:
            return false
        }
    }

    private func runUnsavedChangesAlert(for editor: TerminalCodeEditorView) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = AppLocalization.format(
            .unsavedChangesQuestion,
            editor.fileURL?.lastPathComponent ?? ""
        )
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: AppLocalization.string(.save))
        alert.addButton(withTitle: AppLocalization.string(.discardChanges))
        alert.addButton(withTitle: AppLocalization.string(.cancel))
        return alert.runModal()
    }
}
