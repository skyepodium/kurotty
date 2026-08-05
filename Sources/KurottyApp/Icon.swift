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
        /// 13pt / regular. Toolbar and chrome buttons.
        case regular
        /// 20pt / regular. Empty-state art.
        case large

        var pointSizePT: CGFloat {
            switch self {
            case .micro: return 9
            case .small: return 11
            case .regular: return 13
            case .large: return 20
            }
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
    static let disclosure = "chevron.right"
}
