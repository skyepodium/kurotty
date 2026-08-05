import Foundation

/// Why a theme file import can fail. The cases stay UI-free so the parser can
/// be exercised without AppKit; Preferences maps them to localized copy.
enum TerminalThemeImportError: Error, Equatable {
    /// The data is neither an iTerm2 property list nor a Ghostty-style
    /// `key = value` document with any recognized color key.
    case unrecognizedFormat
    /// The document was recognized but does not carry the full color contract:
    /// all 16 ANSI palette slots plus foreground and background.
    case incompletePalette
}

/// Imports terminal color schemes from the two dominant theme ecosystems:
///
/// * iTerm2 `.itermcolors` — an XML or binary property list whose keys are
///   `Ansi 0 Color` … `Ansi 15 Color`, `Foreground Color`, `Background Color`,
///   and `Cursor Color`, each a dictionary of 0–1 float components.
/// * Ghostty themes — plain-text `key = value` lines with repeated
///   `palette = N=#RRGGBB` entries plus `background`, `foreground`, and
///   `cursor-color`. This is the format of every file under Ghostty's bundled
///   `themes/` directory, so those hundreds of themes import directly.
///
/// The importer returns plain `TerminalColorSettings`; callers decide how the
/// result lands (Preferences stores it as the `custom` theme). A missing cursor
/// color falls back to the imported foreground rather than failing the import,
/// matching how both ecosystems treat the cursor as optional.
enum TerminalThemeImporter {
    /// The palette contract shared with `TerminalColorSettings`: ANSI slots
    /// 0–15. Ghostty themes also carry the extended 256-color cube; those
    /// entries are valid input and deliberately ignored.
    private static let requiredAnsiColorCount = TerminalColorSettings.requiredAnsiColorCount

    private enum ITermKey {
        static let ansiPrefix = "Ansi "
        static let ansiSuffix = " Color"
        static let foreground = "Foreground Color"
        static let background = "Background Color"
        static let cursor = "Cursor Color"
        static let redComponent = "Red Component"
        static let greenComponent = "Green Component"
        static let blueComponent = "Blue Component"
    }

    private enum GhosttyKey {
        static let palette = "palette"
        static let foreground = "foreground"
        static let background = "background"
        static let cursor = "cursor-color"
    }

    static func importTheme(from data: Data) throws -> TerminalColorSettings {
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = plist as? [String: Any] {
            return try theme(fromITermColors: dictionary)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TerminalThemeImportError.unrecognizedFormat
        }
        return try theme(fromGhosttyTheme: text)
    }

    // MARK: - iTerm2 .itermcolors

    static func theme(fromITermColors dictionary: [String: Any]) throws -> TerminalColorSettings {
        var ansi = [Int: String]()
        for (key, value) in dictionary {
            guard key.hasPrefix(ITermKey.ansiPrefix), key.hasSuffix(ITermKey.ansiSuffix) else { continue }
            let indexText = key.dropFirst(ITermKey.ansiPrefix.count).dropLast(ITermKey.ansiSuffix.count)
            guard let index = Int(indexText), (0..<requiredAnsiColorCount).contains(index),
                  let hex = hexColor(fromITermComponents: value)
            else { continue }
            ansi[index] = hex
        }

        let foreground = hexColor(fromITermComponents: dictionary[ITermKey.foreground])
        let background = hexColor(fromITermComponents: dictionary[ITermKey.background])
        let cursor = hexColor(fromITermComponents: dictionary[ITermKey.cursor])
        let recognizedAnyColor = !ansi.isEmpty || foreground != nil || background != nil
        guard recognizedAnyColor else {
            throw TerminalThemeImportError.unrecognizedFormat
        }
        return try theme(ansi: ansi, foreground: foreground, background: background, cursor: cursor)
    }

    private static func hexColor(fromITermComponents value: Any?) -> String? {
        guard let components = value as? [String: Any],
              let red = floatComponent(components[ITermKey.redComponent]),
              let green = floatComponent(components[ITermKey.greenComponent]),
              let blue = floatComponent(components[ITermKey.blueComponent])
        else {
            return nil
        }
        return hexString(red: red, green: green, blue: blue)
    }

    private static func floatComponent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let component = number.doubleValue
        guard component.isFinite else { return nil }
        return min(1, max(0, component))
    }

    private static func hexString(red: Double, green: Double, blue: Double) -> String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    // MARK: - Ghostty theme

    static func theme(fromGhosttyTheme text: String) throws -> TerminalColorSettings {
        var ansi = [Int: String]()
        var foreground: String?
        var background: String?
        var cursor: String?

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case GhosttyKey.palette:
                guard let entry = paletteEntry(fromGhosttyValue: value),
                      (0..<requiredAnsiColorCount).contains(entry.index)
                else { continue }
                ansi[entry.index] = entry.hex
            case GhosttyKey.foreground:
                foreground = normalizedHex(value) ?? foreground
            case GhosttyKey.background:
                background = normalizedHex(value) ?? background
            case GhosttyKey.cursor:
                cursor = normalizedHex(value) ?? cursor
            default:
                continue
            }
        }

        let recognizedAnyColor = !ansi.isEmpty || foreground != nil || background != nil || cursor != nil
        guard recognizedAnyColor else {
            throw TerminalThemeImportError.unrecognizedFormat
        }
        return try theme(ansi: ansi, foreground: foreground, background: background, cursor: cursor)
    }

    private static func paletteEntry(fromGhosttyValue value: String) -> (index: Int, hex: String)? {
        guard let separator = value.firstIndex(of: "=") else { return nil }
        let indexText = value[..<separator].trimmingCharacters(in: .whitespaces)
        let colorText = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard let index = Int(indexText), let hex = normalizedHex(colorText) else { return nil }
        return (index, hex)
    }

    /// Accepts `#RRGGBB` or bare `RRGGBB` and returns canonical uppercase
    /// `#RRGGBB`, the shape `ColorHexParser` and the settings JSON use.
    private static func normalizedHex(_ value: String) -> String? {
        let stripped = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard stripped.count == 6, Int(stripped, radix: 16) != nil else { return nil }
        return "#" + stripped.uppercased()
    }

    // MARK: - Shared assembly

    private static func theme(
        ansi: [Int: String],
        foreground: String?,
        background: String?,
        cursor: String?
    ) throws -> TerminalColorSettings {
        guard ansi.count == requiredAnsiColorCount,
              let foreground,
              let background
        else {
            throw TerminalThemeImportError.incompletePalette
        }
        let orderedAnsi = (0..<requiredAnsiColorCount).compactMap { ansi[$0] }
        return TerminalColorSettings(
            foreground: foreground,
            background: background,
            // Neither ecosystem requires a cursor color; the foreground is the
            // closest faithful stand-in and keeps the import from failing over
            // an optional field.
            cursor: cursor ?? foreground,
            ansi: orderedAnsi
        )
    }
}
