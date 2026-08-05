import AppKit
import KurottyCore

/// Per-pane content builders for `PreferencesView`: which settings exist and
/// which card each one lives in. Extracted verbatim from
/// `PreferencesView.swift`; the shared card/row/control builders live in
/// `PreferencesViewControls.swift`.
extension PreferencesView {
    func buildTerminalPage() {
        addPageHeader(copy(.terminalTitle), subtitle: copy(.terminalSubtitle))

        let shellSection = section(title: copy(.shellSection), subtitle: copy(.shellSectionHelp))
        addRow(copy(.workingDirectory), control: workingDirectoryField, to: shellSection)
        configureTextField(workingDirectoryField, action: #selector(textFieldChanged(_:)))
        perProjectHistoryCheckbox.title = copy(.perProjectHistoryCheckboxTitle)
        addRow(copy(.perProjectHistory), control: perProjectHistoryCheckbox, to: shellSection)
        detailStack.addArrangedSubview(shellSection)

        let textSection = section(title: copy(.textSection), subtitle: copy(.textSectionHelp))
        fontPopup.removeAllItems()
        fontPopup.addItems(withTitles: availableMonospacedFonts())
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        addRow(copy(.font), control: fontPopup, to: textSection)
        configureNumericField(fontSizeField, stepper: fontSizeStepper, minimum: SettingsDefaults.minimumTerminalFontSizePT, maximum: SettingsDefaults.maximumTerminalFontSizePT, increment: 1)
        addRow(
            copy(.fontSize),
            control: numericControl(field: fontSizeField, stepper: fontSizeStepper, suffix: "pt"),
            to: textSection
        )
        hideMouseCursorCheckbox.title = copy(.hideMouseCursorCheckboxTitle)
        addRow(copy(.hideMouseCursor), control: hideMouseCursorCheckbox, to: textSection)
        confirmMultilinePasteCheckbox.title = copy(.confirmMultilinePasteCheckboxTitle)
        addRow(copy(.confirmMultilinePaste), control: confirmMultilinePasteCheckbox, to: textSection)
        confirmCloseCheckbox.title = copy(.confirmCloseCheckboxTitle)
        addRow(copy(.confirmClose), control: confirmCloseCheckbox, to: textSection)
        statusBarCheckbox.title = copy(.statusBarCheckboxTitle)
        addRow(copy(.statusBar), control: statusBarCheckbox, to: textSection)
        detailStack.addArrangedSubview(textSection)

        let editorSection = section(title: copy(.editorSection), subtitle: copy(.editorSectionHelp))
        configureNumericField(
            codeEditorFontSizeField,
            stepper: codeEditorFontSizeStepper,
            minimum: SettingsDefaults.minimumCodeEditorFontSizePT,
            maximum: SettingsDefaults.maximumCodeEditorFontSizePT,
            increment: 1
        )
        addRow(
            copy(.editorFontSize),
            control: numericControl(field: codeEditorFontSizeField, stepper: codeEditorFontSizeStepper, suffix: "pt"),
            to: editorSection
        )
        codeEditorWrapCheckbox.title = copy(.editorWrapCheckboxTitle)
        addRow(copy(.editorWrap), control: codeEditorWrapCheckbox, to: editorSection)
        detailStack.addArrangedSubview(editorSection)

        let historySection = section(title: copy(.historySection), subtitle: copy(.historySectionHelp))
        configureNumericField(scrollbackField, stepper: scrollbackStepper, minimum: Double(SettingsDefaults.minimumScrollbackRows), maximum: Double(SettingsDefaults.maximumScrollbackRows), increment: 1_000)
        addRow(
            copy(.scrollback),
            control: numericControl(field: scrollbackField, stepper: scrollbackStepper, suffix: copy(.lines)),
            to: historySection
        )
        commandHistoryCheckbox.title = copy(.commandHistoryCheckboxTitle)
        addRow(copy(.commandHistory), control: commandHistoryCheckbox, to: historySection)
        agentSessionIndexCheckbox.title = copy(.agentSessionIndexCheckboxTitle)
        addRow(copy(.agentSessionIndex), control: agentSessionIndexCheckbox, to: historySection)
        restoreScrollbackCheckbox.title = copy(.restoreScrollbackCheckboxTitle)
        addRow(copy(.restoreScrollback), control: restoreScrollbackCheckbox, to: historySection)
        agentStatusHooksCheckbox.title = copy(.agentStatusHooksCheckboxTitle)
        addRow(copy(.agentStatusHooks), control: agentStatusHooksCheckbox, to: historySection)
        detailStack.addArrangedSubview(historySection)

        let quickCommandsSection = section(
            title: copy(.quickCommandsSection),
            subtitle: copy(.quickCommandsSectionHelp)
        )
        quickCommandsButton.title = copy(.quickCommandsButtonTitle)
        stylePrimaryButton(quickCommandsButton)
        // One primary action per pane, bottom-right of the last card. Every
        // other control in Preferences is a setting, not an action.
        quickCommandsSection.addArrangedSubview(trailingActionRow(quickCommandsButton))
        // An action is not a hideable row, so its title is a keyword: the card
        // is found by it and stays whole.
        search.registerKeyword(quickCommandsButton.title, in: quickCommandsSection)
        detailStack.addArrangedSubview(quickCommandsSection)
    }

    func buildAppearancePage() {
        addPageHeader(copy(.appearanceTitle), subtitle: copy(.appearanceSubtitle))

        let themeSection = section(title: copy(.themeSection), subtitle: copy(.themeSectionHelp))
        themePopup.removeAllItems()
        themePopup.addItems(withTitles: PreferencesThemePopup.entries.map { copy($0.copyKey) })
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        addRow(copy(.theme), control: themePopup, to: themeSection)
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.heightAnchor.constraint(equalToConstant: Layout.previewHeightPX).isActive = true
        previewView.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX - Layout.cardPaddingPX * 2).isActive = true
        themeSection.addArrangedSubview(previewView)
        // The Appearance pane's single primary action, mirroring the Quick
        // Commands editor button on the Terminal pane: everything else in the
        // card is a setting.
        importThemeButton.title = copy(.importThemeButtonTitle)
        stylePrimaryButton(importThemeButton)
        themeSection.addArrangedSubview(trailingActionRow(importThemeButton))
        // An action is not a hideable row, so its title is a keyword: the card
        // is found by it and stays whole.
        search.registerKeyword(importThemeButton.title, in: themeSection)
        detailStack.addArrangedSubview(themeSection)

        configureCustomColors()
        detailStack.addArrangedSubview(customColorsStack)
    }

    func buildWindowPage() {
        addPageHeader(copy(.windowTitle), subtitle: copy(.windowSubtitle))

        let sizeSection = section(title: copy(.windowSizeSection), subtitle: copy(.windowSizeHelp))
        configureNumericField(windowWidthField, stepper: windowWidthStepper, minimum: SettingsDefaults.minimumWindowWidthPX, maximum: SettingsDefaults.maximumWindowWidthPX, increment: 20)
        configureNumericField(windowHeightField, stepper: windowHeightStepper, minimum: SettingsDefaults.minimumWindowHeightPX, maximum: SettingsDefaults.maximumWindowHeightPX, increment: 20)
        addRow(
            copy(.width),
            control: numericControl(field: windowWidthField, stepper: windowWidthStepper, suffix: "px"),
            to: sizeSection
        )
        addRow(
            copy(.height),
            control: numericControl(field: windowHeightField, stepper: windowHeightStepper, suffix: "px"),
            to: sizeSection
        )
        detailStack.addArrangedSubview(sizeSection)
    }

    func configureCustomColors() {
        customColorsStack.arrangedSubviews.forEach {
            customColorsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        customColorsStack.orientation = .vertical
        customColorsStack.alignment = .leading
        customColorsStack.spacing = Layout.rowSpacingPX
        customColorsStack.edgeInsets = NSEdgeInsets(
            top: Layout.cardPaddingPX,
            left: Layout.cardPaddingPX,
            bottom: Layout.cardPaddingPX,
            right: Layout.cardPaddingPX
        )
        styleAsCard(customColorsStack)
        customColorsStack.translatesAutoresizingMaskIntoConstraints = false
        customColorsStack.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX).isActive = true
        // The palette is a grid of wells, not a row list, so every color name is
        // a keyword: searching "cursor" or "red" opens the card whole rather
        // than tearing one well out of the grid.
        search.registerCard(
            customColorsStack,
            title: copy(.customColors),
            isAvailable: { [weak self] in self?.isCustomPaletteAvailable ?? false }
        )

        let heading = sectionHeading(copy(.customColors), subtitle: copy(.customColorsHelp))
        heading.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX - Layout.cardPaddingPX * 2).isActive = true
        customColorsStack.addArrangedSubview(heading)

        configureColorWell(foregroundWell, tag: 0)
        configureColorWell(backgroundWell, tag: 1)
        configureColorWell(cursorWell, tag: 2)
        let primaryColors = NSStackView(views: [
            labeledColorWell(copy(.foreground), well: foregroundWell),
            labeledColorWell(copy(.background), well: backgroundWell),
            labeledColorWell(copy(.cursor), well: cursorWell),
        ])
        for name in [copy(.foreground), copy(.background), copy(.cursor), copy(.ansiPalette)] {
            search.registerKeyword(name, in: customColorsStack)
        }
        primaryColors.orientation = .horizontal
        primaryColors.spacing = DesignTokens.Space.x6PX
        customColorsStack.addArrangedSubview(primaryColors)

        let ansiTitle = NSTextField(labelWithString: copy(.ansiPalette))
        ansiTitle.font = DesignTokens.Typography.prefsSection.font
        ansiTitle.textColor = chromeTheme.textPrimary
        customColorsStack.addArrangedSubview(ansiTitle)

        ansiWells = (0..<TerminalColorSettings.requiredAnsiColorCount).map { index in
            let well = NSColorWell()
            configureColorWell(well, tag: 100 + index)
            return well
        }
        let ansiControls = ansiWells.enumerated().map { index, well in
            let name = PreferencesCopy.ansiColorName(index, language: AppLocalization.language)
            search.registerKeyword(name, in: customColorsStack)
            return labeledColorWell(name, well: well)
        }
        let ansiGrid = NSGridView(views: stride(from: 0, to: ansiControls.count, by: Layout.ansiColumnCount).map { start in
            Array(ansiControls[start..<min(start + Layout.ansiColumnCount, ansiControls.count)])
        })
        ansiGrid.rowSpacing = DesignTokens.Space.x3PX
        ansiGrid.columnSpacing = DesignTokens.Space.x3PX
        customColorsStack.addArrangedSubview(ansiGrid)
    }

    private func availableMonospacedFonts() -> [String] {
        let candidates = [settings.terminal.fontName, "Menlo", "Monaco", "SF Mono", "Courier", "Courier New"]
        return Array(Set(candidates.filter { NSFont(name: $0, size: 13) != nil })).sorted()
    }
}
