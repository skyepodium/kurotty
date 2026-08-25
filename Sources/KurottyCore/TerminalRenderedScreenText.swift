import Foundation

public enum TerminalRenderedScreenText {
    public static func line(from cells: [TerminalScreenCell]) -> String {
        TerminalSelectionText.line(from: cells.map {
            TerminalWordSelection.Cell(character: $0.character, isContinuation: $0.isContinuation)
        })
    }

    public static func lines(from rows: [[TerminalScreenCell]]) -> [String] {
        rows.map(line(from:))
    }

    public static func text(from rows: [[TerminalScreenCell]]) -> String {
        lines(from: rows).joined(separator: "\n")
    }
}
