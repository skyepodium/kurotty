import Foundation
import simd

struct AppSettings: Codable, Equatable {
    var schemaVersion: Int?
    var terminal: TerminalSettings
    var window: WindowSettings
    var shell: ShellSettings
    var notifications: NotificationSettings

    static let `default` = AppSettings(
        schemaVersion: Defaults.schemaVersion,
        terminal: TerminalSettings(
            theme: TerminalThemePreset.kurottyName,
            fontName: Defaults.fontName,
            fontSize: Defaults.fontSize,
            scrollbackLines: Defaults.scrollbackLines,
            colors: TerminalColorSettings.default
        ),
        window: WindowSettings(
            width: Defaults.windowWidth,
            height: Defaults.windowHeight
        ),
        shell: ShellSettings(
            workingDirectory: Defaults.shellWorkingDirectory
        ),
        notifications: NotificationSettings.default
    )

    private enum Defaults {
        static let schemaVersion = 7
        static let fontName = "Menlo"
        static let fontSize = Double(DesignTokens.Typography.terminalFontSizePT)
        static let scrollbackLines = AppConstants.Terminal.maxScrollbackRows
        static let windowWidth = AppConstants.Settings.defaultWindowWidthPX
        static let windowHeight = AppConstants.Settings.defaultWindowHeightPX
        static let shellWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case terminal
        case window
        case shell
        case notifications
    }

    init(
        schemaVersion: Int?,
        terminal: TerminalSettings,
        window: WindowSettings,
        shell: ShellSettings,
        notifications: NotificationSettings
    ) {
        self.schemaVersion = schemaVersion
        self.terminal = terminal
        self.window = window
        self.shell = shell
        self.notifications = notifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        terminal = try container.decode(TerminalSettings.self, forKey: .terminal)
        window = try container.decodeIfPresent(WindowSettings.self, forKey: .window) ?? .default
        shell = try container.decodeIfPresent(ShellSettings.self, forKey: .shell) ?? .default
        notifications = try container.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? .default
    }
}

/// Live-applied to existing terminal surfaces when settings change.
struct TerminalSettings: Codable, Equatable {
    var theme: String
    var fontName: String
    var fontSize: Double
    var scrollbackLines: Int
    var colors: TerminalColorSettings

    private enum CodingKeys: String, CodingKey {
        case theme
        case fontName
        case fontSize
        case scrollbackLines
        case colors
    }

    init(theme: String, fontName: String, fontSize: Double, scrollbackLines: Int, colors: TerminalColorSettings) {
        self.theme = theme
        self.fontName = fontName
        self.fontSize = fontSize
        self.scrollbackLines = scrollbackLines
        self.colors = colors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? ""
        fontName = try container.decode(String.self, forKey: .fontName)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        scrollbackLines = try container.decode(Int.self, forKey: .scrollbackLines)
        colors = try container.decode(TerminalColorSettings.self, forKey: .colors)
    }
}

/// Launch/default-window size; existing windows may apply it when settings are reloaded.
struct WindowSettings: Codable, Equatable {
    var width: Double
    var height: Double

    static let `default` = WindowSettings(
        width: AppConstants.Settings.defaultWindowWidthPX,
        height: AppConstants.Settings.defaultWindowHeightPX
    )
}

/// Launch-only default for new shell sessions; filesystem validation happens at shell launch.
struct ShellSettings: Codable, Equatable {
    var workingDirectory: String

    static let `default` = ShellSettings(
        workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
    )

    static func normalizedWorkingDirectory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.default.workingDirectory
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return Self.default.workingDirectory
        }
        return expanded
    }
}

/// Live-applied notification privacy preferences.
struct NotificationSettings: Codable, Equatable {
    var exposeBackgroundTaskOutputSummary: Bool

    static let `default` = NotificationSettings(exposeBackgroundTaskOutputSummary: false)
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
        static let foreground = "#E5E7EB"
        static let background = "#24272E"
        static let cursor = "#D7C6F4"
        static let ansi = [
            "#2F333A",
            "#FF5F67",
            "#5FD38D",
            "#E5C07B",
            "#61AFEF",
            "#C792EA",
            "#56B6C2",
            "#D7DAE0",
            "#60646C",
            "#FF7B86",
            "#8EE8A3",
            "#F0D28A",
            "#7AB7FF",
            "#D7A8FF",
            "#7FDCE3",
            "#F5F7FA",
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

enum TerminalThemePreset {
    static let kurottyName = "kurotty"
    static let darkName = "kuro-dark"
    static let lighttyName = "lightty"
    static let customName = "custom"

    static func colors(named name: String) -> TerminalColorSettings? {
        switch canonicalName(name) {
        case kurottyName:
            return .default
        case darkName:
            return .default
        case lighttyName:
            return .lightty
        default:
            return nil
        }
    }

    static func canonicalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension TerminalColorSettings {
    static let lightty = TerminalColorSettings(
        foreground: "#202124",
        background: "#FFFFFF",
        cursor: "#111111",
        ansi: [
            "#AFA7F5",
            "#AB4634",
            "#55C236",
            "#9A4DB4",
            "#3347C3",
            "#B445B8",
            "#4FC3C7",
            "#C9C9C9",
            "#666666",
            "#D47D78",
            "#55B94A",
            "#A452BD",
            "#5B5AA2",
            "#CF75D3",
            "#35B9BD",
            "#FFFFFF",
        ]
    )
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

    init(fileManager: FileManager = .default, settingsURL: URL? = nil) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()

        self.settingsURL = settingsURL ?? Self.defaultSettingsURL(fileManager: fileManager)
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
        normalizeTheme(&next, sourceSchemaVersion: sourceSchemaVersion)
        next.terminal.fontName = next.terminal.fontName.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.terminal.fontName.isEmpty {
            next.terminal.fontName = AppSettings.default.terminal.fontName
        }
        next.terminal.fontSize = min(
            AppConstants.Settings.maximumTerminalFontSizePT,
            max(AppConstants.Settings.minimumTerminalFontSizePT, next.terminal.fontSize)
        )
        next.terminal.scrollbackLines = min(
            AppConstants.Terminal.maxScrollbackRows,
            max(AppConstants.Terminal.minimumScrollbackRows, next.terminal.scrollbackLines)
        )
        next.window.width = min(
            AppConstants.Settings.maximumWindowWidthPX,
            max(AppConstants.Settings.minimumWindowWidthPX, next.window.width)
        )
        next.window.height = min(
            AppConstants.Settings.maximumWindowHeightPX,
            max(AppConstants.Settings.minimumWindowHeightPX, next.window.height)
        )
        if next.terminal.colors.ansi.count < TerminalColorSettings.requiredAnsiColorCount {
            next.terminal.colors.ansi = TerminalColorSettings.default.ansi
        } else if next.terminal.colors.ansi.count > TerminalColorSettings.requiredAnsiColorCount {
            next.terminal.colors.ansi = Array(next.terminal.colors.ansi.prefix(TerminalColorSettings.requiredAnsiColorCount))
        }
        return next
    }

    private func normalizeTheme(_ settings: inout AppSettings, sourceSchemaVersion: Int) {
        let theme = TerminalThemePreset.canonicalName(settings.terminal.theme)
        if let presetColors = TerminalThemePreset.colors(named: theme) {
            let normalizedPresetName = theme == TerminalThemePreset.darkName
                ? TerminalThemePreset.kurottyName
                : theme
            let currentSchemaVersion = AppSettings.default.schemaVersion ?? 1
            guard sourceSchemaVersion >= currentSchemaVersion || settings.terminal.colors == presetColors else {
                settings.terminal.theme = TerminalThemePreset.customName
                return
            }
            settings.terminal.theme = normalizedPresetName
            settings.terminal.colors = presetColors
            return
        }

        if theme.isEmpty {
            settings.terminal.theme = inferredThemeName(for: settings.terminal.colors)
            if let presetColors = TerminalThemePreset.colors(named: settings.terminal.theme) {
                settings.terminal.colors = presetColors
            }
            return
        }

        settings.terminal.theme = TerminalThemePreset.customName
    }

    private func inferredThemeName(for colors: TerminalColorSettings) -> String {
        if colors == .lightty {
            return TerminalThemePreset.lighttyName
        }
        if colors == .default {
            return TerminalThemePreset.kurottyName
        }
        return TerminalThemePreset.customName
    }

    private func migrateLegacyDefaults(_ settings: inout AppSettings) {
        guard LegacyDefaults.shouldMigrate(colors: settings.terminal.colors) else {
            return
        }
        settings.terminal.theme = TerminalThemePreset.kurottyName
        settings.terminal.colors.foreground = TerminalColorSettings.default.foreground
        settings.terminal.colors.background = TerminalColorSettings.default.background
        settings.terminal.colors.cursor = TerminalColorSettings.default.cursor
        settings.terminal.colors.ansi = TerminalColorSettings.default.ansi
    }

    private enum LegacyDefaults {
        static let colors = TerminalColorSettings(
            foreground: "#EBEBEB",
            background: "#000000",
            cursor: "#D9D9D9",
            ansi: TerminalColorSettings.default.ansi
        )
        static let oldDefaultColors = TerminalColorSettings(
            foreground: "#E6EDF3",
            background: "#0B1020",
            cursor: "#7DD3FC",
            ansi: [
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
        )

        static func shouldMigrate(colors: TerminalColorSettings) -> Bool {
            colors == Self.colors || colors == Self.oldDefaultColors
        }
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
