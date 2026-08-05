import AppKit

/// Shared card, row, and control builders for `PreferencesView`: the layout
/// vocabulary every pane is composed from. Extracted verbatim from
/// `PreferencesView.swift`.
extension PreferencesView {
    func addPageHeader(_ title: String, subtitle: String) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Space.x1PX
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DesignTokens.Typography.prefsTitle.font
        titleLabel.textColor = chromeTheme.textPrimary
        let subtitleLabel = wrappingLabel(subtitle)
        subtitleLabel.font = DesignTokens.Typography.prefsBody.font
        subtitleLabel.textColor = chromeTheme.textSecondary
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX).isActive = true
        detailStack.addArrangedSubview(stack)
    }

    /// A settings card: raised fill, hairline border, `md` radius, `x5` padding.
    /// The fill and border come from the chrome theme, so the card belongs to
    /// the same surface family as the sidebar and the tab bar.
    func section(title: String, subtitle: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Layout.rowSpacingPX
        stack.edgeInsets = NSEdgeInsets(
            top: Layout.cardPaddingPX,
            left: Layout.cardPaddingPX,
            bottom: Layout.cardPaddingPX,
            right: Layout.cardPaddingPX
        )
        styleAsCard(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX).isActive = true
        let heading = sectionHeading(title, subtitle: subtitle)
        heading.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX - Layout.cardPaddingPX * 2).isActive = true
        stack.addArrangedSubview(heading)
        search.registerCard(stack, title: title)
        return stack
    }

    /// The one place a labeled setting is added to a card, and therefore the one
    /// place search learns that the setting exists. A row added any other way is
    /// a row no query can find.
    func addRow(_ label: String, control: NSView, to card: NSStackView) {
        let rowView = row(label: label, control: control)
        card.addArrangedSubview(rowView)
        search.registerRow(rowView, label: label, in: card)
    }

    func styleAsCard(_ view: NSView) {
        let theme = chromeTheme
        view.wantsLayer = true
        view.layer?.cornerRadius = DesignTokens.Radius.mdPX
        view.layer?.backgroundColor = theme.surfaceRaised.cgColor
        view.layer?.borderWidth = DesignTokens.Component.hairlinePX
        view.layer?.borderColor = theme.hairline.cgColor
        // Switching preferences panes is not a transition; cards must appear at
        // their final color.
        view.layer.map(ChromeMotion.disableImplicitAnimations(on:))
    }

    func sectionHeading(_ title: String, subtitle: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Component.preferencesHeadingLineGapPX
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DesignTokens.Typography.prefsSection.font
        titleLabel.textColor = chromeTheme.textPrimary
        let subtitleLabel = wrappingLabel(subtitle)
        subtitleLabel.font = DesignTokens.Typography.prefsCaption.font
        subtitleLabel.textColor = chromeTheme.textTertiary
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        return stack
    }

    private func row(label title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = DesignTokens.Typography.prefsBody.font
        label.textColor = chromeTheme.textSecondary
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Layout.labelWidthPX).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        if control is NSPopUpButton {
            control.widthAnchor.constraint(equalToConstant: Layout.fieldWidthPX).isActive = true
        }
        // Checkbox titles are full sentences and are the widest thing in a card.
        // At 720pt they no longer fit on one line, so they wrap instead of
        // truncating: a setting whose explanation ends in an ellipsis is worse
        // than a setting that takes two lines.
        if let checkbox = control as? NSButton, checkbox.cell is NSButtonCell {
            checkbox.font = DesignTokens.Typography.prefsBody.font
            checkbox.cell?.wraps = true
            checkbox.cell?.lineBreakMode = .byWordWrapping
            checkbox.widthAnchor.constraint(
                lessThanOrEqualToConstant: Layout.controlColumnWidthPX
            ).isActive = true
        }
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Layout.labelControlGapPX
        return stack
    }

    /// Right-aligns a pane's single primary action inside its card.
    func trailingActionRow(_ control: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [spacer, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(
            equalToConstant: Layout.contentWidthPX - Layout.cardPaddingPX * 2
        ).isActive = true
        return stack
    }

    /// The AppKit spelling of `.borderedProminent`: an accent-filled rounded
    /// push button at the regular control height.
    func stylePrimaryButton(_ button: NSButton) {
        styleButtonMetrics(button)
        button.bezelColor = chromeTheme.accent
    }

    /// Every other button in Preferences is the recessed category list, which is
    /// a selection control rather than an action, so there is no second bezel
    /// style to define here yet.
    func styleButtonMetrics(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        guard sizedButtons.insert(ObjectIdentifier(button)).inserted else { return }
        button.heightAnchor.constraint(
            equalToConstant: DesignTokens.Component.preferencesButtonHeightPX
        ).isActive = true
        button.widthAnchor.constraint(
            greaterThanOrEqualToConstant: DesignTokens.Component.preferencesButtonWidthPX
        ).isActive = true
    }

    func numericControl(field: NSTextField, stepper: NSStepper, suffix: String) -> NSStackView {
        let suffixLabel = NSTextField(labelWithString: suffix)
        suffixLabel.font = DesignTokens.Typography.prefsCaption.font
        suffixLabel.textColor = chromeTheme.textTertiary
        let stack = NSStackView(views: [field, stepper, suffixLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DesignTokens.Space.x2PX
        return stack
    }

    func labeledColorWell(_ title: String, well: NSColorWell) -> NSStackView {
        well.toolTip = title
        well.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        label.font = DesignTokens.Typography.prefsCaption.font
        label.textColor = chromeTheme.textTertiary
        label.alignment = .center
        let stack = NSStackView(views: [well, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = DesignTokens.Space.x1PX
        return stack
    }

    func configureTextField(_ field: NSTextField, action: Selector) {
        field.delegate = self
        field.target = self
        field.action = action
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Layout.fieldWidthPX).isActive = true
    }

    func configureNumericField(_ field: NSTextField, stepper: NSStepper, minimum: Double, maximum: Double, increment: Double) {
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldChanged(_:))
        field.alignment = .right
        field.formatter = NumberFormatter.integerOrDecimal
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: DesignTokens.Component.preferencesNumericFieldWidthPX).isActive = true
        stepper.minValue = minimum
        stepper.maxValue = maximum
        stepper.increment = increment
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
    }

    func configureColorWell(_ well: NSColorWell, tag: Int) {
        well.tag = tag
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: Layout.colorWellSizePX).isActive = true
        well.heightAnchor.constraint(equalToConstant: Layout.colorWellSizePX).isActive = true
    }

    func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }
}

private extension NumberFormatter {
    static var integerOrDecimal: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        return formatter
    }
}
