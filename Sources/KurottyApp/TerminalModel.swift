import Foundation
import KurottyCore

enum StreamState {
    case normal
    case escape
    case escapeDesignator
    case escapeDecPrivate
    case csi
    case osc
    case oscEscape
}

enum TerminalCursorPresentationPolicy {
    private static let minimumContrastRatio: Float = 3

    static func isFocusedForUser(
        isApplicationActive: Bool,
        isKeyWindow: Bool,
        isFirstResponder: Bool
    ) -> Bool {
        isApplicationActive && isKeyWindow && isFirstResponder
    }

    static func shouldRenderBlinkPhase(
        isFocusedForUser: Bool,
        cursorBlinkOn: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        !isFocusedForUser || cursorBlinkOn || hasMarkedText
    }

    static func visibleColor(
        preferred: SIMD4<Float>,
        frame: TerminalFrame
    ) -> SIMD4<Float> {
        let background = frame.backgrounds.last(where: {
            $0.row == frame.cursorRow && $0.column == frame.cursorColumn
        })?.color ?? frame.defaultBackground

        if contrastRatio(preferred, background) >= minimumContrastRatio {
            return preferred
        }
        if contrastRatio(frame.defaultForeground, background) >= minimumContrastRatio {
            return frame.defaultForeground
        }

        let black = SIMD4<Float>(0, 0, 0, 1)
        let white = SIMD4<Float>(1, 1, 1, 1)
        return contrastRatio(black, background) >= contrastRatio(white, background) ? black : white
    }

    static func contrastRatio(_ first: SIMD4<Float>, _ second: SIMD4<Float>) -> Float {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: SIMD4<Float>) -> Float {
        func linearize(_ component: Float) -> Float {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(color.x)
            + 0.7152 * linearize(color.y)
            + 0.0722 * linearize(color.z)
    }
}

enum TerminalEscapeSequence {
    static func beginsTwoByteDesignator(_ scalar: UnicodeScalar) -> Bool {
        switch scalar {
        case "(", ")", "*", "+", "-", ".", "/", "%":
            return true
        default:
            return false
        }
    }

    static func beginsTwoByteDecPrivate(_ scalar: UnicodeScalar) -> Bool {
        scalar == "#"
    }
}

struct TerminalLinkRange: Equatable {
    static let hoverColor = SIMD4<Float>(0.22, 0.48, 0.90, 1)

    private static let linkRegex = try! NSRegularExpression(
        pattern: #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"'`]+"#
    )
    private static let automaticLinkSecurityPolicy = TerminalSecurityPolicy.default
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}")

    let row: Int
    let startColumn: Int
    let endColumn: Int
    let urlString: String

    func contains(row: Int, column: Int) -> Bool {
        self.row == row && column >= startColumn && column < endColumn
    }

    static func findAll(in cells: [TerminalScreenCell], row: Int) -> [TerminalLinkRange] {
        findAll(in: [cells], startingRow: row)
    }

    static func findAll(in rows: [[TerminalScreenCell]], startingRow: Int) -> [TerminalLinkRange] {
        var ranges: [TerminalLinkRange] = []
        var logicalLineStart = 0

        while logicalLineStart < rows.count {
            var logicalLineEnd = logicalLineStart + 1
            while logicalLineEnd < rows.count,
                  rows[logicalLineEnd - 1].last?.wrapsToNextRow == true {
                logicalLineEnd += 1
            }
            ranges.append(contentsOf: findAll(
                in: rows[logicalLineStart..<logicalLineEnd],
                startingRow: startingRow + logicalLineStart
            ))
            logicalLineStart = logicalLineEnd
        }
        return ranges
    }

    private static func findAll(
        in rows: ArraySlice<[TerminalScreenCell]>,
        startingRow: Int
    ) -> [TerminalLinkRange] {
        var text = ""
        var positionsByCharacterOffset: [(row: Int, column: Int)] = []
        var linkURLsByCharacterOffset: [String?] = []
        var cellsByRow: [Int: [TerminalScreenCell]] = [:]
        for (rowOffset, cells) in rows.enumerated() {
            let row = startingRow + rowOffset
            cellsByRow[row] = cells
            for (cellColumn, cell) in cells.enumerated() where !cell.isContinuation {
                text.append(cell.character)
                positionsByCharacterOffset.append((row: row, column: cellColumn))
                linkURLsByCharacterOffset.append(cell.linkURL)
            }
        }
        guard !text.isEmpty else { return [] }

        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var ranges = explicitLinkRanges(
            cellsByRow: cellsByRow,
            positionsByCharacterOffset: positionsByCharacterOffset,
            linkURLsByCharacterOffset: linkURLsByCharacterOffset
        )
        for match in linkRegex.matches(in: text, range: searchRange) {
            guard let textRange = Range(match.range, in: text) else { continue }
            var urlString = String(text[textRange])
            while let scalar = urlString.unicodeScalars.last, trailingPunctuation.contains(scalar) {
                urlString.removeLast()
            }
            guard let url = URL(string: urlString),
                  automaticLinkSecurityPolicy.linkOpenDecision(for: url) != .deny else {
                continue
            }

            let startOffset = text.distance(from: text.startIndex, to: textRange.lowerBound)
            let endOffset = startOffset + urlString.count
            guard startOffset >= 0,
                  endOffset > startOffset,
                  startOffset < positionsByCharacterOffset.count,
                  endOffset - 1 < positionsByCharacterOffset.count else {
                continue
            }

            let automaticRanges = linkRanges(
                positions: positionsByCharacterOffset,
                cellsByRow: cellsByRow,
                offsets: startOffset..<endOffset,
                urlString: urlString
            )
            guard !automaticRanges.contains(where: { automaticRange in
                ranges.contains(where: { $0.overlaps(automaticRange) })
            }) else { continue }
            ranges.append(contentsOf: automaticRanges)
        }
        return ranges
    }

    static func find(in cells: [TerminalScreenCell], row: Int, column: Int) -> TerminalLinkRange? {
        findAll(in: cells, row: row).first { link in
            link.contains(row: row, column: column)
        }
    }

    private static func explicitLinkRanges(
        cellsByRow: [Int: [TerminalScreenCell]],
        positionsByCharacterOffset: [(row: Int, column: Int)],
        linkURLsByCharacterOffset: [String?]
    ) -> [TerminalLinkRange] {
        var ranges: [TerminalLinkRange] = []
        var offset = 0
        while offset < linkURLsByCharacterOffset.count {
            guard let urlString = linkURLsByCharacterOffset[offset], !urlString.isEmpty else {
                offset += 1
                continue
            }

            let startOffset = offset
            offset += 1
            while offset < linkURLsByCharacterOffset.count && linkURLsByCharacterOffset[offset] == urlString {
                offset += 1
            }

            ranges.append(contentsOf: linkRanges(
                positions: positionsByCharacterOffset,
                cellsByRow: cellsByRow,
                offsets: startOffset..<offset,
                urlString: urlString
            ))
        }
        return ranges
    }

    private static func linkRanges(
        positions: [(row: Int, column: Int)],
        cellsByRow: [Int: [TerminalScreenCell]],
        offsets: Range<Int>,
        urlString: String
    ) -> [TerminalLinkRange] {
        var ranges: [TerminalLinkRange] = []
        var segmentStart = offsets.lowerBound

        while segmentStart < offsets.upperBound {
            let row = positions[segmentStart].row
            var segmentEnd = segmentStart + 1
            while segmentEnd < offsets.upperBound, positions[segmentEnd].row == row {
                segmentEnd += 1
            }
            let endLeadColumn = positions[segmentEnd - 1].column
            let endWidth = cellsByRow[row].map {
                max(1, $0[endLeadColumn].character.terminalColumnWidth)
            } ?? 1
            ranges.append(TerminalLinkRange(
                row: row,
                startColumn: positions[segmentStart].column,
                endColumn: endLeadColumn + endWidth,
                urlString: urlString
            ))
            segmentStart = segmentEnd
        }
        return ranges
    }

    private func overlaps(_ other: TerminalLinkRange) -> Bool {
        row == other.row && startColumn < other.endColumn && other.startColumn < endColumn
    }
}

enum TerminalHyperlinkControl: Equatable {
    case activate(String)
    case clear
    case ignore

    static func update(fromOSC8Payload payload: String) -> TerminalHyperlinkControl {
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .ignore
        }

        let urlString = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else {
            return .clear
        }
        return .activate(urlString)
    }
}

enum TerminalMouseButton: Int, Equatable {
    case left = 0
    case middle = 1
    case right = 2
}

enum TerminalMouseTrackingMode: Equatable {
    case none
    case normal
    case buttonMotion
    case anyMotion
}

struct TerminalMouseModifiers: OptionSet, Equatable {
    let rawValue: Int

    static let shift = TerminalMouseModifiers(rawValue: 1 << 0)
    static let option = TerminalMouseModifiers(rawValue: 1 << 1)
    static let control = TerminalMouseModifiers(rawValue: 1 << 2)

    var xtermButtonCodeOffset: Int {
        var offset = 0
        if contains(.shift) {
            offset += 4
        }
        if contains(.option) {
            offset += 8
        }
        if contains(.control) {
            offset += 16
        }
        return offset
    }
}

struct TerminalMouseReportingState: Equatable {
    private var normalTracking = false
    private var buttonMotionTracking = false
    private var anyMotionTracking = false
    var usesUTF8ExtendedCoordinates = false
    var usesSGRExtendedCoordinates = false

    var trackingMode: TerminalMouseTrackingMode {
        if anyMotionTracking {
            return .anyMotion
        }
        if buttonMotionTracking {
            return .buttonMotion
        }
        if normalTracking {
            return .normal
        }
        return .none
    }

    var isEnabled: Bool {
        trackingMode != .none
    }

    mutating func set(decPrivateMode mode: Int, enabled: Bool) {
        switch mode {
        case 1000:
            normalTracking = enabled
        case 1002:
            buttonMotionTracking = enabled
        case 1003:
            anyMotionTracking = enabled
        case 1005:
            usesUTF8ExtendedCoordinates = enabled
        case 1006:
            usesSGRExtendedCoordinates = enabled
        default:
            break
        }
    }

    mutating func reset() {
        normalTracking = false
        buttonMotionTracking = false
        anyMotionTracking = false
        usesUTF8ExtendedCoordinates = false
        usesSGRExtendedCoordinates = false
    }
}

struct TerminalFocusReportingState: Equatable {
    private(set) var isEnabled = false
    private var lastReportedFocus: Bool?

    mutating func set(enabled: Bool) {
        isEnabled = enabled
        lastReportedFocus = nil
    }

    mutating func sequenceIfNeeded(isFocused: Bool) -> String? {
        guard isEnabled, lastReportedFocus != isFocused else {
            return nil
        }
        lastReportedFocus = isFocused
        return isFocused ? "\u{1b}[I" : "\u{1b}[O"
    }
}

enum TerminalMouseEventKind: Equatable {
    case press(TerminalMouseButton)
    case release(TerminalMouseButton)
    case drag(TerminalMouseButton)
    case move
    case wheelUp
    case wheelDown
}

enum TerminalMouseEventEncoder {
    static func sequence(
        for kind: TerminalMouseEventKind,
        column: Int,
        row: Int,
        modifiers: TerminalMouseModifiers,
        reportingState: TerminalMouseReportingState
    ) -> String? {
        guard column >= 0, row >= 0, shouldReport(kind, state: reportingState) else {
            return nil
        }

        let buttonCode = baseButtonCode(for: kind) + modifiers.xtermButtonCodeOffset
        let x = column + 1
        let y = row + 1
        if reportingState.usesSGRExtendedCoordinates {
            let final = isRelease(kind) ? "m" : "M"
            return "\u{1b}[<\(buttonCode);\(x);\(y)\(final)"
        }

        let legacyButtonCode = legacyBaseButtonCode(for: kind) + modifiers.xtermButtonCodeOffset
        let coordinateLimit = reportingState.usesUTF8ExtendedCoordinates ? 2_015 : 223
        guard legacyButtonCode <= 223, x <= coordinateLimit, y <= coordinateLimit,
              let encodedButton = legacyScalarString(legacyButtonCode + 32),
              let encodedX = legacyScalarString(x + 32),
              let encodedY = legacyScalarString(y + 32) else {
            return nil
        }
        return "\u{1b}[M\(encodedButton)\(encodedX)\(encodedY)"
    }

    private static func shouldReport(_ kind: TerminalMouseEventKind, state: TerminalMouseReportingState) -> Bool {
        switch kind {
        case .press, .release, .wheelUp, .wheelDown:
            return state.isEnabled
        case .drag:
            return state.trackingMode == .buttonMotion || state.trackingMode == .anyMotion
        case .move:
            return state.trackingMode == .anyMotion
        }
    }

    private static func baseButtonCode(for kind: TerminalMouseEventKind) -> Int {
        switch kind {
        case .press(let button), .release(let button):
            return button.rawValue
        case .drag(let button):
            return 32 + button.rawValue
        case .move:
            return 35
        case .wheelUp:
            return 64
        case .wheelDown:
            return 65
        }
    }

    private static func legacyBaseButtonCode(for kind: TerminalMouseEventKind) -> Int {
        if case .release = kind {
            return 3
        }
        return baseButtonCode(for: kind)
    }

    private static func isRelease(_ kind: TerminalMouseEventKind) -> Bool {
        if case .release = kind {
            return true
        }
        return false
    }

    private static func legacyScalarString(_ value: Int) -> String? {
        guard let scalar = UnicodeScalar(UInt32(value)) else {
            return nil
        }
        return String(Character(scalar))
    }
}

struct TerminalBlockElementRect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum TerminalBlockElementGeometry {
    static func rects(for character: Character) -> [TerminalBlockElementRect]? {
        switch character {
        case "█":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 1)]
        case "▉":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 7.0 / 8.0, height: 1)]
        case "▊":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 6.0 / 8.0, height: 1)]
        case "▋":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 5.0 / 8.0, height: 1)]
        case "▌":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 0.5, height: 1)]
        case "▍":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 3.0 / 8.0, height: 1)]
        case "▎":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 2.0 / 8.0, height: 1)]
        case "▏":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 1.0 / 8.0, height: 1)]
        case "▐":
            return [TerminalBlockElementRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case "▀":
            return [TerminalBlockElementRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        case "▄":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 0.5)]
        case "▁":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 1.0 / 8.0)]
        case "▂":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 2.0 / 8.0)]
        case "▃":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 3.0 / 8.0)]
        case "▅":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 5.0 / 8.0)]
        case "▆":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 6.0 / 8.0)]
        case "▇":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 7.0 / 8.0)]
        case "▖":
            return [TerminalBlockElementRect(x: 0, y: 0, width: 0.5, height: 0.5)]
        case "▗":
            return [TerminalBlockElementRect(x: 0.5, y: 0, width: 0.5, height: 0.5)]
        case "▘":
            return [TerminalBlockElementRect(x: 0, y: 0.5, width: 0.5, height: 0.5)]
        case "▝":
            return [TerminalBlockElementRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case "▙":
            return [
                TerminalBlockElementRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 0.5),
            ]
        case "▚":
            return [
                TerminalBlockElementRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                TerminalBlockElementRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            ]
        case "▛":
            return [
                TerminalBlockElementRect(x: 0, y: 0.5, width: 1, height: 0.5),
                TerminalBlockElementRect(x: 0, y: 0, width: 0.5, height: 0.5),
            ]
        case "▜":
            return [
                TerminalBlockElementRect(x: 0, y: 0.5, width: 1, height: 0.5),
                TerminalBlockElementRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            ]
        case "▞":
            return [
                TerminalBlockElementRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
                TerminalBlockElementRect(x: 0, y: 0, width: 0.5, height: 0.5),
            ]
        case "▟":
            return [
                TerminalBlockElementRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
                TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 0.5),
            ]
        default:
            return nil
        }
    }
}

struct TerminalSize: Equatable {
    let columns: Int
    let rows: Int
}

struct TerminalMetrics {
    let size: TerminalSize
    let cellSize: TerminalFrameSize
}

struct TerminalCellPosition: Hashable, Comparable {
    let row: Int
    let column: Int

    static func < (lhs: TerminalCellPosition, rhs: TerminalCellPosition) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

struct TerminalSelectionRange {
    let start: TerminalCellPosition
    let end: TerminalCellPosition
}

struct TerminalFrameDamage {
    let rows: [Int]
    let rects: [TerminalFrameRect]
    let isFull: Bool
}
