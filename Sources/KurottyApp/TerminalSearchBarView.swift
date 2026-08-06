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
        navigationButtonCount: Int,
        optionButtonCount: Int
    ) -> CGFloat {
        let component = DesignTokens.Component.self
        let buttonCount = 1 + navigationButtonCount + optionButtonCount
        let arrangedViewCount = 2 + buttonCount
        return component.terminalSearchStackLeadingInsetPX
            + component.terminalSearchStackTrailingInsetPX
            + component.terminalSearchMinimumQueryWidthPX
            + resultCountWidth
            + component.terminalSearchButtonSidePX * CGFloat(buttonCount)
            + component.terminalSearchStackSpacingPX * CGFloat(arrangedViewCount - 1)
    }

    var onQueryChanged: ((String) -> Void)?
    var onOptionsChanged: ((TerminalSearchOptions) -> Void)?
    var onNextMatch: (() -> Void)?
    var onPreviousMatch: (() -> Void)?
    var onClose: (() -> Void)?

    /// The toggles keep their state across close and reopen: a user who searches
    /// with regex once is usually about to do it again.
    private(set) var searchOptions = TerminalSearchOptions.default

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
    private lazy var matchCaseButton = makeOptionButton(
        symbolName: IconSymbol.matchCase,
        accessibilityLabel: AppLocalization.string(.matchCase),
        action: #selector(matchCaseButtonPressed(_:))
    )
    private lazy var regularExpressionButton = makeOptionButton(
        symbolName: IconSymbol.regularExpression,
        accessibilityLabel: AppLocalization.string(.useRegularExpression),
        action: #selector(regularExpressionButtonPressed(_:))
    )
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    /// The bar's scaled box: its own height and preferred width, the query
    /// field, the result-count slot, and every button side.
    private let metrics = ChromeMetricBindings()
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
        applyBorderColor()
        applyOptionButtonAppearance()
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
        // The same broadcast carries a UI-text-scale change, so the bar re-takes
        // its box and its query font here as well as its colors.
        metrics.reapply()
        queryField.font = NSFont.systemFont(ofSize: DesignTokens.Typography.controlLabel.sizePT)
        resultCountLabel.font = DesignTokens.Typography.statusBarNum.font
        layer?.backgroundColor = theme.activeTabBackground.cgColor
        layer.map(DesignTokens.Elevation.floating(for: theme).apply(to:))
        queryField.textColor = theme.textPrimary
        queryField.layer?.backgroundColor = theme.windowBackground
            .withAlphaComponent(DesignTokens.Component.terminalSearchFieldFillAlphaRATIO)
            .cgColor
        refreshLocalization()
        applyResultCountColor()
        applyBorderColor()
        applyOptionButtonAppearance()
        // Symbols are palette-tinted, not template images, so a theme change has
        // to rebuild them rather than just set `contentTintColor`.
        for button in [previousButton, nextButton, closeButton] {
            guard let symbolName = button.identifier?.rawValue else { continue }
            button.image = Icon.symbol(symbolName, .small, tint: theme.textSecondary) ?? button.image
        }
    }

    /// An engaged toggle has to read as engaged with no label next to it, so it
    /// takes the accent-on-selection-wash pairing selected rows use elsewhere.
    /// A regex that does not compile tints its own toggle `error`, which points
    /// at the option responsible instead of only reddening the field.
    private func applyOptionButtonAppearance() {
        let isPatternBroken = !isQueryValid
        for (button, isEngaged) in [
            (matchCaseButton, searchOptions.isCaseSensitive),
            (regularExpressionButton, searchOptions.usesRegularExpression),
        ] {
            button.applyChromeTheme(chromeTheme)
            let engagedTint = button === regularExpressionButton && isPatternBroken
                ? chromeTheme.error
                : chromeTheme.accent
            button.normalTintColor = isEngaged ? engagedTint : chromeTheme.textSecondary
            button.hoverTintColor = isEngaged ? engagedTint : chromeTheme.textPrimary
            button.normalBackgroundColor = isEngaged ? chromeTheme.selectionFill : .clear
            button.setAccessibilityValue(isEngaged)
        }
    }

    /// A regex is invalid for as long as it takes to finish typing it, so this
    /// drives appearance only — never an alert, never a thrown error.
    private var isQueryValid: Bool {
        TerminalSearchPattern.isValidQuery(queryField.stringValue, options: searchOptions)
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
        // A pattern that cannot compile outranks the focus ring: the field is
        // where the problem is, and the user is looking at it either way.
        if !isQueryValid {
            layer?.borderColor = chromeTheme.error.cgColor
            return
        }
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
            (matchCaseButton, L10nKey.matchCase),
            (regularExpressionButton, L10nKey.useRegularExpression),
        ] as [(NSButton, L10nKey)] {
            let label = AppLocalization.string(key)
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        applyResultCountColor()
        applyBorderColor()
        applyOptionButtonAppearance()
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
        // Shed controls in reverse order of urgency as the pane narrows: the
        // option toggles are set once and forgotten, the arrows have keyboard
        // equivalents, and the count is the last thing worth losing.
        let showsOptions = bounds.width >= Self.minimumWidth(
            resultCountWidth: resultCountWidth,
            navigationButtonCount: 2,
            optionButtonCount: 2
        )
        let showsNavigation = bounds.width >= Self.minimumWidth(
            resultCountWidth: resultCountWidth,
            navigationButtonCount: 2,
            optionButtonCount: 0
        )
        let showsResultCount = bounds.width >= Self.minimumWidth(
            resultCountWidth: resultCountWidth,
            navigationButtonCount: 0,
            optionButtonCount: 0
        )
        matchCaseButton.isHidden = !showsOptions
        regularExpressionButton.isHidden = !showsOptions
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

        let stack = NSStackView(views: [
            queryField,
            matchCaseButton,
            regularExpressionButton,
            resultCountLabel,
            previousButton,
            nextButton,
            closeButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = DesignTokens.Component.terminalSearchStackSpacingPX
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let preferredWidthConstraint = metrics.bind(widthAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.terminalSearchWidthPX
        }
        preferredWidthConstraint.priority = .defaultHigh
        let minimumQueryWidthConstraint = metrics.bind(
            queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ) {
            DesignTokens.Component.terminalSearchMinimumQueryWidthPX
        }
        minimumQueryWidthConstraint.priority = .init(rawValue: 999)

        NSLayoutConstraint.activate([
            metrics.bind(heightAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.terminalSearchHeightPX
            },
            preferredWidthConstraint,

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Component.terminalSearchStackLeadingInsetPX),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Component.terminalSearchStackTrailingInsetPX),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Component.terminalSearchStackVerticalInsetPX),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Component.terminalSearchStackVerticalInsetPX),

            metrics.bind(queryField.heightAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.terminalSearchQueryHeightPX
            },
            minimumQueryWidthConstraint,
            metrics.bind(resultCountLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)) {
                DesignTokens.Component.terminalSearchMinimumResultCountWidthPX
            },
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
        metrics.bind(button.widthAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.terminalSearchButtonSidePX
        }.isActive = true
        metrics.bind(button.heightAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.terminalSearchButtonSidePX
        }.isActive = true
        return button
    }

    /// Option toggles are `ChromeIconButton`s rather than the bar's own plain
    /// buttons: they need hover, press, and a keyboard focus ring, which is
    /// exactly what the shared chrome control already carries.
    private func makeOptionButton(
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) -> ChromeIconButton {
        let button = ChromeIconButton(
            symbolName: symbolName,
            accessibilityLabel: accessibilityLabel,
            size: .small,
            target: self,
            action: action
        )
        button.setAccessibilityRole(.checkBox)
        button.toolTip = accessibilityLabel
        metrics.bind(button.widthAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.terminalSearchButtonSidePX
        }.isActive = true
        metrics.bind(button.heightAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.terminalSearchButtonSidePX
        }.isActive = true
        return button
    }

    @objc private func matchCaseButtonPressed(_ sender: NSButton) {
        searchOptions.isCaseSensitive.toggle()
        searchOptionsChanged()
    }

    @objc private func regularExpressionButtonPressed(_ sender: NSButton) {
        searchOptions.usesRegularExpression.toggle()
        searchOptionsChanged()
    }

    private func searchOptionsChanged() {
        applyOptionButtonAppearance()
        applyBorderColor()
        onOptionsChanged?(searchOptions)
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
