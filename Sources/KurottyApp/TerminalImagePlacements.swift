import Foundation
import KurottyCore

/// Where every picture the terminal has been sent sits in the buffer, and which
/// of them the viewport can currently see.
///
/// **Anchored to content rows, not to screen rows.** A screen row is a position
/// in the visible window and means something different after every line of
/// output; a content row counts from the top of the scrollback and does not
/// move once written. An image pinned to a screen row would slide up the
/// picture as text arrived underneath it, which is the same class of mistake as
/// indexing a viewport slice with an absolute row.
///
/// Pure and rendererless, so the arithmetic that decides whether a picture is
/// on screen can be tested without a terminal, a store or a web view.
struct TerminalImagePlacements {
    /// One picture, fixed in the buffer.
    struct Placement: Equatable {
        let identifier: TerminalImageStore.Identifier
        /// Row from the top of the scrollback, which does not change as output
        /// arrives.
        let contentRow: Int
        let column: Int
        let columns: Int
        let rows: Int
        let name: String?

        /// The last content row this picture covers.
        var lastContentRow: Int {
            contentRow + rows - 1
        }
    }

    private(set) var placements: [Placement] = []

    mutating func insert(_ placement: Placement) {
        placements.append(placement)
    }

    mutating func removeAll() {
        placements.removeAll()
    }

    /// Drops the pictures that have scrolled out of the buffer entirely, and
    /// says which they were so their bytes can go too.
    ///
    /// Scrollback is bounded, so rows fall off the top; an image whose last row
    /// has fallen off is unreachable and holding its bytes is a leak that grows
    /// with the session's age rather than with what is on screen.
    mutating func discardBefore(contentRow: Int) -> [TerminalImageStore.Identifier] {
        var dropped: [TerminalImageStore.Identifier] = []

        placements.removeAll { placement in
            guard placement.lastContentRow < contentRow else {
                return false
            }
            dropped.append(placement.identifier)
            return true
        }

        return dropped
    }

    /// The pictures the viewport can see, in the viewport's own coordinates.
    ///
    /// A picture partly above the top of the window keeps its negative row: it
    /// has to be positioned by where it starts, not by where it becomes
    /// visible, or it slides down as the window scrolls past it. Clipping is
    /// the renderer's job and it has a box to do it in.
    func visible(from firstContentRow: Int, rows visibleRows: Int) -> [TerminalFrameImage] {
        let lastContentRow = firstContentRow + visibleRows - 1

        return placements.compactMap { placement in
            guard placement.lastContentRow >= firstContentRow,
                  placement.contentRow <= lastContentRow
            else {
                return nil
            }

            return TerminalFrameImage(
                identifier: placement.identifier.value,
                column: placement.column,
                row: placement.contentRow - firstContentRow,
                columns: placement.columns,
                rows: placement.rows,
                name: placement.name
            )
        }
    }
}
