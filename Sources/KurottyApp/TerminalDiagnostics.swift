import Foundation
import KurottyCore
import simd

struct TerminalNotificationLogMetadata: CustomStringConvertible {
    let identifierPrefix: String
    let titleLength: Int
    let bodyLength: Int

    init(identifierPrefix: String, title: String, body: String) {
        self.identifierPrefix = identifierPrefix
        titleLength = title.count
        bodyLength = body.count
    }

    var description: String {
        "identifierPrefix=\(identifierPrefix) titleLength=\(titleLength) bodyLength=\(bodyLength)"
    }
}

struct TerminalRawPtyLogMetadata: CustomStringConvertible {
    let byteCount: Int

    init(data: Data) {
        byteCount = data.count
    }

    var description: String {
        "byteCount=\(byteCount)"
    }
}

enum TerminalScreenDiagnostics {
    static func occupiedCellCount(in cells: [TerminalScreenCell]) -> Int {
        cells.reduce(0) { count, cell in
            cell.character == " " && cell.style == .default && !cell.isContinuation ? count : count + 1
        }
    }

    static func styleRuns(for styles: [TerminalTextStyle], background: Bool) -> String {
        guard !styles.isEmpty else { return "[]" }
        var runs: [String] = []
        var start = 0
        var color = colorForStyle(styles[0], background: background)
        for index in 1..<styles.count {
            let next = colorForStyle(styles[index], background: background)
            if !sameColor(next, color) {
                runs.append("\(start)-\(index - 1):\(debugRGB(color))")
                start = index
                color = next
            }
        }
        runs.append("\(start)-\(styles.count - 1):\(debugRGB(color))")
        return "[" + runs.joined(separator: ", ") + "]"
    }

    private static func colorForStyle(_ style: TerminalTextStyle, background: Bool) -> SIMD4<Float> {
        background ? style.effectiveBackground : style.effectiveForeground
    }

    private static func sameColor(_ lhs: SIMD4<Float>, _ rhs: SIMD4<Float>) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z && lhs.w == rhs.w
    }

    private static func debugRGB(_ color: SIMD4<Float>) -> String {
        String(format: "(%0.3f,%0.3f,%0.3f,%0.3f)", color.x, color.y, color.z, color.w)
    }
}
