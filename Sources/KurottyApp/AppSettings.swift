import Foundation
import simd

struct AppSettings: Codable, Equatable {
    var schemaVersion: Int?
    var terminal: TerminalSettings
    var window: WindowSettings

    static let `default` = AppSettings(
        schemaVersion: Defaults.schemaVersion,
        terminal: TerminalSettings(
            fontName: Defaults.fontName,
            fontSize: Defaults.fontSize,
            scrollbackLines: Defaults.scrollbackLines,
            colors: TerminalColorSettings.default
        ),
        window: WindowSettings(
            width: Defaults.windowWidth,
            height: Defaults.windowHeight
        )
    )

    private enum Defaults {
        static let schemaVersion = 3
        static let fontName = "Menlo"
        static let fontSize = Double(DesignTokens.Typography.terminalFontSizePT)
        static let scrollbackLines = AppConstants.Terminal.maxScrollbackRows
        static let windowWidth = 1100.0
        static let windowHeight = 720.0
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case terminal
        case window
    }

    init(schemaVersion: Int?, terminal: TerminalSettings, window: WindowSettings) {
        self.schemaVersion = schemaVersion
        self.terminal = terminal
        self.window = window
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        terminal = try container.decode(TerminalSettings.self, forKey: .terminal)
        window = try container.decodeIfPresent(WindowSettings.self, forKey: .window) ?? .default
    }
}

struct TerminalSettings: Codable, Equatable {
    var fontName: String
    var fontSize: Double
    var scrollbackLines: Int
    var colors: TerminalColorSettings
}

struct WindowSettings: Codable, Equatable {
    var width: Double
    var height: Double

    static let `default` = WindowSettings(width: 1100, height: 720)
}

struct TerminalColorSettings: Codable, Equatable {
    static let requiredAnsiColorCount = 16

    var foreground: String
    var background: String
    var cursor: String
    var ansi: [String]

    static let `default` = TerminalColorSettings(
        foreground: Defaults.foreground,
        background: Defaults.background,
        cursor: Defaults.cursor,
        ansi: Defaults.ansi
    )

    private enum Defaults {
        static let foreground = "#E6EDF3"
        static let background = "#0B1020"
        static let cursor = "#7DD3FC"
        static let ansi = [
            "#3B4252",
            "#BF616A",
            "#A3BE8C",
            "#EBCB8B",
            "#81A1C1",
            "#B48EAD",
            "#88C0D0",
            "#E5E9F0",
            "#4C566A",
            "#BF616A",
            "#A3BE8C",
            "#EBCB8B",
            "#81A1C1",
            "#B48EAD",
            "#8FBCBB",
            "#ECEFF4",
        ]
    }

    var foregroundColor: SIMD4<Float> {
        ColorHexParser.parse(foreground, fallback: DesignTokens.Color.terminalForeground)
    }

    var backgroundColor: SIMD4<Float> {
        ColorHexParser.parse(background, fallback: DesignTokens.Color.terminalDefaultBackground)
    }

    var cursorColor: SIMD4<Float> {
        ColorHexParser.parse(cursor, fallback: DesignTokens.Color.terminalCursor)
    }
}

enum ColorHexParser {
    static func parse(_ value: String, fallback: SIMD4<Float>) -> SIMD4<Float> {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 6, let raw = Int(hex, radix: 16) else {
            return fallback
        }

        let red = Float((raw >> 16) & 0xff) / 255
        let green = Float((raw >> 8) & 0xff) / 255
        let blue = Float(raw & 0xff) / 255
        return SIMD4<Float>(red, green, blue, 1)
    }
}

@MainActor
final class AppSettingsStore {
    static let shared = AppSettingsStore()
    static let didChangeNotification = Notification.Name("dev.kurotty.settings.didChange")

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    let settingsURL: URL

    private enum Path {
        static let appDirectoryName = AppConstants.Settings.directoryName
        static let settingsFileName = AppConstants.Settings.fileName
        static let libraryDirectoryName = "Library"
        static let applicationSupportDirectoryName = "Application Support"
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()

        settingsURL = Self.defaultSettingsURL(fileManager: fileManager)
    }

    func loadRawJSON() throws -> String {
        let data = try encoder.encode(load())
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func load() throws -> AppSettings {
        try ensureSettingsFileExists()
        let data = try Data(contentsOf: settingsURL)
        return normalized(try decoder.decode(AppSettings.self, from: data))
    }

    func save(rawJSON: String) throws {
        let data = Data(rawJSON.utf8)
        let settings = normalized(try decoder.decode(AppSettings.self, from: data))
        let normalizedData = try encoder.encode(settings)
        try ensureSettingsDirectoryExists()
        try normalizedData.write(to: settingsURL, options: .atomic)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.notificationSettingsKey: settings]
        )
    }

    static let notificationSettingsKey = "settings"

    private func ensureSettingsFileExists() throws {
        guard !fileManager.fileExists(atPath: settingsURL.path) else {
            return
        }

        try ensureSettingsDirectoryExists()
        let data = try encoder.encode(AppSettings.default)
        try data.write(to: settingsURL, options: .atomic)
    }

    private func ensureSettingsDirectoryExists() throws {
        let directoryURL = settingsURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func normalized(_ settings: AppSettings) -> AppSettings {
        var next = settings
        let sourceSchemaVersion = next.schemaVersion ?? 0
        let currentSchemaVersion = AppSettings.default.schemaVersion ?? 1
        next.schemaVersion = currentSchemaVersion
        if sourceSchemaVersion < currentSchemaVersion {
            migrateLegacyDefaults(&next)
        }
        next.terminal.fontName = next.terminal.fontName.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.terminal.fontName.isEmpty {
            next.terminal.fontName = AppSettings.default.terminal.fontName
        }
        next.terminal.fontSize = min(48, max(8, next.terminal.fontSize))
        next.terminal.scrollbackLines = min(
            AppConstants.Terminal.maxScrollbackRows,
            max(1_000, next.terminal.scrollbackLines)
        )
        next.window.width = min(4_000, max(320, next.window.width))
        next.window.height = min(3_000, max(240, next.window.height))
        if next.terminal.colors.ansi.count < TerminalColorSettings.requiredAnsiColorCount {
            next.terminal.colors.ansi = TerminalColorSettings.default.ansi
        } else if next.terminal.colors.ansi.count > TerminalColorSettings.requiredAnsiColorCount {
            next.terminal.colors.ansi = Array(next.terminal.colors.ansi.prefix(TerminalColorSettings.requiredAnsiColorCount))
        }
        return next
    }

    private func migrateLegacyDefaults(_ settings: inout AppSettings) {
        let legacyColors = LegacyDefaults.colors
        guard settings.terminal.colors.foreground == legacyColors.foreground,
              settings.terminal.colors.background == legacyColors.background,
              settings.terminal.colors.cursor == legacyColors.cursor
        else {
            return
        }
        settings.terminal.colors.foreground = TerminalColorSettings.default.foreground
        settings.terminal.colors.background = TerminalColorSettings.default.background
        settings.terminal.colors.cursor = TerminalColorSettings.default.cursor
    }

    private enum LegacyDefaults {
        static let colors = TerminalColorSettings(
            foreground: "#EBEBEB",
            background: "#000000",
            cursor: "#D9D9D9",
            ansi: TerminalColorSettings.default.ansi
        )
    }

    private static func defaultSettingsURL(fileManager: FileManager) -> URL {
        guard let supportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(Path.libraryDirectoryName)
                .appendingPathComponent(Path.applicationSupportDirectoryName)
                .appendingPathComponent(Path.appDirectoryName)
                .appendingPathComponent(Path.settingsFileName)
        }

        return supportURL
            .appendingPathComponent(Path.appDirectoryName)
            .appendingPathComponent(Path.settingsFileName)
    }
}
