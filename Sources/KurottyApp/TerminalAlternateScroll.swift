import Foundation

/// DEC private mode 1007: alternate scroll.
///
/// On the alternate screen there is no scrollback to move, so a wheel gesture
/// that is not claimed by mouse reporting would otherwise do nothing at all in
/// `less`, `man`, or `git log`. This translates the wheel into the cursor keys
/// those pagers already bind to line movement.
///
/// The row quantization is not repeated here: the caller feeds the row delta
/// that `TerminalScrollWheelAccumulator` already produced, so trackpad and
/// discrete wheels behave identically to normal-screen scrolling.
enum TerminalAlternateScroll {
    struct Context: Equatable {
        let isAlternateScreenActive: Bool
        let isAlternateScrollEnabled: Bool
        let isMouseReportingEnabled: Bool
        let applicationCursorKeysEnabled: Bool
        /// Shift is the app-wide "give me the terminal's own behavior" escape,
        /// the same one that bypasses mouse reporting.
        let isShiftHeld: Bool

        init(
            isAlternateScreenActive: Bool,
            isAlternateScrollEnabled: Bool,
            isMouseReportingEnabled: Bool,
            applicationCursorKeysEnabled: Bool,
            isShiftHeld: Bool = false
        ) {
            self.isAlternateScreenActive = isAlternateScreenActive
            self.isAlternateScrollEnabled = isAlternateScrollEnabled
            self.isMouseReportingEnabled = isMouseReportingEnabled
            self.applicationCursorKeysEnabled = applicationCursorKeysEnabled
            self.isShiftHeld = isShiftHeld
        }
    }

    /// True when the wheel belongs to alternate scroll and must not fall through
    /// to Kurotty's own scrollback, even for a zero-row gesture.
    static func claimsWheel(in context: Context) -> Bool {
        context.isAlternateScreenActive
            && context.isAlternateScrollEnabled
            && !context.isMouseReportingEnabled
            && !context.isShiftHeld
    }

    /// The cursor-key run for `rowDelta`, matching the row sign convention of
    /// the scroll accumulator: positive scrolls back toward earlier lines.
    static func keySequence(rowDelta: Int, context: Context) -> String? {
        guard claimsWheel(in: context), rowDelta != 0 else { return nil }
        let key: String
        if context.applicationCursorKeysEnabled {
            key = rowDelta > 0 ? "\u{1b}OA" : "\u{1b}OB"
        } else {
            key = rowDelta > 0 ? "\u{1b}[A" : "\u{1b}[B"
        }
        return String(repeating: key, count: abs(rowDelta))
    }
}
