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

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnterKey {
            onReturnKey?()
            return
        }
        super.keyDown(with: event)
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
    private enum Symbol {
        static let folder = "folder"
    }

    private let titleLabel: NSTextField
    private let titleStyler: TerminalSidebarRowTitleStyler

    init(group: TerminalCommandHistoryPanelGroup, chromeTheme: DesignTokens.ChromeTheme) {
        titleLabel = NSTextField(labelWithString: group.display.lastComponent)
        titleStyler = TerminalSidebarRowTitleStyler(
            baseFontSizePT: DesignTokens.Typography.sidebarGroupNameFontSizePT,
            baseWeight: .semibold,
            baseColor: chromeTheme.textPrimary,
            chromeTheme: chromeTheme
        )
        super.init(frame: .zero)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: Symbol.folder, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: DesignTokens.Component.commandHistoryGroupIconPointSizePT,
                weight: .medium
            ))
        iconView.contentTintColor = chromeTheme.textSecondary
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
        parentLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.sidebarSecondaryFontSizePT)
        parentLabel.textColor = chromeTheme.textMuted
        parentLabel.lineBreakMode = .byTruncatingMiddle
        parentLabel.maximumNumberOfLines = 1
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parentLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        parentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(parentLabel)

        let badgeView = NSView()
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = DesignTokens.Component.commandHistoryBadgeHeightPX / 2
        badgeView.layer?.backgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(DesignTokens.Component.commandHistoryBadgeBackgroundAlphaRATIO)
            .cgColor
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeView)

        let countLabel = NSTextField(labelWithString: "\(group.entriesNewestFirst.count)")
        countLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.sidebarBadgeFontSizePT, weight: .medium)
        countLabel.textColor = chromeTheme.textSecondary
        countLabel.alignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeView.addSubview(countLabel)

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
            badgeView.heightAnchor.constraint(equalToConstant: DesignTokens.Component.commandHistoryBadgeHeightPX),
            badgeView.widthAnchor.constraint(
                greaterThanOrEqualToConstant: DesignTokens.Component.commandHistoryBadgeMinWidthPX
            ),

            countLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            countLabel.leadingAnchor.constraint(
                equalTo: badgeView.leadingAnchor,
                constant: DesignTokens.Component.commandHistoryBadgeTextInsetXPX
            ),
            countLabel.trailingAnchor.constraint(
                equalTo: badgeView.trailingAnchor,
                constant: -DesignTokens.Component.commandHistoryBadgeTextInsetXPX
            ),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

extension TerminalCommandHistoryGroupCellView: TerminalSidebarRowTitleStyling {
    func applySidebarRowTitleStyle(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        titleStyler.apply(appearance, to: titleLabel)
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
            baseFontSizePT: DesignTokens.Typography.sidebarCommandFontSizePT,
            baseWeight: .regular,
            baseColor: chromeTheme.textPrimary,
            chromeTheme: chromeTheme,
            isMonospaced: true
        )
        super.init(frame: .zero)

        let didSucceed = (entry.exitCode ?? 0) == 0
        let dot = NSView()
        dot.wantsLayer = true
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
        detailLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.sidebarSecondaryFontSizePT)
        detailLabel.textColor = chromeTheme.textMuted
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
