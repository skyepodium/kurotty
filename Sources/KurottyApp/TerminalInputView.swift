import AppKit

@MainActor
final class TerminalInputView: NSView, @preconcurrency NSTextInputClient {
    private let core: CoreBridge
    private var markedText = NSMutableAttributedString()
    private var inputSelectedRange = NSRange(location: NSNotFound, length: 0)

    init(core: CoreBridge) {
        self.core = core
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        core.recordKeyEvent()
        if handleCommandKey(event) {
            return
        }
        if handleTerminalControlKey(event) {
            return
        }
        interpretKeyEvents([event])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCommandKey(event) || super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        core.feed(text)
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("", forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        if TerminalCommandDispatcher.dispatchWindowCommand(from: self, event: event) {
            return true
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              flags.subtracting([.command, .shift]).isEmpty,
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else {
            return false
        }

        switch characters {
        case "c" where flags == .command:
            copy(nil)
            return true
        case "v" where flags == .command:
            paste(nil)
            return true
        case "x" where flags == .command:
            cut(nil)
            return true
        default:
            return false
        }
    }

    private func handleTerminalControlKey(_ event: NSEvent) -> Bool {
        if let controlText = terminalControlText(for: event) {
            core.feed(controlText)
            return true
        }

        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              event.charactersIgnoringModifiers == "\t"
        else {
            return false
        }
        core.feed("\t")
        return true
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        core.feed(text)
        unmarkText()
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            core.feed("\n")
        case #selector(insertTab(_:)):
            core.feed("\t")
        case #selector(cancelOperation(_:)):
            core.feed("\u{1b}")
        case #selector(deleteBackward(_:)):
            core.feed("\u{7f}")
        default:
            break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attr = string as? NSAttributedString ?? NSAttributedString(string: string as? String ?? "")
        markedText = NSMutableAttributedString(attributedString: attr)
        self.inputSelectedRange = selectedRange
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        inputSelectedRange = NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { inputSelectedRange }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
}

private func terminalControlText(for event: NSEvent) -> String? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.control), !flags.contains(.command), !flags.contains(.option) else {
        return nil
    }
    guard let character = event.charactersIgnoringModifiers?.unicodeScalars.first else {
        return nil
    }

    switch character.value {
    case 0x00...0x1f, 0x7f:
        return String(character)
    case 0x40, 0x20:
        return "\u{0}"
    case 0x41...0x5a:
        return String(UnicodeScalar(character.value - 0x40)!)
    case 0x61...0x7a:
        return String(UnicodeScalar(character.value - 0x60)!)
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
