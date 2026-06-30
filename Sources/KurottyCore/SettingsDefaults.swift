import Foundation

public enum SettingsDefaults {
    public static let schemaVersion = 9
    public static let terminalFontName = "Menlo"
    public static let terminalFontSizePT = 15.0
    public static let maximumScrollbackRows = 1_000_000
    public static let minimumScrollbackRows = 1_000
    public static let defaultWindowWidthPX = 1100.0
    public static let defaultWindowHeightPX = 720.0
    public static let minimumWindowWidthPX = 320.0
    public static let maximumWindowWidthPX = 4_000.0
    public static let minimumWindowHeightPX = 240.0
    public static let maximumWindowHeightPX = 3_000.0
    public static let minimumTerminalFontSizePT = 8.0
    public static let maximumTerminalFontSizePT = 48.0

    public static var shellWorkingDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
}

public enum TerminalColorDefaults {
    public static let foregroundHex = "#E5E7EB"
    public static let backgroundHex = "#22252B"
    public static let cursorHex = "#D7C6F4"

    public static let foreground = SIMD4<Float>(229.0 / 255.0, 231.0 / 255.0, 235.0 / 255.0, 1)
    public static let background = SIMD4<Float>(34.0 / 255.0, 37.0 / 255.0, 43.0 / 255.0, 1)
    public static let cursor = SIMD4<Float>(215.0 / 255.0, 198.0 / 255.0, 244.0 / 255.0, 1)

    public static let ansiHex = [
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
