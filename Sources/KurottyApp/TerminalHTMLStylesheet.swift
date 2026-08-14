import AppKit
import KurottyCore

/// The document the rows are hosted in, and the rules that draw them.
///
/// Separated from the view because it is a different kind of thing: the view
/// owns a web view's lifetime and the bridge to it, while this is a pure
/// description of how a terminal looks. Nothing here touches WebKit, so the
/// stylesheet can be read, diffed and reasoned about without a renderer, and a
/// second document-shaped backend could adopt it whole.
enum TerminalHTMLStylesheet {
    /// The CSS font stack: the configured face, then whatever the glyph atlas
    /// would fall back to.
    static func fontStack(for font: NSFont) -> String {
        var families = [font.familyName ?? font.fontName]

        // The same named list the glyph atlas walks, for the same reason: a
        // powerline separator lives in the private use area, and CoreText's
        // cascade answers `.LastResort` for it even on a machine that has a
        // Nerd Font installed. Asking the cascade alone is what left those
        // cells as empty boxes on this renderer's first run, while Metal drew
        // them correctly from this list.
        for family in TerminalGlyphFallbackFonts.installed(
            from: TerminalGlyphFallbackFonts.general + TerminalGlyphFallbackFonts.cjk,
            size: font.pointSize
        ) where !families.contains(family) {
            families.append(family)
        }

        // Generic families last, so a machine with none of the above still
        // renders monospaced text rather than proportional.
        let quoted = families.map { "\"\($0)\"" }.joined(separator: ", ")
        return "\(quoted), ui-monospace, monospace"
    }

    /// The page the rows live in.
    ///
    /// Everything positional is a CSS variable, so a font or size change is a
    /// variable update rather than a different document, and a row can size its
    /// runs in cell units without knowing the pixel size.
    static func document(
        font: NSFont,
        backgroundColor: SIMD4<Float>,
        cursorColor: SIMD4<Float>,
        cellSize: TerminalFrameSize,
        padding: TerminalFramePoint
    ) -> String {
        let background = TerminalHTMLDocument.css(backgroundColor)
        let cursor = TerminalHTMLDocument.css(cursorColor)
        let size = font.pointSize
        let stack = fontStack(for: font)

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
        :root {
            \(TerminalHTMLDocument.Variable.cellWidth): \(cellSize.width)px;
            \(TerminalHTMLDocument.Variable.cellHeight): \(cellSize.height)px;
            \(TerminalHTMLDocument.Variable.paddingX): \(padding.x)px;
            \(TerminalHTMLDocument.Variable.paddingY): \(padding.y)px;
        }
        html, body {
            margin: 0; padding: 0;
            background: \(background);
            overflow: hidden;
            cursor: text;
            /* The second half of the one-selection rule. `TerminalHTMLWebView`
               stops a gesture from ever reaching the page; this stops the page
               from holding a selection by any other route — a stray
               `Select All` that escapes the responder chain, a caret WebKit
               places on load, a future script. A DOM selection here would draw
               a second highlight over the surface's own, and the two would
               disagree on wide glyphs and trailing blanks. The selection the
               user sees arrives inside the frame, as cell colours. */
            user-select: none;
            -webkit-user-select: none;
        }
        /* The grid's origin, and the reason it is a box rather than padding on
           the rows: the cursor is positioned absolutely and has to share the
           origin, so both live inside one offset container and neither has to
           add the padding itself. */
        #\(TerminalHTMLDocument.Markup.gridID) {
            position: absolute;
            left: var(\(TerminalHTMLDocument.Variable.paddingX));
            top: var(\(TerminalHTMLDocument.Variable.paddingY));
        }
        #screen {
            position: relative;
            font-family: \(stack);
            font-size: \(size)px;
            line-height: var(--ch);
            white-space: pre;
            -webkit-font-smoothing: antialiased;
        }
        .\(TerminalHTMLDocument.Markup.rowClass) {
            height: var(--ch);
            white-space: pre;
        }
        .\(TerminalHTMLDocument.Markup.runClass) {
            display: inline-block;
            height: var(--ch);
            vertical-align: top;
            overflow: hidden;
        }
        .\(TerminalHTMLDocument.Markup.underlineClass) { text-decoration: underline; }
        .\(TerminalHTMLDocument.Markup.strikethroughClass) { text-decoration: line-through; }
        .\(TerminalHTMLDocument.Markup.underlineClass).\(TerminalHTMLDocument.Markup.strikethroughClass) {
            text-decoration: underline line-through;
        }
        #cursor {
            position: absolute;
            top: 0; left: 0;
            width: var(--cw);
            height: var(--ch);
            background: \(cursor);
            mix-blend-mode: difference;
            pointer-events: none;
            will-change: transform;
        }
        </style></head>
        <body><div id="\(TerminalHTMLDocument.Markup.gridID)"><div id="screen"></div><div id="cursor"></div></div></body></html>
        """
    }
}
