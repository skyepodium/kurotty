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

// MARK: - Icons

enum FileExplorerIcon {
    static let folderSymbolName = "folder"
    static let refreshSymbolName = "arrow.clockwise"
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
        iconView.image = NSImage(
            systemSymbolName: FileExplorerIcon.symbolName(for: item.node),
            accessibilityDescription: nil
        )
        iconView.contentTintColor = Self.iconColor(
            isDimmed: isDimmed,
            isDirectory: isDirectory,
            dimmedColor: dimmedColor,
            chromeTheme: chromeTheme
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: DesignTokens.Component.fileExplorerRowIconPointSizePT,
            weight: .regular
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleStyler.apply(.rest, to: nameLabel)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        let gitSlotView = TerminalFileExplorerGitSlotView(badge: badge, chromeTheme: chromeTheme)
        addSubview(gitSlotView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: FileExplorerMetrics.rowInsetXPX
            ),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameLabel.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: FileExplorerMetrics.rowGapPX
            ),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            gitSlotView.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameLabel.trailingAnchor,
                constant: FileExplorerMetrics.rowGapPX
            ),
            gitSlotView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -FileExplorerMetrics.rowInsetXPX
            ),
            gitSlotView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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
        // Folders take a quiet accent so the tree's structure is readable at a
        // glance; files stay at the lowest text rank.
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
        glyphView.image = NSImage(
            systemSymbolName: FileExplorerIcon.conflictSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(
            pointSize: DesignTokens.Component.fileExplorerGitConflictPointSizePT,
            weight: .regular
        ))
        glyphView.contentTintColor = chromeTheme.error
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

extension TerminalFileExplorerRowCellView: TerminalSidebarRowTitleStyling {
    func applySidebarRowTitleStyle(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        titleStyler.apply(appearance, to: nameLabel)
    }
}
