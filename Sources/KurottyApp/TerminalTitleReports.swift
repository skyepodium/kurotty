import Foundation
import KurottyCore

/// The XTWINOPS title operations (`CSI Ps t`) Kurotty understands. Every other
/// sequence with final byte `t` is either a capability probe answered by
/// `TerminalCapabilityReplies` or a window-manipulation request Kurotty does not
/// honour at all.
enum TerminalTitleOperation: Equatable, Sendable {
    /// `CSI 20 t` — report the icon title, framed as `OSC L <title> ST`.
    case reportIconTitle
    /// `CSI 21 t` — report the window title, framed as `OSC l <title> ST`.
    case reportWindowTitle
    /// `CSI 22 ; Ps t` — push the current title onto the title stack.
    case pushTitle
    /// `CSI 23 ; Ps t` — pop the title stack back onto the current title.
    case popTitle
}

/// Parsing and framing for the XTWINOPS title operations, and the one place a
/// title is made safe to hand back to the child that wrote it.
///
/// The two reports are a security boundary rather than a feature gap. A program
/// can *set* the title with OSC 0/1/2, so a program that can also read it back
/// has a write-then-read primitive — and the read arrives on the shell's
/// standard input, not on its screen. A title carrying a newline is therefore a
/// line the shell runs, and a title carrying an escape byte is a sequence the
/// terminal executes inside its own reply. Two independent defences follow from
/// that: the reports answer nothing unless `terminal.titleReportsEnabled` is on
/// (see `TerminalOutputInterpreter.applyTitleOperation`), and every title that
/// is ever framed goes through `sanitized(_:)` here, on the way out, where no
/// caller can skip it.
enum TerminalTitleReports {
    /// XTWINOPS request parameters (`CSI Ps t`).
    private enum Request {
        static let reportIconTitle = 20
        static let reportWindowTitle = 21
        static let pushTitle = 22
        static let popTitle = 23
    }

    /// `Ps` of `CSI 22 ; Ps t` and `CSI 23 ; Ps t`: which title the stack
    /// operation addresses. Kurotty carries one title per surface — the icon
    /// title and the window title are the same string, because a pane has one
    /// name and draws it in one place — so all three values select the same
    /// entry on the same stack. They are still validated rather than ignored: a
    /// fourth value is not a title operation, and must fall through to whatever
    /// else `CSI Ps t` might mean.
    private enum StackTarget {
        static let bothTitles = 0
        static let iconTitle = 1
        static let windowTitle = 2
    }

    private static let operatingSystemCommand = "\u{1b}]"
    private static let stringTerminator = "\u{1b}\\"
    /// The OSC codes xterm reports the two titles under: lowercase `l` carries
    /// the window title, uppercase `L` the icon title.
    private static let windowTitleReportCode = "l"
    private static let iconTitleReportCode = "L"
    private static let windowOperationFinal: Character = "t"

    /// Classifies a parsed CSI sequence as a title operation, or `nil` when it
    /// is not one. Nothing here decides whether the operation may run; that is
    /// the interpreter's job, because only it knows the setting.
    static func operation(final: Character, parsed: CsiParameters) -> TerminalTitleOperation? {
        guard final == windowOperationFinal, !parsed.isPrivate else { return nil }
        guard let request = parsed.values.first else { return nil }
        switch request {
        case Request.reportIconTitle:
            guard parsed.values.count == 1 else { return nil }
            return .reportIconTitle
        case Request.reportWindowTitle:
            guard parsed.values.count == 1 else { return nil }
            return .reportWindowTitle
        case Request.pushTitle:
            guard hasKnownStackTarget(parsed) else { return nil }
            return .pushTitle
        case Request.popTitle:
            guard hasKnownStackTarget(parsed) else { return nil }
            return .popTitle
        default:
            return nil
        }
    }

    private static func hasKnownStackTarget(_ parsed: CsiParameters) -> Bool {
        switch parsed.values.count {
        case 1:
            // `Ps` omitted. xterm's default is 0, "both titles", which is the
            // only thing a single-title terminal can mean anyway.
            return true
        case 2:
            switch parsed.values[1] {
            case StackTarget.bothTitles, StackTarget.iconTitle, StackTarget.windowTitle:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    /// The exact bytes for a title report, or `nil` for the stack operations,
    /// which answer nothing. The title is sanitized here rather than by the
    /// caller so that framing an unsanitized one is not expressible.
    static func report(_ operation: TerminalTitleOperation, title: String) -> String? {
        let reportCode: String
        switch operation {
        case .reportWindowTitle:
            reportCode = windowTitleReportCode
        case .reportIconTitle:
            reportCode = iconTitleReportCode
        case .pushTitle, .popTitle:
            return nil
        }
        return operatingSystemCommand + reportCode + sanitized(title) + stringTerminator
    }

    /// Removes every control character from a title and caps what is left.
    ///
    /// The OSC parser accepts a title byte for byte, so `ESC ] 0 ; a<LF>b BEL`
    /// really does store a title with a newline in it. Reporting that title
    /// types the newline at the prompt. C0 and DEL go because of `\n` and `\r`;
    /// C1 goes because a single byte in that range is the same control as the
    /// two-byte `ESC`-prefixed form, and 0x9b would open a CSI inside Kurotty's
    /// own reply. The cap bounds what remains once every surviving byte is
    /// printable: a very long title is still a very long line on stdin.
    static func sanitized(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        var keptScalarCount = 0
        for scalar in title.unicodeScalars {
            guard !isControlScalar(scalar) else { continue }
            scalars.append(scalar)
            keptScalarCount += 1
            guard keptScalarCount < AppConstants.Terminal.maximumReportedTitleScalarCount else { break }
        }
        return String(scalars)
    }

    /// C0 (which contains the escape byte), DEL, and C1.
    private static func isControlScalar(_ scalar: UnicodeScalar) -> Bool {
        let firstC1Scalar: UInt32 = 0x80
        let lastC1Scalar: UInt32 = 0x9f
        let firstPrintableScalar: UInt32 = 0x20
        let deleteScalar: UInt32 = 0x7f
        if scalar.value < firstPrintableScalar || scalar.value == deleteScalar {
            return true
        }
        return scalar.value >= firstC1Scalar && scalar.value <= lastC1Scalar
    }
}
