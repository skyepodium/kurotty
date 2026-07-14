import Foundation

struct TerminalScrollWheelAccumulator {
    private var pendingPreciseDeltaPX: CGFloat = 0

    mutating func rows(
        for scrollingDeltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        cellHeightPX: CGFloat
    ) -> Int {
        guard scrollingDeltaY != 0 else { return 0 }

        if hasPreciseScrollingDeltas {
            return preciseRows(for: scrollingDeltaY, cellHeightPX: cellHeightPX)
        }

        pendingPreciseDeltaPX = 0
        let normalizedTicks = max(CGFloat(1), abs(scrollingDeltaY))
        let rowsPerTick = DesignTokens.Component.terminalDiscreteScrollRowsPerTick
        let magnitude = max(rowsPerTick, Int(normalizedTicks * CGFloat(rowsPerTick)))
        return scrollingDeltaY > 0 ? magnitude : -magnitude
    }

    private mutating func preciseRows(
        for scrollingDeltaY: CGFloat,
        cellHeightPX: CGFloat
    ) -> Int {
        let normalizedCellHeightPX = max(1, cellHeightPX)
        pendingPreciseDeltaPX += scrollingDeltaY
            * DesignTokens.Component.terminalPreciseScrollMultiplierRATIO
        let rowDelta = Int(pendingPreciseDeltaPX / normalizedCellHeightPX)
        pendingPreciseDeltaPX -= CGFloat(rowDelta) * normalizedCellHeightPX
        return rowDelta
    }
}
