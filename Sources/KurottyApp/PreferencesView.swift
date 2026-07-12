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
        static let sidebarWidthPX: CGFloat = 184
        static let contentWidthPX: CGFloat = 590
        static let sectionSpacingPX: CGFloat = 18
        static let sectionInsetPX: CGFloat = 16
        static let rowSpacingPX: CGFloat = 10
        static let labelWidthPX: CGFloat = 150
        static let fieldWidthPX: CGFloat = 240
        static let previewHeightPX: CGFloat = 176
        static let colorWellSizePX: CGFloat = 34
        static let ansiColumnCount = 4
    }

    private static let autosaveDelay: TimeInterval = 0.25

    private let store: AppSettingsStore
    private var settings = AppSettings.default
    private var autosaveWorkItem: DispatchWorkItem?
    private var isUpdatingControls = false

    private lazy var categoryStack = NSStackView()
    private lazy var detailScrollView = NSScrollView()
    private lazy var detailStack = NSStackView()
    private lazy var statusLabel = NSTextField(labelWithString: "")

    private lazy var workingDirectoryField = NSTextField()
    private lazy var fontPopup = NSPopUpButton()
    private lazy var fontSizeField = NSTextField()
    private lazy var fontSizeStepper = NSStepper()
    private lazy var scrollbackField = NSTextField()
    private lazy var scrollbackStepper = NSStepper()
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

    private func configure() {
        wantsLayer = true

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
            categoryStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            categoryStack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            categoryStack.widthAnchor.constraint(equalToConstant: Layout.sidebarWidthPX - 28),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.sidebarWidthPX),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),

            detailScrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailScrollView.topAnchor.constraint(equalTo: topAnchor),
            detailScrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 22),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            statusLabel.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func configureSidebar() {
        categoryStack.orientation = .vertical
        categoryStack.alignment = .leading
        categoryStack.spacing = 4
        categoryStack.translatesAutoresizingMaskIntoConstraints = false

        let headingLabel = NSTextField(labelWithString: copy(.settingsTitle))
        headingLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        categoryStack.addArrangedSubview(headingLabel)
        categoryStack.setCustomSpacing(14, after: headingLabel)

        for category in Category.allCases {
            let button = NSButton(title: title(for: category), target: self, action: #selector(categorySelected(_:)))
            button.tag = category.rawValue
            button.bezelStyle = .recessed
            button.alignment = .left
            button.setButtonType(.toggle)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: Layout.sidebarWidthPX - 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
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
        detailStack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 28, right: 24)
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
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func categorySelected(_ sender: NSButton) {
        guard let category = Category(rawValue: sender.tag) else { return }
        selectCategory(category)
    }

    private func selectCategory(_ category: Category) {
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
        detailStack.addArrangedSubview(shellSection)

        let textSection = section(title: copy(.textSection), subtitle: copy(.textSectionHelp))
        fontPopup.removeAllItems()
        fontPopup.addItems(withTitles: availableMonospacedFonts())
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        textSection.addArrangedSubview(row(label: copy(.font), control: fontPopup))
        configureNumericField(fontSizeField, stepper: fontSizeStepper, minimum: SettingsDefaults.minimumTerminalFontSizePT, maximum: SettingsDefaults.maximumTerminalFontSizePT, increment: 1)
        textSection.addArrangedSubview(row(label: copy(.fontSize), control: numericControl(field: fontSizeField, stepper: fontSizeStepper, suffix: "pt")))
        detailStack.addArrangedSubview(textSection)

        let historySection = section(title: copy(.historySection), subtitle: copy(.historySectionHelp))
        configureNumericField(scrollbackField, stepper: scrollbackStepper, minimum: Double(SettingsDefaults.minimumScrollbackRows), maximum: Double(SettingsDefaults.maximumScrollbackRows), increment: 1_000)
        historySection.addArrangedSubview(row(label: copy(.scrollback), control: numericControl(field: scrollbackField, stepper: scrollbackStepper, suffix: copy(.lines))))
        detailStack.addArrangedSubview(historySection)
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
        previewView.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX - Layout.sectionInsetPX * 2).isActive = true
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
        customColorsStack.edgeInsets = NSEdgeInsets(top: Layout.sectionInsetPX, left: Layout.sectionInsetPX, bottom: Layout.sectionInsetPX, right: Layout.sectionInsetPX)
        customColorsStack.wantsLayer = true
        customColorsStack.layer?.cornerRadius = 10
        customColorsStack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        customColorsStack.translatesAutoresizingMaskIntoConstraints = false
        customColorsStack.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX).isActive = true

        let heading = sectionHeading(copy(.customColors), subtitle: copy(.customColorsHelp))
        heading.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX - Layout.sectionInsetPX * 2).isActive = true
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
        primaryColors.spacing = 22
        customColorsStack.addArrangedSubview(primaryColors)

        let ansiTitle = NSTextField(labelWithString: copy(.ansiPalette))
        ansiTitle.font = .systemFont(ofSize: 12, weight: .medium)
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
        ansiGrid.rowSpacing = 8
        ansiGrid.columnSpacing = 10
        customColorsStack.addArrangedSubview(ansiGrid)
    }

    private func addPageHeader(_ title: String, subtitle: String) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitleLabel = wrappingLabel(subtitle)
        subtitleLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX).isActive = true
        detailStack.addArrangedSubview(stack)
    }

    private func section(title: String, subtitle: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Layout.rowSpacingPX
        stack.edgeInsets = NSEdgeInsets(top: Layout.sectionInsetPX, left: Layout.sectionInsetPX, bottom: Layout.sectionInsetPX, right: Layout.sectionInsetPX)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 10
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX).isActive = true
        let heading = sectionHeading(title, subtitle: subtitle)
        heading.widthAnchor.constraint(equalToConstant: Layout.contentWidthPX - Layout.sectionInsetPX * 2).isActive = true
        stack.addArrangedSubview(heading)
        return stack
    }

    private func sectionHeading(_ title: String, subtitle: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let subtitleLabel = wrappingLabel(subtitle)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        return stack
    }

    private func row(label title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Layout.labelWidthPX).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        if control is NSPopUpButton {
            control.widthAnchor.constraint(equalToConstant: Layout.fieldWidthPX).isActive = true
        }
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    private func numericControl(field: NSTextField, stepper: NSStepper, suffix: String) -> NSStackView {
        let suffixLabel = NSTextField(labelWithString: suffix)
        suffixLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [field, stepper, suffixLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func labeledColorWell(_ title: String, well: NSColorWell) -> NSStackView {
        well.toolTip = title
        well.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        let stack = NSStackView(views: [well, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
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
        field.widthAnchor.constraint(equalToConstant: 92).isActive = true
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
        syncControlsFromSettings()
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
        scrollbackField.integerValue = settings.terminal.scrollbackLines
        scrollbackStepper.integerValue = settings.terminal.scrollbackLines
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
