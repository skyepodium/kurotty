import AppKit

/// Outline view that turns Return/keypad-Enter into an insert action instead
/// of the default row toggle, matching the history panel interaction contract.
@MainActor
final class TerminalCommandHistoryOutlineView: NSOutlineView {
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnterKey: UInt16 = 76
    }

    var onReturnKey: (() -> Void)?

    /// Tint for the disclosure chevron. The outline view builds that button
    /// itself, so it cannot be reached through the cell views.
    var disclosureTintColor: NSColor = DesignTokens.ChromeTheme.dark.textTertiary {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnterKey {
            onReturnKey?()
            return
        }
        super.keyDown(with: event)
    }

    /// AppKit's stock disclosure triangle is a filled system triangle at the
    /// system size. The sidebar wants a quiet 9pt chevron in a 16x16 box that
    /// turns a quarter-turn on expand, which is exactly the collapsed/expanded
    /// image pair below.
    override func makeView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        owner: Any?
    ) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        guard identifier == NSOutlineView.disclosureButtonIdentifier,
              let button = view as? NSButton
        else {
            return view
        }
        let pointSizePT = DesignTokens.Component.commandHistoryDisclosurePointSizePT
        button.image = Icon.symbol(
            IconSymbol.disclosureCollapsed,
            pointSizePT: pointSizePT,
            weight: .semibold,
            tint: disclosureTintColor
        )
        button.alternateImage = Icon.symbol(
            IconSymbol.disclosureExpanded,
            pointSizePT: pointSizePT,
            weight: .semibold,
            tint: disclosureTintColor
        )
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = disclosureTintColor
        button.frame = NSRect(
            origin: button.frame.origin,
            size: NSSize(
                width: DesignTokens.Component.commandHistoryDisclosureBoxSizePX,
                height: DesignTokens.Component.commandHistoryDisclosureBoxSizePX
            )
        )
        return button
    }
}

/// Command-history and agent-session sidebar row. All painting lives in the
/// shared `TerminalSidebarRowView` so history, agent sessions, and the file
/// explorer cannot drift apart.
@MainActor
final class TerminalCommandHistorySidebarRowView: TerminalSidebarRowView {}

/// Expandable project node: folder icon, emphasized last path component,
/// dimmed parent path, and a trailing rounded count badge.
@MainActor
final class TerminalCommandHistoryGroupCellView: NSTableCellView {
    private let titleLabel: NSTextField
    private let titleStyler: TerminalSidebarRowTitleStyler
    private let badgeView: TerminalSidebarCountBadgeView

    init(group: TerminalCommandHistoryPanelGroup, chromeTheme: DesignTokens.ChromeTheme) {
        titleLabel = NSTextField(labelWithString: group.display.lastComponent)
        titleStyler = TerminalSidebarRowTitleStyler(
            role: DesignTokens.Typography.rowTitle,
            restColor: chromeTheme.textPrimary,
            chromeTheme: chromeTheme
        )
        badgeView = TerminalSidebarCountBadgeView(
            text: "\(group.entriesNewestFirst.count)",
            chromeTheme: chromeTheme
        )
        super.init(frame: .zero)

        let iconView = NSImageView()
        iconView.image = Icon.symbol(
            IconSymbol.folder,
            pointSizePT: DesignTokens.Component.commandHistoryGroupIconPointSizePT,
            weight: .regular,
            tint: chromeTheme.textTertiary
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let nameLabel = titleLabel
        titleStyler.apply(.rest, to: nameLabel)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        let parentLabel = NSTextField(labelWithString: group.display.parentDisplay)
        DesignTokens.Typography.rowSecondary.apply(to: parentLabel, color: chromeTheme.textTertiary)
        parentLabel.lineBreakMode = .byTruncatingMiddle
        parentLabel.maximumNumberOfLines = 1
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parentLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        parentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(parentLabel)

        addSubview(badgeView)

        toolTip = group.display.path.isEmpty ? nil : group.display.path

        let gap = DesignTokens.Component.commandHistoryRowGapPX
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: gap),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            parentLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: gap),
            parentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            parentLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: badgeView.leadingAnchor,
                constant: -gap
            ),

            badgeView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DesignTokens.Component.commandHistoryRowInsetXPX
            ),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

extension TerminalCommandHistoryGroupCellView: TerminalSidebarRowTitleStyling {
    func applySidebarRowTitleStyle(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        titleStyler.apply(appearance, to: titleLabel)
        badgeView.apply(appearance)
    }
}

/// Command leaf row: status dot, monospaced command text with middle
/// truncation, and a trailing relative-time detail (failures append the exit
/// code in dimmed text).
@MainActor
final class TerminalCommandHistoryCommandCellView: NSTableCellView {
    private let commandLabel: NSTextField
    private let titleStyler: TerminalSidebarRowTitleStyler

    init(entry: TerminalCommandHistoryEntry, chromeTheme: DesignTokens.ChromeTheme, now: Date) {
        commandLabel = NSTextField(labelWithString: entry.commandText)
        titleStyler = TerminalSidebarRowTitleStyler(
            role: DesignTokens.Typography.monoBody,
            restColor: chromeTheme.textSecondary,
            selectedColor: chromeTheme.textPrimary,
            chromeTheme: chromeTheme
        )
        super.init(frame: .zero)

        let didSucceed = (entry.exitCode ?? 0) == 0
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        dot.layer?.cornerRadius = DesignTokens.Component.commandHistoryStatusDotSizePX / 2
        dot.layer?.backgroundColor = didSucceed
            ? chromeTheme.success.cgColor
            : chromeTheme.error.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        titleStyler.apply(.rest, to: commandLabel)
        commandLabel.lineBreakMode = .byTruncatingMiddle
        commandLabel.maximumNumberOfLines = 1
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commandLabel)

        let detailLabel = NSTextField(
            labelWithString: TerminalCommandHistoryRowBuilder.trailingDetailLabel(for: entry, now: now)
        )
        // Monospaced digits: the relative time ticks over while the panel is
        // open and must not shift the column it sits in.
        detailLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.Typography.rowSecondary.sizePT,
            weight: DesignTokens.Typography.rowSecondary.weight
        )
        detailLabel.textColor = chromeTheme.textTertiary
        detailLabel.alignment = .right
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        toolTip = entry.commandText

        let gap = DesignTokens.Component.commandHistoryRowGapPX
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: DesignTokens.Component.commandHistoryStatusDotSizePX),
            dot.heightAnchor.constraint(equalToConstant: DesignTokens.Component.commandHistoryStatusDotSizePX),

            commandLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: gap),
            commandLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: commandLabel.trailingAnchor, constant: gap),
            detailLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DesignTokens.Component.commandHistoryRowInsetXPX
            ),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: DesignTokens.Component.commandHistoryTimeLabelMinWidthPX
            ),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

extension TerminalCommandHistoryCommandCellView: TerminalSidebarRowTitleStyling {
    func applySidebarRowTitleStyle(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        titleStyler.apply(appearance, to: commandLabel)
    }
}
