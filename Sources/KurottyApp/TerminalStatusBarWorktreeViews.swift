import AppKit

/// The status bar's git-worktree surfaces: the leading worktree segment and the
/// popover that lists the repository's worktrees.
///
/// Both render already-final copy from `TerminalStatusBarWorktreeModel` over a
/// `TerminalGitWorktreeSnapshot`. Neither observes anything, so a dismissed
/// popover leaves no timers or observers behind.

// MARK: - Worktree segment

/// Leading segment, right of the agent segment: the branch of the git worktree
/// the active pane's working directory belongs to, with a count badge once the
/// repository has more than one worktree.
///
/// The segment hides itself whenever the pane is not inside a worktree, so a
/// non-repository directory costs no chrome at all. Nothing here uses the
/// accent color: the accent stays reserved for focus and selection.
@MainActor
final class TerminalStatusBarWorktreeSegmentView: TerminalStatusBarSegmentView {
    private let glyphView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private var summary = TerminalStatusBarWorktreeSummary.absent
    private var visibility = TerminalStatusBarVisibility.full

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var currentSummary: TerminalStatusBarWorktreeSummary {
        summary
    }

    private func configureContent() {
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.imageScaling = .scaleProportionallyDown
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.wantsLayer = true
        badgeContainer.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        badgeContainer.layer?.cornerRadius = DesignTokens.Component.StatusBar.badgeCornerRadiusPX

        labelField.font = DesignTokens.Typography.statusBar.font
        labelField.lineBreakMode = .byTruncatingTail
        labelField.isSelectable = false
        labelField.cell?.truncatesLastVisibleLine = true

        badgeField.font = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.Component.StatusBar.badgeFontSizePT,
            weight: DesignTokens.Typography.badge.weight
        )
        badgeField.isSelectable = false
        badgeField.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeField)

        contentStackView.addArrangedSubview(glyphView)
        contentStackView.addArrangedSubview(labelField)
        contentStackView.addArrangedSubview(badgeContainer)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.glyphLabelGapPX, after: glyphView)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.labelDetailGapPX, after: labelField)

        NSLayoutConstraint.activate([
            glyphView.widthAnchor.constraint(equalToConstant: DesignTokens.Component.StatusBar.iconPointSizePT),
            glyphView.heightAnchor.constraint(equalToConstant: DesignTokens.Component.StatusBar.iconPointSizePT),
            labelField.widthAnchor.constraint(
                lessThanOrEqualToConstant: DesignTokens.Component.StatusBar.worktreeLabelMaxWidthPX
            ),
            badgeContainer.heightAnchor.constraint(equalToConstant: DesignTokens.Component.StatusBar.badgeHeightPX),
            badgeField.leadingAnchor.constraint(
                equalTo: badgeContainer.leadingAnchor,
                constant: DesignTokens.Component.StatusBar.badgeTextInsetXPX
            ),
            badgeField.trailingAnchor.constraint(
                equalTo: badgeContainer.trailingAnchor,
                constant: -DesignTokens.Component.StatusBar.badgeTextInsetXPX
            ),
            badgeField.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
        ])
        // Nothing is known about the pane's directory yet, so the segment
        // starts hidden rather than as an empty click target.
        applyContent()
    }

    func update(summary: TerminalStatusBarWorktreeSummary, visibility: TerminalStatusBarVisibility) {
        guard summary != self.summary || visibility != self.visibility else {
            return
        }
        self.summary = summary
        self.visibility = visibility
        applyContent()
    }

    override func applyThemeToContent() {
        applyContent()
    }

    override func applyHoverState(isHovered: Bool) {
        labelField.textColor = isHovered ? chromeTheme.textPrimary : chromeTheme.textSecondary
    }

    private func applyContent() {
        isHidden = !summary.isPresent || !visibility.showsWorktree
        glyphView.image = Icon.symbol(
            IconSymbol.worktree,
            pointSizePT: DesignTokens.Component.StatusBar.iconPointSizePT,
            weight: .medium,
            tint: chromeTheme.textMuted
        )
        labelField.stringValue = summary.displayText
        labelField.textColor = chromeTheme.textSecondary

        let showsBadge = summary.worktreeCount > 1
        badgeContainer.isHidden = !showsBadge
        badgeField.stringValue = showsBadge ? "\(summary.worktreeCount)" : ""
        badgeField.textColor = chromeTheme.textMuted
        badgeContainer.layer?.backgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(DesignTokens.Component.StatusBar.hoverFillAlphaRATIO)
            .cgColor

        toolTip = summary.tooltip.isEmpty ? nil : summary.tooltip
    }
}

// MARK: - Worktree popover

/// Worktree-segment popover: one row per checkout of the repository, each
/// carrying its branch, its uncommitted-changes marker, whether it is the main
/// worktree, and how many indexed agent sessions are working inside it.
///
/// Selecting a row inserts a `cd` command at the prompt through the same
/// insert-only path the agent resume row uses. Nothing here executes anything.
@MainActor
final class TerminalStatusBarWorktreeListView: NSView {
    /// Inserts `cd '<path>'` at the prompt. Never executes it.
    var onChangeDirectory: ((GitWorktree) -> Void)?

    private let theme: DesignTokens.ChromeTheme
    private var changeDirectoryRows: [Int: GitWorktree] = [:]

    init(rows: [GitWorktreeRow], theme: DesignTokens.ChromeTheme) {
        self.theme = theme
        super.init(frame: .zero)
        configure(rows: rows)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(rows: [GitWorktreeRow]) {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = DesignTokens.Component.StatusBar.popoverRowGapPX
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        stackView.addArrangedSubview(TerminalStatusBarPopoverText.header(
            AppLocalization.string(.statusBarWorktreeTitle),
            theme: theme
        ))

        let visibleRows = rows.prefix(DesignTokens.Component.StatusBar.popoverMaximumRowCount)
        if visibleRows.isEmpty {
            stackView.addArrangedSubview(TerminalStatusBarPopoverText.secondary(
                AppLocalization.string(.statusBarNoWorktrees),
                theme: theme
            ))
        }
        for (index, row) in visibleRows.enumerated() {
            stackView.addArrangedSubview(makeRow(row, index: index))
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: DesignTokens.Component.StatusBar.popoverWidthPX),
            stackView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DesignTokens.Component.StatusBar.popoverInsetPX
            ),
            stackView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DesignTokens.Component.StatusBar.popoverInsetPX
            ),
            stackView.topAnchor.constraint(
                equalTo: topAnchor,
                constant: DesignTokens.Component.StatusBar.popoverInsetPX
            ),
            stackView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -DesignTokens.Component.StatusBar.popoverInsetPX
            ),
        ])
    }

    private func makeRow(_ row: GitWorktreeRow, index: Int) -> NSView {
        let rowStackView = NSStackView()
        rowStackView.orientation = .horizontal
        rowStackView.alignment = .centerY
        rowStackView.spacing = DesignTokens.Component.StatusBar.labelDetailGapPX

        // The worktree the pane is already in is the selected one, so it is the
        // single place in this popover where the accent is allowed.
        let nameField = TerminalStatusBarPopoverText.primary(
            TerminalStatusBarWorktreeText.rowName(for: row),
            theme: theme
        )
        nameField.textColor = row.isCurrent ? theme.accent : theme.textPrimary
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailField = TerminalStatusBarPopoverText.secondary(
            TerminalStatusBarWorktreeText.rowDetail(for: row),
            theme: theme
        )
        detailField.lineBreakMode = .byTruncatingTail

        rowStackView.addArrangedSubview(nameField)
        rowStackView.addArrangedSubview(detailField)

        // The current worktree needs no "cd here" affordance.
        if !row.isCurrent {
            let changeDirectoryButton = NSButton(
                title: AppLocalization.string(.statusBarWorktreeChangeDirectory),
                target: self,
                action: #selector(changeDirectoryButtonPressed(_:))
            )
            changeDirectoryButton.tag = index
            changeDirectoryButton.bezelStyle = .inline
            changeDirectoryButton.controlSize = .small
            changeDirectoryButton.font = DesignTokens.Typography.statusBar.font
            changeDirectoryRows[index] = row.worktree
            rowStackView.addArrangedSubview(changeDirectoryButton)
        }

        rowStackView.toolTip = row.worktree.path
        rowStackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rowStackView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.StatusBar.popoverRowHeightPX
            ),
            nameField.widthAnchor.constraint(
                lessThanOrEqualToConstant: DesignTokens.Component.StatusBar.worktreeRowBranchMaxWidthPX
            ),
        ])
        return rowStackView
    }

    @objc private func changeDirectoryButtonPressed(_ sender: NSButton) {
        guard let worktree = changeDirectoryRows[sender.tag] else {
            return
        }
        onChangeDirectory?(worktree)
    }
}
