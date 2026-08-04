import AppKit

/// Self-contained editor for the quick-command list: a table of commands on
/// top, an inspector for the selected command below.
///
/// Every edit goes straight through `QuickCommandStore`, which normalizes and
/// debounce-saves, so an in-progress row is preserved rather than dropped.
/// This view never sends anything to a terminal pane.
@MainActor
final class QuickCommandsEditorView: NSView {
    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("quickCommands.column.name")
        static let scope = NSUserInterfaceItemIdentifier("quickCommands.column.scope")
        static let action = NSUserInterfaceItemIdentifier("quickCommands.column.action")
    }

    private enum Symbol {
        static let add = "plus"
        static let remove = "minus"
    }

    private let store: QuickCommandStore
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let nameField = NSTextField()
    private let shortcutField = NSTextField()
    private let commandTextView = NSTextView()
    private let commandScrollView = NSScrollView()
    private let scopeField = NSTextField()
    private let chooseDirectoryButton = NSButton()
    private let clearDirectoryButton = NSButton()
    private let appendEnterCheckbox = NSButton()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var commands: [QuickCommand] = []
    private var isApplyingSelection = false

    init(store: QuickCommandStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        configure()
        reloadCommands()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var commandsForTesting: [QuickCommand] {
        commands
    }

    var selectedCommandForTesting: QuickCommand? {
        selectedCommand()
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        wantsLayer = true
        layer?.backgroundColor = theme.windowBackground.cgColor
        nameField.textColor = theme.textPrimary
        shortcutField.textColor = theme.textPrimary
        scopeField.textColor = theme.textPrimary
        commandTextView.textColor = theme.textPrimary
        commandTextView.backgroundColor = theme.topChromeBackground
        emptyStateLabel.textColor = theme.textMuted
        tableView.backgroundColor = theme.topChromeBackground
        tableView.reloadData()
    }

    // MARK: - Layout

    private func configure() {
        wantsLayer = true
        configureTable()
        configureToolbarButtons()
        configureInspectorFields()
        layoutSubviewsWithConstraints()
        applyChromeTheme(chromeTheme)
    }

    private func configureTable() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = DesignTokens.Component.quickCommandTableRowHeightPX
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()

        addColumn(Column.name, title: AppLocalization.string(.quickCommandColumnName), width: DesignTokens.Component.quickCommandNameColumnWidthPX)
        addColumn(Column.scope, title: AppLocalization.string(.quickCommandColumnScope), width: DesignTokens.Component.quickCommandScopeColumnWidthPX)
        addColumn(Column.action, title: AppLocalization.string(.quickCommandColumnAction), width: DesignTokens.Component.quickCommandActionColumnWidthPX)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyStateLabel.stringValue = AppLocalization.string(.quickCommandsEmptyState)
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func addColumn(_ identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    private func configureToolbarButtons() {
        configureToolbarButton(addButton, symbol: Symbol.add, fallbackTitle: AppLocalization.string(.quickCommandAdd), action: #selector(addCommand))
        configureToolbarButton(removeButton, symbol: Symbol.remove, fallbackTitle: AppLocalization.string(.quickCommandRemove), action: #selector(removeSelectedCommand))
    }

    private func configureToolbarButton(
        _ button: NSButton,
        symbol: String,
        fallbackTitle: String,
        action: Selector
    ) {
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: fallbackTitle) {
            button.image = image
            button.title = ""
        } else {
            button.title = fallbackTitle
        }
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureInspectorFields() {
        nameField.placeholderString = AppLocalization.string(.quickCommandFieldName)
        nameField.target = self
        nameField.action = #selector(commitInspectorEdits)
        nameField.delegate = self

        shortcutField.placeholderString = AppLocalization.string(.quickCommandFieldShortcut)
        shortcutField.target = self
        shortcutField.action = #selector(commitInspectorEdits)
        shortcutField.delegate = self

        commandTextView.isRichText = false
        commandTextView.isAutomaticQuoteSubstitutionEnabled = false
        commandTextView.isAutomaticDashSubstitutionEnabled = false
        commandTextView.isAutomaticSpellingCorrectionEnabled = false
        commandTextView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        commandTextView.delegate = self
        commandScrollView.documentView = commandTextView
        commandScrollView.hasVerticalScroller = true
        commandScrollView.borderType = .bezelBorder
        commandScrollView.translatesAutoresizingMaskIntoConstraints = false

        scopeField.placeholderString = AppLocalization.string(.quickCommandClearDirectory)
        scopeField.target = self
        scopeField.action = #selector(commitInspectorEdits)
        scopeField.delegate = self

        chooseDirectoryButton.title = AppLocalization.string(.quickCommandChooseDirectory)
        chooseDirectoryButton.bezelStyle = .rounded
        chooseDirectoryButton.target = self
        chooseDirectoryButton.action = #selector(chooseDirectory)

        clearDirectoryButton.title = AppLocalization.string(.quickCommandClearDirectory)
        clearDirectoryButton.bezelStyle = .rounded
        clearDirectoryButton.target = self
        clearDirectoryButton.action = #selector(clearDirectory)

        appendEnterCheckbox.setButtonType(.switch)
        appendEnterCheckbox.title = AppLocalization.string(.quickCommandFieldAppendEnter)
        appendEnterCheckbox.target = self
        appendEnterCheckbox.action = #selector(commitInspectorEdits)
    }

    private func layoutSubviewsWithConstraints() {
        let toolbarStack = NSStackView(views: [addButton, removeButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = DesignTokens.Component.quickCommandEditorRowSpacingPX

        let nameRow = labeledRow(AppLocalization.string(.quickCommandFieldName), field: nameField)
        let shortcutRow = labeledRow(AppLocalization.string(.quickCommandFieldShortcut), field: shortcutField)
        let commandRow = labeledRow(AppLocalization.string(.quickCommandFieldCommandText), field: commandScrollView)
        let scopeControls = NSStackView(views: [scopeField, chooseDirectoryButton, clearDirectoryButton])
        scopeControls.orientation = .horizontal
        scopeControls.spacing = DesignTokens.Component.quickCommandEditorRowSpacingPX
        let scopeRow = labeledRow(AppLocalization.string(.quickCommandFieldScopeDirectory), field: scopeControls)

        let stack = NSStackView(views: [
            scrollView,
            toolbarStack,
            nameRow,
            commandRow,
            scopeRow,
            shortcutRow,
            appendEnterCheckbox,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Component.quickCommandEditorRowSpacingPX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Component.quickCommandEditorPaddingPX),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Component.quickCommandEditorPaddingPX),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Component.quickCommandEditorPaddingPX),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -DesignTokens.Component.quickCommandEditorPaddingPX),
            scrollView.heightAnchor.constraint(equalToConstant: DesignTokens.Component.quickCommandTableHeightPX),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandScrollView.heightAnchor.constraint(equalToConstant: DesignTokens.Component.quickCommandCommandTextHeightPX),
            commandRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scopeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    private func labeledRow(_ title: String, field: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: DesignTokens.Component.quickCommandFieldLabelWidthPX).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = DesignTokens.Component.quickCommandEditorRowSpacingPX
        return row
    }

    // MARK: - Data

    private func reloadCommands() {
        commands = store.commands
        tableView.reloadData()
        emptyStateLabel.isHidden = !commands.isEmpty
        applySelectionToInspector()
    }

    private func selectedCommand() -> QuickCommand? {
        let row = tableView.selectedRow
        guard row >= 0, row < commands.count else {
            return nil
        }
        return commands[row]
    }

    private func applySelectionToInspector() {
        isApplyingSelection = true
        defer { isApplyingSelection = false }

        guard let command = selectedCommand() else {
            nameField.stringValue = ""
            shortcutField.stringValue = ""
            commandTextView.string = ""
            scopeField.stringValue = ""
            appendEnterCheckbox.state = .off
            setInspectorEnabled(false)
            return
        }
        setInspectorEnabled(true)
        nameField.stringValue = command.name
        shortcutField.stringValue = command.keyboardShortcut ?? ""
        commandTextView.string = command.bodyText
        scopeField.stringValue = command.scope.directoryPath ?? ""
        appendEnterCheckbox.state = command.executesOnDispatch ? .on : .off
    }

    private func setInspectorEnabled(_ enabled: Bool) {
        nameField.isEnabled = enabled
        shortcutField.isEnabled = enabled
        scopeField.isEnabled = enabled
        chooseDirectoryButton.isEnabled = enabled
        clearDirectoryButton.isEnabled = enabled
        appendEnterCheckbox.isEnabled = enabled
        commandTextView.isEditable = enabled
        removeButton.isEnabled = enabled
    }

    // MARK: - Actions

    @objc private func addCommand() {
        guard commands.count < AppConstants.QuickCommands.maximumCommandCount else {
            NSSound.beep()
            return
        }
        let identifier = "\(AppConstants.QuickCommands.identifierPrefix)\(UUID().uuidString)"
        let command = QuickCommand(
            id: identifier,
            name: "",
            action: .terminalCommand(text: "", appendEnter: false)
        )
        commands = store.apply(.upsert(command))
        tableView.reloadData()
        emptyStateLabel.isHidden = !commands.isEmpty
        if let index = commands.firstIndex(where: { $0.id == identifier }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        applySelectionToInspector()
        window?.makeFirstResponder(nameField)
    }

    @objc private func removeSelectedCommand() {
        guard let command = selectedCommand() else {
            return
        }
        commands = store.apply(.delete(id: command.id))
        tableView.reloadData()
        emptyStateLabel.isHidden = !commands.isEmpty
        applySelectionToInspector()
    }

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        scopeField.stringValue = url.path
        commitInspectorEdits()
    }

    @objc private func clearDirectory() {
        scopeField.stringValue = ""
        commitInspectorEdits()
    }

    @objc private func commitInspectorEdits() {
        guard !isApplyingSelection, let command = selectedCommand() else {
            return
        }
        var updated = command
        updated.name = nameField.stringValue
        let shortcut = shortcutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.keyboardShortcut = shortcut.isEmpty ? nil : shortcut
        let directory = scopeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.scope = directory.isEmpty ? .global : .directory(path: directory)
        switch command.action {
        case .terminalCommand:
            updated.action = .terminalCommand(
                text: commandTextView.string,
                appendEnter: appendEnterCheckbox.state == .on
            )
        case let .agentPrompt(_, agent):
            updated.action = .agentPrompt(text: commandTextView.string, agent: agent)
        }

        let selectedRow = tableView.selectedRow
        commands = store.apply(.upsert(updated))
        tableView.reloadData()
        if selectedRow >= 0, selectedRow < commands.count {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
    }
}

extension QuickCommandsEditorView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        commands.count
    }
}

extension QuickCommandsEditorView: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < commands.count, let identifier = tableColumn?.identifier else {
            return nil
        }
        let command = commands[row]
        let label = NSTextField(labelWithString: cellText(for: command, column: identifier))
        label.lineBreakMode = .byTruncatingTail
        label.textColor = chromeTheme.textPrimary
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        applySelectionToInspector()
    }

    private func cellText(for command: QuickCommand, column: NSUserInterfaceItemIdentifier) -> String {
        switch column {
        case Column.name:
            return QuickCommandPresentation.title(for: command, language: AppLocalization.language)
        case Column.scope:
            return QuickCommandPresentation.scopeDescription(
                for: command.scope,
                language: AppLocalization.language
            )
        default:
            return command.executesOnDispatch
                ? AppLocalization.string(.quickCommandRunsImmediately)
                : AppLocalization.string(.quickCommandInsertsOnly)
        }
    }
}

extension QuickCommandsEditorView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        commitInspectorEdits()
    }
}

extension QuickCommandsEditorView: NSTextViewDelegate {
    func textDidEndEditing(_ notification: Notification) {
        commitInspectorEdits()
    }
}
