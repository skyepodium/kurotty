import Foundation

/// Pure 1-based line number to `NSRange` mapping for the code editor.
///
/// Extracted so `path:line:col` link targeting is testable without an
/// `NSTextView`. Offsets are UTF-16 based to match `NSTextView` selection.
enum TerminalCodeEditorLineRange {
    /// Range of `line` (1-based) excluding its terminator, or `nil` when the
    /// line number is out of range.
    static func characterRange(forLine line: Int, in text: String) -> NSRange? {
        guard line >= 1 else { return nil }
        let nsText = text as NSString
        var currentLine = 1
        var lineStart = 0

        while true {
            var start = 0
            var end = 0
            var contentsEnd = 0
            nsText.getLineStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: lineStart, length: 0)
            )
            if currentLine == line {
                return NSRange(location: start, length: contentsEnd - start)
            }
            guard end > lineStart, end < nsText.length else { return nil }
            lineStart = end
            currentLine += 1
        }
    }

    /// Caret offset for a 1-based `line`/`column` pair, clamped to the line.
    static func caretRange(forLine line: Int, column: Int?, in text: String) -> NSRange? {
        guard let lineRange = characterRange(forLine: line, in: text) else { return nil }
        guard let column, column >= 1 else { return lineRange }
        let offset = min(column - 1, lineRange.length)
        return NSRange(location: lineRange.location + offset, length: 0)
    }
}
