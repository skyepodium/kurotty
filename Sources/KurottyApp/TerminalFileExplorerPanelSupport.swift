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
    static let ignoredBadgeText = "⊘"
    static let modifiedBadgeText = "M"
    static let untrackedBadgeText = "U"
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
        let isDimmed = item.node.isHiddenFile || badge == .ignored
        nameLabel = NSTextField(labelWithString: item.filterDisplayPath ?? item.node.name)
        titleStyler = TerminalSidebarRowTitleStyler(
            baseFontSizePT: DesignTokens.Typography.labelFontSizePT,
            baseWeight: .regular,
            baseColor: isDimmed
                ? chromeTheme.textMuted
                : item.node.kind == .directory ? chromeTheme.textSecondary : chromeTheme.textPrimary,
            chromeTheme: chromeTheme
        )
        super.init(frame: .zero)

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: FileExplorerIcon.symbolName(for: item.node),
            accessibilityDescription: nil
        )
        iconView.contentTintColor = isDimmed || item.node.kind == .directory
            ? chromeTheme.textMuted
            : chromeTheme.textSecondary
        iconView.alphaValue = isDimmed ? FileExplorerMetrics.dimmedAlphaRATIO : 1
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: FileExplorerMetrics.rowIconSizePX,
            weight: .regular
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleStyler.apply(.rest, to: nameLabel)
        nameLabel.alphaValue = isDimmed ? FileExplorerMetrics.dimmedAlphaRATIO : 1
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        let badgeLabel = NSTextField(labelWithString: Self.badgeText(for: badge))
        badgeLabel.font = NSFont.systemFont(
            ofSize: DesignTokens.Typography.statusFontSizePT,
            weight: .semibold
        )
        badgeLabel.textColor = Self.badgeColor(for: badge, chromeTheme: chromeTheme)
        badgeLabel.alignment = .right
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeLabel)

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

            badgeLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameLabel.trailingAnchor,
                constant: FileExplorerMetrics.rowGapPX
            ),
            badgeLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -FileExplorerMetrics.rowInsetXPX
            ),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: FileExplorerMetrics.badgeMinWidthPX
            ),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func badgeText(for badge: FileExplorerGitBadge?) -> String {
        switch badge {
        case .modified: FileExplorerIcon.modifiedBadgeText
        case .untracked: FileExplorerIcon.untrackedBadgeText
        case .ignored: FileExplorerIcon.ignoredBadgeText
        case nil: ""
        }
    }

    private static func badgeColor(
        for badge: FileExplorerGitBadge?,
        chromeTheme: DesignTokens.ChromeTheme
    ) -> NSColor {
        switch badge {
        case .modified: chromeTheme.warning
        case .untracked: chromeTheme.success
        case .ignored, nil: chromeTheme.textMuted
        }
    }
}

extension TerminalFileExplorerRowCellView: TerminalSidebarRowTitleStyling {
    func applySidebarRowTitleStyle(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        titleStyler.apply(appearance, to: nameLabel)
    }
}
