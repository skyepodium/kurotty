import AppKit

enum TerminalTextInputRouter {
    private enum KeyCode {
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126

        static let qwertyLatinKeys: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 30: "]", 32: "u", 33: "[", 34: "i", 35: "p",
            37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        ]
    }

    @MainActor
    static func handleKeyDown(_ event: NSEvent, in view: NSView, hasMarkedText: Bool) -> Bool {
        guard shouldOfferToInputContext(event, hasMarkedText: hasMarkedText) else {
            return false
        }

        // NSTextInputContext owns IME composition. Offering text events here
        // first keeps input-source switches inside AppKit's IME lifecycle instead
        // of leaking Korean intermediate jamo as committed terminal input.
        if view.inputContext?.handleEvent(event) == true {
            log("keyDown inputContext marked=\(hasMarkedText) event=\(describe(event))")
            return true
        }

        view.interpretKeyEvents([event])
        log("keyDown interpreted fallback marked=\(hasMarkedText) event=\(describe(event))")
        return true
    }

    static func latinKeyEquivalent(for event: NSEvent) -> String? {
        if let characters = event.charactersIgnoringModifiers?.lowercased(),
           characters.count == 1,
           characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }) {
            return characters
        }
        return KeyCode.qwertyLatinKeys[event.keyCode]
    }

    static func committedText(from string: Any) -> String {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        return (text as NSString).precomposedStringWithCanonicalMapping
    }

    static func commandShortcutControlText(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              flags.subtracting([.command]).isEmpty,
              let character = latinKeyEquivalent(for: event)?.unicodeScalars.first
        else {
            return nil
        }
        return terminalControlText(forBaseScalarValue: character.value)
    }

    static func terminalControlText(for event: NSEvent) -> String? {
        if let enterText = terminalEnterText(for: event) {
            return enterText
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), !flags.contains(.command), !flags.contains(.option) else {
            return nil
        }
        if let character = event.charactersIgnoringModifiers?.unicodeScalars.first,
           let text = terminalControlText(forBaseScalarValue: character.value) {
            return text
        }

        guard let fallbackValue = controlBaseScalarValue(forKeyCode: event.keyCode) else {
            return nil
        }
        return terminalControlText(forBaseScalarValue: fallbackValue)
    }

    private static func terminalControlText(forBaseScalarValue value: UInt32) -> String? {
        switch value {
        case 0x00...0x1f, 0x7f:
            return controlScalarText(value)
        case 0x40, 0x20:
            return "\u{0}"
        case 0x41...0x5a:
            return controlScalarText(value - 0x40)
        case 0x61...0x7a:
            return controlScalarText(value - 0x60)
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

    private static func terminalEnterText(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting([.shift, .numericPad, .function]).isEmpty else {
            return nil
        }

        switch event.keyCode {
        case 36, 76:
            return flags.contains(.shift) ? "\n" : "\r"
        default:
            return nil
        }
    }

    private static func controlBaseScalarValue(forKeyCode keyCode: UInt16) -> UInt32? {
        KeyCode.qwertyLatinKeys[keyCode]?.unicodeScalars.first?.value
    }

    static func logInsertText(_ text: String, replacementRange: NSRange) {
        log("insertText \(metadata(for: text)) replacement=\(NSStringFromRange(replacementRange))")
    }

    static func logMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange) {
        log("setMarkedText \(metadata(for: text)) selected=\(NSStringFromRange(selectedRange)) replacement=\(NSStringFromRange(replacementRange))")
    }

    static func logUnmarkText() {
        log("unmarkText")
    }

    static func logPTYWrite(_ text: String, source: String) {
        log("ptyWrite source=\(source) \(metadata(for: text))")
    }

    private static func shouldOfferToInputContext(_ event: NSEvent, hasMarkedText: Bool) -> Bool {
        if hasMarkedText {
            return true
        }

        if terminalControlText(for: event) != nil {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }

        if isNavigationCommandKey(event) {
            return false
        }

        return !(event.characters ?? "").isEmpty ||
            !(event.charactersIgnoringModifiers ?? "").isEmpty
    }

    private static func isNavigationCommandKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting([.shift, .numericPad, .function]).isEmpty else {
            return false
        }

        switch event.keyCode {
        case KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.downArrow, KeyCode.upArrow:
            return true
        default:
            return false
        }
    }

    private static func describe(_ event: NSEvent) -> String {
        "keyCode=\(event.keyCode) flags=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)"
    }

    private static func controlScalarText(_ value: UInt32) -> String? {
        guard let scalar = UnicodeScalar(value) else {
            return nil
        }
        return String(scalar)
    }

    private static func metadata(for text: String) -> String {
        "utf8ByteCount=\(text.utf8.count) characterCount=\(text.count)"
    }

    private static func log(_ message: String) {
        guard DebugOptions.inputClient else { return }
        NSLog("Kurotty input-client: %@", message)
    }
}
