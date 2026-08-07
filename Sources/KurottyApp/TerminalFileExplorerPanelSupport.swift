import AppKit

/// Support pieces for `TerminalFileExplorerPanelView`: file icons and the row
/// cell. Localized copy lives in `AppLocalization` (fileExplorer* keys).

// MARK: - Remote-session copy

/// Thin presentation helper over the shared `fileExplorerRemote*` localization
/// keys; the panel's only formatting need is substituting the `user@host:/srv`
/// label into the explanation.
enum FileExplorerRemoteCopy {
    static func title(language: AppLanguage = AppLocalization.language) -> String {
        AppLocalization.string(.fileExplorerRemoteTitle, language: language)
    }

    /// `hostPath` is the `user@host:/srv/app` label for the active session.
    static func explanation(
        hostPath: String,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        String(
            format: AppLocalization.string(.fileExplorerRemoteExplanation, language: language),
            locale: Locale(identifier: language.rawValue),
            hostPath
        )
    }
}

// MARK: - Agent provenance copy

/// Tooltip copy for a file an agent wrote. Pure so the wording is testable
/// without building a row.
enum FileExplorerAgentTouchCopy {
    private static let lineSeparator = "\n"

    /// `Changed by Claude Code · 2h` plus the prompt line when the transcript
    /// recorded one.
    static func tooltip(
        for touch: AgentFileTouch,
        now: Date,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        let locale = Locale(identifier: language.rawValue)
        let title = String(
            format: AppLocalization.string(.fileExplorerAgentTouchTitle, language: language),
            locale: locale,
            touch.agent.displayName,
            TerminalCommandHistoryRowBuilder.relativeTimeLabel(from: touch.changedAt, to: now)
        )
        guard let prompt = touch.promptExcerpt else {
            return title
        }
        let promptLine = String(
            format: AppLocalization.string(.fileExplorerAgentTouchPrompt, language: language),
            locale: locale,
            prompt
        )
        return title + lineSeparator + promptLine
    }
}

// MARK: - Icons

enum FileExplorerIcon {
    /// Filled, and the only tinted glyph in the leading column.
    ///
    /// Directories carry the tree's structure, so the one thing the leading
    /// column has to answer instantly is "is this a folder or a file". The
    /// outline `folder` answered it with a notch in a rounded rectangle and the
    /// outline `doc` answered with a fold in the same rectangle, which at 13pt
    /// is the same shape twice. Fill plus tint makes the answer two independent
    /// channels — ink coverage and hue — so it still reads for a user who
    /// cannot separate the hues, and it still reads at a glance for one who can.
    ///
    /// Deliberately *not* carrying git state as well. The row already has a
    /// reserved git column and a reserved agent column, and encoding the same
    /// fact a second time in a different visual language is exactly what the
    /// agent ring was shaped to avoid.
    static let folderSymbolName = IconSymbol.folderFilled
    static let refreshSymbolName = IconSymbol.refresh
    /// Empty-state glyph for a working directory that lives on another machine.
    static let remoteSymbolName = "network"
    /// Conflict is the only git state that still earns a glyph: it is the one
    /// the user has to act on, and a triangle says so where a dot cannot.
    static let conflictSymbolName = "exclamationmark.triangle.fill"
    private static let defaultFileSymbolName = "doc"
    private static let symbolNameByExtension: [String: String] = [
        "swift": "swift",
        "zig": "chevron.left.forwardslash.chevron.right",
        "c": "chevron.left.forwardslash.chevron.right",
        "h": "chevron.left.forwardslash.chevron.right",
        "metal": "chevron.left.forwardslash.chevron.right",
        "sh": "terminal",
        "md": "doc.text",
        "txt": "doc.text",
        "json": "curlybraces",
        "yml": "curlybraces",
        "yaml": "curlybraces",
        "toml": "curlybraces",
        "plist": "curlybraces",
        "png": "photo",
        "jpg": "photo",
        "jpeg": "photo",
        "gif": "photo",
        "icns": "photo",
        "bmp": "photo",
        "heic": "photo",
        "heif": "photo",
        "tiff": "photo",
        "webp": "photo",
        "svg": "photo",
    ]

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "icns", "bmp", "heic", "heif", "tiff", "webp", "svg"
    ]

    static func symbolName(for node: FileExplorerNode) -> String {
        guard node.kind == .file else {
            return folderSymbolName
        }
        let fileExtension = node.url.pathExtension.lowercased()
        return symbolNameByExtension[fileExtension] ?? defaultFileSymbolName
    }

    static func isImageFile(_ node: FileExplorerNode) -> Bool {
        imageExtensions.contains(node.url.pathExtension.lowercased())
    }
}

// MARK: - Inline action error

/// One-line notice for a create, rename, or trash that did not happen.
///
/// A failed write is ordinary in this panel — no permission, a read-only
/// volume, a path the terminal beside it already moved — so it is said here
/// while the tree stays put, rather than in an alert that stops the window.
///
/// The row collapses to nothing when there is no message, its top padding
/// included, so a panel that has refused nothing keeps exactly the layout it
/// had before this existed.
@MainActor
final class TerminalFileExplorerActionErrorRow: NSView {
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var collapsedHeightConstraint = heightAnchor.constraint(equalToConstant: 0)

    /// `nil` while the row is collapsed away.
    private(set) var message: String?

    init(chromeTheme: DesignTokens.ChromeTheme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        applyChromeTheme(chromeTheme)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        // The collapsed height is what keeps the quiet panel unchanged, so the
        // label has to yield to it rather than insist on its intrinsic height.
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(messageLabel)

        collapsedHeightConstraint.isActive = true
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageLabel.topAnchor.constraint(
                equalTo: topAnchor,
                constant: DesignTokens.Component.fileExplorerActionErrorPaddingYPX
            ),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `nil` clears the row and gives its space back.
    func present(_ message: String?) {
        self.message = message
        messageLabel.stringValue = message ?? ""
        isHidden = message == nil
        collapsedHeightConstraint.isActive = message == nil
        needsLayout = true
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        DesignTokens.Typography.rowSecondary.apply(to: messageLabel, color: theme.error)
    }
}

// MARK: - Row cell

/// File-explorer sidebar row. Painting lives in the shared
/// `TerminalSidebarRowView` so the explorer and the history/agent lists share
/// one three-state row system.
@MainActor
final class TerminalFileExplorerSidebarRowView: TerminalSidebarRowView {}

@MainActor
final class TerminalFileExplorerRowCellView: NSTableCellView {
    private let nameLabel: NSTextField
    private let titleStyler: TerminalSidebarRowTitleStyler

    init(
        item: TerminalFileExplorerOutlineItem,
        badge: FileExplorerGitBadge?,
        agentMarker: FileExplorerAgentMarker = .none,
        now: Date = Date(),
        chromeTheme: DesignTokens.ChromeTheme
    ) {
        let isDirectory = item.node.kind == .directory
        // Ignored entries carry no dot at all; the whole row drops a rank
        // instead, which says "present but out of play" without a glyph.
        let isDimmed = item.node.isHiddenFile || badge == .ignored
        // Dimming is a color, never `alphaValue`: alpha also dims the subpixel
        // antialiasing, so a faded label loses stroke weight as well as
        // contrast and stops looking like the same typeface.
        let dimmedColor = chromeTheme.textTertiary.withAlphaComponent(
            DesignTokens.Component.fileExplorerDimmedTextAlphaRATIO
        )
        nameLabel = NSTextField(labelWithString: item.filterDisplayPath ?? item.node.name)
        titleStyler = TerminalSidebarRowTitleStyler(
            role: DesignTokens.Typography.rowTitle,
            restColor: isDimmed ? dimmedColor : chromeTheme.textSecondary,
            selectedColor: isDimmed ? dimmedColor : chromeTheme.textPrimary,
            chromeTheme: chromeTheme
        )
        super.init(frame: .zero)

        let iconView = NSImageView()
        iconView.image = Icon.symbol(
            FileExplorerIcon.symbolName(for: item.node),
            pointSizePT: DesignTokens.Component.fileExplorerRowIconPointSizePT,
            weight: .regular,
            tint: Self.iconColor(
                isDimmed: isDimmed,
                isDirectory: isDirectory,
                dimmedColor: dimmedColor,
                chromeTheme: chromeTheme
            )
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleStyler.apply(.rest, to: nameLabel)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        let agentSlotView = TerminalFileExplorerAgentSlotView(
            marker: agentMarker,
            chromeTheme: chromeTheme
        )
        addSubview(agentSlotView)

        let gitSlotView = TerminalFileExplorerGitSlotView(badge: badge, chromeTheme: chromeTheme)
        addSubview(gitSlotView)

        // The tooltip is the reveal path for provenance: the marker says an
        // agent wrote this, hovering says which agent and from which prompt.
        toolTip = agentMarker.touch.map { FileExplorerAgentTouchCopy.tooltip(for: $0, now: now) }

        NSLayoutConstraint.activate(
            TerminalSidebarRowLayout.leadingSlotConstraints(
                glyphView: iconView,
                in: self,
                leadingInsetPX: DesignTokens.Component.fileExplorerRowInsetXPX
            ) + [
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

                nameLabel.leadingAnchor.constraint(
                    equalTo: iconView.trailingAnchor,
                    constant: DesignTokens.Component.fileExplorerRowGapPX
                ),
                nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

                agentSlotView.leadingAnchor.constraint(
                    greaterThanOrEqualTo: nameLabel.trailingAnchor,
                    constant: DesignTokens.Component.fileExplorerRowGapPX
                ),
                agentSlotView.trailingAnchor.constraint(equalTo: gitSlotView.leadingAnchor),
                agentSlotView.centerYAnchor.constraint(equalTo: centerYAnchor),

                gitSlotView.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -DesignTokens.Component.fileExplorerRowInsetXPX
                ),
                gitSlotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func iconColor(
        isDimmed: Bool,
        isDirectory: Bool,
        dimmedColor: NSColor,
        chromeTheme: DesignTokens.ChromeTheme
    ) -> NSColor {
        guard !isDimmed else {
            return dimmedColor
        }
        // Folders take the accent so the tree's structure is readable at a
        // glance; files stay at the lowest text rank. The tint is a meaningful
        // graphic rather than decoration — it is half of what says "directory" —
        // so it answers to WCAG 1.4.11 at 3:1 against every surface it can land
        // on, which `DesignTokenColorRampTests` measures rather than assumes.
        return isDirectory
            ? chromeTheme.accent.withAlphaComponent(
                DesignTokens.Component.fileExplorerFolderIconAlphaRATIO
            )
            : chromeTheme.textTertiary
    }
}

/// Fixed-width git column for one explorer row.
///
/// The column is a reserved 14x14 slot whatever the row's state is. The
/// previous `M` / `U` / `⊘` letters had different optical weights and baselines,
/// so the name column beside them shifted from row to row; a slot plus a 5pt dot
/// cannot.
@MainActor
final class TerminalFileExplorerGitSlotView: NSView {
    private let badge: FileExplorerGitBadge?
    private let chromeTheme: DesignTokens.ChromeTheme

    init(badge: FileExplorerGitBadge?, chromeTheme: DesignTokens.ChromeTheme) {
        self.badge = badge
        self.chromeTheme = chromeTheme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(
                equalToConstant: DesignTokens.Component.fileExplorerGitSlotSizePX
            ),
            heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.fileExplorerGitSlotSizePX
            ),
        ])
        configureConflictGlyphIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard badge != .conflicted, let dotColor else {
            return
        }
        let size = DesignTokens.Component.fileExplorerGitDotSizePX
        let dotRect = NSRect(
            x: bounds.midX - size / 2,
            y: bounds.midY - size / 2,
            width: size,
            height: size
        )
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    /// Conflict is the one state that outgrows a dot, so it gets a glyph
    /// centered in the same reserved slot.
    private func configureConflictGlyphIfNeeded() {
        guard badge == .conflicted else {
            return
        }
        let glyphView = NSImageView()
        glyphView.image = Icon.symbol(
            FileExplorerIcon.conflictSymbolName,
            pointSizePT: DesignTokens.Component.fileExplorerGitConflictPointSizePT,
            weight: .regular,
            tint: chromeTheme.error
        )
        glyphView.imageScaling = .scaleNone
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphView)
        NSLayoutConstraint.activate([
            glyphView.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// `nil` means the slot stays empty: clean files and ignored entries both
    /// draw nothing, and ignored rows are already demoted as a whole row.
    private var dotColor: NSColor? {
        switch badge {
        case .modified:
            return chromeTheme.warning
        case .untracked:
            return chromeTheme.success
        case .staged:
            return chromeTheme.accent
        case .conflicted, .ignored, nil:
            return nil
        }
    }
}

/// Fixed-width agent-provenance column, immediately before the git column.
///
/// Draws a hollow ring rather than a fourth dot color. Git already owns the
/// filled-dot vocabulary in this row, and at 6 px a difference in shape is
/// legible where a difference in hue is not — especially since "an agent wrote
/// this" and "this differs from HEAD" are frequently true at the same time.
/// Like the git slot, the column is reserved whether or not it draws, so the
/// name beside it never shifts.
@MainActor
final class TerminalFileExplorerAgentSlotView: NSView {
    private let marker: FileExplorerAgentMarker
    private let chromeTheme: DesignTokens.ChromeTheme

    init(marker: FileExplorerAgentMarker, chromeTheme: DesignTokens.ChromeTheme) {
        self.marker = marker
        self.chromeTheme = chromeTheme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(
                equalToConstant: DesignTokens.Component.fileExplorerAgentSlotSizePX
            ),
            heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.fileExplorerAgentSlotSizePX
            ),
        ])
        guard marker.hasRecentChange else {
            return
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(AppLocalization.string(.fileExplorerAgentTouchAccessibility))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard marker.hasRecentChange else {
            return
        }
        let diameter = DesignTokens.Component.fileExplorerAgentRingDiameterPX
        let lineWidth = DesignTokens.Component.fileExplorerAgentRingLineWidthPX
        // Inset by half the stroke: NSBezierPath centers the line on the path,
        // so an uninset oval would paint outside the reserved slot.
        let ringRect = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        .insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = NSBezierPath(ovalIn: ringRect)
        path.lineWidth = lineWidth
        chromeTheme.accent
            .withAlphaComponent(DesignTokens.Component.fileExplorerAgentRingAlphaRATIO)
            .setStroke()
        path.stroke()
    }
}

extension TerminalFileExplorerRowCellView: TerminalSidebarRowTitleStyling {
    func applySidebarRowTitleStyle(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        titleStyler.apply(appearance, to: nameLabel)
    }
}
