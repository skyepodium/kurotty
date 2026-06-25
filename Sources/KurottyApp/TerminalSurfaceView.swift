import AppKit

@MainActor
final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
    private let core = CoreBridge(cols: 120, rows: 40)
    private let shell = ShellSession()
    private let metalView: TerminalMetalView
    private var screen = TerminalScreen(rows: 40, columns: 120)
    private var scrollbackRows: [[TerminalScreenCell]] = []
    private var scrollbackOffset = 0
    private var normalScreenSnapshot: TerminalScreen?
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursorRow = 0
    private var savedCursorColumn = 0
    private var cursorVisible = true
    private var isUsingAlternateScreen = false
    private var bracketedPasteEnabled = false
    private var currentStyle = TerminalTextStyle.default
    private var parserState = StreamState.normal
    private var csiBuffer = ""
    private var markedText = NSMutableAttributedString()
    private var inputSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var lastSentSize = TerminalSize(columns: 120, rows: 40)
    private let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private let padding = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)

    override init(frame frameRect: NSRect) {
        metalView = TerminalMetalView(font: font)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
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
        shell.onOutput = { [weak self] text in
            Task { @MainActor in
                self?.appendOutput(text)
            }
        }
        shell.start()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        syncSizeWithView()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        let lineDelta = max(1, Int(abs(event.scrollingDeltaY) / 8))
        if event.scrollingDeltaY > 0 {
            scrollbackOffset = min(scrollbackRows.count, scrollbackOffset + lineDelta)
        } else if event.scrollingDeltaY < 0 {
            scrollbackOffset = max(0, scrollbackOffset - lineDelta)
        }
        updateMetalFrame()
    }

    override func keyDown(with event: NSEvent) {
        core.recordKeyEvent()
        interpretKeyEvents([event])
    }

    func metalFramePresented() {
        core.recordFramePresented()
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        if bracketedPasteEnabled {
            send("\u{1b}[200~\(text)\u{1b}[201~")
        } else {
            send(text)
        }
    }

    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visibleText(), forType: .string)
    }

    override func layout() {
        super.layout()
        syncSizeWithView()
        updateMetalFrame()
    }

    private func syncSizeWithView() {
        let metrics = terminalMetrics()
        guard metrics.size.columns > 0, metrics.size.rows > 0 else { return }
        if metrics.size != lastSentSize {
            cursorRow = screen.resize(rows: metrics.size.rows, columns: metrics.size.columns, anchorRow: cursorRow)
            cursorColumn = min(cursorColumn, metrics.size.columns - 1)
            lastSentSize = metrics.size
            shell.resize(columns: metrics.size.columns, rows: metrics.size.rows)
            core.resize(cols: UInt32(metrics.size.columns), rows: UInt32(metrics.size.rows))
        }
    }

    private func updateMetalFrame() {
        let metrics = terminalMetrics()
        var cells: [TerminalCell] = []
        var backgrounds: [TerminalBackground] = []
        cells.reserveCapacity(metrics.size.rows * metrics.size.columns / 2)
        let rowsToRender = visibleRowsForRendering(limit: metrics.size.rows)
        for row in 0..<rowsToRender.count {
            let sourceRow = rowsToRender[row]
            for column in 0..<min(sourceRow.count, metrics.size.columns) {
                let cell = sourceRow[column]
                if cell.style.background != TerminalTextStyle.default.background && !cell.isContinuation {
                    backgrounds.append(TerminalBackground(column: column, row: row, color: cell.style.effectiveBackground))
                }
                if cell.character != " " && !cell.isContinuation {
                    cells.append(TerminalCell(
                        character: cell.character,
                        column: column,
                        row: row,
                        foreground: cell.style.effectiveForeground,
                        background: cell.style.effectiveBackground
                    ))
                }
            }
        }

        metalView.update(frame: TerminalFrame(
            cells: cells,
            backgrounds: backgrounds,
            cursorColumn: min(cursorColumn, metrics.size.columns - 1),
            cursorRow: cursorVisible && scrollbackOffset == 0 ? min(cursorRow, metrics.size.rows - 1) : -1,
            markedText: markedText.string,
            columns: metrics.size.columns,
            visibleRows: metrics.size.rows,
            cellSize: metrics.cellSize,
            padding: CGPoint(x: padding.left, y: padding.top)
        ))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        send(text)
        unmarkText()
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            send("\r")
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
        let attr = string as? NSAttributedString ?? NSAttributedString(string: string as? String ?? "")
        markedText = NSMutableAttributedString(attributedString: attr)
        inputSelectedRange = selectedRange
        updateMetalFrame()
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        inputSelectedRange = NSRange(location: NSNotFound, length: 0)
        updateMetalFrame()
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { inputSelectedRange }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let metrics = terminalMetrics()
        let localRect = NSRect(
            x: padding.left + CGFloat(cursorColumn) * metrics.cellSize.width,
            y: padding.top + CGFloat(cursorRow + 1) * metrics.cellSize.height,
            width: metrics.cellSize.width,
            height: metrics.cellSize.height
        )
        return window?.convertToScreen(convert(localRect, to: nil)) ?? .zero
    }

    private func send(_ text: String) {
        shell.write(text)
    }

    private func appendOutput(_ text: String) {
        if !text.isEmpty {
            scrollbackOffset = 0
        }
        core.feed(text)
        for scalar in text.unicodeScalars {
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
                let spaces = max(1, 8 - (cursorColumn % 8))
                appendPrintable(String(repeating: " ", count: spaces))
            case 0..<32, 127:
                continue
            default:
                appendPrintable(String(scalar))
            }
        }
        updateMetalFrame()
    }

    private func visibleText() -> String {
        visibleRowsForRendering(limit: screen.rows).map { row in
            String(row.map(\.character)).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
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
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        let width = max(8, ceil(("0" as NSString).size(withAttributes: [.font: font]).width))
        let columns = max(1, Int((bounds.width - padding.left - padding.right) / width))
        let rows = max(1, Int((bounds.height - padding.top - padding.bottom) / lineHeight))
        return TerminalMetrics(size: TerminalSize(columns: columns, rows: rows), cellSize: CGSize(width: width, height: lineHeight))
    }

    private func appendPrintable(_ text: String) {
        for character in text {
            let width = character.terminalColumnWidth
            guard width > 0 else { continue }
            if width == 2 && cursorColumn == screen.columns - 1 {
                carriageReturnLineFeed()
            } else if cursorColumn >= screen.columns {
                carriageReturnLineFeed()
            }

            screen.set(character: character, row: cursorRow, column: cursorColumn, width: width, style: currentStyle)
            cursorColumn += width
        }
    }

    private func lineFeed() {
        if cursorRow == screen.rows - 1 {
            appendScrollback(rows: screen.scrollUp())
        } else {
            cursorRow += 1
        }
    }

    private func appendScrollback(rows: [[TerminalScreenCell]]) {
        guard !isUsingAlternateScreen else { return }
        scrollbackRows.append(contentsOf: rows)
        let maxScrollbackRows = 1_000_000
        if scrollbackRows.count > maxScrollbackRows {
            scrollbackRows.removeFirst(scrollbackRows.count - maxScrollbackRows)
        }
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
                parserState = .normal
            } else if scalar.value == 0x1b {
                parserState = .oscEscape
            }
            return true
        case .oscEscape:
            parserState = .normal
            return true
        }
    }

    private func executeCsi(final: Character, params: String) {
        let parsed = CsiParameters(params)
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
            screen.insertLines(at: cursorRow, count: parsed.value(at: 0, default: 1))
        case "M":
            screen.deleteLines(at: cursorRow, count: parsed.value(at: 0, default: 1))
        case "P":
            screen.deleteCharacters(row: cursorRow, column: cursorColumn, count: parsed.value(at: 0, default: 1))
        case "@":
            screen.insertCharacters(row: cursorRow, column: cursorColumn, count: parsed.value(at: 0, default: 1))
        case "S":
            screen.scrollUp(count: parsed.value(at: 0, default: 1))
        case "T":
            screen.scrollDown(count: parsed.value(at: 0, default: 1))
        case "m":
            applySgr(parsed.values)
        case "s":
            savedCursorRow = cursorRow
            savedCursorColumn = cursorColumn
        case "u":
            cursorRow = min(screen.rows - 1, savedCursorRow)
            cursorColumn = min(screen.columns - 1, savedCursorColumn)
        case "h":
            setMode(params: parsed, enabled: true)
        case "l":
            setMode(params: parsed, enabled: false)
        default:
            break
        }
    }

    private func setMode(params: CsiParameters, enabled: Bool) {
        guard params.isPrivate else { return }
        for value in params.values {
            switch value {
            case 25:
                cursorVisible = enabled
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
            screen.clear(row: cursorRow, from: cursorColumn, through: screen.columns - 1)
        case 1:
            screen.clear(row: cursorRow, from: 0, through: cursorColumn)
        case 2:
            screen.clear(row: cursorRow)
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
                    screen.clear(row: row)
                }
            }
        case 1:
            if cursorRow > 0 {
                for row in 0..<cursorRow {
                    screen.clear(row: row)
                }
            }
            eraseInLine(mode: 1)
        case 2, 3:
            screen.clear()
            cursorRow = 0
            cursorColumn = 0
        default:
            break
        }
    }

    private func reverseIndex() {
        if cursorRow == 0 {
            screen.scrollDown()
        } else {
            cursorRow -= 1
        }
    }

    private func enterAlternateScreen() {
        guard !isUsingAlternateScreen else { return }
        normalScreenSnapshot = screen
        screen.clear()
        cursorRow = 0
        cursorColumn = 0
        isUsingAlternateScreen = true
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
        normalScreenSnapshot = nil
        isUsingAlternateScreen = false
    }

    private func resetTerminal() {
        screen.clear()
        cursorRow = 0
        cursorColumn = 0
        cursorVisible = true
        bracketedPasteEnabled = false
        currentStyle = .default
        normalScreenSnapshot = nil
        isUsingAlternateScreen = false
    }

    private func applySgr(_ values: [Int]) {
        let codes = values.isEmpty ? [0] : values
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0:
                currentStyle = .default
            case 1:
                currentStyle.bold = true
            case 22:
                currentStyle.bold = false
            case 7:
                currentStyle.inverse = true
            case 27:
                currentStyle.inverse = false
            case 30...37:
                currentStyle.foreground = TerminalTextStyle.ansiColor(code - 30, bright: currentStyle.bold)
            case 39:
                currentStyle.foreground = TerminalTextStyle.default.foreground
            case 40...47:
                currentStyle.background = TerminalTextStyle.ansiColor(code - 40, bright: false)
            case 49:
                currentStyle.background = TerminalTextStyle.default.background
            case 90...97:
                currentStyle.foreground = TerminalTextStyle.ansiColor(code - 90, bright: true)
            case 100...107:
                currentStyle.background = TerminalTextStyle.ansiColor(code - 100, bright: true)
            case 38, 48:
                let isForeground = code == 38
                guard index + 1 < codes.count else { break }
                if codes[index + 1] == 5, index + 2 < codes.count {
                    let color = TerminalTextStyle.xterm256Color(codes[index + 2])
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
}

private enum StreamState {
    case normal
    case escape
    case csi
    case osc
    case oscEscape
}

private struct TerminalSize: Equatable {
    let columns: Int
    let rows: Int
}

private struct TerminalMetrics {
    let size: TerminalSize
    let cellSize: CGSize
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

    mutating func clear() {
        discardResizeHiddenRows()
        cells = Array(repeating: TerminalScreen.blankRow(columns: columns), count: rows)
    }

    mutating func clear(row: Int) {
        guard cells.indices.contains(row) else { return }
        cells[row] = TerminalScreen.blankRow(columns: columns)
    }

    mutating func clear(row: Int, from start: Int, through end: Int) {
        guard cells.indices.contains(row) else { return }
        let lower = max(0, min(start, columns - 1))
        let upper = max(0, min(end, columns - 1))
        guard lower <= upper else { return }
        for column in lower...upper {
            cells[row][column] = TerminalScreenCell()
        }
    }

    mutating func set(character: Character, row: Int, column: Int, width: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        cells[row][column] = TerminalScreenCell(character: character, isContinuation: false, style: style)
        if width == 2 && column + 1 < columns {
            cells[row][column + 1] = TerminalScreenCell(character: " ", isContinuation: true, style: style)
        }
        if column > 0 && cells[row][column - 1].isContinuation {
            cells[row][column - 1] = TerminalScreenCell()
        }
        if width == 1 && column + 1 < columns && cells[row][column + 1].isContinuation {
            cells[row][column + 1] = TerminalScreenCell()
        }
    }

    @discardableResult
    mutating func scrollUp(count: Int = 1) -> [[TerminalScreenCell]] {
        discardResizeHiddenRows()
        let amount = min(max(1, count), rows)
        let removed = Array(cells.prefix(amount))
        cells.removeFirst(amount)
        cells.append(contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns), count: amount))
        return removed
    }

    mutating func scrollDown(count: Int = 1) {
        discardResizeHiddenRows()
        let amount = min(max(1, count), rows)
        cells.removeLast(amount)
        cells.insert(contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns), count: amount), at: 0)
    }

    mutating func insertLines(at row: Int, count: Int) {
        discardResizeHiddenRows()
        guard rows > 0 else { return }
        let start = min(max(0, row), rows - 1)
        let amount = min(max(1, count), rows - start)
        cells.removeSubrange((rows - amount)..<rows)
        cells.insert(contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns), count: amount), at: start)
    }

    mutating func deleteLines(at row: Int, count: Int) {
        discardResizeHiddenRows()
        guard rows > 0 else { return }
        let start = min(max(0, row), rows - 1)
        let amount = min(max(1, count), rows - start)
        cells.removeSubrange(start..<(start + amount))
        cells.append(contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns), count: amount))
    }

    mutating func insertCharacters(row: Int, column: Int, count: Int) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        let amount = min(max(1, count), columns - column)
        var line = cells[row]
        line.removeSubrange((columns - amount)..<columns)
        line.insert(contentsOf: Array(repeating: TerminalScreenCell(), count: amount), at: column)
        cells[row] = line
    }

    mutating func deleteCharacters(row: Int, column: Int, count: Int) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        let amount = min(max(1, count), columns - column)
        var line = cells[row]
        line.removeSubrange(column..<(column + amount))
        line.append(contentsOf: Array(repeating: TerminalScreenCell(), count: amount))
        cells[row] = line
    }

    mutating func discardResizeHiddenRows() {
        resizeHiddenRowsAbove.removeAll(keepingCapacity: true)
        resizeHiddenRowsBelow.removeAll(keepingCapacity: true)
    }

    static func blankRow(columns: Int) -> [TerminalScreenCell] {
        Array(repeating: TerminalScreenCell(), count: columns)
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
    var inverse = false

    static let `default` = TerminalTextStyle(
        foreground: SIMD4<Float>(0.92, 0.92, 0.92, 1),
        background: SIMD4<Float>(0, 0, 0, 1)
    )

    var effectiveForeground: SIMD4<Float> {
        inverse ? background : (bold ? brighten(foreground) : foreground)
    }

    var effectiveBackground: SIMD4<Float> {
        inverse ? foreground : background
    }

    static func ansiColor(_ index: Int, bright: Bool) -> SIMD4<Float> {
        let normal: [SIMD3<Float>] = [
            SIMD3<Float>(0.00, 0.00, 0.00),
            SIMD3<Float>(0.80, 0.12, 0.12),
            SIMD3<Float>(0.35, 0.70, 0.25),
            SIMD3<Float>(0.78, 0.64, 0.20),
            SIMD3<Float>(0.25, 0.45, 0.85),
            SIMD3<Float>(0.70, 0.35, 0.80),
            SIMD3<Float>(0.25, 0.70, 0.75),
            SIMD3<Float>(0.86, 0.86, 0.86),
        ]
        let brightColors: [SIMD3<Float>] = [
            SIMD3<Float>(0.40, 0.40, 0.40),
            SIMD3<Float>(1.00, 0.30, 0.30),
            SIMD3<Float>(0.55, 0.95, 0.45),
            SIMD3<Float>(1.00, 0.85, 0.35),
            SIMD3<Float>(0.45, 0.65, 1.00),
            SIMD3<Float>(0.95, 0.55, 1.00),
            SIMD3<Float>(0.45, 0.95, 1.00),
            SIMD3<Float>(1.00, 1.00, 1.00),
        ]
        let color = (bright ? brightColors : normal)[max(0, min(index, 7))]
        return SIMD4<Float>(color.x, color.y, color.z, 1)
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
}

private struct CsiParameters {
    let isPrivate: Bool
    let values: [Int]

    init(_ raw: String) {
        isPrivate = raw.hasPrefix("?")
        values = raw
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { part in
                let digits = part.filter(\.isNumber)
                return digits.isEmpty ? 0 : Int(digits) ?? 0
            }
    }

    func value(at index: Int, default defaultValue: Int) -> Int {
        guard values.indices.contains(index), values[index] > 0 else { return defaultValue }
        return values[index]
    }
}

private extension Character {
    var terminalColumnWidth: Int {
        guard let scalar = unicodeScalars.first else { return 1 }
        let value = scalar.value
        if value == 0 || (value < 32) || (0x7f..<0xa0).contains(value) {
            return 0
        }
        if CharacterSet.nonBaseCharacters.contains(scalar) {
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
}
