import AppKit

/// The scrollback indicator's thumb: the only thing that draws in the terminal's
/// trailing strip.
///
/// Colors come from the active chrome ramp rather than a fixed gray, because the
/// thumb sits on the terminal canvas and a light canvas turns a light gray into
/// nothing at all.
@MainActor
final class ScrollIndicatorThumbView: NSView {
    var onDragNormalizedOffset: ((CGFloat) -> Void)?
    /// Fires when the pointer takes or releases the thumb. The coordinator holds
    /// the indicator open for as long as it is engaged.
    var onPointerEngagementChange: ((Bool) -> Void)?

    var chromeTheme = DesignTokens.ChromeTheme.dark {
        didSet { updateAppearance() }
    }

    /// True while the pointer is over the thumb or dragging it.
    private(set) var isPointerEngaged = false

    private var trackingArea: NSTrackingArea?
    private var dragOffsetY: CGFloat = 0
    private var isHovering = false {
        didSet { pointerStateDidChange() }
    }
    private var isDraggingThumb = false {
        didSet { pointerStateDidChange() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Same rule as every other chrome control: the fill snaps between
        // states. A hover that fades is a hover that feels laggy, and the
        // thumb also moves during layout, which AppKit would otherwise animate.
        if let layer {
            ChromeMotion.disableImplicitAnimations(on: layer)
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Arrow, not pointing hand: the pointing hand means "web link" on macOS and
    /// marks a control as not-native the moment it appears. Exposed so the rule
    /// can be asserted; `resetCursorRects` itself is not readable back.
    var indicatorCursor: NSCursor { .arrow }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: indicatorCursor)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        isDraggingThumb = true
        let location = convert(event.locationInWindow, from: nil)
        dragOffsetY = min(max(0, location.y), bounds.height)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let location = superview.convert(event.locationInWindow, from: nil)
        let trackFrame = NSRect(x: frame.minX, y: 0, width: frame.width, height: superview.bounds.height)
        let maxTravel = max(1, trackFrame.height - frame.height)
        let nextY = min(max(0, location.y - dragOffsetY - trackFrame.minY), maxTravel)
        onDragNormalizedOffset?(nextY / maxTravel)
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingThumb = false
    }

    // MARK: - Test seams

    func setHoveringForTesting(_ hovering: Bool) {
        isHovering = hovering
    }

    func setDraggingForTesting(_ dragging: Bool) {
        isDraggingThumb = dragging
    }

    var fillColorForTesting: CGColor? {
        layer?.backgroundColor
    }

    // MARK: - Appearance

    private func pointerStateDidChange() {
        updateAppearance()
        let isEngaged = isHovering || isDraggingThumb
        guard isEngaged != isPointerEngaged else { return }
        isPointerEngaged = isEngaged
        onPointerEngagementChange?(isEngaged)
    }

    private func updateAppearance() {
        let color: NSColor
        if isDraggingThumb {
            color = chromeTheme.scrollerThumbActive
        } else if isHovering {
            color = chromeTheme.scrollerThumbHover
        } else {
            color = chromeTheme.scrollerThumb
        }
        layer?.backgroundColor = color.cgColor
    }
}
