import AppKit

/// Single factory for SF Symbol chrome icons.
///
/// Before this existed, every chrome surface built its own
/// `NSImage.SymbolConfiguration` inline, so point sizes and weights drifted
/// between the sidebar, the status bar, the file explorer, and the tab bar.
/// `Icon.SizeClass` pins the four sizes chrome is allowed to use; anything that
/// needs a size outside that ramp must ask for it explicitly through
/// `symbol(_:pointSizePT:weight:tint:)` and say why.
enum Icon {
    /// The chrome icon ramp. Sizes are paired with the weight that keeps the
    /// stroke optically even at that size: small glyphs need more weight to
    /// survive, large glyphs need less so they do not read as bold.
    enum SizeClass {
        /// 9pt / semibold. Inline separators and other sub-caption marks.
        case micro
        /// 11pt / medium. Row accessories, badges, search-pill glyphs.
        case small
        /// 14pt / regular. Toolbar and chrome buttons.
        case regular
        /// 20pt / regular. Empty-state art.
        case large

        /// The spec sizes, before the user's UI text scale.
        var basePointSizePT: CGFloat {
            switch self {
            case .micro: return 9
            case .small: return 11
            case .regular: return 14
            case .large: return 20
            }
        }

        /// A chrome glyph sits beside chrome type, so it follows the same
        /// scale: an 11pt magnifier next to a 19pt query field reads as a
        /// rendering bug, not as a smaller icon.
        var pointSizePT: CGFloat {
            DesignTokens.UIScale.scaledPointSize(basePointSizePT)
        }

        var weight: NSFont.Weight {
            switch self {
            case .micro: return .semibold
            case .small: return .medium
            case .regular, .large: return .regular
            }
        }
    }

    /// Builds a tinted symbol at one of the four chrome sizes.
    static func symbol(
        _ name: String,
        _ size: SizeClass,
        tint: NSColor,
        accessibilityDescription: String? = nil
    ) -> NSImage? {
        symbol(
            name,
            pointSizePT: size.pointSizePT,
            weight: size.weight,
            tint: tint,
            accessibilityDescription: accessibilityDescription
        )
    }

    /// Escape hatch for a symbol whose size is dictated by surrounding type
    /// rather than by the chrome ramp, such as the 8pt breadcrumb chevron that
    /// has to sit inside an 11pt path bar without outgrowing it.
    static func symbol(
        _ name: String,
        pointSizePT: CGFloat,
        weight: NSFont.Weight,
        tint: NSColor,
        accessibilityDescription: String? = nil
    ) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSizePT, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        return image.withSymbolConfiguration(configuration)
    }
}

/// SF Symbol names used by the surfaces in this design pass. Keeping the raw
/// strings here stops `"xmark"` and `"plus"` from being retyped per call site.
enum IconSymbol {
    static let add = "plus"
    static let close = "xmark"
    static let breadcrumbSeparator = "chevron.right"
    static let previousMatch = "chevron.up"
    static let nextMatch = "chevron.down"
    static let matchCase = "textformat"
    static let regularExpression = "curlybraces"
    static let disclosureCollapsed = "chevron.right"
    static let disclosureExpanded = "chevron.down"
    static let sidebarLeading = "sidebar.leading"
    static let sidebarTrailing = "sidebar.trailing"
    /// Split glyphs read as "where the new pane lands": 2x1 puts it to the
    /// right, 1x2 puts it below. Matching what cmux uses, since a user coming
    /// from either app should not have to relearn the pair.
    static let splitRight = "square.split.2x1"
    static let splitDown = "square.split.1x2"
    static let refresh = "arrow.clockwise"
    static let search = "magnifyingglass"
    static let clearSearch = "xmark.circle.fill"
    /// Outline. The quiet folder, for chrome that only *refers* to a directory:
    /// the explorer's toggle button and the working-directory group headers in
    /// the history and agent-session lists, which are all `textTertiary` marks
    /// standing behind their labels.
    static let folder = "folder"
    /// Filled. The mark for a row that *is* a directory, which is only the file
    /// explorer's tree (`FileExplorerIcon.folderSymbolName`).
    ///
    /// The explorer used the outline one for a release, on the theory that a
    /// solid mark competes with the disclosure chevron beside it. It does not:
    /// the chevron is a small tertiary hairline in its own column and the
    /// folder is a tinted 13pt glyph in another, so the two were never in the
    /// same contest. What the outline actually cost was *kind* — at 13pt an
    /// outline `folder` and an outline `doc` are the same rounded rectangle
    /// with a nick in one edge, so the leading column stopped saying whether a
    /// row was a directory and the tree read as one undifferentiated list.
    /// Filled against outline is a silhouette difference, which survives being
    /// glanced at, being small, and being greyscale.
    static let folderFilled = "folder.fill"
    static let remove = "minus"

    /// The command-history mark: used by the panel's toggle and by its own
    /// empty state, so the button that opens the panel and the art inside it
    /// are the same glyph.
    static let history = "clock.arrow.circlepath"

    // MARK: Empty states
    static let commandHistoryEmptyState = history
    static let agentSessionEmptyState = "bubble.left.and.text.bubble.right"

    // MARK: Getting Started
    /// The three checklist states. Filled marks, because the glyph *is* the
    /// state here — there is no coloured pill behind it to carry the meaning,
    /// and a hollow ring at 13pt reads as an unrendered icon.
    static let setupReady = "checkmark.circle.fill"
    static let setupAction = "circle.dashed"
    static let setupUnavailable = "minus.circle.fill"

    // MARK: Status bar
    static let memory = "memorychip"
    static let cpu = "cpu"
    static let agent = "sparkles"
    static let worktree = "arrow.triangle.branch"
}
