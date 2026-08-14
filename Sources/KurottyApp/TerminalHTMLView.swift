import AppKit
import KurottyCore
import WebKit

/// A terminal renderer that draws into a web view instead of a glyph atlas.
///
/// The alternative to `TerminalMetalView`, selected through
/// `TerminalRendererFactory`. Both implement `TerminalAppKitRenderer` and both
/// receive the same `TerminalFrame`, damage included, so nothing above this
/// layer knows which one is drawing.
///
/// **The web view displays; it never handles input.** Keyboard, IME, mouse and
/// scrolling stay on the AppKit path they already take, which is the design
/// decision that protects the Hangul composition work in `AGENTS.md`: marked
/// text belongs to `NSTextInputContext` and a web content process must not be
/// allowed to own it. The view is therefore hit-test transparent and never
/// becomes first responder.
///
/// Rows are patched, not rebuilt. The frame already carries the damage the
/// surface computed, so an ordinary keystroke replaces one row's markup and
/// leaves the other twenty-three alone.
@MainActor
final class TerminalHTMLView: NSView, TerminalAppKitRenderer {
    private enum Script {
        /// One frame, in one call.
        ///
        /// Everything a frame changes travels together — cell metrics, rows,
        /// cursor — because each `callAsyncJavaScript` is a round trip to the
        /// web content process, and three per frame is three times the crossing
        /// for no benefit.
        ///
        /// It resolves after a double `requestAnimationFrame`, which is the
        /// closest a web view offers to "this has been composited". That is what
        /// makes `onPresented` mean the same thing here as it does for Metal,
        /// which fires it from the command buffer's completion handler. Firing
        /// it when the script was merely *sent* would report a latency that
        /// excludes all the work being measured.
        ///
        /// Screen content arrives as arguments. Terminal output is bytes from an
        /// arbitrary program, and interpolating them into source is how that
        /// program gets to write the script.
        static let applyFrame = """
        if (cellWidth > 0) {
            document.documentElement.style.setProperty('--cw', cellWidth + 'px');
            document.documentElement.style.setProperty('--ch', cellHeight + 'px');
        }

        if (replaceAll) {
            const screen = document.getElementById('screen');
            if (screen) { screen.innerHTML = rows.join(''); }
        } else {
            // The row element stays and only its children change. Replacing a
            // row's `outerHTML` discards a live element and its layout box on
            // every keystroke; this keeps the box and reparses only the spans.
            for (const [id, markup] of Object.entries(patch)) {
                const row = document.getElementById(id);
                if (row) { row.innerHTML = markup; }
            }
        }

        const cursor = document.getElementById('cursor');
        if (cursor) {
            cursor.style.transform =
                `translate(calc(var(--cw) * ${cursorColumn}), calc(var(--ch) * ${cursorRow}))`;
            cursor.style.opacity = cursorVisible ? '1' : '0';
        }

        await new Promise(resolve =>
            requestAnimationFrame(() => requestAnimationFrame(resolve))
        );
        """
    }

    private enum Metrics {
        /// Frames that arrive before the shell has loaded are coalesced to the
        /// most recent one. A queue would replay a backlog of screens nobody
        /// will see.
        static let pendingFrameCOUNT = 1
        /// How long a frame may go unreported before the renderer reports it
        /// anyway. Far beyond a frame budget: this catches a page that has
        /// stopped animating, not a page that is merely slow.
        static let presentationDeadlineSECONDS = 0.5
    }

    private let webView: WKWebView
    private var isDocumentLoaded = false
    private var pendingFrame: TerminalFrame?
    private var renderedRows: [String] = []
    private var font: NSFont
    private var backgroundColor: SIMD4<Float>
    private var cursorColor: SIMD4<Float>
    private var cellSize = TerminalFrameSize(width: 8, height: 16)
    /// The document is loaded with placeholder cell metrics, so the first frame
    /// must publish real ones even when they happen to match the placeholder.
    private var hasPublishedCellSize = false
    private var presentationWatchdog: DispatchWorkItem?
    private var isAwaitingPresentation = false

    var onPresented: (() -> Void)?
    var rendererView: NSView { self }

    // Diagnostics the protocol requires. The overlays are Metal-specific
    // drawing aids with no counterpart here; they are accepted and ignored
    // rather than made to look implemented.
    var diagnosticRenderingLogEnabled = false
    var diagnosticFullRedrawEnabled = false
    var diagnosticCellBoundaryOverlayEnabled = false
    var diagnosticBaselineOverlayEnabled = false
    var diagnosticGlyphQuadOverlayEnabled = false
    private(set) var damageDiagnostics = TerminalRenderDamageDiagnostics.empty

    init(font: NSFont, backgroundColor: SIMD4<Float>, cursorColor: SIMD4<Float>) {
        self.font = font
        self.backgroundColor = backgroundColor
        self.cursorColor = cursorColor

        let configuration = WKWebViewConfiguration()
        // The document runs one small script that patches rows. Nothing it
        // renders can reach the network: the stylesheet references no resource
        // and the page has no way to make a request.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = false

        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: .zero)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        webView.navigationDelegate = self
        loadShell()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalHTMLView is created in code, not from a nib")
    }

    /// Input belongs to the surface above, not to the web content process.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    // MARK: - Frames

    func update(frame: TerminalFrame) {
        guard isDocumentLoaded else {
            cellSize = frame.cellSize
            pendingFrame = frame
            return
        }

        draw(frame)
    }

    private func draw(_ frame: TerminalFrame) {
        let rows = TerminalHTMLDocument.rows(frame: frame)
        let replaceAll = frame.isFullDamage || renderedRows.count != rows.count
        var patch: [String: String] = [:]

        if replaceAll {
            renderedRows = rows
        } else {
            for row in frame.dirtyRows where rows.indices.contains(row) {
                guard renderedRows[row] != rows[row] else {
                    continue
                }
                renderedRows[row] = rows[row]
                patch["\(TerminalHTMLDocument.Markup.rowIDPrefix)\(row)"] =
                    TerminalHTMLDocument.rowContents(row, frame: frame)
            }

            // Nothing visible changed. The frame still has to report itself
            // presented or the latency metric waits forever for a paint that is
            // not coming.
            guard !patch.isEmpty else {
                presentationWatchdog?.cancel()
                presentationWatchdog = nil
                isAwaitingPresentation = false
                onPresented?()
                return
            }
        }

        let publishesCellSize = cellSize != frame.cellSize || !hasPublishedCellSize
        cellSize = frame.cellSize
        hasPublishedCellSize = true

        armPresentationWatchdog()

        run(Script.applyFrame, arguments: [
            "cellWidth": publishesCellSize ? Double(frame.cellSize.width) : 0,
            "cellHeight": Double(frame.cellSize.height),
            "replaceAll": replaceAll,
            "rows": replaceAll ? rows : [],
            "patch": patch,
            "cursorColumn": frame.cursorColumn,
            "cursorRow": frame.cursorRow,
            "cursorVisible": frame.cursorBlinkOn,
        ])
    }

    /// Reports the frame presented even if the page never answers.
    ///
    /// The script resolves after a double `requestAnimationFrame`, and a web
    /// view stops servicing those when its window is occluded or minimised. On
    /// Metal an occluded window still completes its command buffer, so the
    /// difference is not cosmetic: without this, the app's latency accounting
    /// waits on a paint that is never coming, and every frame after it is timed
    /// from the wrong start.
    ///
    /// The deadline is generous on purpose. It exists to stop a stall, not to
    /// cut a slow frame short, and firing it early would report a presentation
    /// that has not happened.
    private func armPresentationWatchdog() {
        presentationWatchdog?.cancel()

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.isAwaitingPresentation else {
                return
            }
            self.isAwaitingPresentation = false
            self.onPresented?()
        }

        presentationWatchdog = watchdog
        isAwaitingPresentation = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Metrics.presentationDeadlineSECONDS,
            execute: watchdog
        )
    }

    private func run(_ body: String, arguments: [String: Any]) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                if case let .failure(error) = result {
                    // Never the screen's contents: terminal output is sensitive,
                    // and a failure message quoting a row would put it in a log.
                    NSLog("terminal html renderer script failed: %@", error.localizedDescription)
                }

                // Reported on failure too. A frame that never reports leaves the
                // latency metric waiting on a paint that will not arrive.
                self.presentationWatchdog?.cancel()
                self.presentationWatchdog = nil

                guard self.isAwaitingPresentation else {
                    return  // The watchdog already reported this frame.
                }
                self.isAwaitingPresentation = false
                self.onPresented?()
            }
        }
    }

    // MARK: - Appearance

    func applyAppearance(
        font: NSFont,
        backgroundColor: SIMD4<Float>,
        cursorColor: SIMD4<Float>
    ) {
        self.font = font
        self.backgroundColor = backgroundColor
        self.cursorColor = cursorColor

        guard isDocumentLoaded else {
            return
        }

        loadShell()
    }

    /// The CSS font stack: the configured font, then whatever CoreText falls
    /// back to for the glyphs it lacks.
    ///
    /// Menlo is the default and has no powerline separators, yet the glyph
    /// atlas draws them — because CoreText's cascade finds an installed font
    /// that does. Naming only the configured family here left those cells as
    /// missing-glyph boxes, which is what the first screenshot showed. Asking
    /// CoreText the same question the atlas asks keeps both renderers drawing
    /// from the same fonts, rather than hardcoding a list of font names this
    /// machine happens to have.
    private func fontStack() -> String {
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

    private func loadShell() {
        isDocumentLoaded = false
        hasPublishedCellSize = false
        renderedRows = []
        webView.loadHTMLString(shellDocument(), baseURL: nil)
    }

    /// The page the rows live in.
    ///
    /// Everything positional is a CSS variable so a font or size change is a
    /// variable update rather than a different document, and every row can size
    /// its runs in cell units without knowing the pixel size.
    private func shellDocument() -> String {
        let background = TerminalHTMLDocument.css(backgroundColor)
        let cursor = TerminalHTMLDocument.css(cursorColor)
        let size = font.pointSize
        let stack = fontStack()

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
        :root {
            --cw: \(cellSize.width)px;
            --ch: \(cellSize.height)px;
        }
        html, body {
            margin: 0; padding: 0;
            background: \(background);
            overflow: hidden;
            cursor: text;
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
        <body><div id="screen"></div><div id="cursor"></div></body></html>
        """
    }
}

extension TerminalHTMLView: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // WebKit's navigation callbacks are framework-owned. AGENTS.md is
        // explicit that those are nonisolated until proven otherwise, so the
        // hop to the main actor is written out rather than assumed.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.isDocumentLoaded = true

                guard let pending = self.pendingFrame else {
                    return
                }
                self.pendingFrame = nil
                self.draw(pending)
            }
        }
    }
}
