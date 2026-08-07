import AppKit

/// A narrow overlay scroller for glass sidebars.
///
/// AppKit's legacy sidebar scroller becomes an opaque charcoal stripe in a
/// light window. This keeps the native scroll mechanics while drawing only a
/// quiet, rounded thumb that strengthens on interaction.
@MainActor
final class TerminalSidebarScroller: NSScroller {
    private var chromeTheme = DesignTokens.ChromeTheme.dark

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = .overlay
        controlSize = .small
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        needsDisplay = true
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob).insetBy(
            dx: DesignTokens.Component.sidebarScrollerHorizontalInsetPX,
            dy: DesignTokens.Component.sidebarScrollerVerticalInsetPX
        )
        guard knobRect.width > 0, knobRect.height > 0 else { return }
        let alpha = hitPart == .knob
            ? DesignTokens.Component.sidebarScrollerActiveAlphaRATIO
            : DesignTokens.Component.sidebarScrollerRestingAlphaRATIO
        chromeTheme.textTertiary.withAlphaComponent(alpha).setFill()
        NSBezierPath(
            roundedRect: knobRect,
            xRadius: knobRect.width / 2,
            yRadius: knobRect.width / 2
        ).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}
