import AppKit

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(in: super.drawingRect(forBounds: rect))
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObject: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: centeredTextRect(in: super.drawingRect(forBounds: rect)),
            in: controlView,
            editor: textObject,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObject: NSText,
        delegate: Any?,
        start selectionStart: Int,
        length selectionLength: Int
    ) {
        super.select(
            withFrame: centeredTextRect(in: super.drawingRect(forBounds: rect)),
            in: controlView,
            editor: textObject,
            delegate: delegate,
            start: selectionStart,
            length: selectionLength
        )
    }

    private func centeredTextRect(in rect: NSRect) -> NSRect {
        guard let font else { return rect }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = min(rect.height, lineHeight)
        return NSRect(
            x: rect.minX,
            y: rect.minY + floor((rect.height - height) / 2),
            width: rect.width,
            height: height
        )
    }
}

@MainActor
final class TerminalSearchBarView: NSView, NSTextFieldDelegate {
    /// Width the bar needs before a given set of controls still fits. This is
    /// layout arithmetic over the shared `Component.terminalSearch*` tokens, not
    /// a token table of its own.
    private static func minimumWidth(
        resultCountWidth: CGFloat,
        navigationButtonCount: Int
    ) -> CGFloat {
        let component = DesignTokens.Component.self
        let arrangedViewCount = 3 + navigationButtonCount
        return component.terminalSearchStackLeadingInsetPX
            + component.terminalSearchStackTrailingInsetPX
            + component.terminalSearchMinimumQueryWidthPX
            + resultCountWidth
            + component.terminalSearchButtonSidePX * CGFloat(1 + navigationButtonCount)
            + component.terminalSearchStackSpacingPX * CGFloat(arrangedViewCount - 1)
    }

    var onQueryChanged: ((String) -> Void)?
    var onNextMatch: (() -> Void)?
    var onPreviousMatch: (() -> Void)?
    var onClose: (() -> Void)?

    private let queryField = NSTextField()
    private let resultCountLabel = NSTextField(labelWithString: TerminalSearchSummary.empty.displayText)
    private lazy var previousButton = makeButton(
        symbolName: IconSymbol.previousMatch,
        accessibilityLabel: AppLocalization.string(.previousSearchMatch),
        action: #selector(previousButtonPressed(_:))
    )
    private lazy var nextButton = makeButton(
        symbolName: IconSymbol.nextMatch,
        accessibilityLabel: AppLocalization.string(.nextSearchMatch),
        action: #selector(nextButtonPressed(_:))
    )
    private lazy var closeButton = makeButton(
        symbolName: IconSymbol.close,
        accessibilityLabel: AppLocalization.string(.closeSearch),
        action: #selector(closeButtonPressed(_:))
    )
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var lastSummary = TerminalSearchSummary.empty
    private var isQueryFieldFocused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayout()
        applyChromeTheme(chromeTheme)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present(query: String? = nil) {
        if let query {
            queryField.stringValue = query
        }
        refreshLocalization()
        isHidden = false
        window?.makeFirstResponder(queryField)
        queryField.selectText(nil)
    }

    func dismiss() {
        isHidden = true
    }

    func update(summary: TerminalSearchSummary) {
        resultCountLabel.stringValue = summary.displayText
        let hasMatches = summary.totalMatches > 0
        previousButton.isEnabled = hasMatches
        nextButton.isEnabled = hasMatches
        lastSummary = summary
        applyResultCountColor()
        needsLayout = true
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = theme.activeTabBackground.cgColor
        layer.map(DesignTokens.Elevation.floating(for: theme).apply(to:))
        queryField.textColor = theme.textPrimary
        queryField.layer?.backgroundColor = theme.windowBackground
            .withAlphaComponent(DesignTokens.Component.terminalSearchFieldFillAlphaRATIO)
            .cgColor
        refreshLocalization()
        applyResultCountColor()
        applyBorderColor()
        // Symbols are palette-tinted, not template images, so a theme change has
        // to rebuild them rather than just set `contentTintColor`.
        for button in [previousButton, nextButton, closeButton] {
            guard let symbolName = button.identifier?.rawValue else { continue }
            button.image = Icon.symbol(symbolName, .small, tint: theme.textSecondary) ?? button.image
        }
    }

    /// The bar borrows the focus ring the field itself gives up: `queryField`
    /// draws no ring of its own, so the accent border is the only signal that
    /// typing goes here.
    func controlTextDidBeginEditing(_ notification: Notification) {
        isQueryFieldFocused = true
        applyBorderColor()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        isQueryFieldFocused = false
        applyBorderColor()
    }

    private func applyBorderColor() {
        layer?.borderColor = isQueryFieldFocused
            ? chromeTheme.accent.cgColor
            : chromeTheme.hairline.cgColor
    }

    /// Zero matches for something the user actually typed is a failed search,
    /// so the count turns `error`. An empty query has zero matches too, but
    /// that is a resting state, not a failure.
    private func applyResultCountColor() {
        let isFailedSearch = lastSummary.totalMatches == 0 && !queryField.stringValue.isEmpty
        resultCountLabel.textColor = isFailedSearch ? chromeTheme.error : chromeTheme.textTertiary
    }

    func refreshLocalization() {
        queryField.placeholderAttributedString = NSAttributedString(
            string: AppLocalization.string(.findTerminalOutputPlaceholder),
            attributes: [.foregroundColor: chromeTheme.textMuted]
        )
        queryField.setAccessibilityLabel(AppLocalization.string(.findTerminalOutput))
        for (button, key) in [
            (previousButton, L10nKey.previousSearchMatch),
            (nextButton, L10nKey.nextSearchMatch),
            (closeButton, L10nKey.closeSearch),
        ] {
            let label = AppLocalization.string(key)
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        applyResultCountColor()
        onQueryChanged?(queryField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            submit(modifiers: NSApp.currentEvent?.modifierFlags ?? [])
            return true
        default:
            return false
        }
    }

    func submit(modifiers: NSEvent.ModifierFlags) {
        if modifiers.terminalInputModifiers.contains(.shift) {
            onPreviousMatch?()
        } else {
            onNextMatch?()
        }
    }

    override func layout() {
        let resultCountWidth = max(
            DesignTokens.Component.terminalSearchMinimumResultCountWidthPX,
            resultCountLabel.intrinsicContentSize.width
        )
        let showsNavigation = bounds.width >= Self.minimumWidth(
            resultCountWidth: resultCountWidth,
            navigationButtonCount: 2
        )
        let showsResultCount = bounds.width >= Self.minimumWidth(
            resultCountWidth: resultCountWidth,
            navigationButtonCount: 0
        )
        previousButton.isHidden = !showsNavigation
        nextButton.isHidden = !showsNavigation
        resultCountLabel.isHidden = !showsResultCount
        super.layout()
    }

    private func configureLayout() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Radius.lgPX
        layer?.borderWidth = DesignTokens.Component.hairlinePX
        // The bar's own appearance never animates: it either is on screen or is
        // not, and a fade would make Cmd+F feel slow.
        layer.map(ChromeMotion.disableImplicitAnimations(on:))

        queryField.cell = VerticallyCenteredTextFieldCell(textCell: "")
        queryField.delegate = self
        queryField.isEditable = true
        queryField.isSelectable = true
        queryField.usesSingleLineMode = true
        queryField.font = NSFont.systemFont(ofSize: DesignTokens.Typography.controlLabel.sizePT)
        queryField.focusRingType = .none
        queryField.isBezeled = false
        queryField.isBordered = false
        queryField.drawsBackground = false
        queryField.wantsLayer = true
        queryField.layer?.cornerRadius = DesignTokens.Radius.smPX
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        queryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        queryField.translatesAutoresizingMaskIntoConstraints = false

        resultCountLabel.font = DesignTokens.Typography.statusBarNum.font
        resultCountLabel.alignment = .right
        resultCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        resultCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [queryField, resultCountLabel, previousButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = DesignTokens.Component.terminalSearchStackSpacingPX
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let preferredWidthConstraint = widthAnchor.constraint(
            equalToConstant: DesignTokens.Component.terminalSearchWidthPX
        )
        preferredWidthConstraint.priority = .defaultHigh
        let minimumQueryWidthConstraint = queryField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: DesignTokens.Component.terminalSearchMinimumQueryWidthPX
        )
        minimumQueryWidthConstraint.priority = .init(rawValue: 999)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalSearchHeightPX),
            preferredWidthConstraint,

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Component.terminalSearchStackLeadingInsetPX),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Component.terminalSearchStackTrailingInsetPX),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Component.terminalSearchStackVerticalInsetPX),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Component.terminalSearchStackVerticalInsetPX),

            queryField.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalSearchQueryHeightPX),
            minimumQueryWidthConstraint,
            resultCountLabel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: DesignTokens.Component.terminalSearchMinimumResultCountWidthPX
            ),
        ])
        update(summary: .empty)
        isHidden = true
    }

    private func makeButton(
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) -> NSButton {
        let image = Icon.symbol(
            symbolName,
            .small,
            tint: chromeTheme.textSecondary,
            accessibilityDescription: accessibilityLabel
        ) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(symbolName)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalSearchButtonSidePX).isActive = true
        button.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalSearchButtonSidePX).isActive = true
        return button
    }

    @objc private func previousButtonPressed(_ sender: NSButton) {
        onPreviousMatch?()
    }

    @objc private func nextButtonPressed(_ sender: NSButton) {
        onNextMatch?()
    }

    @objc private func closeButtonPressed(_ sender: NSButton) {
        onClose?()
    }
}
