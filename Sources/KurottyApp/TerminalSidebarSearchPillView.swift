import AppKit

/// The one search pill shared by every sidebar section: command history, agent
/// sessions, and the file explorer.
///
/// Two decisions are baked in here rather than left to each panel:
///
/// * The fill is a solid `surfaceRaised`, not a translucent wash over the
///   sidebar. A translucent fill makes the field's color depend on whatever is
///   behind it, so it reads as a smudge instead of a control; a solid raised
///   surface plus a hairline border reads as an input.
/// * Focus is expressed twice — the border switches to `accent` and a
///   `focusRing` stroke is added outside it — so the state survives on both
///   themes and for color-vision-deficient users.
///
/// The ring is a sublayer with `masksToBounds` off, which is what lets it sit
/// outside the pill's own rounded rect without the pill growing.
@MainActor
final class TerminalSidebarSearchPillView: NSView {
    /// Fires on every keystroke, matching the immediate-filter behavior the
    /// panels had when each owned its own field.
    var onQueryChanged: (() -> Void)?

    private let iconView = NSImageView()
    private let textField = NSTextField()
    private let clearButton = NSButton()
    private let focusRingLayer = CAShapeLayer()
    private let placeholderProvider: () -> String
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var isFieldFocused = false
    /// The pill's own box. Everything else here is rebuilt by
    /// `applyAppearance()`; these constants are what would otherwise stay at
    /// the size they were installed with.
    private let metrics = ChromeMetricBindings()

    init(placeholder: @escaping () -> String) {
        placeholderProvider = placeholder
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Public API

    var stringValue: String {
        get { textField.stringValue }
        set {
            textField.stringValue = newValue
            updateClearButtonVisibility()
        }
    }

    var isEnabled: Bool {
        get { textField.isEnabled }
        set {
            textField.isEnabled = newValue
            clearButton.isEnabled = newValue
        }
    }

    func focus() {
        window?.makeFirstResponder(textField)
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        applyChromeMetrics()
        applyAppearance()
    }

    /// Re-takes what was sized from a token at init. This is the broadcast a
    /// UI-text-scale change arrives on, so anything sized once has to be
    /// re-sized here or the pill keeps its old box under new type.
    func applyChromeMetrics() {
        metrics.reapply()
        textField.font = DesignTokens.Typography.rowTitle.font
    }

    /// Panel-relative frame accessor for layout regression tests.
    var pillFrame: NSRect { bounds }

    var isClearButtonVisibleForTesting: Bool { !clearButton.isHidden }

    // MARK: Setup

    private func configure() {
        wantsLayer = true
        // Focus flips the border to the accent; it must not fade in.
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.masksToBounds = false
        layer?.cornerRadius = DesignTokens.Radius.smPX
        layer?.borderWidth = DesignTokens.Component.sidebarSearchPillBorderWidthPX

        focusRingLayer.fillColor = nil
        focusRingLayer.lineWidth = DesignTokens.Component.sidebarSearchPillFocusRingWidthPX
        focusRingLayer.isHidden = true
        focusRingLayer.actions = ["path": NSNull(), "strokeColor": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(focusRingLayer)

        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        textField.delegate = self
        textField.font = DesignTokens.Typography.rowTitle.font
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.usesSingleLineMode = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)

        clearButton.isBordered = false
        clearButton.bezelStyle = .inline
        clearButton.imagePosition = .imageOnly
        clearButton.title = ""
        clearButton.target = self
        clearButton.action = #selector(clearPressed(_:))
        clearButton.isHidden = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        let edgeInset = DesignTokens.Component.sidebarSearchPillEdgeInsetXPX
        let textInset = DesignTokens.Component.sidebarSearchPillTextInsetXPX
        let pillHeight = metrics.bind(heightAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.sidebarSearchPillHeightPX
        }
        let clearWidth = metrics.bind(clearButton.widthAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.sidebarSearchClearHitSizePX
        }
        let clearHeight = metrics.bind(clearButton.heightAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.sidebarSearchClearHitSizePX
        }
        NSLayoutConstraint.activate([
            pillHeight,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            textField.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: DesignTokens.Component.sidebarSearchIconGapPX
            ),
            textField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -edgeInset),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearWidth,
            clearHeight,
        ])
        applyAppearance()
    }

    override func layout() {
        super.layout()
        let outset = DesignTokens.Component.sidebarSearchPillFocusRingOutsetPX
        focusRingLayer.frame = bounds
        focusRingLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: -outset, dy: -outset),
            cornerWidth: DesignTokens.Radius.smPX + outset,
            cornerHeight: DesignTokens.Radius.smPX + outset,
            transform: nil
        )
    }

    @objc private func clearPressed(_ sender: NSButton) {
        textField.stringValue = ""
        updateClearButtonVisibility()
        onQueryChanged?()
    }

    private func updateClearButtonVisibility() {
        clearButton.isHidden = textField.stringValue.isEmpty
    }

    private func applyAppearance() {
        layer?.backgroundColor = chromeTheme.surfaceRaised.cgColor
        layer?.borderColor = (isFieldFocused ? chromeTheme.accent : chromeTheme.hairline).cgColor
        focusRingLayer.strokeColor = chromeTheme.focusRing.cgColor
        focusRingLayer.isHidden = !isFieldFocused
        // Palette-tinted symbols carry their color in the image, so focus and
        // theme changes rebuild the glyphs instead of retinting a template.
        iconView.image = Icon.symbol(
            IconSymbol.search,
            pointSizePT: DesignTokens.Component.sidebarSearchIconPointSizePT,
            weight: .medium,
            tint: isFieldFocused ? chromeTheme.accent : chromeTheme.textTertiary
        )
        clearButton.image = Icon.symbol(
            IconSymbol.clearSearch,
            pointSizePT: DesignTokens.Component.sidebarSearchClearGlyphPointSizePT,
            weight: .regular,
            tint: chromeTheme.textTertiary
        )
        textField.textColor = chromeTheme.textPrimary
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholderProvider(),
            attributes: [
                .foregroundColor: chromeTheme.textTertiary,
                .font: DesignTokens.Typography.rowTitle.font,
            ]
        )
        updateClearButtonVisibility()
    }
}

extension TerminalSidebarSearchPillView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updateClearButtonVisibility()
        onQueryChanged?()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        isFieldFocused = true
        applyAppearance()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        isFieldFocused = false
        applyAppearance()
    }
}
