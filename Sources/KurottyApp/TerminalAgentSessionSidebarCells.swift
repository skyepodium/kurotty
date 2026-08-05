import AppKit

/// Reference-type wrappers because NSOutlineView tracks items by object
/// identity. Rebuilt on every reload; expansion state lives in the panel.
@MainActor
final class TerminalAgentSessionGroupOutlineItem: NSObject {
    let group: AgentSessionPanelGroup
    let sessionItems: [TerminalAgentSessionOutlineItem]

    init(group: AgentSessionPanelGroup) {
        self.group = group
        sessionItems = group.sessionsNewestFirst.map(TerminalAgentSessionOutlineItem.init)
    }
}

@MainActor
final class TerminalAgentSessionOutlineItem: NSObject {
    let record: AgentSessionRecord

    init(record: AgentSessionRecord) {
        self.record = record
    }
}

/// Expandable project node for the agent-session sidebar. Mirrors
/// `TerminalCommandHistoryGroupCellView` exactly: folder icon, emphasized last
/// path component, dimmed parent path, and a trailing rounded count badge.
@MainActor
final class TerminalAgentSessionGroupCellView: NSTableCellView {
    private enum Symbol {
        static let folder = "folder"
    }

    private let titleLabel: NSTextField
    private let titleStyler: TerminalSidebarRowTitleStyler

    init(
        display: TerminalCommandHistoryDirectoryDisplay,
        sessionCount: Int,
        chromeTheme: DesignTokens.ChromeTheme
    ) {
        titleLabel = NSTextField(labelWithString: display.lastComponent)
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

        let parentLabel = NSTextField(labelWithString: display.parentDisplay)
        parentLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.sidebarSecondaryFontSizePT)
        parentLabel.textColor = chromeTheme.textMuted
        parentLabel.lineBreakMode = .byTruncatingMiddle
        parentLabel.maximumNumberOfLines = 1
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parentLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        parentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(parentLabel)

        let badgeView = TerminalAgentSessionBadgeView(
            text: "\(sessionCount)",
            chromeTheme: chromeTheme
        )
        addSubview(badgeView)

        toolTip = display.path.isEmpty ? nil : display.path

        let gap = DesignTokens.Component.commandHistoryRowGapPX
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: gap),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            parentLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: gap),
            parentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            parentLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeView.leadingAnchor, constant: -gap),

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

extension TerminalAgentSessionGroupCellView: TerminalSidebarRowTitleStyling {
    func applySidebarRowTitleStyle(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        titleStyler.apply(appearance, to: titleLabel)
    }
}

/// Session leaf row: agent icon, semibold title, dimmed home-abbreviated
/// working directory, trailing relative time, and a message-count badge.
@MainActor
final class TerminalAgentSessionRowCellView: NSTableCellView {
    private let titleLabel: NSTextField
    private let titleStyler: TerminalSidebarRowTitleStyler

    init(
        record: AgentSessionRecord,
        chromeTheme: DesignTokens.ChromeTheme,
        now: Date,
        homeDirectory: String
    ) {
        titleLabel = NSTextField(labelWithString: record.title)
        titleStyler = TerminalSidebarRowTitleStyler(
            baseFontSizePT: DesignTokens.Typography.sidebarGroupNameFontSizePT,
            baseWeight: .semibold,
            baseColor: chromeTheme.textPrimary,
            chromeTheme: chromeTheme
        )
        super.init(frame: .zero)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: record.agent.symbolName, accessibilityDescription: record.agent.displayName)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: DesignTokens.Component.agentSessionAgentIconPointSizePT,
                weight: .medium
            ))
        iconView.contentTintColor = chromeTheme.textSecondary
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleStyler.apply(.rest, to: titleLabel)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let directoryLabel = NSTextField(
            labelWithString: AgentSessionRowBuilder.directoryLabel(for: record, homeDirectory: homeDirectory)
        )
        directoryLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.sidebarSecondaryFontSizePT)
        directoryLabel.textColor = chromeTheme.textMuted
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.maximumNumberOfLines = 1
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        directoryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(directoryLabel)

        let timeLabel = NSTextField(
            labelWithString: AgentSessionRowBuilder.relativeTimeLabel(for: record, now: now)
        )
        timeLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.sidebarSecondaryFontSizePT)
        timeLabel.textColor = chromeTheme.textMuted
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)

        let badgeView = TerminalAgentSessionBadgeView(
            text: AgentSessionRowBuilder.messageCountLabel(for: record),
            chromeTheme: chromeTheme
        )
        addSubview(badgeView)

        toolTip = [record.title, AgentSessionRowBuilder.agentDetailLabel(for: record), record.cwd]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let gap = DesignTokens.Component.commandHistoryRowGapPX
        let textGap = DesignTokens.Component.agentSessionRowTextGapPY
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: gap),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -textGap),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -gap),

            directoryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            directoryLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: textGap),
            directoryLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeView.leadingAnchor, constant: -gap),

            timeLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DesignTokens.Component.commandHistoryRowInsetXPX
            ),
            timeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timeLabel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: DesignTokens.Component.commandHistoryTimeLabelMinWidthPX
            ),

            badgeView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DesignTokens.Component.commandHistoryRowInsetXPX
            ),
            badgeView.centerYAnchor.constraint(equalTo: directoryLabel.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

extension TerminalAgentSessionRowCellView: TerminalSidebarRowTitleStyling {
    func applySidebarRowTitleStyle(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        titleStyler.apply(appearance, to: titleLabel)
    }
}

/// Rounded count badge sharing the command-history badge metrics so both
/// left-panel sections render identical pills.
@MainActor
final class TerminalAgentSessionBadgeView: NSView {
    init(text: String, chromeTheme: DesignTokens.ChromeTheme) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Component.commandHistoryBadgeHeightPX / 2
        layer?.backgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(DesignTokens.Component.commandHistoryBadgeBackgroundAlphaRATIO)
            .cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: text)
        countLabel.font = NSFont.systemFont(
            ofSize: DesignTokens.Typography.sidebarBadgeFontSizePT,
            weight: .medium
        )
        countLabel.textColor = chromeTheme.textSecondary
        countLabel.alignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.commandHistoryBadgeHeightPX),
            widthAnchor.constraint(
                greaterThanOrEqualToConstant: DesignTokens.Component.commandHistoryBadgeMinWidthPX
            ),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DesignTokens.Component.commandHistoryBadgeTextInsetXPX
            ),
            countLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DesignTokens.Component.commandHistoryBadgeTextInsetXPX
            ),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
