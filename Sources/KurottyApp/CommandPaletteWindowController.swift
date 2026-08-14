import AppKit

struct CommandPalettePresentedEntry: Equatable {
    enum Kind: Equatable {
        case window(TerminalCommandPaletteEntry)
        case commandSpan(TerminalCommandSpanPaletteEntry)
        case quickCommand(TerminalQuickCommandPaletteEntry)
    }

    let kind: Kind
    let language: AppLanguage

    var title: String {
        switch kind {
        case let .window(entry):
            return entry.title
        case let .commandSpan(entry):
            return entry.title
        case let .quickCommand(entry):
            return entry.title
        }
    }

    var detail: String? {
        switch kind {
        case let .window(entry):
            return entry.shortcutLabel
        case let .commandSpan(entry):
            return entry.requiresExplicitApproval
                ? "\(entry.categoryTitle) - \(AppLocalization.string(.requiresConfirmation, language: language))"
                : entry.categoryTitle
        case let .quickCommand(entry):
            // A quick command that appends Return executes on selection, so the
            // row says so instead of looking like the insert-only ones.
            return entry.executesOnDispatch
                ? "\(entry.categoryTitle) - \(AppLocalization.string(.quickCommandRunsImmediately, language: language))"
                : "\(entry.categoryTitle) - \(AppLocalization.string(.quickCommandInsertsOnly, language: language))"
        }
    }

    var windowCommand: TerminalCommand? {
        guard case let .window(entry) = kind else {
            return nil
        }
        return entry.command
    }

    var commandSpanCommand: TerminalCommandSpanCommand? {
        guard case let .commandSpan(entry) = kind else {
            return nil
        }
        return entry.command
    }

    var quickCommand: QuickCommand? {
        guard case let .quickCommand(entry) = kind else {
            return nil
        }
        return entry.quickCommand
    }
}

struct CommandPalettePresenter {
    private let palette: TerminalCommandPalette
    private(set) var query: String
    private(set) var visibleEntries: [CommandPalettePresentedEntry]
    private(set) var selectedIndex: Int?
    private let language: AppLanguage

    init(
        palette: TerminalCommandPalette = TerminalCommandPalette(includesCommandSpanCommands: true),
        query: String = "",
        language: AppLanguage = .english
    ) {
        self.palette = palette
        self.language = language
        self.query = query
        self.visibleEntries = Self.presentedEntries(in: palette, matching: query, language: language)
        self.selectedIndex = visibleEntries.isEmpty ? nil : 0
    }

    var selectedEntry: CommandPalettePresentedEntry? {
        guard let selectedIndex,
              visibleEntries.indices.contains(selectedIndex)
        else {
            return nil
        }
        return visibleEntries[selectedIndex]
    }

    mutating func updateQuery(_ query: String) {
        self.query = query
        visibleEntries = Self.presentedEntries(in: palette, matching: query, language: language)
        selectedIndex = visibleEntries.isEmpty ? nil : 0
    }

    mutating func select(row: Int) {
        guard visibleEntries.indices.contains(row) else {
            selectedIndex = nil
            return
        }
        selectedIndex = row
    }

    mutating func moveSelection(by offset: Int) {
        guard !visibleEntries.isEmpty else {
            selectedIndex = nil
            return
        }

        let currentIndex = selectedIndex ?? 0
        selectedIndex = min(max(currentIndex + offset, 0), visibleEntries.count - 1)
    }

    func executeSelected(
        windowCommandExecutor: (TerminalCommand) -> Void,
        commandSpanExecutor: (TerminalCommandSpanCommand) -> Bool,
        quickCommandExecutor: (QuickCommand) -> Bool = { _ in false }
    ) -> Bool {
        guard let selectedEntry else {
            return false
        }
        switch selectedEntry.kind {
        case let .window(entry):
            windowCommandExecutor(entry.command)
            return true
        case let .commandSpan(entry):
            return commandSpanExecutor(entry.command)
        case let .quickCommand(entry):
            return quickCommandExecutor(entry.quickCommand)
        }
    }

    /// Quick commands are listed last: the built-in window commands and the
    /// selection's command-span actions keep their existing ranking, and the
    /// user's own commands form a trailing section.
    private static func presentedEntries(
        in palette: TerminalCommandPalette,
        matching query: String,
        language: AppLanguage
    ) -> [CommandPalettePresentedEntry] {
        palette.results(for: query).map { .init(kind: .window($0), language: language) }
            + palette.commandSpanResults(for: query).map { .init(kind: .commandSpan($0), language: language) }
            + palette.quickCommandResults(for: query).map { .init(kind: .quickCommand($0), language: language) }
    }
}

@MainActor
final class CommandPaletteWindowController: NSWindowController {
    private let searchField = PaletteSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let commandExecutor: (TerminalCommand) -> Void
    private let commandSpanExecutor: (TerminalCommandSpanCommand) -> Bool
    private let quickCommandExecutor: (QuickCommand) -> Bool
    /// Captured as a value rather than observed. The palette lives for one
    /// invocation, so it cannot outlive a theme change.
    private let chromeTheme: DesignTokens.ChromeTheme
    private var presenter: CommandPalettePresenter

    init(
        palette: TerminalCommandPalette = TerminalCommandPalette(includesCommandSpanCommands: true),
        commandExecutor: @escaping (TerminalCommand) -> Void,
        commandSpanExecutor: @escaping (TerminalCommandSpanCommand) -> Bool = { _ in false },
        quickCommandExecutor: @escaping (QuickCommand) -> Bool = { _ in false },
        chromeTheme: DesignTokens.ChromeTheme = .dark
    ) {
        self.chromeTheme = chromeTheme
        self.presenter = CommandPalettePresenter(palette: palette, language: AppLocalization.language)
        self.commandExecutor = commandExecutor
        self.commandSpanExecutor = commandSpanExecutor
        self.quickCommandExecutor = quickCommandExecutor

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DesignTokens.Component.commandPaletteWidthPX,
                height: DesignTokens.Component.commandPaletteHeightPX
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = AppLocalization.string(.commandPalette)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(searchField)
    }

    private func configureWindow() {
        guard let window else {
            return
        }

        // The theme decides light or dark, not the system. Without this the
        // window's system-drawn parts — the scroller, the focus ring, the
        // field's own fill — come out in the Mac's appearance beside chrome
        // painted from the theme's tokens, which is why this palette looked
        // borrowed under a light theme.
        window.appearance = chromeTheme.windowAppearance

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        searchField.placeholderString = AppLocalization.string(.searchCommands)
        searchField.target = self
        searchField.action = #selector(searchFieldDidChange(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onMoveSelection = { [weak self] offset in
            self?.moveSelection(by: offset)
        }
        // A command has one activation, so the Command-held flag the shared
        // field reports is not a second action here.
        searchField.onExecuteSelection = { [weak self] _ in
            self?.executeSelectedCommand()
        }
        searchField.onCancel = { [weak self] in
            self?.close()
        }

        let column = NSTableColumn(identifier: Self.commandColumnIdentifier)
        column.title = AppLocalization.string(.command)
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = DesignTokens.Component.commandPaletteRowHeightPX
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDidDoubleClick(_:))
        tableView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        reloadEntries()
    }

    @objc private func searchFieldDidChange(_ sender: NSSearchField) {
        presenter.updateQuery(sender.stringValue)
        reloadEntries()
    }

    @objc private func tableViewDidDoubleClick(_ sender: NSTableView) {
        let clickedRow = sender.clickedRow
        guard clickedRow >= 0 else {
            return
        }
        presenter.select(row: clickedRow)
        executeSelectedCommand()
    }

    private func moveSelection(by offset: Int) {
        presenter.moveSelection(by: offset)
        selectPresentedRow()
    }

    private func executeSelectedCommand() {
        guard presenter.executeSelected(
            windowCommandExecutor: commandExecutor,
            commandSpanExecutor: commandSpanExecutor,
            quickCommandExecutor: quickCommandExecutor
        ) else {
            return
        }
        close()
    }

    private func reloadEntries() {
        tableView.reloadData()
        selectPresentedRow()
    }

    private func selectPresentedRow() {
        guard let selectedIndex = presenter.selectedIndex else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    private static let commandColumnIdentifier = NSUserInterfaceItemIdentifier("CommandPaletteCommandColumn")
    private static let commandCellIdentifier = NSUserInterfaceItemIdentifier("CommandPaletteCommandCell")
}

extension CommandPaletteWindowController: NSTableViewDataSource, NSTableViewDelegate {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated {
            presenter.visibleEntries.count
        }
    }

    nonisolated func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        MainActor.assumeIsolated {
            guard presenter.visibleEntries.indices.contains(row) else {
                return nil
            }

            let cell = tableView.makeView(
                withIdentifier: Self.commandCellIdentifier,
                owner: self
            ) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = Self.commandCellIdentifier

            let textField: NSTextField
            if let existingTextField = cell.textField {
                textField = existingTextField
            } else {
                textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.textField = textField
                cell.addSubview(textField)
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            let entry = presenter.visibleEntries[row]
            if let detail = entry.detail {
                textField.stringValue = "\(entry.title)    \(detail)"
            } else {
                textField.stringValue = entry.title
            }
            return cell
        }
    }

    nonisolated func tableViewSelectionDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            presenter.select(row: tableView.selectedRow)
        }
    }
}
