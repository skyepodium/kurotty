import AppKit

private final class ScrollIndicatorThumbView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
    static let titleDidChangeNotification = Notification.Name("dev.kurotty.terminalSurface.titleDidChange")
    static let focusDidChangeNotification = Notification.Name("dev.kurotty.terminalSurface.focusDidChange")
    static let titleNotificationKey = "title"

    private let core = CoreBridge(
        cols: UInt32(AppConstants.Terminal.defaultColumns),
        rows: UInt32(AppConstants.Terminal.defaultRows)
    )
    private let shell = ShellSession()
    private let notifier = TerminalNotifier.shared
    private let metalView: TerminalMetalView
    private let verticalScroller = NSScroller(frame: .zero)
    private let scrollThumbView = ScrollIndicatorThumbView(frame: .zero)
    private var terminalDefaultStyle: TerminalTextStyle
    private var terminalAnsiColors: [SIMD4<Float>]
    private var maxScrollbackRows: Int
    private var screen = TerminalScreen(rows: AppConstants.Terminal.defaultRows, columns: AppConstants.Terminal.defaultColumns)
    private var scrollbackRows: [[TerminalScreenCell]] = []
    private var scrollbackOffset = 0
    private var normalScreenSnapshot: TerminalScreen?
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursorRow = 0
    private var savedCursorColumn = 0
    private var scrollRegionTop = 0
    private var scrollRegionBottom = AppConstants.Terminal.defaultRows - 1
    private var cursorVisible = true
    private var isUsingAlternateScreen = false
    private var bracketedPasteEnabled = false
    private var currentStyle: TerminalTextStyle
    private var parserState = StreamState.normal
    private var csiBuffer = ""
    private var oscBuffer = ""
    private var terminalTitle = "-zsh"
    private var currentWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    private var selectionAnchor: TerminalCellPosition?
    private var selectionFocus: TerminalCellPosition?
    private var markedText = NSMutableAttributedString()
    private var inputSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var markedTextAnchor: TerminalCellPosition?
    private var lastSentSize = TerminalSize(columns: AppConstants.Terminal.defaultColumns, rows: AppConstants.Terminal.defaultRows)
    private var font: NSFont
    private var pendingDirtyRows = Set<Int>()
    private var pendingFullDamage = true
    private var debugFrameIndex: UInt64 = 0
    private var windowScreenObserver: NSObjectProtocol?
    private var currentBackingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    private let padding = NSEdgeInsets(
        top: DesignTokens.Space.terminalTopPX,
        left: DesignTokens.Space.terminalLeftPX,
        bottom: DesignTokens.Space.terminalBottomPX,
        right: DesignTokens.Space.terminalRightPX
    )

    override init(frame frameRect: NSRect) {
        let settings = (try? AppSettingsStore.shared.load()) ?? .default
        let configuredFont = NSFont(
            name: settings.terminal.fontName,
            size: CGFloat(settings.terminal.fontSize)
        ) ?? NSFont.monospacedSystemFont(ofSize: CGFloat(settings.terminal.fontSize), weight: .regular)
        font = configuredFont
        terminalDefaultStyle = TerminalTextStyle(
            foreground: settings.terminal.colors.foregroundColor,
            background: settings.terminal.colors.backgroundColor
        )
        terminalAnsiColors = Self.ansiColors(from: settings)
        currentStyle = terminalDefaultStyle
        maxScrollbackRows = max(1, settings.terminal.scrollbackLines)
        metalView = TerminalMetalView(
            font: configuredFont,
            backgroundColor: terminalDefaultStyle.background,
            cursorColor: settings.terminal.colors.cursorColor
        )
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = terminalDefaultStyle.background.cgColor
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.onPresented = { [weak self] in
            self?.metalFramePresented()
        }
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        verticalScroller.scrollerStyle = .legacy
        verticalScroller.controlSize = .small
        verticalScroller.target = self
        verticalScroller.action = #selector(scrollerDidChange(_:))
        verticalScroller.isHidden = true
        addSubview(verticalScroller)
        scrollThumbView.wantsLayer = true
        scrollThumbView.layer?.backgroundColor = DesignTokens.Color.scrollerThumb.cgColor
        scrollThumbView.layer?.cornerRadius = DesignTokens.Component.terminalScrollerThumbWidthPX / 2
        scrollThumbView.isHidden = true
        addSubview(scrollThumbView)
        shell.onOutput = { [weak self] text in
            Task { @MainActor in
                self?.appendOutput(text)
            }
        }
        shell.onExit = { [weak self] status in
            Task { @MainActor in
                self?.notifyShellDidExit(status: status)
            }
        }
        if DebugOptions.ptyLog {
            shell.onRawOutput = { data in
                NSLog("Kurotty PTY raw: bytes=%@ decoded=%@", Self.hexDump(data), Self.escapedText(data))
            }
        }
        metalView.diagnosticRenderingLogEnabled = DebugOptions.layout || DebugOptions.renderRects || DebugOptions.dirtyRects || DebugOptions.backgroundRuns || DebugOptions.cursorCell || DebugOptions.scrollRegion
        metalView.diagnosticFullRedrawEnabled = true
        metalView.diagnosticCellBoundaryOverlayEnabled = DebugOptions.renderRects
        metalView.diagnosticBaselineOverlayEnabled = DebugOptions.renderRects
        metalView.diagnosticGlyphQuadOverlayEnabled = DebugOptions.renderRects
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: AppSettingsStore.shared
        )
        observeInputSourceChanges()
        shell.start()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isOpaque: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            NotificationCenter.default.post(name: Self.focusDidChangeNotification, object: self)
        }
        return didBecomeFirstResponder
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        currentBackingScale = effectiveBackingScale
        observeWindowScreenChanges()
        syncSizeWithView()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        removeWindowScreenObserver()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        handleDisplayConfigurationChanged()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selectionAnchor = cellPosition(for: event)
        selectionFocus = nil
        markFullDamage()
        updateMetalFrame()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = selectionAnchor else { return }
        let focus = cellPosition(for: event)
        selectionFocus = focus == anchor ? nil : focus
        markFullDamage()
        updateMetalFrame()
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor = selectionAnchor else { return }
        let focus = cellPosition(for: event)
        selectionFocus = focus == anchor ? nil : focus
        markFullDamage()
        updateMetalFrame()
    }

    override func scrollWheel(with event: NSEvent) {
        let lineDelta = max(1, Int(abs(event.scrollingDeltaY) / 8))
        let previousOffset = scrollbackOffset
        if event.scrollingDeltaY > 0 {
            scrollbackOffset = min(scrollbackRows.count, scrollbackOffset + lineDelta)
        } else if event.scrollingDeltaY < 0 {
            scrollbackOffset = max(0, scrollbackOffset - lineDelta)
        }
        if scrollbackOffset != previousOffset {
            markFullDamage()
        }
        updateScrollIndicator()
        updateMetalFrame()
    }

    override func keyDown(with event: NSEvent) {
        core.recordKeyEvent()
        if handleCommandKey(event) {
            return
        }
        if TerminalTextInputRouter.handleKeyDown(event, in: self, hasMarkedText: hasMarkedText()) {
            return
        }
        if handleTerminalControlKey(event) {
            return
        }
        interpretKeyEvents([event])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCommandKey(event) || super.performKeyEquivalent(with: event)
    }

    func metalFramePresented() {
        core.recordFramePresented()
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        guard !text.isEmpty else { return }
        if bracketedPasteEnabled {
            send("\u{1b}[200~\(text)\u{1b}[201~")
        } else {
            send(text)
        }
    }

    @objc func copy(_ sender: Any?) {
        let text = selectedText() ?? visibleText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        if TerminalCommandDispatcher.dispatchWindowCommand(from: self, event: event) {
            return true
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              flags.subtracting([.command, .shift]).isEmpty,
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else {
            return false
        }

        switch characters {
        case "c" where flags == .command:
            copy(nil)
            return true
        case "v" where flags == .command:
            paste(nil)
            return true
        case "x" where flags == .command:
            cut(nil)
            return true
        default:
            return false
        }
    }

    private func handleTerminalControlKey(_ event: NSEvent) -> Bool {
        if let controlText = terminalControlText(for: event) {
            send(controlText)
            return true
        }

        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              event.charactersIgnoringModifiers == "\t"
        else {
            return false
        }
        send("\t")
        return true
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        apply(settings: settings)
    }

    override func layout() {
        super.layout()
        markFullDamage()
        syncSizeWithView()
        layoutScrollIndicator()
        updateMetalFrame()
    }

    @objc private func scrollerDidChange(_ sender: NSScroller) {
        let maxOffset = scrollbackRows.count
        guard maxOffset > 0 else { return }
        let normalized = max(0, min(1, sender.doubleValue))
        let nextOffset = min(maxOffset, max(0, Int(round((1 - normalized) * CGFloat(maxOffset)))))
        guard nextOffset != scrollbackOffset else { return }
        scrollbackOffset = nextOffset
        markFullDamage()
        updateScrollIndicator()
        updateMetalFrame()
    }

    private func observeWindowScreenChanges() {
        removeWindowScreenObserver()
        guard let window else { return }
        windowScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayConfigurationChanged()
            }
        }
    }

    private func removeWindowScreenObserver() {
        guard let windowScreenObserver else { return }
        NotificationCenter.default.removeObserver(windowScreenObserver)
        self.windowScreenObserver = nil
    }

    private func observeInputSourceChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputSourceDidChange(_:)),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
    }

    @objc private func inputSourceDidChange(_ notification: Notification) {
        handleInputSourceChanged()
    }

    private func handleInputSourceChanged() {
        // Korean IME can leave stale marked-text state across an input source
        // switch. Let AppKit discard the old composition instead of sending
        // intermediate jamo to the PTY or hiding them in our router.
        inputContext?.discardMarkedText()
        resetMarkedTextForInputSourceChange()
    }

    private func resetMarkedTextForInputSourceChange() {
        markMarkedTextDirty()
        markedText = NSMutableAttributedString()
        inputSelectedRange = NSRange(location: NSNotFound, length: 0)
        markedTextAnchor = nil
        markDirty(row: cursorRow)
        updateMetalFrame()
    }

    private func handleDisplayConfigurationChanged() {
        // Moving between Retina and 1x displays can change effective cell metrics and
        // PTY dimensions. Force a full frame so Metal receives fresh cell geometry.
        currentBackingScale = effectiveBackingScale
        markFullDamage()
        syncSizeWithView()
        updateMetalFrame()
    }

    private func syncSizeWithView() {
        let metrics = terminalMetrics()
        guard metrics.size.columns > 0, metrics.size.rows > 0 else { return }
        if metrics.size != lastSentSize {
            cursorRow = screen.resize(rows: metrics.size.rows, columns: metrics.size.columns, anchorRow: cursorRow)
            cursorColumn = min(cursorColumn, metrics.size.columns - 1)
            resetScrollRegion()
            lastSentSize = metrics.size
            shell.resize(columns: metrics.size.columns, rows: metrics.size.rows)
            core.resize(cols: UInt32(metrics.size.columns), rows: UInt32(metrics.size.rows))
            markFullDamage()
        }
    }

    private func updateMetalFrame() {
        let metrics = terminalMetrics()
        let damage = consumePendingDamage(metrics: metrics)
        var cells: [TerminalCell] = []
        var backgrounds: [TerminalBackground] = []
        var decorations: [TerminalDecoration] = []
        cells.reserveCapacity(metrics.size.rows * metrics.size.columns / 2)
        let rowsToRender = visibleRowsForRendering(limit: metrics.size.rows)
        let selectedCells = selectedCellSet()
        for row in 0..<rowsToRender.count {
            let sourceRow = rowsToRender[row]
            for column in 0..<min(sourceRow.count, metrics.size.columns) {
                let cell = sourceRow[column]
                let position = TerminalCellPosition(row: row, column: column)
                let isSelected = selectedCells.contains(position)
                if isSelected {
                    backgrounds.append(TerminalBackground(column: column, row: row, color: TerminalSelectionStyle.backgroundColor))
                } else if shouldRenderBackground(for: cell) {
                    backgrounds.append(TerminalBackground(column: column, row: row, color: cell.style.effectiveBackground))
                }
                if cell.isContinuation {
                    continue
                }
                if cell.style.underline {
                    decorations.append(TerminalDecoration(
                        column: column,
                        row: row,
                        width: max(1, cell.character.terminalColumnWidth),
                        kind: .underline,
                        color: cell.style.effectiveForeground
                    ))
                }
                if cell.style.strikethrough {
                    decorations.append(TerminalDecoration(
                        column: column,
                        row: row,
                        width: max(1, cell.character.terminalColumnWidth),
                        kind: .strikethrough,
                        color: cell.style.effectiveForeground
                    ))
                }
                if cell.character != " " {
                    cells.append(TerminalCell(
                        character: cell.character,
                        column: column,
                        row: row,
                        foreground: isSelected ? TerminalSelectionStyle.foregroundColor : cell.style.effectiveForeground,
                        background: cell.style.effectiveBackground
                    ))
                }
            }
        }
        metalView.update(frame: TerminalFrame(
            cells: cells,
            backgrounds: backgrounds,
            decorations: decorations,
            defaultForeground: terminalDefaultStyle.foreground,
            defaultBackground: terminalDefaultStyle.background,
            dirtyRows: damage.rows,
            dirtyRects: damage.rects,
            isFullDamage: damage.isFull,
            cursorColumn: min(cursorColumn + markedText.string.terminalColumnWidth, metrics.size.columns - 1),
            cursorRow: cursorVisible && scrollbackOffset == 0 ? min(cursorRow, metrics.size.rows - 1) : -1,
            markedTextColumn: cursorColumn,
            markedText: markedText.string,
            markedTextSelectedRange: NSRange(location: NSNotFound, length: 0),
            columns: metrics.size.columns,
            visibleRows: metrics.size.rows,
            cellSize: metrics.cellSize,
            padding: CGPoint(x: padding.left, y: padding.top)
        ))
        logScreenDumpIfNeeded(rows: rowsToRender, damage: damage, metrics: metrics)
        debugFrameIndex &+= 1
    }

    private func shouldRenderBackground(for cell: TerminalScreenCell) -> Bool {
        guard !cell.style.effectiveBackground.sameColor(as: terminalDefaultStyle.background) else {
            return false
        }
        if cell.character == " ", cell.style == .default {
            return false
        }
        return true
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = TerminalTextInputRouter.committedText(from: string)
        TerminalTextInputRouter.logInsertText(text, replacementRange: replacementRange)
        unmarkText()
        guard !text.isEmpty else { return }
        TerminalTextInputRouter.logPTYWrite(text, source: "insertText")
        send(text)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            send("\r")
        case #selector(insertTab(_:)):
            send("\t")
        case #selector(cancelOperation(_:)):
            resetMarkedTextForInputSourceChange()
            send("\u{1b}")
        case #selector(deleteBackward(_:)):
            send("\u{7f}")
        case #selector(deleteForward(_:)):
            send("\u{1b}[3~")
        case #selector(moveToBeginningOfLine(_:)):
            send("\u{1b}[H")
        case #selector(moveToEndOfLine(_:)):
            send("\u{1b}[F")
        case #selector(moveUp(_:)):
            send("\u{1b}[A")
        case #selector(moveDown(_:)):
            send("\u{1b}[B")
        case #selector(moveLeft(_:)):
            send("\u{1b}[D")
        case #selector(moveRight(_:)):
            send("\u{1b}[C")
        case #selector(scrollPageUp(_:)):
            send("\u{1b}[5~")
        case #selector(scrollPageDown(_:)):
            send("\u{1b}[6~")
        default:
            break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markMarkedTextDirty()
        let attr = string as? NSAttributedString ?? NSAttributedString(string: string as? String ?? "")
        TerminalTextInputRouter.logMarkedText(attr.string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedText = NSMutableAttributedString(attributedString: attr)
        inputSelectedRange = selectedRange
        markedTextAnchor = TerminalCellPosition(row: cursorRow, column: cursorColumn)
        markMarkedTextDirty()
        updateMetalFrame()
    }

    func unmarkText() {
        TerminalTextInputRouter.logUnmarkText()
        markMarkedTextDirty()
        markedText = NSMutableAttributedString()
        inputSelectedRange = NSRange(location: NSNotFound, length: 0)
        markedTextAnchor = nil
        markDirty(row: cursorRow)
        updateMetalFrame()
    }

    private func markMarkedTextDirty() {
        guard let anchor = markedTextAnchor else {
            markDirty(row: cursorRow)
            return
        }
        // IME composition is an overlay on top of terminal cells. When it changes
        // or commits, redraw the original row so transient composition pixels do
        // not become persistent cell backgrounds.
        markDirty(row: anchor.row)
        if anchor.row != cursorRow {
            markDirty(row: cursorRow)
        }
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange {
        inputSelectedRange.location == NSNotFound ? NSRange(location: 0, length: 0) : inputSelectedRange
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int {
        let metrics = terminalMetrics()
        guard metrics.cellSize.width > 0, metrics.cellSize.height > 0 else { return 0 }
        let column = Int((point.x - padding.left) / metrics.cellSize.width)
        let row = Int((bounds.height - padding.top - point.y) / metrics.cellSize.height)
        let clampedColumn = min(max(0, column), max(0, metrics.size.columns - 1))
        let clampedRow = min(max(0, row), max(0, metrics.size.rows - 1))
        return clampedRow * metrics.size.columns + clampedColumn
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = selectedRange()
        let localRect = currentCursorCellRectInViewCoordinates()
        let windowRect = convert(localRect, to: nil)
        let screenRect = window?.convertToScreen(windowRect) ?? .zero
        logIMEFirstRect(range: range, actualRange: actualRange?.pointee, localRect: localRect, windowRect: windowRect, screenRect: screenRect)
        return screenRect
    }

    private func send(_ text: String) {
        clearSelection()
        shell.write(text)
    }

    private func appendOutput(_ text: String) {
        let previousCursorRow = cursorRow
        let previousScrollbackOffset = scrollbackOffset
        if !text.isEmpty {
            scrollbackOffset = 0
        }
        if previousScrollbackOffset != scrollbackOffset {
            markFullDamage()
        } else {
            markDirty(row: previousCursorRow)
        }
        core.feed(text)
        for character in text {
            if parserState == .normal && character.isTerminalPrintableGrapheme {
                appendPrintable(String(character))
                continue
            }

            for scalar in character.unicodeScalars {
                if consumeControl(scalar) {
                    continue
                }

                switch scalar.value {
                case 10:
                    lineFeed()
                case 13:
                    cursorColumn = 0
                case 8:
                    cursorColumn = max(0, cursorColumn - 1)
                case 9:
                    let spaces = max(1, AppConstants.Terminal.tabWidthColumns - (cursorColumn % AppConstants.Terminal.tabWidthColumns))
                    appendPrintable(String(repeating: " ", count: spaces))
                case 0..<32, 127:
                    continue
                default:
                    appendPrintable(String(Character(scalar)))
                }
            }
        }
        markDirty(row: cursorRow)
        updateMetalFrame()
    }

    private func visibleText() -> String {
        visibleRowsForRendering(limit: screen.rows).map { row in
            String(row.map(\.character)).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private func selectedText() -> String? {
        guard let range = normalizedSelectionRange() else { return nil }
        let rows = visibleRowsForRendering(limit: terminalMetrics().size.rows)
        guard !rows.isEmpty else { return nil }

        var selectedLines: [String] = []
        for rowIndex in range.start.row...range.end.row where rows.indices.contains(rowIndex) {
            let row = rows[rowIndex]
            let startColumn = rowIndex == range.start.row ? range.start.column : 0
            let endColumn = rowIndex == range.end.row ? range.end.column : min(row.count - 1, screen.columns - 1)
            guard startColumn <= endColumn, startColumn < row.count else {
                selectedLines.append("")
                continue
            }
            let cells = row[startColumn...min(endColumn, row.count - 1)]
            selectedLines.append(String(cells.map(\.character)).trimmingCharacters(in: .whitespaces))
        }
        return selectedLines.joined(separator: "\n")
    }

    private func selectedCellSet() -> Set<TerminalCellPosition> {
        guard let range = normalizedSelectionRange() else { return [] }
        var cells = Set<TerminalCellPosition>()
        for row in range.start.row...range.end.row {
            let startColumn = row == range.start.row ? range.start.column : 0
            let endColumn = row == range.end.row ? range.end.column : screen.columns - 1
            guard startColumn <= endColumn else { continue }
            for column in startColumn...endColumn {
                cells.insert(TerminalCellPosition(row: row, column: column))
            }
        }
        return cells
    }

    private func normalizedSelectionRange() -> TerminalSelectionRange? {
        guard let anchor = selectionAnchor, let focus = selectionFocus, anchor != focus else { return nil }
        if anchor < focus {
            return TerminalSelectionRange(start: anchor, end: focus)
        }
        return TerminalSelectionRange(start: focus, end: anchor)
    }

    private func cellPosition(for event: NSEvent) -> TerminalCellPosition {
        let metrics = terminalMetrics()
        let location = convert(event.locationInWindow, from: nil)
        let rawColumn = Int(floor((location.x - padding.left) / metrics.cellSize.width))
        let rawRow = Int(floor((bounds.height - location.y - padding.top) / metrics.cellSize.height))
        let column = max(0, min(metrics.size.columns - 1, rawColumn))
        let row = max(0, min(metrics.size.rows - 1, rawRow))
        return TerminalCellPosition(row: row, column: column)
    }

    private func clearSelection() {
        guard selectionAnchor != nil || selectionFocus != nil else { return }
        selectionAnchor = nil
        selectionFocus = nil
        markFullDamage()
    }

    private func visibleRowsForRendering(limit: Int) -> [[TerminalScreenCell]] {
        let allRows = scrollbackRows + screen.cells
        guard !allRows.isEmpty else { return [] }
        let visibleCount = max(1, limit)
        let bottomStart = max(0, allRows.count - visibleCount)
        let start = max(0, bottomStart - scrollbackOffset)
        let end = min(allRows.count, start + visibleCount)
        var rows = Array(allRows[start..<end])
        if rows.count < visibleCount {
            rows.append(contentsOf: Array(repeating: TerminalScreen.blankRow(columns: screen.columns), count: visibleCount - rows.count))
        }
        return rows
    }

    private func terminalMetrics() -> TerminalMetrics {
        let scale = currentBackingScale
        let rawLineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        let rawWidth = max(AppConstants.Terminal.minimumCellWidthPX, ceil(("0" as NSString).size(withAttributes: [.font: font]).width))
        let lineHeight = snapMetricToPhysicalPixels(rawLineHeight, scale: scale)
        let width = snapMetricToPhysicalPixels(rawWidth, scale: scale)
        let columns = max(1, Int((bounds.width - padding.left - padding.right) / width))
        let rows = max(1, Int((bounds.height - padding.top - padding.bottom) / lineHeight))
        return TerminalMetrics(size: TerminalSize(columns: columns, rows: rows), cellSize: CGSize(width: width, height: lineHeight))
    }

    private var effectiveBackingScale: CGFloat {
        window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func snapMetricToPhysicalPixels(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        ceil(value * scale) / scale
    }

    private func apply(settings: AppSettings) {
        let nextFont = NSFont(
            name: settings.terminal.fontName,
            size: CGFloat(settings.terminal.fontSize)
        ) ?? NSFont.monospacedSystemFont(ofSize: CGFloat(settings.terminal.fontSize), weight: .regular)
        font = nextFont
        terminalDefaultStyle = TerminalTextStyle(
            foreground: settings.terminal.colors.foregroundColor,
            background: settings.terminal.colors.backgroundColor
        )
        terminalAnsiColors = Self.ansiColors(from: settings)
        maxScrollbackRows = max(1, settings.terminal.scrollbackLines)
        currentStyle = terminalDefaultStyle
        if scrollbackRows.count > maxScrollbackRows {
            scrollbackRows.removeFirst(scrollbackRows.count - maxScrollbackRows)
            markFullDamage()
        }
        updateScrollIndicator()
        layer?.backgroundColor = terminalDefaultStyle.background.cgColor
        metalView.applyAppearance(
            font: nextFont,
            backgroundColor: terminalDefaultStyle.background,
            cursorColor: settings.terminal.colors.cursorColor
        )
        markFullDamage()
        syncSizeWithView()
        updateMetalFrame()
    }

    private static func ansiColors(from settings: AppSettings) -> [SIMD4<Float>] {
        let configuredAnsiColors = settings.terminal.colors.ansi.map {
            ColorHexParser.parse($0, fallback: DesignTokens.Color.terminalForeground)
        }
        return configuredAnsiColors.count >= TerminalColorSettings.requiredAnsiColorCount
            ? Array(configuredAnsiColors.prefix(TerminalColorSettings.requiredAnsiColorCount))
            : DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright
    }

    private static func hexDump(_ data: Data) -> String {
        data.prefix(512).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func escapedText(_ data: Data) -> String {
        String(decoding: data.prefix(512), as: UTF8.self)
            .replacingOccurrences(of: "\u{1b}", with: "ESC")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func logScreenDumpIfNeeded(rows: [[TerminalScreenCell]], damage: TerminalFrameDamage, metrics: TerminalMetrics) {
        guard DebugOptions.screenDump || DebugOptions.layout else { return }
        NSLog(
            "Kurotty screen dump: frame=%llu rows=%d cols=%d cursor=(%d,%d) scrollRegion=%d-%d full=%@ dirtyRows=%@ cell=(%0.2f,%0.2f) scale=%0.2f",
            debugFrameIndex,
            metrics.size.rows,
            metrics.size.columns,
            cursorRow,
            cursorColumn,
            scrollRegionTop,
            scrollRegionBottom,
            damage.isFull ? "yes" : "no",
            damage.rows.map(String.init).joined(separator: ","),
            metrics.cellSize.width,
            metrics.cellSize.height,
            currentBackingScale
        )
        for rowIndex in 0..<min(rows.count, metrics.size.rows) {
            let row = Array(rows[rowIndex].prefix(metrics.size.columns))
            let text = String(row.map(\.character))
            let cursorMarker = rowIndex == cursorRow ? " cursorCol=\(cursorColumn)" : ""
            NSLog(
                "Kurotty row[%03d]%@: text='%@' bgRuns=%@ fgRuns=%@",
                rowIndex,
                cursorMarker,
                text,
                styleRuns(for: row.map(\.style), background: true),
                styleRuns(for: row.map(\.style), background: false)
            )
        }
    }

    private func styleRuns(for styles: [TerminalTextStyle], background: Bool) -> String {
        guard !styles.isEmpty else { return "[]" }
        var runs: [String] = []
        var start = 0
        var color = background ? styles[0].effectiveBackground : styles[0].effectiveForeground
        for index in 1..<styles.count {
            let next = background ? styles[index].effectiveBackground : styles[index].effectiveForeground
            if !next.sameColor(as: color) {
                runs.append("\(start)-\(index - 1):\(color.debugRGB)")
                start = index
                color = next
            }
        }
        runs.append("\(start)-\(styles.count - 1):\(color.debugRGB)")
        return "[" + runs.joined(separator: ", ") + "]"
    }

    private func currentCursorCellRectInViewCoordinates() -> NSRect {
        let metrics = terminalMetrics()
        return Self.cursorCellRectInViewCoordinates(
            boundsHeight: bounds.height,
            padding: padding,
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            cellSize: metrics.cellSize,
            columns: metrics.size.columns,
            rows: metrics.size.rows
        )
    }

    static func cursorCellRectInViewCoordinates(
        boundsHeight: CGFloat,
        padding: NSEdgeInsets,
        cursorRow: Int,
        cursorColumn: Int,
        cellSize: CGSize,
        columns: Int,
        rows: Int
    ) -> NSRect {
        let clampedRow = min(max(0, cursorRow), max(0, rows - 1))
        let clampedColumn = min(max(0, cursorColumn), max(0, columns - 1))
        return NSRect(
            x: padding.left + CGFloat(clampedColumn) * cellSize.width,
            // Terminal row 0 is visually at the top. NSView local coordinates are
            // bottom-origin here, so IME/AppKit must use the same y math as Metal
            // cursor placement instead of the top-origin terminal row formula.
            y: boundsHeight - padding.top - CGFloat(clampedRow + 1) * cellSize.height,
            width: max(1, cellSize.width),
            height: max(1, cellSize.height)
        )
    }

    private func logIMEFirstRect(
        range: NSRange,
        actualRange: NSRange?,
        localRect: NSRect,
        windowRect: NSRect,
        screenRect: NSRect
    ) {
        guard DebugOptions.imeRect || DebugOptions.inputClient || DebugOptions.cursorCoordinates else { return }
        NSLog(
            "Kurotty IME firstRect: cursor=(row:%d,col:%d) requested=%@ actual=%@ local=%@ window=%@ screen=%@ bounds=%@ scale=%0.2f flipped=%@ marked=%@ selected=%@",
            cursorRow,
            cursorColumn,
            NSStringFromRange(range),
            actualRange.map(NSStringFromRange) ?? "nil",
            NSStringFromRect(localRect),
            NSStringFromRect(windowRect),
            NSStringFromRect(screenRect),
            NSStringFromRect(bounds),
            effectiveBackingScale,
            isFlipped ? "yes" : "no",
            NSStringFromRange(markedRange()),
            NSStringFromRange(selectedRange())
        )
    }

    private func appendPrintable(_ text: String) {
        for character in text {
            let width = character.terminalColumnWidth
            guard width > 0 else {
                screen.appendCombining(character: character, row: cursorRow, before: cursorColumn)
                markDirty(row: cursorRow)
                continue
            }
            if width == 2 && cursorColumn == screen.columns - 1 {
                carriageReturnLineFeed()
            } else if cursorColumn >= screen.columns {
                carriageReturnLineFeed()
            }

            let printableStyle = styleForPrintableWrite(row: cursorRow, column: cursorColumn, width: width)
            screen.set(character: character, row: cursorRow, column: cursorColumn, width: width, style: printableStyle)
            markDirty(row: cursorRow)
            cursorColumn += width
        }
    }

    private func styleForPrintableWrite(row: Int, column: Int, width: Int) -> TerminalTextStyle {
        guard !currentStyle.inverse,
              currentStyle.effectiveBackground.sameColor(as: terminalDefaultStyle.background),
              let existingBackground = existingNonDefaultBackground(row: row, column: column, width: width)
        else {
            return currentStyle
        }
        // TUIs often paint an input row background, then print default-background
        // text over it. Keep that row color so wide Hangul commits do not punch
        // white/default rectangles through Codex-style input bars.
        var style = currentStyle
        style.background = existingBackground
        return style
    }

    private func existingNonDefaultBackground(row: Int, column: Int, width: Int) -> SIMD4<Float>? {
        guard screen.cells.indices.contains(row), column >= 0, column < screen.columns else {
            return nil
        }
        let upper = min(screen.columns - 1, column + max(1, width) - 1)
        for targetColumn in column...upper {
            let background = screen.cells[row][targetColumn].style.effectiveBackground
            if !background.sameColor(as: terminalDefaultStyle.background) {
                return background
            }
        }
        return nil
    }

    private func lineFeed() {
        markDirty(row: cursorRow)
        if cursorRow >= scrollRegionTop && cursorRow == scrollRegionBottom {
            let removed = screen.scrollUpRegion(top: scrollRegionTop, bottom: scrollRegionBottom, style: currentStyle)
            if shouldAppendScrollbackForActiveScrollRegion() {
                appendScrollback(rows: removed)
            }
            markFullDamage()
        } else {
            cursorRow = min(screen.rows - 1, cursorRow + 1)
            markDirty(row: cursorRow)
        }
    }

    private func resetScrollRegion() {
        scrollRegionTop = 0
        scrollRegionBottom = max(0, screen.rows - 1)
        logScrollRegion(reason: "reset")
    }

    private func setScrollRegion(_ parsed: CsiParameters) {
        guard !parsed.isPrivate else { return }
        if parsed.values.isEmpty {
            resetScrollRegion()
        } else {
            let top = max(0, min(screen.rows - 1, parsed.value(at: 0, default: 1) - 1))
            let bottom = max(0, min(screen.rows - 1, parsed.value(at: 1, default: screen.rows) - 1))
            guard top < bottom else { return }
            scrollRegionTop = top
            scrollRegionBottom = bottom
            logScrollRegion(reason: "set")
        }
        // DECSTBM moves the cursor home so subsequent TUI draws target the new
        // scroll contract rather than the old cursor row.
        cursorRow = 0
        cursorColumn = 0
        markFullDamage()
    }

    private func logScrollRegion(reason: String) {
        guard DebugOptions.scrollRegion || DebugOptions.vtParser else { return }
        NSLog(
            "Kurotty scroll region %@: top=%d bottom=%d rows=%d cursor=(%d,%d)",
            reason,
            scrollRegionTop,
            scrollRegionBottom,
            screen.rows,
            cursorRow,
            cursorColumn
        )
    }

    private func appendScrollback(rows: [[TerminalScreenCell]]) {
        scrollbackRows.append(contentsOf: rows)
        if scrollbackRows.count > maxScrollbackRows {
            scrollbackRows.removeFirst(scrollbackRows.count - maxScrollbackRows)
        }
        updateScrollIndicator()
    }

    private func layoutScrollIndicator() {
        let width = DesignTokens.Component.terminalScrollerWidthPX
        let scrollerX = max(0, bounds.width - width)
        verticalScroller.frame = NSRect(
            x: scrollerX,
            y: 0,
            width: width,
            height: bounds.height
        )
        updateScrollIndicator()
    }

    private func updateScrollIndicator() {
        let maxOffset = scrollbackRows.count
        let isHidden = maxOffset == 0 || bounds.height <= 0
        verticalScroller.isHidden = isHidden
        scrollThumbView.isHidden = isHidden
        guard !isHidden else { return }
        let visibleRows = max(1, terminalMetrics().size.rows)
        verticalScroller.knobProportion = max(
            0.05,
            min(1, CGFloat(visibleRows) / CGFloat(visibleRows + maxOffset))
        )
        verticalScroller.doubleValue = max(0, min(1, 1 - CGFloat(scrollbackOffset) / CGFloat(maxOffset)))
        verticalScroller.needsDisplay = true

        // NSScroller can be nearly invisible depending on system overlay style.
        // Draw a deterministic thumb so scrollback position is always visible.
        let trackHeight = max(1, verticalScroller.bounds.height)
        let thumbWidth = DesignTokens.Component.terminalScrollerThumbWidthPX
        let thumbHeight = max(
            DesignTokens.Component.terminalScrollerMinThumbHeightPX,
            trackHeight * CGFloat(visibleRows) / CGFloat(visibleRows + maxOffset)
        )
        let clampedThumbHeight = min(trackHeight, thumbHeight)
        let maxTravel = max(0, trackHeight - clampedThumbHeight)
        let normalizedOffset = max(0, min(1, CGFloat(scrollbackOffset) / CGFloat(maxOffset)))
        scrollThumbView.frame = NSRect(
            x: verticalScroller.frame.minX + (verticalScroller.bounds.width - thumbWidth) / 2,
            y: verticalScroller.frame.minY + maxTravel * normalizedOffset,
            width: thumbWidth,
            height: clampedThumbHeight
        )
        scrollThumbView.needsDisplay = true
    }

    private func shouldAppendScrollbackForActiveScrollRegion() -> Bool {
        // TUIs such as Codex often reserve bottom rows with DECSTBM while still
        // scrolling the transcript from row 0. Lines leaving that top-anchored
        // region should remain reachable via terminal scrollback.
        scrollRegionTop == 0
    }

    private func carriageReturnLineFeed() {
        cursorColumn = 0
        lineFeed()
    }

    private func consumeControl(_ scalar: UnicodeScalar) -> Bool {
        switch parserState {
        case .normal:
            if scalar.value == 0x1b {
                parserState = .escape
                return true
            }
            return false
        case .escape:
            switch scalar {
            case "[":
                csiBuffer = ""
                parserState = .csi
            case "]":
                oscBuffer = ""
                parserState = .osc
            case "7":
                savedCursorRow = cursorRow
                savedCursorColumn = cursorColumn
                parserState = .normal
            case "8":
                cursorRow = min(screen.rows - 1, savedCursorRow)
                cursorColumn = min(screen.columns - 1, savedCursorColumn)
                parserState = .normal
            case "D":
                lineFeed()
                parserState = .normal
            case "E":
                carriageReturnLineFeed()
                parserState = .normal
            case "M":
                reverseIndex()
                parserState = .normal
            case "c":
                resetTerminal()
                parserState = .normal
            default:
                parserState = .normal
            }
            return true
        case .csi:
            if scalar.value >= 0x40 && scalar.value <= 0x7e {
                executeCsi(final: Character(scalar), params: csiBuffer)
                csiBuffer = ""
                parserState = .normal
            } else {
                csiBuffer.append(Character(scalar))
            }
            return true
        case .osc:
            if scalar.value == 0x07 {
                executeOsc(oscBuffer)
                oscBuffer = ""
                parserState = .normal
            } else if scalar.value == 0x1b {
                parserState = .oscEscape
            } else {
                oscBuffer.append(Character(scalar))
            }
            return true
        case .oscEscape:
            if scalar == "\\" {
                executeOsc(oscBuffer)
            }
            oscBuffer = ""
            parserState = .normal
            return true
        }
    }

    private func executeOsc(_ command: String) {
        let parts = command.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let code = String(parts[0])
        let payload = String(parts[1])

        if payload == "?" {
            respondToOscQuery(code)
            return
        }

        switch code {
        case "0", "1", "2":
            terminalTitle = payload
            publishTitle()
        case "7":
            updateWorkingDirectory(fromOsc7: payload)
            publishTitle()
        case "9":
            notifyItermOsc9(payload)
        default:
            break
        }
    }

    private func notifyShellDidExit(status: Int32) {
        notifier.notifyShellDidExit(status: status)
    }

    private func notifyItermOsc9(_ payload: String) {
        notifier.notifyItermOsc9(message: payload)
    }

    private func respondToOscQuery(_ code: String) {
        switch code {
        case "10":
            send("\u{1b}]10;\(terminalOscColor(terminalDefaultStyle.foreground))\u{1b}\\")
        case "11":
            send("\u{1b}]11;\(terminalOscColor(terminalDefaultStyle.background))\u{1b}\\")
        default:
            break
        }
    }

    private func updateWorkingDirectory(fromOsc7 payload: String) {
        guard let url = URL(string: payload),
              url.isFileURL
        else {
            return
        }
        currentWorkingDirectory = url.path
    }

    private func publishTitle() {
        NotificationCenter.default.post(
            name: Self.titleDidChangeNotification,
            object: self,
            userInfo: [Self.titleNotificationKey: displayTitle()]
        )
    }

    private func displayTitle() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let displayPath: String
        if currentWorkingDirectory == home {
            displayPath = "~"
        } else if currentWorkingDirectory.hasPrefix(home + "/") {
            displayPath = "~/" + currentWorkingDirectory.dropFirst(home.count + 1)
        } else {
            displayPath = currentWorkingDirectory
        }

        let trimmedTitle = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty || trimmedTitle == displayPath ? "-zsh" : trimmedTitle
        if title.contains(displayPath), displayPath != "~" {
            return title
        }
        return "\(displayPath) (\(title))"
    }

    private func terminalOscColor(_ color: SIMD4<Float>) -> String {
        func component(_ value: Float) -> String {
            let clamped = max(0, min(1, value))
            return String(format: "%04x", Int((clamped * 65_535).rounded()))
        }
        return "rgb:\(component(color.x))/\(component(color.y))/\(component(color.z))"
    }

    private func executeCsi(final: Character, params: String) {
        let parsed = CsiParameters(params)
        let previousCursorRow = cursorRow
        logCsi(final: final, params: params, parsed: parsed, phase: "before")
        switch final {
        case "A":
            cursorRow = max(0, cursorRow - parsed.value(at: 0, default: 1))
        case "B", "e":
            cursorRow = min(screen.rows - 1, cursorRow + parsed.value(at: 0, default: 1))
        case "C", "a":
            cursorColumn = min(screen.columns - 1, cursorColumn + parsed.value(at: 0, default: 1))
        case "D":
            cursorColumn = max(0, cursorColumn - parsed.value(at: 0, default: 1))
        case "E":
            cursorRow = min(screen.rows - 1, cursorRow + parsed.value(at: 0, default: 1))
            cursorColumn = 0
        case "F":
            cursorRow = max(0, cursorRow - parsed.value(at: 0, default: 1))
            cursorColumn = 0
        case "G", "`":
            cursorColumn = min(screen.columns - 1, max(0, parsed.value(at: 0, default: 1) - 1))
        case "H", "f":
            cursorRow = min(screen.rows - 1, max(0, parsed.value(at: 0, default: 1) - 1))
            cursorColumn = min(screen.columns - 1, max(0, parsed.value(at: 1, default: 1) - 1))
        case "J":
            eraseInDisplay(mode: parsed.value(at: 0, default: 0))
        case "K":
            eraseInLine(mode: parsed.value(at: 0, default: 0))
        case "L":
            insertLines(count: parsed.value(at: 0, default: 1))
        case "M":
            deleteLines(count: parsed.value(at: 0, default: 1))
        case "P":
            screen.deleteCharacters(row: cursorRow, column: cursorColumn, count: parsed.value(at: 0, default: 1), style: currentStyle)
            markDirty(row: cursorRow)
        case "@":
            screen.insertCharacters(row: cursorRow, column: cursorColumn, count: parsed.value(at: 0, default: 1), style: currentStyle)
            markDirty(row: cursorRow)
        case "S":
            let removed = screen.scrollUpRegion(top: scrollRegionTop, bottom: scrollRegionBottom, count: parsed.value(at: 0, default: 1), style: currentStyle)
            if shouldAppendScrollbackForActiveScrollRegion() {
                appendScrollback(rows: removed)
            }
            markFullDamage()
        case "T":
            screen.scrollDownRegion(top: scrollRegionTop, bottom: scrollRegionBottom, count: parsed.value(at: 0, default: 1), style: currentStyle)
            markFullDamage()
        case "m":
            applySgr(parsed.values)
        case "r":
            setScrollRegion(parsed)
        case "s":
            savedCursorRow = cursorRow
            savedCursorColumn = cursorColumn
        case "u":
            guard !parsed.isPrivate else { break }
            cursorRow = min(screen.rows - 1, savedCursorRow)
            cursorColumn = min(screen.columns - 1, savedCursorColumn)
        case "n":
            if parsed.value(at: 0, default: 0) == 6 {
                send(cursorPositionReport())
            }
        case "c":
            send("\u{1b}[?1;2c")
        case "h":
            setMode(params: parsed, enabled: true)
        case "l":
            setMode(params: parsed, enabled: false)
        default:
            break
        }
        if cursorRow != previousCursorRow {
            markDirty(row: previousCursorRow)
            markDirty(row: cursorRow)
        }
        logCsi(final: final, params: params, parsed: parsed, phase: "after")
    }

    private func logCsi(final: Character, params: String, parsed: CsiParameters, phase: String) {
        guard DebugOptions.vtParser || DebugOptions.cursorLog else { return }
        NSLog(
            "Kurotty CSI %@: ESC[%@%@ private=%@ values=%@ cursor=(%d,%d) scrollRegion=%d-%d fg=%@ bg=%@",
            phase,
            params,
            String(final),
            parsed.isPrivate ? "yes" : "no",
            parsed.values.map(String.init).joined(separator: ","),
            cursorRow,
            cursorColumn,
            scrollRegionTop,
            scrollRegionBottom,
            currentStyle.effectiveForeground.debugRGB,
            currentStyle.effectiveBackground.debugRGB
        )
    }

    private func insertLines(count: Int) {
        let bottom = cursorRow >= scrollRegionTop && cursorRow <= scrollRegionBottom ? scrollRegionBottom : screen.rows - 1
        screen.insertLines(at: cursorRow, bottom: bottom, count: count, style: currentStyle)
        markDirty(rows: cursorRow..<(bottom + 1))
    }

    private func deleteLines(count: Int) {
        let bottom = cursorRow >= scrollRegionTop && cursorRow <= scrollRegionBottom ? scrollRegionBottom : screen.rows - 1
        screen.deleteLines(at: cursorRow, bottom: bottom, count: count, style: currentStyle)
        markDirty(rows: cursorRow..<(bottom + 1))
    }

    private func cursorPositionReport() -> String {
        "\u{1b}[\(cursorRow + 1);\(cursorColumn + 1)R"
    }

    private func setMode(params: CsiParameters, enabled: Bool) {
        guard params.isPrivate else { return }
        for value in params.values {
            switch value {
            case 25:
                cursorVisible = enabled
                markDirty(row: cursorRow)
            case 47, 1047, 1049:
                if enabled {
                    enterAlternateScreen()
                } else {
                    leaveAlternateScreen()
                }
            case 2004:
                bracketedPasteEnabled = enabled
            default:
                break
            }
        }
    }

    private func eraseInLine(mode: Int) {
        switch mode {
        case 0:
            screen.clear(row: cursorRow, from: cursorColumn, through: screen.columns - 1, style: currentStyle)
            markDirty(row: cursorRow)
        case 1:
            screen.clear(row: cursorRow, from: 0, through: cursorColumn, style: currentStyle)
            markDirty(row: cursorRow)
        case 2:
            screen.clear(row: cursorRow, style: currentStyle)
            markDirty(row: cursorRow)
        default:
            break
        }
    }

    private func eraseInDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseInLine(mode: 0)
            if cursorRow + 1 < screen.rows {
                for row in (cursorRow + 1)..<screen.rows {
                    screen.clear(row: row, style: currentStyle)
                }
                markDirty(rows: (cursorRow + 1)..<screen.rows)
            }
        case 1:
            if cursorRow > 0 {
                for row in 0..<cursorRow {
                    screen.clear(row: row, style: currentStyle)
                }
                markDirty(rows: 0..<cursorRow)
            }
            eraseInLine(mode: 1)
        case 2, 3:
            screen.clear(style: currentStyle)
            cursorRow = 0
            cursorColumn = 0
            markFullDamage()
        default:
            break
        }
    }

    private func reverseIndex() {
        markDirty(row: cursorRow)
        if cursorRow >= scrollRegionTop && cursorRow == scrollRegionTop {
            screen.scrollDownRegion(top: scrollRegionTop, bottom: scrollRegionBottom, style: currentStyle)
            markFullDamage()
        } else {
            cursorRow = max(0, cursorRow - 1)
            markDirty(row: cursorRow)
        }
    }

    private func enterAlternateScreen() {
        guard !isUsingAlternateScreen else { return }
        normalScreenSnapshot = screen
        screen.clear()
        cursorRow = 0
        cursorColumn = 0
        resetScrollRegion()
        isUsingAlternateScreen = true
        markFullDamage()
    }

    private func leaveAlternateScreen() {
        guard isUsingAlternateScreen else { return }
        if let snapshot = normalScreenSnapshot {
            screen = snapshot
            cursorRow = screen.resize(rows: lastSentSize.rows, columns: lastSentSize.columns, anchorRow: cursorRow)
        } else {
            screen.clear()
        }
        cursorRow = min(cursorRow, screen.rows - 1)
        cursorColumn = min(cursorColumn, screen.columns - 1)
        resetScrollRegion()
        normalScreenSnapshot = nil
        isUsingAlternateScreen = false
        markFullDamage()
    }

    private func resetTerminal() {
        screen.clear()
        cursorRow = 0
        cursorColumn = 0
        cursorVisible = true
        bracketedPasteEnabled = false
        currentStyle = terminalDefaultStyle
        normalScreenSnapshot = nil
        isUsingAlternateScreen = false
        resetScrollRegion()
        markFullDamage()
    }

    private func markDirty(row: Int) {
        guard row >= 0 else { return }
        pendingDirtyRows.insert(row)
    }

    private func markDirty(rows: Range<Int>) {
        for row in rows {
            markDirty(row: row)
        }
    }

    private func markFullDamage() {
        pendingFullDamage = true
    }

    private func consumePendingDamage(metrics: TerminalMetrics) -> TerminalFrameDamage {
        let visibleRows = max(1, metrics.size.rows)
        let rows: [Int]
        let isFull = pendingFullDamage
        if isFull {
            rows = Array(0..<visibleRows)
        } else {
            rows = pendingDirtyRows
                .filter { $0 >= 0 && $0 < visibleRows }
                .sorted()
        }
        let rects = rows.map { row in
            CGRect(
                x: padding.left,
                y: bounds.height - padding.top - metrics.cellSize.height * CGFloat(row + 1),
                width: metrics.cellSize.width * CGFloat(metrics.size.columns),
                height: metrics.cellSize.height
            )
        }
        pendingDirtyRows.removeAll(keepingCapacity: true)
        pendingFullDamage = false
        return TerminalFrameDamage(rows: rows, rects: rects, isFull: isFull)
    }

    private func applySgr(_ values: [Int]) {
        let codes = values.isEmpty ? [0] : values
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0:
                currentStyle = terminalDefaultStyle
            case 1:
                currentStyle.bold = true
            case 2:
                currentStyle.dim = true
            case 3:
                currentStyle.italic = true
            case 4:
                currentStyle.underline = true
            case 5:
                currentStyle.blink = true
            case 9:
                currentStyle.strikethrough = true
            case 22:
                currentStyle.bold = false
                currentStyle.dim = false
            case 23:
                currentStyle.italic = false
            case 24:
                currentStyle.underline = false
            case 25:
                currentStyle.blink = false
            case 29:
                currentStyle.strikethrough = false
            case 7:
                currentStyle.inverse = true
            case 27:
                currentStyle.inverse = false
            case 30...37:
                currentStyle.foreground = terminalAnsiColor(code - 30, bright: currentStyle.bold)
            case 39:
                currentStyle.foreground = terminalDefaultStyle.foreground
            case 40...47:
                currentStyle.background = terminalAnsiColor(code - 40, bright: false)
            case 49:
                currentStyle.background = terminalDefaultStyle.background
            case 90...97:
                currentStyle.foreground = terminalAnsiColor(code - 90, bright: true)
            case 100...107:
                currentStyle.background = terminalAnsiColor(code - 100, bright: true)
            case 38, 48:
                let isForeground = code == 38
                guard index + 1 < codes.count else { break }
                if codes[index + 1] == 5, index + 2 < codes.count {
                    let color = xterm256Color(codes[index + 2])
                    if isForeground {
                        currentStyle.foreground = color
                    } else {
                        currentStyle.background = color
                    }
                    index += 2
                } else if codes[index + 1] == 2, index + 4 < codes.count {
                    let color = TerminalTextStyle.rgb(red: codes[index + 2], green: codes[index + 3], blue: codes[index + 4])
                    if isForeground {
                        currentStyle.foreground = color
                    } else {
                        currentStyle.background = color
                    }
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }

    private func terminalAnsiColor(_ index: Int, bright: Bool) -> SIMD4<Float> {
        let offset = bright ? DesignTokens.Color.ansiNormal.count : 0
        let clampedIndex = max(0, min(offset + index, terminalAnsiColors.count - 1))
        return terminalAnsiColors[clampedIndex]
    }

    private func xterm256Color(_ value: Int) -> SIMD4<Float> {
        let index = max(0, min(value, 255))
        if index < TerminalColorSettings.requiredAnsiColorCount {
            return terminalAnsiColors[index]
        }
        if terminalDefaultStyle.isLightBackground, index >= 250 {
            return lightThemeGray(index)
        }
        if index < 232 {
            let cube = index - 16
            let red = cube / 36
            let green = (cube / 6) % 6
            let blue = cube % 6
            func component(_ value: Int) -> Int { value == 0 ? 0 : 55 + value * 40 }
            return TerminalTextStyle.rgb(red: component(red), green: component(green), blue: component(blue))
        }
        let gray = 8 + (index - 232) * 10
        return TerminalTextStyle.rgb(red: gray, green: gray, blue: gray)
    }

    private func lightThemeGray(_ index: Int) -> SIMD4<Float> {
        let clamped = max(250, min(index, 255))
        // Keep Codex's muted gray panels visible without making them heavy blocks
        // on the lightty background.
        let component = 205 + (clamped - 250) * 6
        return TerminalTextStyle.rgb(red: component, green: component, blue: component)
    }
}

private enum StreamState {
    case normal
    case escape
    case csi
    case osc
    case oscEscape
}

private func terminalControlText(for event: NSEvent) -> String? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.control), !flags.contains(.command), !flags.contains(.option) else {
        return nil
    }
    guard let character = event.charactersIgnoringModifiers?.unicodeScalars.first else {
        return nil
    }

    switch character.value {
    case 0x00...0x1f, 0x7f:
        return String(character)
    case 0x40, 0x20:
        return "\u{0}"
    case 0x41...0x5a:
        return String(UnicodeScalar(character.value - 0x40)!)
    case 0x61...0x7a:
        return String(UnicodeScalar(character.value - 0x60)!)
    case 0x5b:
        return "\u{1b}"
    case 0x5c:
        return "\u{1c}"
    case 0x5d:
        return "\u{1d}"
    case 0x5e:
        return "\u{1e}"
    case 0x5f:
        return "\u{1f}"
    case 0x3f:
        return "\u{7f}"
    default:
        return nil
    }
}

private struct TerminalSize: Equatable {
    let columns: Int
    let rows: Int
}

private struct TerminalMetrics {
    let size: TerminalSize
    let cellSize: CGSize
}

private struct TerminalCellPosition: Hashable, Comparable {
    let row: Int
    let column: Int

    static func < (lhs: TerminalCellPosition, rhs: TerminalCellPosition) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

private struct TerminalSelectionRange {
    let start: TerminalCellPosition
    let end: TerminalCellPosition
}

enum TerminalSelectionStyle {
    static let backgroundColor = SIMD4<Float>(0.22, 0.48, 0.82, 1)
    static let foregroundColor = SIMD4<Float>(1, 1, 1, 1)
}

private struct TerminalFrameDamage {
    let rows: [Int]
    let rects: [CGRect]
    let isFull: Bool
}

private struct TerminalScreen {
    private(set) var rows: Int
    private(set) var columns: Int
    var cells: [[TerminalScreenCell]]
    private var resizeHiddenRowsAbove: [[TerminalScreenCell]] = []
    private var resizeHiddenRowsBelow: [[TerminalScreenCell]] = []

    init(rows: Int, columns: Int) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.cells = Array(repeating: TerminalScreen.blankRow(columns: self.columns), count: self.rows)
    }

    @discardableResult
    mutating func resize(rows newRows: Int, columns newColumns: Int, anchorRow: Int? = nil) -> Int {
        let targetRows = max(1, newRows)
        let targetColumns = max(1, newColumns)
        let oldRows = resizeHiddenRowsAbove + cells + resizeHiddenRowsBelow
        let normalizedRows = oldRows.map { TerminalScreen.resize(row: $0, columns: targetColumns) }
        let totalRows = max(1, normalizedRows.count)
        let visibleStart = resizeHiddenRowsAbove.count
        let clampedAnchor = min(max(0, anchorRow ?? rows - 1), max(0, rows - 1))
        let anchorAbsoluteRow = min(totalRows - 1, visibleStart + clampedAnchor)
        let preferredAnchorRow = min(clampedAnchor, targetRows - 1)
        let maxStart = max(0, totalRows - targetRows)
        let start = max(0, min(anchorAbsoluteRow - preferredAnchorRow, maxStart))
        let end = min(totalRows, start + targetRows)
        var resized = Array(repeating: TerminalScreen.blankRow(columns: targetColumns), count: targetRows)
        if !normalizedRows.isEmpty {
            for targetRow in 0..<(end - start) {
                resized[targetRow] = normalizedRows[start + targetRow]
            }
        }
        resizeHiddenRowsAbove = start > 0 ? Array(normalizedRows[..<start]) : []
        resizeHiddenRowsBelow = end < normalizedRows.count ? Array(normalizedRows[end...]) : []
        rows = targetRows
        columns = targetColumns
        cells = resized
        return min(targetRows - 1, max(0, anchorAbsoluteRow - start))
    }

    mutating func clear(style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        cells = Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: rows)
    }

    mutating func clear(row: Int, style: TerminalTextStyle = .default) {
        guard cells.indices.contains(row) else { return }
        cells[row] = TerminalScreen.blankRow(columns: columns, style: style)
    }

    mutating func clear(row: Int, from start: Int, through end: Int, style: TerminalTextStyle = .default) {
        guard cells.indices.contains(row) else { return }
        guard start <= end, start < columns, end >= 0 else { return }
        let lower = max(0, min(start, columns - 1))
        let upper = max(0, min(end, columns - 1))
        guard lower <= upper else { return }
        for column in lower...upper {
            cells[row][column] = TerminalScreenCell(style: style)
        }
    }

    mutating func set(character: Character, row: Int, column: Int, width: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        clearWideCellIfNeeded(row: row, column: column, style: style)
        cells[row][column] = TerminalScreenCell(character: character, isContinuation: false, style: style)
        if width == 2 && column + 1 < columns {
            cells[row][column + 1] = TerminalScreenCell(character: " ", isContinuation: true, style: style)
        }
        if column > 0 && cells[row][column - 1].isContinuation {
            cells[row][column - 1] = TerminalScreenCell(style: style)
        }
        if width == 1 && column + 1 < columns && cells[row][column + 1].isContinuation {
            cells[row][column + 1] = TerminalScreenCell(style: style)
        }
    }

    mutating func appendCombining(character: Character, row: Int, before column: Int) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column > 0 else { return }
        var leadColumn = min(column - 1, columns - 1)
        while leadColumn > 0 && cells[row][leadColumn].isContinuation {
            leadColumn -= 1
        }
        guard cells[row][leadColumn].character != " " else { return }
        let merged = String(cells[row][leadColumn].character) + String(character)
        if merged.count == 1, let composed = merged.first {
            cells[row][leadColumn].character = composed
        }
    }

    private mutating func clearWideCellIfNeeded(row: Int, column: Int, style: TerminalTextStyle) {
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        guard cells[row][column].isContinuation else { return }
        var leadColumn = column
        while leadColumn > 0 && cells[row][leadColumn].isContinuation {
            leadColumn -= 1
        }
        cells[row][leadColumn] = TerminalScreenCell(style: style)
        var nextColumn = leadColumn + 1
        while nextColumn < columns && cells[row][nextColumn].isContinuation {
            cells[row][nextColumn] = TerminalScreenCell(style: style)
            nextColumn += 1
        }
    }

    @discardableResult
    mutating func scrollUp(count: Int = 1) -> [[TerminalScreenCell]] {
        scrollUpRegion(top: 0, bottom: rows - 1, count: count)
    }

    mutating func scrollDown(count: Int = 1) {
        _ = scrollDownRegion(top: 0, bottom: rows - 1, count: count)
    }

    @discardableResult
    mutating func scrollUpRegion(top: Int, bottom: Int, count: Int = 1, style: TerminalTextStyle = .default) -> [[TerminalScreenCell]] {
        discardResizeHiddenRows()
        guard let region = normalizedRegion(top: top, bottom: bottom) else { return [] }
        let amount = min(max(1, count), region.count)
        let removed = Array(cells[region.lowerBound..<(region.lowerBound + amount)])
        cells.removeSubrange(region.lowerBound..<(region.lowerBound + amount))
        cells.insert(
            contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: amount),
            at: region.upperBound - amount + 1
        )
        return removed
    }

    @discardableResult
    mutating func scrollDownRegion(top: Int, bottom: Int, count: Int = 1, style: TerminalTextStyle = .default) -> [[TerminalScreenCell]] {
        discardResizeHiddenRows()
        guard let region = normalizedRegion(top: top, bottom: bottom) else { return [] }
        let amount = min(max(1, count), region.count)
        let lower = region.upperBound - amount + 1
        let removed = Array(cells[lower...region.upperBound])
        cells.removeSubrange(lower...region.upperBound)
        cells.insert(
            contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: amount),
            at: region.lowerBound
        )
        return removed
    }

    mutating func insertLines(at row: Int, count: Int, style: TerminalTextStyle = .default) {
        insertLines(at: row, bottom: rows - 1, count: count, style: style)
    }

    mutating func insertLines(at row: Int, bottom: Int, count: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard let region = normalizedRegion(top: row, bottom: bottom) else { return }
        let amount = min(max(1, count), region.count)
        cells.removeSubrange((region.upperBound - amount + 1)...region.upperBound)
        cells.insert(contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: amount), at: region.lowerBound)
    }

    mutating func deleteLines(at row: Int, count: Int, style: TerminalTextStyle = .default) {
        deleteLines(at: row, bottom: rows - 1, count: count, style: style)
    }

    mutating func deleteLines(at row: Int, bottom: Int, count: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard let region = normalizedRegion(top: row, bottom: bottom) else { return }
        let amount = min(max(1, count), region.count)
        cells.removeSubrange(region.lowerBound..<(region.lowerBound + amount))
        cells.insert(
            contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: amount),
            at: region.upperBound - amount + 1
        )
    }

    mutating func insertCharacters(row: Int, column: Int, count: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        let amount = min(max(1, count), columns - column)
        var line = cells[row]
        line.removeSubrange((columns - amount)..<columns)
        line.insert(contentsOf: Array(repeating: TerminalScreenCell(style: style), count: amount), at: column)
        cells[row] = line
    }

    mutating func deleteCharacters(row: Int, column: Int, count: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        let amount = min(max(1, count), columns - column)
        var line = cells[row]
        line.removeSubrange(column..<(column + amount))
        line.append(contentsOf: Array(repeating: TerminalScreenCell(style: style), count: amount))
        cells[row] = line
    }

    mutating func discardResizeHiddenRows() {
        resizeHiddenRowsAbove.removeAll(keepingCapacity: true)
        resizeHiddenRowsBelow.removeAll(keepingCapacity: true)
    }

    private func normalizedRegion(top: Int, bottom: Int) -> ClosedRange<Int>? {
        guard rows > 0 else { return nil }
        let lower = max(0, min(top, rows - 1))
        let upper = max(0, min(bottom, rows - 1))
        guard lower <= upper else { return nil }
        return lower...upper
    }

    static func blankRow(columns: Int, style: TerminalTextStyle = .default) -> [TerminalScreenCell] {
        Array(repeating: TerminalScreenCell(style: style), count: columns)
    }

    private static func resize(row: [TerminalScreenCell], columns: Int) -> [TerminalScreenCell] {
        if row.count == columns {
            return row
        }
        if row.count > columns {
            return Array(row.prefix(columns))
        }
        return row + Array(repeating: TerminalScreenCell(), count: columns - row.count)
    }
}

private struct TerminalScreenCell {
    var character: Character = " "
    var isContinuation = false
    var style = TerminalTextStyle.default
}

private struct TerminalTextStyle: Equatable {
    var foreground: SIMD4<Float>
    var background: SIMD4<Float>
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var blink = false
    var strikethrough = false
    var inverse = false

    static let `default` = TerminalTextStyle(
        foreground: SIMD4<Float>(0.92, 0.92, 0.92, 1),
        background: SIMD4<Float>(0, 0, 0, 1)
    )

    var effectiveForeground: SIMD4<Float> {
        if inverse {
            return background
        }
        let weighted = bold ? brighten(foreground) : foreground
        return dim ? dimmed(weighted, against: background) : weighted
    }

    var effectiveBackground: SIMD4<Float> {
        inverse ? foreground : background
    }

    var isLightBackground: Bool {
        luminance(background) > 0.5
    }

    static func ansiColor(_ index: Int, bright: Bool) -> SIMD4<Float> {
        (bright ? DesignTokens.Color.ansiBright : DesignTokens.Color.ansiNormal)[max(0, min(index, 7))]
    }

    static func rgb(red: Int, green: Int, blue: Int) -> SIMD4<Float> {
        SIMD4<Float>(
            Float(max(0, min(red, 255))) / 255,
            Float(max(0, min(green, 255))) / 255,
            Float(max(0, min(blue, 255))) / 255,
            1
        )
    }

    static func xterm256Color(_ value: Int) -> SIMD4<Float> {
        let index = max(0, min(value, 255))
        if index < 16 {
            return ansiColor(index % 8, bright: index >= 8)
        }
        if index < 232 {
            let cube = index - 16
            let r = cube / 36
            let g = (cube / 6) % 6
            let b = cube % 6
            func component(_ v: Int) -> Int { v == 0 ? 0 : 55 + v * 40 }
            return rgb(red: component(r), green: component(g), blue: component(b))
        }
        let gray = 8 + (index - 232) * 10
        return rgb(red: gray, green: gray, blue: gray)
    }

    private func brighten(_ color: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(min(color.x * 1.15, 1), min(color.y * 1.15, 1), min(color.z * 1.15, 1), color.w)
    }

    private func dimmed(_ color: SIMD4<Float>, against background: SIMD4<Float>) -> SIMD4<Float> {
        if luminance(background) > 0.5 {
            return blend(color, background, amount: dimBlendAmount(for: color))
        }
        return SIMD4<Float>(color.x * 0.62, color.y * 0.62, color.z * 0.62, color.w)
    }

    private func dimBlendAmount(for color: SIMD4<Float>) -> Float {
        chroma(color) > 0.08 ? 0.04 : 0.48
    }

    private func chroma(_ color: SIMD4<Float>) -> Float {
        max(color.x, max(color.y, color.z)) - min(color.x, min(color.y, color.z))
    }

    private func blend(_ color: SIMD4<Float>, _ background: SIMD4<Float>, amount: Float) -> SIMD4<Float> {
        let kept = max(0, min(1, 1 - amount))
        let mixed = max(0, min(1, amount))
        return SIMD4<Float>(
            color.x * kept + background.x * mixed,
            color.y * kept + background.y * mixed,
            color.z * kept + background.z * mixed,
            color.w
        )
    }

    private func luminance(_ color: SIMD4<Float>) -> Float {
        color.x * 0.2126 + color.y * 0.7152 + color.z * 0.0722
    }
}

private struct CsiParameters {
    let isPrivate: Bool
    let values: [Int]

    init(_ raw: String) {
        let privatePrefixes = CharacterSet(charactersIn: "<=>?")
        let trimmed = raw.trimmingCharacters(in: privatePrefixes)
        isPrivate = raw.first.map { privatePrefixes.contains($0.unicodeScalars.first!) } ?? false
        values = trimmed
            .split(whereSeparator: { $0 == ";" || $0 == ":" })
            .map { part in
                Int(part.filter(\.isNumber)) ?? 0
            }
    }

    func value(at index: Int, default defaultValue: Int) -> Int {
        guard values.indices.contains(index), values[index] > 0 else { return defaultValue }
        return values[index]
    }
}

private extension Character {
    var terminalColumnWidth: Int {
        if unicodeScalars.allSatisfy({ CharacterSet.nonBaseCharacters.contains($0) }) {
            return 0
        }
        let widthScalar = firstBaseScalarForTerminalWidth ?? unicodeScalars.first
        guard let scalar = widthScalar else { return 1 }
        let value = scalar.value
        if value == 0 || (value < 32) || (0x7f..<0xa0).contains(value) {
            return 0
        }
        if value >= 0x1100 &&
            (value <= 0x115f ||
             value == 0x2329 || value == 0x232a ||
             (0x2e80...0xa4cf).contains(value) ||
             (0xac00...0xd7a3).contains(value) ||
             (0xf900...0xfaff).contains(value) ||
             (0xfe10...0xfe19).contains(value) ||
             (0xfe30...0xfe6f).contains(value) ||
             (0xff00...0xff60).contains(value) ||
             (0xffe0...0xffe6).contains(value) ||
             (0x1f300...0x1f64f).contains(value) ||
             (0x1f900...0x1f9ff).contains(value)) {
            return 2
        }
        return 1
    }

    var isTerminalPrintableGrapheme: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let value = scalar.value
        return value != 0x1b && value != 10 && value != 13 && value != 8 && value != 9 &&
            value >= 32 && value != 127
    }

    private var firstBaseScalarForTerminalWidth: UnicodeScalar? {
        unicodeScalars.first { scalar in
            !CharacterSet.nonBaseCharacters.contains(scalar) &&
                scalar.value != 0x200d &&
                !(0xfe00...0xfe0f).contains(scalar.value)
        }
    }
}

private extension String {
    var terminalColumnWidth: Int {
        reduce(0) { $0 + $1.terminalColumnWidth }
    }
}

private extension SIMD4 where Scalar == Float {
    func sameColor(as other: SIMD4<Float>) -> Bool {
        x == other.x && y == other.y && z == other.z && w == other.w
    }

    var debugRGB: String {
        String(format: "(%0.3f,%0.3f,%0.3f,%0.3f)", x, y, z, w)
    }
}
