import AppKit
import KurottyCore

@MainActor
final class PreferencesView: NSView, NSTextFieldDelegate {
    /// Aliases onto the tokens the settings surface uses.
    ///
    /// Anything pointing at a scaled token is a `var`, not a `let`: a stored
    /// alias would capture whatever the UI text scale was the first time
    /// Settings was opened and then never move again, which is the whole bug
    /// the computed tokens exist to avoid.
    enum Layout {
        static var navWidthPX: CGFloat { DesignTokens.Component.preferencesSidebarWidthPX }
        static var navRowHeightPX: CGFloat { DesignTokens.Component.preferencesNavRowHeightPX }
        static var navRowWidthPX: CGFloat {
            navWidthPX - DesignTokens.Component.preferencesNavTrailingInsetPX
        }
        static let outerInsetPX = DesignTokens.Space.x6PX
        /// Widest the content column is allowed to get. Cards are elastic
        /// below it — the surface is a tab now, not a fixed 720pt window, so
        /// nothing may assume a width.
        static let contentMaxWidthPX = DesignTokens.Component.preferencesContentMaxWidthPX
        static let sectionSpacingPX = DesignTokens.Space.x5PX
        static let cardPaddingPX = DesignTokens.Space.x5PX
        static let rowSpacingPX = DesignTokens.Space.x3PX
        static var labelWidthPX: CGFloat { DesignTokens.Component.preferencesLabelColumnWidthPX }
        static let labelControlGapPX = DesignTokens.Space.x4PX
        /// What a card's padding, right-aligned label column, and label-control
        /// gap take out of the card's width. Subtracted from the card at layout
        /// time rather than precomputed, because the card no longer has a fixed
        /// width to precompute against.
        static var labelColumnTotalPX: CGFloat {
            cardPaddingPX * 2 + labelWidthPX + labelControlGapPX
        }
        static var fieldWidthPX: CGFloat { DesignTokens.Component.preferencesControlWidthPX }
        static let previewHeightPX = DesignTokens.Component.preferencesThemePreviewHeightPX
        static let colorWellSizePX = DesignTokens.Component.preferencesColorWellSizePX
        static let ansiColumnCount = DesignTokens.Component.preferencesAnsiColumnCount
    }

    private static let autosaveDelay: TimeInterval = 0.25

    private let store: AppSettingsStore
    var settings = AppSettings.default
    private var autosaveWorkItem: DispatchWorkItem?
    private var isUpdatingControls = false
    private var selectedCategory = PreferencesCategory.terminal
    /// The UI text scale the currently built panes were laid out against. A
    /// settings surface is chrome like any other, so it has to rebuild itself
    /// when the scale moves — exactly as it already does for a theme switch.
    private var builtUITextScalePercent = DesignTokens.UIScale.percent
    /// Scaled constants on the long-lived shell: the header bar, the nav
    /// column, the nav rows, and the status line.
    private let metrics = ChromeMetricBindings()
    /// Controls whose size constraints are already installed. Pages are rebuilt
    /// on every category switch, but the controls themselves are long-lived, so
    /// a second build must not stack a second identical constraint on them.
    var sizedControls = Set<ObjectIdentifier>()

    lazy var search = PreferencesSearchController(
        placeholder: { PreferencesCopy.string(.searchPlaceholder, language: AppLocalization.language) },
        noResultsFormat: { PreferencesCopy.string(.searchNoResults, language: AppLocalization.language) }
    )

    private lazy var headerView = NSView()
    private lazy var titleLabel = NSTextField(labelWithString: "")
    private lazy var headerSeparator = NSBox()
    private lazy var navDivider = NSBox()
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
    lazy var confirmCloseCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(confirmCloseToggled(_:))
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
    lazy var commandProgressCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(commandProgressToggled(_:))
    )
    lazy var menuBarExtraCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(menuBarExtraToggled(_:))
    )
    lazy var promptNavigatorRailCheckbox = NSButton(
        checkboxWithTitle: "",
        target: self,
        action: #selector(promptNavigatorRailToggled(_:))
    )
    lazy var quickCommandsButton = NSButton(
        title: "",
        target: self,
        action: #selector(openQuickCommandsEditor(_:))
    )
    lazy var uiTextScaleSlider = NSSlider()
    lazy var uiTextScaleValueLabel = NSTextField(labelWithString: "")
    lazy var themePopup = NSPopUpButton()
    lazy var importThemeButton = NSButton(
        title: "",
        target: self,
        action: #selector(importThemePressed(_:))
    )
    lazy var customColorsStack = NSStackView()
    /// The palette card outlives the pane it sits in, so its column constraint
    /// is retired and reinstalled on every Appearance build.
    var customColorsWidthConstraint: NSLayoutConstraint?
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
        // the surface has to be repainted here: `configure()` had nothing but
        // the defaults to paint with, which left a light-theme settings page on
        // a dark canvas.
        applyChromeTheme()
        indexEveryPane()
    }

    override init(frame frameRect: NSRect) {
        store = .shared
        super.init(frame: frameRect)
        configure()
        reloadFromDisk()
        // The chrome theme is derived from the settings that were just read, so
        // the surface has to be repainted here: `configure()` had nothing but
        // the defaults to paint with, which left a light-theme settings page on
        // a dark canvas.
        applyChromeTheme()
        indexEveryPane()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Chrome theme in effect for the settings surface. Preferences used to
    /// paint its cards with the generic system control background regardless of
    /// the terminal theme, which is why it was the one surface that never
    /// matched the rest of the app.
    var chromeTheme: DesignTokens.ChromeTheme {
        DesignTokens.ChromeTheme.theme(for: settings)
    }

    private func configure() {
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))

        configureHeader()
        configureNav()
        configureDetailArea()
        configureStatusBar()

        addSubview(headerView)
        addSubview(headerSeparator)
        addSubview(categoryStack)
        addSubview(navDivider)
        addSubview(detailScrollView)
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),
            metrics.bind(headerView.heightAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.preferencesHeaderHeightPX
            },

            headerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerSeparator.topAnchor.constraint(equalTo: headerView.bottomAnchor),

            categoryStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DesignTokens.Component.preferencesNavInsetXPX
            ),
            categoryStack.topAnchor.constraint(
                equalTo: headerSeparator.bottomAnchor,
                constant: DesignTokens.Component.preferencesNavTopInsetPX
            ),
            metrics.bind(categoryStack.widthAnchor.constraint(equalToConstant: 0)) {
                Layout.navRowWidthPX
            },

            metrics.bind(navDivider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)) {
                Layout.navWidthPX
            },
            navDivider.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            navDivider.bottomAnchor.constraint(equalTo: bottomAnchor),
            // An `NSBox` separator only knows its own thickness along the axis
            // AppKit can infer, and for a vertical rule it cannot: with only a
            // leading edge pinned and the scroll view hung off its trailing
            // edge, this box absorbed every spare point. In a wide tab it grew
            // past a thousand points, which is what pushed the settings content
            // to the far right and left a dead band beside the nav.
            navDivider.widthAnchor.constraint(equalToConstant: DesignTokens.Component.hairlinePX),

            detailScrollView.leadingAnchor.constraint(equalTo: navDivider.trailingAnchor),
            detailScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailScrollView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            detailScrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -DesignTokens.Space.x3PX),

            statusLabel.leadingAnchor.constraint(equalTo: navDivider.trailingAnchor, constant: Layout.outerInsetPX),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.outerInsetPX),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Space.x4PX),
            metrics.bind(statusLabel.heightAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.preferencesStatusHeightPX
            },
        ])
        applyChromeTheme()
    }

    /// Repaints the surface, the cards, and the system controls for the
    /// active terminal theme. Called on load and after every save so a theme
    /// change in the Appearance pane is reflected immediately.
    private func applyChromeTheme() {
        let theme = chromeTheme
        appearance = theme.windowAppearance
        layer?.backgroundColor = theme.surfaceCanvas.cgColor
        headerView.layer?.backgroundColor = theme.surfaceChrome.cgColor
        titleLabel.textColor = theme.textPrimary
        statusLabel.textColor = theme.textTertiary
        applyChromeMetrics()
        // The nav rows paint their own capsule, so they need the ramp the same
        // way the sidebar lists do.
        for case let row as PreferencesNavRowButton in categoryStack.arrangedSubviews {
            row.chromeTheme = theme
        }
        search.applyChromeTheme(theme)
    }

    /// The header, the nav column, and the status line are built once and
    /// outlive every pane rebuild, so their scaled sizes have to be re-taken
    /// here; everything inside a pane comes back with the rebuild.
    private func applyChromeMetrics() {
        metrics.reapply()
        titleLabel.font = DesignTokens.Typography.prefsTitle.font
        statusLabel.font = DesignTokens.Typography.prefsCaption.font
    }

    /// Top bar of the settings surface: the page title over the nav column and
    /// the query field over the content column, above one hairline that runs
    /// the full width.
    ///
    /// Search moved out of the nav list to get here. A query reaches settings in
    /// every pane, so a field parked inside one column read as a filter on that
    /// column rather than on the surface.
    private func configureHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer.map(ChromeMotion.disableImplicitAnimations(on:))

        titleLabel.stringValue = copy(.settingsTitle)
        titleLabel.font = DesignTokens.Typography.prefsTitle.font
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        headerSeparator.boxType = .separator
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        navDivider.boxType = .separator
        navDivider.translatesAutoresizingMaskIntoConstraints = false

        search.onCategoryRequested = { [weak self] category in
            self?.selectCategory(category)
        }
        let queryField = search.queryField
        headerView.addSubview(titleLabel)
        headerView.addSubview(queryField)

        // The field takes its designed width where there is room and gives it
        // back to the trailing inset in a narrow tab, so it never overhangs.
        let designedWidth = metrics.bind(queryField.widthAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.preferencesHeaderSearchWidthPX
        }
        designedWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(
                equalTo: headerView.leadingAnchor,
                constant: DesignTokens.Component.preferencesNavInsetXPX
            ),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            metrics.bind(
                queryField.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 0)
            ) {
                Layout.navWidthPX + Layout.outerInsetPX
            },
            queryField.trailingAnchor.constraint(
                lessThanOrEqualTo: headerView.trailingAnchor,
                constant: -Layout.outerInsetPX
            ),
            queryField.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            designedWidth,
        ])
    }

    private func configureNav() {
        categoryStack.orientation = .vertical
        categoryStack.alignment = .leading
        categoryStack.spacing = DesignTokens.Space.x1PX
        categoryStack.translatesAutoresizingMaskIntoConstraints = false

        for category in PreferencesCategory.allCases {
            let button = PreferencesNavRowButton()
            button.title = title(for: category)
            button.target = self
            button.action = #selector(categorySelected(_:))
            button.tag = category.rawValue
            button.chromeTheme = chromeTheme
            button.translatesAutoresizingMaskIntoConstraints = false
            metrics.bind(button.widthAnchor.constraint(equalToConstant: 0)) {
                Layout.navRowWidthPX
            }.isActive = true
            metrics.bind(button.heightAnchor.constraint(equalToConstant: 0)) {
                Layout.navRowHeightPX
            }.isActive = true
            categoryStack.addArrangedSubview(button)
        }
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
    /// delegate's terminal search, so while the settings tab is selected "find"
    /// means find a setting.
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

        // The content column is elastic with a ceiling: `fill` is the growth
        // rule and yields to the maximum, so the same cards read correctly in a
        // half-width tab and on a 6K display.
        let fill = detailStack.widthAnchor.constraint(equalTo: documentView.widthAnchor)
        fill.priority = .defaultHigh

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: detailScrollView.contentView.heightAnchor),
            detailStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            detailStack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor),
            detailStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: Layout.contentMaxWidthPX + Layout.outerInsetPX * 2
            ),
            fill,
            detailStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            detailStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor),
        ])

        // The empty state stays arranged for the surface's whole life. A pane
        // switch tears every card down, and a view that left the hierarchy
        // would take its width constraint with it.
        detailStack.addArrangedSubview(search.emptyStateView)
        pinToContentColumn(search.emptyStateView)
    }

    /// Pins `view` to the content column, which is the detail stack minus its
    /// own insets. Everything the panes add goes through here instead of
    /// carrying a width of its own: a settings surface hosted in a tab has no
    /// fixed width to hard-code.
    func pinToContentColumn(_ view: NSView) {
        contentColumnWidthConstraint(for: view).isActive = true
    }

    /// The same constraint, unactivated, for the one card that outlives a pane
    /// build. The custom palette is torn out of the stack on every switch, and
    /// a constraint to a stack the view has left is one Auto Layout will not
    /// honour, so its owner retires the old constraint before installing this.
    func contentColumnWidthConstraint(for view: NSView) -> NSLayoutConstraint {
        view.translatesAutoresizingMaskIntoConstraints = false
        return view.widthAnchor.constraint(
            equalTo: detailStack.widthAnchor,
            constant: -Layout.outerInsetPX * 2
        )
    }

    /// Pins `view` to the inside of `card` — the card's width less its padding
    /// on both sides. Card-relative rather than column-relative so a card can
    /// never disagree with the heading that sits in it.
    func pinToCardContent(_ view: NSView, in card: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(
            equalTo: card.widthAnchor,
            constant: -Layout.cardPaddingPX * 2
        ).isActive = true
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
        builtUITextScalePercent = DesignTokens.UIScale.percent
        for case let button as NSButton in categoryStack.arrangedSubviews {
            button.state = button.tag == category.rawValue ? .on : .off
        }
        for view in detailStack.arrangedSubviews where view !== search.emptyStateView {
            detailStack.removeArrangedSubview(view)
            view.removeFromSuperview()
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
        // Re-arranging a view that is already in the stack moves it to the end,
        // which puts the empty state back below the rebuilt cards without ever
        // detaching it.
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

    /// Live-applied: the debounced save installs the new scale into the design
    /// tokens and every open window re-lays itself out on the change
    /// notification, this surface included.
    @objc func uiTextScaleChanged(_ sender: NSSlider) {
        guard !isUpdatingControls else { return }
        settings.terminal.uiTextScalePercent = Self.snappedUITextScalePercent(sender.doubleValue)
        syncControlsFromSettings()
        scheduleAutosave()
    }

    /// Snaps a raw slider position onto the notch scale. The slider itself is
    /// continuous rather than tick-marked: nineteen visible ticks across 220pt
    /// reads as a ruler, and the snapping is what the user actually feels.
    static func snappedUITextScalePercent(_ value: Double) -> Double {
        let step = DesignTokens.UIScale.stepPercent
        return DesignTokens.UIScale.clamped((value / step).rounded() * step)
    }

    @objc func colorChanged(_ sender: NSColorWell) {
        guard !isUpdatingControls else { return }
        let hex = sender.color.terminalPaletteHex
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

    /// Live-applied: every open pane hears the change, so a bar that is on
    /// screen at that moment goes away with it instead of finishing its command.
    @objc private func commandProgressToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.commandProgressIndicatorEnabled = sender.state == .on
        scheduleAutosave()
    }

    /// Live-applied: the icon appears in or leaves the menu bar as soon as the
    /// change lands, so the checkbox is its own preview.
    @objc private func menuBarExtraToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.menuBarExtraEnabled = sender.state == .on
        scheduleAutosave()
    }

    /// Live-applied: open panes install or drop the rail as soon as the change
    /// lands. Turning it off also forgets every recorded marker, because the
    /// scrollback keeps moving while the rail is not watching it and a marker
    /// restored later would point at a row that has since moved.
    @objc private func promptNavigatorRailToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.promptNavigatorRailEnabled = sender.state == .on
        scheduleAutosave()
    }

    @objc private func confirmMultilinePasteToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.confirmMultilinePaste = sender.state == .on
        scheduleAutosave()
    }

    @objc private func confirmCloseToggled(_ sender: NSButton) {
        guard !isUpdatingControls else { return }
        settings.terminal.confirmCloseRunningProcess = sender.state == .on
        scheduleAutosave()
    }

    @objc private func importThemePressed(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Ghostty theme files carry no extension at all, so the panel cannot
        // filter by type without hiding exactly the files this exists for.
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importTheme(from: url)
        }
    }

    private func importTheme(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let colors = try TerminalThemeImporter.importTheme(from: data)
            applyImportedThemeColors(colors)
            setStatus(String(format: copy(.themeImported), url.deletingPathExtension().lastPathComponent))
        } catch {
            setStatus(String(format: copy(.themeImportFailed), themeImportFailureDescription(error)))
        }
    }

    /// Imported palettes land as the `custom` theme so the normalizer keeps
    /// every color instead of snapping the palette back to a preset.
    func applyImportedThemeColors(_ colors: TerminalColorSettings) {
        settings.terminal.theme = TerminalThemePreset.customName
        settings.terminal.colors = colors
        applyChromeTheme()
        // The cards take their fill from the chrome theme, so an imported
        // palette has to rebuild the pane, exactly like a preset switch.
        selectCategory(selectedCategory)
        scheduleAutosave()
    }

    private func themeImportFailureDescription(_ error: Error) -> String {
        switch error {
        case TerminalThemeImportError.unrecognizedFormat:
            return copy(.themeImportUnrecognized)
        case TerminalThemeImportError.incompletePalette:
            return copy(.themeImportIncomplete)
        default:
            return error.localizedDescription
        }
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
        confirmCloseCheckbox.state = settings.terminal.confirmCloseRunningProcess ? .on : .off
        statusBarCheckbox.state = settings.terminal.statusBarEnabled ? .on : .off
        commandProgressCheckbox.state = settings.terminal.commandProgressIndicatorEnabled ? .on : .off
        menuBarExtraCheckbox.state = settings.terminal.menuBarExtraEnabled ? .on : .off
        promptNavigatorRailCheckbox.state = settings.terminal.promptNavigatorRailEnabled ? .on : .off
        agentSessionIndexCheckbox.state = settings.terminal.agentSessionIndexEnabled ? .on : .off
        hideMouseCursorCheckbox.state = settings.terminal.hideMouseCursorWhileTyping ? .on : .off
        perProjectHistoryCheckbox.state = settings.shell.perProjectHistoryEnabled ? .on : .off
        agentStatusHooksCheckbox.state = settings.terminal.agentStatusHooksEnabled ? .on : .off
        restoreScrollbackCheckbox.state = settings.terminal.restoreScrollbackOnLaunch ? .on : .off
        uiTextScaleSlider.doubleValue = settings.terminal.uiTextScalePercent
        uiTextScaleValueLabel.stringValue = "\(Int(settings.terminal.uiTextScalePercent.rounded()))%"
        windowWidthField.doubleValue = settings.window.width
        windowWidthStepper.doubleValue = settings.window.width
        windowHeightField.doubleValue = settings.window.height
        windowHeightStepper.doubleValue = settings.window.height

        themePopup.selectItem(
            at: PreferencesThemePopup.index(
                ofPresetName: TerminalThemePreset.canonicalName(settings.terminal.theme)
            )
        )
        foregroundWell.color = NSColor.terminalPaletteSRGB(settings.terminal.colors.foreground) ?? .textColor
        backgroundWell.color = NSColor.terminalPaletteSRGB(settings.terminal.colors.background) ?? .textBackgroundColor
        cursorWell.color = NSColor.terminalPaletteSRGB(settings.terminal.colors.cursor) ?? .controlAccentColor
        for (index, well) in ansiWells.enumerated() where settings.terminal.colors.ansi.indices.contains(index) {
            well.color = NSColor.terminalPaletteSRGB(settings.terminal.colors.ansi[index]) ?? .gray
        }
        previewView.colors = settings.terminal.colors
        // The preview is a preview of the terminal, font included: leaving it on
        // a fixed family and size made every font change look like a no-op.
        previewView.fontName = settings.terminal.fontName
        previewView.fontSizePT = settings.terminal.fontSize
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
            // Every label in a pane took its font when the pane was built, so a
            // scale change has to rebuild it — the same reason a preset switch
            // does. Instant, never a transition.
            if DesignTokens.UIScale.percent != builtUITextScalePercent {
                selectCategory(selectedCategory)
            }
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

    /// Retranslates the whole surface in place after a language switch. The
    /// header and the nav rows are built once, so they are re-titled here; every
    /// label inside a pane comes back translated with the rebuild.
    func refreshLocalization() {
        titleLabel.stringValue = copy(.settingsTitle)
        for case let button as NSButton in categoryStack.arrangedSubviews {
            guard let category = PreferencesCategory(rawValue: button.tag) else { continue }
            button.title = title(for: category)
        }
        // The query field's placeholder is re-read while the theme is applied,
        // which is also what repaints the header for the current ramp.
        applyChromeTheme()
        selectCategory(selectedCategory)
    }

    // MARK: Test hooks

    var selectedCategoryForTesting: PreferencesCategory { selectedCategory }

    var settingsForTesting: AppSettings { settings }

    /// Switches panes the way the sidebar buttons do, for tests that need to
    /// inspect or render a pane other than the initial one.
    func selectCategoryForTesting(_ category: PreferencesCategory) {
        selectCategory(category)
    }

    /// Types a query the way the sidebar field does, including the pane switch
    /// and the visibility pass it triggers.
    func applySearchQueryForTesting(_ query: String) {
        search.query = query
    }

    var visibleCardTitlesForTesting: [String] { search.visibleCardTitlesForTesting }

    var visibleRowLabelsForTesting: [String] { search.visibleRowLabelsForTesting }

    var visibleCardWidthsForTesting: [CGFloat] { search.visibleCardWidthsForTesting }

    /// Width the detail area actually offers, which is not the surface width
    /// minus the nav: a legacy (non-overlay) scroller quietly takes a slice of
    /// it, and whether the user has one is a system setting.
    var detailAreaWidthForTesting: CGFloat { detailScrollView.contentView.bounds.width }

    /// Which nav rows are switched on. Selection is the nav's only state, so
    /// this is what "the surface is showing pane X" means to a test.
    var selectedNavTitlesForTesting: [String] {
        categoryStack.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .filter { $0.state == .on }
            .map(\.title)
    }

    /// Drives a nav row the way a click does, target-action included, so the
    /// tests exercise the same path the user does.
    func clickNavRowForTesting(_ category: PreferencesCategory) {
        guard let button = categoryStack.arrangedSubviews
            .compactMap({ $0 as? NSButton })
            .first(where: { $0.tag == category.rawValue })
        else {
            return
        }
        button.performClick(nil)
    }

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
        Entry(presetName: TerminalThemePreset.nacreName, copyKey: .themeNacre),
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
