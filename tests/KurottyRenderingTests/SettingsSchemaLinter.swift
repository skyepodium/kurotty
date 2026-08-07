import Foundation

/// Structural invariants of the portable settings schema, checked by reading
/// the source text of the three files that carry it.
///
/// WHY this parses source instead of exercising behavior: the failure it guards
/// against is a merge artifact, not a runtime bug. Two branches that each add a
/// settings key both edit `AppSettingsNormalizer.normalized(_:)` in the same
/// place, and the conflict region never contains the closing brace of a
/// migration block — that brace sits below the region and is shared by both
/// sides. The obvious "keep both sides" resolution therefore nests the second
/// `if` inside the first. When the braces happen to balance, the nested form is
/// a legal program in which every migration from the nesting point down quietly
/// stops running for files that were already past the outer version, and no
/// assertion about a normalized `AppSettings` value notices unless it happens to
/// exercise the exact source schema version the nesting hides. The shape has to
/// be checked as shape.
///
/// This is a linter, not a test that asserts a file contains a substring. It
/// blanks comments and string literals, tracks brace depth, and resolves
/// declarations to line ranges before asking anything. `SettingsSchemaLinterTests`
/// only runs it and reports what it found, and `scripts/check-settings-schema.sh`
/// runs the same code with `swiftc` so the invariants still hold on a tree that
/// does not compile — which matters, because the first time this bug shipped the
/// compiler had already caught it and the failure was lost in a pipeline whose
/// exit status came from `tail`.
enum SettingsSchemaLinter {

    // MARK: - Findings

    enum Rule: String {
        /// An anchor the linter needs is missing. Reported rather than ignored:
        /// a linter that cannot find the migration table must fail, not pass.
        case sourceStructure
        case braceBalance
        case migrationBlockNesting
        case migrationCondition
        case migrationConstantUnused
        case migrationConstantUnknown
        case migrationConstantDuplicated
        case migrationDocumentation
        case migrationAssignmentShape
        case migrationAssignmentUnknownKey
        case migrationAssignmentUndocumented
        case migrationVersionRange
        case migrationVersionOrder
        case migrationVersionShared
        case migrationMissingForKey
        case codingKey
        case initializerParameter
        case defaultSource
        case unusedDefaultAlias
        case validationKey
    }

    struct Finding: Equatable, CustomStringConvertible {
        let rule: Rule
        let file: String
        let line: Int
        let message: String

        var description: String {
            "\(file):\(line): [\(rule.rawValue)] \(message)"
        }
    }

    // MARK: - Inputs

    struct Sources {
        var appSettings: String
        var settingsDefaults: String
        var validation: String
    }

    enum RepositoryPath {
        static let appSettings = "Sources/KurottyApp/AppSettings.swift"
        static let settingsDefaults = "Sources/KurottyCore/SettingsDefaults.swift"
        static let validation = "Sources/KurottyApp/AppSettingsValidation.swift"
    }

    struct MissingSourceError: Error, CustomStringConvertible {
        let path: String
        var description: String { "settings schema source not found: \(path)" }
    }

    static func sources(at root: URL) throws -> Sources {
        func read(_ relativePath: String) throws -> String {
            let url = root.appendingPathComponent(relativePath)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw MissingSourceError(path: url.path)
            }
            return text
        }

        return Sources(
            appSettings: try read(RepositoryPath.appSettings),
            settingsDefaults: try read(RepositoryPath.settingsDefaults),
            validation: try read(RepositoryPath.validation)
        )
    }

    static func lintRepository(at root: URL) throws -> [Finding] {
        lint(try sources(at: root))
    }

    /// Keys that decode through `decodeIfPresent(...) ?? SettingsDefaults.x` and
    /// deliberately carry no migration block. Every other such key must have
    /// one, so a key added without a migration fails here instead of shipping.
    /// The entry is the record of the decision; writing one is meant to cost a
    /// moment's thought rather than to be the cheap way out.
    private static let keysExemptFromMigration: [String: String] = [
        "terminal.commandHistoryEnabled":
            "older than the first entry in the migration table (schema 11), so there is no version to reset from",
        "terminal.codeEditorFontSize":
            "arrived at schema 16 with no reset block; a hand-edited older file carrying this key keeps its value",
        "terminal.codeEditorWrapsLines":
            "arrived at schema 16 alongside codeEditorFontSize, with no reset block for the same reason",
        "terminal.agentStatusHookConsent":
            "records an answer the user gave, not a preference with a default worth re-applying",
        "terminal.agentStatusCodexHookConsent":
            "records the same answer for Codex, and is omitted from the migrations for the same reason",
    ]

    /// Written into a `Migration` constant's doc comment to say that sharing a
    /// schema version with another constant, at the version the app currently
    /// writes, is intended rather than the residue of two branches that both
    /// bumped the schema to the same number.
    static let sharedVersionDirective = "schema-lint: shared-version-ok"

    // MARK: - Entry Point

    static func lint(_ sources: Sources) -> [Finding] {
        let app = SwiftSourceScan(name: "AppSettings.swift", text: sources.appSettings)
        let defaults = SwiftSourceScan(name: "SettingsDefaults.swift", text: sources.settingsDefaults)
        let validation = SwiftSourceScan(name: "AppSettingsValidation.swift", text: sources.validation)

        // Brace balance runs first and alone. Every range resolved below comes
        // from brace depth, so an imbalance turns every later answer into noise;
        // reporting only the imbalance keeps the message the one worth reading.
        let balanceFindings = [app, defaults, validation].compactMap(braceFinding(for:))
        guard balanceFindings.isEmpty else { return sortedFindings(balanceFindings) }

        var findings: [Finding] = []
        let structs = settingsStructs(in: app, findings: &findings)
        let currentSchemaVersion = schemaVersion(in: defaults, findings: &findings)

        checkStructShape(structs, in: app, findings: &findings)
        checkDefaultAliases(in: app, findings: &findings)
        checkMigrations(
            in: app,
            structs: structs,
            currentSchemaVersion: currentSchemaVersion,
            findings: &findings
        )
        checkValidationKeys(in: validation, structs: structs, findings: &findings)

        return sortedFindings(findings)
    }

    private static func sortedFindings(_ findings: [Finding]) -> [Finding] {
        findings.sorted {
            ($0.file, $0.line, $0.rule.rawValue) < ($1.file, $1.line, $1.rule.rawValue)
        }
    }

    // MARK: - Brace Balance

    private static func braceFinding(for scan: SwiftSourceScan) -> Finding? {
        if let line = scan.firstNegativeDepthLine {
            return Finding(
                rule: .braceBalance,
                file: scan.name,
                line: line + 1,
                message: "closing brace with no matching opening brace"
            )
        }
        guard scan.finalDepth != 0 else {
            return nil
        }
        let verb = scan.finalDepth > 0 ? "unclosed" : "unopened"
        return Finding(
            rule: .braceBalance,
            file: scan.name,
            line: scan.code.count,
            message: "\(abs(scan.finalDepth)) \(verb) brace(s) at end of file; "
                + "a migration block that swallowed its neighbour looks exactly like this"
        )
    }

    // MARK: - Settings Structs

    private struct SettingsStruct {
        var name: String
        var storedProperties: [Declaration]
        var codingKeys: [Declaration]?
        var initializerParameters: [InitializerParameter]?
        var optionalDecodedDefaults: [DecodedDefault]

        func property(named name: String) -> Declaration? {
            storedProperties.first { $0.name == name }
        }
    }

    private struct Declaration {
        var name: String
        var line: Int
    }

    private struct InitializerParameter {
        var name: String
        var defaultExpression: String?
        var line: Int
    }

    private struct DecodedDefault {
        var property: String
        var defaultName: String
        var line: Int
    }

    /// The section name each struct occupies in the settings document. The
    /// migration blocks address keys as `next.<section>.<key>`, so the linter
    /// needs the same mapping to tell a real key from a typo.
    private static let sectionStructNames = [
        "terminal": "TerminalSettings",
        "window": "WindowSettings",
        "shell": "ShellSettings",
    ]

    private static func settingsStructs(
        in scan: SwiftSourceScan,
        findings: inout [Finding]
    ) -> [String: SettingsStruct] {
        var result: [String: SettingsStruct] = [:]
        for (section, structName) in sectionStructNames.sorted(by: { $0.key < $1.key }) {
            guard let parsed = parseStruct(named: structName, in: scan) else {
                findings.append(Finding(
                    rule: .sourceStructure,
                    file: scan.name,
                    line: 1,
                    message: "no `struct \(structName)` found; the settings sections are the linter's map of the schema"
                ))
                continue
            }
            result[section] = parsed
        }
        return result
    }

    private static func parseStruct(named name: String, in scan: SwiftSourceScan) -> SettingsStruct? {
        guard let header = scan.declarationLine(kind: "struct", name: name),
              let body = scan.block(headerAt: header)
        else {
            return nil
        }

        var storedProperties: [Declaration] = []
        for index in body.body where scan.depthBefore[index] == body.bodyDepth {
            // A stored property, not a computed one: the line declares a type
            // and ends there. `var x: T {` opens an accessor block instead.
            guard let match = captures(#"^var ([A-Za-z_][A-Za-z0-9_]*):\s*[^{]+$"#, scan.trimmed(index)) else {
                continue
            }
            storedProperties.append(Declaration(name: match[1], line: index))
        }

        var codingKeys: [Declaration]?
        if let keysHeader = scan.declarationLine(kind: "enum", name: "CodingKeys", in: body.body),
           let keysBody = scan.block(headerAt: keysHeader) {
            codingKeys = keysBody.body.compactMap { index in
                captures(#"^case ([A-Za-z_][A-Za-z0-9_]*)$"#, scan.trimmed(index))
                    .map { Declaration(name: $0[1], line: index) }
            }
        }

        var initializerParameters: [InitializerParameter]?
        if let initHeader = body.body.first(where: { scan.trimmed($0) == "init(" }),
           let closing = (initHeader..<body.body.upperBound).first(where: {
               captures(#"^\)\s*\{$"#, scan.trimmed($0)) != nil
           }) {
            initializerParameters = ((initHeader + 1)..<closing).compactMap { index in
                parseInitializerParameter(scan.trimmed(index), line: index)
            }
        }

        var optionalDecodedDefaults: [DecodedDefault] = []
        if let decoderHeader = body.body.first(where: { scan.trimmed($0).hasPrefix("init(from decoder") }),
           let decoderBody = scan.block(headerAt: decoderHeader) {
            for statement in assignmentStatements(in: decoderBody.body, scan: scan) {
                guard statement.text.contains("decodeIfPresent"),
                      let fallback = captures(#"\?\?\s*SettingsDefaults\.([A-Za-z_][A-Za-z0-9_]*)"#, statement.text)
                else {
                    continue
                }
                optionalDecodedDefaults.append(DecodedDefault(
                    property: statement.target,
                    defaultName: fallback[1],
                    line: statement.line
                ))
            }
        }

        return SettingsStruct(
            name: name,
            storedProperties: storedProperties,
            codingKeys: codingKeys,
            initializerParameters: initializerParameters,
            optionalDecodedDefaults: optionalDecodedDefaults
        )
    }

    private static func parseInitializerParameter(_ text: String, line: Int) -> InitializerParameter? {
        guard let colon = text.firstIndex(of: ":") else {
            return nil
        }
        let name = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        guard captures(#"^[A-Za-z_][A-Za-z0-9_]*$"#, name) != nil else {
            return nil
        }
        var remainder = String(text[text.index(after: colon)...])
        if remainder.hasSuffix(",") {
            remainder.removeLast()
        }
        guard let equals = remainder.range(of: " = ") else {
            return InitializerParameter(name: name, defaultExpression: nil, line: line)
        }
        let expression = String(remainder[equals.upperBound...]).trimmingCharacters(in: .whitespaces)
        return InitializerParameter(name: name, defaultExpression: expression, line: line)
    }

    /// Statements of the form `target = ...`, folded back together across the
    /// continuation lines that `decodeIfPresent` calls are routinely wrapped on.
    private struct AssignmentStatement {
        var target: String
        var text: String
        var line: Int
    }

    private static func assignmentStatements(
        in range: Range<Int>,
        scan: SwiftSourceScan
    ) -> [AssignmentStatement] {
        var statements: [AssignmentStatement] = []
        for index in range {
            let trimmed = scan.trimmed(index)
            if let match = captures(#"^([A-Za-z_][A-Za-z0-9_]*) = "#, trimmed) {
                statements.append(AssignmentStatement(target: match[1], text: trimmed, line: index))
            } else if !statements.isEmpty, !trimmed.isEmpty {
                statements[statements.count - 1].text += " " + trimmed
            }
        }
        return statements
    }

    // MARK: - Struct Shape

    private static func checkStructShape(
        _ structs: [String: SettingsStruct],
        in scan: SwiftSourceScan,
        findings: inout [Finding]
    ) {
        for section in structs.keys.sorted() {
            guard let model = structs[section] else { continue }
            let propertyNames = Set(model.storedProperties.map(\.name))

            // A hand-written `CodingKeys` is the whole persistence contract: a
            // property missing from it is silently never written to disk, and
            // the compiler has nothing to say about that.
            if let codingKeys = model.codingKeys {
                let keyNames = Set(codingKeys.map(\.name))
                for property in model.storedProperties where !keyNames.contains(property.name) {
                    findings.append(Finding(
                        rule: .codingKey,
                        file: scan.name,
                        line: property.line + 1,
                        message: "\(model.name).\(property.name) has no CodingKeys case, so it is never encoded"
                    ))
                }
                for key in codingKeys where !propertyNames.contains(key.name) {
                    findings.append(Finding(
                        rule: .codingKey,
                        file: scan.name,
                        line: key.line + 1,
                        message: "\(model.name).CodingKeys.\(key.name) has no matching stored property"
                    ))
                }
            }

            if let parameters = model.initializerParameters {
                let parameterNames = Set(parameters.map(\.name))
                for property in model.storedProperties where !parameterNames.contains(property.name) {
                    findings.append(Finding(
                        rule: .initializerParameter,
                        file: scan.name,
                        line: property.line + 1,
                        message: "\(model.name).\(property.name) has no initializer parameter of the same name"
                    ))
                }
                // Defaults live in exactly one table. A literal here would be a
                // second copy that drifts from `SettingsDefaults` unnoticed.
                for parameter in parameters {
                    guard let expression = parameter.defaultExpression,
                          !expression.hasPrefix("SettingsDefaults.")
                    else {
                        continue
                    }
                    findings.append(Finding(
                        rule: .defaultSource,
                        file: scan.name,
                        line: parameter.line + 1,
                        message: "\(model.name).init parameter \(parameter.name) defaults to \(expression) "
                            + "rather than to a SettingsDefaults constant"
                    ))
                }
            }
        }
    }

    private static func checkDefaultAliases(in scan: SwiftSourceScan, findings: inout [Finding]) {
        guard let header = scan.declarationLine(kind: "struct", name: "AppSettings"),
              let appSettings = scan.block(headerAt: header)
        else {
            findings.append(Finding(
                rule: .sourceStructure,
                file: scan.name,
                line: 1,
                message: "no `struct AppSettings` found"
            ))
            return
        }
        guard let aliasHeader = scan.declarationLine(kind: "enum", name: "Defaults", in: appSettings.body),
              let aliases = scan.block(headerAt: aliasHeader)
        else {
            findings.append(Finding(
                rule: .sourceStructure,
                file: scan.name,
                line: appSettings.header + 1,
                message: "no `enum Defaults` inside AppSettings"
            ))
            return
        }

        var declared: [Declaration] = []
        for index in aliases.body {
            guard let match = captures(#"^static let ([A-Za-z_][A-Za-z0-9_]*) = (.+)$"#, scan.trimmed(index)) else {
                continue
            }
            declared.append(Declaration(name: match[1], line: index))
            // The alias table exists to name the shared defaults, never to
            // restate their values.
            if captures(#"^SettingsDefaults\.[A-Za-z_][A-Za-z0-9_]*$"#, match[2]) == nil {
                findings.append(Finding(
                    rule: .defaultSource,
                    file: scan.name,
                    line: index + 1,
                    message: "AppSettings.Defaults.\(match[1]) is \(match[2]) rather than a SettingsDefaults constant"
                ))
            }
        }

        var used: Set<String> = []
        for index in appSettings.body where !aliases.body.contains(index) {
            for name in matches(#"(?<![A-Za-z0-9_])Defaults\.([A-Za-z_][A-Za-z0-9_]*)"#, scan.code[index]) {
                used.insert(name)
            }
        }
        for alias in declared where !used.contains(alias.name) {
            findings.append(Finding(
                rule: .unusedDefaultAlias,
                file: scan.name,
                line: alias.line + 1,
                message: "AppSettings.Defaults.\(alias.name) is never read; "
                    + "the value it names is not reaching AppSettings.default"
            ))
        }
    }

    // MARK: - Migrations

    private struct MigrationConstant {
        var name: String
        var version: Int
        var documentation: String
        var line: Int
    }

    private struct MigrationBlock {
        var constantName: String
        var conditionLine: Int
        var isTopLevel: Bool
        var assignments: [MigrationAssignment]
    }

    private struct MigrationAssignment {
        var section: String
        var key: String
        var expression: String
        var line: Int
    }

    private static func schemaVersion(in scan: SwiftSourceScan, findings: inout [Finding]) -> Int? {
        for index in 0..<scan.code.count {
            guard let match = captures(
                #"^public static let schemaVersion = ([0-9_]+)$"#,
                scan.trimmed(index)
            ) else {
                continue
            }
            return Int(match[1].replacingOccurrences(of: "_", with: ""))
        }
        findings.append(Finding(
            rule: .sourceStructure,
            file: scan.name,
            line: 1,
            message: "no `public static let schemaVersion` found"
        ))
        return nil
    }

    private static func checkMigrations(
        in scan: SwiftSourceScan,
        structs: [String: SettingsStruct],
        currentSchemaVersion: Int?,
        findings: inout [Finding]
    ) {
        guard let normalizerHeader = scan.declarationLine(kind: "struct", name: "AppSettingsNormalizer"),
              let normalizer = scan.block(headerAt: normalizerHeader)
        else {
            findings.append(Finding(
                rule: .sourceStructure,
                file: scan.name,
                line: 1,
                message: "no `struct AppSettingsNormalizer` found"
            ))
            return
        }
        guard let migrationHeader = scan.declarationLine(kind: "enum", name: "Migration", in: normalizer.body),
              let migrationEnum = scan.block(headerAt: migrationHeader)
        else {
            findings.append(Finding(
                rule: .sourceStructure,
                file: scan.name,
                line: normalizer.header + 1,
                message: "no `enum Migration` inside AppSettingsNormalizer"
            ))
            return
        }
        guard let normalizedHeader = normalizer.body.first(where: {
            scan.trimmed($0).hasPrefix("static func normalized(")
        }), let normalized = scan.block(headerAt: normalizedHeader) else {
            findings.append(Finding(
                rule: .sourceStructure,
                file: scan.name,
                line: normalizer.header + 1,
                message: "no `static func normalized(_:)` inside AppSettingsNormalizer"
            ))
            return
        }

        let constants = parseMigrationConstants(in: migrationEnum.body, scan: scan, findings: &findings)
        let blocks = parseMigrationBlocks(in: normalized, scan: scan, findings: &findings)

        checkConstantVersions(constants, currentSchemaVersion: currentSchemaVersion, scan: scan, findings: &findings)
        checkConstantBlockPairing(constants, blocks: blocks, scan: scan, findings: &findings)
        checkBlockContents(blocks, constants: constants, structs: structs, scan: scan, findings: &findings)
        checkMigrationCoverage(structs, blocks: blocks, scan: scan, findings: &findings)
    }

    private static func parseMigrationConstants(
        in range: Range<Int>,
        scan: SwiftSourceScan,
        findings: inout [Finding]
    ) -> [MigrationConstant] {
        var constants: [MigrationConstant] = []
        var documentation: [String] = []
        for index in range {
            let raw = scan.raw[index].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("///") {
                documentation.append(String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let match = captures(
                #"^static let ([A-Za-z_][A-Za-z0-9_]*) = ([0-9_]+)$"#,
                scan.trimmed(index)
            ) else {
                if !raw.isEmpty {
                    documentation.removeAll()
                }
                continue
            }
            constants.append(MigrationConstant(
                name: match[1],
                version: Int(match[2].replacingOccurrences(of: "_", with: "")) ?? -1,
                documentation: documentation.joined(separator: " "),
                line: index
            ))
            if documentation.isEmpty {
                findings.append(Finding(
                    rule: .migrationDocumentation,
                    file: scan.name,
                    line: index + 1,
                    message: "Migration.\(match[1]) has no doc comment naming the keys it introduced"
                ))
            }
            documentation.removeAll()
        }
        return constants
    }

    private static func parseMigrationBlocks(
        in normalized: SwiftSourceScan.Block,
        scan: SwiftSourceScan,
        findings: inout [Finding]
    ) -> [MigrationBlock] {
        var blocks: [MigrationBlock] = []
        for index in normalized.body {
            let trimmed = scan.trimmed(index)
            guard trimmed.hasPrefix("if "), trimmed.contains("sourceSchemaVersion") else {
                continue
            }
            let isTopLevel = scan.depthBefore[index] == normalized.bodyDepth

            guard let condition = captures(
                #"^if sourceSchemaVersion < ([A-Za-z_][A-Za-z0-9_.]*) \{$"#,
                trimmed
            ) else {
                findings.append(Finding(
                    rule: .migrationCondition,
                    file: scan.name,
                    line: index + 1,
                    message: "migration guard is `\(trimmed)`; it must read "
                        + "`if sourceSchemaVersion < Migration.<name> {`"
                ))
                continue
            }

            // The one guard in this function that reads a schema version without
            // being a migration: it gates the legacy colour rewrite.
            if condition[1] == "currentSchemaVersion" {
                if !isTopLevel {
                    findings.append(Finding(
                        rule: .migrationBlockNesting,
                        file: scan.name,
                        line: index + 1,
                        message: "the legacy-defaults guard is nested inside another block"
                    ))
                }
                continue
            }

            guard condition[1].hasPrefix("Migration.") else {
                findings.append(Finding(
                    rule: .migrationCondition,
                    file: scan.name,
                    line: index + 1,
                    message: "migration guard compares against \(condition[1]); "
                        + "a version belongs in a named Migration constant, not at the comparison"
                ))
                continue
            }

            if !isTopLevel {
                findings.append(Finding(
                    rule: .migrationBlockNesting,
                    file: scan.name,
                    line: index + 1,
                    message: "\(condition[1]) is nested inside another block of normalized(_:); "
                        + "it only runs for files that already matched the outer guard"
                ))
            }

            var assignments: [MigrationAssignment] = []
            if let block = scan.block(headerAt: index) {
                for line in block.body where scan.depthBefore[line] == block.bodyDepth {
                    let statement = scan.trimmed(line)
                    guard statement.hasPrefix("next.") else { continue }
                    guard let match = captures(
                        #"^next\.([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*) = (.+)$"#,
                        statement
                    ) else {
                        findings.append(Finding(
                            rule: .migrationAssignmentShape,
                            file: scan.name,
                            line: line + 1,
                            message: "`\(statement)` is not a `next.<section>.<key> = ...` reset"
                        ))
                        continue
                    }
                    assignments.append(MigrationAssignment(
                        section: match[1],
                        key: match[2],
                        expression: match[3],
                        line: line
                    ))
                }
                if assignments.isEmpty {
                    findings.append(Finding(
                        rule: .migrationAssignmentShape,
                        file: scan.name,
                        line: index + 1,
                        message: "\(condition[1]) guards no key reset at all"
                    ))
                }
            }

            blocks.append(MigrationBlock(
                constantName: String(condition[1].dropFirst("Migration.".count)),
                conditionLine: index,
                isTopLevel: isTopLevel,
                assignments: assignments
            ))
        }
        return blocks
    }

    private static func checkConstantVersions(
        _ constants: [MigrationConstant],
        currentSchemaVersion: Int?,
        scan: SwiftSourceScan,
        findings: inout [Finding]
    ) {
        for constant in constants {
            if constant.version < 1 {
                findings.append(Finding(
                    rule: .migrationVersionRange,
                    file: scan.name,
                    line: constant.line + 1,
                    message: "Migration.\(constant.name) is \(constant.version); schema versions start at 1"
                ))
            }
            if let current = currentSchemaVersion, constant.version > current {
                findings.append(Finding(
                    rule: .migrationVersionRange,
                    file: scan.name,
                    line: constant.line + 1,
                    message: "Migration.\(constant.name) is \(constant.version) but SettingsDefaults.schemaVersion "
                        + "is \(current); the reset would fire on files the app itself just wrote"
                ))
            }
        }

        // Declaration order is the table's index. A merge that appends out of
        // order is the same merge that gets the rest of this wrong.
        for (previous, next) in zip(constants, constants.dropFirst()) where next.version < previous.version {
            findings.append(Finding(
                rule: .migrationVersionOrder,
                file: scan.name,
                line: next.line + 1,
                message: "Migration.\(next.name) (\(next.version)) is declared after "
                    + "Migration.\(previous.name) (\(previous.version))"
            ))
        }

        // Two constants at the version the app currently writes is the second
        // merge trap: both branches bumped the schema to the same number and the
        // text merged cleanly. It is usually right — both keys did arrive in that
        // version — so this asks for a word rather than forbidding it.
        guard let current = currentSchemaVersion else { return }
        let shared = Dictionary(grouping: constants, by: \.version)
            .filter { $0.key == current && $0.value.count > 1 }
        for (version, group) in shared.sorted(by: { $0.key < $1.key }) {
            guard !group.allSatisfy({ $0.documentation.contains(sharedVersionDirective) }) else {
                continue
            }
            let names = group.map(\.name).sorted().joined(separator: ", ")
            findings.append(Finding(
                rule: .migrationVersionShared,
                file: scan.name,
                line: group.map(\.line).min().map { $0 + 1 } ?? 1,
                message: "\(names) all sit at schema \(version), which is the version the app writes today. "
                    + "Confirm every one of those keys really shipped in \(version) and add "
                    + "`\(sharedVersionDirective)` to each doc comment, or give one its own version"
            ))
        }
    }

    private static func checkConstantBlockPairing(
        _ constants: [MigrationConstant],
        blocks: [MigrationBlock],
        scan: SwiftSourceScan,
        findings: inout [Finding]
    ) {
        let declared = Dictionary(uniqueKeysWithValues: constants.map { ($0.name, $0) })
        var guardedBy: [String: [MigrationBlock]] = [:]
        for block in blocks {
            guardedBy[block.constantName, default: []].append(block)
        }

        for constant in constants where guardedBy[constant.name] == nil {
            findings.append(Finding(
                rule: .migrationConstantUnused,
                file: scan.name,
                line: constant.line + 1,
                message: "Migration.\(constant.name) guards no block in normalized(_:); "
                    + "the reset it was declared for is not running"
            ))
        }
        for (name, group) in guardedBy.sorted(by: { $0.key < $1.key }) {
            if declared[name] == nil {
                findings.append(Finding(
                    rule: .migrationConstantUnknown,
                    file: scan.name,
                    line: (group.first?.conditionLine ?? 0) + 1,
                    message: "normalized(_:) guards on Migration.\(name), which is not declared"
                ))
            }
            guard group.count > 1 else { continue }
            findings.append(Finding(
                rule: .migrationConstantDuplicated,
                file: scan.name,
                line: (group.last?.conditionLine ?? 0) + 1,
                message: "Migration.\(name) guards \(group.count) separate blocks; "
                    + "one constant means one block"
            ))
        }
    }

    private static func checkBlockContents(
        _ blocks: [MigrationBlock],
        constants: [MigrationConstant],
        structs: [String: SettingsStruct],
        scan: SwiftSourceScan,
        findings: inout [Finding]
    ) {
        let declared = Dictionary(uniqueKeysWithValues: constants.map { ($0.name, $0) })
        for block in blocks {
            for assignment in block.assignments {
                if !assignment.expression.hasPrefix("SettingsDefaults.") {
                    findings.append(Finding(
                        rule: .migrationAssignmentShape,
                        file: scan.name,
                        line: assignment.line + 1,
                        message: "\(assignment.section).\(assignment.key) migrates to \(assignment.expression); "
                            + "a migration resets to the shared default, never to a value written out again here"
                    ))
                }
                if let model = structs[assignment.section] {
                    if model.property(named: assignment.key) == nil {
                        findings.append(Finding(
                            rule: .migrationAssignmentUnknownKey,
                            file: scan.name,
                            line: assignment.line + 1,
                            message: "\(model.name) has no property \(assignment.key)"
                        ))
                    }
                } else {
                    findings.append(Finding(
                        rule: .migrationAssignmentUnknownKey,
                        file: scan.name,
                        line: assignment.line + 1,
                        message: "\(assignment.section) is not a settings section"
                    ))
                }

                // The doc comment is the record of which keys a schema version
                // introduced. A block that resets a key its own comment never
                // names has either grown a key it should not own or absorbed a
                // neighbour during a merge.
                guard let constant = declared[block.constantName] else { continue }
                if !mentions(assignment.key, in: constant.documentation) {
                    findings.append(Finding(
                        rule: .migrationAssignmentUndocumented,
                        file: scan.name,
                        line: assignment.line + 1,
                        message: "Migration.\(constant.name) resets \(assignment.section).\(assignment.key), "
                            + "but its doc comment does not name that key"
                    ))
                }
            }
        }
    }

    private static func checkMigrationCoverage(
        _ structs: [String: SettingsStruct],
        blocks: [MigrationBlock],
        scan: SwiftSourceScan,
        findings: inout [Finding]
    ) {
        var migrated: Set<String> = []
        for block in blocks {
            for assignment in block.assignments {
                migrated.insert("\(assignment.section).\(assignment.key)")
            }
        }

        for section in structs.keys.sorted() {
            guard let model = structs[section] else { continue }
            for decoded in model.optionalDecodedDefaults {
                let qualified = "\(section).\(decoded.property)"
                guard !migrated.contains(qualified),
                      keysExemptFromMigration[qualified] == nil
                else {
                    continue
                }
                findings.append(Finding(
                    rule: .migrationMissingForKey,
                    file: scan.name,
                    line: decoded.line + 1,
                    message: "\(qualified) falls back to SettingsDefaults.\(decoded.defaultName) when absent, "
                        + "so an older file can reach the app without it, yet no migration block resets it. "
                        + "Add the block, or record the exemption in SettingsSchemaLinter"
                ))
            }
        }
    }

    // MARK: - Validation Keys

    private static func checkValidationKeys(
        in scan: SwiftSourceScan,
        structs: [String: SettingsStruct],
        findings: inout [Finding]
    ) {
        guard let header = scan.declarationLine(kind: "enum", name: "AppSettingKey"),
              let block = scan.block(headerAt: header)
        else {
            findings.append(Finding(
                rule: .sourceStructure,
                file: scan.name,
                line: 1,
                message: "no `enum AppSettingKey` found"
            ))
            return
        }

        for index in block.body {
            guard let match = captures(#"^case ([A-Za-z_][A-Za-z0-9_]*)$"#, scan.trimmed(index)) else {
                continue
            }
            let key = match[1]
            // `schemaVersion` is the document's own key and the colour keys name
            // fields of the nested `TerminalColorSettings`, so neither maps onto
            // a section property one-to-one.
            guard key != "schemaVersion", !key.hasPrefix("terminalColors") else {
                continue
            }
            guard let section = sectionStructNames.keys.sorted(by: { $0.count > $1.count })
                .first(where: { key.hasPrefix($0) && key.count > $0.count })
            else {
                findings.append(Finding(
                    rule: .validationKey,
                    file: scan.name,
                    line: index + 1,
                    message: "AppSettingKey.\(key) names no settings section"
                ))
                continue
            }
            guard let model = structs[section] else { continue }
            let suffix = String(key.dropFirst(section.count))
            let matched = model.storedProperties.contains {
                $0.name.compare(suffix, options: .caseInsensitive) == .orderedSame
            }
            guard !matched else { continue }
            findings.append(Finding(
                rule: .validationKey,
                file: scan.name,
                line: index + 1,
                message: "AppSettingKey.\(key) has no matching \(model.name) property; "
                    + "the validation report is describing a key that no longer exists"
            ))
        }
    }

    // MARK: - Text Helpers

    private static func mentions(_ identifier: String, in text: String) -> Bool {
        captures("(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: identifier))(?![A-Za-z0-9_])", text) != nil
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else {
            return nil
        }
        return (0..<match.numberOfRanges).map { group in
            Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Source Scan

/// One Swift file reduced to something with a trustworthy brace depth: line
/// comments, block comments, and the interiors of string literals are blanked,
/// so a brace inside a comment or a string cannot move the count. `raw` keeps
/// the original text because two invariants are about what a doc comment says.
private struct SwiftSourceScan {
    let name: String
    let raw: [String]
    let code: [String]
    let depthBefore: [Int]
    let depthAfter: [Int]
    let finalDepth: Int
    let firstNegativeDepthLine: Int?

    struct Block {
        let header: Int
        let body: Range<Int>
        let bodyDepth: Int
    }

    init(name: String, text: String) {
        self.name = name
        let rawLines = text.components(separatedBy: "\n")
        var codeLines: [String] = []
        codeLines.reserveCapacity(rawLines.count)

        var inBlockComment = false
        for line in rawLines {
            let characters = Array(line)
            var output = ""
            var inString = false
            var escaped = false
            var index = 0
            while index < characters.count {
                let character = characters[index]
                let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
                if inBlockComment {
                    if character == "*", next == "/" {
                        inBlockComment = false
                        output.append("  ")
                        index += 2
                        continue
                    }
                    output.append(" ")
                    index += 1
                    continue
                }
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                    output.append(" ")
                    index += 1
                    continue
                }
                if character == "/", next == "/" {
                    break
                }
                if character == "/", next == "*" {
                    inBlockComment = true
                    output.append("  ")
                    index += 2
                    continue
                }
                if character == "\"" {
                    inString = true
                    output.append(" ")
                    index += 1
                    continue
                }
                output.append(character)
                index += 1
            }
            codeLines.append(output)
        }

        var before: [Int] = []
        var after: [Int] = []
        var depth = 0
        var negative: Int?
        before.reserveCapacity(codeLines.count)
        after.reserveCapacity(codeLines.count)
        for (index, line) in codeLines.enumerated() {
            before.append(depth)
            for character in line where character == "{" || character == "}" {
                depth += character == "{" ? 1 : -1
                if depth < 0, negative == nil {
                    negative = index
                }
            }
            after.append(depth)
        }

        self.raw = rawLines
        self.code = codeLines
        self.depthBefore = before
        self.depthAfter = after
        self.finalDepth = depth
        self.firstNegativeDepthLine = negative
    }

    func trimmed(_ index: Int) -> String {
        code[index].trimmingCharacters(in: .whitespaces)
    }

    /// The line declaring `kind name`, ignoring any access modifier in front of
    /// it and refusing a prefix match, so `struct AppSettings` never resolves to
    /// `struct AppSettingsPersistence`.
    func declarationLine(kind: String, name: String, in range: Range<Int>? = nil) -> Int? {
        let searched = range ?? 0..<code.count
        let pattern = "^(?:public |internal |private |fileprivate )?(?:final )?\(kind) "
            + "\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        return searched.first { index in
            let line = trimmed(index)
            return expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
    }

    /// The lines strictly inside the braces opened by the declaration whose
    /// header starts at `header`, plus the depth those lines sit at.
    func block(headerAt header: Int) -> Block? {
        guard let open = (header..<code.count).first(where: { code[$0].contains("{") }),
              depthAfter[open] > depthBefore[open],
              let close = ((open + 1)..<code.count).first(where: { depthAfter[$0] <= depthBefore[open] })
        else {
            return nil
        }
        return Block(header: header, body: (open + 1)..<close, bodyDepth: depthAfter[open])
    }
}
