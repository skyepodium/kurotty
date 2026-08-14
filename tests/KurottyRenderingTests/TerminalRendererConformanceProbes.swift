import Foundation
import KurottyCore

/// The probe table, and the gaps it currently finds.
enum TerminalRendererConformance {
    /// Inputs the HTML renderer does not observe today.
    ///
    /// A ratchet, not a suppression list. A probe that fails without an entry
    /// here fails the suite; an entry whose probe has started passing also
    /// fails the suite, so a fixed gap cannot quietly stay on the list. Each
    /// reason says what the renderer draws instead.
    static let knownGaps: [String: String] = [
        "padding": """
        The frame's content inset never reaches the page. Metal offsets every \
        cell, cursor, decoration and marked-text box by frame.padding; the HTML \
        document has `padding: 0` and positions rows from the window's top-left \
        corner, so the two renderers put the same screen in different places.
        """,
        "dirtyRects": """
        Rect damage is ignored; only dirtyRows patches a row. Harmless today \
        because the surface derives rects one-per-dirty-row, so a rect-only \
        frame is currently unreachable — but the same omission is why the HTML \
        renderer's damageDiagnostics is always empty.
        """,
        "cursorStyle.block": "DECSCUSR shape never reaches the page: #cursor is always a full-cell box.",
        "cursorStyle.underline": "DECSCUSR shape never reaches the page: #cursor is always a full-cell box.",
        "cursorStyle.bar": "DECSCUSR shape never reaches the page: #cursor is always a full-cell box.",
        "markedText": "IME preedit is never drawn; the composing text is invisible in this renderer.",
        "markedTextColumn": "IME preedit anchor is never read, so there is nowhere for the preedit to move.",
        "markedTextSelectedRange": "The caret inside the preedit is never drawn.",
    ]

    static let probes: [TerminalConformanceProbe] = content + decorations + cursor + preedit + geometry + damage

    // MARK: Content

    private static let content: [TerminalConformanceProbe] = [
        TerminalConformanceProbe(
            name: "cells",
            members: [.cells],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame(text: "zb"),
            ])
        ),
        TerminalConformanceProbe(
            name: "backgrounds",
            members: [.backgrounds],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing {
                    $0.backgrounds = [TerminalBackground(
                        column: TerminalConformanceFrame.Baseline.interiorColumn,
                        row: TerminalConformanceFrame.Baseline.interiorRow,
                        color: TerminalConformanceFrame.Baseline.accent
                    )]
                },
            ])
        ),
        TerminalConformanceProbe(
            name: "defaultForeground",
            members: [.defaultForeground],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing {
                    $0.defaultForeground = TerminalConformanceFrame.Baseline.accent
                },
            ])
        ),
        TerminalConformanceProbe(
            name: "defaultBackground",
            members: [.defaultBackground],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing {
                    $0.defaultBackground = TerminalConformanceFrame.Baseline.accent
                },
            ])
        ),
    ]

    // MARK: Decorations

    /// One probe per decoration kind, each comparing a frame carrying that kind
    /// against the same frame carrying nothing. A kind the projector skips
    /// leaves the two frames identical, which is exactly what the block-element
    /// bug did.
    private static let decorations: [TerminalConformanceProbe] = TerminalDecorationKindCase.allCases.map { kind in
        TerminalConformanceProbe(
            name: "decoration.\(kind.rawValue)",
            members: [.decorations],
            decorationKind: kind,
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing {
                    $0.decorations = [TerminalDecoration(
                        column: TerminalConformanceFrame.Baseline.interiorColumn,
                        row: TerminalConformanceFrame.Baseline.interiorRow,
                        width: 1,
                        kind: decorationKind(kind),
                        color: TerminalConformanceFrame.Baseline.accent
                    )]
                },
            ])
        )
    }

    private static func decorationKind(_ kind: TerminalDecorationKindCase) -> TerminalDecoration.Kind {
        switch kind {
        case .underline:
            return .underline
        case .strikethrough:
            return .strikethrough
        case .boxDrawing:
            return .boxDrawing(left: true, right: true, up: false, down: false)
        case .blockElement:
            return .blockElement(x: 0, y: 0, width: 1, height: 0.5)
        }
    }

    // MARK: Cursor

    private static let cursor: [TerminalConformanceProbe] = [
        TerminalConformanceProbe(
            name: "cursorColumn",
            members: [.cursorColumn],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing {
                    $0.cursorColumn = TerminalConformanceFrame.Baseline.interiorColumn
                },
            ])
        ),
        TerminalConformanceProbe(
            name: "cursorRow",
            members: [.cursorRow],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing {
                    $0.cursorRow = TerminalConformanceFrame.Baseline.interiorRow
                },
            ])
        ),
        TerminalConformanceProbe(
            name: "cursorBlinkOn",
            members: [.cursorBlinkOn],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing { $0.cursorBlinkOn = false },
            ])
        ),
    ] + TerminalCursorShapeCase.allCases.map { shape in
        // Each shape against the next one round the ring, so all three pairs
        // have to be distinguishable and a renderer that draws two of the three
        // the same way fails on exactly the pair it confuses.
        //
        // Deliberately about `shape` only. `TerminalCursorStyle.blinks` decides
        // whether the cursor follows the blink phase, and the surface has
        // already folded that decision into `cursorBlinkOn` before the frame is
        // built, so requiring the renderer to draw `blinks` as well would be
        // asking it to reimplement a decision it is handed.
        TerminalConformanceProbe(
            name: "cursorStyle.\(shape.rawValue)",
            members: [.cursorStyle],
            cursorShape: shape,
            trial: .distinguishable([
                TerminalConformanceFrame().changing {
                    $0.cursorStyle = TerminalCursorStyle(shape: shape.shape, blinks: false)
                },
                TerminalConformanceFrame().changing {
                    $0.cursorStyle = TerminalCursorStyle(shape: shape.next.shape, blinks: false)
                },
            ])
        )
    }

    // MARK: IME preedit

    /// Marked text is composition state, not screen content: the terminal
    /// buffer must not contain it, so the renderer is the only thing that can
    /// show it. `TerminalMetalView` names it in 37 places.
    private static let preeditText = "한글"

    private static let preedit: [TerminalConformanceProbe] = [
        TerminalConformanceProbe(
            name: "markedText",
            members: [.markedText],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing { $0.markedText = preeditText },
            ])
        ),
        TerminalConformanceProbe(
            name: "markedTextColumn",
            members: [.markedTextColumn],
            trial: .distinguishable([
                TerminalConformanceFrame().changing {
                    $0.markedText = preeditText
                    $0.markedTextColumn = 0
                },
                TerminalConformanceFrame().changing {
                    $0.markedText = preeditText
                    $0.markedTextColumn = TerminalConformanceFrame.Baseline.interiorColumn
                },
            ])
        ),
        TerminalConformanceProbe(
            name: "markedTextSelectedRange",
            members: [.markedTextSelectedRange],
            trial: .distinguishable([
                TerminalConformanceFrame().changing {
                    $0.markedText = preeditText
                    $0.markedTextSelectedRange = TerminalTextSelectionRange(location: 0, length: 0)
                },
                TerminalConformanceFrame().changing {
                    $0.markedText = preeditText
                    $0.markedTextSelectedRange = TerminalTextSelectionRange(
                        location: preeditText.utf16.count,
                        length: 0
                    )
                },
            ])
        ),
    ]

    // MARK: Geometry

    private static let geometry: [TerminalConformanceProbe] = [
        TerminalConformanceProbe(
            name: "columns",
            members: [.columns],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing {
                    $0.columns = TerminalConformanceFrame.Baseline.columnsCOUNT + 2
                },
            ])
        ),
        TerminalConformanceProbe(
            name: "visibleRows",
            members: [.visibleRows],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing {
                    $0.visibleRows = TerminalConformanceFrame.Baseline.rowsCOUNT + 2
                },
            ])
        ),
        TerminalConformanceProbe(
            name: "cellSize",
            members: [.cellSize],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing {
                    $0.cellSize = TerminalFrameSize(
                        width: TerminalConformanceFrame.Baseline.cellWidthPX + 2,
                        height: TerminalConformanceFrame.Baseline.cellHeightPX + 4
                    )
                },
            ])
        ),
        TerminalConformanceProbe(
            name: "padding",
            members: [.padding],
            trial: .distinguishable([
                TerminalConformanceFrame(),
                TerminalConformanceFrame().changing {
                    $0.padding = TerminalFramePoint(
                        x: TerminalConformanceFrame.Baseline.cellWidthPX,
                        y: TerminalConformanceFrame.Baseline.cellHeightPX
                    )
                },
            ])
        ),
    ]

    // MARK: Damage

    /// The marker a damage probe looks for. It is a character the baseline
    /// frame does not contain, so finding it in the document means the changed
    /// row was really redrawn rather than merely still being there.
    private static let redrawnMARKER = "Z"

    private static var seedFrame: TerminalConformanceFrame { TerminalConformanceFrame(text: "ab") }
    private static var redrawnFrame: TerminalConformanceFrame {
        TerminalConformanceFrame(text: redrawnMARKER + "b").changing { $0.isFullDamage = false }
    }

    private static let damage: [TerminalConformanceProbe] = [
        TerminalConformanceProbe(
            name: "isFullDamage",
            members: [.isFullDamage],
            trial: .sequences([
                TerminalConformanceProbe.Sequence(
                    frames: [seedFrame, redrawnFrame.changing { $0.isFullDamage = true }],
                    marker: redrawnMARKER,
                    isExpected: true,
                    because: "a full-damage frame must redraw the screen even with no row reported dirty"
                ),
            ])
        ),
        TerminalConformanceProbe(
            name: "dirtyRows",
            members: [.dirtyRows],
            trial: .sequences([
                TerminalConformanceProbe.Sequence(
                    frames: [seedFrame, redrawnFrame.changing { $0.dirtyRows = [0] }],
                    marker: redrawnMARKER,
                    isExpected: true,
                    because: "a row reported dirty must be redrawn"
                ),
                TerminalConformanceProbe.Sequence(
                    frames: [seedFrame, redrawnFrame],
                    marker: redrawnMARKER,
                    isExpected: false,
                    because: "a renderer that redraws a row nobody reported dirty is not reading dirtyRows at all"
                ),
            ])
        ),
        TerminalConformanceProbe(
            name: "dirtyRects",
            members: [.dirtyRects],
            trial: .sequences([
                TerminalConformanceProbe.Sequence(
                    frames: [seedFrame, redrawnFrame.changing {
                        $0.dirtyRects = [TerminalConformanceFrame.rowRect(0)]
                    }],
                    marker: redrawnMARKER,
                    isExpected: true,
                    because: "damage reported as a rect must be redrawn like damage reported as a row"
                ),
            ])
        ),
    ]
}
