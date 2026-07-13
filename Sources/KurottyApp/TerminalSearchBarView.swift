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
    private enum Metrics {
        static let stackLeadingInset: CGFloat = 8
        static let stackTrailingInset: CGFloat = 6
        static let stackSpacing: CGFloat = 4
        static let stackVerticalInset: CGFloat = 7
        static let queryHeight: CGFloat = 30
        static let minimumQueryWidth: CGFloat = 120
        static let minimumResultCountWidth: CGFloat = 44
        static let buttonSide: CGFloat = 24

        static func minimumWidth(
            resultCountWidth: CGFloat,
            navigationButtonCount: Int
        ) -> CGFloat {
            let arrangedViewCount = 3 + navigationButtonCount
            return stackLeadingInset
                + stackTrailingInset
                + minimumQueryWidth
                + resultCountWidth
                + buttonSide * CGFloat(1 + navigationButtonCount)
                + stackSpacing * CGFloat(arrangedViewCount - 1)
        }
    }

    var onQueryChanged: ((String) -> Void)?
    var onNextMatch: (() -> Void)?
    var onPreviousMatch: (() -> Void)?
    var onClose: (() -> Void)?

    private let queryField = NSTextField()
    private let resultCountLabel = NSTextField(labelWithString: TerminalSearchSummary.empty.displayText)
    private lazy var previousButton = makeButton(
        symbolName: "chevron.up",
        accessibilityLabel: AppLocalization.string(.previousSearchMatch),
        action: #selector(previousButtonPressed(_:))
    )
    private lazy var nextButton = makeButton(
        symbolName: "chevron.down",
        accessibilityLabel: AppLocalization.string(.nextSearchMatch),
        action: #selector(nextButtonPressed(_:))
    )
    private lazy var closeButton = makeButton(
        symbolName: "xmark",
        accessibilityLabel: AppLocalization.string(.closeSearch),
        action: #selector(closeButtonPressed(_:))
    )
    private var chromeTheme = DesignTokens.ChromeTheme.dark

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
        needsLayout = true
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = theme.activeTabBackground.cgColor
        layer?.borderColor = theme.borderHairline.cgColor
        queryField.textColor = theme.textPrimary
        queryField.layer?.backgroundColor = theme.windowBackground.withAlphaComponent(0.9).cgColor
        refreshLocalization()
        resultCountLabel.textColor = theme.textSecondary
        for button in [previousButton, nextButton, closeButton] {
            button.contentTintColor = theme.textSecondary
        }
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
            Metrics.minimumResultCountWidth,
            resultCountLabel.intrinsicContentSize.width
        )
        let showsNavigation = bounds.width >= Metrics.minimumWidth(
            resultCountWidth: resultCountWidth,
            navigationButtonCount: 2
        )
        let showsResultCount = bounds.width >= Metrics.minimumWidth(
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
        layer?.cornerRadius = DesignTokens.Component.terminalSearchCornerRadiusPX
        layer?.borderWidth = DesignTokens.Component.hairlinePX
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        queryField.cell = VerticallyCenteredTextFieldCell(textCell: "")
        queryField.delegate = self
        queryField.isEditable = true
        queryField.isSelectable = true
        queryField.usesSingleLineMode = true
        queryField.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT)
        queryField.focusRingType = .none
        queryField.isBezeled = false
        queryField.isBordered = false
        queryField.drawsBackground = false
        queryField.wantsLayer = true
        queryField.layer?.cornerRadius = DesignTokens.Component.radiusSmallPX
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        queryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        queryField.translatesAutoresizingMaskIntoConstraints = false

        resultCountLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.Typography.statusFontSizePT,
            weight: .medium
        )
        resultCountLabel.alignment = .right
        resultCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        resultCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [queryField, resultCountLabel, previousButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = Metrics.stackSpacing
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let preferredWidthConstraint = widthAnchor.constraint(
            equalToConstant: DesignTokens.Component.terminalSearchWidthPX
        )
        preferredWidthConstraint.priority = .defaultHigh
        let minimumQueryWidthConstraint = queryField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Metrics.minimumQueryWidth
        )
        minimumQueryWidthConstraint.priority = .init(rawValue: 999)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalSearchHeightPX),
            preferredWidthConstraint,

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.stackLeadingInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.stackTrailingInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.stackVerticalInset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.stackVerticalInset),

            queryField.heightAnchor.constraint(equalToConstant: Metrics.queryHeight),
            minimumQueryWidthConstraint,
            resultCountLabel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: Metrics.minimumResultCountWidth
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
        let button = NSButton(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) ?? NSImage(),
            target: self,
            action: action
        )
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Metrics.buttonSide).isActive = true
        button.heightAnchor.constraint(equalToConstant: Metrics.buttonSide).isActive = true
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
