import AppKit
import KurottyCore
import WebKit

/// The web view the terminal document is drawn into, and the one place the
/// input boundary is decided.
///
/// **The rule: no `NSEvent` crosses into the web view. Not one.** Not a key
/// event, not a mouse event, not a scroll. Everything is delivered to
/// `TerminalSurfaceView`, which is the first responder for both renderers and
/// already owns keyboard, IME, scrolling, links, and the text selection.
///
/// It would be tempting to let mouse-down/drag/up through, because a selection
/// gesture is made of mouse events and the DOM would give a selection for free.
/// Two things say no. The first is `AGENTS.md`: marked text belongs to
/// `NSTextInputContext`, and the moment a web content process can become first
/// responder it can own the composition — that is the `d안녕` regression, and
/// hit-testing is far too weak a fence to bet it on, because `makeFirstResponder`
/// and the key-view loop never consult `hitTest`. The second is that the app
/// already *has* a selection: `TerminalSurfaceView.selectionAnchor` /
/// `selectionFocus`, which `Cmd+C`, the context menu, Select All and search all
/// read. A DOM selection would be a second one, drawn by a different engine over
/// the same pixels, disagreeing about wide glyphs, scrollback rows and trailing
/// blanks. One selection that is slightly less capable beats two that differ.
///
/// So the selection reaches this view the way every other pixel does — baked
/// into `TerminalFrame` by the surface as per-cell foreground and background —
/// and nothing here has to know what a selection is.
///
/// Refusing hit tests keeps the pointer flowing to the surface. Refusing first
/// responder *and* key-view membership keeps the two paths that bypass hit
/// testing from handing focus to the content process anyway. Dragging is a
/// third path, and none of those three cover it.
final class TerminalHTMLWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override var canBecomeKeyView: Bool {
        false
    }

    /// Drops belong to the surface, which turns a dropped file into a path on
    /// the command line.
    ///
    /// A web view registers seventeen dragged types of its own, because dropping
    /// a file onto a page is something pages do. Sitting on top of the surface,
    /// it therefore claimed every drop the terminal used to receive — and none
    /// of the rules above prevented it, because a drag destination is found by
    /// its registration rather than by hit testing or by focus.
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        // Ignored rather than unregistered afterwards: WebKit registers during
        // its own initialisation and re-registers when content loads, so undoing
        // it once would only hold until the next navigation.
    }
}

/// A terminal renderer that draws into a web view instead of a glyph atlas.
///
/// The alternative to `TerminalMetalView`, selected through
/// `TerminalRendererFactory`. Both implement `TerminalAppKitRenderer` and both
/// receive the same `TerminalFrame`, damage included, so nothing above this
/// layer knows which one is drawing.
///
/// **The web view displays; it never handles input.** The rule is stated once,
/// on `TerminalHTMLWebView`, and enforced there rather than event by event.
///
/// Rows are patched, not rebuilt. The frame already carries the damage the
/// surface computed, so an ordinary keystroke replaces one row's markup and
/// leaves the other twenty-three alone.
@MainActor
final class TerminalHTMLView: NSView, TerminalAppKitRenderer {
    private enum Script {
        /// One frame, in one call.
        ///
        /// Everything a frame changes travels together — cell metrics, padding,
        /// rows, cursor — because each `callAsyncJavaScript` is a round trip to
        /// the web content process, and three per frame is three times the
        /// crossing for no benefit.
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
        const screen = document.getElementById('\(TerminalHTMLDocument.Markup.screenID)');
        if (screen) {
            if (replacesScreen) {
                screen.innerHTML = screenMarkup;
            } else {
                // Scrolling moves rows; it does not change them. Recycling the
                // elements that scrolled off the near edge onto the far one turns
                // a screen-sized reparse into `shift` of them, and the rows that
                // survived keep their existing layout boxes.
                for (let moved = 0; moved < shift; moved++) {
                    screen.appendChild(screen.firstElementChild);
                }
                for (let moved = 0; moved > shift; moved--) {
                    screen.insertBefore(screen.lastElementChild, screen.firstElementChild);
                }

                // Rows are addressed by position rather than by id, because a
                // shift has just moved them and an id would now name the wrong
                // element. The row element stays and only its children change:
                // replacing a row's `outerHTML` discards a live element and its
                // layout box on every keystroke.
                const elements = screen.children;
                for (let index = 0; index < patchRows.length; index++) {
                    const row = elements[patchRows[index]];
                    if (row) { row.innerHTML = patchMarkup[index]; }
                }
            }
        }

        // Position, shape and visibility arrive as one declaration the projector
        // wrote, so the shape DECSCUSR selected is decided in the pure layer next
        // to everything else the frame decides.
        const cursor = document.getElementById('\(TerminalHTMLDocument.Markup.cursorID)');
        if (cursor) { cursor.style.cssText = cursorStyle; }

        await new Promise(resolve =>
            requestAnimationFrame(() => requestAnimationFrame(resolve))
        );
        """

        /// The cell box every run is sized against.
        ///
        /// Its own call rather than a field on the frame update, because these
        /// change on a resize or a font change and not on the frames in
        /// between. Sending them every frame would put two unrelated lifetimes
        /// in one message.
        static let setMetrics = """
        const root = document.documentElement.style;
        root.setProperty('\(TerminalHTMLDocument.Variable.cellWidth)', width + 'px');
        root.setProperty('\(TerminalHTMLDocument.Variable.cellHeight)', height + 'px');
        root.setProperty('\(TerminalHTMLDocument.Variable.paddingX)', paddingX + 'px');
        root.setProperty('\(TerminalHTMLDocument.Variable.paddingY)', paddingY + 'px');
        root.setProperty('\(TerminalHTMLDocument.Variable.cursorBarWidth)', cursorBar);
        root.setProperty('\(TerminalHTMLDocument.Variable.cursorUnderlineHeight)', cursorUnderline);
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
        /// Assumed when the view has no window and no screen to ask. Retina is
        /// the overwhelmingly likely answer on the Macs Kurotty runs on, and it
        /// is the same assumption `TerminalMetalView` makes.
        static let fallbackBackingSCALE: CGFloat = 2
    }

    private let webView: TerminalHTMLWebView
    private var isDocumentLoaded = false
    private var pendingFrame: TerminalFrame?
    /// The inner markup the page is currently showing, row by row. The diff is
    /// taken against this rather than against the frame's damage: damage says
    /// what *might* have changed, and a blink tick says the whole screen did.
    private var renderedRows: [String] = []
    /// The cursor declaration the page is currently showing, so a frame that
    /// changes nothing else can still be recognised as changing the cursor.
    private var renderedCursor = ""
    private var font: NSFont
    private var backgroundColor: SIMD4<Float>
    private var cursorColor: SIMD4<Float>
    private var cellSize = TerminalFrameSize(width: 8, height: 16)
    /// Where row 0, column 0 begins, in the surface's coordinates.
    ///
    /// The renderer is not free to pick this. `TerminalSurfaceView` resolves a
    /// click to a cell by subtracting the very padding it puts in the frame, so
    /// drawing the grid anywhere else makes the pointer and the glyphs disagree
    /// by exactly that much — and a selection drag then covers the wrong cells.
    private var padding = TerminalFramePoint.zero
    /// The document is loaded with placeholder cell metrics, so the first frame
    /// must publish real ones even when they happen to match the placeholder.
    private var hasPublishedMetrics = false
    private var presentationWatchdog: DispatchWorkItem?
    private var isAwaitingPresentation = false
    /// The density the page's cursor thicknesses were resolved against. They
    /// are stated in device pixels, so a view moved to a display of a different
    /// density has to be told them again — which the next frame does, rather
    /// than a document reload that would blank every row until something draws.
    private var publishedBackingScale: CGFloat = 0

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

        webView = TerminalHTMLWebView(frame: .zero, configuration: configuration)

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

    /// The same rule as `TerminalHTMLWebView`, applied to the container.
    ///
    /// Both are needed and neither is redundant. The container has to be
    /// transparent or the pointer stops here instead of reaching
    /// `TerminalSurfaceView`, which is what makes the selection gesture work at
    /// all; the web view has to refuse independently because a subview can be
    /// focused without ever being hit-tested.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override var canBecomeKeyView: Bool {
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
        publishMetricsIfChanged(cell: frame.cellSize, padding: frame.padding)

        // One index of the frame, shared by every row. Building it per row made
        // patching a screen quadratic: 97.5ms against 5.2ms on a 55x200 screen.
        var screen = TerminalHTMLDocument.Screen(frame: frame)
        let rows = screen.contents()
        let plan = TerminalHTMLRowDiff.plan(from: renderedRows, to: rows)
        let cursor = TerminalHTMLDocument.cursorDeclaration(frame: frame)

        // Nothing visible changed. The frame still has to report itself
        // presented, or the latency metric waits forever for a paint that is not
        // coming.
        guard !plan.isEmpty || cursor != renderedCursor else {
            reportPresented()
            return
        }

        renderedRows = rows
        renderedCursor = cursor
        armPresentationWatchdog()

        run(Script.applyFrame, arguments: [
            "replacesScreen": plan.replacesScreen,
            "screenMarkup": plan.replacesScreen
                ? TerminalHTMLDocument.document(rowContents: rows) : "",
            "shift": plan.shift,
            "patchRows": plan.rows,
            "patchMarkup": plan.rows.map { rows[$0] },
            "cursorStyle": cursor,
        ])
    }

    /// Publishes the cell box every run is sized against, and the origin the
    /// grid is drawn from.
    ///
    /// The document loads before any frame arrives, so these start as
    /// placeholders. Runs were clipped mid-glyph until the cell box was sent;
    /// the padding is the same class of error one level out — `TerminalSurfaceView`
    /// maps a click to a cell by subtracting the padding it put in the frame,
    /// so a grid drawn at the page origin puts every glyph a padding away from
    /// the cell the pointer resolves to.
    private func publishMetricsIfChanged(cell: TerminalFrameSize, padding: TerminalFramePoint) {
        let scale = backingScale

        guard cellSize != cell
            || self.padding != padding
            || publishedBackingScale != scale
            || !hasPublishedMetrics
        else {
            return
        }

        cellSize = cell
        self.padding = padding
        publishedBackingScale = scale
        hasPublishedMetrics = true

        run(Script.setMetrics, arguments: [
            "width": Double(cell.width),
            "height": Double(cell.height),
            "paddingX": Double(padding.x),
            "paddingY": Double(padding.y),
            "cursorBar": cssLength(devicePixels: AppConstants.Terminal.cursorWidthPX),
            "cursorUnderline": cssLength(devicePixels: AppConstants.Terminal.cursorUnderlineHeightPX),
        ])
    }

    /// The screen the view is on, or the best guess available before it has one.
    private var backingScale: CGFloat {
        window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? Metrics.fallbackBackingSCALE
    }

    /// A device-pixel count as the CSS length that draws exactly that many
    /// pixels on this screen. CSS lengths are points, so the cursor's rules
    /// would come out twice as thick as Metal's on a Retina display if the
    /// density were ignored.
    private func cssLength(devicePixels: Float) -> String {
        "\(Double(devicePixels) / Double(max(backingScale, 1)))px"
    }

    /// The metrics script, so a test can hold it to the variables it must
    /// publish without standing up a web content process.
    static var metricsScriptForTesting: String {
        Script.setMetrics
    }

    /// Reports a frame presented exactly once, cancelling anything still
    /// waiting to report it.
    private func reportPresented() {
        presentationWatchdog?.cancel()
        presentationWatchdog = nil

        guard isAwaitingPresentation else {
            return
        }

        isAwaitingPresentation = false
        onPresented?()
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

                    // The page no longer matches what the diff believes it
                    // shows, and every later frame would be patched against a
                    // fiction. Forgetting it makes the next frame rebuild the
                    // screen outright.
                    self.renderedRows = []
                    self.renderedCursor = ""
                }

                // Reported on failure too. A frame that never reports leaves
                // the latency metric waiting on a paint that will not arrive.
                self.reportPresented()
            }
        }
    }

    private func loadShell() {
        isDocumentLoaded = false
        hasPublishedMetrics = false
        renderedCursor = ""
        publishedBackingScale = 0
        renderedRows = []
        webView.loadHTMLString(
            TerminalHTMLStylesheet.document(
                font: font,
                backgroundColor: backgroundColor,
                cursorColor: cursorColor,
                cellSize: cellSize,
                padding: padding
            ),
            baseURL: nil
        )
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
