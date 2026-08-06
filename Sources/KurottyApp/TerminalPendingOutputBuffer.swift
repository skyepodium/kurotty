import Foundation

/// The PTY reader's undecoded byte buffer, bounded by construction.
///
/// Backed by `TmuxBoundedOutputHistory` rather than a third hand-rolled ring:
/// the tmux pane history already solves drop-oldest retention with chunked
/// storage, and its absolute offset pair is what makes a drop observable
/// instead of silent. `TerminalOutputBackpressurePolicy` should keep the buffer
/// far below `byteLimit`; the limit is the backstop for the case where it does
/// not, so that a wedged consumer costs a fixed amount of memory instead of all
/// of it.
///
/// Owns the UTF-8 boundary handling too, which used to be inline in the PTY
/// drain loop and therefore unreachable from a test.
struct TerminalPendingOutputBuffer {
    private var history: TmuxBoundedOutputHistory
    /// Absolute offset of the next byte to decode. Absolute rather than an
    /// index because the ring may drop bytes underneath it, and the gap between
    /// this and `history.startOffset` is precisely what was lost.
    private var decodeOffset: UInt64 = 0
    private(set) var droppedByteCount = 0

    init(byteLimit: Int) {
        history = TmuxBoundedOutputHistory(byteLimit: byteLimit)
    }

    var byteLimit: Int { history.byteLimit }

    var pendingByteCount: Int {
        Int(history.endOffset - max(decodeOffset, history.startOffset))
    }

    var isEmpty: Bool { pendingByteCount == 0 }

    mutating func append(_ data: Data) {
        history.append(data)
    }

    mutating func removeAll() {
        history.removeAll()
        decodeOffset = 0
    }

    /// Returns the longest prefix of the pending bytes that decodes as UTF-8,
    /// leaving a partial trailing scalar buffered for the next read.
    ///
    /// Returns nil when nothing can be decoded yet, which is the "we are
    /// mid-scalar and have too few bytes to tell" case.
    mutating func takeDecodedText() -> String? {
        let replay = history.replay(after: decodeOffset)
        if replay.requiresFullReplay {
            // The ring dropped bytes we had not decoded. Count them so the
            // corruption they cause downstream is attributable rather than
            // mysterious.
            droppedByteCount += Int(replay.startOffset - decodeOffset)
            decodeOffset = replay.startOffset
        }

        let pendingBytes = replay.data
        if let text = String(data: pendingBytes, encoding: .utf8) {
            consume(pendingBytes.count)
            return text
        }

        let count = pendingBytes.count
        guard count > AppConstants.Shell.maximumUTF8ScalarBytes else { return nil }
        for validCount in stride(
            from: count - 1,
            through: max(0, count - AppConstants.Shell.maximumUTF8ScalarBytes),
            by: -1
        ) {
            let prefix = pendingBytes.prefix(validCount)
            if let text = String(data: prefix, encoding: .utf8) {
                consume(validCount)
                return text
            }
        }
        // No valid boundary in the trailing scalar window: the stream itself is
        // malformed, so replace the bad bytes rather than stall the reader.
        let decodableCount = count - AppConstants.Shell.maximumUTF8ScalarBytes
        let text = String(decoding: pendingBytes.prefix(decodableCount), as: UTF8.self)
        consume(decodableCount)
        return text
    }

    private mutating func consume(_ count: Int) {
        decodeOffset += UInt64(count)
        // Release what has been decoded instead of letting the ring sit at its
        // limit forever: an idle pane should hold no PTY bytes at all.
        history.discard(before: decodeOffset)
    }
}
