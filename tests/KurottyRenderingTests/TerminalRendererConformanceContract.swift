import Foundation
import KurottyCore



/// Every input `TerminalFrame` carries.
///
/// Kurotty has two renderers behind one protocol, and every bug found so far in
/// the second one had the same shape: Metal draws something the frame reports
/// and the HTML renderer silently ignores it. Powerline separators, block
/// element geometry and IME marked text were all found by a human noticing a
/// screenshot looked wrong, which does not scale.
///
/// This list is the seam the two renderers actually share. It is written out so
/// it can be compared against the type itself — `TerminalFrame` gaining a field
/// without an entry here fails the census, and an entry without a probe fails
/// the coverage check — and so every entry can be held to the one rule that
/// catches the whole class: **an input the frame carries must be observable in
/// what the renderer produces.** An input that changes nothing observable is an
/// input the renderer dropped.
enum TerminalFrameMember: String, CaseIterable {
    case cells
    case backgrounds
    case decorations
    case images
    case defaultForeground
    case defaultBackground
    case dirtyRows
    case dirtyRects
    case isFullDamage
    case cursorColumn
    case cursorRow
    case cursorBlinkOn
    case cursorStyle
    case markedTextColumn
    case markedText
    case markedTextSelectedRange
    case columns
    case visibleRows
    case cellSize
    case padding

    /// The stored properties `TerminalFrame` really has, asked of the type
    /// rather than of a list somebody remembered to update.
    static func declaredByTheType(in frame: TerminalFrame) -> [String] {
        Mirror(reflecting: frame).children.compactMap(\.label)
    }
}

/// The cases of `TerminalDecoration.Kind`, mirrored so they can be enumerated.
///
/// Swift can enumerate the cases of a `CaseIterable` enum and can check a
/// `switch` for exhaustiveness, but `TerminalDecoration.Kind` has associated
/// values and cannot be `CaseIterable`. The mirror gives the enumeration and
/// `of(_:)` gives the exhaustiveness: it has no `default`, so a new kind stops
/// this file compiling until somebody names it here — and naming it here
/// without a probe then fails the census. That is the check surviving growth,
/// at compile time where it is cheapest.
enum TerminalDecorationKindCase: String, CaseIterable {
    case underline
    case strikethrough
    case boxDrawing
    case blockElement

    static func of(_ kind: TerminalDecoration.Kind) -> Self {
        switch kind {
        case .underline:
            return .underline
        case .strikethrough:
            return .strikethrough
        case .boxDrawing:
            return .boxDrawing
        case .blockElement:
            return .blockElement
        }
    }
}

/// The cases of `TerminalCursorStyle.Shape`, for the same reason.
enum TerminalCursorShapeCase: String, CaseIterable {
    case block
    case underline
    case bar

    static func of(_ shape: TerminalCursorStyle.Shape) -> Self {
        switch shape {
        case .block:
            return .block
        case .underline:
            return .underline
        case .bar:
            return .bar
        }
    }

    var shape: TerminalCursorStyle.Shape {
        switch self {
        case .block:
            return .block
        case .underline:
            return .underline
        case .bar:
            return .bar
        }
    }

    /// The next shape round the ring, so each shape is compared against a
    /// different one and every pair has to come out distinguishable.
    var next: TerminalCursorShapeCase {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

// MARK: - Frames to probe with

/// A `TerminalFrame` under construction.
///
/// A probe changes exactly one input, so the baseline lives here once and each
/// probe is a two-line mutation. Building frames by hand instead would make it
/// far too easy to change two things and call the difference proof.
struct TerminalConformanceFrame {
    enum Baseline {
        static let columnsCOUNT = 12
        static let rowsCOUNT = 4
        static let cellWidthPX = 9.0
        static let cellHeightPX = 18.0
        static let foreground = SIMD4<Float>(0.9, 0.9, 0.9, 1)
        static let background = SIMD4<Float>(0, 0, 0, 1)
        static let accent = SIMD4<Float>(1, 0, 0, 1)
        /// The default colours are deliberately not the colours the baseline's
        /// own cells carry. A frame whose defaults match its cells coalesces
        /// the whole row into one run, so changing a default would split the
        /// row and be observable as *structure* — which would let a renderer
        /// that never emitted a colour at all still pass those two probes.
        static let defaultForeground = SIMD4<Float>(0.5, 0.5, 0.5, 1)
        static let defaultBackground = SIMD4<Float>(0.05, 0.05, 0.05, 1)
        static let text = "ab"
        /// A row and column well inside the baseline grid, so a probe that
        /// moves something there cannot fall off the edge and be clamped.
        static let interiorRow = 1
        static let interiorColumn = 3
    }

    var cells: [TerminalCell]
    var backgrounds: [TerminalBackground] = []
    var decorations: [TerminalDecoration] = []
    var images: [TerminalFrameImage] = []
    var defaultForeground = Baseline.defaultForeground
    var defaultBackground = Baseline.defaultBackground
    var dirtyRows: [Int] = []
    var dirtyRects: [TerminalFrameRect] = []
    var isFullDamage = true
    var cursorColumn = 0
    var cursorRow = 0
    var cursorBlinkOn = true
    var cursorStyle = TerminalCursorStyle.default
    var markedTextColumn = 0
    var markedText = ""
    var markedTextSelectedRange = TerminalTextSelectionRange.none
    var columns = Baseline.columnsCOUNT
    var visibleRows = Baseline.rowsCOUNT
    var cellSize = TerminalFrameSize(width: Baseline.cellWidthPX, height: Baseline.cellHeightPX)
    var padding = TerminalFramePoint.zero

    init(text: String = Baseline.text) {
        cells = Self.row(text)
    }

    static func row(_ text: String, row: Int = 0) -> [TerminalCell] {
        text.enumerated().map { offset, character in
            TerminalCell(
                character: character,
                column: offset,
                row: row,
                foreground: Baseline.foreground,
                background: Baseline.background
            )
        }
    }

    /// The whole-row rect the surface derives from a dirty row, so a damage
    /// probe reports rects the way the real frame builder does.
    static func rowRect(_ row: Int) -> TerminalFrameRect {
        TerminalFrameRect(
            x: 0,
            y: Baseline.cellHeightPX * Double(row),
            width: Baseline.cellWidthPX * Double(Baseline.columnsCOUNT),
            height: Baseline.cellHeightPX
        )
    }

    func frame() -> TerminalFrame {
        TerminalFrame(
            cells: cells,
            backgrounds: backgrounds,
            decorations: decorations,
            images: images,
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            dirtyRows: dirtyRows,
            dirtyRects: dirtyRects,
            isFullDamage: isFullDamage,
            cursorColumn: cursorColumn,
            cursorRow: cursorRow,
            cursorBlinkOn: cursorBlinkOn,
            cursorStyle: cursorStyle,
            markedTextColumn: markedTextColumn,
            markedText: markedText,
            markedTextSelectedRange: markedTextSelectedRange,
            columns: columns,
            visibleRows: visibleRows,
            cellSize: cellSize,
            padding: padding
        )
    }

    /// A copy with one input changed, which is the only way a probe is allowed
    /// to build its second frame.
    func changing(_ mutate: (inout TerminalConformanceFrame) -> Void) -> TerminalConformanceFrame {
        var copy = self
        mutate(&copy)
        return copy
    }
}

// MARK: - Probes

/// One claim about one input.
struct TerminalConformanceProbe {
    /// What the renderer is fed, and what has to come out.
    enum Trial {
        /// Frames differing in exactly one input. Every pair of them must
        /// produce a different document: two frames that a renderer cannot be
        /// told apart from are two frames it draws the same way.
        case distinguishable([TerminalConformanceFrame])
        /// Frames delivered in order, ending in a document that must contain —
        /// or must not contain — a marker. Damage is not content: a frame that
        /// reports nothing dirty is *supposed* to change nothing, so "the
        /// output differs" is the wrong question and "the right thing was
        /// redrawn, and only then" is the right one.
        case sequences([Sequence])
    }

    struct Sequence {
        var frames: [TerminalConformanceFrame]
        var marker: String
        var isExpected: Bool
        var because: String
    }

    /// The name the gap list and the failure message use.
    let name: String
    /// Frame inputs this probe covers. The census fails if a member has none.
    let members: [TerminalFrameMember]
    var decorationKind: TerminalDecorationKindCase?
    var cursorShape: TerminalCursorShapeCase?
    let trial: Trial
}
