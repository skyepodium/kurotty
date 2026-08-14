import Foundation
import KurottyCore

/// Where the caret sits and what shape DECSCUSR gave it.
///
/// Pure, and free of any renderer, because it is a question about the frame
/// rather than about a drawing surface: the glyph atlas and a document backend
/// have to put the caret in the same cell, and the one place they could
/// disagree is the composition case below.
///
/// `blinks` is deliberately absent. The surface has already folded the blink
/// phase into `cursorBlinkOn` before the frame is built, so a renderer that
/// consulted the style's blink flag as well would blink the cursor twice.
struct TerminalCursorPlacement: Equatable {
    var column: Int
    var row: Int
    var shape: TerminalCursorStyle.Shape
    var isVisible: Bool

    init(frame: TerminalFrame) {
        column = max(0, Self.caretColumn(frame: frame))
        row = max(0, frame.cursorRow)
        shape = frame.cursorStyle.shape
        isVisible = frame.cursorBlinkOn && frame.cursorRow >= 0
    }

    /// The column the caret occupies, which is inside the composition while one
    /// is being typed: the input method's selected sub-range says where the next
    /// keystroke lands, and a caret parked after the whole preedit would say
    /// something else.
    private static func caretColumn(frame: TerminalFrame) -> Int {
        guard let range = frame.markedTextRenderRange else {
            return frame.cursorColumn
        }

        return range.cursorColumn(
            in: frame.markedText,
            selectedUTF16Location: frame.markedTextSelectedRange.location
        )
    }
}
