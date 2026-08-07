import AppKit

/// One tab in the window's custom tab bar: title, close button, and hover wash.
/// The active tab is grounded into the bar like Dia's connected tab shape.
/// Extracted from `TerminalWindowController.swift`;
/// the controller rebuilds these in `updateTabBar()`.
@MainActor
final class TerminalTabItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = ChromeIconButton(
        symbolName: IconSymbol.close,
        accessibilityLabel: AppLocalization.string(.closePaneOrTab),
        size: .small,
        target: nil,
        action: nil
    )
    /// Achromatic hover wash painted over whatever the tab's base fill is, so
    /// hover reads the same on the selected and unselected tab and can never be
    /// mistaken for the accent.
    private let hoverOverlayView = NSView()
    private let selected: Bool
    private let chromeTheme: DesignTokens.ChromeTheme
    private var isHovered = false
    private let onSelect: () -> Void
    private let onClose: () -> Void

    init(
        title: String,
        isSelected: Bool,
        chromeTheme: DesignTokens.ChromeTheme,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        selected = isSelected
        self.chromeTheme = chromeTheme
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)
        configure(title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The close button is hidden by alpha on an unselected, unhovered tab, but
    /// it keeps its frame. Hit-testing the frame alone therefore closed tabs the
    /// user could not see the button on — and because tracking is
    /// `.activeInKeyWindow`, hover never fires in a background window, so the
    /// first click on another window's tab closed it instead of focusing it.
    nonisolated static func closesTab(atLocation location: CGPoint, closeButtonFrame: CGRect, closeButtonAlpha: CGFloat) -> Bool {
        closeButtonAlpha > 0 && closeButtonFrame.contains(location)
    }

    nonisolated static func hoverOverlayColor(for theme: DesignTokens.ChromeTheme) -> NSColor {
        theme.textPrimary.withAlphaComponent(
            DesignTokens.Component.terminalTabHoverFillAlphaRATIO
        )
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if Self.closesTab(
            atLocation: location,
            closeButtonFrame: closeButton.frame,
            closeButtonAlpha: closeButton.alphaValue
        ) {
            onClose()
            return
        }
        onSelect()
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
        let location = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(location) else { return }
        isHovered = false
        updateAppearance()
    }

    @objc private func closePressed(_ sender: NSButton) {
        onClose()
    }

    private func configure(title: String) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // A tab's fill and hover wash both change on the same
        // click that moves it; none of them may fade.
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.cornerRadius = DesignTokens.Radius.mdPX
        layer?.masksToBounds = true
        layer?.maskedCorners = selected
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        hoverOverlayView.wantsLayer = true
        hoverOverlayView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        hoverOverlayView.isHidden = true
        hoverOverlayView.layer?.backgroundColor = Self.hoverOverlayColor(for: chromeTheme).cgColor
        hoverOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverOverlayView)

        titleField.stringValue = title
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        closeButton.toolTip = TerminalCommandTooltip.text(
            for: .closeCurrentPane,
            title: AppLocalization.string(.closePaneOrTab)
        )
        closeButton.applyChromeTheme(chromeTheme)
        // Same deliberate accent hover as the add button.
        closeButton.hoverBackgroundColor = chromeTheme.activeIndicator.withAlphaComponent(
            DesignTokens.Component.terminalTabButtonHoverAlphaRATIO
        )
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabHeightPX),
            widthAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.Component.terminalTabMinWidthPX),
            widthAnchor.constraint(lessThanOrEqualToConstant: DesignTokens.Component.terminalTabMaxWidthPX),

            hoverOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hoverOverlayView.topAnchor.constraint(equalTo: topAnchor),
            hoverOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Component.terminalTabTitleLeadingPX),
            titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -DesignTokens.Component.terminalTabTitleCloseGapPX),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Component.terminalTabCloseTrailingPX),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabCloseWidthPX),
            closeButton.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabCloseWidthPX),
        ])
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = tabBackgroundColor.cgColor
        hoverOverlayView.isHidden = !isHovered
        let titleRole = selected ? DesignTokens.Typography.tabLabelSel : DesignTokens.Typography.tabLabel
        titleRole.apply(
            to: titleField,
            color: selected || isHovered ? chromeTheme.textPrimary : chromeTheme.textSecondary
        )
        closeButton.normalTintColor = selected || isHovered ? chromeTheme.textSecondary : chromeTheme.textTertiary
        closeButton.alphaValue = selected || isHovered ? 1 : 0
    }

    /// The unselected tab has no fill of its own. The selected fill reaches the
    /// bar's bottom edge, so it reads as connected instead of as a floating
    /// capsule.
    private var tabBackgroundColor: NSColor {
        selected ? chromeTheme.surfaceRaised : .clear
    }
}
