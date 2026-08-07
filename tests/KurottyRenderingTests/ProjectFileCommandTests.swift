import XCTest
@testable import KurottyApp

/// The two commands added for the project file palette and the Getting Started
/// tab: how they are reached, and that reaching them does not cost an existing
/// chord.
final class ProjectFileCommandTests: XCTestCase {
    private var windowCommands: [TerminalCommand] {
        TerminalCommandRegistry.default.windowCommands
    }

    private func command(_ id: TerminalWindowCommandID) throws -> TerminalCommand {
        try XCTUnwrap(windowCommands.first { $0.id == id })
    }

    func testOpenProjectFileIsBoundToCommandP() throws {
        // Command-P. Kurotty has no Print command to contest it, and it is the
        // chord every editor already trained people on.
        let command = try command(.openProjectFile)
        XCTAssertEqual(command.shortcut?.keyEquivalent, "p")
        XCTAssertEqual(command.shortcut?.modifiers, [.command])
        XCTAssertEqual(command.action, .openProjectFile)
    }

    func testTheNewShortcutCollidesWithNothingAlreadyBound() {
        // A chord taken twice is a chord that silently stops working for one of
        // the two commands.
        let bindings = windowCommands.compactMap { command -> String? in
            guard let shortcut = command.shortcut, let keyEquivalent = shortcut.keyEquivalent else {
                return nil
            }
            return "\(shortcut.modifiers.rawValue):\(keyEquivalent)"
        }
        XCTAssertEqual(Set(bindings).count, bindings.count)
    }

    func testGettingStartedIsReachableByNameWithNoShortcutOfItsOwn() {
        // It is read once and then reached from the palette; a chord spent on
        // it would be a chord taken from something used daily.
        let command = windowCommands.first { $0.id == .openGettingStarted }
        XCTAssertNotNil(command)
        XCTAssertNil(command?.shortcut)
    }

    func testBothCommandsAreFindableInThePaletteByTheWordsPeopleUse() {
        let palette = TerminalCommandPalette()
        for (query, expected) in [
            ("go to file", TerminalWindowCommandID.openProjectFile),
            ("quick open", .openProjectFile),
            ("fuzzy file search", .openProjectFile),
            ("onboarding", .openGettingStarted),
            ("first run", .openGettingStarted),
            ("setup", .openGettingStarted),
        ] {
            XCTAssertTrue(
                palette.results(for: query).contains { $0.command.id == expected },
                "\(query) did not find \(expected.rawValue)"
            )
        }
    }

    func testEveryWindowCommandIDStaysUniqueAfterTheAdditions() {
        let ids = windowCommands.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - Login shell resolution

    func testTheLoginShellComesFromTheEnvironmentWhenItNamesOne() {
        XCTAssertEqual(
            TerminalShellIntegrationBootstrap.loginShellPath(environment: ["SHELL": "/opt/homebrew/bin/fish"]),
            "/opt/homebrew/bin/fish"
        )
    }

    func testAnAbsentOrEmptyShellVariableFallsBackToTheSystemDefault() {
        // macOS has shipped zsh as the login shell since Catalina, so the
        // fallback is the one that is almost certainly right.
        XCTAssertEqual(
            TerminalShellIntegrationBootstrap.loginShellPath(environment: [:]),
            AppConstants.Shell.defaultPath
        )
        XCTAssertEqual(
            TerminalShellIntegrationBootstrap.loginShellPath(environment: ["SHELL": ""]),
            AppConstants.Shell.defaultPath
        )
    }
}
