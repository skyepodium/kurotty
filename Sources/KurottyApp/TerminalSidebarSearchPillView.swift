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

    private enum Symbol {
        static let search = "magnifyingglass"
        static let clear = "xmark.circle.fill"
    }

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
        applyAppearance()
    }

    /// Panel-relative frame accessor for layout regression tests.
    var pillFrame: NSRect { bounds }

    var isClearButtonVisibleForTesting: Bool { !clearButton.isHidden }

    // MARK: Setup

    private func configure() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.cornerRadius = DesignTokens.Radius.smPX
        layer?.borderWidth = DesignTokens.Component.sidebarSearchPillBorderWidthPX

        focusRingLayer.fillColor = nil
        focusRingLayer.lineWidth = DesignTokens.Component.sidebarSearchPillFocusRingWidthPX
        focusRingLayer.isHidden = true
        focusRingLayer.actions = ["path": NSNull(), "strokeColor": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(focusRingLayer)

        iconView.image = NSImage(systemSymbolName: Symbol.search, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: DesignTokens.Component.sidebarSearchIconPointSizePT,
                weight: .medium
            ))
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

        clearButton.image = NSImage(systemSymbolName: Symbol.clear, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: DesignTokens.Component.sidebarSearchClearGlyphPointSizePT,
                weight: .regular
            ))
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
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.sidebarSearchPillHeightPX),

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
            clearButton.widthAnchor.constraint(
                equalToConstant: DesignTokens.Component.sidebarSearchClearHitSizePX
            ),
            clearButton.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.sidebarSearchClearHitSizePX
            ),
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
        iconView.contentTintColor = isFieldFocused ? chromeTheme.accent : chromeTheme.textTertiary
        clearButton.contentTintColor = chromeTheme.textTertiary
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
