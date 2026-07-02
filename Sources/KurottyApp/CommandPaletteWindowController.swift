import AppKit

struct CommandPalettePresenter {
    private let palette: TerminalCommandPalette
    private(set) var query: String
    private(set) var visibleEntries: [TerminalCommandPaletteEntry]
    private(set) var selectedIndex: Int?

    init(palette: TerminalCommandPalette = TerminalCommandPalette(), query: String = "") {
        self.palette = palette
        self.query = query
        self.visibleEntries = palette.results(for: query)
        self.selectedIndex = visibleEntries.isEmpty ? nil : 0
    }

    var selectedEntry: TerminalCommandPaletteEntry? {
        guard let selectedIndex,
              visibleEntries.indices.contains(selectedIndex)
        else {
            return nil
        }
        return visibleEntries[selectedIndex]
    }

    mutating func updateQuery(_ query: String) {
        self.query = query
        visibleEntries = palette.results(for: query)
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

    func executeSelected(_ execute: (TerminalCommand) -> Void) -> Bool {
        guard let selectedEntry else {
            return false
        }
        execute(selectedEntry.command)
        return true
    }
}

@MainActor
final class CommandPaletteWindowController: NSWindowController {
    private let searchField = CommandPaletteSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let commandExecutor: (TerminalCommand) -> Void
    private var presenter: CommandPalettePresenter

    init(
        palette: TerminalCommandPalette = TerminalCommandPalette(),
        commandExecutor: @escaping (TerminalCommand) -> Void
    ) {
        self.presenter = CommandPalettePresenter(palette: palette)
        self.commandExecutor = commandExecutor

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Command Palette"
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

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        searchField.placeholderString = "Search commands"
        searchField.target = self
        searchField.action = #selector(searchFieldDidChange(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onMoveSelection = { [weak self] offset in
            self?.moveSelection(by: offset)
        }
        searchField.onExecuteSelection = { [weak self] in
            self?.executeSelectedCommand()
        }
        searchField.onCancel = { [weak self] in
            self?.close()
        }

        let column = NSTableColumn(identifier: Self.commandColumnIdentifier)
        column.title = "Command"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 34
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
        guard presenter.executeSelected(commandExecutor) else {
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
            if let shortcutLabel = entry.shortcutLabel {
                textField.stringValue = "\(entry.title)    \(shortcutLabel)"
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

private final class CommandPaletteSearchField: NSSearchField {
    var onMoveSelection: ((Int) -> Void)?
    var onExecuteSelection: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            onMoveSelection?(1)
        case 126:
            onMoveSelection?(-1)
        case 36, 76:
            onExecuteSelection?()
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}
