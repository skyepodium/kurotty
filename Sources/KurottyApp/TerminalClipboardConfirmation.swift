import Foundation

/// An OSC 52 clipboard request the security policy answered with `ask`, carried
/// from the moment it arrives to the moment the user can actually answer it.
///
/// The decoded text travels with the request because the answer is what applies
/// it; it is never logged, never put in a diagnostic string, and never shown in
/// the confirmation sheet.
struct TerminalClipboardConfirmationRequest: Equatable {
    let operation: TerminalOSC52Policy.Operation
    /// The OSC 52 selection field (`c`, `p`, …) the program addressed.
    let selection: String
    let byteCount: Int
    let text: String
}

/// Decides *when* an OSC 52 confirmation may be put in front of the user.
///
/// A pane that is not the one the user is looking at must not open a modal
/// sheet: with several agent panes running, a background clipboard write would
/// steal focus from whatever the user is actually doing. The request is held
/// instead and presented when the pane comes back to the front.
///
/// **Coalescing rule: at most one request is ever pending, and a newer request
/// replaces the older one.** Two reasons. The pasteboard holds a single value,
/// so approving a superseded write would leave stale text on it while the
/// program that sent the *last* write believes that one won. And the whole
/// point of holding the sheet back is that the user should not return to a
/// stack of them; presenting the first and dropping the rest would answer a
/// request the program has already moved past. The number of requests dropped
/// this way is counted so the presentation layer can say so if it wants to.
///
/// The queue also refuses to present a second sheet while one is up, for the
/// same "no stack of sheets" reason, and drains on `didFinishPresenting`.
///
/// Focus is not decided here: callers pass the same predicate the rest of the
/// surface uses (`TerminalCursorPresentationPolicy.isFocusedForUser`), so there
/// is exactly one definition of "the user is looking at this pane".
struct TerminalClipboardConfirmationQueue {
    enum Submission: Equatable {
        case present(TerminalClipboardConfirmationRequest)
        /// Held back. `supersededRequestCount` is how many earlier requests the
        /// coalescing rule has discarded since the last presentation.
        case deferred(supersededRequestCount: Int)
    }

    private(set) var pendingRequest: TerminalClipboardConfirmationRequest?
    private(set) var isPresenting = false
    private(set) var supersededRequestCount = 0

    var hasPendingRequest: Bool { pendingRequest != nil }

    mutating func submit(
        _ request: TerminalClipboardConfirmationRequest,
        isFocused: Bool
    ) -> Submission {
        guard isFocused, !isPresenting else {
            if pendingRequest != nil {
                supersededRequestCount += 1
            }
            pendingRequest = request
            return .deferred(supersededRequestCount: supersededRequestCount)
        }
        isPresenting = true
        return .present(request)
    }

    /// The pane's focus state changed. Returns the request to present now, if
    /// focus has just come back to a pane that was holding one.
    mutating func focusDidChange(isFocused: Bool) -> TerminalClipboardConfirmationRequest? {
        guard isFocused, !isPresenting, let request = pendingRequest else { return nil }
        pendingRequest = nil
        supersededRequestCount = 0
        isPresenting = true
        return request
    }

    /// The sheet closed. Returns whatever arrived while it was up, if the pane
    /// is still in front of the user.
    mutating func didFinishPresenting(isFocused: Bool) -> TerminalClipboardConfirmationRequest? {
        isPresenting = false
        return focusDidChange(isFocused: isFocused)
    }

    /// Pane, window, or session teardown. A held request must not outlive the
    /// session that produced it: the program that asked is gone, and answering
    /// it later would write to the pasteboard on behalf of nothing.
    mutating func cancelPending() {
        pendingRequest = nil
        supersededRequestCount = 0
        isPresenting = false
    }
}

extension TerminalClipboardConfirmationRequest {
    /// Builds the request an `ask` evaluation stands for, or `nil` when the
    /// payload carries nothing that could be put on the pasteboard.
    init?(evaluation: TerminalOSC52Policy.Evaluation, base64Payload: String) {
        guard evaluation.decision == .ask, evaluation.operation == .write else { return nil }
        guard let text = TerminalOSC52Policy.decodedText(fromBase64Payload: base64Payload),
              !text.isEmpty
        else { return nil }
        self.init(
            operation: evaluation.operation,
            selection: evaluation.metadata.selection,
            byteCount: evaluation.metadata.byteCount ?? text.utf8.count,
            text: text
        )
    }
}
