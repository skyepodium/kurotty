import XCTest
import KurottyCore

/// Runs `SettingsSchemaLinter` — first against the tree as it stands, then
/// against copies of it damaged in the specific ways a settings merge damages
/// it — and asserts on what the linter reports.
///
/// These assertions are about the linter's findings, never about the contents of
/// a source file: nothing here says "AppSettings.swift contains this string" as
/// a claim about the product. The fixtures do quote source, because a fixture
/// for a merge conflict has to be a merge conflict, and each one is built
/// through a helper that fails loudly when its anchor stops matching, so a
/// reworded comment turns the test red rather than turning it into a no-op that
/// passes forever.
final class SettingsSchemaLinterTests: XCTestCase {

    // MARK: - The Tree As It Stands

    func testCurrentSourceSatisfiesEveryStructuralInvariant() throws {
        let findings = try SettingsSchemaLinter.lintRepository(at: repositoryRoot())

        XCTAssertEqual(
            findings.map(\.description),
            [],
            "the settings schema violates an invariant; run ./scripts/check-settings-schema.sh"
        )
    }

    // MARK: - The Merge That Has Now Happened Three Times

    func testKeepingBothSidesOfAMigrationConflictIsCaught() throws {
        // The literal artifact: the conflict region held the two `if` headers but
        // not the closing brace below them, so keeping both sides nests the
        // second guard inside the first and leaves the file one brace short.
        var sources = try liveSources()
        sources.appSettings = nestingCloseConfirmationInsideStatusBar(sources.appSettings)

        let findings = SettingsSchemaLinter.lint(sources)

        assert(findings, contains: .braceBalance, mentioning: "unclosed")
    }

    func testNestedMigrationBlockIsCaughtWhenTheBracesStillBalance() throws {
        // The same nesting with the missing brace put back. This compiles, ships,
        // and silently stops every migration below the nesting point from running
        // for files that already passed the outer version, so brace counting is
        // not enough on its own.
        var sources = try liveSources()
        sources.appSettings = balancingBraces(
            after: nestingCloseConfirmationInsideStatusBar(sources.appSettings)
        )

        let findings = SettingsSchemaLinter.lint(sources)

        XCTAssertFalse(findings.contains { $0.rule == .braceBalance })
        assert(findings, contains: .migrationBlockNesting, mentioning: "closeConfirmationSchemaVersion")
    }

    // MARK: - Half-Finished Settings Changes

    func testMigrationConstantWithNoMigrationBlockIsCaught() throws {
        var sources = try liveSources()
        sources.appSettings = duplicatingMigrationConstant(
            named: "menuBarExtraSchemaVersion",
            as: "orphanSchemaVersion",
            in: sources.appSettings
        )

        let findings = SettingsSchemaLinter.lint(sources)

        assert(findings, contains: .migrationConstantUnused, mentioning: "orphanSchemaVersion")
    }

    func testDeclaredKeyWithNoMigrationBlockIsCaught() throws {
        // A settings change that added the key, the coding key, the default and
        // the initializer parameter, and then forgot the migration.
        var sources = try liveSources()
        sources.appSettings = removingMigrationBlock(
            named: "menuBarExtraSchemaVersion",
            from: sources.appSettings
        )
        sources.appSettings = removingMigrationConstant(
            named: "menuBarExtraSchemaVersion",
            from: sources.appSettings
        )

        let findings = SettingsSchemaLinter.lint(sources)

        assert(findings, contains: .migrationMissingForKey, mentioning: "terminal.menuBarExtraEnabled")
        XCTAssertFalse(
            findings.contains { $0.rule == .migrationConstantUnused },
            "the constant went with the block; only the uncovered key should be reported"
        )
    }

    func testPropertyMissingFromCodingKeysIsCaught() throws {
        var sources = try liveSources()
        sources.appSettings = removingLine("        case menuBarExtraEnabled", from: sources.appSettings)

        let findings = SettingsSchemaLinter.lint(sources)

        assert(findings, contains: .codingKey, mentioning: "menuBarExtraEnabled")
    }

    // MARK: - The Merge That Resolves Cleanly

    func testTwoMigrationsAtTheCurrentSchemaVersionAreReportedUntilAcknowledged() throws {
        // Two branches that both bumped the schema to the same number merge
        // without a conflict, and the result is usually right — both keys really
        // did arrive in that version. Usually is not a guarantee, so it has to be
        // said out loud rather than left to luck.
        var sources = try liveSources()
        // Everything declared between the two colliding constants and the
        // current version moves with them. Constants are declared in version
        // order, so leaving them behind would make the fixture fail on the
        // ordering rule instead of on the collision it is about.
        for constant in [
            "commandProgressIndicatorSchemaVersion",
            "menuBarExtraSchemaVersion",
            "promptNavigatorRailSchemaVersion",
            "gettingStartedSchemaVersion",
            "agentWaitingNotificationSchemaVersion",
        ] {
            sources.appSettings = settingMigrationVersion(
                of: constant,
                to: SettingsDefaults.schemaVersion,
                in: sources.appSettings
            )
        }

        let findings = SettingsSchemaLinter.lint(sources)
        assert(findings, contains: .migrationVersionShared, mentioning: "menuBarExtraSchemaVersion")

        // The moved constants that do not already carry the directive, plus
        // every constant that genuinely sits at the current version and was
        // alone there until this fixture crowded it.
        for constant in [
            "commandProgressIndicatorSchemaVersion",
            "menuBarExtraSchemaVersion",
            "agentWaitingNotificationSchemaVersion",
            "titleReportsSchemaVersion",
        ] {
            sources.appSettings = acknowledgingSharedVersion(of: constant, in: sources.appSettings)
        }

        XCTAssertEqual(
            SettingsSchemaLinter.lint(sources).map(\.description),
            [],
            "an acknowledged shared version should clear every finding"
        )
    }

    // MARK: - Fixtures

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func liveSources() throws -> SettingsSchemaLinter.Sources {
        try SettingsSchemaLinter.sources(at: repositoryRoot())
    }

    private func assert(
        _ findings: [SettingsSchemaLinter.Finding],
        contains rule: SettingsSchemaLinter.Rule,
        mentioning needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matched = findings.contains { $0.rule == rule && $0.message.contains(needle) }
        XCTAssertTrue(
            matched,
            "expected a \(rule.rawValue) finding mentioning \(needle), got: "
                + findings.map(\.description).joined(separator: " | "),
            file: file,
            line: line
        )
    }

    /// Reproduces the conflict resolution itself: the `}` that closed the status
    /// bar migration is dropped and the close-confirmation guard takes its place.
    private func nestingCloseConfirmationInsideStatusBar(
        _ source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        replacing(
            """
                        next.terminal.statusBarEnabled = SettingsDefaults.statusBarEnabled
                    }
                    if sourceSchemaVersion < Migration.closeConfirmationSchemaVersion {
            """,
            with: """
                        next.terminal.statusBarEnabled = SettingsDefaults.statusBarEnabled
                        if sourceSchemaVersion < Migration.closeConfirmationSchemaVersion {
            """,
            in: source,
            file: file,
            line: line
        )
    }

    /// Puts the missing brace back without undoing the nesting, which is the
    /// version of the mistake a build cannot see.
    private func balancingBraces(
        after source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        replacing(
            """
                        next.terminal.confirmCloseRunningProcess = SettingsDefaults.confirmCloseRunningProcess
                    }
            """,
            with: """
                            next.terminal.confirmCloseRunningProcess = SettingsDefaults.confirmCloseRunningProcess
                        }
                    }
            """,
            in: source,
            file: file,
            line: line
        )
    }

    private func replacing(
        _ old: String,
        with new: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let occurrences = source.components(separatedBy: old).count - 1
        XCTAssertEqual(
            occurrences,
            1,
            "fixture anchor no longer appears exactly once in AppSettings.swift",
            file: file,
            line: line
        )
        return source.replacingOccurrences(of: old, with: new)
    }

    /// Locates blocks and constants by their structure rather than by quoting
    /// the comments inside them, so rewording a comment cannot silently empty a
    /// fixture out.
    private func removingMigrationBlock(
        named name: String,
        from source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "        if sourceSchemaVersion < Migration.\(name) {"),
              let end = lines[start...].firstIndex(of: "        }")
        else {
            XCTFail("no migration block guarded by Migration.\(name)", file: file, line: line)
            return source
        }
        lines.removeSubrange(start...end)
        return lines.joined(separator: "\n")
    }

    private func removingMigrationConstant(
        named name: String,
        from source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        guard let declaration = migrationConstantIndex(named: name, in: lines) else {
            XCTFail("no Migration constant named \(name)", file: file, line: line)
            return source
        }
        var start = declaration
        while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
            start -= 1
        }
        lines.removeSubrange(start...declaration)
        return lines.joined(separator: "\n")
    }

    private func duplicatingMigrationConstant(
        named source: String,
        as name: String,
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let index = migrationConstantIndex(named: source, in: lines),
              let version = migrationVersion(in: lines[index])
        else {
            XCTFail("no Migration constant named \(source)", file: file, line: line)
            return text
        }
        lines.insert(
            contentsOf: [
                "        /// Schema version that introduced nothing at all.",
                "        static let \(name) = \(version)",
            ],
            at: index + 1
        )
        return lines.joined(separator: "\n")
    }

    private func settingMigrationVersion(
        of name: String,
        to version: Int,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        guard let index = migrationConstantIndex(named: name, in: lines) else {
            XCTFail("no Migration constant named \(name)", file: file, line: line)
            return source
        }
        lines[index] = "        static let \(name) = \(version)"
        return lines.joined(separator: "\n")
    }

    private func acknowledgingSharedVersion(
        of name: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        guard let index = migrationConstantIndex(named: name, in: lines) else {
            XCTFail("no Migration constant named \(name)", file: file, line: line)
            return source
        }
        lines.insert("        /// \(SettingsSchemaLinter.sharedVersionDirective)", at: index)
        return lines.joined(separator: "\n")
    }

    private func removingLine(
        _ text: String,
        from source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: text) else {
            XCTFail("no line `\(text)`", file: file, line: line)
            return source
        }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    private func migrationConstantIndex(named name: String, in lines: [String]) -> Int? {
        lines.firstIndex { $0.hasPrefix("        static let \(name) = ") }
    }

    private func migrationVersion(in declaration: String) -> Int? {
        declaration.split(separator: "=").last.flatMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
    }
}
