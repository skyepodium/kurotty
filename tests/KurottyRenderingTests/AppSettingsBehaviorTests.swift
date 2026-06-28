import XCTest
@testable import KurottyApp

final class AppSettingsBehaviorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    @MainActor
    func testSaveLoadMigratesMissingShellSettingsToHomeDirectory() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        try store.save(rawJSON: legacySettingsJSON(shell: nil))
        let settings = try store.load()

        XCTAssertEqual(settings.schemaVersion, AppSettings.default.schemaVersion)
        XCTAssertEqual(settings.shell.workingDirectory, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func testShellWorkingDirectoryNormalizationExpandsTildeAndRejectsInvalidPaths() throws {
        XCTAssertEqual(
            ShellSettings.normalizedWorkingDirectory("~"),
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertEqual(
            ShellSettings.normalizedWorkingDirectory(""),
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertEqual(
            ShellSettings.normalizedWorkingDirectory(settingsURL().path),
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertEqual(
            ShellSettings.normalizedWorkingDirectory(temporaryDirectory.path),
            temporaryDirectory.path
        )
    }

    @MainActor
    func testSaveLoadPersistsValidShellWorkingDirectory() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        try store.save(rawJSON: legacySettingsJSON(shell: #","shell":{"workingDirectory":"\#(temporaryDirectory.path)"}"#))
        let settings = try store.load()

        XCTAssertEqual(settings.shell.workingDirectory, temporaryDirectory.path)
    }

    @MainActor
    func testSaveLoadPreservesInvalidShellWorkingDirectoryForLaunchTimeValidation() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())
        let invalidPath = temporaryDirectory.appendingPathComponent("missing").path

        try store.save(rawJSON: legacySettingsJSON(shell: #","shell":{"workingDirectory":"\#(invalidPath)"}"#))
        let settings = try store.load()

        XCTAssertEqual(settings.shell.workingDirectory, invalidPath)
        XCTAssertEqual(
            ShellSettings.normalizedWorkingDirectory(settings.shell.workingDirectory),
            FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    private func settingsURL() -> URL {
        temporaryDirectory.appendingPathComponent("settings.json")
    }

    private func legacySettingsJSON(shell: String?) -> String {
        """
        {
          "schemaVersion": 4,
          "terminal": {
            "theme": "kuro-dark",
            "fontName": "Menlo",
            "fontSize": 15,
            "scrollbackLines": 1000,
            "colors": {
              "foreground": "#E6EDF3",
              "background": "#0B1020",
              "cursor": "#7DD3FC",
              "ansi": [
                "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
                "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
                "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"
              ]
            }
          },
          "window": {
            "width": 1100,
            "height": 720
          }\(shell ?? "")
        }
        """
    }
}
