import AppKit

@MainActor
final class PreferencesThemePreviewView: NSView {
    var colors: TerminalColorSettings = .default {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = color(colors.background, fallback: .black)
        background.setFill()
        NSBezierPath.fill(bounds)

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let foreground = color(colors.foreground, fallback: .white)
        let lineHeight: CGFloat = 24
        let left: CGFloat = 18
        let top: CGFloat = 18

        draw("kurotty", at: NSPoint(x: left, y: top), color: ansiColor(6), font: boldFont)
        draw("  ~/dev/project", at: NSPoint(x: left + 57, y: top), color: ansiColor(4), font: font)
        draw("$ git status", at: NSPoint(x: left, y: top + lineHeight), color: foreground, font: font)
        draw("On branch develop", at: NSPoint(x: left, y: top + lineHeight * 2), color: ansiColor(2), font: font)
        draw("M  Sources/Preferences.swift", at: NSPoint(x: left, y: top + lineHeight * 3), color: ansiColor(3), font: font)
        draw("$ ", at: NSPoint(x: left, y: top + lineHeight * 4), color: foreground, font: font)

        let cursor = color(colors.cursor, fallback: .white)
        cursor.setFill()
        NSBezierPath.fill(NSRect(x: left + 18, y: top + lineHeight * 4 - 1, width: 8, height: 17))

        let swatchWidth = max(8, (bounds.width - left * 2) / 16)
        for index in 0..<min(colors.ansi.count, 16) {
            ansiColor(index).setFill()
            NSBezierPath.fill(NSRect(x: left + CGFloat(index) * swatchWidth, y: bounds.height - 17, width: swatchWidth, height: 5))
        }
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
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard value.count == 6, let raw = Int(value, radix: 16) else { return fallback }
        return NSColor(
            calibratedRed: CGFloat((raw >> 16) & 0xff) / 255,
            green: CGFloat((raw >> 8) & 0xff) / 255,
            blue: CGFloat(raw & 0xff) / 255,
            alpha: 1
        )
    }
}
