import AppKit

/// The picker window.
///
/// A list of things a command produced, filtered by typing, chosen with Return.
/// Everything it decides lives in `QuickCommandPickerPresenter`; this is the
/// AppKit shell, in the shape `ProjectFileQuickOpenWindowController` already
/// established.
///
/// **The design is one idea repeated.** The selection is a rounded shape inside
/// the row rather than a bar across it; the ranking is made visible by dimming
/// what is not the answer and ruling a line above it; and exactly one row wears
/// a Return mark, so a common case that takes one keystroke looks like it takes
/// one keystroke. Nothing here has a border — separation is fill and space,
/// which is the whole of what makes Arc's and Dia's lists read as designed
/// rather than as tables.
@MainActor
final class QuickCommandPickerWindowController: NSWindowController {
    private let searchField = PaletteSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let chromeTheme: DesignTokens.ChromeTheme
    private let chooseHandler: (QuickCommandPickerRow) -> Void
    private var presenter: QuickCommandPickerPresenter

    private static let rowColumnIdentifier = NSUserInterfaceItemIdentifier("quickPickerRow")
    private static let rowCellIdentifier = NSUserInterfaceItemIdentifier("quickPickerRowCell")

    init(
        title: String,
        placeholder: String,
        chromeTheme: DesignTokens.ChromeTheme,
        chooseHandler: @escaping (QuickCommandPickerRow) -> Void
    ) {
        self.chromeTheme = chromeTheme
        self.chooseHandler = chooseHandler
        presenter = QuickCommandPickerPresenter(isLoading: true)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DesignTokens.Component.quickPickerWidthPX,
                height: DesignTokens.Component.quickPickerHeightPX
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureWindow(placeholder: placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows the rows the source produced.
    func apply(rows: [QuickCommandPickerRow]) {
        presenter.applyRows(rows)
        reload()
    }

    /// Says why there are no rows.
    ///
    /// An empty list with no explanation is the worst thing a picker over a
    /// network can do: `You must be logged in to the server` is the answer, and
    /// showing nothing turns it into a mystery.
    func apply(failure: String) {
        presenter.applyRows([])
        statusLabel.stringValue = failure
        tableView.reloadData()
    }

    private func configureWindow(placeholder: String) {
        guard let window else {
            return
        }

        // The theme decides light or dark, not the system. Without this the
        // window's system-drawn parts — the scroller, the focus ring, the
        // field's own fill — come out in whatever appearance the Mac is in,
        // beside chrome painted from the theme's tokens. Neither existing
        // palette does this, which is why they look borrowed under Nacre.
        window.appearance = chromeTheme.windowAppearance
        window.backgroundColor = chromeTheme.surfaceChrome

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        searchField.placeholderString = placeholder
        searchField.target = self
        searchField.action = #selector(searchFieldDidChange(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onMoveSelection = { [weak self] offset in
            self?.moveSelection(by: offset)
        }
        searchField.onExecuteSelection = { [weak self] _ in
            self?.chooseSelection()
        }
        searchField.onCancel = { [weak self] in
            self?.close()
        }

        let column = NSTableColumn(identifier: Self.rowColumnIdentifier)
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = DesignTokens.Component.quickPickerRowHeightPX
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        // The row's own pill is the selection. AppKit's would draw a second one
        // underneath it, in the system's accent rather than the theme's.
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = DesignTokens.Typography.rowSecondary.font
        statusLabel.textColor = chromeTheme.textTertiary
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)
        contentView.addSubview(statusLabel)

        let pad = DesignTokens.Space.x4PX
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: pad),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: DesignTokens.Space.x2PX),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: DesignTokens.Space.x2PX),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -DesignTokens.Space.x2PX),

            statusLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: DesignTokens.Space.x2PX),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -pad),
        ])

        reload()
    }

    @objc private func searchFieldDidChange(_ sender: NSSearchField) {
        presenter.updateQuery(sender.stringValue)
        reload()
    }

    @objc private func tableViewDoubleClicked() {
        presenter.select(row: tableView.selectedRow)
        chooseSelection()
    }

    private func moveSelection(by offset: Int) {
        presenter.moveSelection(by: offset)
        syncSelection()
    }

    private func chooseSelection() {
        guard let row = presenter.selectedRow else {
            return
        }
        close()
        chooseHandler(row)
    }

    private func reload() {
        tableView.reloadData()
        syncSelection()
        statusLabel.stringValue = statusText()
    }

    private func syncSelection() {
        guard let index = presenter.selectedIndex else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        // The pill is drawn by the cell, so a selection change has to redraw
        // the rows rather than let AppKit paint its own highlight.
        tableView.reloadData()
    }

    private func statusText() -> String {
        guard !presenter.isLoading else {
            return "…"
        }
        let secondary = presenter.visibleRows.filter(\.isSecondary).count
        guard secondary > 0 else {
            return "\(presenter.visibleRows.count)"
        }
        return "\(presenter.visibleRows.count - secondary) + \(secondary)"
    }
}

extension QuickCommandPickerWindowController: NSWindowDelegate {
    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            window?.makeFirstResponder(searchField)
        }
    }
}

extension QuickCommandPickerWindowController: NSTableViewDataSource, NSTableViewDelegate {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { presenter.visibleRows.count }
    }

    nonisolated func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        MainActor.assumeIsolated {
            guard presenter.visibleRows.indices.contains(row) else {
                return nil
            }
            let cell = tableView.makeView(
                withIdentifier: Self.rowCellIdentifier,
                owner: self
            ) as? QuickCommandPickerCellView ?? QuickCommandPickerCellView(theme: chromeTheme)
            cell.identifier = Self.rowCellIdentifier
            cell.apply(presenter.visibleRows[row], isSelected: presenter.selectedIndex == row)
            return cell
        }
    }

    /// The rule above the infrastructure.
    ///
    /// A row view rather than a separator row, so the list's indices stay the
    /// list's indices — a spacer row would have to be skipped by every arrow
    /// key and excluded from every count.
    nonisolated func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        MainActor.assumeIsolated {
            let view = QuickCommandPickerRowView()
            view.hairlineColor = presenter.firstSecondaryIndex == row ? chromeTheme.hairline : nil
            return view
        }
    }
}

/// A row that can draw a rule along its top edge.
///
/// This is where "these are not answers" is said in the layout rather than in
/// words: everything below the line is present because it is in the pod, not
/// because anyone is likely to want it.
@MainActor
final class QuickCommandPickerRowView: NSTableRowView {
    var hairlineColor: NSColor?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let hairlineColor else {
            return
        }
        hairlineColor.setFill()
        NSRect(
            x: DesignTokens.Space.x4PX,
            y: bounds.maxY - 1,
            width: bounds.width - DesignTokens.Space.x4PX * 2,
            height: 1
        ).fill()
    }

    /// AppKit's selection is refused here for the same reason the table's is:
    /// the cell draws a pill in the theme's colour, and a system highlight
    /// underneath would be a second selection in the system's accent.
    override func drawSelection(in dirtyRect: NSRect) {}
}
