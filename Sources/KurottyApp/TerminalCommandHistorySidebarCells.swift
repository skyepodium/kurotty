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

/// Sidebar row with a rounded accent-tinted selection highlight and a subtle
/// hover highlight, drawn from chrome-theme colors so both light and dark
/// presets stay correct.
@MainActor
final class TerminalCommandHistorySidebarRowView: NSTableRowView {
    var hoverBackgroundColor: NSColor = .clear
    var selectionBackgroundColor: NSColor = .clear
    private var isMouseInside = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isMouseInside, !isSelected else {
            return
        }
        fillHighlight(with: hoverBackgroundColor)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else {
            return
        }
        fillHighlight(with: selectionBackgroundColor)
    }

    private func fillHighlight(with color: NSColor) {
        let highlightRect = bounds.insetBy(
            dx: DesignTokens.Component.commandHistoryRowHighlightInsetXPX,
            dy: DesignTokens.Component.commandHistoryRowHighlightInsetYPX
        )
        let radius = DesignTokens.Component.commandHistoryRowCornerRadiusPX
        color.setFill()
        NSBezierPath(roundedRect: highlightRect, xRadius: radius, yRadius: radius).fill()
    }
}

/// Expandable project node: folder icon, emphasized last path component,
/// dimmed parent path, and a trailing rounded count badge.
@MainActor
final class TerminalCommandHistoryGroupCellView: NSTableCellView {
    private enum Symbol {
        static let folder = "folder"
    }

    init(group: TerminalCommandHistoryPanelGroup, chromeTheme: DesignTokens.ChromeTheme) {
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

        let nameLabel = NSTextField(labelWithString: group.display.lastComponent)
        nameLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.sidebarGroupNameFontSizePT, weight: .semibold)
        nameLabel.textColor = chromeTheme.textPrimary
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

/// Command leaf row: status dot, monospaced command text with middle
/// truncation, and a trailing relative-time detail (failures append the exit
/// code in dimmed text).
@MainActor
final class TerminalCommandHistoryCommandCellView: NSTableCellView {
    init(entry: TerminalCommandHistoryEntry, chromeTheme: DesignTokens.ChromeTheme, now: Date) {
        super.init(frame: .zero)

        let didSucceed = (entry.exitCode ?? 0) == 0
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = DesignTokens.Component.commandHistoryStatusDotSizePX / 2
        dot.layer?.backgroundColor = didSucceed
            ? DesignTokens.Color.successGreen.cgColor
            : DesignTokens.Color.errorRed.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        let commandLabel = NSTextField(labelWithString: entry.commandText)
        commandLabel.font = NSFont.monospacedSystemFont(
            ofSize: DesignTokens.Typography.sidebarCommandFontSizePT,
            weight: .regular
        )
        commandLabel.textColor = chromeTheme.textPrimary
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
