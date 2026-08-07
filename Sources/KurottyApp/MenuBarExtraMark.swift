import AppKit

/// Kurotty's own mark, reduced to the one shape that survives a menu bar.
///
/// The app icon cannot be used directly. A menu-bar image is a *template*: the
/// system reads only its alpha and paints the coverage dark on a light bar,
/// light on a dark one, and inverted again while the menu is held open. Handing
/// it a full-colour render therefore hands it a silhouette, and the app icon's
/// silhouette is a white cat, three speed lines, a paw, and a wave — an ink
/// bounding box far wider than it is tall, most of which is not the cat.
///
/// So the mark is re-drawn here rather than extracted. Extraction keeps the
/// parts of the artwork that only make sense in colour; this keeps the parts
/// that still say "Kurotty" in one flat tone at 18pt: the round head, the two
/// pointed ears, and the two tall oval eyes. The speed lines, the paw, the
/// wave, the blush, and the 3D shading are all dropped, because at 18pt they
/// are noise around the face rather than detail on it.
///
/// A path rather than a generated bitmap, so nothing has to be produced at
/// package time and nothing binary is committed: the same geometry renders at
/// whatever backing scale the display asks for.
enum MenuBarExtraMark {
    /// Geometry is authored in a unit square with a **top-left** origin, which
    /// is how the artwork reads, and mapped into AppKit's bottom-left space on
    /// the way out. Keeping the authoring space separate from the drawing space
    /// is what lets the numbers below be compared against the icon by eye.
    private static func point(_ x: CGFloat, _ y: CGFloat, in bounds: NSRect) -> NSPoint {
        NSPoint(x: bounds.minX + x * bounds.width, y: bounds.maxY - y * bounds.height)
    }

    /// The whole mark as one path: the silhouette as a single closed contour,
    /// then the eyes as separate contours inside it.
    ///
    /// The winding rule is even-odd, which is what makes the eyes holes rather
    /// than a second layer of ink. It also means the silhouette has to be one
    /// continuous outline with the ears built into it — an ear added as its own
    /// overlapping triangle would punch a hole where it crossed the head, which
    /// is the failure mode a union of shapes has under this rule.
    static func path(in bounds: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        appendSilhouette(to: path, in: bounds)
        appendEye(to: path, centerX: 0.315, in: bounds)
        appendEye(to: path, centerX: 0.685, in: bounds)
        return path
    }

    private static func appendSilhouette(to path: NSBezierPath, in bounds: NSRect) {
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { point(x, y, in: bounds) }

        // The ears are straight-edged triangles rather than curved ones: a
        // curved ear edge is a one-pixel taper at this size and antialiases
        // into a grey smear, while a straight edge stays an edge. Each base
        // spans about a third of the head's width and each apex sits centred
        // over its own base — a narrow ear, or an apex pushed out towards the
        // corner, is the difference between a cat and a horned blob, and it is
        // the first thing that goes wrong when the head is widened. The tips
        // stop a hair inside the top edge, because a point landing exactly on
        // the boundary antialiases away and reads as clipped.
        path.move(to: p(0.225, 0.020))
        path.line(to: p(0.400, 0.265))
        // The crown between the ears. A shallow dome, not a V: the icon's head
        // is round and a deep notch here reads as a third, smaller ear. The
        // ears clear it by about a quarter of the head's height, which is the
        // ratio the icon draws — taller and the cat starts reading as a bat.
        path.curve(to: p(0.600, 0.265), controlPoint1: p(0.450, 0.210), controlPoint2: p(0.550, 0.210))
        path.line(to: p(0.775, 0.020))
        // The shoulder: where the ear's outer edge hands off to the skull. From
        // here down the outline is all curve, so the head is a cheek rather than
        // the flank of a triangle.
        path.line(to: p(0.945, 0.400))
        path.curve(to: p(0.980, 0.620), controlPoint1: p(0.968, 0.470), controlPoint2: p(0.980, 0.545))
        path.curve(to: p(0.760, 0.955), controlPoint1: p(0.980, 0.790), controlPoint2: p(0.900, 0.900))
        // The chin. Control points pushed past y=1 so the curve's own midpoint
        // reaches the bottom edge; a chin that stops short leaves the head
        // looking cropped rather than round.
        path.curve(to: p(0.240, 0.955), controlPoint1: p(0.650, 1.015), controlPoint2: p(0.350, 1.015))
        path.curve(to: p(0.020, 0.620), controlPoint1: p(0.100, 0.900), controlPoint2: p(0.020, 0.790))
        path.curve(to: p(0.055, 0.400), controlPoint1: p(0.020, 0.545), controlPoint2: p(0.032, 0.470))
        path.close()
    }

    /// One eye, as a tall oval. Tall rather than round because that is what the
    /// icon draws, and because a vertical oval keeps more open area per pixel of
    /// width than a circle does once the whole face is 18pt across — the eye is
    /// the first feature that closes up when the mark is scaled down, and a
    /// closed eye turns the cat back into a blob.
    private static func appendEye(to path: NSBezierPath, centerX: CGFloat, in bounds: NSRect) {
        let radiusX: CGFloat = 0.120
        let radiusY: CGFloat = 0.175
        let centerY: CGFloat = 0.635
        let rect = NSRect(
            x: bounds.minX + (centerX - radiusX) * bounds.width,
            y: bounds.maxY - (centerY + radiusY) * bounds.height,
            width: 2 * radiusX * bounds.width,
            height: 2 * radiusY * bounds.height
        )
        path.appendOval(in: rect)
    }
}
