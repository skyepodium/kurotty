import AppKit

/// One row of the Settings pane list.
///
/// AppKit's `.recessed` bezel drew a grey capsule behind *every* row and marked
/// the selected one by darkening it a step, which on the light ramps left three
/// rows that read as the same object — the pane you were looking at was not
/// findable from the list. This paints through `TerminalSidebarRowHighlight`
/// instead, so the Settings list marks selection the way every other list in the
/// window marks it: an unselected row has no surface of its own, and the
/// selected one is a capsule.
@MainActor
final class PreferencesNavRowButton: NSButton {
    var chromeTheme = DesignTokens.ChromeTheme.dark {
        didSet { needsDisplay = true }
    }

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.toggle)
        alignment = .left
        // The title is drawn by AppKit on top of the capsule; the highlight owns
        // the surface underneath and nothing else.
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The row's state in the shared painter's vocabulary. A Settings row is
    /// never the first responder of a list, so it never carries a focus ring.
    var highlightState: TerminalSidebarRowHighlight.State {
        TerminalSidebarRowHighlight.State(
            isSelected: state == .on,
            isHovered: isHovered,
            isWindowActive: window?.isKeyWindow ?? false
        )
    }

    var currentAppearance: TerminalSidebarRowHighlight.Appearance {
        TerminalSidebarRowHighlight.appearance(for: highlightState, theme: chromeTheme)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        TerminalSidebarRowHighlight.paint(currentAppearance, in: bounds)
        super.draw(dirtyRect)
    }
}
