import AppKit
import KurottyCore

@MainActor
final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
    static let titleDidChangeNotification = Notification.Name("dev.kurotty.terminalSurface.titleDidChange")
    static let focusDidChangeNotification = Notification.Name("dev.kurotty.terminalSurface.focusDidChange")
    static let titleNotificationKey = "title"

    private let core: any TerminalCore = TerminalCoreFactory.makeDefaultCore(
        cols: UInt32(AppConstants.Terminal.defaultColumns),
        rows: UInt32(AppConstants.Terminal.defaultRows)
    )
    private let shell: any TerminalSession = TerminalSessionFactory.makeDefaultSession()
    private let notifier = TerminalNotifier.shared
    private let renderer: any TerminalAppKitRenderer
    private lazy var scrollIndicatorCoordinator = TerminalScrollIndicatorCoordinator { [weak self] normalizedOffset in
        self?.setScrollbackOffset(fromNormalizedOffset: normalizedOffset)
    }
    private var terminalDefaultStyle: TerminalTextStyle
    private var terminalAnsiColors: [SIMD4<Float>]
    private var maxScrollbackRows: Int
    private var screen = TerminalScreen(rows: AppConstants.Terminal.defaultRows, columns: AppConstants.Terminal.defaultColumns)
    private var scrollbackRows = BoundedScrollbackRows()
    private var scrollbackOffset = 0
    private var normalScreenSnapshot: TerminalScreen?
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursorRow = 0
    private var savedCursorColumn = 0
    private var scrollRegionTop = 0
    private var scrollRegionBottom = AppConstants.Terminal.defaultRows - 1
    private var cursorVisible = true
    private var cursorBlinkOn = true
    private var cursorBlinkTimer: Timer?
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
    private var selectionGestureState = TerminalSelectionGestureState()
    private var terminalTrackingArea: NSTrackingArea?
    private var hoveredLinkRange: TerminalLinkRange?
    private var markedText = NSMutableAttributedString()
    private var inputSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var markedTextAnchor: TerminalCellPosition?
    private var pendingMarkedTextAnchor: TerminalCellPosition?
    private var keyboardSelectionInputStart: TerminalCellPosition?
    private var lastSentSize = TerminalSize(columns: AppConstants.Terminal.defaultColumns, rows: AppConstants.Terminal.defaultRows)
    private var font: NSFont
    private var pendingDirtyRows = Set<Int>()
    private var pendingFullDamage = true
    private var pendingOutputText = ""
    private var isOutputFlushScheduled = false
    private var scrollbackRowsAppendedDuringOutput = 0
    private var submittedInputSequence = 0
    private var backgroundTaskInputSequence: Int?
    private var backgroundTaskHasOutput = false
    private var backgroundTaskOutputText = ""
    private var backgroundTaskNotificationWorkItem: DispatchWorkItem?
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
        renderer = TerminalRendererFactory.makeDefaultRenderer(
            font: configuredFont,
            backgroundColor: terminalDefaultStyle.background,
            cursorColor: settings.terminal.colors.cursorColor
        )
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = terminalDefaultStyle.background.cgColor
        let rendererView = renderer.rendererView
        rendererView.translatesAutoresizingMaskIntoConstraints = false
        renderer.onPresented = { [weak self] in
            self?.rendererFramePresented()
        }
        addSubview(rendererView)
        NSLayoutConstraint.activate([
            rendererView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rendererView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rendererView.topAnchor.constraint(equalTo: topAnchor),
            rendererView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scrollIndicatorCoordinator.install(in: self)
        shell.onOutput = { [weak self] text in
            Task { @MainActor in
                self?.enqueueOutput(text)
            }
        }
        if DebugOptions.ptyLog {
            shell.onRawOutput = { data in
                let metadata = TerminalRawPtyLogMetadata(data: data)
                NSLog("%@: %@", AppConstants.Diagnostics.ptyRawLogPrefix, metadata.description)
            }
        }
        renderer.diagnosticRenderingLogEnabled = DebugOptions.layout || DebugOptions.renderRects || DebugOptions.dirtyRects || DebugOptions.backgroundRuns || DebugOptions.cursorCell || DebugOptions.scrollRegion
        // Keep the scaffold available as an explicit diagnostic escape hatch for
        // resize, IME, scrollback, or tmux status-line dirty-rect regressions.
        renderer.diagnosticFullRedrawEnabled = DebugOptions.fullModelRedraw || AppConstants.Rendering.forceFullModelRedrawUntilDamageIsVerified
        renderer.diagnosticCellBoundaryOverlayEnabled = DebugOptions.renderRects
        renderer.diagnosticBaselineOverlayEnabled = DebugOptions.renderRects
        renderer.diagnosticGlyphQuadOverlayEnabled = DebugOptions.renderRects
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: AppSettingsStore.shared
        )
        observeInputSourceChanges()
        shell.start(workingDirectory: settings.shell.workingDirectory)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isOpaque: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let terminalTrackingArea {
            removeTrackingArea(terminalTrackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        terminalTrackingArea = nextTrackingArea
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            startCursorBlinking()
            NotificationCenter.default.post(name: Self.focusDidChangeNotification, object: self)
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            stopCursorBlinking(showCursor: true)
            NotificationCenter.default.post(name: Self.focusDidChangeNotification, object: self)
        }
        return didResignFirstResponder
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        currentBackingScale = effectiveBackingScale
        observeWindowScreenChanges()
        syncSizeWithView()
        updateCursorBlinkStateForFocus()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopCursorBlinking(showCursor: true)
        }
        removeWindowScreenObserver()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        handleDisplayConfigurationChanged()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let position = cellPosition(for: event)
        if event.modifierFlags.contains(.command), let link = linkRange(at: position) {
            clearSelection()
            setHoveredLinkRange(link)
            presentOpenLinkDialog(for: link)
            return
        }
        if event.clickCount >= 2 {
            selectWord(at: position)
            return
        }
        selectionGestureState.beginCharacterSelection()
        selectionAnchor = position
        selectionFocus = nil
        markFullDamage()
        updateRendererFrame()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredLinkRange(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredLinkRange(nil)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateHoveredLinkRange(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelectionFocus(with: event, autoscroll: true)
    }

    override func mouseUp(with event: NSEvent) {
        updateSelectionFocus(with: event, autoscroll: false)
    }

    override func scrollWheel(with event: NSEvent) {
        let lineDelta = max(1, Int(abs(event.scrollingDeltaY) / 8))
        let maxOffset = maxScrollbackOffset()
        let previousOffset = scrollbackOffset
        if event.scrollingDeltaY > 0 {
            scrollbackOffset = min(maxOffset, scrollbackOffset + lineDelta)
        } else if event.scrollingDeltaY < 0 {
            scrollbackOffset = max(0, scrollbackOffset - lineDelta)
        }
        if scrollbackOffset != previousOffset {
            markFullDamage()
        }
        updateScrollIndicator()
        updateRendererFrame()
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
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        return handleCommandKey(event) || handleKeyEquivalentTerminalControl(event) || super.performKeyEquivalent(with: event)
    }

    func rendererFramePresented() {
        core.recordFramePresented()
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        guard !text.isEmpty else { return }
        if bracketedPasteEnabled {
            pendingMarkedTextAnchor = nil
            send("\u{1b}[200~\(text)\u{1b}[201~")
        } else {
            pendingMarkedTextAnchor = nil
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

    func sendText(_ text: String) {
        send(text)
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        if TerminalCommandDispatcher.dispatchWindowCommand(from: self, event: event) {
            return true
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              flags.subtracting([.command, .shift]).isEmpty,
              let characters = TerminalTextInputRouter.latinKeyEquivalent(for: event)
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
        if let controlText = TerminalTextInputRouter.terminalControlText(for: event) {
            send(controlText)
            return true
        }
        if let commandControlText = TerminalTextInputRouter.commandShortcutControlText(for: event) {
            send(commandControlText)
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

    private func handleKeyEquivalentTerminalControl(_ event: NSEvent) -> Bool {
        if let commandControlText = TerminalTextInputRouter.commandShortcutControlText(for: event) {
            resetMarkedTextForInputSourceChange()
            send(commandControlText)
            return true
        }
        guard !hasMarkedText() else {
            return false
        }
        return handleTerminalControlKey(event)
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
        updateRendererFrame()
    }

    private func setScrollbackOffset(fromNormalizedOffset normalizedOffset: CGFloat) {
        let maxOffset = maxScrollbackOffset()
        guard maxOffset > 0 else { return }
        let nextOffset = min(maxOffset, max(0, Int(round(normalizedOffset * CGFloat(maxOffset)))))
        guard nextOffset != scrollbackOffset else { return }
        scrollbackOffset = nextOffset
        markFullDamage()
        updateScrollIndicator()
        updateRendererFrame()
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

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        // Reset only kurotty's overlay state here. Calling discardMarkedText()
        // from the global keyboardSelectionDidChange notification re-enters
        // AppKit/IMK synchronously; with split panes every surface observes the
        // notification, which can pin the main thread during the next key event.
        resetMarkedTextForInputSourceChange()
    }

    private func resetMarkedTextForInputSourceChange() {
        guard hasMarkedText() else { return }
        markMarkedTextDirty()
        markedText = NSMutableAttributedString()
        inputSelectedRange = NSRange(location: NSNotFound, length: 0)
        markedTextAnchor = nil
        pendingMarkedTextAnchor = nil
        markDirty(row: cursorRow)
        updateRendererFrame()
    }

    private func handleDisplayConfigurationChanged() {
        // Moving between Retina and 1x displays can change effective cell metrics and
        // PTY dimensions. Force a full frame so Metal receives fresh cell geometry.
        currentBackingScale = effectiveBackingScale
        markFullDamage()
        syncSizeWithView()
        updateRendererFrame()
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

    private func updateRendererFrame() {
        let metrics = terminalMetrics()
        let damage = consumePendingDamage(metrics: metrics)
        var cells: [TerminalCell] = []
        var backgrounds: [TerminalBackground] = []
        var decorations: [TerminalDecoration] = []
        cells.reserveCapacity(metrics.size.rows * metrics.size.columns / AppConstants.Rendering.visibleCellReserveDivisor)
        let rowsToRender = visibleRowsForRendering(limit: metrics.size.rows)
        let visibleStartRow = visibleRowStartIndex(limit: metrics.size.rows)
        let selectedCells = selectedCellSet()
        for row in 0..<rowsToRender.count {
            let sourceRow = rowsToRender[row]
            for column in 0..<min(sourceRow.count, metrics.size.columns) {
                let cell = sourceRow[column]
                let position = TerminalCellPosition(row: visibleStartRow + row, column: column)
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
                if hoveredLinkRange?.contains(row: row, column: column) == true {
                    decorations.append(TerminalDecoration(
                        column: column,
                        row: row,
                        width: max(1, cell.character.terminalColumnWidth),
                        kind: .underline,
                        color: TerminalLinkRange.hoverColor
                    ))
                }
                if appendBoxDrawingDecoration(
                    for: cell.character,
                    column: column,
                    row: row,
                    color: isSelected ? TerminalSelectionStyle.foregroundColor : cell.style.effectiveForeground,
                    to: &decorations
                ) {
                    continue
                }
                if appendBlockElementDecoration(
                    for: cell.character,
                    column: column,
                    row: row,
                    color: isSelected ? TerminalSelectionStyle.foregroundColor : cell.style.effectiveForeground,
                    to: &decorations
                ) {
                    continue
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
        let markedTextPosition = renderedMarkedTextPosition(visibleStartRow: visibleStartRow)
        let displayCursorRow = markedTextPosition?.row ?? cursorRow
        let displayCursorColumn = markedTextPosition?.column ?? cursorColumn
        renderer.update(frame: TerminalFrame(
            cells: cells,
            backgrounds: backgrounds,
            decorations: decorations,
            defaultForeground: terminalDefaultStyle.foreground,
            defaultBackground: terminalDefaultStyle.background,
            dirtyRows: damage.rows,
            dirtyRects: damage.rects,
            isFullDamage: damage.isFull,
            cursorColumn: min(displayCursorColumn + markedText.string.terminalColumnWidth, metrics.size.columns - 1),
            cursorRow: cursorVisible && scrollbackOffset == 0 ? min(displayCursorRow, metrics.size.rows - 1) : -1,
            // Inactive panes keep a steady cursor; focus only controls blink.
            cursorBlinkOn: window?.firstResponder !== self || cursorBlinkOn,
            markedTextColumn: displayCursorColumn,
            markedText: markedText.string,
            markedTextSelectedRange: .none,
            columns: metrics.size.columns,
            visibleRows: metrics.size.rows,
            cellSize: metrics.cellSize,
            padding: TerminalFramePoint(x: Double(padding.left), y: Double(padding.top))
        ))
        logScreenDumpIfNeeded(rows: rowsToRender, damage: damage, metrics: metrics)
        debugFrameIndex &+= 1
    }

    private func renderedMarkedTextPosition(visibleStartRow: Int) -> TerminalCellPosition? {
        guard markedText.length > 0 else { return nil }
        let anchor = markedTextAnchor ?? TerminalCellPosition(row: cursorRow, column: cursorColumn)
        return TerminalCellPosition(row: anchor.row - visibleStartRow, column: anchor.column)
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

    private func appendBoxDrawingDecoration(
        for character: Character,
        column: Int,
        row: Int,
        color: SIMD4<Float>,
        to decorations: inout [TerminalDecoration]
    ) -> Bool {
        let left: Bool
        let right: Bool
        let up: Bool
        let down: Bool
        switch character {
        case "─":
            left = true; right = true; up = false; down = false
        case "│":
            left = false; right = false; up = true; down = true
        case "┌", "╭":
            left = false; right = true; up = false; down = true
        case "┐", "╮":
            left = true; right = false; up = false; down = true
        case "└", "╰":
            left = false; right = true; up = true; down = false
        case "┘", "╯":
            left = true; right = false; up = true; down = false
        case "├":
            left = false; right = true; up = true; down = true
        case "┤":
            left = true; right = false; up = true; down = true
        case "┬":
            left = true; right = true; up = false; down = true
        case "┴":
            left = true; right = true; up = true; down = false
        case "┼":
            left = true; right = true; up = true; down = true
        default:
            return false
        }
        decorations.append(TerminalDecoration(
            column: column,
            row: row,
            width: 1,
            kind: .boxDrawing(left: left, right: right, up: up, down: down),
            color: color
        ))
        return true
    }

    private func appendBlockElementDecoration(
        for character: Character,
        column: Int,
        row: Int,
        color: SIMD4<Float>,
        to decorations: inout [TerminalDecoration]
    ) -> Bool {
        let rect: (x: Double, y: Double, width: Double, height: Double)
        switch character {
        case "█":
            rect = (0, 0, 1, 1)
        case "▉":
            rect = (0, 0, 7.0 / 8.0, 1)
        case "▊":
            rect = (0, 0, 6.0 / 8.0, 1)
        case "▋":
            rect = (0, 0, 5.0 / 8.0, 1)
        case "▌":
            rect = (0, 0, 0.5, 1)
        case "▍":
            rect = (0, 0, 3.0 / 8.0, 1)
        case "▎":
            rect = (0, 0, 2.0 / 8.0, 1)
        case "▏":
            rect = (0, 0, 1.0 / 8.0, 1)
        case "▐":
            rect = (0.5, 0, 0.5, 1)
        case "▀":
            rect = (0, 0.5, 1, 0.5)
        case "▄":
            rect = (0, 0, 1, 0.5)
        case "▁":
            rect = (0, 0, 1, 1.0 / 8.0)
        case "▂":
            rect = (0, 0, 1, 2.0 / 8.0)
        case "▃":
            rect = (0, 0, 1, 3.0 / 8.0)
        case "▅":
            rect = (0, 0, 1, 5.0 / 8.0)
        case "▆":
            rect = (0, 0, 1, 6.0 / 8.0)
        case "▇":
            rect = (0, 0, 1, 7.0 / 8.0)
        default:
            return false
        }
        decorations.append(TerminalDecoration(
            column: column,
            row: row,
            width: 1,
            kind: .blockElement(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
            color: color
        ))
        return true
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = TerminalTextInputRouter.committedText(from: string)
        TerminalTextInputRouter.logInsertText(text, replacementRange: replacementRange)
        recordPendingMarkedTextAnchor(afterCommitting: text)
        unmarkText()
        guard !text.isEmpty else { return }
        TerminalTextInputRouter.logPTYWrite(text, source: "insertText")
        send(text)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            pendingMarkedTextAnchor = nil
            send("\r")
        case #selector(insertTab(_:)):
            pendingMarkedTextAnchor = nil
            send("\t")
        case #selector(cancelOperation(_:)):
            resetMarkedTextForInputSourceChange()
            send("\u{1b}")
        case #selector(deleteBackward(_:)):
            pendingMarkedTextAnchor = nil
            send("\u{7f}")
        case #selector(deleteForward(_:)):
            pendingMarkedTextAnchor = nil
            send("\u{1b}[3~")
        case #selector(moveToBeginningOfLine(_:)):
            pendingMarkedTextAnchor = nil
            send("\u{1b}[H")
        case #selector(moveToEndOfLine(_:)):
            pendingMarkedTextAnchor = nil
            send("\u{1b}[F")
        case #selector(moveUp(_:)):
            pendingMarkedTextAnchor = nil
            send("\u{1b}[A")
        case #selector(moveDown(_:)):
            pendingMarkedTextAnchor = nil
            send("\u{1b}[B")
        case #selector(moveLeft(_:)):
            pendingMarkedTextAnchor = nil
            send("\u{1b}[D")
        case #selector(moveRight(_:)):
            pendingMarkedTextAnchor = nil
            send("\u{1b}[C")
        case #selector(moveUpAndModifySelection(_:)):
            pendingMarkedTextAnchor = nil
            extendKeyboardSelection(rowDelta: -1, columnDelta: 0)
        case #selector(moveDownAndModifySelection(_:)):
            pendingMarkedTextAnchor = nil
            extendKeyboardSelection(rowDelta: 1, columnDelta: 0)
        case #selector(moveRightAndModifySelection(_:)):
            pendingMarkedTextAnchor = nil
            extendKeyboardSelection(rowDelta: 0, columnDelta: 1)
        case #selector(moveLeftAndModifySelection(_:)):
            pendingMarkedTextAnchor = nil
            extendKeyboardSelection(rowDelta: 0, columnDelta: -1)
        case #selector(scrollPageUp(_:)):
            pendingMarkedTextAnchor = nil
            send("\u{1b}[5~")
        case #selector(scrollPageDown(_:)):
            pendingMarkedTextAnchor = nil
            send("\u{1b}[6~")
        default:
            break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        followLiveOutputForUserInput()
        markMarkedTextDirty()
        let attr = string as? NSAttributedString ?? NSAttributedString(string: string as? String ?? "")
        TerminalTextInputRouter.logMarkedText(attr.string, selectedRange: selectedRange, replacementRange: replacementRange)
        if markedText.length == 0 {
            markedTextAnchor = pendingMarkedTextAnchor ?? TerminalCellPosition(row: cursorRow, column: cursorColumn)
            pendingMarkedTextAnchor = nil
        }
        markedText = NSMutableAttributedString(attributedString: attr)
        inputSelectedRange = selectedRange
        markMarkedTextDirty()
        updateRendererFrame()
    }

    func unmarkText() {
        TerminalTextInputRouter.logUnmarkText()
        markMarkedTextDirty()
        markedText = NSMutableAttributedString()
        inputSelectedRange = NSRange(location: NSNotFound, length: 0)
        markedTextAnchor = nil
        markDirty(row: cursorRow)
        updateRendererFrame()
    }

    private func recordPendingMarkedTextAnchor(afterCommitting text: String) {
        guard !text.isEmpty else {
            pendingMarkedTextAnchor = nil
            return
        }
        let anchor = markedTextAnchor ?? TerminalCellPosition(row: cursorRow, column: cursorColumn)
        pendingMarkedTextAnchor = advancedTerminalPosition(from: anchor, by: text)
    }

    private func advancedTerminalPosition(from position: TerminalCellPosition, by text: String) -> TerminalCellPosition {
        var row = position.row
        var column = position.column
        let columns = max(1, terminalMetrics().size.columns)
        for character in text {
            let width = character.terminalColumnWidth
            guard width > 0 else { continue }
            if width == 2 && column == columns - 1 {
                row += 1
                column = 0
            } else if column >= columns {
                row += 1
                column = 0
            }
            column += width
        }
        return TerminalCellPosition(row: row, column: min(column, columns - 1))
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
        let cellWidth = CGFloat(metrics.cellSize.width)
        let cellHeight = CGFloat(metrics.cellSize.height)
        let column = Int((point.x - padding.left) / cellWidth)
        let row = Int((bounds.height - padding.top - point.y) / cellHeight)
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

    private func send(_ text: String, recordsUserActivity: Bool = true) {
        clearSelection()
        if recordsUserActivity {
            followLiveOutputForUserInput()
            recordKeyboardSelectionInputStartIfNeeded(for: text)
            recordUserInput(text)
        }
        shell.write(text)
    }

    private func followLiveOutputForUserInput() {
        guard scrollbackOffset != 0 else { return }
        scrollbackOffset = 0
        markFullDamage()
        updateScrollIndicator()
        updateRendererFrame()
    }

    private func sendTerminalResponse(_ text: String) {
        guard shell.canReceiveTerminalResponseWithoutEcho() else {
            return
        }
        send(text, recordsUserActivity: false)
    }

    private func recordUserInput(_ text: String) {
        guard text.contains("\r") || text.contains("\n") else {
            return
        }
        pendingMarkedTextAnchor = nil
        keyboardSelectionInputStart = nil
        submittedInputSequence &+= 1
        backgroundTaskInputSequence = submittedInputSequence
        backgroundTaskHasOutput = false
        backgroundTaskOutputText = ""
        backgroundTaskNotificationWorkItem?.cancel()
        backgroundTaskNotificationWorkItem = nil
    }

    private func recordKeyboardSelectionInputStartIfNeeded(for text: String) {
        guard keyboardSelectionInputStart == nil else { return }
        guard text.contains(where: { $0.isTerminalPrintableGrapheme }) else { return }
        keyboardSelectionInputStart = TerminalCellPosition(
            row: visibleRowStartIndex(limit: terminalMetrics().size.rows) + cursorRow,
            column: cursorColumn
        )
    }

    private func recordOutputForBackgroundTask(_ text: String) {
        guard backgroundTaskInputSequence != nil else {
            return
        }
        backgroundTaskHasOutput = true
        appendBackgroundTaskOutputText(text)
        scheduleBackgroundTaskIdleCheck()
    }

    private func appendBackgroundTaskOutputText(_ text: String) {
        backgroundTaskOutputText.append(text)
        let maxCharacters = AppConstants.Notifications.backgroundTaskOutputCaptureMaxCharacters
        guard backgroundTaskOutputText.count > maxCharacters else {
            return
        }
        let startIndex = backgroundTaskOutputText.index(backgroundTaskOutputText.endIndex, offsetBy: -maxCharacters)
        backgroundTaskOutputText = String(backgroundTaskOutputText[startIndex...])
    }

    private func scheduleBackgroundTaskIdleCheck() {
        guard let inputSequence = backgroundTaskInputSequence else {
            return
        }
        backgroundTaskNotificationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.notifyBackgroundTaskIfIdle(inputSequence: inputSequence)
            }
        }
        backgroundTaskNotificationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppConstants.Notifications.backgroundTaskIdleSeconds,
            execute: workItem
        )
    }

    private func notifyBackgroundTaskIfIdle(inputSequence: Int) {
        guard backgroundTaskInputSequence == inputSequence, backgroundTaskHasOutput else {
            return
        }
        backgroundTaskInputSequence = nil
        backgroundTaskHasOutput = false
        backgroundTaskNotificationWorkItem = nil
        let outputText = backgroundTaskOutputText
        backgroundTaskOutputText = ""
        guard shouldDeliverUserNotification else {
            return
        }
        let body = backgroundTaskNotificationBody(outputText: outputText)
        notifier.notifyBackgroundTaskCompleted(body: body)
    }

    private var isTerminalFocusedForUser: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self
    }

    private var shouldDeliverUserNotification: Bool {
        !isTerminalFocusedForUser
    }

    private func backgroundTaskNotificationBody(outputText: String) -> String {
        guard let summary = TerminalNotificationSummary.latestMeaningfulText(fromOutputText: outputText) else {
            return AppConstants.Notifications.backgroundTaskFinishedBody
        }
        if summary.count <= AppConstants.Notifications.backgroundTaskSummaryMaxCharacters {
            return summary
        }
        return String(summary.prefix(AppConstants.Notifications.backgroundTaskSummaryMaxCharacters))
    }

    private func enqueueOutput(_ text: String) {
        pendingOutputText.append(text)
        guard !isOutputFlushScheduled else { return }
        isOutputFlushScheduled = true
        // TUIs often clear and repaint the same status/input row across adjacent
        // PTY chunks. Coalescing one display tick avoids presenting the cleared
        // intermediate model as visible flicker or a cursor jump.
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.Component.ptyOutputCoalescingDelaySeconds) { [weak self] in
            Task { @MainActor in
                self?.flushPendingOutput()
            }
        }
    }

    private func flushPendingOutput() {
        isOutputFlushScheduled = false
        let text = pendingOutputText
        pendingOutputText = ""
        guard !text.isEmpty else { return }
        appendOutput(text)
        if !pendingOutputText.isEmpty {
            enqueueOutput("")
        }
    }

    private func appendOutput(_ text: String) {
        let previousCursorRow = cursorRow
        let previousScrollbackOffset = scrollbackOffset
        scrollbackRowsAppendedDuringOutput = 0
        let shouldFollowOutput = scrollbackOffset == 0
        if shouldFollowOutput {
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
        recordOutputForBackgroundTask(text)
        pendingMarkedTextAnchor = nil
        markDirty(row: cursorRow)
        let appendedScrollbackCount = scrollbackRowsAppendedDuringOutput
        if !shouldFollowOutput, appendedScrollbackCount > 0 {
            scrollbackOffset = min(maxScrollbackOffset(), scrollbackOffset + appendedScrollbackCount)
            markFullDamage()
        }
        scrollbackRowsAppendedDuringOutput = 0
        updateScrollIndicator()
        updateRendererFrame()
    }

    private func visibleText() -> String {
        visibleRowsForRendering(limit: screen.rows).map { row in
            String(row.map(\.character)).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private func selectedText() -> String? {
        guard let range = normalizedSelectionRange() else { return nil }
        let rows = allRowsForSelection()
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
            selectedLines.append(TerminalSelectionText.line(from: cells.map {
                TerminalWordSelection.Cell(character: $0.character, isContinuation: $0.isContinuation)
            }))
        }
        return selectedLines.joined(separator: "\n")
    }

    private func selectedCellSet() -> Set<TerminalCellPosition> {
        guard let range = normalizedSelectionRange() else { return [] }
        let rows = visibleRowsForRendering(limit: terminalMetrics().size.rows)
        var cells = Set<TerminalCellPosition>()
        for row in range.start.row...range.end.row {
            let sourceRow = rows.indices.contains(row) ? rows[row] : []
            let startColumn = row == range.start.row ? range.start.column : 0
            let baseEndColumn = row == range.end.row ? range.end.column : screen.columns - 1
            let selectionCells = sourceRow.map {
                TerminalWordSelection.Cell(character: $0.character, isContinuation: $0.isContinuation)
            }
            let endColumn = TerminalWordSelection.Bounds(startColumn: startColumn, endColumn: baseEndColumn)
                .highlightEndColumn(in: selectionCells)
            guard startColumn <= endColumn else { continue }
            for column in startColumn...endColumn {
                cells.insert(TerminalCellPosition(row: row, column: column))
            }
        }
        return cells
    }

    private func normalizedSelectionRange() -> TerminalSelectionRange? {
        guard let anchor = selectionAnchor, let focus = selectionFocus else { return nil }
        let normalized = TerminalSelectionRangeModel.normalized(
            anchor: TerminalSelectionPosition(row: anchor.row, column: anchor.column),
            focus: TerminalSelectionPosition(row: focus.row, column: focus.column)
        )
        guard let normalized else { return nil }
        return TerminalSelectionRange(
            start: TerminalCellPosition(row: normalized.start.row, column: normalized.start.column),
            end: TerminalCellPosition(row: normalized.end.row, column: normalized.end.column)
        )
    }

    private func updateCursorBlinkStateForFocus() {
        if window?.firstResponder === self {
            startCursorBlinking()
        } else {
            stopCursorBlinking(showCursor: true)
        }
    }

    private func startCursorBlinking() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkOn = true
        let timer = Timer(timeInterval: AppConstants.Terminal.cursorBlinkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.toggleCursorBlink()
            }
        }
        cursorBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        markFullDamage()
        updateRendererFrame()
    }

    private func stopCursorBlinking(showCursor: Bool) {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        cursorBlinkOn = showCursor
        markFullDamage()
        updateRendererFrame()
    }

    private func toggleCursorBlink() {
        guard window?.firstResponder === self else {
            stopCursorBlinking(showCursor: true)
            return
        }
        cursorBlinkOn.toggle()
        markFullDamage()
        updateRendererFrame()
    }

    private func selectWord(at position: TerminalCellPosition) {
        let rows = visibleRowsForRendering(limit: terminalMetrics().size.rows)
        guard rows.indices.contains(position.row) else {
            clearSelection()
            return
        }
        let row = rows[position.row]
        let cells = row.map { TerminalWordSelection.Cell(character: $0.character, isContinuation: $0.isContinuation) }
        guard let bounds = TerminalWordSelection.bounds(in: cells, clickedColumn: position.column) else {
            clearSelection()
            return
        }

        selectionAnchor = TerminalCellPosition(row: position.row, column: bounds.startColumn)
        selectionFocus = TerminalCellPosition(row: position.row, column: bounds.endColumn)
        selectionGestureState.selectWord()
        markFullDamage()
        updateRendererFrame()
    }

    private func updateSelectionFocus(with event: NSEvent, autoscroll: Bool) {
        guard let anchor = selectionAnchor else { return }
        if autoscroll {
            guard selectionGestureState.shouldUpdateFocusOnPointerDrag() else { return }
            autoscrollSelectionIfNeeded(with: event)
        } else if !selectionGestureState.shouldUpdateFocusOnPointerUp() {
            return
        }
        let focus = cellPosition(for: event)
        selectionFocus = focus == anchor ? nil : focus
        markFullDamage()
        updateRendererFrame()
    }

    private func autoscrollSelectionIfNeeded(with event: NSEvent) {
        guard !scrollbackRows.isEmpty else { return }
        let metrics = terminalMetrics()
        let location = convert(event.locationInWindow, from: nil)
        let threshold = max(CGFloat(metrics.cellSize.height), 18)
        let topEdge = bounds.height - padding.top
        let bottomEdge = padding.bottom

        let rowDelta: Int
        if location.y > topEdge - threshold {
            rowDelta = 1
        } else if location.y < bottomEdge + threshold {
            rowDelta = -1
        } else {
            return
        }

        let previousOffset = scrollbackOffset
        scrollbackOffset = max(0, min(scrollbackRows.count, scrollbackOffset + rowDelta))
        guard scrollbackOffset != previousOffset else { return }

        // Keep the anchor attached to the same visible text while scrollback moves
        // under an active drag; otherwise selection appears to slide away.
        if let anchor = selectionAnchor {
            let clampedRow = max(0, min(metrics.size.rows - 1, anchor.row + scrollbackOffset - previousOffset))
            selectionAnchor = TerminalCellPosition(row: clampedRow, column: anchor.column)
        }
        updateScrollIndicator()
    }

    private func cellPosition(for event: NSEvent) -> TerminalCellPosition {
        let metrics = terminalMetrics()
        let location = convert(event.locationInWindow, from: nil)
        let cellWidth = CGFloat(metrics.cellSize.width)
        let cellHeight = CGFloat(metrics.cellSize.height)
        let rawColumn = Int(floor((location.x - padding.left) / cellWidth))
        let rawRow = Int(floor((bounds.height - location.y - padding.top) / cellHeight))
        let column = max(0, min(metrics.size.columns - 1, rawColumn))
        let visibleRow = max(0, min(metrics.size.rows - 1, rawRow))
        let maxContentRow = max(0, allRowsForSelection().count - 1)
        let row = min(maxContentRow, visibleRowStartIndex(limit: metrics.size.rows) + visibleRow)
        return TerminalCellPosition(row: row, column: column)
    }

    private func extendKeyboardSelection(rowDelta: Int, columnDelta: Int) {
        if scrollbackOffset != 0 {
            scrollbackOffset = 0
            updateScrollIndicator()
        }

        let metrics = terminalMetrics()
        let liveCursorPosition = TerminalCellPosition(
            row: visibleRowStartIndex(limit: metrics.size.rows) + cursorRow,
            column: cursorColumn
        )
        let inputStart = keyboardSelectionInputStart ?? liveCursorPosition
        let anchor = selectionAnchor ?? liveCursorPosition
        let focus = selectionFocus ?? liveCursorPosition
        let nextFocus = clampedSelectionPosition(
            row: focus.row + rowDelta,
            column: focus.column + columnDelta,
            metrics: metrics,
            inputStart: inputStart
        )

        selectionGestureState.beginCharacterSelection()
        selectionAnchor = anchor
        selectionFocus = nextFocus == anchor ? nil : nextFocus
        markFullDamage()
        updateRendererFrame()
    }

    private func clampedSelectionPosition(
        row: Int,
        column: Int,
        metrics: TerminalMetrics,
        inputStart: TerminalCellPosition
    ) -> TerminalCellPosition {
        let maxRow = max(0, allRowsForSelection().count - 1)
        let nextRow = max(inputStart.row, min(maxRow, row))
        let minimumColumn = nextRow == inputStart.row ? inputStart.column : 0
        let nextColumn = max(minimumColumn, min(metrics.size.columns - 1, column))
        return TerminalCellPosition(row: nextRow, column: nextColumn)
    }

    private func updateHoveredLinkRange(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            setHoveredLinkRange(nil)
            return
        }
        setHoveredLinkRange(linkRange(at: cellPosition(for: event)))
    }

    private func setHoveredLinkRange(_ nextRange: TerminalLinkRange?) {
        guard hoveredLinkRange != nextRange else { return }
        if let oldRange = hoveredLinkRange {
            markDirty(row: oldRange.row)
        }
        hoveredLinkRange = nextRange
        if let nextRange {
            markDirty(row: nextRange.row)
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
        updateRendererFrame()
    }

    private func linkRange(at position: TerminalCellPosition) -> TerminalLinkRange? {
        let visibleStart = visibleRowStartIndex(limit: terminalMetrics().size.rows)
        let visibleRow = position.row - visibleStart
        let rowsToRender = visibleRowsForRendering(limit: terminalMetrics().size.rows)
        guard rowsToRender.indices.contains(visibleRow) else { return nil }
        return TerminalLinkRange.find(
            in: rowsToRender[visibleRow],
            row: visibleRow,
            column: position.column
        )
    }

    private func presentOpenLinkDialog(for link: TerminalLinkRange) {
        guard let url = URL(string: link.urlString) else { return }
        let alert = NSAlert()
        alert.messageText = "Open Link?"
        alert.informativeText = link.urlString
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Open in Browser")
        alert.addButton(withTitle: "Cancel")

        if let window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                NSWorkspace.shared.open(url)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private func clearSelection() {
        guard selectionAnchor != nil || selectionFocus != nil else { return }
        selectionGestureState.beginCharacterSelection()
        selectionAnchor = nil
        selectionFocus = nil
        markFullDamage()
    }

    private func visibleRowsForRendering(limit: Int) -> [[TerminalScreenCell]] {
        let allRows = allRowsForSelection()
        guard !allRows.isEmpty else { return [] }
        let visibleCount = max(1, limit)
        let start = visibleRowStartIndex(limit: limit)
        let end = min(allRows.count, start + visibleCount)
        var rows = Array(allRows[start..<end])
        if rows.count < visibleCount {
            rows.append(contentsOf: Array(repeating: TerminalScreen.blankRow(columns: screen.columns), count: visibleCount - rows.count))
        }
        return rows
    }

    private func visibleRowStartIndex(limit: Int) -> Int {
        let allRows = allRowsForSelection()
        guard !allRows.isEmpty else { return 0 }
        let visibleCount = max(1, limit)
        let bottomStart = max(0, allRows.count - visibleCount)
        return max(0, bottomStart - scrollbackOffset)
    }

    private func maxScrollbackOffset(visibleRows: Int? = nil) -> Int {
        let visibleCount = max(1, visibleRows ?? terminalMetrics().size.rows)
        return max(0, allRowsForSelection().count - visibleCount)
    }

    private func allRowsForSelection() -> [[TerminalScreenCell]] {
        scrollbackRows.rows + screen.cells
    }

    private func terminalMetrics() -> TerminalMetrics {
        let scale = currentBackingScale
        let rawLineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        let rawWidth = max(
            AppConstants.Terminal.minimumCellWidthPX,
            ("0" as NSString).size(withAttributes: [.font: font]).width
        )
        let lineHeight = snapMetricToPhysicalPixels(rawLineHeight, scale: scale)
        let width = snapMetricToPhysicalPixels(rawWidth, scale: scale)
        let columns = max(1, Int((bounds.width - padding.left - padding.right) / width))
        let rows = max(1, Int((bounds.height - padding.top - padding.bottom) / lineHeight))
        return TerminalMetrics(
            size: TerminalSize(columns: columns, rows: rows),
            cellSize: TerminalFrameSize(width: Double(width), height: Double(lineHeight))
        )
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
        let previousDefaultStyle = terminalDefaultStyle
        let previousAnsiColors = terminalAnsiColors
        let nextAnsiColors = Self.ansiColors(from: settings)
        font = nextFont
        terminalDefaultStyle = TerminalTextStyle(
            foreground: settings.terminal.colors.foregroundColor,
            background: settings.terminal.colors.backgroundColor
        )
        terminalAnsiColors = nextAnsiColors
        let colorMap = TerminalStyleColorMap(
            previousDefaultStyle: previousDefaultStyle,
            nextDefaultStyle: terminalDefaultStyle,
            previousAnsiColors: previousAnsiColors,
            nextAnsiColors: nextAnsiColors
        )
        maxScrollbackRows = max(1, settings.terminal.scrollbackLines)
        currentStyle = terminalDefaultStyle
        screen.remapColors(colorMap)
        scrollbackRows.remapColors(colorMap)
        screen.remapStyle(from: previousDefaultStyle, to: terminalDefaultStyle)
        scrollbackRows.remapStyle(from: previousDefaultStyle, to: terminalDefaultStyle)
        if trimScrollbackRowsToLimit() {
            markFullDamage()
        }
        updateScrollIndicator()
        layer?.backgroundColor = terminalDefaultStyle.background.cgColor
        renderer.applyAppearance(
            font: nextFont,
            backgroundColor: terminalDefaultStyle.background,
            cursorColor: settings.terminal.colors.cursorColor
        )
        markFullDamage()
        syncSizeWithView()
        updateRendererFrame()
    }

    private static func ansiColors(from settings: AppSettings) -> [SIMD4<Float>] {
        let configuredAnsiColors = settings.terminal.colors.ansi.map {
            ColorHexParser.parse($0, fallback: DesignTokens.Color.terminalForeground)
        }
        return configuredAnsiColors.count >= TerminalColorSettings.requiredAnsiColorCount
            ? Array(configuredAnsiColors.prefix(TerminalColorSettings.requiredAnsiColorCount))
            : DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright
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
            let cursorMarker = rowIndex == cursorRow ? " cursorCol=\(cursorColumn)" : ""
            NSLog(
                "Kurotty row[%03d]%@: occupiedCells=%d bgRuns=%@ fgRuns=%@",
                rowIndex,
                cursorMarker,
                TerminalScreenDiagnostics.occupiedCellCount(in: row),
                TerminalScreenDiagnostics.styleRuns(for: row.map(\.style), background: true),
                TerminalScreenDiagnostics.styleRuns(for: row.map(\.style), background: false)
            )
        }
    }

    private func currentCursorCellRectInViewCoordinates() -> NSRect {
        let metrics = terminalMetrics()
        return Self.cursorCellRectInViewCoordinates(
            boundsHeight: bounds.height,
            padding: padding,
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            cellSize: CGSize(
                width: CGFloat(metrics.cellSize.width),
                height: CGFloat(metrics.cellSize.height)
            ),
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

            screen.set(character: character, row: cursorRow, column: cursorColumn, width: width, style: currentStyle)
            markDirty(row: cursorRow)
            cursorColumn += width
        }
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
        scrollbackRowsAppendedDuringOutput += rows.count
        scrollbackRows.append(contentsOf: rows, limit: maxScrollbackRows)
        scrollbackOffset = min(scrollbackOffset, maxScrollbackOffset())
        updateScrollIndicator()
    }

    @discardableResult
    private func trimScrollbackRowsToLimit() -> Bool {
        let didTrim = scrollbackRows.trim(to: maxScrollbackRows)
        scrollbackOffset = min(scrollbackOffset, maxScrollbackOffset())
        return didTrim
    }

    private func layoutScrollIndicator() {
        let visibleRows = max(1, terminalMetrics().size.rows)
        scrollIndicatorCoordinator.layout(
            in: bounds,
            visibleRows: visibleRows,
            maxScrollbackOffset: maxScrollbackOffset(visibleRows: visibleRows),
            scrollbackOffset: scrollbackOffset
        )
    }

    private func updateScrollIndicator() {
        let visibleRows = max(1, terminalMetrics().size.rows)
        scrollIndicatorCoordinator.update(
            bounds: bounds,
            visibleRows: visibleRows,
            maxScrollbackOffset: maxScrollbackOffset(visibleRows: visibleRows),
            scrollbackOffset: scrollbackOffset
        )
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
            case let scalar where TerminalEscapeSequence.beginsTwoByteDesignator(scalar):
                parserState = .escapeDesignator
            case let scalar where TerminalEscapeSequence.beginsTwoByteDecPrivate(scalar):
                parserState = .escapeDecPrivate
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
        case .escapeDesignator:
            parserState = .normal
            return true
        case .escapeDecPrivate:
            parserState = .normal
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

    private func notifyItermOsc9(_ payload: String) {
        guard shouldDeliverUserNotification else {
            return
        }
        notifier.notifyItermOsc9(message: payload)
    }

    private func respondToOscQuery(_ code: String) {
        switch code {
        case "10":
            sendTerminalResponse("\u{1b}]10;\(terminalOscColor(terminalDefaultStyle.foreground))\u{1b}\\")
        case "11":
            sendTerminalResponse("\u{1b}]11;\(terminalOscColor(terminalDefaultStyle.background))\u{1b}\\")
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
        case "X":
            let count = max(1, parsed.value(at: 0, default: 1))
            screen.clear(row: cursorRow, from: cursorColumn, through: cursorColumn + count - 1, style: currentStyle)
            markDirty(row: cursorRow)
        case "@":
            screen.insertCharacters(row: cursorRow, column: cursorColumn, count: parsed.value(at: 0, default: 1), style: currentStyle)
            markDirty(row: cursorRow)
        case "b":
            let written = screen.repeatPrecedingGraphicCharacter(row: cursorRow, column: cursorColumn, count: parsed.value(at: 0, default: 1))
            if written > 0 {
                cursorColumn = min(screen.columns, cursorColumn + written)
                markDirty(row: cursorRow)
            }
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
            guard TerminalSgrPolicy.shouldApplySgr(for: parsed) else { break }
            applySgr(parsed.elements)
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
            if !parsed.isPrivate, parsed.value(at: 0, default: 0) == 6 {
                sendTerminalResponse(cursorPositionReport())
            }
        case "c":
            if let response = TerminalDeviceAttributes.response(for: parsed) {
                sendTerminalResponse(response)
            }
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
            let cellWidth = CGFloat(metrics.cellSize.width)
            let cellHeight = CGFloat(metrics.cellSize.height)
            return TerminalFrameRect(
                x: Double(padding.left),
                y: Double(bounds.height - padding.top - cellHeight * CGFloat(row + 1)),
                width: Double(cellWidth * CGFloat(metrics.size.columns)),
                height: Double(cellHeight)
            )
        }
        pendingDirtyRows.removeAll(keepingCapacity: true)
        pendingFullDamage = false
        return TerminalFrameDamage(rows: rows, rects: rects, isFull: isFull)
    }

    private func applySgr(_ elements: [CsiParameterElement]) {
        let codes = elements.isEmpty ? [CsiParameterElement(values: [0])] : elements
        var index = 0
        while index < codes.count {
            let element = codes[index]
            let code = element.value
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
                applyUnderlineSgr(element)
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
                if let color = colorFromColonSgr(element) {
                    if isForeground {
                        currentStyle.foreground = color
                    } else {
                        currentStyle.background = color
                    }
                    break
                }
                guard index + 1 < codes.count else { break }
                if codes[index + 1].value == 5, index + 2 < codes.count {
                    let color = xterm256Color(codes[index + 2].value)
                    if isForeground {
                        currentStyle.foreground = color
                    } else {
                        currentStyle.background = color
                    }
                    index += 2
                } else if codes[index + 1].value == 2, index + 4 < codes.count {
                    let color = TerminalTextStyle.rgb(red: codes[index + 2].value, green: codes[index + 3].value, blue: codes[index + 4].value)
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

    private func applyUnderlineSgr(_ element: CsiParameterElement) {
        guard element.values.count > 1 else {
            currentStyle.underline = true
            return
        }
        currentStyle.underline = element.values[1] != 0
    }

    private func colorFromColonSgr(_ element: CsiParameterElement) -> SIMD4<Float>? {
        guard element.values.count > 1 else { return nil }
        switch element.values[1] {
        case 5:
            guard element.values.count > 2 else { return nil }
            return xterm256Color(element.values[2])
        case 2:
            let colorComponents = Array(element.values.dropFirst(2).suffix(3))
            guard colorComponents.count == 3 else { return nil }
            return TerminalTextStyle.rgb(red: colorComponents[0], green: colorComponents[1], blue: colorComponents[2])
        default:
            return nil
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

private struct BoundedScrollbackRows {
    private var storage: [[TerminalScreenCell]] = []
    private var startIndex = 0

    var count: Int {
        storage.count - startIndex
    }

    var isEmpty: Bool {
        count == 0
    }

    var rows: [[TerminalScreenCell]] {
        guard !isEmpty else { return [] }
        return Array(storage[startIndex...])
    }

    @discardableResult
    mutating func append(contentsOf newRows: [[TerminalScreenCell]], limit: Int) -> Int {
        guard !newRows.isEmpty else { return 0 }
        storage.append(contentsOf: newRows)
        let previousCount = count - newRows.count
        _ = trim(to: limit)
        return max(0, count - max(0, previousCount))
    }

    @discardableResult
    mutating func trim(to limit: Int) -> Bool {
        let boundedLimit = max(0, limit)
        let rowsToDrop = count - boundedLimit
        guard rowsToDrop > 0 else {
            compactStorageIfNeeded()
            return false
        }

        startIndex += rowsToDrop
        compactStorageIfNeeded()
        return true
    }

    private mutating func compactStorageIfNeeded() {
        guard startIndex > 0 else { return }
        guard startIndex >= storage.count / 2 || startIndex == storage.count else { return }
        storage.removeSubrange(0..<startIndex)
        startIndex = 0
    }

    mutating func remapStyle(from previousStyle: TerminalTextStyle, to nextStyle: TerminalTextStyle) {
        guard previousStyle != nextStyle else { return }
        for rowIndex in startIndex..<storage.count {
            for columnIndex in storage[rowIndex].indices where storage[rowIndex][columnIndex].style == previousStyle {
                storage[rowIndex][columnIndex].style = nextStyle
            }
        }
    }

    mutating func remapColors(_ colorMap: TerminalStyleColorMap) {
        for rowIndex in startIndex..<storage.count {
            for columnIndex in storage[rowIndex].indices {
                storage[rowIndex][columnIndex].style = storage[rowIndex][columnIndex].style.remappingColors(colorMap)
            }
        }
    }
}
