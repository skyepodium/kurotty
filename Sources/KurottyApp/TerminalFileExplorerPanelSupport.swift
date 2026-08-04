import AppKit

/// Support pieces for `TerminalFileExplorerPanelView`: file icons and the row
/// cell. Localized copy lives in `AppLocalization` (fileExplorer* keys).

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

@MainActor
final class TerminalFileExplorerSidebarRowView: NSTableRowView {
    var hoverBackgroundColor: NSColor = .clear
    var selectionBackgroundColor: NSColor = .clear
    private var isMouseInside = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
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
        guard isMouseInside, !isSelected else { return }
        fillHighlight(with: hoverBackgroundColor)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        fillHighlight(with: selectionBackgroundColor)
    }

    private func fillHighlight(with color: NSColor) {
        let rect = bounds.insetBy(
            dx: DesignTokens.Component.fileExplorerRowHighlightInsetXPX,
            dy: DesignTokens.Component.fileExplorerRowHighlightInsetYPX
        )
        color.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: DesignTokens.Component.fileExplorerRowCornerRadiusPX,
            yRadius: DesignTokens.Component.fileExplorerRowCornerRadiusPX
        ).fill()
    }
}

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
