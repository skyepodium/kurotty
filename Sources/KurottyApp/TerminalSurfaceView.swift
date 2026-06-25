import AppKit

@MainActor
final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
    private let core = CoreBridge(cols: 120, rows: 40)
    private let shell = ShellSession()
    private let metalView: TerminalMetalView
    private var rows: [[Character]] = [[]]
    private var cursorRow = 0
    private var cursorColumn = 0
    private var parserState = StreamState.normal
    private var csiBuffer = ""
    private var markedText = NSMutableAttributedString()
    private var inputSelectedRange = NSRange(location: NSNotFound, length: 0)
    private let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private let padding = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)

    override init(frame frameRect: NSRect) {
        metalView = TerminalMetalView(font: font)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        metalView.translatesAutoresizingMaskIntoConstraints = false
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
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        core.recordKeyEvent()
        interpretKeyEvents([event])
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        send(text)
    }

    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visibleText(), forType: .string)
    }

    override func layout() {
        super.layout()
        updateMetalFrame()
    }

    private func updateMetalFrame() {
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        let maxLines = max(1, Int((bounds.height - padding.top - padding.bottom) / lineHeight))
        let columns = terminalColumns()
        let visibleRows = makeVisibleRows(columns: columns)
        let firstVisibleIndex = max(0, visibleRows.count - maxLines)
        let displayRows = Array(visibleRows.suffix(maxLines))
        var cells: [TerminalCell] = []
        for (visibleIndex, visualRow) in displayRows.enumerated() {
            for (column, character) in visualRow.text.enumerated() where character != " " {
                cells.append(TerminalCell(character: character, column: column, row: visibleIndex))
            }
        }
        let cursorVisualIndex = visualIndexForCursor(columns: columns)
        let cursorDisplayRow = max(0, cursorVisualIndex - firstVisibleIndex)

        metalView.update(frame: TerminalFrame(
            cells: cells,
            cursorColumn: cursorColumn % columns,
            cursorRow: min(maxLines - 1, cursorDisplayRow),
            columns: columns,
            visibleRows: maxLines,
            cellSize: CGSize(width: max(8, "W".size(withAttributes: [.font: font]).width), height: lineHeight),
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
            send("\n")
        case #selector(deleteBackward(_:)):
            send("\u{7f}")
        case #selector(moveUp(_:)):
            send("\u{1b}[A")
        case #selector(moveDown(_:)):
            send("\u{1b}[B")
        case #selector(moveLeft(_:)):
            send("\u{1b}[D")
        case #selector(moveRight(_:)):
            send("\u{1b}[C")
        default:
            break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attr = string as? NSAttributedString ?? NSAttributedString(string: string as? String ?? "")
        markedText = NSMutableAttributedString(attributedString: attr)
        inputSelectedRange = selectedRange
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        inputSelectedRange = NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { inputSelectedRange }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }

    private func send(_ text: String) {
        core.feed(text)
        shell.write(text)
    }

    private func appendOutput(_ text: String) {
        for scalar in text.unicodeScalars {
            if consumeControl(scalar) {
                continue
            }

            switch scalar.value {
            case 10:
                cursorRow += 1
                ensureCursorRow()
                cursorColumn = 0
            case 13:
                cursorColumn = 0
            case 127, 8:
                if cursorColumn > 0 {
                    cursorColumn -= 1
                    if cursorColumn < rows[cursorRow].count {
                        rows[cursorRow].remove(at: cursorColumn)
                    }
                }
            case 9:
                appendPrintable("    ")
            case 0..<32:
                continue
            default:
                appendPrintable(String(scalar))
            }
        }
        if rows.count > 10_000 {
            let removeCount = rows.count - 10_000
            rows.removeFirst(removeCount)
            cursorRow = max(0, cursorRow - removeCount)
        }
        updateMetalFrame()
    }

    private func visibleText() -> String {
        rows.map { String($0) }.joined(separator: "\n")
    }

    private func terminalColumns() -> Int {
        let charWidth = max(8, "W".size(withAttributes: [.font: font]).width)
        return max(1, Int((bounds.width - padding.left - padding.right) / charWidth))
    }

    private func makeVisibleRows(columns: Int) -> [VisualRow] {
        rows.enumerated().flatMap { rowIndex, row in
            wrap(String(row), rowIndex: rowIndex, columns: columns)
        }
    }

    private func wrap(_ line: String, rowIndex: Int, columns: Int) -> [VisualRow] {
        if line.isEmpty {
            return [VisualRow(rowIndex: rowIndex, wrapIndex: 0, text: "")]
        }

        var result: [VisualRow] = []
        var current = ""
        current.reserveCapacity(columns)
        var wrapIndex = 0

        for character in line {
            if current.count >= columns {
                result.append(VisualRow(rowIndex: rowIndex, wrapIndex: wrapIndex, text: current))
                current = ""
                wrapIndex += 1
            }
            current.append(character)
        }
        result.append(VisualRow(rowIndex: rowIndex, wrapIndex: wrapIndex, text: current))
        return result
    }

    private func appendPrintable(_ text: String) {
        for character in text {
            ensureCursorRow()
            if cursorColumn < rows[cursorRow].count {
                rows[cursorRow][cursorColumn] = character
            } else {
                while rows[cursorRow].count < cursorColumn {
                    rows[cursorRow].append(" ")
                }
                rows[cursorRow].append(character)
            }
            cursorColumn += 1
        }
    }

    private func ensureCursorRow() {
        while rows.count <= cursorRow {
            rows.append([])
        }
    }

    private func visualIndexForCursor(columns: Int) -> Int {
        var index = 0
        for rowIndex in 0..<cursorRow {
            index += max(1, Int(ceil(Double(rows[rowIndex].count) / Double(columns))))
        }
        index += cursorColumn / columns
        return index
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
            if scalar == "[" {
                csiBuffer = ""
                parserState = .csi
            } else if scalar == "]" {
                parserState = .osc
            } else {
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
        let numbers = parseCsiNumbers(params)
        switch final {
        case "J":
            eraseInDisplay(mode: numbers.first ?? 0)
        case "K":
            eraseInLine(mode: numbers.first ?? 0)
        case "G":
            cursorColumn = max(0, (numbers.first ?? 1) - 1)
        case "C":
            cursorColumn += max(1, numbers.first ?? 1)
        case "D":
            cursorColumn = max(0, cursorColumn - max(1, numbers.first ?? 1))
        case "P":
            deleteCharacters(count: max(1, numbers.first ?? 1))
        default:
            break
        }
    }

    private func parseCsiNumbers(_ params: String) -> [Int] {
        params
            .split(separator: ";")
            .compactMap { part in
                let digits = part.filter(\.isNumber)
                return digits.isEmpty ? nil : Int(digits)
            }
    }

    private func eraseInLine(mode: Int) {
        ensureCursorRow()
        switch mode {
        case 0:
            if cursorColumn < rows[cursorRow].count {
                rows[cursorRow].removeSubrange(cursorColumn..<rows[cursorRow].count)
            }
        case 1:
            let end = min(cursorColumn, rows[cursorRow].count)
            if end > 0 {
                rows[cursorRow].replaceSubrange(0..<end, with: Array(repeating: Character(" "), count: end))
            }
        case 2:
            rows[cursorRow].removeAll(keepingCapacity: true)
            cursorColumn = 0
        default:
            break
        }
    }

    private func eraseInDisplay(mode: Int) {
        ensureCursorRow()
        switch mode {
        case 0:
            eraseInLine(mode: 0)
            if cursorRow + 1 < rows.count {
                rows.removeSubrange((cursorRow + 1)..<rows.count)
            }
        case 1:
            if cursorRow > 0 {
                rows.replaceSubrange(0..<cursorRow, with: Array(repeating: [], count: cursorRow))
            }
            eraseInLine(mode: 1)
        case 2, 3:
            rows = [[]]
            cursorRow = 0
            cursorColumn = 0
        default:
            break
        }
    }

    private func deleteCharacters(count: Int) {
        ensureCursorRow()
        guard cursorColumn < rows[cursorRow].count else { return }
        let end = min(rows[cursorRow].count, cursorColumn + count)
        rows[cursorRow].removeSubrange(cursorColumn..<end)
    }
}

private enum StreamState {
    case normal
    case escape
    case csi
    case osc
    case oscEscape
}

private struct VisualRow {
    let rowIndex: Int
    let wrapIndex: Int
    let text: String
}
