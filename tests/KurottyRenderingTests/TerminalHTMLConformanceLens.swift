import Foundation
import KurottyCore
import WebKit
@testable import KurottyApp



/// What the HTML renderer produced, read back out of the live page.
///
/// Not the projector's return value: the projector only builds rows, and two of
/// the three bugs so far were in what the *view* does with the rest of the
/// frame. The observable is therefore the whole document — the stylesheet, the
/// custom properties on the root element, and everything in the body including
/// the cursor's inline style — so the check makes no assumption about how a
/// given input ought to be drawn. A renderer free to draw the cursor shape as a
/// class, a border, a background image or another element passes all four ways;
/// it fails only by drawing nothing.
///
/// It needs no window and no screen. A web view with no window never services
/// `requestAnimationFrame`, which is why the renderer's own presentation
/// watchdog exists and why this reads the document directly instead of waiting
/// to be told the frame was presented: scripts run in the order they are sent,
/// and the document is mutated before the script awaits a paint that is not
/// coming.
@MainActor
final class TerminalHTMLConformanceLens {
    enum Failure: Error, CustomStringConvertible {
        case noWebView
        case documentNeverLoaded
        case documentNeverAnswered

        var description: String {
            switch self {
            case .noWebView:
                return "the HTML renderer no longer holds a WKWebView, so there is nothing to read the document from"
            case .documentNeverLoaded:
                return "the HTML renderer never finished loading its document"
            case .documentNeverAnswered:
                return "the page never answered; the conformance check cannot run and must not be skipped"
            }
        }
    }

    private enum Limits {
        static let loadDeadlineSECONDS = 30.0
        static let readDeadlineSECONDS = 10.0
        static let pollIntervalSECONDS = 0.01
    }

    /// Everything the page shows, in one string. The separator is a character
    /// no document can contain, so two different documents cannot serialize the
    /// same way by having content spill across the boundary.
    private static let snapshotScript = """
    [document.documentElement.style.cssText,
     document.head.innerHTML,
     document.body.innerHTML].join('\\u0000')
    """

    private let view: TerminalHTMLView
    private let webView: WKWebView

    init(fontSizePT: Double = 12) throws {
        view = TerminalHTMLView(
            font: .monospacedSystemFont(ofSize: fontSizePT, weight: .regular),
            backgroundColor: TerminalConformanceFrame.Baseline.background,
            cursorColor: TerminalConformanceFrame.Baseline.foreground
        )

        // The web view is private to the renderer, and it stays private: a
        // testing hook on a file two other tracks are editing is a merge
        // conflict, and reading the document is a test's business rather than
        // the renderer's.
        guard let found = Mirror(reflecting: view).children.compactMap({ $0.value as? WKWebView }).first else {
            throw Failure.noWebView
        }
        webView = found
    }

    var renderer: any TerminalAppKitRenderer { view }

    /// Loads the document by drawing one frame and waiting for the renderer to
    /// report it presented. Every later frame is read directly.
    func load() throws {
        var presented = false
        view.onPresented = { presented = true }
        view.update(frame: TerminalConformanceFrame().frame())

        let deadline = Date().addingTimeInterval(Limits.loadDeadlineSECONDS)
        while !presented, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(Limits.pollIntervalSECONDS))
        }
        view.onPresented = nil

        guard presented else {
            throw Failure.documentNeverLoaded
        }
    }

    /// Draws the frames in order and returns the document that results.
    @discardableResult
    func observe(_ frames: [TerminalConformanceFrame]) throws -> String {
        for frame in frames {
            view.update(frame: frame.frame())
        }
        return try readDocument()
    }

    func observe(_ frame: TerminalConformanceFrame) throws -> String {
        try observe([frame])
    }

    private func readDocument() throws -> String {
        var document: String?
        var answered = false
        webView.evaluateJavaScript(Self.snapshotScript) { value, _ in
            document = value as? String
            answered = true
        }

        let deadline = Date().addingTimeInterval(Limits.readDeadlineSECONDS)
        while !answered, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(Limits.pollIntervalSECONDS))
        }

        guard let document else {
            throw Failure.documentNeverAnswered
        }
        return document
    }
}
