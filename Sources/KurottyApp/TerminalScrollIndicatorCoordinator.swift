import AppKit

@MainActor
final class TerminalScrollIndicatorCoordinator: NSObject {
    private let scroller = NSScroller(frame: .zero)
    private let thumbView = ScrollIndicatorThumbView(frame: .zero)
    private let onNormalizedScrollbackOffsetChange: (CGFloat) -> Void

    init(onNormalizedScrollbackOffsetChange: @escaping (CGFloat) -> Void) {
        self.onNormalizedScrollbackOffsetChange = onNormalizedScrollbackOffsetChange
        super.init()
        configureScroller()
        configureThumbView()
    }

    func install(in view: NSView) {
        view.addSubview(scroller)
        view.addSubview(thumbView)
    }

    func layout(in bounds: NSRect, visibleRows: Int, maxScrollbackOffset: Int, scrollbackOffset: Int) {
        let width = DesignTokens.Component.terminalScrollerWidthPX
        scroller.frame = NSRect(
            x: max(0, bounds.width - width),
            y: 0,
            width: width,
            height: bounds.height
        )
        update(bounds: bounds, visibleRows: visibleRows, maxScrollbackOffset: maxScrollbackOffset, scrollbackOffset: scrollbackOffset)
    }

    func update(bounds: NSRect, visibleRows: Int, maxScrollbackOffset: Int, scrollbackOffset: Int) {
        let isHidden = maxScrollbackOffset == 0 || bounds.height <= 0
        scroller.isHidden = isHidden
        thumbView.isHidden = isHidden
        guard !isHidden else { return }

        let trackHeight = max(CGFloat(1), scroller.bounds.height)
        let contentRows = visibleRows + maxScrollbackOffset
        let proportionalKnob = CGFloat(visibleRows) / CGFloat(contentRows)
        let minimumHeightKnob = DesignTokens.Component.terminalScrollerMinThumbHeightPX / trackHeight
        let knobProportion = min(
            CGFloat(1),
            max(
                DesignTokens.Component.terminalScrollerMinKnobProportion,
                minimumHeightKnob,
                proportionalKnob
            )
        )
        scroller.knobProportion = knobProportion
        scroller.doubleValue = max(0, min(1, 1 - CGFloat(scrollbackOffset) / CGFloat(maxScrollbackOffset)))
        scroller.needsDisplay = true

        // NSScroller can be nearly invisible depending on system overlay style.
        // Draw a deterministic thumb so scrollback position is always visible.
        let thumbWidth = DesignTokens.Component.terminalScrollerThumbWidthPX
        let thumbHeight = trackHeight * knobProportion
        let clampedThumbHeight = min(trackHeight, thumbHeight)
        let maxTravel = max(CGFloat.zero, trackHeight - clampedThumbHeight)
        let normalizedOffset = max(CGFloat.zero, min(CGFloat(1), CGFloat(scrollbackOffset) / CGFloat(maxScrollbackOffset)))
        thumbView.frame = NSRect(
            x: scroller.frame.minX + (scroller.bounds.width - thumbWidth) / 2,
            y: scroller.frame.minY + maxTravel * normalizedOffset,
            width: thumbWidth,
            height: clampedThumbHeight
        )
        thumbView.needsDisplay = true
    }

    @objc private func scrollerDidChange(_ sender: NSScroller) {
        let normalizedScrollerValue = max(0, min(1, sender.doubleValue))
        onNormalizedScrollbackOffsetChange(1 - normalizedScrollerValue)
    }

    private func configureScroller() {
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .small
        scroller.target = self
        scroller.action = #selector(scrollerDidChange(_:))
        scroller.isHidden = true
    }

    private func configureThumbView() {
        thumbView.layer?.cornerRadius = DesignTokens.Component.terminalScrollerThumbWidthPX / 2
        thumbView.onDragNormalizedOffset = { [weak self] normalizedOffset in
            self?.onNormalizedScrollbackOffsetChange(normalizedOffset)
        }
        thumbView.isHidden = true
    }
}
