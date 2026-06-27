import AppKit

enum TerminalTextInputRouter {
    @MainActor
    static func handleKeyDown(_ event: NSEvent, in view: NSView, hasMarkedText: Bool) -> Bool {
        guard shouldOfferToInputContext(event, hasMarkedText: hasMarkedText) else {
            return false
        }

        // interpretKeyEvents is the NSTextInputClient path that owns IME
        // composition. Once a text candidate is offered here, never fall back to
        // raw characters; Korean IME may otherwise leak intermediate jamo to PTY.
        view.interpretKeyEvents([event])
        log("keyDown interpreted marked=\(hasMarkedText) event=\(describe(event))")
        return true
    }

    static func committedText(from string: Any) -> String {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        return (text as NSString).precomposedStringWithCanonicalMapping
    }

    static func logInsertText(_ text: String, replacementRange: NSRange) {
        log("insertText text=\(debugText(text)) replacement=\(NSStringFromRange(replacementRange))")
    }

    static func logMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange) {
        log("setMarkedText text=\(debugText(text)) selected=\(NSStringFromRange(selectedRange)) replacement=\(NSStringFromRange(replacementRange))")
    }

    static func logUnmarkText() {
        log("unmarkText")
    }

    static func logPTYWrite(_ text: String, source: String) {
        log("ptyWrite source=\(source) utf8=\(text.data(using: .utf8)?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "") text=\(debugText(text))")
    }

    private static func shouldOfferToInputContext(_ event: NSEvent, hasMarkedText: Bool) -> Bool {
        if hasMarkedText {
            return true
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }

        return !(event.characters ?? "").isEmpty ||
            !(event.charactersIgnoringModifiers ?? "").isEmpty
    }

    private static func describe(_ event: NSEvent) -> String {
        "keyCode=\(event.keyCode) chars=\(debugText(event.characters ?? "")) ignoring=\(debugText(event.charactersIgnoringModifiers ?? "")) flags=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)"
    }

    private static func debugText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{1b}", with: "\\e")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func log(_ message: String) {
        guard DebugOptions.inputClient else { return }
        NSLog("Kurotty input-client: %@", message)
    }
}
