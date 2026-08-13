/// How the cursor cell is drawn, and whether the drawing follows the blink
/// phase. This is the state DECSCUSR (`CSI Ps SP q`) owns: `vim`, `neovim`,
/// `fish` and `zsh`'s vi mode all switch it on every mode change, so it is a
/// per-terminal value that outlives any single frame.
public struct TerminalCursorStyle: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        /// Fills the cursor cell.
        case block
        /// A rule along the bottom edge of the cursor cell.
        case underline
        /// A rule along the leading edge of the cursor cell.
        case bar
    }

    /// Kurotty's power-on cursor: a blinking bar, which is what the renderer
    /// drew before DECSCUSR existed. A full reset and DECSCUSR `0` return here.
    public static let `default` = TerminalCursorStyle(shape: .bar, blinks: true)

    public let shape: Shape
    public let blinks: Bool

    public init(shape: Shape, blinks: Bool) {
        self.shape = shape
        self.blinks = blinks
    }

    /// The DECSCUSR parameter that selects this style. `0` is deliberately not
    /// produced: it names "the terminal's default" rather than a shape, so a
    /// style always round-trips through the parameter that states it outright.
    public var decscusrParameter: Int {
        switch (shape, blinks) {
        case (.block, true):
            return DecscusrParameter.blinkingBlock
        case (.block, false):
            return DecscusrParameter.steadyBlock
        case (.underline, true):
            return DecscusrParameter.blinkingUnderline
        case (.underline, false):
            return DecscusrParameter.steadyUnderline
        case (.bar, true):
            return DecscusrParameter.blinkingBar
        case (.bar, false):
            return DecscusrParameter.steadyBar
        }
    }

    /// DECSCUSR parameter values (`CSI Ps SP q`).
    public enum DecscusrParameter {
        /// Ghostty and kitty both read `0` as "whatever this terminal's
        /// configured default is" rather than as a shape of its own; xterm's
        /// table writes it as "blinking block (default)" only because a
        /// blinking block is *its* default. Kurotty follows the former, so a
        /// program that resets the cursor gets Kurotty's cursor back.
        public static let `default` = 0
        public static let blinkingBlock = 1
        public static let steadyBlock = 2
        public static let blinkingUnderline = 3
        public static let steadyUnderline = 4
        public static let blinkingBar = 5
        public static let steadyBar = 6
    }

    /// The style a DECSCUSR parameter selects, or `nil` for a parameter the
    /// sequence does not define. `nil` means *ignore*: xterm, ghostty and kitty
    /// all leave the cursor untouched for an out-of-range `Ps` rather than
    /// clamping it to the nearest shape.
    public static func decscusr(parameter: Int) -> TerminalCursorStyle? {
        switch parameter {
        case DecscusrParameter.default:
            return .default
        case DecscusrParameter.blinkingBlock:
            return TerminalCursorStyle(shape: .block, blinks: true)
        case DecscusrParameter.steadyBlock:
            return TerminalCursorStyle(shape: .block, blinks: false)
        case DecscusrParameter.blinkingUnderline:
            return TerminalCursorStyle(shape: .underline, blinks: true)
        case DecscusrParameter.steadyUnderline:
            return TerminalCursorStyle(shape: .underline, blinks: false)
        case DecscusrParameter.blinkingBar:
            return TerminalCursorStyle(shape: .bar, blinks: true)
        case DecscusrParameter.steadyBar:
            return TerminalCursorStyle(shape: .bar, blinks: false)
        default:
            return nil
        }
    }

    /// Classifies a parsed CSI sequence whose final byte is `q`.
    ///
    /// `rawParameters` is the parameter buffer exactly as received, because the
    /// space intermediate is what separates DECSCUSR from the other sequences
    /// that end in `q` — DECSCA is `CSI Ps " q` and XTVERSION is `CSI > q`, and
    /// `CsiParameters` drops both the intermediate and the private prefix.
    /// `TerminalCapabilityReplies` reads DECRQM's `$` the same way.
    public static func decscusr(
        rawParameters: String,
        parsed: CsiParameters
    ) -> TerminalCursorStyle? {
        guard rawParameters.last == decscusrIntermediate,
              !parsed.isPrivate,
              parsed.values.count == 1,
              let parameter = parsed.values.first
        else {
            return nil
        }
        return decscusr(parameter: parameter)
    }

    private static let decscusrIntermediate: Character = " "
}
