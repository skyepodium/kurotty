import AppKit
import XCTest
@testable import KurottyApp

final class QuickCommandTests: XCTestCase {
    private enum Fixture {
        static let repositoryPath = "/Users/tester/dev/terminal/kurotty"
        static let nestedPath = "/Users/tester/dev/terminal/kurotty/Sources/KurottyApp"
        static let siblingPath = "/Users/tester/dev/terminal/orca"
        static let parentPath = "/Users/tester/dev/terminal"
        static let statusCommand = "git status"
        static let buildCommand = "swift build"
        static let commandIdentifier = "test-command"
        static let commandName = "Status"
    }

    private func makeCommand(
        id: String = Fixture.commandIdentifier,
        name: String = Fixture.commandName,
        scope: QuickCommandScope = .global,
        text: String = Fixture.statusCommand,
        appendEnter: Bool = false
    ) -> QuickCommand {
        QuickCommand(
            id: id,
            name: name,
            scope: scope,
            action: .terminalCommand(text: text, appendEnter: appendEnter)
        )
    }

    // MARK: - Normalization and limits

    func testNormalizationTrimsNameAndKeepsBodyTrailingTrim() {
        let normalized = QuickCommandNormalizer.normalize(records: [
            QuickCommandRecord(
                id: "  \(Fixture.commandIdentifier)  ",
                name: "  \(Fixture.commandName)  ",
                command: "\(Fixture.statusCommand)   \n"
            ),
        ])

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].id, Fixture.commandIdentifier)
        XCTAssertEqual(normalized[0].name, Fixture.commandName)
        XCTAssertEqual(normalized[0].bodyText, Fixture.statusCommand)
    }

    func testNormalizationPreservesIncompleteInProgressRows() {
        let normalized = QuickCommandNormalizer.normalize(records: [
            QuickCommandRecord(id: "row-1", name: ""),
            QuickCommandRecord(id: "row-2", command: ""),
            QuickCommandRecord(id: "row-3", name: "", command: ""),
        ])

        XCTAssertEqual(normalized.map(\.id), ["row-1", "row-2", "row-3"])
        XCTAssertTrue(normalized.allSatisfy { !$0.isComplete })
    }

    func testNormalizationDropsRecordsWithoutAnyBodyOrNameField() {
        let normalized = QuickCommandNormalizer.normalize(records: [
            QuickCommandRecord(id: "only-id"),
            QuickCommandRecord(id: "kept", name: ""),
        ])

        XCTAssertEqual(normalized.map(\.id), ["kept"])
    }

    func testNormalizationCapsCommandCount() {
        let overflowCount = AppConstants.QuickCommands.maximumCommandCount + 5
        let records = (0..<overflowCount).map { index in
            QuickCommandRecord(id: "command-\(index)", name: "n\(index)", command: Fixture.statusCommand)
        }

        let normalized = QuickCommandNormalizer.normalize(records: records)

        XCTAssertEqual(normalized.count, AppConstants.QuickCommands.maximumCommandCount)
        XCTAssertEqual(normalized.last?.id, "command-\(AppConstants.QuickCommands.maximumCommandCount - 1)")
    }

    func testNormalizationTruncatesTerminalTextAndAgentPromptSeparately() {
        let longText = String(repeating: "a", count: AppConstants.QuickCommands.maximumAgentPromptCharacterCount + 50)
        let normalized = QuickCommandNormalizer.normalize(records: [
            QuickCommandRecord(id: "terminal", name: "t", command: longText),
            QuickCommandRecord(
                id: "agent",
                name: "a",
                action: AppConstants.QuickCommands.agentPromptActionRawValue,
                prompt: longText,
                agent: "claude"
            ),
        ])

        XCTAssertEqual(normalized[0].bodyText.count, AppConstants.QuickCommands.maximumTerminalTextCharacterCount)
        XCTAssertEqual(normalized[1].bodyText.count, AppConstants.QuickCommands.maximumAgentPromptCharacterCount)
        XCTAssertEqual(normalized[1].action, .agentPrompt(text: normalized[1].bodyText, agent: "claude"))
    }

    func testNormalizationTruncatesNameToLimit() {
        let longName = String(repeating: "n", count: AppConstants.QuickCommands.maximumNameCharacterCount + 10)
        let normalized = QuickCommandNormalizer.normalize(records: [
            QuickCommandRecord(id: "x", name: longName, command: Fixture.statusCommand),
        ])

        XCTAssertEqual(normalized[0].name.count, AppConstants.QuickCommands.maximumNameCharacterCount)
    }

    func testNormalizationDeduplicatesIdentifiersAndFillsMissingOnes() {
        let normalized = QuickCommandNormalizer.normalize(records: [
            QuickCommandRecord(id: "same", name: "a", command: Fixture.statusCommand),
            QuickCommandRecord(id: "same", name: "b", command: Fixture.buildCommand),
            QuickCommandRecord(name: "c", command: Fixture.buildCommand),
        ])

        XCTAssertEqual(normalized[0].id, "same")
        XCTAssertEqual(normalized[1].id, "same-2")
        XCTAssertEqual(normalized[2].id, "\(AppConstants.QuickCommands.identifierPrefix)3")
    }

    func testAbsentAppendEnterNormalizesToInsertOnly() {
        let normalized = QuickCommandNormalizer.normalize(records: [
            QuickCommandRecord(id: "x", name: "n", command: Fixture.statusCommand),
        ])

        XCTAssertEqual(normalized[0].action, .terminalCommand(text: Fixture.statusCommand, appendEnter: false))
        XCTAssertFalse(normalized[0].executesOnDispatch)
    }

    func testScopeNormalizationFallsBackToGlobalForUnknownOrEmptyPaths() {
        let normalized = QuickCommandNormalizer.normalize(records: [
            QuickCommandRecord(id: "a", name: "a", scope: QuickCommandScopeRecord(type: "repo", path: Fixture.repositoryPath), command: Fixture.statusCommand),
            QuickCommandRecord(id: "b", name: "b", scope: QuickCommandScopeRecord(type: AppConstants.QuickCommands.directoryScopeRawValue, path: "   "), command: Fixture.statusCommand),
            QuickCommandRecord(id: "c", name: "c", scope: QuickCommandScopeRecord(type: AppConstants.QuickCommands.directoryScopeRawValue, path: Fixture.repositoryPath), command: Fixture.statusCommand),
        ])

        XCTAssertEqual(normalized[0].scope, .global)
        XCTAssertEqual(normalized[1].scope, .global)
        XCTAssertEqual(normalized[2].scope, .directory(path: Fixture.repositoryPath))
    }

    func testMutationMergePreservesUnrelatedCommands() {
        let existing = [makeCommand(id: "a", name: "A"), makeCommand(id: "b", name: "B")]

        let updated = QuickCommandNormalizer.apply(.upsert(makeCommand(id: "b", name: "B2")), to: existing)
        XCTAssertEqual(updated.map(\.name), ["A", "B2"])

        let appended = QuickCommandNormalizer.apply(.upsert(makeCommand(id: "c", name: "C")), to: existing)
        XCTAssertEqual(appended.map(\.id), ["a", "b", "c"])

        let deleted = QuickCommandNormalizer.apply(.delete(id: "a"), to: existing)
        XCTAssertEqual(deleted.map(\.id), ["b"])
    }

    func testMutationUpsertRefusesToGrowBeyondTheCap() {
        let full = (0..<AppConstants.QuickCommands.maximumCommandCount).map { makeCommand(id: "c\($0)") }

        let result = QuickCommandNormalizer.apply(.upsert(makeCommand(id: "overflow")), to: full)

        XCTAssertEqual(result.count, AppConstants.QuickCommands.maximumCommandCount)
        XCTAssertFalse(result.contains { $0.id == "overflow" })
    }

    // MARK: - Multi-line flattening

    func testMultiLineTerminalTextFlattensToShellCommandList() {
        let flattened = QuickCommandNormalizer.flattenedTerminalText("git fetch\n  git status  \n\ngit log")

        XCTAssertEqual(flattened, "git fetch; git status; git log")
        XCTAssertFalse(flattened.contains("\n"))
        XCTAssertFalse(flattened.contains("\r"))
    }

    func testFlatteningHandlesCarriageReturnAndCarriageReturnNewline() {
        XCTAssertEqual(QuickCommandNormalizer.flattenedTerminalText("a\r\nb"), "a; b")
        XCTAssertEqual(QuickCommandNormalizer.flattenedTerminalText("a\rb"), "a; b")
    }

    func testSingleLineTerminalTextIsUnchangedByFlattening() {
        XCTAssertEqual(
            QuickCommandNormalizer.flattenedTerminalText("  \(Fixture.statusCommand)  "),
            "  \(Fixture.statusCommand)  "
        )
    }

    func testFlatteningAQuickCommandRewritesOnlyItsBody() {
        let command = makeCommand(text: "git fetch\ngit status", appendEnter: true)

        let flattened = QuickCommandNormalizer.flattened(command)

        XCTAssertEqual(flattened.action, .terminalCommand(text: "git fetch; git status", appendEnter: true))
        XCTAssertEqual(flattened.id, command.id)
        XCTAssertEqual(flattened.name, command.name)
    }

    func testAgentPromptFlatteningJoinsWithSpacesAndNeverKeepsLineBreaks() {
        let command = QuickCommand(
            id: "agent",
            name: "Review",
            action: .agentPrompt(text: "review this diff\nfocus on tests", agent: "claude")
        )

        let flattened = QuickCommandNormalizer.flattened(command)

        XCTAssertEqual(flattened.bodyText, "review this diff focus on tests")
        XCTAssertFalse(flattened.bodyText.contains("\n"))
    }

    // MARK: - Directory scope filtering

    func testDirectoryScopedCommandsOnlyAppearAtOrBelowTheirDirectory() {
        let command = makeCommand(scope: .directory(path: Fixture.repositoryPath))

        XCTAssertTrue(QuickCommandNormalizer.isVisible(command, inWorkingDirectory: Fixture.repositoryPath))
        XCTAssertTrue(QuickCommandNormalizer.isVisible(command, inWorkingDirectory: Fixture.nestedPath))
        XCTAssertTrue(QuickCommandNormalizer.isVisible(command, inWorkingDirectory: Fixture.repositoryPath + "/"))
        XCTAssertFalse(QuickCommandNormalizer.isVisible(command, inWorkingDirectory: Fixture.parentPath))
        XCTAssertFalse(QuickCommandNormalizer.isVisible(command, inWorkingDirectory: Fixture.siblingPath))
        XCTAssertFalse(QuickCommandNormalizer.isVisible(command, inWorkingDirectory: nil))
    }

    func testDirectoryScopeDoesNotMatchOnPartialComponentNames() {
        let command = makeCommand(scope: .directory(path: Fixture.repositoryPath))

        XCTAssertFalse(
            QuickCommandNormalizer.isVisible(command, inWorkingDirectory: Fixture.repositoryPath + "-old")
        )
    }

    func testGlobalCommandsAppearEverywhereIncludingUnknownDirectories() {
        let command = makeCommand()

        XCTAssertTrue(QuickCommandNormalizer.isVisible(command, inWorkingDirectory: nil))
        XCTAssertTrue(QuickCommandNormalizer.isVisible(command, inWorkingDirectory: Fixture.siblingPath))
    }

    func testVisibleCommandsFiltersTheListForACwd() {
        let commands = [
            makeCommand(id: "global", name: "Global"),
            makeCommand(id: "scoped", name: "Scoped", scope: .directory(path: Fixture.repositoryPath)),
            makeCommand(id: "other", name: "Other", scope: .directory(path: Fixture.siblingPath)),
        ]

        let visible = QuickCommandNormalizer.visibleCommands(commands, inWorkingDirectory: Fixture.nestedPath)

        XCTAssertEqual(visible.map(\.id), ["global", "scoped"])
    }

    // MARK: - Dispatch routing

    func testInsertOnlyDispatchWritesTextWithoutAnyNewline() {
        var sent: [String] = []
        let result = TerminalCommandDispatcher.execute(
            quickCommand: makeCommand(text: "git fetch\ngit status", appendEnter: false),
            approval: QuickCommandApproval(isUserInitiated: true),
            handlers: QuickCommandDispatchHandlers(sendText: { sent.append($0) })
        )

        XCTAssertEqual(result, .insertedText("git fetch; git status"))
        XCTAssertEqual(sent, ["git fetch; git status"])
        XCTAssertFalse(sent[0].contains("\n"))
        XCTAssertFalse(sent[0].contains("\r"))
    }

    func testExecutingDispatchAppendsExactlyOneEnterSequence() {
        var sent: [String] = []
        let result = TerminalCommandDispatcher.execute(
            quickCommand: makeCommand(appendEnter: true),
            approval: QuickCommandApproval(isUserInitiated: true),
            handlers: QuickCommandDispatchHandlers(sendText: { sent.append($0) })
        )

        XCTAssertEqual(result, .executedText(Fixture.statusCommand + AppConstants.QuickCommands.enterSequence))
        XCTAssertEqual(sent, [Fixture.statusCommand + AppConstants.QuickCommands.enterSequence])
        XCTAssertEqual(sent[0].filter { $0 == "\r" }.count, 1)
    }

    func testExecutingDispatchIsRefusedWithoutUserInitiatedApproval() {
        var sent: [String] = []
        let result = TerminalCommandDispatcher.execute(
            quickCommand: makeCommand(appendEnter: true),
            approval: QuickCommandApproval(isUserInitiated: false),
            handlers: QuickCommandDispatchHandlers(sendText: { sent.append($0) })
        )

        XCTAssertEqual(result, .requiresApproval)
        XCTAssertTrue(sent.isEmpty)
    }

    func testInsertOnlyDispatchStillWorksWithoutUserInitiatedApproval() {
        var sent: [String] = []
        let result = TerminalCommandDispatcher.execute(
            quickCommand: makeCommand(appendEnter: false),
            approval: QuickCommandApproval(isUserInitiated: false),
            handlers: QuickCommandDispatchHandlers(sendText: { sent.append($0) })
        )

        XCTAssertEqual(result, .insertedText(Fixture.statusCommand))
        XCTAssertEqual(sent, [Fixture.statusCommand])
    }

    func testEmptyQuickCommandNeverSendsAnything() {
        var sent: [String] = []
        let result = TerminalCommandDispatcher.execute(
            quickCommand: makeCommand(text: "   \n  ", appendEnter: true),
            approval: QuickCommandApproval(isUserInitiated: true),
            handlers: QuickCommandDispatchHandlers(sendText: { sent.append($0) })
        )

        XCTAssertEqual(result, .emptyCommand)
        XCTAssertTrue(sent.isEmpty)
    }

    func testAgentPromptDispatchInsertsWithoutExecuting() {
        var sent: [String] = []
        let command = QuickCommand(
            id: "agent",
            name: "Review",
            action: .agentPrompt(text: "review\nthis", agent: "claude")
        )

        let result = TerminalCommandDispatcher.execute(
            quickCommand: command,
            approval: QuickCommandApproval(isUserInitiated: true),
            handlers: QuickCommandDispatchHandlers(sendText: { sent.append($0) })
        )

        XCTAssertEqual(result, .insertedText("review this"))
        XCTAssertFalse(sent[0].contains("\r"))
    }

    @MainActor
    func testInvokerRoutesThroughTheDispatcherAndTheInjectedTarget() {
        var sent: [String] = []
        let target = QuickCommandClosureSendTarget(
            workingDirectory: { Fixture.repositoryPath },
            sendText: { sent.append($0) }
        )

        let result = QuickCommandInvoker.invoke(makeCommand(appendEnter: true), target: target)

        XCTAssertEqual(result, .executedText(Fixture.statusCommand + AppConstants.QuickCommands.enterSequence))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(target.quickCommandWorkingDirectory, Fixture.repositoryPath)
    }

    @MainActor
    func testInvokerRefusesNonUserInitiatedExecutionThroughTheTarget() {
        var sent: [String] = []
        let target = QuickCommandClosureSendTarget(sendText: { sent.append($0) })

        let result = QuickCommandInvoker.invoke(
            makeCommand(appendEnter: true),
            target: target,
            approval: QuickCommandApproval(isUserInitiated: false)
        )

        XCTAssertEqual(result, .requiresApproval)
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Source shape: no raw send bypasses the dispatcher

    func testOnlyTheInvokerCallsTheSendTargetAndItGoesThroughTheDispatcher() throws {
        let invokerSource = try sourceFile("Sources/KurottyApp/QuickCommandSurfaces.swift")
        XCTAssertTrue(
            invokerSource.contains("TerminalCommandDispatcher.execute("),
            "quick command invocation must route through the dispatcher"
        )

        let featureSources = [
            "Sources/KurottyApp/QuickCommandsEditorView.swift",
            "Sources/KurottyApp/QuickCommandsEditorWindowController.swift",
            "Sources/KurottyApp/QuickCommandStore.swift",
            "Sources/KurottyApp/QuickCommandNormalizer.swift",
        ]
        for path in featureSources {
            let source = try sourceFile(path)
            XCTAssertFalse(
                source.contains("sendQuickCommandText("),
                "\(path) must not send text to a pane directly"
            )
            XCTAssertFalse(
                source.contains("sendTextToActivePane("),
                "\(path) must not reach a pane behind the dispatcher"
            )
        }
    }

    // MARK: - Store

    @MainActor
    private func makeStore(
        storeURL: URL? = nil,
        seedsWhenFileIsMissing: Bool = false
    ) -> QuickCommandStore {
        QuickCommandStore(
            storeURL: storeURL ?? temporaryStoreURL(),
            saveDebounceSeconds: 0,
            seedsWhenFileIsMissing: seedsWhenFileIsMissing
        )
    }

    private func temporaryStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurotty-quick-command-tests-\(UUID().uuidString)")
            .appendingPathComponent(AppConstants.QuickCommands.storageFileName)
    }

    @MainActor
    func testStoreRoundTripsCommandsThroughDisk() throws {
        let storeURL = temporaryStoreURL()
        let store = makeStore(storeURL: storeURL)
        store.replaceAll([
            makeCommand(id: "a", name: "A", scope: .directory(path: Fixture.repositoryPath), appendEnter: true),
            makeCommand(id: "b", name: "B", text: Fixture.buildCommand),
        ])
        store.saveImmediately()

        let reloaded = makeStore(storeURL: storeURL)
        XCTAssertEqual(reloaded.commands.map(\.id), ["a", "b"])
        XCTAssertEqual(reloaded.commands[0].scope, .directory(path: Fixture.repositoryPath))
        XCTAssertTrue(reloaded.commands[0].executesOnDispatch)
        XCTAssertEqual(reloaded.commands[1].bodyText, Fixture.buildCommand)

        let data = try Data(contentsOf: storeURL)
        let document = try JSONDecoder().decode(QuickCommandsDocument.self, from: data)
        XCTAssertEqual(document.version, AppConstants.QuickCommands.storageSchemaVersion)
        XCTAssertEqual(document.commands.count, 2)
    }

    @MainActor
    func testStoreCapsPersistedCommandCount() {
        let store = makeStore()
        let overflowCount = AppConstants.QuickCommands.maximumCommandCount + 5

        store.replaceAll((0..<overflowCount).map { makeCommand(id: "c\($0)") })

        XCTAssertEqual(store.commandCount, AppConstants.QuickCommands.maximumCommandCount)
    }

    @MainActor
    func testStoreWritesAtomicallyToItsOwnApplicationSupportFile() throws {
        let storeURL = temporaryStoreURL()
        let store = makeStore(storeURL: storeURL)

        store.apply(.upsert(makeCommand()))
        store.saveImmediately()

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        let source = try sourceFile("Sources/KurottyApp/QuickCommandStore.swift")
        XCTAssertTrue(source.contains("options: .atomic"))
        XCTAssertTrue(source.contains("persistenceQueue.async"))
    }

    @MainActor
    func testStoreSeedsStarterCommandsOnlyWhenTheFileIsMissing() throws {
        let storeURL = temporaryStoreURL()
        let seeded = QuickCommandStore(
            storeURL: storeURL,
            saveDebounceSeconds: 0,
            seedsWhenFileIsMissing: true
        )

        let seeds = seeded.commands
        XCTAssertEqual(seeds.count, QuickCommandSeeds.starterCommands().count)
        XCTAssertTrue(
            seeds.allSatisfy { !$0.executesOnDispatch },
            "seeded commands must be insert-only"
        )
        seeded.saveImmediately()

        let reopened = QuickCommandStore(
            storeURL: storeURL,
            saveDebounceSeconds: 0,
            seedsWhenFileIsMissing: true
        )
        reopened.replaceAll([])
        reopened.saveImmediately()

        let afterUserClearedTheList = QuickCommandStore(
            storeURL: storeURL,
            saveDebounceSeconds: 0,
            seedsWhenFileIsMissing: true
        )
        XCTAssertTrue(
            afterUserClearedTheList.commands.isEmpty,
            "an existing file must never be re-seeded"
        )
    }

    @MainActor
    func testStoreFiltersByWorkingDirectory() {
        let store = makeStore()
        store.replaceAll([
            makeCommand(id: "global", name: "Global"),
            makeCommand(id: "scoped", name: "Scoped", scope: .directory(path: Fixture.siblingPath)),
        ])

        XCTAssertEqual(store.commands(forWorkingDirectory: Fixture.repositoryPath).map(\.id), ["global"])
        XCTAssertEqual(
            store.commands(forWorkingDirectory: Fixture.siblingPath).map(\.id).sorted(),
            ["global", "scoped"]
        )
    }

    // MARK: - Registry and palette registration

    func testRegistryRegistersQuickCommandsFilteredByWorkingDirectory() {
        let registry = TerminalCommandRegistry.default.registering(
            quickCommands: [
                makeCommand(id: "global", name: "Global Status"),
                makeCommand(id: "scoped", name: "Scoped Build", scope: .directory(path: Fixture.repositoryPath)),
                makeCommand(id: "other", name: "Other", scope: .directory(path: Fixture.siblingPath)),
            ],
            workingDirectory: Fixture.nestedPath
        )

        XCTAssertEqual(registry.quickCommands.map(\.quickCommand.id), ["global", "scoped"])
        XCTAssertEqual(registry.quickCommand(for: "scoped")?.name, "Scoped Build")
        XCTAssertNil(registry.quickCommand(for: "other"))
        XCTAssertFalse(registry.windowCommands.isEmpty, "registering must not disturb window commands")
    }

    func testPaletteExposesQuickCommandEntriesWithScopeAndSafetySubtitles() {
        let registry = TerminalCommandRegistry.default.registering(
            quickCommands: [
                makeCommand(id: "insert", name: "Git Status"),
                makeCommand(id: "run", name: "Run Build", text: Fixture.buildCommand, appendEnter: true),
            ],
            workingDirectory: nil
        )
        let palette = TerminalCommandPalette(registry: registry)

        XCTAssertEqual(palette.quickCommandEntries.map(\.title), ["Git Status", "Run Build"])
        XCTAssertEqual(
            palette.quickCommandEntries.map(\.id),
            [
                AppConstants.QuickCommands.paletteIdentifierPrefix + "insert",
                AppConstants.QuickCommands.paletteIdentifierPrefix + "run",
            ]
        )
        XCTAssertFalse(palette.quickCommandEntries[0].executesOnDispatch)
        XCTAssertTrue(palette.quickCommandEntries[1].executesOnDispatch)
        XCTAssertTrue(palette.quickCommandEntries[0].subtitle.contains(AppLocalization.string(.quickCommandInsertsOnly, language: .english)))
        XCTAssertTrue(palette.quickCommandEntries[1].subtitle.contains(AppLocalization.string(.quickCommandRunsImmediately, language: .english)))
    }

    func testPaletteSearchMatchesQuickCommandNamesAndBodies() {
        let registry = TerminalCommandRegistry.default.registering(
            quickCommands: [
                makeCommand(id: "status", name: "Git Status"),
                makeCommand(id: "build", name: "Build", text: Fixture.buildCommand),
            ],
            workingDirectory: nil
        )
        let palette = TerminalCommandPalette(registry: registry)

        XCTAssertEqual(palette.quickCommandResults(for: "git").map(\.quickCommand.id), ["status"])
        XCTAssertEqual(palette.quickCommandResults(for: "swift").map(\.quickCommand.id), ["build"])
        XCTAssertEqual(palette.quickCommandResults(for: "").count, 2)
        XCTAssertTrue(palette.quickCommandResults(for: "zzzz").isEmpty)
    }

    func testDefaultRegistryHasNoQuickCommandsUntilRegistered() {
        XCTAssertTrue(TerminalCommandRegistry.default.quickCommands.isEmpty)
        XCTAssertTrue(TerminalCommandPalette(registry: .default).quickCommandEntries.isEmpty)
    }

    // MARK: - Context menu

    func testContextMenuLayoutAppendsQuickCommandsForTheActiveDirectory() {
        let layout = TerminalContextMenuBuilder.layout(
            for: TerminalContextMenuState(hasSelection: false, hasPasteboardText: true),
            quickCommands: [
                makeCommand(id: "global", name: "Git Status"),
                makeCommand(id: "scoped", name: "Scoped", scope: .directory(path: Fixture.siblingPath)),
            ],
            workingDirectory: Fixture.repositoryPath
        )

        XCTAssertEqual(
            layout.entries,
            TerminalContextMenuBuilder.entries(
                for: TerminalContextMenuState(hasSelection: false, hasPasteboardText: true)
            ),
            "the existing flat entries must be unchanged"
        )
        XCTAssertEqual(layout.quickCommandSubmenu?.items.map(\.quickCommandID), ["global"])
        XCTAssertEqual(
            layout.quickCommandSubmenu?.title,
            AppLocalization.string(.quickCommandsMenuTitle, language: .english)
        )
    }

    func testContextMenuOmitsTheSubmenuWhenNothingIsVisibleOrComplete() {
        let empty = TerminalContextMenuBuilder.layout(
            for: TerminalContextMenuState(hasSelection: false, hasPasteboardText: false),
            quickCommands: [],
            workingDirectory: Fixture.repositoryPath
        )
        XCTAssertNil(empty.quickCommandSubmenu)

        let incompleteOnly = TerminalContextMenuBuilder.layout(
            for: TerminalContextMenuState(hasSelection: false, hasPasteboardText: false),
            quickCommands: [makeCommand(id: "blank", name: "", text: "")],
            workingDirectory: Fixture.repositoryPath
        )
        XCTAssertNil(incompleteOnly.quickCommandSubmenu)
    }

    @MainActor
    func testContextSubmenuMenuItemsCarryTheQuickCommandIdentifier() throws {
        let submenu = try XCTUnwrap(
            QuickCommandContextMenuBuilder.submenu(
                for: [makeCommand(id: "global", name: "Git Status")],
                workingDirectory: nil
            )
        )

        let menu = QuickCommandContextMenuBuilder.makeMenu(
            for: submenu,
            target: nil,
            action: #selector(NSMenuItem.description)
        )

        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(menu.items[0].title, "Git Status")
        XCTAssertEqual(menu.items[0].representedObject as? String, "global")
    }

    // MARK: - Presentation

    func testPresentationFallsBackToBodyThenPlaceholderForUnnamedCommands() {
        XCTAssertEqual(
            QuickCommandPresentation.title(for: makeCommand(name: "  ")),
            Fixture.statusCommand
        )
        XCTAssertEqual(
            QuickCommandPresentation.title(for: makeCommand(name: "", text: "")),
            AppLocalization.string(.quickCommandUntitled, language: .english)
        )
    }

    func testScopeDescriptionNamesTheDirectory() {
        let description = QuickCommandPresentation.scopeDescription(
            for: .directory(path: Fixture.repositoryPath),
            language: .english
        )

        XCTAssertTrue(description.contains("kurotty"))
    }
}

private func sourceFile(_ relativePath: String) throws -> String {
    try String(
        contentsOf: sourceRoot().appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

private func sourceRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        url.deleteLastPathComponent()
    }
    return url
}
