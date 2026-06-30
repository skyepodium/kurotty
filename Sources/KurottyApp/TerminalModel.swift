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

    private static let linkRegex = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#)
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}")

    let row: Int
    let startColumn: Int
    let endColumn: Int
    let urlString: String

    func contains(row: Int, column: Int) -> Bool {
        self.row == row && column >= startColumn && column < endColumn
    }

    static func find(in cells: [TerminalScreenCell], row: Int, column: Int) -> TerminalLinkRange? {
        var text = ""
        var columnsByCharacterOffset: [Int] = []
        for (cellColumn, cell) in cells.enumerated() where !cell.isContinuation {
            text.append(cell.character)
            columnsByCharacterOffset.append(cellColumn)
        }
        guard !text.isEmpty else { return nil }

        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in linkRegex.matches(in: text, range: searchRange) {
            guard let textRange = Range(match.range, in: text) else { continue }
            var urlString = String(text[textRange])
            while let scalar = urlString.unicodeScalars.last, trailingPunctuation.contains(scalar) {
                urlString.removeLast()
            }
            guard !urlString.isEmpty else { continue }

            let startOffset = text.distance(from: text.startIndex, to: textRange.lowerBound)
            let endOffset = startOffset + urlString.count
            guard startOffset >= 0,
                  endOffset > startOffset,
                  startOffset < columnsByCharacterOffset.count,
                  endOffset - 1 < columnsByCharacterOffset.count else {
                continue
            }

            let startColumn = columnsByCharacterOffset[startOffset]
            let endColumn = columnsByCharacterOffset[endOffset - 1] + 1
            if column >= startColumn && column < endColumn {
                return TerminalLinkRange(
                    row: row,
                    startColumn: startColumn,
                    endColumn: endColumn,
                    urlString: urlString
                )
            }
        }
        return nil
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
