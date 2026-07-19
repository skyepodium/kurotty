public enum TerminalViewportBackgroundPolicy {
    public static func background(
        in rows: [[TerminalScreenCell]],
        columns: Int,
        fallback: SIMD4<Float>
    ) -> SIMD4<Float> {
        guard columns > 0, !rows.isEmpty else { return fallback }

        var counts: [(color: SIMD4<Float>, count: Int)] = [(fallback, 0)]
        func record(_ cell: TerminalScreenCell) {
            let color = renderedBackground(for: cell, fallback: fallback)
            if let index = counts.firstIndex(where: { $0.color.sameColor(as: color) }) {
                counts[index].count += 1
            } else {
                counts.append((color, 1))
            }
        }

        if let top = rows.first {
            for cell in top.prefix(columns) {
                record(cell)
            }
        }
        if rows.count > 1, let bottom = rows.last {
            for cell in bottom.prefix(columns) {
                record(cell)
            }
        }
        if rows.count > 2 {
            for row in rows.dropFirst().dropLast() {
                let visibleCells = row.prefix(columns)
                guard let first = visibleCells.first else { continue }
                record(first)
                if visibleCells.count > 1, let last = visibleCells.last {
                    record(last)
                }
            }
        }

        let largestCount = counts.map(\.count).max() ?? 0
        if counts[0].count == largestCount {
            return fallback
        }
        return counts.first(where: { $0.count == largestCount })?.color ?? fallback
    }

    private static func renderedBackground(
        for cell: TerminalScreenCell,
        fallback: SIMD4<Float>
    ) -> SIMD4<Float> {
        if cell.character == " ", !cell.isContinuation, cell.style == .default {
            return fallback
        }
        return cell.style.effectiveBackground
    }
}
