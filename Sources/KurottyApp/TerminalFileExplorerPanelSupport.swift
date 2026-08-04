import AppKit

/// Support pieces for `TerminalFileExplorerPanelView`: panel-local localized
/// copy, file icons, and the row cell.

// MARK: - Localized copy

/// Panel-local strings mirroring `AppLocalization`'s language resolution.
/// The coordinator should migrate these keys into `AppLocalization` when it
/// wires the panel (that file is owned by a concurrent change right now).
enum FileExplorerL10n {
    enum Key {
        case searchPlaceholder, segmentName, segmentContent, refresh
        case open, revealInFinder, copyPath, insertPathIntoTerminal
    }

    static func string(_ key: Key) -> String {
        translations[AppLocalization.language]?[key]
            ?? translations[.english]?[key]
            ?? ""
    }

    private static let translations: [AppLanguage: [Key: String]] = [
        .english: [
            .searchPlaceholder: "Find files", .segmentName: "Name", .segmentContent: "Content",
            .refresh: "Refresh",
            .open: "Open", .revealInFinder: "Reveal in Finder", .copyPath: "Copy Path",
            .insertPathIntoTerminal: "Insert Path into Terminal",
        ],
        .korean: [
            .searchPlaceholder: "파일 찾기", .segmentName: "이름", .segmentContent: "내용",
            .refresh: "새로 고침",
            .open: "열기", .revealInFinder: "Finder에서 보기", .copyPath: "경로 복사",
            .insertPathIntoTerminal: "터미널에 경로 입력",
        ],
        .japanese: [
            .searchPlaceholder: "ファイルを検索", .segmentName: "名前", .segmentContent: "内容",
            .refresh: "再読み込み",
            .open: "開く", .revealInFinder: "Finderで表示", .copyPath: "パスをコピー",
            .insertPathIntoTerminal: "ターミナルにパスを挿入",
        ],
    ]
}

// MARK: - Icons

enum FileExplorerIcon {
    static let folderSymbolName = "folder"
    static let refreshSymbolName = "arrow.clockwise"
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
    ]

    static func symbolName(for node: FileExplorerNode) -> String {
        guard node.kind == .file else {
            return folderSymbolName
        }
        let fileExtension = node.url.pathExtension.lowercased()
        return symbolNameByExtension[fileExtension] ?? defaultFileSymbolName
    }
}

// MARK: - Row cell

@MainActor
final class TerminalFileExplorerRowCellView: NSTableCellView {
    init(
        item: TerminalFileExplorerOutlineItem,
        badge: FileExplorerGitBadge?,
        chromeTheme: DesignTokens.ChromeTheme
    ) {
        super.init(frame: .zero)
        let isDimmed = item.node.isHiddenFile || badge == .ignored

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: FileExplorerIcon.symbolName(for: item.node),
            accessibilityDescription: nil
        )
        iconView.contentTintColor = isDimmed ? chromeTheme.textMuted : chromeTheme.textSecondary
        iconView.alphaValue = isDimmed ? FileExplorerMetrics.dimmedAlphaRATIO : 1
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: FileExplorerMetrics.rowIconSizePX,
            weight: .regular
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let displayName = item.filterDisplayPath ?? item.node.name
        let nameLabel = NSTextField(labelWithString: displayName)
        nameLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT)
        nameLabel.textColor = isDimmed ? chromeTheme.textMuted : chromeTheme.textPrimary
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
        case .modified: DesignTokens.Color.warningOrange
        case .untracked: DesignTokens.Color.successGreen
        case .ignored, nil: chromeTheme.textMuted
        }
    }
}
