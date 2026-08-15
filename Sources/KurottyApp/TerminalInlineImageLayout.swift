import CoreGraphics
import Foundation

/// How many cells an inline image asks for, and how many it gets.
///
/// A terminal has no notion of a box that is 300 pixels tall; it has rows. So
/// every image has to be resolved into a whole number of columns and rows
/// before anything can be drawn, and the rows it takes are rows the cursor has
/// to skip — otherwise the next line of output is printed through the picture.
///
/// Pure. No image decoding, no renderer, no screen: the inputs are the sender's
/// request, the image's own pixel size, and the terminal's geometry.
enum TerminalInlineImageLayout {
    /// The cells an image will occupy.
    struct Size: Equatable {
        var columns: Int
        var rows: Int
    }

    /// The terminal geometry an image is being placed into.
    struct Bounds: Equatable {
        var columns: Int
        var rows: Int
        var cellWidthPX: CGFloat
        var cellHeightPX: CGFloat
    }

    private enum Minimum {
        /// Every accepted image occupies at least one cell.
        ///
        /// An image resolved to zero rows would advance the cursor by nothing
        /// and be overwritten by the next line before anyone saw it, which
        /// reads as the terminal having silently dropped it.
        static let cellCOUNT = 1
    }

    /// Resolves a request against an image's own size and the terminal's.
    ///
    /// The aspect ratio is honoured whenever exactly one extent is given, which
    /// is the common case (`width=40`) and the one where guessing the other
    /// dimension is the whole job. With both given it is honoured only if the
    /// sender asked, matching iTerm2: `preserveAspectRatio=0` is how a program
    /// says it means to stretch.
    static func size(
        for payload: TerminalInlineImagePayload,
        pixelSize: CGSize,
        in bounds: Bounds
    ) -> Size {
        let cellWidth = max(bounds.cellWidthPX, 1)
        let cellHeight = max(bounds.cellHeightPX, 1)

        let requestedColumns = cells(
            payload.width,
            axisPixels: pixelSize.width,
            cellPixels: cellWidth,
            axisCells: bounds.columns
        )
        let requestedRows = cells(
            payload.height,
            axisPixels: pixelSize.height,
            cellPixels: cellHeight,
            axisCells: bounds.rows
        )

        var columns = requestedColumns
        var rows = requestedRows

        // One extent given: the other follows from the image's own proportions,
        // measured in cells rather than pixels, because a cell is taller than
        // it is wide and an aspect ratio applied in pixels comes out squashed.
        let ratio = aspectRatioInCells(pixelSize: pixelSize, cellWidth: cellWidth, cellHeight: cellHeight)
        if payload.width == .auto, payload.height != .auto, ratio > 0 {
            columns = Int((CGFloat(rows) * ratio).rounded())
        } else if payload.height == .auto, payload.width != .auto, ratio > 0 {
            rows = Int((CGFloat(columns) / ratio).rounded())
        } else if payload.width != .auto, payload.height != .auto, payload.preservesAspectRatio, ratio > 0 {
            // Both given and the ratio is to be kept, so the request becomes a
            // box the image is fitted inside rather than stretched to.
            let fittedRows = Int((CGFloat(columns) / ratio).rounded())
            if fittedRows <= rows {
                rows = fittedRows
            } else {
                columns = Int((CGFloat(rows) * ratio).rounded())
            }
        }

        return Size(
            columns: clamped(columns, to: bounds.columns),
            rows: clamped(rows, to: bounds.rows)
        )
    }

    /// One extent as a cell count.
    private static func cells(
        _ extent: TerminalInlineImagePayload.Extent,
        axisPixels: CGFloat,
        cellPixels: CGFloat,
        axisCells: Int
    ) -> Int {
        switch extent {
        case .auto:
            return Int((axisPixels / cellPixels).rounded())
        case let .cells(count):
            return count
        case let .pixels(count):
            return Int((CGFloat(count) / cellPixels).rounded())
        case let .percent(share):
            return Int((CGFloat(axisCells) * CGFloat(share) / 100).rounded())
        }
    }

    /// The image's width-to-height ratio expressed in cells rather than pixels.
    private static func aspectRatioInCells(
        pixelSize: CGSize,
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) -> CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return 0
        }
        return (pixelSize.width / cellWidth) / (pixelSize.height / cellHeight)
    }

    private static func clamped(_ value: Int, to limit: Int) -> Int {
        min(max(value, Minimum.cellCOUNT), max(limit, Minimum.cellCOUNT))
    }
}
