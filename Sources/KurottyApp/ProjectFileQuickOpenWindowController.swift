import AppKit

/// The project file palette.
///
/// Finds a file anywhere under the active pane's working directory by name and
/// puts its path on the prompt. That is the terminal reason for it to exist:
/// shell tab completion is excellent once you know the directory and useless
/// when you do not, and typing `TerminalSurfaceView` is how people remember
/// files. Command-Return opens the file in an editor tab instead, for the times
/// the answer is to read it rather than to run something on it.
///
/// Everything the window decides lives in `ProjectFileQuickOpenPresenter`; this
/// class is the AppKit shell around it.
@MainActor
final class ProjectFileQuickOpenWindowController: NSWindowController {
    private let searchField = PaletteSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let enumerator: ProjectFileEnumerating
    private let language: AppLanguage
    /// Captured at construction rather than observed. The palette lives for one
    /// invocation, so it cannot outlive a theme change; taking the window's
    /// theme as a value keeps it out of the settings-observer graph entirely.
    private let chromeTheme: DesignTokens.ChromeTheme
    private let insertPathHandler: (String) -> Void
    private let openFileHandler: (URL) -> Void
    private var presenter: ProjectFileQuickOpenPresenter

    init(
        rootDirectory: URL,
        enumerator: ProjectFileEnumerating = ProjectFileEnumerator(),
        language: AppLanguage = AppLocalization.language,
        chromeTheme: DesignTokens.ChromeTheme = .dark,
        insertPathHandler: @escaping (String) -> Void,
        openFileHandler: @escaping (URL) -> Void
    ) {
        self.enumerator = enumerator
        self.language = language
        self.chromeTheme = chromeTheme
        self.insertPathHandler = insertPathHandler
        self.openFileHandler = openFileHandler
        self.presenter = ProjectFileQuickOpenPresenter(rootDirectory: rootDirectory)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DesignTokens.Component.projectFilePaletteWidthPX,
                height: DesignTokens.Component.projectFilePaletteHeightPX
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = AppLocalization.string(.openProjectFile, language: language)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
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
        // The scan starts on open rather than per keystroke: ranking is done
        // against an in-memory index, so one walk per invocation is all the
        // filesystem work this surface ever does.
        enumerator.requestListing(rootDirectory: presenter.rootDirectory) { [weak self] listing in
            guard let self else {
                return
            }
            self.presenter.applyListing(listing)
            self.reloadResults()
        }
    }

    private func configureWindow() {
        guard let window else {
            return
        }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        searchField.placeholderString = AppLocalization.string(.openProjectFilePlaceholder, language: language)
        searchField.target = self
        searchField.action = #selector(searchFieldDidChange(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onMoveSelection = { [weak self] offset in
            self?.moveSelection(by: offset)
        }
        searchField.onExecuteSelection = { [weak self] commandModifierHeld in
            self?.activateSelection(
                ProjectFileQuickOpenActivation.forReturnKey(commandModifierHeld: commandModifierHeld)
            )
        }
        searchField.onCancel = { [weak self] in
            self?.close()
        }

        let column = NSTableColumn(identifier: Self.fileColumnIdentifier)
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = DesignTokens.Component.projectFilePaletteRowHeightPX
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDidDoubleClick(_:))
        tableView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        DesignTokens.Typography.badge.apply(to: footerLabel, color: chromeTheme.textTertiary)
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)
        contentView.addSubview(footerLabel)

        let inset = DesignTokens.Component.projectFilePaletteInsetPX
        let gap = DesignTokens.Component.projectFilePaletteGapPX
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: inset),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: gap),

            footerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            footerLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
            footerLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: gap),
            footerLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -inset),
            footerLabel.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.projectFilePaletteFooterHeightPX
            ),
        ])

        reloadResults()
    }

    @objc private func searchFieldDidChange(_ sender: NSSearchField) {
        presenter.updateQuery(sender.stringValue)
        reloadResults()
    }

    @objc private func tableViewDidDoubleClick(_ sender: NSTableView) {
        let clickedRow = sender.clickedRow
        guard clickedRow >= 0 else {
            return
        }
        presenter.select(row: clickedRow)
        activateSelection(.insertPath)
    }

    private func moveSelection(by offset: Int) {
        presenter.moveSelection(by: offset)
        selectPresentedRow()
    }

    private func activateSelection(_ activation: ProjectFileQuickOpenActivation) {
        guard let outcome = presenter.outcome(for: activation) else {
            return
        }
        switch outcome {
        case let .insertPath(path):
            insertPathHandler(path)
        case let .openInEditor(url):
            openFileHandler(url)
        }
        close()
    }

    private func reloadResults() {
        tableView.reloadData()
        selectPresentedRow()
        footerLabel.stringValue = ProjectFileQuickOpenCopy.footer(for: presenter.status, language: language)
    }

    private func selectPresentedRow() {
        guard let selectedIndex = presenter.selectedIndex else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    private static let fileColumnIdentifier = NSUserInterfaceItemIdentifier("ProjectFilePaletteColumn")
    private static let fileCellIdentifier = NSUserInterfaceItemIdentifier("ProjectFilePaletteCell")
}

extension ProjectFileQuickOpenWindowController: NSWindowDelegate {
    /// Drops the scanned index when the palette closes.
    ///
    /// The window is kept alive by the terminal window until the next
    /// invocation replaces it, and a monorepo's index is tens of thousands of
    /// prepared paths — several megabytes held for a surface nobody is looking
    /// at. The next open re-scans anyway, because the point of scanning per
    /// invocation is that the files may have changed.
    func windowWillClose(_ notification: Notification) {
        presenter = ProjectFileQuickOpenPresenter(rootDirectory: presenter.rootDirectory)
        tableView.reloadData()
    }
}

extension ProjectFileQuickOpenWindowController: NSTableViewDataSource, NSTableViewDelegate {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated {
            presenter.visibleMatches.count
        }
    }

    nonisolated func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        MainActor.assumeIsolated {
            guard presenter.visibleMatches.indices.contains(row) else {
                return nil
            }
            let cell = tableView.makeView(
                withIdentifier: Self.fileCellIdentifier,
                owner: self
            ) as? ProjectFilePaletteCellView ?? ProjectFilePaletteCellView(theme: chromeTheme)
            cell.identifier = Self.fileCellIdentifier
            cell.apply(ProjectFileRowCopy(relativePath: presenter.visibleMatches[row].relativePath))
            return cell
        }
    }

    nonisolated func tableViewSelectionDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            presenter.select(row: tableView.selectedRow)
        }
    }
}

/// A file name over the directory holding it. The two are split rather than
/// shown as one path because the name is what was searched for and the
/// directory is what disambiguates two files with the same name.
struct ProjectFileRowCopy: Equatable {
    let filename: String
    let directory: String

    init(relativePath: String) {
        guard let separatorIndex = relativePath.lastIndex(of: ProjectFileMatcher.pathSeparator) else {
            filename = relativePath
            directory = ""
            return
        }
        filename = String(relativePath[relativePath.index(after: separatorIndex)...])
        directory = String(relativePath[..<separatorIndex])
    }
}

/// Localized footer copy for each palette state. Pure, so the rules about what
/// a truncated or fallback scan says can be asserted without a window.
enum ProjectFileQuickOpenCopy {
    static func footer(for status: ProjectFileQuickOpenStatus, language: AppLanguage) -> String {
        switch status {
        case .scanning:
            return AppLocalization.string(.openProjectFileScanning, language: language)
        case .emptyProject:
            return AppLocalization.string(.openProjectFileEmpty, language: language)
        case .noMatches:
            return AppLocalization.string(.openProjectFileNoMatches, language: language)
        case let .results(source, isListingTruncated, shownCOUNT, totalCOUNT):
            var parts = [
                AppLocalization.format(.openProjectFileResultCount, language: language, shownCOUNT, totalCOUNT),
            ]
            // The fallback scan is named every time it is used, not only when
            // it truncated. A complete-looking list that quietly skipped a
            // gitignored directory is exactly the case where the user needs to
            // know which enumerator answered.
            if source == .directoryWalk {
                parts.append(AppLocalization.string(.openProjectFileWithoutRipgrep, language: language))
            }
            if isListingTruncated {
                parts.append(AppLocalization.string(.openProjectFileTruncated, language: language))
            }
            return parts.joined(separator: " \(AppConstants.StatusBar.labelSeparator) ")
        }
    }
}

private final class ProjectFilePaletteCellView: NSTableCellView {
    private let filenameLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")

    init(theme: DesignTokens.ChromeTheme) {
        super.init(frame: .zero)
        DesignTokens.Typography.rowTitle.apply(to: filenameLabel, color: theme.textPrimary)
        filenameLabel.lineBreakMode = .byTruncatingTail
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        // The directory truncates from the head: the tail is the part that
        // says which of two same-named files this is.
        DesignTokens.Typography.badge.apply(to: directoryLabel, color: theme.textTertiary)
        directoryLabel.lineBreakMode = .byTruncatingHead
        directoryLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(filenameLabel)
        addSubview(directoryLabel)
        textField = filenameLabel

        let insetX = DesignTokens.Component.projectFilePaletteRowInsetXPX
        NSLayoutConstraint.activate([
            filenameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            filenameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
            directoryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            directoryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
            directoryLabel.topAnchor.constraint(
                equalTo: filenameLabel.bottomAnchor,
                constant: DesignTokens.Component.projectFilePaletteRowLineGapPX
            ),
            // Centered as a pair rather than pinned to the row edges, so the
            // two lines stay optically centered as the UI text scale changes
            // the type without changing the row height by the same amount.
            filenameLabel.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: DesignTokens.Component.projectFilePaletteRowLineGapPX
            ),
            directoryLabel.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -DesignTokens.Component.projectFilePaletteRowLineGapPX
            ),
            filenameLabel.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: -DesignTokens.Typography.badge.lineHeightPX / 2
            ),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ copy: ProjectFileRowCopy) {
        filenameLabel.stringValue = copy.filename
        directoryLabel.stringValue = copy.directory
        directoryLabel.isHidden = copy.directory.isEmpty
    }
}
