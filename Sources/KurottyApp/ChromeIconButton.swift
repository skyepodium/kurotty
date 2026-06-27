import AppKit

final class ChromeIconButton: NSButton {
    var normalTintColor = DesignTokens.Color.textMuted {
        didSet { updateAppearance() }
    }
    var hoverTintColor = DesignTokens.Color.textPrimary {
        didSet { updateAppearance() }
    }
    var hoverBackgroundColor = DesignTokens.Color.inactiveTabHoverBackground {
        didSet { updateAppearance() }
    }

    private var isHovered = false

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureChromeButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    private func configureChromeButton() {
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Component.radiusSmallPX
        bezelStyle = .regularSquare
        isBordered = false
        setButtonType(.momentaryPushIn)
        font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        updateAppearance()
    }

    private func updateAppearance() {
        let tint = isEnabled && isHovered ? hoverTintColor : normalTintColor
        contentTintColor = isEnabled ? tint : DesignTokens.Color.textMuted.withAlphaComponent(0.45)
        layer?.backgroundColor = isEnabled && isHovered
            ? hoverBackgroundColor.cgColor
            : NSColor.clear.cgColor
    }
}
