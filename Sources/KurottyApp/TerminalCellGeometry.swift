import Foundation

/// The shapes a terminal draws instead of a glyph, as fractions of one cell.
///
/// Block elements and box drawing are geometry rather than text: the surface
/// converts those characters into `TerminalDecoration` values precisely because
/// no font is involved, and it does not emit a text cell for them. A renderer
/// that ignores them draws the cell's background and nothing else — which is
/// what made Claude Code's mascot a solid black rectangle here once.
///
/// Pure and rendererless. The glyph atlas fills these rectangles directly, a
/// document renderer positions boxes over the cell, and a future canvas backend
/// would fill them again; none of them should re-derive the shapes.
enum TerminalCellGeometry {
    /// A filled rectangle inside one cell, in CSS orientation — `y` measured
    /// downward from the top edge.
    struct Shape: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var color: SIMD4<Float>
    }

    /// Line thickness for box drawing, as a fraction of the cell.
    ///
    /// The atlas derives its own from the font's underline thickness. A
    /// document is sized in cell units and has no font metrics to ask, so this
    /// is a fraction instead.
    static let boxLineRATIO = 0.09

    /// A block element, flipped into CSS orientation.
    ///
    /// The frame measures `y` upward from the bottom of the cell, matching the
    /// renderer that consumed it first. Flipping once here means no caller has
    /// to remember which way is up.
    static func block(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        color: SIMD4<Float>
    ) -> Shape {
        Shape(x: x, y: 1 - y - height, width: width, height: height, color: color)
    }

    /// Box drawing as up to four bars meeting at the centre of the cell.
    ///
    /// Each arm runs from its edge to just past the middle, so a corner joins
    /// without a notch where two bars meet.
    static func box(
        left: Bool,
        right: Bool,
        up: Bool,
        down: Bool,
        color: SIMD4<Float>
    ) -> [Shape] {
        let thickness = boxLineRATIO
        let near = (1 - thickness) / 2
        let far = near + thickness
        var shapes: [Shape] = []

        if left {
            shapes.append(Shape(x: 0, y: near, width: far, height: thickness, color: color))
        }
        if right {
            shapes.append(Shape(x: near, y: near, width: 1 - near, height: thickness, color: color))
        }
        if up {
            shapes.append(Shape(x: near, y: 0, width: thickness, height: far, color: color))
        }
        if down {
            shapes.append(Shape(x: near, y: near, width: thickness, height: 1 - near, color: color))
        }

        return shapes
    }
}
