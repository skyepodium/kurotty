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
    private let titleLabel: NSTextField
    private let titleStyler: TerminalSidebarRowTitleStyler
    private let badgeView: TerminalSidebarCountBadgeView

    init(
        display: TerminalCommandHistoryDirectoryDisplay,
        sessionCount: Int,
        chromeTheme: DesignTokens.ChromeTheme
    ) {
        titleLabel = NSTextField(labelWithString: display.lastComponent)
        titleStyler = TerminalSidebarRowTitleStyler(
            role: DesignTokens.Typography.rowTitle,
            restColor: chromeTheme.textPrimary,
            chromeTheme: chromeTheme
        )
        badgeView = TerminalSidebarCountBadgeView(
            text: "\(sessionCount)",
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

        let parentLabel = NSTextField(labelWithString: display.parentDisplay)
        DesignTokens.Typography.rowSecondary.apply(to: parentLabel, color: chromeTheme.textTertiary)
        parentLabel.lineBreakMode = .byTruncatingMiddle
        parentLabel.maximumNumberOfLines = 1
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parentLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        parentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(parentLabel)

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
        badgeView.apply(appearance)
    }
}

/// Session leaf row: agent icon, semibold title, dimmed home-abbreviated
/// working directory, trailing relative time, and a message-count badge.
@MainActor
final class TerminalAgentSessionRowCellView: NSTableCellView {
    private let titleLabel: NSTextField
    private let titleStyler: TerminalSidebarRowTitleStyler
    private let badgeView: TerminalSidebarCountBadgeView
    /// Absent when the session's context window is unknown. Hidden rather than
    /// drawn empty: an inert bar would claim a fact the transcript never gave us.
    private let contextMeterView: TerminalAgentContextMeterView?

    init(
        record: AgentSessionRecord,
        chromeTheme: DesignTokens.ChromeTheme,
        now: Date,
        homeDirectory: String
    ) {
        titleLabel = NSTextField(labelWithString: record.title)
        titleStyler = TerminalSidebarRowTitleStyler(
            role: DesignTokens.Typography.rowTitle,
            restColor: chromeTheme.textSecondary,
            selectedColor: chromeTheme.textPrimary,
            chromeTheme: chromeTheme
        )
        badgeView = TerminalSidebarCountBadgeView(
            text: AgentSessionRowBuilder.messageCountLabel(for: record),
            chromeTheme: chromeTheme
        )
        contextMeterView = record.contextForecast.usedFraction == nil
            ? nil
            : TerminalAgentContextMeterView(
                forecast: record.contextForecast,
                chromeTheme: chromeTheme
            )
        super.init(frame: .zero)

        let iconView = NSImageView()
        iconView.image = Icon.symbol(
            record.agent.symbolName,
            pointSizePT: DesignTokens.Component.agentSessionAgentIconPointSizePT,
            weight: .medium,
            tint: chromeTheme.textTertiary,
            accessibilityDescription: record.agent.displayName
        )
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
        DesignTokens.Typography.rowSecondary.apply(to: directoryLabel, color: chromeTheme.textTertiary)
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.maximumNumberOfLines = 1
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        directoryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(directoryLabel)

        let timeLabel = NSTextField(
            labelWithString: AgentSessionRowBuilder.relativeTimeLabel(for: record, now: now)
        )
        timeLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.Typography.rowSecondary.sizePT,
            weight: DesignTokens.Typography.rowSecondary.weight
        )
        timeLabel.textColor = chromeTheme.textTertiary
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)

        addSubview(badgeView)
        contextMeterView.map(addSubview)

        toolTip = [
            record.title,
            AgentSessionRowBuilder.agentDetailLabel(for: record),
            record.cwd,
            AgentContextForecastCopy.summary(for: record.contextForecast) ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

        let gap = DesignTokens.Component.commandHistoryRowGapPX
        let textGap = DesignTokens.Component.agentSessionRowTextGapPY
        // The meter sits on the lower line, between the directory and the
        // message count, so it never displaces the title.
        let directoryTrailingAnchor = contextMeterView?.leadingAnchor ?? badgeView.leadingAnchor
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: gap),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -textGap),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -gap),

            directoryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            directoryLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: textGap),
            directoryLabel.trailingAnchor.constraint(lessThanOrEqualTo: directoryTrailingAnchor, constant: -gap),

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

        if let contextMeterView {
            NSLayoutConstraint.activate([
                contextMeterView.trailingAnchor.constraint(
                    equalTo: badgeView.leadingAnchor,
                    constant: -gap
                ),
                contextMeterView.centerYAnchor.constraint(equalTo: directoryLabel.centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

extension TerminalAgentSessionRowCellView: TerminalSidebarRowTitleStyling {
    func applySidebarRowTitleStyle(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        titleStyler.apply(appearance, to: titleLabel)
        badgeView.apply(appearance)
        contextMeterView?.apply(appearance)
    }
}

/// Context-window meter for one session row.
///
/// One series and one bar. There is nothing to compare against here — a session
/// has exactly one window and one occupancy — so a legend, a second colour, or
/// a numeric overlay would all be decoration. The exact figures are in the row
/// tooltip; the bar only carries "roughly how full" from across the panel.
///
/// The fill is recessive ink at rest and takes the theme's warning colour only
/// once the window is actually under pressure, so colour still means something
/// when it appears. The accent is never used: it belongs to focus and selection.
@MainActor
final class TerminalAgentContextMeterView: NSView {
    private let filledFraction: CGFloat
    private let isUnderPressure: Bool
    private let chromeTheme: DesignTokens.ChromeTheme
    private var isRowHighlighted = false

    /// - Parameter forecast: must have a known limit; callers omit the meter
    ///   entirely when the window is unknown rather than drawing an empty bar.
    init(forecast: AgentContextForecast, chromeTheme: DesignTokens.ChromeTheme) {
        // Clamped for drawing only. A session that ran past its window before
        // compacting reports more than 100% and paints a full bar, which is the
        // truth the bar can express.
        filledFraction = CGFloat(min(1, max(0, forecast.usedFraction ?? 0)))
        isUnderPressure = forecast.pressure == .warning || forecast.pressure == .exhausted
        self.chromeTheme = chromeTheme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))

        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(AgentContextForecastCopy.accessibilityLabel(for: forecast))

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: DesignTokens.Component.agentContextMeterWidthPX),
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.agentContextMeterHeightPX),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Forwarded by the owning cell, like the count badge: the meter is a
    /// grandchild of the row view and never receives the style callback itself.
    func apply(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        let highlighted = appearance.rail != nil
        guard highlighted != isRowHighlighted else {
            return
        }
        isRowHighlighted = highlighted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }
        let radius = bounds.height / 2
        chromeTheme.textPrimary
            .withAlphaComponent(DesignTokens.Component.agentContextMeterTrackAlphaRATIO)
            .setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        guard filledFraction > 0 else {
            return
        }
        let fillRect = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            // Never narrower than the cap: a 1% bar should still read as a dot
            // rather than vanishing.
            width: max(bounds.height, bounds.width * filledFraction),
            height: bounds.height
        )
        fillColor().setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }

    private func fillColor() -> NSColor {
        guard !isUnderPressure else {
            return chromeTheme.warning
                .withAlphaComponent(DesignTokens.Component.agentContextMeterEmphasisAlphaRATIO)
        }
        let alpha = isRowHighlighted
            ? DesignTokens.Component.agentContextMeterEmphasisAlphaRATIO
            : DesignTokens.Component.agentContextMeterFillAlphaRATIO
        return chromeTheme.textTertiary.withAlphaComponent(alpha)
    }
}

/// Count badge shared by the command-history and agent-session group rows.
///
/// Deliberately not a pill. A fully rounded capsule is the shape the system
/// reserves for status; a count is data, so it takes the smallest radius on the
/// scale and stays visually subordinate to the row title.
@MainActor
final class TerminalSidebarCountBadgeView: NSView {
    private let countLabel: NSTextField
    private let chromeTheme: DesignTokens.ChromeTheme

    init(text: String, chromeTheme: DesignTokens.ChromeTheme) {
        countLabel = NSTextField(labelWithString: text)
        self.chromeTheme = chromeTheme
        super.init(frame: .zero)
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.cornerRadius = DesignTokens.Radius.xsPX
        layer?.backgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(DesignTokens.Component.commandHistoryBadgeBackgroundAlphaRATIO)
            .cgColor
        translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.Typography.badge.sizePT,
            weight: DesignTokens.Typography.badge.weight
        )
        countLabel.textColor = chromeTheme.textTertiary
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

    /// Forwarded by the owning cell: the badge is a grandchild of the row view,
    /// so it never receives the row's style callback directly.
    func apply(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        countLabel.textColor = appearance.rail == nil
            ? chromeTheme.textTertiary
            : chromeTheme.textSecondary
    }
}
