import AppKit

enum TerminalTextInputRouter {
    private enum KeyCode {
        static let textInputKeys: Set<UInt16> = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16,
            17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
            31, 32, 33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45,
            46, 47, 49, 50,
        ]
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    @MainActor
    static func handleKeyDown(_ event: NSEvent, in view: NSView, hasMarkedText: Bool) -> Bool {
        guard shouldOfferToInputContext(event, hasMarkedText: hasMarkedText) else {
            return false
        }

        // NSTextInputContext owns IME composition; handleEvent lets AppKit/IMK
        // commit active marked text before terminal control fallback runs.
        if view.inputContext?.handleEvent(event) == true {
            log("keyDown inputContext handled marked=\(hasMarkedText) event=\(describe(event))")
            return true
        }

        // Some AppKit test/runtime contexts do not expose an input context.
        // Keep the NSTextInputClient path as the fallback that delivers
        // setMarkedText/insertText callbacks.
        view.interpretKeyEvents([event])
        log("keyDown interpreted fallback marked=\(hasMarkedText) event=\(describe(event))")
        return true
    }

    static func latinKeyEquivalent(for event: NSEvent) -> String? {
        TerminalKeyEncoder.latinKeyEquivalent(for: event)
    }

    static func committedText(from string: Any) -> String {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        return (text as NSString).precomposedStringWithCanonicalMapping
    }

    static func commandShortcutControlText(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.terminalInputModifiers
        guard flags.contains(.command),
              flags.subtracting([.command]).isEmpty,
              let character = latinKeyEquivalent(for: event)?.unicodeScalars.first
        else {
            return nil
        }
        return commandShortcutControlText(forBaseScalarValue: character.value)
    }

    static func terminalControlText(for event: NSEvent) -> String? {
        TerminalKeyEncoder.sequence(for: event)
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

        let flags = event.modifierFlags.terminalInputModifiers
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }

        if isNavigationCommandKey(event) {
            return false
        }

        if !(event.characters ?? "").isEmpty ||
            !(event.charactersIgnoringModifiers ?? "").isEmpty {
            return true
        }

        return KeyCode.textInputKeys.contains(event.keyCode)
    }

    private static func isNavigationCommandKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.terminalInputModifiers
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

    private static func commandShortcutControlText(forBaseScalarValue value: UInt32) -> String? {
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
