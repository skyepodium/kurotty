import AppKit

/// Borderless icon button used across window chrome: tab add/close, pane close,
/// sidebar toggles, file-explorer refresh.
///
/// It takes its colors from the active `ChromeTheme` rather than from the dark
/// ramp, so a light terminal theme no longer gets dark-chrome icon colors. The
/// tint properties stay public and defaulted so call sites that only override
/// `hoverBackgroundColor` keep compiling.
final class ChromeIconButton: NSButton {
    /// Minimum hit target. Chrome icons are drawn smaller than this, but the
    /// clickable area never is.
    static let minimumHitTargetPX: CGFloat = 24
    /// Alpha applied to the rest tint when the button is disabled.
    static let disabledTintAlphaRATIO: CGFloat = 0.40

    var normalTintColor = DesignTokens.ChromeTheme.dark.textTertiary {
        didSet { updateAppearance() }
    }
    var hoverTintColor = DesignTokens.ChromeTheme.dark.textPrimary {
        didSet { updateAppearance() }
    }
    var hoverBackgroundColor = DesignTokens.ChromeTheme.dark.hoverFill {
        didSet { updateAppearance() }
    }
    var pressBackgroundColor = DesignTokens.ChromeTheme.dark.pressFill {
        didSet { updateAppearance() }
    }
    var focusRingColor = DesignTokens.ChromeTheme.dark.focusRing {
        didSet { updateAppearance() }
    }
    var normalBackgroundColor = NSColor.clear {
        didSet { updateAppearance() }
    }

    private var isHovered = false
    private var isPressed = false
    private let focusRingLayer = CALayer()

    /// Adopts a full theme in one call. Individual color properties remain
    /// available for surfaces that intentionally deviate (the tab bar tints its
    /// hover fill with the accent).
    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        normalTintColor = theme.textTertiary
        hoverTintColor = theme.textPrimary
        hoverBackgroundColor = theme.hoverFill
        pressBackgroundColor = theme.pressFill
        focusRingColor = theme.focusRing
    }

    /// The only initializer that takes content: an SF Symbol rather than a text
    /// glyph, so the icon inherits system metrics and accessibility. The old
    /// `init(title:)` is gone deliberately — `"+"` and `"×"` typed as text do
    /// not scale, do not match the rest of the icon ramp, and read to
    /// VoiceOver as punctuation.
    convenience init(
        symbolName: String,
        accessibilityLabel: String,
        size: Icon.SizeClass = .regular,
        target: AnyObject?,
        action: Selector?
    ) {
        self.init(frame: .zero)
        self.symbolName = symbolName
        self.imagePosition = .imageOnly
        self.target = target
        self.action = action
        setAccessibilityLabel(accessibilityLabel)
        symbolSize = size
        updateSymbolImage()
    }

    private var symbolName: String?
    private var symbolSize: Icon.SizeClass = .regular

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

    /// Guarantees a 24x24 responsive area even where the owning layout sizes the
    /// button smaller (the tab close button is drawn at 18pt). Expanding the hit
    /// rect rather than the frame keeps the icon's optical size and the owner's
    /// constraints intact.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isEnabled, let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return expandedHitRect.contains(local) ? self : nil
    }

    private var expandedHitRect: NSRect {
        let horizontalGrowth = max(0, Self.minimumHitTargetPX - bounds.width) / 2
        let verticalGrowth = max(0, Self.minimumHitTargetPX - bounds.height) / 2
        return bounds.insetBy(dx: -horizontalGrowth, dy: -verticalGrowth)
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

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled else { return }
        // Arrow, not pointing hand: the pointing hand means "web link" on macOS
        // and marks a control as not-native the moment it appears.
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(location) else { return }
        isHovered = false
        isPressed = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateAppearance()
        super.mouseDown(with: event)
        isPressed = false
        updateAppearance()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        updateAppearance()
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        updateAppearance()
        return didResign
    }

    override func layout() {
        super.layout()
        layoutFocusRing()
    }

    private func configureChromeButton() {
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Radius.smPX
        // Hover, press, and focus must land on the same frame as the click.
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        bezelStyle = .regularSquare
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false

        focusRingLayer.borderWidth = DesignTokens.Component.sidebarRowFocusRingWidthPX
        focusRingLayer.cornerRadius = DesignTokens.Radius.smPX
            + DesignTokens.Component.sidebarRowFocusRingOutsetPX
        focusRingLayer.isHidden = true
        ChromeMotion.disableImplicitAnimations(on: focusRingLayer)
        layer?.addSublayer(focusRingLayer)
        updateAppearance()
    }

    private func updateSymbolImage() {
        guard let symbolName else { return }
        let tint = isEnabled && isHovered ? hoverTintColor : normalTintColor
        image = Icon.symbol(
            symbolName,
            symbolSize,
            tint: isEnabled ? tint : normalTintColor.withAlphaComponent(Self.disabledTintAlphaRATIO)
        )
    }

    private func updateAppearance() {
        let tint = isEnabled && isHovered ? hoverTintColor : normalTintColor
        contentTintColor = isEnabled
            ? tint
            : normalTintColor.withAlphaComponent(Self.disabledTintAlphaRATIO)
        layer?.backgroundColor = fillColor().cgColor
        focusRingLayer.borderColor = focusRingColor.cgColor
        focusRingLayer.isHidden = !hasKeyboardFocus
        layoutFocusRing()
        updateSymbolImage()
    }

    private func fillColor() -> NSColor {
        guard isEnabled else { return normalBackgroundColor }
        if isPressed { return pressBackgroundColor }
        if isHovered { return hoverBackgroundColor }
        return normalBackgroundColor
    }

    private var hasKeyboardFocus: Bool {
        isEnabled && window?.firstResponder === self
    }

    private func layoutFocusRing() {
        let outset = DesignTokens.Component.sidebarRowFocusRingOutsetPX
        focusRingLayer.frame = bounds.insetBy(dx: -outset, dy: -outset)
    }
}
