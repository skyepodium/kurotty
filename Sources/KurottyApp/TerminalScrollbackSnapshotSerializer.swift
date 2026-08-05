import Foundation
import KurottyCore

/// Renders retained scrollback rows back into terminal output bytes.
///
/// Only text and SGR styling are emitted. The payload deliberately contains no
/// device queries, no OSC, and no DCS, so replaying it can never make the
/// terminal answer a capability request into a freshly launched shell.
///
/// Rows are serialized from the newest backwards until the byte budget is
/// reached, so a snapshot always ends at a row boundary and never splits an
/// escape sequence.
enum TerminalScrollbackSnapshotSerializer {
    private enum Sgr {
        static let escape = "\u{1b}["
        static let reset = "\u{1b}[0m"
        static let terminator = "m"
        static let separator = ";"
        static let bold = 1
        static let dim = 2
        static let italic = 3
        static let underline = 4
        static let blink = 5
        static let inverse = 7
        static let strikethrough = 9
        static let foregroundExtended = 38
        static let backgroundExtended = 48
        static let trueColorSelector = 2
        static let colorComponentMaximum: Float = 255
    }

    /// Serializes the trailing rows of `rows` within `maximumBytes`.
    static func serialize(
        rows: BoundedScrollbackRows,
        defaultStyle: TerminalTextStyle,
        maximumBytes: Int = TerminalScrollbackSnapshotFormat.Budget.storeBytesPerPane
    ) -> Data {
        serialize(
            rows: (0..<rows.count).compactMap { rows.row(at: $0) },
            defaultStyle: defaultStyle,
            maximumBytes: maximumBytes
        )
    }

    /// Serializes the trailing rows of `rows` within `maximumBytes`.
    ///
    /// Callers pass rows oldest-first; the result keeps that order but may drop
    /// leading rows that do not fit the budget.
    static func serialize(
        rows: [[TerminalScreenCell]],
        defaultStyle: TerminalTextStyle,
        maximumBytes: Int = TerminalScrollbackSnapshotFormat.Budget.storeBytesPerPane
    ) -> Data {
        guard maximumBytes > 0, !rows.isEmpty else {
            return Data()
        }

        let separator = Data(TerminalScrollbackSnapshotFormat.rowSeparator.utf8)
        var retainedNewestFirst: [Data] = []
        var totalBytes = 0
        for row in rows.reversed() {
            let encoded = Data(encoded(row: row, defaultStyle: defaultStyle).utf8)
            let candidate = totalBytes + encoded.count + separator.count
            guard candidate <= maximumBytes else {
                break
            }
            retainedNewestFirst.append(encoded)
            totalBytes = candidate
        }
        guard !retainedNewestFirst.isEmpty else {
            return Data()
        }

        var payload = Data(capacity: totalBytes)
        for encoded in retainedNewestFirst.reversed() {
            payload.append(encoded)
            payload.append(separator)
        }
        return payload
    }

    /// One row as text plus SGR runs, with trailing default-styled blanks
    /// dropped so a mostly empty row costs a few bytes rather than a full line.
    static func encoded(row: [TerminalScreenCell], defaultStyle: TerminalTextStyle) -> String {
        let significantCount = significantCellCount(row: row, defaultStyle: defaultStyle)
        guard significantCount > 0 else {
            return ""
        }

        var output = ""
        var activeStyle = defaultStyle
        for index in 0..<significantCount {
            let cell = row[index]
            guard !cell.isContinuation else {
                continue
            }
            if cell.style != activeStyle {
                output += sgrSequence(for: cell.style, defaultStyle: defaultStyle)
                activeStyle = cell.style
            }
            output.append(cell.character)
        }
        if activeStyle != defaultStyle {
            output += Sgr.reset
        }
        return output
    }

    private static func significantCellCount(
        row: [TerminalScreenCell],
        defaultStyle: TerminalTextStyle
    ) -> Int {
        var count = row.count
        while count > 0 {
            let cell = row[count - 1]
            let isBlank = cell.character == " " && cell.style == defaultStyle && cell.linkURL == nil
            guard isBlank else {
                break
            }
            count -= 1
        }
        return count
    }

    /// SGR for one style. `default` collapses to a reset; anything else is a
    /// reset followed by explicit attributes and truecolor components, so a
    /// run never inherits state from an earlier row.
    static func sgrSequence(for style: TerminalTextStyle, defaultStyle: TerminalTextStyle) -> String {
        guard style != defaultStyle else {
            return Sgr.reset
        }

        var parameters = [0]
        if style.bold { parameters.append(Sgr.bold) }
        if style.dim { parameters.append(Sgr.dim) }
        if style.italic { parameters.append(Sgr.italic) }
        if style.underline { parameters.append(Sgr.underline) }
        if style.blink { parameters.append(Sgr.blink) }
        if style.inverse { parameters.append(Sgr.inverse) }
        if style.strikethrough { parameters.append(Sgr.strikethrough) }
        if style.foreground != defaultStyle.foreground {
            parameters.append(contentsOf: trueColorParameters(Sgr.foregroundExtended, style.foreground))
        }
        if style.background != defaultStyle.background {
            parameters.append(contentsOf: trueColorParameters(Sgr.backgroundExtended, style.background))
        }
        let joined = parameters.map(String.init).joined(separator: Sgr.separator)
        return Sgr.escape + joined + Sgr.terminator
    }

    private static func trueColorParameters(_ selector: Int, _ color: SIMD4<Float>) -> [Int] {
        [
            selector,
            Sgr.trueColorSelector,
            component(color.x),
            component(color.y),
            component(color.z),
        ]
    }

    private static func component(_ value: Float) -> Int {
        Int((max(0, min(1, value)) * Sgr.colorComponentMaximum).rounded())
    }
}
