import AppKit
import KurottyCore

@MainActor
final class PreferencesView: NSView, NSTextFieldDelegate {
    enum Layout {
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
    var settings = AppSettings.default
    private var autosaveWorkItem: DispatchWorkItem?
    private var isUpdatingControls = false
    private var selectedCategory = PreferencesCategory.terminal
    /// Buttons whose size constraints are already installed. Pages are rebuilt
    /// on every category switch, but the controls themselves are long-lived.
    var sizedButtons = Set<ObjectIdentifier>()

    lazy var search = PreferencesSearchController(
        contentWidthPX: Layout.contentWidthPX,
        placeholder: { PreferencesCopy.string(.searchPlaceholder, language: AppLocalization.language) },
        noResultsFormat: { PreferencesCopy.string(.searchNoResults, language: AppLocalization.language) }
    )

    private lazy var categoryStack = NSStackView()
    private lazy var detailScrollView = NSScrollView()
    lazy var detailStack = NSStackView()
    private lazy var statusLabel = NSTextField(labelWithString: "")

    lazy var workingDirectoryField = NSTextField()
    lazy var fontPopup = NSPopUpButton()
    lazy var fontSizeField = NSTextField()
    lazy var fontSizeStepper = NSStepper()
    lazy var codeEditorFontSizeField = NSTextField()
    lazy var codeEditorFontSizeStepper = NSStepper()
    lazy var codeEditorWrapCheckbox = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    lazy var scrollbackField = NSTextField()
    lazy var scrollbackStepper = NSStepper()
    lazy var commandHistoryCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(commandHistoryToggled(_:))
    )
    lazy var confirmMultilinePasteCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(confirmMultilinePasteToggled(_:))
    )
    lazy var agentSessionIndexCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(agentSessionIndexToggled(_:))
    )
    lazy var hideMouseCursorCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(hideMouseCursorToggled(_:))
    )
    lazy var perProjectHistoryCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(perProjectHistoryToggled(_:))
    )
    lazy var agentStatusHooksCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(agentStatusHooksToggled(_:))
    )
    lazy var restoreScrollbackCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(restoreScrollbackToggled(_:))
    )
    lazy var statusBarCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(statusBarToggled(_:))
    )
    lazy var quickCommandsButton = NSButton(
        title: "",
        target: self,
        action: #selector(openQuickCommandsEditor(_:))
    )
    lazy var themePopup = NSPopUpButton()
    lazy var customColorsStack = NSStackView()
    lazy var previewView = PreferencesThemePreviewView()
    lazy var foregroundWell = NSColorWell()
    lazy var backgroundWell = NSColorWell()
    lazy var cursorWell = NSColorWell()
    var ansiWells: [NSColorWell] = []
    lazy var windowWidthField = NSTextField()
    lazy var windowWidthStepper = NSStepper()
    lazy var windowHeightField = NSTextField()
    lazy var windowHeightStepper = NSStepper()

    init(frame frameRect: NSRect, store: AppSettingsStore = .shared) {
        self.store = store
        super.init(frame: frameRect)
        configure()
        reloadFromDisk()
        // The chrome theme is derived from the settings that were just read, so
        // the window shell has to be repainted here: `configure()` had nothing
        // but the defaults to paint with, which left a light-theme settings
        // window on a dark canvas.
        applyChromeTheme()
        indexEveryPane()
    }

    override init(frame frameRect: NSRect) {
        store = .shared
        super.init(frame: frameRect)
        configure()
        reloadFromDisk()
        // The chrome theme is derived from the settings that were just read, so
        // the window shell has to be repainted here: `configure()` had nothing
        // but the defaults to paint with, which left a light-theme settings
        // window on a dark canvas.
        applyChromeTheme()
        indexEveryPane()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Chrome theme in effect for the settings window. Preferences used to paint
    /// its cards with the generic system control background regardless of the
    /// terminal theme, which is why it was the one surface that never matched
    /// the rest of the app.
    var chromeTheme: DesignTokens.ChromeTheme {
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
        search.applyChromeTheme(theme)
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

        configureSearchField()

        for category in PreferencesCategory.allCases {
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

    /// The query field sits above the category list, at the category buttons'
    /// width: searching is a way into the list, not a fourth category.
    private func configureSearchField() {
        search.onCategoryRequested = { [weak self] category in
            self?.selectCategory(category)
        }
        let queryField = search.queryField
        categoryStack.addArrangedSubview(queryField)
        queryField.widthAnchor.constraint(
            equalToConstant: Layout.sidebarWidthPX - Layout.categoryListTrailingInsetPX
        ).isActive = true
        categoryStack.setCustomSpacing(
            DesignTokens.Component.preferencesSearchFieldBottomGapPX,
            after: queryField
        )
    }

    /// Builds each pane once at open so search can reach a setting in a pane the
    /// user has never selected. The panes are rebuilt on every switch anyway, so
    /// this costs one extra build each and keeps the builders as the only place
    /// that knows which settings exist.
    private func indexEveryPane() {
        for category in PreferencesCategory.allCases {
            selectCategory(category)
        }
        selectCategory(.terminal)
    }

    /// Cmd+F reaches the key window's responder chain before it reaches the app
    /// delegate's terminal search, so in the Settings window "find" means find a
    /// setting.
    @objc func findTerminalOutput() {
        search.focusQueryField()
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
        guard let category = PreferencesCategory(rawValue: sender.tag) else { return }
        selectCategory(category)
    }

    private func selectCategory(_ category: PreferencesCategory) {
        selectedCategory = category
        for case let button as NSButton in categoryStack.arrangedSubviews {
            button.state = button.tag == category.rawValue ? .on : .off
        }
        detailStack.arrangedSubviews.forEach {
            detailStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        search.beginRecording(category)
        switch category {
        case .terminal:
            buildTerminalPage()
        case .appearance:
            buildAppearancePage()
        case .window:
            buildWindowPage()
        }
        detailStack.addArrangedSubview(search.emptyStateView)
        search.endRecording()
        // `syncControlsFromSettings` re-applies the filter, so the rebuilt pane
        // never appears unfiltered while a query is active.
        syncControlsFromSettings()
        detailScrollView.contentView.scroll(to: .zero)
        detailScrollView.reflectScrolledClipView(detailScrollView.contentView)
    }

    @objc func themeChanged(_ sender: NSPopUpButton) {
        guard !isUpdatingControls else { return }
        let themeName = PreferencesThemePopup.presetName(atIndex: sender.indexOfSelectedItem)
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

    @objc func colorChanged(_ sender: NSColorWell) {
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

    @objc func fontChanged(_ sender: NSPopUpButton) {
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

    @objc func openQuickCommandsEditor(_ sender: NSButton) {
        QuickCommandsEditorPresenter.presentQuickCommandsEditor()
    }

    @objc func textFieldChanged(_ sender: NSTextField) {
        guard !isUpdatingControls else { return }
        applyTextFieldsToSettings()
        syncControlsFromSettings()
        scheduleAutosave()
    }

    @objc func stepperChanged(_ sender: NSStepper) {
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

        themePopup.selectItem(
            at: PreferencesThemePopup.index(
                ofPresetName: TerminalThemePreset.canonicalName(settings.terminal.theme)
            )
        )
        foregroundWell.color = NSColor(hexRGB: settings.terminal.colors.foreground) ?? .textColor
        backgroundWell.color = NSColor(hexRGB: settings.terminal.colors.background) ?? .textBackgroundColor
        cursorWell.color = NSColor(hexRGB: settings.terminal.colors.cursor) ?? .controlAccentColor
        for (index, well) in ansiWells.enumerated() where settings.terminal.colors.ansi.indices.contains(index) {
            well.color = NSColor(hexRGB: settings.terminal.colors.ansi[index]) ?? .gray
        }
        previewView.colors = settings.terminal.colors
        // The custom palette card is gated by the selected theme and by the
        // active query. One owner decides its `isHidden` so the two rules cannot
        // fight: the filter reads the gate through `isCustomPaletteAvailable`.
        search.applyFilter()
    }

    /// The custom palette is editable only while the custom theme is selected.
    var isCustomPaletteAvailable: Bool {
        settings.terminal.theme == TerminalThemePreset.customName
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

    private func title(for category: PreferencesCategory) -> String {
        switch category {
        case .terminal: return copy(.terminalCategory)
        case .appearance: return copy(.appearanceCategory)
        case .window: return copy(.windowCategory)
        }
    }

    func copy(_ key: PreferencesCopy.Key) -> String {
        PreferencesCopy.string(key, language: AppLocalization.language)
    }

    // MARK: Test hooks

    var selectedCategoryForTesting: PreferencesCategory { selectedCategory }

    /// Types a query the way the sidebar field does, including the pane switch
    /// and the visibility pass it triggers.
    func applySearchQueryForTesting(_ query: String) {
        search.query = query
    }

    var visibleCardTitlesForTesting: [String] { search.visibleCardTitlesForTesting }

    var visibleRowLabelsForTesting: [String] { search.visibleRowLabelsForTesting }

    var searchFieldIsFocusedForTesting: Bool { search.isQueryFieldFocusedForTesting }

    var searchEmptyStateIsVisibleForTesting: Bool { search.isEmptyStateVisibleForTesting }

    var searchEmptyStateMessageForTesting: String { search.emptyStateMessageForTesting }

    var searchIndexForTesting: PreferencesSearchIndex { search.indexForTesting }
}

/// Single source of the theme popup's order. The popup titles, the
/// index-to-preset mapping on selection, and the preset-to-index mapping on
/// sync all derive from this list, so adding a selectable preset is one entry
/// here (plus its copy key and `TerminalThemePreset` colors) instead of three
/// coordinated switch edits.
enum PreferencesThemePopup {
    struct Entry {
        let presetName: String
        let copyKey: PreferencesCopy.Key
    }

    /// Custom stays last: it is the fallback for any stored theme name that
    /// is not a selectable preset.
    static let entries: [Entry] = [
        Entry(presetName: TerminalThemePreset.kurottyName, copyKey: .themeKurotty),
        Entry(presetName: TerminalThemePreset.lighttyName, copyKey: .themeLightty),
        Entry(presetName: TerminalThemePreset.customName, copyKey: .themeCustom),
    ]

    static func presetName(atIndex index: Int) -> String {
        guard entries.indices.contains(index) else {
            return TerminalThemePreset.customName
        }
        return entries[index].presetName
    }

    static func index(ofPresetName name: String) -> Int {
        entries.firstIndex { $0.presetName == name } ?? entries.count - 1
    }
}

private final class FlippedPreferencesDocumentView: NSView {
    override var isFlipped: Bool { true }
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
