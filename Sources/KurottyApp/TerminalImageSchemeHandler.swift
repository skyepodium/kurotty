import Foundation
import WebKit

/// Serves the terminal's inline images to the page, from the store that holds
/// them once.
///
/// **Why a scheme rather than a data URL.** An image's bytes have to reach the
/// page somehow, and a `data:` URL puts them in the markup — so every frame
/// that repositions the picture, which is every frame while scrolling, would
/// carry the whole file across the bridge again. A URL is a few bytes and the
/// page fetches the file once, exactly as a browser does with an ordinary image.
///
/// The scheme is custom because there is no server. Nothing here reaches the
/// network, opens a file, or resolves anything outside the store: a request for
/// an identifier the store does not hold fails, and that is the only shape a
/// request can take.
final class TerminalImageSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The URL scheme the page uses to ask for an image.
    ///
    /// Registered on the web view's configuration, which is why it must not
    /// collide with a scheme WebKit already handles — a custom scheme cannot be
    /// `http`, `file`, or anything else the engine claims.
    static let scheme = "kurotty-image"

    /// Answers with the bytes for an identifier, or nil when the store has
    /// dropped them.
    ///
    /// A closure rather than a store reference so the handler owns nothing and
    /// can be pointed at whatever holds the images — the renderer is created by
    /// a factory that has no business knowing about a terminal session.
    var provider: ((Int) -> TerminalImageStore.Entry?)?

    private enum Response {
        /// Sent for every image, whatever its bytes actually are.
        ///
        /// The terminal receives files from arbitrary programs, so the type is
        /// not taken from the sender's claim about them. WebKit sniffs the
        /// content itself, and a generic type is what lets it — a wrong
        /// specific type would be believed instead.
        static let mimeTYPE = "application/octet-stream"
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let identifier = Self.identifier(in: task.request.url),
              let entry = provider?(identifier)
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = URLResponse(
            url: task.request.url ?? URL(fileURLWithPath: "/"),
            mimeType: Response.mimeTYPE,
            expectedContentLength: entry.data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(entry.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Nothing to cancel: the response is delivered synchronously from
        // memory, so a stop always arrives after the task has already finished.
    }

    /// The URL a frame's image identifier is fetched from.
    static func url(for identifier: Int) -> String {
        "\(scheme)://image/\(identifier)"
    }

    /// The identifier in a request, or nil when the URL is not one this handler
    /// wrote.
    static func identifier(in url: URL?) -> Int? {
        guard let url, url.scheme == scheme else {
            return nil
        }
        return Int(url.lastPathComponent)
    }
}
