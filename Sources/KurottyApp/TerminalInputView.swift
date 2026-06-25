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
        interpretKeyEvents([event])
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

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        core.feed(text)
        unmarkText()
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            core.feed("\n")
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
