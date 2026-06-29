import AppKit

final class ScrollIndicatorThumbView: NSView {
    var onDragNormalizedOffset: ((CGFloat) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var dragOffsetY: CGFloat = 0
    private var isHovering = false {
        didSet { updateAppearance() }
    }
    private var isDraggingThumb = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
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
        addCursorRect(bounds, cursor: .pointingHand)
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

    private func updateAppearance() {
        let color: NSColor
        if isDraggingThumb {
            color = DesignTokens.Color.scrollerThumbActive
        } else if isHovering {
            color = DesignTokens.Color.scrollerThumbHover
        } else {
            color = DesignTokens.Color.scrollerThumb
        }
        layer?.backgroundColor = color.cgColor
    }
}
