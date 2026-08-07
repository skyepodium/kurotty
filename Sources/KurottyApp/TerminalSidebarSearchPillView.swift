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
///
/// The trailing accessory is one slot holding two mutually exclusive controls:
/// the `/` keyboard hint when the field is idle, and the clear button once it
/// holds a query. They are stacked rather than overlaid so the slot collapses
/// to nothing when neither applies and the query gets the full width.
@MainActor
final class TerminalSidebarSearchPillView: NSView {
    /// Fires on every keystroke, matching the immediate-filter behavior the
    /// panels had when each owned its own field.
    var onQueryChanged: (() -> Void)?

    private let iconView = NSImageView()
    private let textField = NSTextField()
    private let clearButton = NSButton()
    private let hintBadgeView = TerminalSidebarKeyHintBadgeView()
    private let accessoryStackView = NSStackView()
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
            updateAccessoryVisibility()
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

    var isKeyHintVisibleForTesting: Bool { !hintBadgeView.isHidden }

    var keyHintFrameForTesting: NSRect { convert(hintBadgeView.bounds, from: hintBadgeView) }

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

        hintBadgeView.isHidden = true

        accessoryStackView.orientation = .horizontal
        accessoryStackView.alignment = .centerY
        accessoryStackView.spacing = DesignTokens.Component.sidebarSearchHintBadgeGapPX
        // Hidden arranged subviews detach, so the slot is exactly as wide as
        // whichever accessory currently applies and zero when neither does.
        accessoryStackView.detachesHiddenViews = true
        accessoryStackView.addArrangedSubview(hintBadgeView)
        accessoryStackView.addArrangedSubview(clearButton)
        accessoryStackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accessoryStackView)

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
            textField.trailingAnchor.constraint(
                equalTo: accessoryStackView.leadingAnchor,
                constant: -DesignTokens.Component.sidebarSearchHintBadgeGapPX
            ),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),

            accessoryStackView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -edgeInset
            ),
            accessoryStackView.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        updateAccessoryVisibility()
        onQueryChanged?()
    }

    /// The two trailing accessories are mutually exclusive: a hint is only
    /// useful while there is nothing to clear, and it would be noise the moment
    /// the user is already in the field.
    private func updateAccessoryVisibility() {
        let isEmpty = textField.stringValue.isEmpty
        clearButton.isHidden = isEmpty
        hintBadgeView.isHidden = !isEmpty || isFieldFocused
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
        hintBadgeView.applyChromeTheme(chromeTheme)
        textField.textColor = chromeTheme.textPrimary
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholderProvider(),
            attributes: [
                .foregroundColor: chromeTheme.textTertiary,
                .font: DesignTokens.Typography.rowTitle.font,
            ]
        )
        updateAccessoryVisibility()
    }
}

extension TerminalSidebarSearchPillView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updateAccessoryVisibility()
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

/// The `/` key cap inside a sidebar search field.
///
/// Drawn as a key rather than written as a sentence: a bordered box with a
/// single glyph is read as "this key does that" at a glance, where "Press / to
/// filter" would be a second line of copy competing with the placeholder in a
/// 28pt control. The sentence still exists — it is the tooltip and the
/// accessibility label — so nothing is only available to someone who already
/// recognises the convention.
///
/// The cap is a hint, so it is the quietest thing in the pill: the lowest text
/// rank inside a hairline, no fill of its own. It sits on `surfaceRaised`, the
/// pill's own surface, which the color-ramp tests already hold to AA.
@MainActor
final class TerminalSidebarKeyHintBadgeView: NSView {
    private let keyLabel: NSTextField
    private let metrics = ChromeMetricBindings()

    init() {
        keyLabel = NSTextField(
            labelWithString: String(DesignTokens.Component.sidebarSearchHintKeyCharacter)
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.cornerRadius = DesignTokens.Radius.xsPX
        layer?.borderWidth = DesignTokens.Component.sidebarSearchHintBadgeBorderWidthPX
        translatesAutoresizingMaskIntoConstraints = false

        let hint = String(
            format: AppLocalization.string(.sidebarFilterKeyboardHint),
            String(DesignTokens.Component.sidebarSearchHintKeyCharacter)
        )
        toolTip = hint
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(hint)

        keyLabel.alignment = .center
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyLabel)

        let height = metrics.bind(heightAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.sidebarSearchHintBadgeHeightPX
        }
        let minimumWidth = metrics.bind(
            widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ) {
            DesignTokens.Component.sidebarSearchHintBadgeMinWidthPX
        }
        // Without this the cap has no upper bound on its width and Auto Layout
        // is free to stretch it across the whole field, which is exactly what
        // it did: the hint rendered as a bare `/` floating mid-pill.
        let hugsItsGlyph = widthAnchor.constraint(
            equalToConstant: DesignTokens.Component.sidebarSearchHintBadgeMinWidthPX
        )
        hugsItsGlyph.priority = .defaultLow
        NSLayoutConstraint.activate([
            height,
            minimumWidth,
            hugsItsGlyph,
            keyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            keyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            keyLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: DesignTokens.Component.sidebarSearchHintBadgeTextInsetXPX
            ),
            keyLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -DesignTokens.Component.sidebarSearchHintBadgeTextInsetXPX
            ),
        ])
        applyChromeTheme(.dark)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        metrics.reapply()
        layer?.borderColor = theme.borderStrong.cgColor
        DesignTokens.Typography.badge.apply(to: keyLabel, color: theme.textTertiary)
    }
}
