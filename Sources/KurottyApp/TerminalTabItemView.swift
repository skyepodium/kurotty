import AppKit

/// One tab in the window's custom tab bar: title, close button, hover wash,
/// and the selection rail. Extracted from `TerminalWindowController.swift`;
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
    /// Selection marker: a 2pt accent rail across the tab's top edge, clipped to
    /// the tab's corner radius.
    private let selectionRailView = NSView()
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

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(location) {
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
        // A tab's fill, hover wash, and selection rail all change on the same
        // click that moves it; none of them may fade.
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.cornerRadius = DesignTokens.Radius.mdPX
        // Clipping is what lets the top rail stop at the rounded corners instead
        // of overhanging them.
        layer?.masksToBounds = true

        hoverOverlayView.wantsLayer = true
        hoverOverlayView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        hoverOverlayView.isHidden = true
        hoverOverlayView.layer?.backgroundColor = chromeTheme.hoverFill.cgColor
        hoverOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverOverlayView)

        selectionRailView.wantsLayer = true
        selectionRailView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        selectionRailView.isHidden = !selected
        selectionRailView.layer?.backgroundColor = chromeTheme.accent.cgColor
        selectionRailView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionRailView)

        titleField.stringValue = title
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
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

            selectionRailView.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionRailView.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionRailView.topAnchor.constraint(equalTo: topAnchor),
            selectionRailView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.terminalTabTopRailHeightPX
            ),

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

    /// The unselected tab has no fill of its own: it sits directly on
    /// `surfaceChrome`, so only the selected tab is raised out of the bar.
    private var tabBackgroundColor: NSColor {
        selected ? chromeTheme.surfaceRaised : .clear
    }
}
