import Foundation
import KurottyCore

/// Color-scheme state reported to TUIs that subscribed with DEC private mode
/// 2031 (the Contour/Kitty "color scheme updates" protocol).
enum TerminalColorSchemeMode: String, Equatable, Sendable {
    case dark
    case light

    /// The terminal's own default background decides the reported scheme; the
    /// macOS system appearance is not the source of truth because Kurotty's
    /// theme can differ from it.
    init(isLightBackground: Bool) {
        self = isLightBackground ? .light : .dark
    }
}

/// Cell/grid geometry a capability reply needs. This mirrors the renderer's
/// single metrics path (`TerminalMetrics`); capability replies must never
/// measure the view themselves.
struct TerminalCapabilityMetrics: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let cellWidthPX: Double
    let cellHeightPX: Double

    init(columns: Int, rows: Int, cellWidthPX: Double, cellHeightPX: Double) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.cellWidthPX = max(1, cellWidthPX)
        self.cellHeightPX = max(1, cellHeightPX)
    }

    var textAreaWidthPX: Int {
        Int((cellWidthPX * Double(columns)).rounded())
    }

    var textAreaHeightPX: Int {
        Int((cellHeightPX * Double(rows)).rounded())
    }

    var roundedCellWidthPX: Int {
        max(1, Int(cellWidthPX.rounded()))
    }

    var roundedCellHeightPX: Int {
        max(1, Int(cellHeightPX.rounded()))
    }
}

/// A capability probe Kurotty recognises and answers on the PTY. Claude Code
/// and Codex send several of these at startup and block until they are
/// answered, so an unrecognised probe is a hang, not a cosmetic gap.
enum TerminalCapabilityQuery: Equatable, Sendable {
    /// `CSI 14 t` — text area size in pixels.
    case textAreaSizePixels
    /// `CSI 16 t` — character cell size in pixels.
    case cellSizePixels
    /// `CSI 18 t` — text area size in characters.
    case textAreaSizeCharacters
    /// `CSI ? 2031 $ p` — DECRQM report for the color-scheme update mode.
    case colorSchemeUpdateModeReport
}

enum TerminalCapabilityReplies {
    /// XTWINOPS request parameters (`CSI Ps t`).
    private enum WindowReportRequest {
        static let textAreaSizePixels = 14
        static let cellSizePixels = 16
        static let textAreaSizeCharacters = 18
    }

    /// XTWINOPS report parameters Kurotty answers with.
    private enum WindowReportResponse {
        static let textAreaSizePixels = 4
        static let cellSizePixels = 6
        static let textAreaSizeCharacters = 8
    }

    /// DEC private mode 2031: color-scheme update notifications.
    static let colorSchemeUpdateMode = 2031

    /// `CSI ? 997 ; Ps n` carries the color-scheme change notification.
    private enum ColorSchemeNotification {
        static let mode = 997
        static let darkParameter = 1
        static let lightParameter = 2
    }

    /// DECRPM state values (`CSI ? Ps ; Pm $ y`).
    private enum ModeReportState {
        static let set = 1
        static let reset = 2
    }

    private static let controlSequenceIntroducer = "\u{1b}["
    /// Intermediate byte that marks DECRQM (`$`) inside a CSI parameter buffer.
    private static let decrqmIntermediate: Character = "$"
    private static let decrqmFinal: Character = "p"
    private static let decrpmFinal = "$y"
    private static let windowReportFinal: Character = "t"
    private static let deviceStatusFinal: Character = "n"

    /// Classifies a fully parsed CSI sequence. `rawParameters` is the parameter
    /// buffer exactly as received, because `CsiParameters` intentionally drops
    /// the DECRQM `$` intermediate that distinguishes a mode *query* from any
    /// other CSI with final byte `p`.
    static func query(
        final: Character,
        rawParameters: String,
        parsed: CsiParameters
    ) -> TerminalCapabilityQuery? {
        switch final {
        case windowReportFinal:
            guard !parsed.isPrivate, parsed.values.count == 1 else { return nil }
            switch parsed.values[0] {
            case WindowReportRequest.textAreaSizePixels:
                return .textAreaSizePixels
            case WindowReportRequest.cellSizePixels:
                return .cellSizePixels
            case WindowReportRequest.textAreaSizeCharacters:
                return .textAreaSizeCharacters
            default:
                return nil
            }
        case decrqmFinal:
            guard rawParameters.last == decrqmIntermediate,
                  parsed.prefix == "?",
                  parsed.values.first == colorSchemeUpdateMode
            else {
                return nil
            }
            return .colorSchemeUpdateModeReport
        default:
            return nil
        }
    }

    /// The exact bytes for a recognised query, or `nil` when the geometry the
    /// answer depends on is not available yet.
    static func reply(
        for query: TerminalCapabilityQuery,
        metrics: TerminalCapabilityMetrics?,
        colorSchemeUpdateModeEnabled: Bool
    ) -> String? {
        switch query {
        case .textAreaSizePixels:
            guard let metrics else { return nil }
            return windowReport(
                parameter: WindowReportResponse.textAreaSizePixels,
                height: metrics.textAreaHeightPX,
                width: metrics.textAreaWidthPX
            )
        case .cellSizePixels:
            guard let metrics else { return nil }
            return windowReport(
                parameter: WindowReportResponse.cellSizePixels,
                height: metrics.roundedCellHeightPX,
                width: metrics.roundedCellWidthPX
            )
        case .textAreaSizeCharacters:
            guard let metrics else { return nil }
            return windowReport(
                parameter: WindowReportResponse.textAreaSizeCharacters,
                height: metrics.rows,
                width: metrics.columns
            )
        case .colorSchemeUpdateModeReport:
            let state = colorSchemeUpdateModeEnabled ? ModeReportState.set : ModeReportState.reset
            return "\(controlSequenceIntroducer)?\(colorSchemeUpdateMode);\(state)\(decrpmFinal)"
        }
    }

    /// `CSI ? 997 ; Ps n` — pushed to subscribed TUIs when the terminal's
    /// color scheme actually flips, so they can re-theme without restarting.
    static func colorSchemeNotification(_ mode: TerminalColorSchemeMode) -> String {
        let parameter = mode == .dark
            ? ColorSchemeNotification.darkParameter
            : ColorSchemeNotification.lightParameter
        return "\(controlSequenceIntroducer)?\(ColorSchemeNotification.mode);\(parameter)\(deviceStatusFinal)"
    }

    private static func windowReport(parameter: Int, height: Int, width: Int) -> String {
        "\(controlSequenceIntroducer)\(parameter);\(height);\(width)\(windowReportFinal)"
    }
}
