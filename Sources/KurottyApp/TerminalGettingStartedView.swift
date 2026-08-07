import AppKit

/// The Getting Started page.
///
/// A scrolling list of what Kurotty found on this machine, one row per check.
/// It is a page rather than a modal on purpose: it opens as an ordinary center
/// tab beside the terminal, so nothing is blocked, the prompt is one tab away,
/// and closing it is the same Command-W as closing anything else. A full-screen
/// wizard in front of a terminal would be the wrong shape for the app — a
/// person opened a terminal to type into it.
///
/// Every decision about what a row says lives in `TerminalSetupChecklist`; this
/// draws it.
@MainActor
final class TerminalGettingStartedView: NSView {
    /// Sends the user to Settings. Owned by the window, which is the only thing
    /// that can open a tab.
    var onOpenSettings: (() -> Void)?

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var language = AppLocalization.language
    private var environment = TerminalSetupEnvironment()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = theme.surfaceCanvas.cgColor
        rebuild()
    }

    /// Re-reads the machine. Called when the tab is opened or re-selected
    /// rather than on a timer: every check here is either a process spawn or a
    /// settings read, and polling them would spend CPU on a page nobody is
    /// looking at.
    func update(environment: TerminalSetupEnvironment) {
        self.environment = environment
        rebuild()
    }

    func refreshLocalization() {
        language = AppLocalization.language
        rebuild()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = chromeTheme.surfaceCanvas.cgColor

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = DesignTokens.Component.gettingStartedRowGapPX
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        // Flipped, like the settings page's own document view: an unflipped
        // document view shorter than its clip view is laid out from the bottom
        // edge up, which drops a half-page checklist to the foot of the tab.
        let documentView = FlippedGettingStartedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let inset = DesignTokens.Component.gettingStartedInsetPX
        // Only upper bounds on the column width would leave Auto Layout free to
        // collapse it onto the widest row's intrinsic size, so the column is
        // also *pulled* to the trailing edge at a priority the max-width
        // constraint can beat. Elastic up to a reading width, then it stops.
        let stretch = contentStack.trailingAnchor.constraint(
            equalTo: documentView.trailingAnchor,
            constant: -inset
        )
        stretch.priority = .defaultHigh
        stretch.isActive = true

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: inset),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -inset),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: inset),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: documentView.trailingAnchor,
                constant: -inset
            ),
            contentStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: DesignTokens.Component.gettingStartedContentMaxWidthPX
            ),
        ])

        rebuild()
    }

    private func rebuild() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        DesignTokens.Typography.prefsTitle.apply(
            to: titleLabel,
            color: chromeTheme.textPrimary
        )
        titleLabel.stringValue = AppLocalization.string(.gettingStarted, language: language)
        DesignTokens.Typography.prefsBody.apply(to: subtitleLabel, color: chromeTheme.textSecondary)
        subtitleLabel.stringValue = AppLocalization.string(.gettingStartedSubtitle, language: language)
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0

        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(subtitleLabel)
        contentStack.setCustomSpacing(DesignTokens.Component.gettingStartedTextGapPX, after: titleLabel)
        contentStack.setCustomSpacing(DesignTokens.Component.gettingStartedHeaderGapPX, after: subtitleLabel)

        for item in TerminalSetupChecklist.items(environment: environment) {
            let row = TerminalGettingStartedRowView(
                item: item,
                theme: chromeTheme,
                language: language,
                onOpenSettings: { [weak self] in self?.onOpenSettings?() }
            )
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }
}

/// One checklist row: a state glyph, a title over its explanation, and at most
/// one action.
@MainActor
private final class TerminalGettingStartedRowView: NSView {
    private let onOpenSettings: () -> Void
    private let action: TerminalSetupChecklistAction?
    private let language: AppLanguage
    private let actionButton = NSButton()

    init(
        item: TerminalSetupChecklistItem,
        theme: DesignTokens.ChromeTheme,
        language: AppLanguage,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onOpenSettings = onOpenSettings
        self.action = item.action
        self.language = language
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = theme.surfaceRaised.cgColor
        layer?.cornerRadius = DesignTokens.Component.gettingStartedRowCornerRadiusPX
        translatesAutoresizingMaskIntoConstraints = false

        let glyphView = NSImageView()
        glyphView.image = Icon.symbol(
            Self.symbolName(for: item.state),
            .regular,
            tint: Self.tint(for: item.state, theme: theme),
            accessibilityDescription: TerminalSetupChecklistCopy.stateLabel(for: item.state, language: language)
        )
        glyphView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: TerminalSetupChecklistCopy.title(for: item.id, language: language))
        DesignTokens.Typography.prefsSection.apply(to: titleLabel, color: theme.textPrimary)
        titleLabel.lineBreakMode = .byTruncatingTail

        let stateLabel = NSTextField(
            labelWithString: TerminalSetupChecklistCopy.stateLabel(for: item.state, language: language)
        )
        DesignTokens.Typography.badge.apply(to: stateLabel, color: Self.tint(for: item.state, theme: theme))
        stateLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let detailLabel = NSTextField(
            wrappingLabelWithString: TerminalSetupChecklistCopy.detail(for: item.id, language: language)
        )
        DesignTokens.Typography.prefsCaption.apply(to: detailLabel, color: theme.textSecondary)
        detailLabel.maximumNumberOfLines = 0

        let headerStack = NSStackView(views: [titleLabel, stateLabel])
        headerStack.orientation = .horizontal
        headerStack.spacing = DesignTokens.Component.gettingStartedRowGutterPX
        headerStack.alignment = .firstBaseline

        let textStack = NSStackView(views: [headerStack, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = DesignTokens.Component.gettingStartedTextGapPX
        textStack.translatesAutoresizingMaskIntoConstraints = false

        if let action {
            actionButton.title = TerminalSetupChecklistCopy.actionLabel(for: action, language: language)
            actionButton.bezelStyle = .rounded
            actionButton.target = self
            actionButton.action = #selector(performAction)
            textStack.addArrangedSubview(actionButton)
        }

        addSubview(glyphView)
        addSubview(textStack)

        let inset = DesignTokens.Component.gettingStartedRowInsetPX
        NSLayoutConstraint.activate([
            glyphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyphView.topAnchor.constraint(equalTo: textStack.topAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: DesignTokens.Component.gettingStartedGutterWidthPX),

            textStack.leadingAnchor.constraint(
                equalTo: glyphView.trailingAnchor,
                constant: DesignTokens.Component.gettingStartedRowGutterPX
            ),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func performAction() {
        guard let action else {
            return
        }
        switch action {
        case .openSettings:
            onOpenSettings()
        case let .copyCommand(command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            // The button becomes its own receipt rather than raising an alert:
            // copying is not worth a modal, and a title that changed is proof
            // the click landed.
            actionButton.title = AppLocalization.string(.gettingStartedCommandCopied, language: language)
        }
    }

    private static func symbolName(for state: TerminalSetupChecklistState) -> String {
        switch state {
        case .ready:
            return IconSymbol.setupReady
        case .action:
            return IconSymbol.setupAction
        case .unavailable:
            return IconSymbol.setupUnavailable
        }
    }

    /// `action` is the warning hue, not the error one. Nothing on this page is
    /// broken — every row is something Kurotty works without.
    private static func tint(
        for state: TerminalSetupChecklistState,
        theme: DesignTokens.ChromeTheme
    ) -> NSColor {
        switch state {
        case .ready:
            return theme.success
        case .action:
            return theme.warning
        case .unavailable:
            return theme.textTertiary
        }
    }
}

private final class FlippedGettingStartedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
