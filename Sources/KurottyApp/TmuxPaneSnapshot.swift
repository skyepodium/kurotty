import Foundation

/// The terminal modes and cursor state tmux keeps for a pane but does not
/// include in `capture-pane` output.
struct TmuxPaneTerminalState: Equatable, Sendable {
    var paneID = ""
    var width = 80
    var height = 24
    var alternateOn = false
    var alternateSavedX: Int?
    var alternateSavedY: Int?
    var cursorX = 0
    var cursorY = 0
    var scrollRegionUpper = 0
    var scrollRegionLower = 23
    var tabStops = stride(from: 8, through: 992, by: 8).map { $0 }
    var cursorVisible = true
    var insertMode = false
    var originMode = false
    var applicationCursorKeys = false
    var applicationKeypad = false
    var wraparound = true
    var mouseStandard = false
    var mouseButton = false
    var mouseAny = false
    var mouseUTF8 = false
    var mouseSGR = false
    var bracketedPaste = false
    var paneKeyMode = ""
    var extendedKeyFormat: TerminalExtendedKeyFormat = .xterm
    var attachedClientCount = 1

    static func parse(_ response: String, expectedPaneID: String) -> Self? {
        var fields: [String: String] = [:]
        let components: [Substring]
        if response.contains("\t") {
            components = response.split(separator: "\t", omittingEmptySubsequences: false)
        } else {
            // tmux 1.8 had a format bug which returned a literal `\t`. Keeping
            // this fallback costs nothing and makes reconnects to old servers safe.
            components = response.components(separatedBy: "\\t").map { Substring($0) }
        }
        for component in components {
            guard let equals = component.firstIndex(of: "=") else { continue }
            let key = String(component[..<equals])
            let value = String(component[component.index(after: equals)...])
            guard !key.isEmpty else { continue }
            fields[key] = value
        }

        guard fields["pane_id"] == expectedPaneID else { return nil }
        var state = Self()
        state.paneID = expectedPaneID
        state.width = positiveInt(fields["pane_width"], fallback: state.width)
        state.height = positiveInt(fields["pane_height"], fallback: state.height)
        state.alternateOn = bool(fields["alternate_on"])
        state.alternateSavedX = savedCursorCoordinate(fields["alternate_saved_x"])
        state.alternateSavedY = savedCursorCoordinate(fields["alternate_saved_y"])
        state.cursorX = nonnegativeInt(fields["cursor_x"])
        state.cursorY = nonnegativeInt(fields["cursor_y"])
        state.scrollRegionUpper = nonnegativeInt(fields["scroll_region_upper"])
        state.scrollRegionLower = nonnegativeInt(
            fields["scroll_region_lower"],
            fallback: max(0, state.height - 1)
        )
        if let tabs = fields["pane_tabs"] {
            state.tabStops = tabs.split(separator: ",").compactMap { Int($0) }.filter { $0 >= 0 }
        }
        state.cursorVisible = bool(fields["cursor_flag"], fallback: true)
        state.insertMode = bool(fields["insert_flag"])
        state.originMode = bool(fields["origin_flag"])
        state.applicationCursorKeys = bool(fields["keypad_cursor_flag"])
        state.applicationKeypad = bool(fields["keypad_flag"])
        state.wraparound = bool(fields["wrap_flag"], fallback: true)
        state.mouseStandard = bool(fields["mouse_standard_flag"])
        state.mouseButton = bool(fields["mouse_button_flag"])
        state.mouseAny = bool(fields["mouse_any_flag"])
        state.mouseUTF8 = bool(fields["mouse_utf8_flag"])
        state.mouseSGR = bool(fields["mouse_sgr_flag"])
        state.bracketedPaste = bool(fields["bracket_paste_flag"])
        state.paneKeyMode = fields["pane_key_mode"] ?? ""
        state.extendedKeyFormat = TerminalExtendedKeyFormat(
            rawValue: fields["extended_keys_format"] ?? ""
        ) ?? .xterm
        state.attachedClientCount = positiveInt(fields["session_attached"], fallback: 1)
        return state
    }

    private static func bool(_ value: String?, fallback: Bool = false) -> Bool {
        guard let value else { return fallback }
        return value == "1"
    }

    private static func positiveInt(_ value: String?, fallback: Int) -> Int {
        guard let value, let parsed = Int(value), parsed > 0 else { return fallback }
        return parsed
    }

    private static func nonnegativeInt(_ value: String?, fallback: Int = 0) -> Int {
        guard let value, let parsed = Int(value), parsed >= 0 else { return fallback }
        return parsed
    }

    private static func savedCursorCoordinate(_ value: String?) -> Int? {
        guard let value, let parsed = Int(value), parsed >= 0 else { return nil }
        // tmux uses UINT_MAX when alternate screen mode was entered with
        // ?47/?1047 rather than ?1049 and there is no cursor to restore.
        guard parsed != Int(UInt32.max) else { return nil }
        return parsed
    }
}

/// A coherent pane checkpoint. `replayData` is deliberately materialized once:
/// consumers must apply it before any `%output` deltas collected while the
/// checkpoint commands were in flight.
struct TmuxPaneSnapshot: Equatable, Sendable {
    let primaryScreen: Data
    let alternateScreen: Data
    let terminalState: TmuxPaneTerminalState
    let pendingOutput: Data
    let replayData: Data

    init(
        currentScreen: Data,
        alternateScreen: Data,
        terminalState: TmuxPaneTerminalState,
        pendingOutput: Data,
        byteLimit: Int
    ) {
        // `capture-pane` without -a is the current screen. While alternate
        // screen mode is active, -a is the saved primary screen (this is also
        // why iTerm2 swaps the two captured grids when alternate_on is set).
        let primary = terminalState.alternateOn ? alternateScreen : currentScreen
        let activeAlternate = terminalState.alternateOn ? currentScreen : Data()
        self.primaryScreen = primary
        self.alternateScreen = activeAlternate
        self.terminalState = terminalState
        self.pendingOutput = pendingOutput
        replayData = Self.makeBoundedReplay(
            primaryScreen: primary,
            alternateScreen: activeAlternate,
            state: terminalState,
            pendingOutput: pendingOutput,
            byteLimit: max(0, byteLimit)
        )
    }

    private static func makeBoundedReplay(
        primaryScreen: Data,
        alternateScreen: Data,
        state: TmuxPaneTerminalState,
        pendingOutput: Data,
        byteLimit: Int
    ) -> Data {
        guard byteLimit > 0 else { return Data() }

        let stateSuffix = terminalStateSequence(state) + pendingOutput
        let fixedPrefix = Data("\u{1b}c\u{1b}[3J".utf8)
        let alternateTransition: Data
        if state.alternateOn,
           let savedX = state.alternateSavedX,
           let savedY = state.alternateSavedY {
            alternateTransition = Data(
                "\u{1b}[\(savedY + 1);\(savedX + 1)H\u{1b}[?1049h\u{1b}[2J\u{1b}[H".utf8
            )
        } else if state.alternateOn {
            alternateTransition = Data("\u{1b}[?1047h\u{1b}[2J\u{1b}[H".utf8)
        } else {
            alternateTransition = Data()
        }
        let fixedByteCount = fixedPrefix.count + alternateTransition.count + stateSuffix.count
        guard fixedByteCount <= byteLimit else {
            // Never truncate in the middle of UTF-8 or a control sequence.
            var minimal = Data()
            if byteLimit >= 2 { minimal.append(Data("\u{1b}c".utf8)) }
            if byteLimit - minimal.count >= 4 { minimal.append(Data("\u{1b}[3J".utf8)) }
            return minimal
        }

        let screenBudget = byteLimit - fixedByteCount
        let alternateBudget: Int
        if state.alternateOn {
            // The visible alternate grid takes precedence, but retain room for
            // useful primary history whenever both fit.
            alternateBudget = min(alternateScreen.count, max(screenBudget / 2, min(screenBudget, state.width * state.height * 8)))
        } else {
            alternateBudget = 0
        }
        let boundedAlternate = boundedScreenSuffix(alternateScreen, byteLimit: alternateBudget)
        let boundedPrimary = boundedScreenSuffix(
            primaryScreen,
            byteLimit: screenBudget - boundedAlternate.count
        )

        var result = Data()
        result.reserveCapacity(byteLimit)
        result.append(fixedPrefix)
        result.append(boundedPrimary)
        if state.alternateOn {
            result.append(alternateTransition)
            result.append(boundedAlternate)
        }
        result.append(stateSuffix)
        if result.count > byteLimit {
            // The accounting above is exact, so this is defense in depth.
            result = Data(result.prefix(byteLimit))
        }
        return result
    }

    private static func terminalStateSequence(_ state: TmuxPaneTerminalState) -> Data {
        var sequence = ""
        // RIS established the default every-eight-column stops. Replace only
        // the stops visible to tmux and retain future defaults so widening the
        // pane does not permanently lose columns 24, 32, ...
        for defaultStop in stride(from: 8, to: state.width, by: 8) {
            sequence += "\u{1b}[\(defaultStop + 1)G\u{1b}[g"
        }
        for tabStop in state.tabStops.filter({ $0 >= 0 && $0 < state.width }).sorted() {
            sequence += "\u{1b}[\(tabStop + 1)G\u{1b}H"
        }

        let upper = min(max(0, state.scrollRegionUpper), max(0, state.height - 1))
        let lower = min(max(0, state.scrollRegionLower), max(0, state.height - 1))
        if upper < lower {
            sequence += "\u{1b}[\(upper + 1);\(lower + 1)r"
        } else {
            sequence += "\u{1b}[r"
        }
        sequence += state.originMode ? "\u{1b}[?6h" : "\u{1b}[?6l"
        let absoluteCursorY = min(max(0, state.cursorY), state.height - 1)
        let addressedCursorY = state.originMode ? max(0, absoluteCursorY - upper) : absoluteCursorY
        sequence += "\u{1b}[\(addressedCursorY + 1);"
            + "\(min(max(0, state.cursorX), state.width - 1) + 1)H"
        sequence += state.cursorVisible ? "\u{1b}[?25h" : "\u{1b}[?25l"
        sequence += state.insertMode ? "\u{1b}[4h" : "\u{1b}[4l"
        sequence += state.applicationCursorKeys ? "\u{1b}[?1h" : "\u{1b}[?1l"
        sequence += state.wraparound ? "\u{1b}[?7h" : "\u{1b}[?7l"
        sequence += state.applicationKeypad ? "\u{1b}=" : "\u{1b}>"
        let keyMode: Int
        switch state.paneKeyMode {
        case "Ext 1": keyMode = 1
        case "Ext 2": keyMode = 2
        default: keyMode = 0
        }
        sequence += "\u{1b}[>4;\(keyMode)m"
        sequence += "\u{1b}[>4;\(state.extendedKeyFormat == .csiU ? 1 : 0)f"
        sequence += "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1005l\u{1b}[?1006l"
        if state.mouseStandard { sequence += "\u{1b}[?1000h" }
        if state.mouseButton { sequence += "\u{1b}[?1002h" }
        if state.mouseAny { sequence += "\u{1b}[?1003h" }
        if state.mouseUTF8 { sequence += "\u{1b}[?1005h" }
        if state.mouseSGR { sequence += "\u{1b}[?1006h" }
        sequence += state.bracketedPaste ? "\u{1b}[?2004h" : "\u{1b}[?2004l"
        return Data(sequence.utf8)
    }

    private static func boundedScreenSuffix(_ data: Data, byteLimit: Int) -> Data {
        guard byteLimit > 0, !data.isEmpty else { return Data() }
        guard data.count > byteLimit else { return data }

        // Start on a hard line boundary so a retained suffix cannot begin in
        // the middle of UTF-8 or an SGR escape sequence.
        let searchStart = data.index(data.endIndex, offsetBy: -byteLimit)
        if let lineBreak = data.range(of: Data([0x0d, 0x0a]), in: searchStart..<data.endIndex) {
            return Data(data[lineBreak.upperBound...])
        }
        return Data()
    }
}

enum TmuxPendingOutputDecoder {
    static func decode(_ response: Data) -> Data {
        guard !response.isEmpty else { return Data() }
        let bytes = [UInt8](response)
        var decoded = Data()
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x5c, index + 3 < bytes.count,
               let value = octalValue(bytes[(index + 1)...(index + 3)]) {
                decoded.append(value)
                index += 4
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return decoded
    }

    private static func octalValue(_ digits: ArraySlice<UInt8>) -> UInt8? {
        guard digits.count == 3, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x37 }) else { return nil }
        return digits.reduce(0) { value, digit in value * 8 + (digit - 0x30) }
    }
}
