import Foundation
import KurottyCore

/// Reconstructs the command line the user typed by echoing the bytes Kurotty
/// writes to the PTY.
///
/// This exists because `OSC 133;C` carries no command text, so the only local
/// evidence of *what* ran is the keystroke stream. That stream is not plain
/// text: it carries CSI sequences for arrow keys, SS3 for application-cursor
/// mode, bracketed-paste guards, and OSC replies. Appending every "printable"
/// byte therefore recorded the literal escape payloads, which is why history
/// showed entries like `[A`, `OA`, `cd fOA`, `ssOAOBh-real`, and
/// `[200~curl …[201~`.
///
/// So this type runs the same ground/escape/CSI/SS3/OSC state machine the
/// output interpreter uses, and only ground-state printables reach the buffer.
///
/// It is a deliberately dumb echo: it cannot see text the shell produced on the
/// user's behalf (history recall, tab completion, `Ctrl-R`). Those still record
/// whatever the user physically typed. The authoritative fix is to have the
/// shell integration report `$1` from `preexec`; this type is the fallback for
/// sessions without that, and the guard that keeps the fallback from emitting
/// garbage.
struct TerminalSubmittedCommandRecorder {
    private enum State: Equatable {
        case ground
        /// Saw ESC; the next byte selects the sequence family.
        case escape
        /// Consuming CSI parameter/intermediate bytes until a final byte.
        case csi
        /// SS3 takes exactly one byte (`ESC O A` = up arrow).
        case ss3
        /// OSC runs until BEL or ST.
        case osc
        /// DCS/SOS/PM/APC run until ST.
        case string
    }

    private var state: State = .ground
    /// CSI parameter bytes accumulated for the current sequence, used only to
    /// recognise the bracketed-paste guards `CSI 200 ~` and `CSI 201 ~`.
    private var csiParameters = ""
    /// Inside a bracketed paste, newlines are literal content: the shell buffers
    /// the paste and waits for a real Enter, so treating them as submissions
    /// would split one pasted command into several bogus entries.
    private var isInBracketedPaste = false
    private var pendingText = ""
    private let maximumCharacters: Int

    init(maximumCharacters: Int = AppConstants.Notifications.commandInputCaptureMaxCharacters) {
        self.maximumCharacters = maximumCharacters
    }

    /// The command line as reconstructed so far, before submission.
    var pendingCommandText: String { pendingText }

    /// Feeds bytes headed for the PTY and returns the command bodies whose
    /// Enter arrived in this chunk, in order. Empty means nothing was submitted.
    mutating func consume(_ text: String) -> [String] {
        var submitted: [String] = []
        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            switch state {
            case .ground:
                if let body = consumeGround(character, scalar: scalar) {
                    submitted.append(body)
                }
            case .escape:
                consumeEscapeIntroducer(scalar)
            case .csi:
                consumeCSI(scalar)
            case .ss3:
                state = .ground
            case .osc, .string:
                consumeStringTerminator(scalar)
            }
        }
        return submitted
    }

    /// Drops the in-progress line. Callers use this when the pane's line editor
    /// is no longer the thing receiving keystrokes.
    mutating func reset() {
        state = .ground
        csiParameters = ""
        isInBracketedPaste = false
        pendingText.removeAll(keepingCapacity: true)
    }

    // MARK: - Ground state

    /// Returns the submitted body when this character ended a command.
    private mutating func consumeGround(_ character: Character, scalar: UnicodeScalar) -> String? {
        switch scalar.value {
        case 0x1b:
            state = .escape
            return nil
        case 0x0a, 0x0d:
            // Only a real Enter submits. Inside a bracketed paste the shell is
            // still collecting, so the newline is content.
            guard !isInBracketedPaste else {
                pendingText.append("\n")
                trimToMaximum()
                return nil
            }
            return takeSubmittedBody()
        case 0x7f, 0x08:
            if !pendingText.isEmpty { pendingText.removeLast() }
            return nil
        case 0x15:
            // Ctrl-U kills the line.
            pendingText.removeAll(keepingCapacity: true)
            return nil
        case 0x03:
            // Ctrl-C abandons the line. Without this the discarded text merges
            // into whatever the user types next.
            pendingText.removeAll(keepingCapacity: true)
            return nil
        case 0x17:
            deleteTrailingWord()
            return nil
        default:
            guard character.isTerminalPrintableGrapheme else { return nil }
            pendingText.append(character)
            trimToMaximum()
            return nil
        }
    }

    private mutating func takeSubmittedBody() -> String? {
        defer { pendingText.removeAll(keepingCapacity: true) }
        return TerminalSubmittedCommandSummary.notificationBody(from: pendingText)
    }

    private mutating func deleteTrailingWord() {
        while let last = pendingText.last, last.isWhitespace {
            pendingText.removeLast()
        }
        while let last = pendingText.last, !last.isWhitespace {
            pendingText.removeLast()
        }
    }

    private mutating func trimToMaximum() {
        guard pendingText.count > maximumCharacters else { return }
        let start = pendingText.index(pendingText.endIndex, offsetBy: -maximumCharacters)
        pendingText = String(pendingText[start...])
    }

    // MARK: - Escape states

    private mutating func consumeEscapeIntroducer(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x5b: // [
            csiParameters = ""
            state = .csi
        case 0x4f: // O
            state = .ss3
        case 0x5d: // ]
            state = .osc
        case 0x50, 0x58, 0x5e, 0x5f: // P (DCS), X (SOS), ^ (PM), _ (APC)
            state = .string
        default:
            // Two-byte escapes (`ESC 7`, `ESC =`, Alt-<key>) end here, and the
            // introducer byte must not reach the buffer.
            state = .ground
        }
    }

    private mutating func consumeCSI(_ scalar: UnicodeScalar) {
        // Final bytes are 0x40...0x7e; everything before is parameter or
        // intermediate and belongs to the sequence, not the command.
        guard (0x40...0x7e).contains(scalar.value) else {
            csiParameters.unicodeScalars.append(scalar)
            return
        }
        if scalar.value == 0x7e { // ~
            switch csiParameters {
            case "200": isInBracketedPaste = true
            case "201": isInBracketedPaste = false
            default: break
            }
        }
        csiParameters = ""
        state = .ground
    }

    private mutating func consumeStringTerminator(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x07: // BEL
            state = .ground
        case 0x1b: // ESC of a two-byte ST; the trailing `\` lands in ground and
            // is dropped by the escape introducer default.
            state = .escape
        default:
            break
        }
    }
}
