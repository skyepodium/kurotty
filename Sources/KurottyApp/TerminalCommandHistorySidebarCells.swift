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
    /// `/` jumps to the panel's filter field.
    ///
    /// It takes the key away from `NSOutlineView`'s type-select, which is the
    /// right trade in this list: type-select matches a row's leading characters,
    /// and these rows lead with `git`, `swift`, or `cd`, so it lands on the
    /// wrong row far more often than the filter does. The field it jumps to
    /// searches the whole command.
    var onFilterKey: (() -> Void)?

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
        if TerminalSidebarFilterKey.matches(event), let onFilterKey {
            onFilterKey()
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

    /// `makeView` replaces AppKit's smaller stock disclosure image with our
    /// 16pt box. Keeping the stock origin after that resize pushes the chevron
    /// below the folder/title band. Recompute the whole frame from the row so
    /// all three elements share the same visual centre.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        Self.disclosureFrame(
            rowFrame: rect(ofRow: row),
            baseFrame: super.frameOfOutlineCell(atRow: row)
        )
    }

    static func disclosureFrame(rowFrame: NSRect, baseFrame: NSRect) -> NSRect {
        let size = DesignTokens.Component.commandHistoryDisclosureBoxSizePX
        // NSOutlineView is flipped: the group cell moves its folder/title up
        // by half of the reserved top air, so the disclosure must subtract the
        // same amount. Adding it places the chevron below the shared centreline
        // in both the history and agent-session sections.
        let visualContentCenterY = rowFrame.midY
            - DesignTokens.Component.commandHistoryGroupRowTopAirPX / 2
        return NSRect(
            x: baseFrame.minX,
            y: visualContentCenterY - size / 2,
            width: size,
            height: size
        )
    }
}

/// Command-history and agent-session sidebar row. All painting lives in the
/// shared `TerminalSidebarRowView` so history, agent sessions, and the file
/// explorer cannot drift apart.
@MainActor
final class TerminalCommandHistorySidebarRowView: TerminalSidebarRowView {}

/// Expandable project node: folder icon, emphasized last path component,
/// dimmed parent path, and a trailing rounded count badge.
///
/// This row is the history list's section header, so its content is pinned to
/// the bottom of a taller row and the space above it is left empty. That air is
/// the whole vertical-rhythm budget the reference sidebars spend on every row,
/// spent instead on the ten rows where it separates something.
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
        DesignTokens.Typography.rowSecondary.apply(to: parentLabel, color: chromeTheme.textSecondary)
        parentLabel.lineBreakMode = .byTruncatingMiddle
        parentLabel.maximumNumberOfLines = 1
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parentLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        parentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(parentLabel)

        addSubview(badgeView)

        toolTip = group.display.path.isEmpty ? nil : group.display.path

        let gap = DesignTokens.Component.commandHistoryRowGapPX
        // Unflipped row geometry: the air is at the high-y edge, so the content
        // band's centre sits half the air below the cell's own centre.
        let airOffset = -DesignTokens.Component.commandHistoryGroupRowTopAirPX / 2
        NSLayoutConstraint.activate(
            TerminalSidebarRowLayout.leadingSlotConstraints(glyphView: iconView, in: self) + [
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: airOffset),

                nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: gap),
                nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: airOffset),

                parentLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: gap),
                parentLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: airOffset),
                parentLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: badgeView.leadingAnchor,
                    constant: -gap
                ),

                badgeView.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -DesignTokens.Component.commandHistoryRowInsetXPX
                ),
                badgeView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: airOffset),
            ]
        )
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
            restColor: chromeTheme.textPrimary,
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
        detailLabel.textColor = chromeTheme.textSecondary
        detailLabel.alignment = .right
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        toolTip = entry.commandText

        let gap = DesignTokens.Component.commandHistoryRowGapPX
        let dotSize = DesignTokens.Component.commandHistoryStatusDotSizePX
        // The dot is centred in a reserved slot rather than pinned to the row
        // edge, and the command text starts after the whole slot. The slot is
        // one outline level narrower than a directory row's icon slot, so the
        // command column lands on the directory-name column above it by
        // construction — it used to happen to line up because a 6pt dot and a
        // 12pt folder glyph differed by roughly the indentation.
        let slot = DesignTokens.Component.sidebarRowStatusSlotWidthPX
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: leadingAnchor, constant: slot / 2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: dotSize),
            dot.heightAnchor.constraint(equalToConstant: dotSize),

            commandLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: slot + gap),
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
