import AppKit

/// Popover content views for the status bar: per-pane process usage on the
/// right, bounded agent status history on the left.
///
/// Both are built once per presentation from an immutable snapshot; neither
/// observes anything, so a dismissed popover leaves no timers or observers
/// behind.

// MARK: - Process usage

/// Right-segment popover: one row per pane, sorted by memory descending, each
/// with a destructive "Quit process" action.
@MainActor
final class TerminalStatusBarProcessUsageView: NSView {
    /// Invoked for a row's quit button. The bar owns the confirmation and the
    /// kill policy; this view only reports intent.
    var onQuitProcess: ((TerminalPaneResourceUsage) -> Void)?

    private let theme: DesignTokens.ChromeTheme
    private var quitButtonRows: [Int: TerminalPaneResourceUsage] = [:]

    init(usage: TerminalWindowResourceUsage, theme: DesignTokens.ChromeTheme) {
        self.theme = theme
        super.init(frame: .zero)
        configure(usage: usage)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(usage: TerminalWindowResourceUsage) {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = TerminalStatusBarTokens.popoverRowGapPX
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        stackView.addArrangedSubview(TerminalStatusBarPopoverText.header(
            TerminalStatusBarStrings.string(.processUsageTitle),
            theme: theme
        ))
        stackView.addArrangedSubview(TerminalStatusBarPopoverText.secondary(
            TerminalResourceUsageFormatter.summaryText(
                bytes: usage.residentBytes,
                cpuPercent: usage.cpuPercent
            ),
            theme: theme
        ))

        let rows = usage.panes.prefix(TerminalStatusBarTokens.popoverMaximumRowCount)
        if rows.isEmpty {
            stackView.addArrangedSubview(TerminalStatusBarPopoverText.secondary(
                TerminalStatusBarStrings.string(.noProcesses),
                theme: theme
            ))
        }
        for (index, paneUsage) in rows.enumerated() {
            stackView.addArrangedSubview(makeRow(paneUsage, index: index))
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: TerminalStatusBarTokens.popoverWidthPX),
            stackView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: TerminalStatusBarTokens.popoverInsetPX
            ),
            stackView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -TerminalStatusBarTokens.popoverInsetPX
            ),
            stackView.topAnchor.constraint(
                equalTo: topAnchor,
                constant: TerminalStatusBarTokens.popoverInsetPX
            ),
            stackView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -TerminalStatusBarTokens.popoverInsetPX
            ),
        ])
    }

    private func makeRow(_ paneUsage: TerminalPaneResourceUsage, index: Int) -> NSView {
        let rowStackView = NSStackView()
        rowStackView.orientation = .horizontal
        rowStackView.alignment = .centerY
        rowStackView.spacing = TerminalStatusBarTokens.metricGapPX

        let titleField = TerminalStatusBarPopoverText.primary(paneUsage.title, theme: theme)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let metricsText = "\(TerminalResourceUsageFormatter.memoryText(bytes: paneUsage.residentBytes))"
            + " \(TerminalStatusBarStrings.summarySeparator) "
            + TerminalResourceUsageFormatter.cpuText(percent: paneUsage.cpuPercent)
        let metricsField = TerminalStatusBarPopoverText.monospacedValue(metricsText, theme: theme)

        let quitButton = NSButton(
            title: TerminalStatusBarStrings.string(.quitProcess),
            target: self,
            action: #selector(quitButtonPressed(_:))
        )
        quitButton.tag = index
        quitButton.bezelStyle = .inline
        quitButton.controlSize = .small
        quitButton.font = NSFont.systemFont(ofSize: TerminalStatusBarTokens.fontSizePT)
        quitButton.isEnabled = paneUsage.processIdentifier != nil
        quitButtonRows[index] = paneUsage

        rowStackView.addArrangedSubview(titleField)
        rowStackView.addArrangedSubview(metricsField)
        rowStackView.addArrangedSubview(quitButton)
        rowStackView.translatesAutoresizingMaskIntoConstraints = false
        rowStackView.heightAnchor.constraint(
            equalToConstant: TerminalStatusBarTokens.popoverRowHeightPX
        ).isActive = true
        return rowStackView
    }

    @objc private func quitButtonPressed(_ sender: NSButton) {
        guard let paneUsage = quitButtonRows[sender.tag] else {
            return
        }
        onQuitProcess?(paneUsage)
    }
}

// MARK: - Agent history

/// Left-segment popover: the bounded status history the registry already keeps
/// for the pane, newest first, plus an insert-only resume action.
@MainActor
final class TerminalStatusBarAgentHistoryView: NSView {
    /// Inserts the resume command at the prompt. Never executes it.
    var onResume: ((AgentSessionRecord) -> Void)?

    private let theme: DesignTokens.ChromeTheme
    private let resumeRecord: AgentSessionRecord?

    init(
        history: [AgentActivityStatus],
        resumeRecord: AgentSessionRecord?,
        theme: DesignTokens.ChromeTheme
    ) {
        self.theme = theme
        self.resumeRecord = resumeRecord
        super.init(frame: .zero)
        configure(history: history)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(history: [AgentActivityStatus]) {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = TerminalStatusBarTokens.popoverRowGapPX
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        stackView.addArrangedSubview(TerminalStatusBarPopoverText.header(
            TerminalStatusBarStrings.string(.statusHistoryTitle),
            theme: theme
        ))

        let rows = history.reversed().prefix(TerminalStatusBarTokens.popoverMaximumRowCount)
        if rows.isEmpty {
            stackView.addArrangedSubview(TerminalStatusBarPopoverText.secondary(
                TerminalStatusBarStrings.string(.noAgent),
                theme: theme
            ))
        }
        for status in rows {
            stackView.addArrangedSubview(makeRow(status))
        }

        if resumeRecord != nil {
            let resumeButton = NSButton(
                title: TerminalStatusBarStrings.string(.resumeLastSession),
                target: self,
                action: #selector(resumeButtonPressed(_:))
            )
            resumeButton.bezelStyle = .rounded
            resumeButton.controlSize = .small
            stackView.addArrangedSubview(resumeButton)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: TerminalStatusBarTokens.popoverWidthPX),
            stackView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: TerminalStatusBarTokens.popoverInsetPX
            ),
            stackView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -TerminalStatusBarTokens.popoverInsetPX
            ),
            stackView.topAnchor.constraint(
                equalTo: topAnchor,
                constant: TerminalStatusBarTokens.popoverInsetPX
            ),
            stackView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -TerminalStatusBarTokens.popoverInsetPX
            ),
        ])
    }

    private func makeRow(_ status: AgentActivityStatus) -> NSView {
        let rowStackView = NSStackView()
        rowStackView.orientation = .horizontal
        rowStackView.alignment = .centerY
        rowStackView.spacing = TerminalStatusBarTokens.labelDetailGapPX

        let timeField = TerminalStatusBarPopoverText.monospacedValue(
            Self.timeFormatter.string(from: status.updatedAt),
            theme: theme
        )
        let stateField = TerminalStatusBarPopoverText.primary(
            TerminalStatusBarStrings.stateLabel(for: status.state),
            theme: theme
        )
        rowStackView.addArrangedSubview(timeField)
        rowStackView.addArrangedSubview(stateField)
        if let detail = status.detail {
            let detailField = TerminalStatusBarPopoverText.secondary(detail, theme: theme)
            detailField.lineBreakMode = .byTruncatingTail
            rowStackView.addArrangedSubview(detailField)
        }
        rowStackView.translatesAutoresizingMaskIntoConstraints = false
        rowStackView.heightAnchor.constraint(
            equalToConstant: TerminalStatusBarTokens.popoverRowHeightPX
        ).isActive = true
        return rowStackView
    }

    @objc private func resumeButtonPressed(_ sender: NSButton) {
        guard let resumeRecord else {
            return
        }
        onResume?(resumeRecord)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Shared popover text

/// Label factories so the two popovers stay typographically identical.
@MainActor
enum TerminalStatusBarPopoverText {
    static func header(_ text: String, theme: DesignTokens.ChromeTheme) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: DesignTokens.Typography.statusFontSizePT, weight: .semibold)
        field.textColor = theme.textPrimary
        return field
    }

    static func primary(_ text: String, theme: DesignTokens.ChromeTheme) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: TerminalStatusBarTokens.fontSizePT, weight: .regular)
        field.textColor = theme.textPrimary
        return field
    }

    static func secondary(_ text: String, theme: DesignTokens.ChromeTheme) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: TerminalStatusBarTokens.fontSizePT, weight: .regular)
        field.textColor = theme.textMuted
        return field
    }

    static func monospacedValue(_ text: String, theme: DesignTokens.ChromeTheme) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.monospacedDigitSystemFont(
            ofSize: TerminalStatusBarTokens.fontSizePT,
            weight: .medium
        )
        field.textColor = theme.textSecondary
        return field
    }
}
