import Foundation

/// Byte and pacing budgets for terminal pastes. These are protocol/runtime
/// budgets, not design tokens: they bound how much clipboard text may reach a
/// PTY at once and how far ahead of the PTY the writer may run.
struct TerminalPasteLimits: Equatable, Sendable {
    /// Payloads at or below this size are written in one call.
    let directMaxBytes: Int
    /// Maximum bytes per write once the payload exceeds `directMaxBytes`.
    let chunkMaxBytes: Int
    /// Payloads above this size are rejected instead of queued.
    let maxBytes: Int
    /// The writer pauses while the session still has at least this many bytes
    /// queued for the PTY, so a large paste cannot outrun the write path.
    let backpressureHighWaterMarkBytes: Int

    static let `default` = TerminalPasteLimits(
        directMaxBytes: 4 * 1_024,
        chunkMaxBytes: 16 * 1_024,
        maxBytes: 8 * 1_024 * 1_024,
        backpressureHighWaterMarkBytes: 64 * 1_024
    )
}

/// The decided shape of one paste. Pure data: it carries counts, modes, and a
/// redacted diagnostic, and never the pasted text itself.
struct TerminalPastePlan: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        /// One unbracketed write.
        case direct
        /// Several writes, paced against the PTY. `isBracketed` records whether
        /// the chunk stream is still wrapped in DEC 2004 markers.
        case chunked
        /// One write wrapped in DEC 2004 bracketed-paste markers.
        case bracketed
        /// Nothing is written.
        case rejected
    }

    enum NewlinePolicy: String, Equatable, Sendable {
        /// Line breaks stay line breaks. Used under bracketed paste, where the
        /// shell receives the payload as literal multi-line text rather than as
        /// a series of Return presses.
        case preserve
        /// Line breaks become carriage returns, matching what the Return key
        /// sends. Without bracketed paste this is what makes each pasted line
        /// behave like a typed line.
        case carriageReturn
    }

    enum RejectionReason: String, Equatable, Sendable {
        case empty
        case payloadTooLarge
    }

    let mode: Mode
    let newlinePolicy: NewlinePolicy
    let byteCount: Int
    let lineCount: Int
    /// Write budget in `.chunked` mode. In the single-write modes it simply
    /// echoes the payload size and no chunking happens.
    let chunkByteCount: Int
    let isBracketed: Bool
    let containsControlCharacters: Bool
    /// True when the payload spans more than one line or ends a line, so
    /// pasting it could execute something the user did not read.
    let isMultiline: Bool
    let requiresConfirmation: Bool
    let rejectionReason: RejectionReason?

    var isExecutable: Bool {
        mode != .rejected
    }

    /// Safe to log, show in diagnostics, and paste into a bug report: counts
    /// and modes only, never a byte of clipboard content.
    var redactedDiagnostic: String {
        [
            "mode=\(mode.rawValue)",
            "bracketed=\(isBracketed)",
            "newlines=\(newlinePolicy.rawValue)",
            "bytes=\(byteCount)",
            "lines=\(lineCount)",
            "chunkBytes=\(chunkByteCount)",
            "controls=\(containsControlCharacters)",
            "multiline=\(isMultiline)",
            "confirm=\(requiresConfirmation)",
            "rejected=\(rejectionReason?.rawValue ?? "none")",
        ].joined(separator: " ")
    }
}

enum TerminalPastePlanner {
    /// Decides how a clipboard payload reaches the PTY. Pure: no AppKit, no
    /// session, no clock.
    static func plan(
        text: String,
        bracketedPasteEnabled: Bool,
        confirmMultilinePaste: Bool,
        limits: TerminalPasteLimits = .default
    ) -> TerminalPastePlan {
        let newlinePolicy: TerminalPastePlan.NewlinePolicy = bracketedPasteEnabled
            ? .preserve
            : .carriageReturn
        let payload = TerminalPastePayload(text: text, newlinePolicy: newlinePolicy)

        guard !payload.isEmpty else {
            return rejected(
                reason: .empty,
                payload: payload,
                newlinePolicy: newlinePolicy,
                isBracketed: bracketedPasteEnabled
            )
        }
        guard payload.byteCount <= limits.maxBytes else {
            return rejected(
                reason: .payloadTooLarge,
                payload: payload,
                newlinePolicy: newlinePolicy,
                isBracketed: bracketedPasteEnabled
            )
        }

        let needsChunking = payload.byteCount > limits.directMaxBytes
        let mode: TerminalPastePlan.Mode
        if needsChunking {
            mode = .chunked
        } else {
            mode = bracketedPasteEnabled ? .bracketed : .direct
        }
        return TerminalPastePlan(
            mode: mode,
            newlinePolicy: newlinePolicy,
            byteCount: payload.byteCount,
            lineCount: payload.lineCount,
            chunkByteCount: needsChunking ? limits.chunkMaxBytes : payload.byteCount,
            isBracketed: bracketedPasteEnabled,
            containsControlCharacters: payload.containsControlCharacters,
            isMultiline: payload.isMultiline,
            requiresConfirmation: confirmMultilinePaste && payload.isMultiline,
            rejectionReason: nil
        )
    }

    /// The exact bytes a plan writes, split so no chunk ever ends mid-scalar.
    /// Returns an empty array for a rejected plan.
    static func chunks(for plan: TerminalPastePlan, text: String) -> [String] {
        guard plan.isExecutable else { return [] }
        let payload = TerminalPastePayload(text: text, newlinePolicy: plan.newlinePolicy)
        guard !payload.isEmpty else { return [] }
        let body = plan.isBracketed
            ? TerminalBracketedPaste.wrap(payload.normalizedText)
            : payload.normalizedText
        // `.direct` and `.bracketed` are single-write modes by definition, so
        // the bracket markers never push them into a second write.
        guard plan.mode == .chunked else { return [body] }
        return TerminalPasteChunker.chunks(of: body, maxChunkByteCount: plan.chunkByteCount)
    }

    private static func rejected(
        reason: TerminalPastePlan.RejectionReason,
        payload: TerminalPastePayload,
        newlinePolicy: TerminalPastePlan.NewlinePolicy,
        isBracketed: Bool
    ) -> TerminalPastePlan {
        TerminalPastePlan(
            mode: .rejected,
            newlinePolicy: newlinePolicy,
            byteCount: payload.byteCount,
            lineCount: payload.lineCount,
            chunkByteCount: 0,
            isBracketed: isBracketed,
            containsControlCharacters: payload.containsControlCharacters,
            isMultiline: payload.isMultiline,
            requiresConfirmation: false,
            rejectionReason: reason
        )
    }
}

/// Normalized clipboard text plus the counts a plan reports. Holding the text
/// here keeps the plan itself content-free.
struct TerminalPastePayload: Equatable {
    let normalizedText: String
    let byteCount: Int
    let lineCount: Int
    let isMultiline: Bool
    let containsControlCharacters: Bool

    init(text: String, newlinePolicy: TerminalPastePlan.NewlinePolicy) {
        // CRLF is normalized first so a Windows clipboard cannot double-submit
        // a line under either newline policy.
        let lineFeedNormalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lineBreakCount = lineFeedNormalized.filter { $0 == "\n" }.count
        isMultiline = lineBreakCount > 0
        lineCount = TerminalPastePayload.lineCount(of: lineFeedNormalized)
        containsControlCharacters = lineFeedNormalized.unicodeScalars.contains { scalar in
            TerminalPastePayload.isDisallowedControlScalar(scalar)
        }
        switch newlinePolicy {
        case .preserve:
            normalizedText = lineFeedNormalized
        case .carriageReturn:
            normalizedText = lineFeedNormalized.replacingOccurrences(of: "\n", with: "\r")
        }
        byteCount = normalizedText.utf8.count
    }

    var isEmpty: Bool {
        normalizedText.isEmpty
    }

    private static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        // A trailing newline ends the last line rather than starting a new one.
        if text.hasSuffix("\n") {
            lines -= 1
        }
        return max(1, lines)
    }

    /// C0 controls other than tab, and the escape byte. Line breaks are already
    /// normalized away by the time this runs.
    private static func isDisallowedControlScalar(_ scalar: UnicodeScalar) -> Bool {
        if scalar == "\t" || scalar == "\n" {
            return false
        }
        return scalar.value < 0x20 || scalar.value == 0x7f
    }
}

/// DEC 2004 bracketed paste markers.
enum TerminalBracketedPaste {
    static let startMarker = "\u{1b}[200~"
    static let endMarker = "\u{1b}[201~"

    /// Wraps a payload, stripping any end marker the clipboard already carried.
    /// Without that strip, clipboard content could close the bracket early and
    /// have its remainder executed by the shell.
    static func wrap(_ text: String) -> String {
        let sanitized = text
            .replacingOccurrences(of: endMarker, with: "")
            .replacingOccurrences(of: startMarker, with: "")
        return startMarker + sanitized + endMarker
    }
}

enum TerminalPasteChunker {
    /// Splits on Character boundaries under a byte budget, so a chunk can never
    /// end in the middle of a UTF-8 scalar or a grapheme cluster.
    static func chunks(of text: String, maxChunkByteCount: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let budget = max(1, maxChunkByteCount)
        guard text.utf8.count > budget else { return [text] }

        var chunks: [String] = []
        var current = ""
        var currentByteCount = 0
        for character in text {
            let characterByteCount = String(character).utf8.count
            if currentByteCount > 0, currentByteCount + characterByteCount > budget {
                chunks.append(current)
                current = ""
                currentByteCount = 0
            }
            current.append(character)
            currentByteCount += characterByteCount
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
