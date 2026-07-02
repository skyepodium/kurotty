import CoreGraphics

struct TerminalPixelProbe: Equatable {
    enum ReasonCode: String {
        case contained
        case emptyGlyphRect = "empty-glyph-rect"
        case glyphExceedsScissorRect = "glyph-exceeds-scissor-rect"
        case glyphExceedsDirtyRect = "glyph-exceeds-dirty-rect"
        case cellExceedsScissorRect = "cell-exceeds-scissor-rect"
        case cellExceedsDirtyRect = "cell-exceeds-dirty-rect"
        case glyphExceedsCellBounds = "glyph-exceeds-cell-bounds"
        case fractionalPixelEdges = "fractional-pixel-edges"
    }

    let cellRect: CGRect
    let glyphRect: CGRect
    let dirtyRect: CGRect?
    let scissorRect: CGRect?
    let backingScale: CGFloat
    let clippingFlags: TerminalPixelProbeClippingFlags
    let reasonCode: ReasonCode
    let summary: String

    static func make(
        cellRect: CGRect,
        glyphRect: CGRect,
        dirtyRect: CGRect?,
        scissorRect: CGRect?,
        backingScale: CGFloat
    ) -> TerminalPixelProbe {
        let flags = TerminalPixelProbeClippingFlags.make(
            cellRect: cellRect,
            glyphRect: glyphRect,
            dirtyRect: dirtyRect,
            scissorRect: scissorRect,
            backingScale: backingScale
        )
        let reasonCode = reasonCode(for: flags)
        return TerminalPixelProbe(
            cellRect: cellRect,
            glyphRect: glyphRect,
            dirtyRect: dirtyRect,
            scissorRect: scissorRect,
            backingScale: backingScale,
            clippingFlags: flags,
            reasonCode: reasonCode,
            summary: reasonCode.rawValue
        )
    }

    private static func reasonCode(for flags: TerminalPixelProbeClippingFlags) -> ReasonCode {
        if flags.emptyGlyphRect { return .emptyGlyphRect }
        if flags.glyphExceedsScissorRect { return .glyphExceedsScissorRect }
        if flags.glyphExceedsDirtyRect { return .glyphExceedsDirtyRect }
        if flags.cellExceedsScissorRect { return .cellExceedsScissorRect }
        if flags.cellExceedsDirtyRect { return .cellExceedsDirtyRect }
        if flags.glyphExceedsCellBounds { return .glyphExceedsCellBounds }
        if flags.fractionalPixelEdges { return .fractionalPixelEdges }
        return .contained
    }
}

struct TerminalPixelProbeClippingFlags: Equatable {
    let glyphExceedsCellBounds: Bool
    let glyphExceedsDirtyRect: Bool
    let glyphExceedsScissorRect: Bool
    let cellExceedsDirtyRect: Bool
    let cellExceedsScissorRect: Bool
    let fractionalPixelEdges: Bool
    let emptyGlyphRect: Bool

    var hasClipping: Bool {
        glyphExceedsCellBounds ||
            glyphExceedsDirtyRect ||
            glyphExceedsScissorRect ||
            cellExceedsDirtyRect ||
            cellExceedsScissorRect
    }

    static func make(
        cellRect: CGRect,
        glyphRect: CGRect,
        dirtyRect: CGRect?,
        scissorRect: CGRect?,
        backingScale: CGFloat
    ) -> TerminalPixelProbeClippingFlags {
        TerminalPixelProbeClippingFlags(
            glyphExceedsCellBounds: !cellRect.containsRectWithinProbeTolerance(glyphRect),
            glyphExceedsDirtyRect: dirtyRect.map { !$0.containsRectWithinProbeTolerance(glyphRect) } ?? false,
            glyphExceedsScissorRect: scissorRect.map { !$0.containsRectWithinProbeTolerance(glyphRect) } ?? false,
            cellExceedsDirtyRect: dirtyRect.map { !$0.containsRectWithinProbeTolerance(cellRect) } ?? false,
            cellExceedsScissorRect: scissorRect.map { !$0.containsRectWithinProbeTolerance(cellRect) } ?? false,
            fractionalPixelEdges: cellRect.hasFractionalPixelEdge() ||
                glyphRect.hasFractionalPixelEdge() ||
                (dirtyRect?.hasFractionalPixelEdge() ?? false) ||
                (scissorRect?.hasFractionalPixelEdge() ?? false),
            emptyGlyphRect: glyphRect.isEmpty || glyphRect.width <= 0 || glyphRect.height <= 0
        )
    }
}

private extension CGRect {
    func containsRectWithinProbeTolerance(_ rect: CGRect) -> Bool {
        let tolerance: CGFloat = 0.001
        return rect.minX >= minX - tolerance &&
            rect.minY >= minY - tolerance &&
            rect.maxX <= maxX + tolerance &&
            rect.maxY <= maxY + tolerance
    }

    func hasFractionalPixelEdge() -> Bool {
        return [minX, minY, maxX, maxY].contains { edge in
            abs(edge - round(edge)) > 0.001
        }
    }
}
