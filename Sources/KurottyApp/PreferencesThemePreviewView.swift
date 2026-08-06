import AppKit
import KurottyCore

/// Resolves the font the theme preview draws its sample in.
///
/// Pure and separate from the view because it is the whole point of the
/// preview: the sample has to render in the family and size the terminal is
/// actually configured with, otherwise changing the font previews as nothing
/// and the user only finds out after closing settings.
enum PreferencesThemePreviewFont {
    /// The configured family at the configured size, falling back to the
    /// monospaced system font when the family is not installed — the same
    /// fallback the terminal takes, so the preview never claims a font the
    /// terminal cannot use.
    static func font(named name: String, sizePT: CGFloat, weight: NSFont.Weight) -> NSFont {
        guard let named = NSFont(name: name, size: sizePT) else {
            return NSFont.monospacedSystemFont(ofSize: sizePT, weight: weight)
        }
        guard weight != .regular else {
            return named
        }
        // A concrete family has no weight axis to ask for, so emphasis goes
        // through the font manager's trait conversion; it hands the family back
        // unchanged when there is no bold face to convert to.
        return NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
    }

    /// Row pitch for `font`. Derived from the point size rather than fixed, so
    /// a 20pt terminal font does not draw its sample lines on top of each
    /// other.
    static func lineHeightPX(for font: NSFont) -> CGFloat {
        font.pointSize * DesignTokens.Component.preferencesThemePreviewLineHeightRATIO
    }
}

@MainActor
final class PreferencesThemePreviewView: NSView {
    var colors: TerminalColorSettings = .default {
        didSet { needsDisplay = true }
    }

    /// Terminal font family and size, mirrored from the settings being edited.
    /// Held as the raw settings pair rather than a resolved `NSFont` so the
    /// preview re-resolves after every keystroke in the font-size field.
    var fontName: String = SettingsDefaults.terminalFontName {
        didSet { needsDisplay = true }
    }

    var fontSizePT: CGFloat = DesignTokens.Typography.terminalFontSizePT {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Component.preferencesThemePreviewCornerRadiusPX
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color(colors.background, fallback: .black).setFill()
        NSBezierPath.fill(bounds)

        let font = bodyFont
        let boldFont = PreferencesThemePreviewFont.font(
            named: fontName,
            sizePT: fontSizePT,
            weight: .semibold
        )
        let foreground = color(colors.foreground, fallback: .white)
        let lineHeight = PreferencesThemePreviewFont.lineHeightPX(for: font)
        let inset = DesignTokens.Component.preferencesThemePreviewInsetPX
        let advance = advanceWidth(in: font)

        let sessionLabel = "kurotty"
        draw(sessionLabel, at: NSPoint(x: inset, y: inset), color: ansiColor(6), font: boldFont)
        // Measured rather than offset by a constant: the gap after the session
        // name has to hold for whatever family and size the terminal runs.
        let pathX = inset
            + width(of: sessionLabel, font: boldFont)
            + advance * DesignTokens.Component.preferencesThemePreviewPromptGapCELLS
        draw("~/dev/project", at: NSPoint(x: pathX, y: inset), color: ansiColor(4), font: font)
        draw("$ git status", at: NSPoint(x: inset, y: inset + lineHeight), color: foreground, font: font)
        draw("On branch develop", at: NSPoint(x: inset, y: inset + lineHeight * 2), color: ansiColor(2), font: font)
        draw("M  Sources/Preferences.swift", at: NSPoint(x: inset, y: inset + lineHeight * 3), color: ansiColor(3), font: font)
        let promptY = inset + lineHeight * 4
        draw("$ ", at: NSPoint(x: inset, y: promptY), color: foreground, font: font)

        color(colors.cursor, fallback: .white).setFill()
        NSBezierPath.fill(NSRect(
            x: inset + advance * 2,
            y: promptY,
            width: advance,
            height: font.pointSize
        ))

        drawAnsiSwatchStrip(inset: inset)
    }

    /// The palette strip along the bottom edge: sixteen equal swatches, so a
    /// theme's whole ANSI range is visible without reading the grid of wells.
    private func drawAnsiSwatchStrip(inset: CGFloat) {
        let swatchCount = min(colors.ansi.count, TerminalColorSettings.requiredAnsiColorCount)
        guard swatchCount > 0 else { return }
        let swatchWidth = max(
            DesignTokens.Component.preferencesThemePreviewSwatchMinWidthPX,
            (bounds.width - inset * 2) / CGFloat(TerminalColorSettings.requiredAnsiColorCount)
        )
        let height = DesignTokens.Component.preferencesThemePreviewSwatchHeightPX
        let y = bounds.height
            - DesignTokens.Component.preferencesThemePreviewSwatchBottomInsetPX
            - height
        for index in 0..<swatchCount {
            ansiColor(index).setFill()
            NSBezierPath.fill(NSRect(
                x: inset + CGFloat(index) * swatchWidth,
                y: y,
                width: swatchWidth,
                height: height
            ))
        }
    }

    private var bodyFont: NSFont {
        PreferencesThemePreviewFont.font(named: fontName, sizePT: fontSizePT, weight: .regular)
    }

    /// One cell of the preview grid. Monospaced by contract, so any glyph's
    /// advance is the cell width.
    private func advanceWidth(in font: NSFont) -> CGFloat {
        width(of: "M", font: font)
    }

    private func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func draw(_ text: String, at point: NSPoint, color: NSColor, font: NSFont) {
        text.draw(at: point, withAttributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    private func ansiColor(_ index: Int) -> NSColor {
        guard colors.ansi.indices.contains(index) else { return .gray }
        return color(colors.ansi[index], fallback: .gray)
    }

    private func color(_ hex: String, fallback: NSColor) -> NSColor {
        NSColor.terminalPaletteSRGB(hex) ?? fallback
    }

    // MARK: Test hooks

    var bodyFontForTesting: NSFont { bodyFont }

    func colorForTesting(_ hex: String, fallback: NSColor = .gray) -> NSColor {
        color(hex, fallback: fallback)
    }
}
