import AppKit

enum TerminalExtendedKeyFormat: String, Equatable, Sendable {
    case xterm
    case csiU = "csi-u"
}

enum TerminalKeyEncoder {
    struct State: Equatable {
        var applicationCursorKeys = false
        var applicationKeypad = false
        var modifyOtherKeysMode = 0
        var extendedKeyFormat: TerminalExtendedKeyFormat = .xterm
    }

    private enum KeyCode {
        static let tab: UInt16 = 48
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let deleteBackward: UInt16 = 51

        static let insert: UInt16 = 114
        static let home: UInt16 = 115
        static let pageUp: UInt16 = 116
        static let forwardDelete: UInt16 = 117
        static let end: UInt16 = 119
        static let pageDown: UInt16 = 121

        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126

        static let qwertyLatinKeys: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i",
            35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        ]
    }

    private static let insertBacktabSelector = NSSelectorFromString("insertBacktab:")

    static func latinKeyEquivalent(for event: NSEvent) -> String? {
        if let characters = event.charactersIgnoringModifiers?.lowercased(),
           characters.count == 1,
           characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }) {
            return characters
        }
        return KeyCode.qwertyLatinKeys[event.keyCode]
    }

    static func sequence(for event: NSEvent, state: State = State()) -> String? {
        let flags = normalizedFlags(event.modifierFlags)
        guard !flags.contains(.command) else {
            return nil
        }

        switch event.keyCode {
        case KeyCode.returnKey:
            guard flags.subtracting([.shift, .numericPad, .function]).isEmpty else { return nil }
            return flags.contains(.shift) ? "\n" : "\r"
        case KeyCode.keypadEnter:
            guard flags.subtracting([.shift, .numericPad, .function]).isEmpty else { return nil }
            if state.applicationKeypad, !flags.contains(.shift) { return "\u{1b}OM" }
            return flags.contains(.shift) ? "\n" : "\r"
        case KeyCode.tab:
            if flags.subtracting([.numericPad, .function]).isEmpty {
                return "\t"
            }
            if flags.subtracting([.shift, .numericPad, .function]).isEmpty {
                if state.modifyOtherKeysMode == 2 {
                    return extendedKeySequence(codepoint: 9, flags: flags, format: state.extendedKeyFormat)
                }
                return "\u{1b}[Z"
            }
            if flags.subtracting([.option, .numericPad, .function]).isEmpty,
               state.modifyOtherKeysMode == 1 {
                return "\u{1b}\t"
            }
            if state.modifyOtherKeysMode == 2,
               let sequence = extendedKeySequence(codepoint: 9, flags: flags, format: state.extendedKeyFormat) {
                return sequence
            }
            return nil
        case KeyCode.deleteBackward:
            guard flags.subtracting([.shift, .numericPad, .function]).isEmpty else { return nil }
            return "\u{7f}"
        default:
            break
        }

        if state.applicationKeypad,
           flags.subtracting([.numericPad, .function]).isEmpty,
           let sequence = applicationKeypadSequence(forKeyCode: event.keyCode) {
            return sequence
        }

        if let arrow = arrowFinal(forKeyCode: event.keyCode) {
            return arrowSequence(final: arrow, flags: flags, state: state)
        }
        if let final = homeEndFinal(forKeyCode: event.keyCode) {
            return csiSequence(prefix: "1", final: final, flags: flags)
        }
        if let number = tildeKeyNumber(forKeyCode: event.keyCode) {
            return tildeSequence(number: number, flags: flags)
        }
        if let final = ss3FunctionFinal(forKeyCode: event.keyCode) {
            return ss3FunctionSequence(final: final, flags: flags)
        }
        if let number = tildeFunctionNumber(forKeyCode: event.keyCode) {
            return tildeSequence(number: number, flags: flags)
        }
        if let extended = modifyOtherKeysSequence(for: event, flags: flags, state: state) {
            return extended
        }
        if let controlText = controlSequence(for: event, flags: flags) {
            return controlText
        }
        return nil
    }

    static func sequence(for selector: Selector, state: State = State()) -> String? {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return "\r"
        case #selector(NSResponder.insertTab(_:)):
            return "\t"
        case insertBacktabSelector:
            return "\u{1b}[Z"
        case #selector(NSResponder.cancelOperation(_:)):
            return "\u{1b}"
        case #selector(NSResponder.deleteBackward(_:)):
            return "\u{7f}"
        case #selector(NSResponder.deleteForward(_:)):
            return "\u{1b}[3~"
        case #selector(NSResponder.moveToBeginningOfLine(_:)):
            return "\u{1b}[H"
        case #selector(NSResponder.moveToEndOfLine(_:)):
            return "\u{1b}[F"
        case #selector(NSResponder.moveUp(_:)):
            return state.applicationCursorKeys ? "\u{1b}OA" : "\u{1b}[A"
        case #selector(NSResponder.moveDown(_:)):
            return state.applicationCursorKeys ? "\u{1b}OB" : "\u{1b}[B"
        case #selector(NSResponder.moveLeft(_:)):
            return state.applicationCursorKeys ? "\u{1b}OD" : "\u{1b}[D"
        case #selector(NSResponder.moveRight(_:)):
            return state.applicationCursorKeys ? "\u{1b}OC" : "\u{1b}[C"
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            return "\u{1b}[1;2A"
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            return "\u{1b}[1;2B"
        case #selector(NSResponder.moveRightAndModifySelection(_:)):
            return "\u{1b}[1;2C"
        case #selector(NSResponder.moveLeftAndModifySelection(_:)):
            return "\u{1b}[1;2D"
        case #selector(NSResponder.scrollPageUp(_:)):
            return "\u{1b}[5~"
        case #selector(NSResponder.scrollPageDown(_:)):
            return "\u{1b}[6~"
        default:
            return nil
        }
    }

    private static func normalizedFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
    }

    private static func modifierParameter(for flags: NSEvent.ModifierFlags) -> Int? {
        var value = 1
        if flags.contains(.shift) { value += 1 }
        if flags.contains(.option) { value += 2 }
        if flags.contains(.control) { value += 4 }
        return value == 1 ? nil : value
    }

    private static func arrowFinal(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case KeyCode.upArrow: return "A"
        case KeyCode.downArrow: return "B"
        case KeyCode.rightArrow: return "C"
        case KeyCode.leftArrow: return "D"
        default: return nil
        }
    }

    private static func applicationKeypadSequence(forKeyCode keyCode: UInt16) -> String? {
        let final: Character
        switch keyCode {
        case 82: final = "p" // 0
        case 83: final = "q" // 1
        case 84: final = "r" // 2
        case 85: final = "s" // 3
        case 86: final = "t" // 4
        case 87: final = "u" // 5
        case 88: final = "v" // 6
        case 89: final = "w" // 7
        case 91: final = "x" // 8
        case 92: final = "y" // 9
        case 65: final = "n" // decimal
        case 75: final = "o" // divide
        case 67: final = "j" // multiply
        case 78: final = "m" // minus
        case 69: final = "k" // plus
        case 81: final = "X" // equals
        default: return nil
        }
        return "\u{1b}O\(final)"
    }

    private static func modifyOtherKeysSequence(
        for event: NSEvent,
        flags: NSEvent.ModifierFlags,
        state: State
    ) -> String? {
        guard (1...2).contains(state.modifyOtherKeysMode) else { return nil }
        let significantFlags = flags.subtracting([.numericPad, .function, .capsLock])
        guard !significantFlags.isEmpty,
              significantFlags.isSubset(of: [.shift, .option, .control]),
              let codepoint = singleCodepoint(event.charactersIgnoringModifiers)
        else {
            return nil
        }

        if state.modifyOtherKeysMode == 1 {
            // Match tmux input_key_mode1: Meta + a regular key and the
            // established Ctrl mappings retain their VT10x representation.
            if significantFlags.contains(.option), !significantFlags.contains(.control) {
                guard let scalar = UnicodeScalar(codepoint) else { return nil }
                return "\u{1b}" + String(scalar)
            }
            if significantFlags.contains(.control),
               let control = controlText(forBaseScalarValue: codepoint) {
                return (significantFlags.contains(.option) ? "\u{1b}" : "") + control
            }
        }

        return extendedKeySequence(
            codepoint: codepoint,
            flags: significantFlags,
            format: state.extendedKeyFormat
        )
    }

    private static func extendedKeySequence(
        codepoint: UInt32,
        flags: NSEvent.ModifierFlags,
        format: TerminalExtendedKeyFormat
    ) -> String? {
        guard let modifier = modifierParameter(for: flags), modifier > 1 else { return nil }
        switch format {
        case .xterm:
            return "\u{1b}[27;\(modifier);\(codepoint)~"
        case .csiU:
            return "\u{1b}[\(codepoint);\(modifier)u"
        }
    }

    private static func singleCodepoint(_ text: String?) -> UInt32? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars
        guard scalars.count == 1 else { return nil }
        return scalars.first?.value
    }

    private static func arrowSequence(final: String, flags: NSEvent.ModifierFlags, state: State) -> String? {
        let significantFlags = flags.subtracting([.numericPad, .function])
        if significantFlags.isEmpty {
            return state.applicationCursorKeys ? "\u{1b}O\(final)" : "\u{1b}[\(final)"
        }
        guard let parameter = modifierParameter(for: significantFlags) else {
            return nil
        }
        return "\u{1b}[1;\(parameter)\(final)"
    }

    private static func homeEndFinal(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case KeyCode.home: return "H"
        case KeyCode.end: return "F"
        default: return nil
        }
    }

    private static func tildeKeyNumber(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case KeyCode.insert: return 2
        case KeyCode.forwardDelete: return 3
        case KeyCode.pageUp: return 5
        case KeyCode.pageDown: return 6
        default: return nil
        }
    }

    private static func ss3FunctionFinal(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 122: return "P"
        case 120: return "Q"
        case 99: return "R"
        case 118: return "S"
        default: return nil
        }
    }

    private static func tildeFunctionNumber(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 96: return 15
        case 97: return 17
        case 98: return 18
        case 100: return 19
        case 101: return 20
        case 109: return 21
        case 103: return 23
        case 111: return 24
        default: return nil
        }
    }

    private static func csiSequence(prefix: String, final: String, flags: NSEvent.ModifierFlags) -> String? {
        let significantFlags = flags.subtracting([.numericPad, .function])
        if significantFlags.isEmpty {
            return "\u{1b}[\(final)"
        }
        guard let parameter = modifierParameter(for: significantFlags) else {
            return nil
        }
        return "\u{1b}[\(prefix);\(parameter)\(final)"
    }

    private static func tildeSequence(number: Int, flags: NSEvent.ModifierFlags) -> String? {
        let significantFlags = flags.subtracting([.numericPad, .function])
        if significantFlags.isEmpty {
            return "\u{1b}[\(number)~"
        }
        guard let parameter = modifierParameter(for: significantFlags) else {
            return nil
        }
        return "\u{1b}[\(number);\(parameter)~"
    }

    private static func ss3FunctionSequence(final: String, flags: NSEvent.ModifierFlags) -> String? {
        let significantFlags = flags.subtracting([.numericPad, .function])
        if significantFlags.isEmpty {
            return "\u{1b}O\(final)"
        }
        guard let parameter = modifierParameter(for: significantFlags) else {
            return nil
        }
        return "\u{1b}[1;\(parameter)\(final)"
    }

    private static func controlSequence(for event: NSEvent, flags: NSEvent.ModifierFlags) -> String? {
        guard flags.contains(.control),
              flags.subtracting([.control, .shift, .numericPad, .function]).isEmpty
        else {
            return nil
        }

        if let character = event.charactersIgnoringModifiers?.unicodeScalars.first,
           let text = controlText(forBaseScalarValue: character.value) {
            return text
        }
        guard let fallbackValue = latinKeyEquivalent(for: event)?.unicodeScalars.first?.value else {
            return nil
        }
        return controlText(forBaseScalarValue: fallbackValue)
    }

    private static func controlText(forBaseScalarValue value: UInt32) -> String? {
        switch value {
        case 0x00...0x1f, 0x7f:
            return scalarText(value)
        case 0x40, 0x20:
            return "\u{0}"
        case 0x41...0x5a:
            return scalarText(value - 0x40)
        case 0x61...0x7a:
            return scalarText(value - 0x60)
        case 0x5b:
            return "\u{1b}"
        case 0x5c:
            return "\u{1c}"
        case 0x5d:
            return "\u{1d}"
        case 0x5e:
            return "\u{1e}"
        case 0x5f:
            return "\u{1f}"
        case 0x3f:
            return "\u{7f}"
        default:
            return nil
        }
    }

    private static func scalarText(_ value: UInt32) -> String? {
        guard let scalar = UnicodeScalar(value) else {
            return nil
        }
        return String(scalar)
    }
}
