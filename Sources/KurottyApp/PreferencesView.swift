import AppKit
import KurottyCore

@MainActor
final class PreferencesView: NSView, NSTextFieldDelegate {
    private enum Category: Int, CaseIterable {
        case terminal
        case appearance
        case window
    }

    private enum Layout {
        static let sidebarWidthPX = DesignTokens.Component.preferencesSidebarWidthPX
        /// The window minus the category sidebar minus the outer inset on both
        /// sides. Cards fill this width exactly so their left edges line up with
        /// the pane heading above them.
        static let contentWidthPX = DesignTokens.Component.preferencesWidthPX
            - DesignTokens.Component.preferencesSidebarWidthPX
            - DesignTokens.Space.x6PX * 2
        static let outerInsetPX = DesignTokens.Space.x6PX
        static let categoryListLeadingPX = DesignTokens.Space.x4PX
        static let categoryListTopPX = DesignTokens.Space.x5PX
        static let sectionSpacingPX = DesignTokens.Space.x5PX
        static let cardPaddingPX = DesignTokens.Space.x5PX
        static let rowSpacingPX = DesignTokens.Space.x3PX
        static let labelWidthPX: CGFloat = 150
        static let labelControlGapPX = DesignTokens.Space.x4PX
        /// What is left inside a card once the right-aligned label column and
        /// its gap are taken.
        static let controlColumnWidthPX = contentWidthPX
            - cardPaddingPX * 2
            - labelWidthPX
            - labelControlGapPX
        static let fieldWidthPX = DesignTokens.Component.preferencesControlWidthPX
        static let previewHeightPX: CGFloat = 176
        static let colorWellSizePX: CGFloat = 34
        static let categoryButtonHeightPX: CGFloat = 32
        static let categoryListTrailingInsetPX: CGFloat = 28
        static let ansiColumnCount = 4
    }

    private static let autosaveDelay: TimeInterval = 0.25

    private let store: AppSettingsStore
    private var settings = AppSettings.default
    private var autosaveWorkItem: DispatchWorkItem?
    private var isUpdatingControls = false
    private var selectedCategory = Category.terminal
    /// Buttons whose size constraints are already installed. Pages are rebuilt
    /// on every category switch, but the controls themselves are long-lived.
    private var sizedButtons = Set<ObjectIdentifier>()

    private lazy var categoryStack = NSStackView()
    private lazy var detailScrollView = NSScrollView()
    private lazy var detailStack = NSStackView()
    private lazy var statusLabel = NSTextField(labelWithString: "")

    private lazy var workingDirectoryField = NSTextField()
    private lazy var fontPopup = NSPopUpButton()
    private lazy var fontSizeField = NSTextField()
    private lazy var fontSizeStepper = NSStepper()
    private lazy var codeEditorFontSizeField = NSTextField()
    private lazy var codeEditorFontSizeStepper = NSStepper()
    private lazy var codeEditorWrapCheckbox = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    private lazy var scrollbackField = NSTextField()
    private lazy var scrollbackStepper = NSStepper()
    private lazy var commandHistoryCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(commandHistoryToggled(_:))
    )
    private lazy var confirmMultilinePasteCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(confirmMultilinePasteToggled(_:))
    )
    private lazy var agentSessionIndexCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(agentSessionIndexToggled(_:))
    )
    private lazy var hideMouseCursorCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(hideMouseCursorToggled(_:))
    )
    private lazy var perProjectHistoryCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(perProjectHistoryToggled(_:))
    )
    private lazy var agentStatusHooksCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(agentStatusHooksToggled(_:))
    )
    private lazy var restoreScrollbackCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(restoreScrollbackToggled(_:))
    )
    private lazy var statusBarCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(statusBarToggled(_:))
    )
    private lazy var quickCommandsButton = NSButton(
        title: "",
        target: self,
        action: #selector(openQuickCommandsEditor(_:))
    )
    private lazy var themePopup = NSPopUpButton()
    private lazy var customColorsStack = NSStackView()
    private lazy var previewView = PreferencesThemePreviewView()
    private lazy var foregroundWell = NSColorWell()
    private lazy var backgroundWell = NSColorWell()
    private lazy var cursorWell = NSColorWell()
    private var ansiWells: [NSColorWell] = []
    private lazy var windowWidthField = NSTextField()
    private lazy var windowWidthStepper = NSStepper()
    private lazy var windowHeightField = NSTextField()
    private lazy var windowHeightStepper = NSStepper()

    init(frame frameRect: NSRect, store: AppSettingsStore = .shared) {
        self.store = store
        super.init(frame: frameRect)
        configure()
        reloadFromDisk()
        selectCategory(.terminal)
    }

    override init(frame frameRect: NSRect) {
        store = .shared
        super.init(frame: frameRect)
        configure()
        reloadFromDisk()
        selectCategory(.terminal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Chrome theme in effect for the settings window. Preferences used to paint
    /// its cards with the generic system control background regardless of the
    /// terminal theme, which is why it was the one surface that never matched
    /// the rest of the app.
    private var chromeTheme: DesignTokens.ChromeTheme {
        DesignTokens.ChromeTheme.theme(for: settings)
    }

    private func configure() {
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))

        configureSidebar()
        configureDetailArea()
        configureStatusBar()

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(categoryStack)
        addSubview(divider)
        addSubview(detailScrollView)
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            categoryStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.categoryListLeadingPX),
            categoryStack.topAnchor.constraint(equalTo: topAnchor, constant: Layout.categoryListTopPX),
            categoryStack.widthAnchor.constraint(equalToConstant: Layout.sidebarWidthPX - Layout.categoryListTrailingInsetPX),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.sidebarWidthPX),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),

            detailScrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailScrollView.topAnchor.constraint(equalTo: topAnchor),
            detailScrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -DesignTokens.Space.x3PX),

            statusLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: Layout.outerInsetPX),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.outerInsetPX),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Space.x4PX),
            statusLabel.heightAnchor.constraint(equalToConstant: DesignTokens.Component.preferencesStatusHeightPX),
        ])
        applyChromeTheme()
    }

    /// Repaints the window shell, the cards, and the system controls for the
    /// active terminal theme. Called on load and after every save so a theme
    /// change in the Appearance pane is reflected immediately.
    private func applyChromeTheme() {
        let theme = chromeTheme
        appearance = theme.windowAppearance
        layer?.backgroundColor = theme.surfaceCanvas.cgColor
        statusLabel.textColor = theme.textTertiary
    }

    private func configureSidebar() {
        categoryStack.orientation = .vertical
        categoryStack.alignment = .leading
        categoryStack.spacing = DesignTokens.Space.x1PX
        categoryStack.translatesAutoresizingMaskIntoConstraints = false

        let headingLabel = NSTextField(labelWithString: copy(.settingsTitle))
        headingLabel.font = DesignTokens.Typography.prefsTitle.font
        categoryStack.addArrangedSubview(headingLabel)
        categoryStack.setCustomSpacing(Layout.sectionSpacingPX, after: headingLabel)

        for category in Category.allCases {
            let button = NSButton(title: title(for: category), target: self, action: #selector(categorySelected(_:)))
            button.tag = category.rawValue
            button.bezelStyle = .recessed
            button.alignment = .left
            button.setButtonType(.toggle)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(
                equalToConstant: Layout.sidebarWidthPX - Layout.categoryListTrailingInsetPX
            ).isActive = true
            button.heightAnchor.constraint(equalToConstant: Layout.categoryButtonHeightPX).isActive = true
            categoryStack.addArrangedSubview(button)
        }
    }

    private func configureDetailArea() {
        detailScrollView.hasVerticalScroller = true
        detailScrollView.drawsBackground = false
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = Layout.sectionSpacingPX
        detailStack.edgeInsets = NSEdgeInsets(
            top: Layout.outerInsetPX,
            left: Layout.outerInsetPX,
            bottom: Layout.outerInsetPX,
            right: Layout.outerInsetPX
        )
        detailStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedPreferencesDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(detailStack)
        detailScrollView.documentView = documentView

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: detailScrollView.contentView.heightAnchor),
            detailStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            detailStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            detailStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor),
        ])
    }

    private func configureStatusBar() {
        statusLabel.font = DesignTokens.Typography.prefsCaption.font
        statusLabel.textColor = chromeTheme.textTertiary
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func categorySelected(_ sender: NSButton) {
        guard let category = Category(rawValue: sender.tag) else { return }
        selectCategory(category)
    }

    private func selectCategory(_ category: Category) {
        selectedCategory = category
        for case let button as NSButton in categoryStack.arrangedSubviews {
            button.state = button.tag == category.rawValue ? .on : .off
        }
        detailStack.arrangedSubviews.forEach {
            detailStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        switch category {
        case .terminal:
            buildTerminalPage()
        case .appearance:
            buildAppearancePage()
        case .window:
            buildWindowPage()
        }
        syncControlsFromSettings()
        detailScrollView.contentView.scroll(to: .zero)
        detailScrollView.reflectScrolledClipView(detailScrollView.contentView)
    }

    private func buildTerminalPage() {
        addPageHeader(copy(.terminalTitle), subtitle: copy(.terminalSubtitle))

        let shellSection = section(title: copy(.shellSection), subtitle: copy(.shellSectionHelp))
        shellSection.addArrangedSubview(row(label: copy(.workingDirectory), control: workingDirectoryField))
        configureTextField(workingDirectoryField, action: #selector(textFieldChanged(_:)))
        perProjectHistoryCheckbox.title = copy(.perProjectHistoryCheckboxTitle)
        shellSection.addArrangedSubview(row(label: copy(.perProjectHistory), control: perProjectHistoryCheckbox))
        detailStack.addArrangedSubview(shellSection)

        let textSection = section(title: copy(.textSection), subtitle: copy(.textSectionHelp))
        fontPopup.removeAllItems()
        fontPopup.addItems(withTitles: availableMonospacedFonts())
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        textSection.addArrangedSubview(row(label: copy(.font), control: fontPopup))
        configureNumericField(fontSizeField, stepper: fontSizeStepper, minimum: SettingsDefaults.minimumTerminalFontSizePT, maximum: SettingsDefaults.maximumTerminalFontSizePT, increment: 1)
        textSection.addArrangedSubview(row(label: copy(.fontSize), control: numericControl(field: fontSizeField, stepper: fontSizeStepper, suffix: "pt")))
        hideMouseCursorCheckbox.title = copy(.hideMouseCursorCheckboxTitle)
        textSection.addArrangedSubview(row(label: copy(.hideMouseCursor), control: hideMouseCursorCheckbox))
        confirmMultilinePasteCheckbox.title = copy(.confirmMultilinePasteCheckboxTitle)
        textSection.addArrangedSubview(row(label: copy(.confirmMultilinePaste), control: confirmMultilinePasteCheckbox))
        statusBarCheckbox.title = copy(.statusBarCheckboxTitle)
        textSection.addArrangedSubview(row(label: copy(.statusBar), control: statusBarCheckbox))
        detailStack.addArrangedSubview(textSection)

        let editorSection = section(title: copy(.editorSection), subtitle: copy(.editorSectionHelp))
        configureNumericField(
            codeEditorFontSizeField,
            stepper: codeEditorFontSizeStepper,
            minimum: SettingsDefaults.minimumCodeEditorFontSizePT,
            maximum: SettingsDefaults.maximumCodeEditorFontSizePT,
            increment: 1
        )
        editorSection.addArrangedSubview(row(
            label: copy(.editorFontSize),
            control: numericControl(field: codeEditorFontSizeField, stepper: codeEditorFontSizeStepper, suffix: "pt")
        ))
        codeEditorWrapCheckbox.title = copy(.editorWrapCheckboxTitle)
        editorSection.addArrangedSubview(row(label: copy(.editorWrap), control: codeEditorWrapCheckbox))
        detailStack.addArrangedSubview(editorSection)

        let historySection = section(title: copy(.historySection), subtitle: copy(.historySectionHelp))
        configureNumericField(scrollbackField, stepper: scrollbackStepper, minimum: Double(SettingsDefaults.minimumScrollbackRows), maximum: Double(SettingsDefaults.maximumScrollbackRows), increment: 1_000)
        historySection.addArrangedSubview(row(label: copy(.scrollback), control: numericControl(field: scrollbackField, stepper: scrollbackStepper, suffix: copy(.lines))))
        commandHistoryCheckbox.title = copy(.commandHistoryCheckboxTitle)
        historySection.addArrangedSubview(row(label: copy(.commandHistory), control: commandHistoryCheckbox))
        agentSessionIndexCheckbox.title = copy(.agentSessionIndexCheckboxTitle)
        historySection.addArrangedSubview(row(label: copy(.agentSessionIndex), control: agentSessionIndexCheckbox))
        restoreScrollbackCheckbox.title = copy(.restoreScrollbackCheckboxTitle)
        historySection.addArrangedSubview(row(label: copy(.restoreScrollback), control: restoreScrollbackCheckbox))
        agentStatusHooksCheckbox.title = copy(.agentStatusHooksCheckboxTitle)
        historySection.addArrangedSubview(row(label: copy(.agentStatusHooks), control: agentStatusHooksCheckbox))
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
        detailStack.addArrangedSubview(quickCommandsSection)
    }

    private func buildAppearancePage() {
        addPageHeader(copy(.appearanceTitle), subtitle: copy(.appearanceSubtitle))

        let themeSection = section(title: copy(.themeSection), subtitle: copy(.themeSectionHelp))
        themePopup.removeAllItems()
        themePopup.addItems(withTitles: [copy(.themeKurotty), copy(.themeLightty), copy(.themeCustom)])
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        themeSection.addArrangedSubview(row(label: copy(.theme), control: themePopup))
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.heightAnchor.constraint(equalToConstant: Layout.previewHeightPX).isActive = true
        previewView.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX - Layout.cardPaddingPX * 2).isActive = true
        themeSection.addArrangedSubview(previewView)
        detailStack.addArrangedSubview(themeSection)

        configureCustomColors()
        detailStack.addArrangedSubview(customColorsStack)
    }

    private func buildWindowPage() {
        addPageHeader(copy(.windowTitle), subtitle: copy(.windowSubtitle))

        let sizeSection = section(title: copy(.windowSizeSection), subtitle: copy(.windowSizeHelp))
        configureNumericField(windowWidthField, stepper: windowWidthStepper, minimum: SettingsDefaults.minimumWindowWidthPX, maximum: SettingsDefaults.maximumWindowWidthPX, increment: 20)
        configureNumericField(windowHeightField, stepper: windowHeightStepper, minimum: SettingsDefaults.minimumWindowHeightPX, maximum: SettingsDefaults.maximumWindowHeightPX, increment: 20)
        sizeSection.addArrangedSubview(row(label: copy(.width), control: numericControl(field: windowWidthField, stepper: windowWidthStepper, suffix: "px")))
        sizeSection.addArrangedSubview(row(label: copy(.height), control: numericControl(field: windowHeightField, stepper: windowHeightStepper, suffix: "px")))
        detailStack.addArrangedSubview(sizeSection)
    }

    private func configureCustomColors() {
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
            labeledColorWell(PreferencesCopy.ansiColorName(index, language: AppLocalization.language), well: well)
        }
        let ansiGrid = NSGridView(views: stride(from: 0, to: ansiControls.count, by: Layout.ansiColumnCount).map { start in
            Array(ansiControls[start..<min(start + Layout.ansiColumnCount, ansiControls.count)])
        })
        ansiGrid.rowSpacing = DesignTokens.Space.x3PX
        ansiGrid.columnSpacing = DesignTokens.Space.x3PX
        customColorsStack.addArrangedSubview(ansiGrid)
    }

    private func addPageHeader(_ title: String, subtitle: String) {
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
    private func section(title: String, subtitle: String) -> NSStackView {
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
        return stack
    }

    private func styleAsCard(_ view: NSView) {
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

    private func sectionHeading(_ title: String, subtitle: String) -> NSStackView {
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
    private func trailingActionRow(_ control: NSView) -> NSStackView {
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
    private func stylePrimaryButton(_ button: NSButton) {
        styleButtonMetrics(button)
        button.bezelColor = chromeTheme.accent
    }

    /// Every other button in Preferences is the recessed category list, which is
    /// a selection control rather than an action, so there is no second bezel
    /// style to define here yet.
    private func styleButtonMetrics(_ button: NSButton) {
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

    private func numericControl(field: NSTextField, stepper: NSStepper, suffix: String) -> NSStackView {
        let suffixLabel = NSTextField(labelWithString: suffix)
        suffixLabel.font = DesignTokens.Typography.prefsCaption.font
        suffixLabel.textColor = chromeTheme.textTertiary
        let stack = NSStackView(views: [field, stepper, suffixLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DesignTokens.Space.x2PX
        return stack
    }

    private func labeledColorWell(_ title: String, well: NSColorWell) -> NSStackView {
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

    private func configureTextField(_ field: NSTextField, action: Selector) {
        field.delegate = self
        field.target = self
        field.action = action
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Layout.fieldWidthPX).isActive = true
    }

    private func configureNumericField(_ field: NSTextField, stepper: NSStepper, minimum: Double, maximum: Double, increment: Double) {
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

    private func configureColorWell(_ well: NSColorWell, tag: Int) {
        well.tag = tag
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: Layout.colorWellSizePX).isActive = true
        well.heightAnchor.constraint(equalToConstant: Layout.colorWellSizePX).isActive = true
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard !isUpdatingControls else { return }
        let themeName: String
        switch sender.indexOfSelectedItem {
        case 0: themeName = TerminalThemePreset.kurottyName
        case 1: themeName = TerminalThemePreset.lighttyName
        default: themeName = TerminalThemePreset.customName
        }
        settings.terminal.theme = themeName
        if let colors = TerminalThemePreset.colors(named: themeName) {
            settings.terminal.colors = colors
        }
        applyChromeTheme()
        // The cards take their fill from the chrome theme, so a preset switch
        // has to rebuild the pane. Instant, never a transition.
        selectCategory(selectedCategory)
        scheduleAutosave()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard !isUpdatingControls else { return }
        let hex = sender.color.hexRGB
        switch sender.tag {
        case 0: settings.terminal.colors.foreground = hex
        case 1: settings.terminal.colors.background = hex
        case 2: settings.terminal.colors.cursor = hex
        case 100...115: settings.terminal.colors.ansi[sender.tag - 100] = hex
        default: return
        }
        settings.terminal.theme = TerminalThemePreset.customName
        syncControlsFromSettings()
        scheduleAutosave()
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        guard !isUpdatingControls, let title = sender.titleOfSelectedItem else { return }
        settings.terminal.fontName = title
        scheduleAutosave()
    }

    @objc private func commandHistoryToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.commandHistoryEnabled = sender.state == .on
        scheduleAutosave()
    }

    /// Launch-only: the new value is stored now and read the next time a
    /// workspace is restored. Nothing is replayed into open panes.
    @objc private func restoreScrollbackToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.restoreScrollbackOnLaunch = sender.state == .on
        scheduleAutosave()
    }

    /// Live-applied: open windows collapse or restore the bar as soon as the
    /// settings change lands, and a collapsed bar stops sampling entirely.
    @objc private func statusBarToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.statusBarEnabled = sender.state == .on
        scheduleAutosave()
    }

    @objc private func confirmMultilinePasteToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.confirmMultilinePaste = sender.state == .on
        scheduleAutosave()
    }

    @objc private func agentSessionIndexToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.agentSessionIndexEnabled = sender.state == .on
        scheduleAutosave()
    }

    @objc private func hideMouseCursorToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.hideMouseCursorWhileTyping = sender.state == .on
        scheduleAutosave()
    }

    @objc private func perProjectHistoryToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.shell.perProjectHistoryEnabled = sender.state == .on
        scheduleAutosave()
    }

    @objc private func agentStatusHooksToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.agentStatusHooksEnabled = sender.state == .on
        scheduleAutosave()
    }

    @objc private func openQuickCommandsEditor(_ sender: NSButton) {
        QuickCommandsEditorPresenter.presentQuickCommandsEditor()
    }

    @objc private func textFieldChanged(_ sender: NSTextField) {
        guard !isUpdatingControls else { return }
        applyTextFieldsToSettings()
        syncControlsFromSettings()
        scheduleAutosave()
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        switch sender {
        case fontSizeStepper: fontSizeField.doubleValue = sender.doubleValue
        case scrollbackStepper: scrollbackField.integerValue = sender.integerValue
        case windowWidthStepper: windowWidthField.doubleValue = sender.doubleValue
        case windowHeightStepper: windowHeightField.doubleValue = sender.doubleValue
        default: return
        }
        textFieldChanged(fontSizeField)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        textFieldChanged(field)
    }

    private func applyTextFieldsToSettings() {
        settings.shell.workingDirectory = workingDirectoryField.stringValue
        settings.terminal.fontSize = fontSizeField.doubleValue
        settings.terminal.codeEditorFontSize = codeEditorFontSizeField.doubleValue
        settings.terminal.codeEditorWrapsLines = codeEditorWrapCheckbox.state == .on
        settings.terminal.scrollbackLines = scrollbackField.integerValue
        settings.window.width = windowWidthField.doubleValue
        settings.window.height = windowHeightField.doubleValue
        settings = AppSettingsNormalizer.normalized(settings)
    }

    private func syncControlsFromSettings() {
        isUpdatingControls = true
        defer { isUpdatingControls = false }

        workingDirectoryField.stringValue = settings.shell.workingDirectory
        if fontPopup.itemTitles.contains(settings.terminal.fontName) {
            fontPopup.selectItem(withTitle: settings.terminal.fontName)
        }
        fontSizeField.doubleValue = settings.terminal.fontSize
        fontSizeStepper.doubleValue = settings.terminal.fontSize
        codeEditorFontSizeField.doubleValue = settings.terminal.codeEditorFontSize
        codeEditorFontSizeStepper.doubleValue = settings.terminal.codeEditorFontSize
        codeEditorWrapCheckbox.state = settings.terminal.codeEditorWrapsLines ? .on : .off
        scrollbackField.integerValue = settings.terminal.scrollbackLines
        scrollbackStepper.integerValue = settings.terminal.scrollbackLines
        commandHistoryCheckbox.state = settings.terminal.commandHistoryEnabled ? .on : .off
        confirmMultilinePasteCheckbox.state = settings.terminal.confirmMultilinePaste ? .on : .off
        statusBarCheckbox.state = settings.terminal.statusBarEnabled ? .on : .off
        agentSessionIndexCheckbox.state = settings.terminal.agentSessionIndexEnabled ? .on : .off
        hideMouseCursorCheckbox.state = settings.terminal.hideMouseCursorWhileTyping ? .on : .off
        perProjectHistoryCheckbox.state = settings.shell.perProjectHistoryEnabled ? .on : .off
        agentStatusHooksCheckbox.state = settings.terminal.agentStatusHooksEnabled ? .on : .off
        restoreScrollbackCheckbox.state = settings.terminal.restoreScrollbackOnLaunch ? .on : .off
        windowWidthField.doubleValue = settings.window.width
        windowWidthStepper.doubleValue = settings.window.width
        windowHeightField.doubleValue = settings.window.height
        windowHeightStepper.doubleValue = settings.window.height

        switch TerminalThemePreset.canonicalName(settings.terminal.theme) {
        case TerminalThemePreset.kurottyName: themePopup.selectItem(at: 0)
        case TerminalThemePreset.lighttyName: themePopup.selectItem(at: 1)
        default: themePopup.selectItem(at: 2)
        }
        customColorsStack.isHidden = settings.terminal.theme != TerminalThemePreset.customName
        foregroundWell.color = NSColor(hexRGB: settings.terminal.colors.foreground) ?? .textColor
        backgroundWell.color = NSColor(hexRGB: settings.terminal.colors.background) ?? .textBackgroundColor
        cursorWell.color = NSColor(hexRGB: settings.terminal.colors.cursor) ?? .controlAccentColor
        for (index, well) in ansiWells.enumerated() where settings.terminal.colors.ansi.indices.contains(index) {
            well.color = NSColor(hexRGB: settings.terminal.colors.ansi[index]) ?? .gray
        }
        previewView.colors = settings.terminal.colors
    }

    private func reloadFromDisk() {
        do {
            settings = try store.load()
            setStatus(copy(.loaded))
        } catch {
            settings = .default
            setStatus(String(format: copy(.loadFailed), error.localizedDescription))
        }
    }

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        setStatus(copy(.saving))
        let snapshot = settings
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.save(snapshot)
            }
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDelay, execute: workItem)
    }

    private func save(_ snapshot: AppSettings) {
        do {
            try store.save(snapshot)
            settings = try store.load()
            syncControlsFromSettings()
            applyChromeTheme()
            setStatus(copy(.saved))
        } catch {
            setStatus(String(format: copy(.saveFailed), error.localizedDescription))
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func title(for category: Category) -> String {
        switch category {
        case .terminal: return copy(.terminalCategory)
        case .appearance: return copy(.appearanceCategory)
        case .window: return copy(.windowCategory)
        }
    }

    private func availableMonospacedFonts() -> [String] {
        let candidates = [settings.terminal.fontName, "Menlo", "Monaco", "SF Mono", "Courier", "Courier New"]
        return Array(Set(candidates.filter { NSFont(name: $0, size: 13) != nil })).sorted()
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }

    private func copy(_ key: PreferencesCopy.Key) -> String {
        PreferencesCopy.string(key, language: AppLocalization.language)
    }
}

private final class FlippedPreferencesDocumentView: NSView {
    override var isFlipped: Bool { true }
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

private extension NSColor {
    convenience init?(hexRGB: String) {
        let value = hexRGB.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard value.count == 6, let raw = Int(value, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((raw >> 16) & 0xff) / 255,
            green: CGFloat((raw >> 8) & 0xff) / 255,
            blue: CGFloat(raw & 0xff) / 255,
            alpha: 1
        )
    }

    var hexRGB: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}
