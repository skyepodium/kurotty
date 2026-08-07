import KurottyCore
import XCTest
@testable import KurottyApp

/// Agent activity status: OSC 9999 parsing, the bounded registry, the opt-in
/// Claude Code hook settings merge, and the loopback hook admission rules.
///
/// The hook tests operate on a temporary directory only. The real
/// `~/.claude/settings.json` is never read or written here.
final class AgentActivityStatusTests: XCTestCase {
    private enum Fixture {
        static let bell = "\u{07}"
        static let escape = "\u{1B}"
        static let oscPrefix = "\u{1B}]9999;"
        static let stringTerminator = "\u{1B}\\"
        static let paneIdentifier = "pane-A"
        static let otherPaneIdentifier = "pane-B"
        static let token = "0123456789abcdef"
        static let workingPayload = #"{"state":"working","agent":"claude","detail":"running tests"}"#
        static let donePayload = #"{"state":"done","agent":"claude"}"#
    }

    // MARK: - OSC parser

    func testParsesWorkingSequenceAndStripsItFromVisibleText() {
        var parser = AgentStatusOSCParser()
        let chunk = "before" + Fixture.oscPrefix + Fixture.workingPayload + Fixture.bell + "after"

        let result = parser.parse(chunk: chunk)

        XCTAssertEqual(result.passthroughText, "beforeafter")
        XCTAssertEqual(result.statuses.count, 1)
        XCTAssertEqual(result.statuses.first?.state, .working)
        XCTAssertEqual(result.statuses.first?.agentName, "claude")
        XCTAssertEqual(result.statuses.first?.detail, "running tests")
    }

    func testParsesStringTerminatorVariant() {
        var parser = AgentStatusOSCParser()

        let result = parser.parse(
            chunk: "x" + Fixture.oscPrefix + Fixture.donePayload + Fixture.stringTerminator + "y"
        )

        XCTAssertEqual(result.passthroughText, "xy")
        XCTAssertEqual(result.statuses.map(\.state), [.done])
    }

    func testParsesSequenceSplitAcrossManyChunks() {
        var parser = AgentStatusOSCParser()
        let whole = "head" + Fixture.oscPrefix + Fixture.workingPayload + Fixture.bell + "tail"
        var passthrough = ""
        var statuses: [AgentActivityStatus] = []

        // One scalar per chunk is the worst realistic PTY fragmentation.
        for scalar in whole.unicodeScalars {
            let result = parser.parse(chunk: String(String.UnicodeScalarView([scalar])))
            passthrough += result.passthroughText
            statuses.append(contentsOf: result.statuses)
        }

        XCTAssertEqual(passthrough, "headtail")
        XCTAssertEqual(statuses.map(\.state), [.working])
    }

    func testSplitAcrossTwoChunksAtEveryBoundaryNeverLeaksSequenceBytes() {
        let whole = "A" + Fixture.oscPrefix + Fixture.donePayload + Fixture.bell + "B"
        let scalars = Array(whole.unicodeScalars)

        for splitIndex in 0...scalars.count {
            var parser = AgentStatusOSCParser()
            let first = String(String.UnicodeScalarView(scalars[0..<splitIndex]))
            let second = String(String.UnicodeScalarView(scalars[splitIndex...]))
            let firstResult = parser.parse(chunk: first)
            let secondResult = parser.parse(chunk: second)
            let passthrough = firstResult.passthroughText + secondResult.passthroughText
            let statuses = firstResult.statuses + secondResult.statuses

            XCTAssertEqual(passthrough, "AB", "leaked sequence text at split \(splitIndex)")
            XCTAssertEqual(statuses.map(\.state), [.done], "lost status at split \(splitIndex)")
        }
    }

    func testUnrelatedEscapeSequencesPassThroughUntouched() {
        var parser = AgentStatusOSCParser()

        let first = parser.parse(chunk: "\(Fixture.escape)[1;31mred\(Fixture.escape)[0m")
        // A lone trailing ESC is genuinely ambiguous and waits exactly one chunk.
        let second = parser.parse(chunk: "\(Fixture.escape)")
        let third = parser.parse(chunk: "[2J")

        XCTAssertEqual(first.passthroughText, "\(Fixture.escape)[1;31mred\(Fixture.escape)[0m")
        XCTAssertTrue(first.statuses.isEmpty)
        XCTAssertEqual(second.passthroughText, "")
        XCTAssertEqual(third.passthroughText, "\(Fixture.escape)[2J")
    }

    func testMalformedJSONIsStrippedAndProducesNoStatus() {
        var parser = AgentStatusOSCParser()

        let result = parser.parse(chunk: "a" + Fixture.oscPrefix + "{not json" + Fixture.bell + "b")

        XCTAssertEqual(result.passthroughText, "ab")
        XCTAssertTrue(result.statuses.isEmpty)
    }

    func testUnknownStateValueIsIgnoredButStillStripped() {
        var parser = AgentStatusOSCParser()

        let result = parser.parse(
            chunk: "a" + Fixture.oscPrefix + #"{"state":"pondering"}"# + Fixture.bell + "b"
        )

        XCTAssertEqual(result.passthroughText, "ab")
        XCTAssertTrue(result.statuses.isEmpty)
    }

    func testEmptyPayloadIsIgnored() {
        var parser = AgentStatusOSCParser()

        let result = parser.parse(chunk: Fixture.oscPrefix + Fixture.bell + "visible")

        XCTAssertEqual(result.passthroughText, "visible")
        XCTAssertTrue(result.statuses.isEmpty)
    }

    func testOversizedUnterminatedPayloadOverflowsAndRecovers() {
        var parser = AgentStatusOSCParser()
        let oversizedCharacterCount = AppConstants.AgentStatus.maximumSequenceBytes + 512
        let flood = String(repeating: "x", count: oversizedCharacterCount)

        let overflow = parser.parse(chunk: Fixture.oscPrefix + flood)

        XCTAssertEqual(overflow.passthroughText, "", "overflowed sequence bytes must not render")
        XCTAssertTrue(overflow.statuses.isEmpty)

        // Bytes up to the next terminator are discarded, then parsing resumes.
        let recovery = parser.parse(chunk: "more garbage" + Fixture.bell + "visible")

        XCTAssertEqual(recovery.passthroughText, "visible")
        XCTAssertFalse(parser.hasPendingCarryForTesting)

        let afterRecovery = parser.parse(chunk: Fixture.oscPrefix + Fixture.donePayload + Fixture.bell + "ok")

        XCTAssertEqual(afterRecovery.passthroughText, "ok")
        XCTAssertEqual(afterRecovery.statuses.map(\.state), [.done])
    }

    func testTwoSequencesInOneChunk() {
        var parser = AgentStatusOSCParser()

        let result = parser.parse(
            chunk: Fixture.oscPrefix + Fixture.workingPayload + Fixture.bell
                + "middle"
                + Fixture.oscPrefix + Fixture.donePayload + Fixture.stringTerminator
        )

        XCTAssertEqual(result.passthroughText, "middle")
        XCTAssertEqual(result.statuses.map(\.state), [.working, .done])
    }

    func testAgentAndDetailAreLengthCapped() {
        var parser = AgentStatusOSCParser()
        let longDetail = String(repeating: "d", count: AppConstants.AgentStatus.maximumDetailCharacters + 50)
        let longAgent = String(repeating: "a", count: AppConstants.AgentStatus.maximumAgentNameCharacters + 50)
        let payload = #"{"state":"working","agent":""# + longAgent + #"","detail":""# + longDetail + #""}"#

        let result = parser.parse(chunk: Fixture.oscPrefix + payload + Fixture.bell)

        XCTAssertEqual(result.statuses.first?.agentName?.count, AppConstants.AgentStatus.maximumAgentNameCharacters)
        XCTAssertEqual(result.statuses.first?.detail?.count, AppConstants.AgentStatus.maximumDetailCharacters)
    }

    func testResetDropsPendingCarry() {
        var parser = AgentStatusOSCParser()
        _ = parser.parse(chunk: Fixture.oscPrefix + #"{"state":"work"#)
        XCTAssertTrue(parser.hasPendingCarryForTesting)

        parser.reset()

        XCTAssertFalse(parser.hasPendingCarryForTesting)
    }

    // MARK: - Registry

    @MainActor
    func testRegistryPublishesAndResolvesLatestStatus() {
        let registry = AgentActivityRegistry()

        registry.record(AgentActivityStatus(state: .working), paneIdentifier: Fixture.paneIdentifier)
        registry.record(AgentActivityStatus(state: .waitingForInput), paneIdentifier: Fixture.paneIdentifier)

        XCTAssertEqual(registry.status(for: Fixture.paneIdentifier)?.state, .waitingForInput)
        XCTAssertNil(registry.status(for: Fixture.otherPaneIdentifier))
    }

    @MainActor
    func testRegistryCapsHistoryPerPane() {
        let registry = AgentActivityRegistry()
        let overflowCount = AppConstants.AgentStatus.maximumHistoryCountPerPane + 15
        let states: [AgentActivityState] = [.working, .waitingForInput, .blocked, .done]

        for index in 0..<overflowCount {
            registry.record(
                AgentActivityStatus(state: states[index % states.count], detail: "step \(index)"),
                paneIdentifier: Fixture.paneIdentifier
            )
        }

        let history = registry.history(for: Fixture.paneIdentifier)
        XCTAssertEqual(history.count, AppConstants.AgentStatus.maximumHistoryCountPerPane)
        XCTAssertEqual(history.last?.detail, "step \(overflowCount - 1)")
    }

    @MainActor
    func testRegistryCollapsesRepeatedIdenticalStatusInsteadOfGrowing() {
        let registry = AgentActivityRegistry()

        for _ in 0..<10 {
            registry.record(
                AgentActivityStatus(state: .working, agentName: "claude"),
                paneIdentifier: Fixture.paneIdentifier
            )
        }

        XCTAssertEqual(registry.history(for: Fixture.paneIdentifier).count, 1)
    }

    @MainActor
    func testRegistryCapsTrackedPaneCount() {
        let registry = AgentActivityRegistry()
        let paneCount = AppConstants.AgentStatus.maximumTrackedPaneCount + 10
        let base = Date(timeIntervalSince1970: 1_000_000)

        for index in 0..<paneCount {
            registry.record(
                AgentActivityStatus(state: .working, updatedAt: base.addingTimeInterval(TimeInterval(index))),
                paneIdentifier: "pane-\(index)"
            )
        }

        XCTAssertEqual(
            registry.trackedPaneIdentifiers.count,
            AppConstants.AgentStatus.maximumTrackedPaneCount
        )
        // Oldest evicted, newest retained.
        XCTAssertNil(registry.status(for: "pane-0", now: base.addingTimeInterval(TimeInterval(paneCount))))
        XCTAssertNotNil(
            registry.status(for: "pane-\(paneCount - 1)", now: base.addingTimeInterval(TimeInterval(paneCount)))
        )
    }

    @MainActor
    func testRegistryPostsNotificationWithPaneIdentifier() {
        let registry = AgentActivityRegistry()
        let expectation = expectation(forNotification: AgentActivityRegistry.didChangeNotification, object: registry) {
            notification in
            notification.userInfo?[AgentActivityRegistry.paneIdentifierNotificationKey] as? String
                == Fixture.paneIdentifier
        }

        registry.record(AgentActivityStatus(state: .done), paneIdentifier: Fixture.paneIdentifier)

        wait(for: [expectation], timeout: 1)
    }

    @MainActor
    func testRemovePaneDropsEverything() {
        let registry = AgentActivityRegistry()
        registry.record(AgentActivityStatus(state: .working), paneIdentifier: Fixture.paneIdentifier)

        registry.removePane(Fixture.paneIdentifier)

        XCTAssertTrue(registry.history(for: Fixture.paneIdentifier).isEmpty)
        XCTAssertNil(registry.status(for: Fixture.paneIdentifier))
    }

    // MARK: - Staleness

    func testWorkingStatusDecaysAfterItsWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let stamped = now.addingTimeInterval(-AppConstants.AgentStatus.workingStaleAfterSeconds - 1)
        let status = AgentActivityStatus(state: .working, updatedAt: stamped)

        XCTAssertTrue(AgentActivityStalenessPolicy.isStale(status, now: now))
        XCTAssertNil(AgentActivityStalenessPolicy.resolved(status, now: now))
    }

    func testFreshWorkingStatusSurvives() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let status = AgentActivityStatus(
            state: .working,
            updatedAt: now.addingTimeInterval(-AppConstants.AgentStatus.workingStaleAfterSeconds + 1)
        )

        XCTAssertFalse(AgentActivityStalenessPolicy.isStale(status, now: now))
        XCTAssertEqual(AgentActivityStalenessPolicy.resolved(status, now: now)?.state, .working)
    }

    func testStatusStampedInTheFutureIsNotStale() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let status = AgentActivityStatus(state: .working, updatedAt: now.addingTimeInterval(60))

        XCTAssertFalse(AgentActivityStalenessPolicy.isStale(status, now: now))
    }

    @MainActor
    func testRegistryResolvesStaleWorkingStatusAsCleared() {
        let registry = AgentActivityRegistry()
        let now = Date(timeIntervalSince1970: 3_000_000)
        registry.record(
            AgentActivityStatus(
                state: .working,
                updatedAt: now.addingTimeInterval(-AppConstants.AgentStatus.workingStaleAfterSeconds - 10)
            ),
            paneIdentifier: Fixture.paneIdentifier
        )

        XCTAssertNil(registry.status(for: Fixture.paneIdentifier, now: now))
        XCTAssertEqual(registry.pruneStale(now: now), [Fixture.paneIdentifier])
        XCTAssertTrue(registry.history(for: Fixture.paneIdentifier).isEmpty)
    }

    // MARK: - Hook setting default and consent

    func testHookSettingDefaultsToOnWhileConsentStartsUnasked() {
        // The default says the user wants status hooks. It is not permission to
        // edit their Claude Code configuration; that answer lives in consent.
        XCTAssertTrue(AppConstants.AgentStatus.hooksEnabledDefault)
        XCTAssertTrue(AgentStatusHookSettings.defaultValue)
        XCTAssertTrue(AgentStatusHookSettings.isEnabled())
        XCTAssertFalse(AgentStatusHookSettings.isEnabled(decodedSettingValue: false))
        XCTAssertEqual(AgentStatusHookSettings.settingsKeyPath, "terminal.agentStatusHooksEnabled")
        XCTAssertEqual(AgentStatusHookConsent.default, .unasked)
    }

    func testConsentPolicyOnlyInstallsWithAnAnswerOrAnExistingInstall() {
        // A fresh install: the setting is on, nothing has been asked.
        XCTAssertEqual(
            AgentStatusHookConsentPolicy.decision(
                isEnabled: true,
                consent: .unasked,
                hasExistingManagedEntries: false
            ),
            .askBeforeInstalling
        )
        XCTAssertEqual(
            AgentStatusHookConsentPolicy.decision(
                isEnabled: true,
                consent: .granted,
                hasExistingManagedEntries: false
            ),
            .install
        )
        XCTAssertEqual(
            AgentStatusHookConsentPolicy.decision(
                isEnabled: true,
                consent: .denied,
                hasExistingManagedEntries: false
            ),
            .leaveConfigurationAlone
        )
        // A refusal silences launch forever, but the Preferences checkbox must
        // not become a switch that does nothing when it is turned back on.
        XCTAssertEqual(
            AgentStatusHookConsentPolicy.decision(
                isEnabled: true,
                consent: .denied,
                hasExistingManagedEntries: false,
                isExplicitUserRequest: true
            ),
            .askBeforeInstalling
        )
        // Already installed from before consent existed: re-asking would be a
        // question about a decision the user already made.
        XCTAssertEqual(
            AgentStatusHookConsentPolicy.decision(
                isEnabled: true,
                consent: .unasked,
                hasExistingManagedEntries: true
            ),
            .install
        )
        XCTAssertEqual(
            AgentStatusHookConsentPolicy.decision(
                isEnabled: false,
                consent: .granted,
                hasExistingManagedEntries: true
            ),
            .leaveConfigurationAlone
        )
    }

    @MainActor
    func testCoordinatorInjectsNoEnvironmentWhileDisabled() throws {
        // Unobserved and pointed at a temporary home like every other
        // coordinator here: an instance that lived on and reacted to a real
        // settings change would install into the user's own `~/.claude`.
        let home = try makeTemporaryHome(agents: [])
        defer { try? FileManager.default.removeItem(at: home) }
        let coordinator = AgentStatusHookCoordinator(
            server: AgentStatusHookServer(token: Fixture.token),
            observesSettingsChanges: false,
            consentStore: Self.recordingConsentStore(initial: .granted).store,
            requestConsent: { _ in XCTFail("nothing may be asked while hooks are off"); return false },
            homeDirectory: home
        )

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertTrue(coordinator.shellEnvironment(paneIdentifier: Fixture.paneIdentifier).isEmpty)
    }

    /// The whole point of the consent gate: turning hooks on for the first time
    /// must not touch the user's file before they answer.
    @MainActor
    func testFirstEnableAsksAndWritesNothingWhenTheUserDeclines() throws {
        let home = try makeTemporaryHome(agents: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }
        let settingsFileURL = configurationURL(for: .claudeCode, in: home)
        let original = Data(#"{"model":"opus"}"#.utf8)
        try original.write(to: settingsFileURL)

        let consent = Self.recordingConsentStore(initial: .unasked)
        var asked: [AgentStatusHookTarget] = []
        let coordinator = AgentStatusHookCoordinator(
            server: AgentStatusHookServer(token: Fixture.token),
            observesSettingsChanges: false,
            consentStore: consent.store,
            requestConsent: { target in
                asked.append(target)
                return false
            },
            homeDirectory: home
        )

        coordinator.setEnabled(true)

        XCTAssertEqual(asked, [.claudeCode])
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertEqual(try Data(contentsOf: settingsFileURL), original, "a refusal must leave the file byte-identical")
        XCTAssertEqual(consent.recorded(), [.claudeCode: .denied])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: settingsFileURL.path + ".kurotty-backup"),
            "no write means no backup either"
        )
        XCTAssertEqual(
            consent.disableCount(),
            1,
            "every agent on this machine refused, so the visible checkbox must go off"
        )
    }

    @MainActor
    func testAGrantedAnswerInstallsAndIsNeverAskedAgain() throws {
        let home = try makeTemporaryHome(agents: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }
        let settingsFileURL = configurationURL(for: .claudeCode, in: home)
        try Data(#"{"model":"opus"}"#.utf8).write(to: settingsFileURL)

        let consent = Self.recordingConsentStore(initial: .unasked)
        var askCount = 0
        let coordinator = AgentStatusHookCoordinator(
            server: AgentStatusHookServer(token: Fixture.token),
            observesSettingsChanges: false,
            consentStore: consent.store,
            requestConsent: { _ in
                askCount += 1
                return true
            },
            homeDirectory: home
        )

        coordinator.setEnabled(true)

        XCTAssertEqual(askCount, 1)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(consent.recorded(), [.claudeCode: .granted])
        XCTAssertTrue(AgentStatusHookInstaller.containsKurottyEntries(try readJSONObject(at: settingsFileURL)))

        // A second pass over the same state must not re-ask.
        coordinator.setEnabled(false)
        coordinator.setEnabled(true)
        XCTAssertEqual(askCount, 1)
        XCTAssertTrue(coordinator.isEnabled)
    }

    /// A user who enabled hooks before consent existed is already installed, so
    /// the upgrade must not interrogate them.
    @MainActor
    func testAnAlreadyInstalledFileIsRefreshedWithoutAsking() throws {
        let home = try makeTemporaryHome(agents: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }
        let settingsFileURL = configurationURL(for: .claudeCode, in: home)
        XCTAssertNoThrow(try assertSuccess(AgentStatusHookInstaller.install(at: settingsFileURL)))

        let consent = Self.recordingConsentStore(initial: .unasked)
        let coordinator = AgentStatusHookCoordinator(
            server: AgentStatusHookServer(token: Fixture.token),
            observesSettingsChanges: false,
            consentStore: consent.store,
            requestConsent: { _ in
                XCTFail("an existing install must not re-ask")
                return false
            },
            homeDirectory: home
        )

        coordinator.setEnabled(true)

        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertTrue(consent.recorded().isEmpty)
        XCTAssertTrue(AgentStatusHookInstaller.containsKurottyEntries(try readJSONObject(at: settingsFileURL)))
    }

    /// Every later launch stays silent after a refusal — no prompt, no write.
    @MainActor
    func testADeniedRecordKeepsEveryLaterLaunchSilent() throws {
        let home = try makeTemporaryHome(agents: [.claudeCode, .codex])
        defer { try? FileManager.default.removeItem(at: home) }
        let settingsFileURL = configurationURL(for: .claudeCode, in: home)
        let original = Data(#"{"model":"opus"}"#.utf8)
        try original.write(to: settingsFileURL)

        let consent = Self.recordingConsentStore(initial: .denied)
        let coordinator = AgentStatusHookCoordinator(
            server: AgentStatusHookServer(token: Fixture.token),
            observesSettingsChanges: false,
            consentStore: consent.store,
            requestConsent: { _ in
                XCTFail("a refusal must not be re-litigated at launch")
                return false
            },
            homeDirectory: home
        )

        coordinator.setEnabled(true, isExplicitUserRequest: false)

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertTrue(coordinator.shellEnvironment(paneIdentifier: Fixture.paneIdentifier).isEmpty)
        XCTAssertEqual(try Data(contentsOf: settingsFileURL), original)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: configurationURL(for: .codex, in: home).path),
            "a silent launch must not create a Codex hooks file either"
        )
        XCTAssertEqual(consent.disableCount(), 0, "nothing was asked, so nothing changed the visible setting")
    }

    /// Turning the setting back on after a refusal is a new request, not a
    /// replay of the old answer, so it asks rather than silently doing nothing.
    @MainActor
    func testTurningHooksBackOnAfterARefusalAsksAgain() throws {
        let home = try makeTemporaryHome(agents: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }
        let settingsFileURL = configurationURL(for: .claudeCode, in: home)
        try Data(#"{"model":"opus"}"#.utf8).write(to: settingsFileURL)

        let consent = Self.recordingConsentStore(initial: .denied)
        var askCount = 0
        let coordinator = AgentStatusHookCoordinator(
            server: AgentStatusHookServer(token: Fixture.token),
            observesSettingsChanges: false,
            consentStore: consent.store,
            requestConsent: { _ in
                askCount += 1
                return true
            },
            homeDirectory: home
        )

        coordinator.setEnabled(true, isExplicitUserRequest: true)

        XCTAssertEqual(askCount, 1)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(consent.recorded(), [.claudeCode: .granted])
        XCTAssertTrue(AgentStatusHookInstaller.containsKurottyEntries(try readJSONObject(at: settingsFileURL)))
    }

    // MARK: - Per-agent consent and Codex

    /// A machine without `~/.codex` is a machine without Codex. Kurotty must not
    /// create the directory and must not raise a prompt about a program the user
    /// does not run.
    @MainActor
    func testCodexIsNeverAskedAboutOrCreatedWhenItIsNotInstalled() throws {
        let home = try makeTemporaryHome(agents: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }

        let consent = Self.recordingConsentStore(initial: .unasked)
        var asked: [AgentStatusHookTarget] = []
        let coordinator = AgentStatusHookCoordinator(
            server: AgentStatusHookServer(token: Fixture.token),
            observesSettingsChanges: false,
            consentStore: consent.store,
            requestConsent: { target in
                asked.append(target)
                return true
            },
            homeDirectory: home
        )

        coordinator.setEnabled(true)

        XCTAssertEqual(asked, [.claudeCode])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(
                    AppConstants.AgentStatus.codexConfigurationDirectoryRelativePath
                ).path
            ),
            "Kurotty must not plant a configuration directory for an agent that is not installed"
        )
    }

    /// One answer per agent: the prompt names the file, so a yes about Claude
    /// Code's settings is not a yes about Codex's hooks.
    @MainActor
    func testConsentIsRecordedPerAgentAndARefusalOfOneLeavesTheOtherInstalled() throws {
        let home = try makeTemporaryHome(agents: [.claudeCode, .codex])
        defer { try? FileManager.default.removeItem(at: home) }
        let codexFileURL = configurationURL(for: .codex, in: home)
        let codexOriginal = Data(#"{"hooks":{}}"#.utf8)
        try codexOriginal.write(to: codexFileURL)

        let consent = Self.recordingConsentStore(initial: .unasked)
        let coordinator = AgentStatusHookCoordinator(
            server: AgentStatusHookServer(token: Fixture.token),
            observesSettingsChanges: false,
            consentStore: consent.store,
            requestConsent: { $0 == .claudeCode },
            homeDirectory: home
        )

        coordinator.setEnabled(true)

        XCTAssertEqual(consent.recorded(), [.claudeCode: .granted, .codex: .denied])
        XCTAssertTrue(coordinator.isEnabled, "one granted agent is enough to run the listener")
        XCTAssertTrue(AgentStatusHookInstaller.containsKurottyEntries(
            try readJSONObject(at: configurationURL(for: .claudeCode, in: home))
        ))
        XCTAssertEqual(try Data(contentsOf: codexFileURL), codexOriginal, "the refused agent's file is untouched")
        XCTAssertEqual(
            consent.disableCount(),
            0,
            "refusing one agent while another is installed must not kill the visible setting"
        )
    }

    @MainActor
    func testBothAgentsInstallWhenBothConsentAndBothComeBackOutOnDisable() throws {
        let home = try makeTemporaryHome(agents: [.claudeCode, .codex])
        defer { try? FileManager.default.removeItem(at: home) }

        let consent = Self.recordingConsentStore(initial: .granted)
        let coordinator = AgentStatusHookCoordinator(
            server: AgentStatusHookServer(token: Fixture.token),
            observesSettingsChanges: false,
            consentStore: consent.store,
            requestConsent: { _ in
                XCTFail("consent is already on record for both agents")
                return false
            },
            homeDirectory: home
        )

        coordinator.setEnabled(true)

        for target in AgentStatusHookTarget.allCases {
            XCTAssertTrue(
                AgentStatusHookInstaller.containsKurottyEntries(
                    try readJSONObject(at: configurationURL(for: target, in: home))
                ),
                "missing entries for \(target.rawValue)"
            )
        }

        coordinator.setEnabled(false)

        for target in AgentStatusHookTarget.allCases {
            XCTAssertFalse(
                AgentStatusHookInstaller.containsKurottyEntries(
                    try readJSONObject(at: configurationURL(for: target, in: home))
                ),
                "entries left behind for \(target.rawValue)"
            )
        }
    }

    /// `~/.codex/hooks.json` is commonly owned by third-party tooling. Installing
    /// beside it must keep every foreign entry, and uninstalling must take back
    /// only what Kurotty wrote.
    func testCodexInstallAndUninstallRoundTripPreservesAForeignHookEntry() throws {
        let home = try makeTemporaryHome(agents: [.codex])
        defer { try? FileManager.default.removeItem(at: home) }
        let fileURL = configurationURL(for: .codex, in: home)
        let foreignCommand = "node /opt/homebrew/lib/node_modules/oh-my-codex/dist/scripts/codex-native-hook.js"
        let original: [String: Any] = [
            "description": "oh-my-codex",
            "hooks": [
                "SessionStart": [
                    ["matcher": "startup|resume|clear", "hooks": [["type": "command", "command": foreignCommand]]],
                ],
                "Stop": [
                    ["hooks": [["type": "command", "command": foreignCommand]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: fileURL)

        XCTAssertNoThrow(try assertSuccess(AgentStatusHookInstaller.install(for: .codex, at: fileURL)))

        let installed = try readJSONObject(at: fileURL)
        XCTAssertEqual(installed["description"] as? String, "oh-my-codex")
        XCTAssertTrue(AgentStatusHookInstaller.containsKurottyEntries(installed))
        let installedHooks = try XCTUnwrap(installed["hooks"] as? [String: Any])
        XCTAssertEqual(
            Set(installedHooks.keys),
            ["SessionStart", "UserPromptSubmit", "Stop"],
            "Kurotty adds only the two lifecycle events it can map, and touches no other"
        )
        XCTAssertEqual(hookCommands(in: installedHooks["SessionStart"]), [foreignCommand])
        XCTAssertTrue(hookCommands(in: installedHooks["Stop"]).contains(foreignCommand))
        XCTAssertTrue(hookCommands(in: installedHooks["Stop"]).contains(where: AgentStatusHookInstaller.isManagedCommand))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path + ".kurotty-backup"))

        XCTAssertNoThrow(try assertSuccess(AgentStatusHookInstaller.uninstall(for: .codex, at: fileURL)))

        let uninstalled = try readJSONObject(at: fileURL)
        XCTAssertFalse(AgentStatusHookInstaller.containsKurottyEntries(uninstalled))
        XCTAssertEqual(uninstalled["description"] as? String, "oh-my-codex")
        let remainingHooks = try XCTUnwrap(uninstalled["hooks"] as? [String: Any])
        XCTAssertEqual(Set(remainingHooks.keys), ["SessionStart", "Stop"])
        XCTAssertEqual(hookCommands(in: remainingHooks["Stop"]), [foreignCommand])
    }

    /// The refusal that matters most. A `~/.codex/hooks.json` carrying a
    /// top-level key Codex itself rejects is not Kurotty's to repair, and it is
    /// certainly not Kurotty's to overwrite: the bytes must come back identical.
    func testACodexConfigWithAnUnrecognizedTopLevelKeyIsReportedAndLeftUntouched() throws {
        let home = try makeTemporaryHome(agents: [.codex])
        defer { try? FileManager.default.removeItem(at: home) }
        let fileURL = configurationURL(for: .codex, in: home)
        // The shape codex-cli 0.146.1 refuses with
        // `unknown field 'state', expected 'description' or 'hooks'`.
        let original = Data(
            #"{"state":{"version":3},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}"#.utf8
        )
        try original.write(to: fileURL)

        for result in [
            AgentStatusHookInstaller.install(for: .codex, at: fileURL),
            AgentStatusHookInstaller.uninstall(for: .codex, at: fileURL),
        ] {
            guard case .failure(let error) = result else {
                return XCTFail("a configuration Kurotty cannot recognize must not be rewritten")
            }
            XCTAssertEqual(error, .unrecognizedConfigurationShape(path: fileURL.path, unrecognizedKeys: ["state"]))
            XCTAssertTrue(error.diagnostic.contains("state"), "the diagnostic has to name what Kurotty did not know")
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), original, "the bytes must be identical")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path + ".kurotty-backup"),
            "a document Kurotty refuses to touch must not even gain a backup beside it"
        )
    }

    /// Claude Code's settings file legitimately carries keys Kurotty knows
    /// nothing about, so the same strictness must not be applied there.
    func testUnknownTopLevelKeysAreFineInClaudeCodeSettings() throws {
        let home = try makeTemporaryHome(agents: [.claudeCode])
        defer { try? FileManager.default.removeItem(at: home) }
        let fileURL = configurationURL(for: .claudeCode, in: home)
        try Data(#"{"model":"opus","statusLine":{"type":"command"}}"#.utf8).write(to: fileURL)

        XCTAssertNoThrow(try assertSuccess(AgentStatusHookInstaller.install(at: fileURL)))

        let installed = try readJSONObject(at: fileURL)
        XCTAssertEqual(installed["model"] as? String, "opus")
        XCTAssertNotNil(installed["statusLine"])
        XCTAssertTrue(AgentStatusHookInstaller.containsKurottyEntries(installed))
    }

    /// A file that is not JSON at all is the older refusal, and it applies to
    /// both agents.
    func testAnUnparseableConfigurationIsRefusedForEveryAgent() throws {
        let home = try makeTemporaryHome(agents: [.claudeCode, .codex])
        defer { try? FileManager.default.removeItem(at: home) }

        for target in AgentStatusHookTarget.allCases {
            let fileURL = configurationURL(for: target, in: home)
            let original = Data("{ not json at all".utf8)
            try original.write(to: fileURL)

            guard case .failure(let error) = AgentStatusHookInstaller.install(for: target, at: fileURL) else {
                return XCTFail("unparseable JSON must not be rewritten for \(target.rawValue)")
            }
            XCTAssertEqual(error, .settingsFileUnreadable(fileURL.path))
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
        }
    }

    /// Codex emits nothing that honestly means "the agent is waiting for you",
    /// so Kurotty reports no such state for it rather than approximating one.
    func testEventStateMappingIsAgentSpecificAndCodexHasNoWaitingSource() {
        XCTAssertEqual(AgentStatusHookEvent.userPromptSubmit.reportedState, .working)
        XCTAssertEqual(AgentStatusHookEvent.notification.reportedState, .waitingForInput)
        XCTAssertEqual(AgentStatusHookEvent.stop.reportedState, .done)

        XCTAssertEqual(AgentStatusHookTarget.claudeCode.events, [.userPromptSubmit, .notification, .stop])
        XCTAssertEqual(AgentStatusHookTarget.codex.events, [.userPromptSubmit, .stop])
        XCTAssertEqual(
            AgentStatusHookTarget.codex.events.map(\.reportedState),
            [.working, .done],
            "no Codex hook event may be read as waiting or blocked"
        )
        XCTAssertEqual(AgentStatusHookTarget.claudeCode.reportedAgentName, "claude")
        XCTAssertEqual(AgentStatusHookTarget.codex.reportedAgentName, "codex")
    }

    /// The generated command is what an agent's hook runner executes, so it is
    /// checked by running it: with Kurotty's PTY environment it reports, and
    /// without it — every other terminal — it exits silently.
    func testTheGeneratedCommandReportsUnderKurottyAndIsInertAnywhereElse() throws {
        let server = AgentStatusHookServer(token: Fixture.token)
        defer { server.stop() }
        let reports = ReportBox()
        server.onReport = { reports.append($0) }

        let bound = expectation(description: "listener bound")
        let boundPort = PortBox()
        server.start { result in
            if case .success(let port) = result {
                boundPort.value = port
            }
            bound.fulfill()
        }
        wait(for: [bound], timeout: 5)
        let port = try XCTUnwrap(boundPort.value)

        let paneIdentifier = "codex-command-pane-\(UUID().uuidString)"
        let command = AgentStatusHookInstaller.command(for: .stop, target: .codex)
        let environment = [
            AppConstants.AgentStatus.paneIdentifierEnvironmentName: paneIdentifier,
            AppConstants.AgentStatus.hookPortEnvironmentName: String(port),
            AppConstants.AgentStatus.hookTokenEnvironmentName: Fixture.token,
        ]

        XCTAssertEqual(runShell(command, environment: [:]), 0, "the guard clause must exit cleanly, not error")
        XCTAssertTrue(reports.all().isEmpty, "no Kurotty environment means no report")

        let reported = expectation(description: "status reported")
        reports.onAppend = { reported.fulfill() }
        XCTAssertEqual(runShell(command, environment: environment), 0)
        wait(for: [reported], timeout: 5)

        let report = try XCTUnwrap(reports.all().first)
        XCTAssertEqual(report.paneIdentifier, paneIdentifier)
        XCTAssertEqual(report.status.state, .done)
        XCTAssertEqual(report.status.agentName, "codex")
    }

    /// Carries the bound port back out of the server's own queue.
    private final class PortBox: @unchecked Sendable {
        var value: UInt16?
    }

    /// Collects reports from the server's own queue.
    private final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var reports: [AgentStatusHookReport] = []
        var onAppend: (() -> Void)?

        func append(_ report: AgentStatusHookReport) {
            lock.lock()
            reports.append(report)
            lock.unlock()
            onAppend?()
        }

        func all() -> [AgentStatusHookReport] {
            lock.lock()
            defer { lock.unlock() }
            return reports
        }
    }

    /// Runs the hook command the way an agent hook runner does: `/bin/sh -c`,
    /// with only the variables Kurotty injects into the PTY.
    private func runShell(_ command: String, environment: [String: String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Test double for the consent record; the production store writes through
    /// `AppSettingsStore`, which tests must never touch.
    @MainActor
    private static func recordingConsentStore(
        initial: AgentStatusHookConsent
    ) -> (
        store: AgentStatusHookConsentStore,
        recorded: () -> [AgentStatusHookTarget: AgentStatusHookConsent],
        disableCount: () -> Int
    ) {
        let box = ConsentBox(initial: initial)
        let store = AgentStatusHookConsentStore(
            read: { box.current[$0] ?? initial },
            record: { target, consent in
                box.current[target] = consent
                box.recorded[target] = consent
            },
            disableHooksSetting: { box.disableCount += 1 }
        )
        return (store, { box.recorded }, { box.disableCount })
    }

    private final class ConsentBox {
        var current: [AgentStatusHookTarget: AgentStatusHookConsent] = [:]
        var recorded: [AgentStatusHookTarget: AgentStatusHookConsent] = [:]
        var disableCount = 0

        init(initial: AgentStatusHookConsent) {
            for target in AgentStatusHookTarget.allCases {
                current[target] = initial
            }
        }
    }

    // MARK: - Hook settings merge / uninstall round trip

    func testInstallMergePreservesForeignKeysAndUninstallRoundTrips() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsFileURL = directory.appendingPathComponent("settings.json")
        let original: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash(ls:*)"]],
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "echo user-owned"]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settingsFileURL)

        XCTAssertNoThrow(try assertSuccess(AgentStatusHookInstaller.install(at: settingsFileURL)))

        let installed = try readJSONObject(at: settingsFileURL)
        XCTAssertEqual(installed["model"] as? String, "opus")
        XCTAssertNotNil(installed["permissions"])
        XCTAssertTrue(AgentStatusHookInstaller.containsKurottyEntries(installed))
        let installedHooks = try XCTUnwrap(installed["hooks"] as? [String: Any])
        for event in AgentStatusHookTarget.claudeCode.events {
            XCTAssertNotNil(installedHooks[event.rawValue], "missing hook entry for \(event.rawValue)")
        }
        // The user's own Stop hook must survive alongside Kurotty's.
        let stopMatchers = try XCTUnwrap(installedHooks["Stop"] as? [[String: Any]])
        let stopCommands = stopMatchers
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(stopCommands.contains("echo user-owned"))
        XCTAssertTrue(stopCommands.contains { AgentStatusHookInstaller.isManagedCommand($0) })

        // A backup of the pre-install file exists.
        let backupURL = directory.appendingPathComponent("settings.json.kurotty-backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        XCTAssertNoThrow(try assertSuccess(AgentStatusHookInstaller.uninstall(at: settingsFileURL)))

        let uninstalled = try readJSONObject(at: settingsFileURL)
        XCTAssertFalse(AgentStatusHookInstaller.containsKurottyEntries(uninstalled))
        XCTAssertEqual(uninstalled["model"] as? String, "opus")
        let remainingStop = try XCTUnwrap((uninstalled["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let remainingCommands = remainingStop
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
        XCTAssertEqual(remainingCommands, ["echo user-owned"])
    }

    func testRepeatedInstallDoesNotDuplicateEntries() {
        let installedOnce = AgentStatusHookInstaller.installing(into: [:])
        let installedTwice = AgentStatusHookInstaller.installing(into: installedOnce)

        let hooks = installedTwice[AppConstants.AgentStatus.hookDocumentHooksKey] as? [String: Any] ?? [:]
        for event in AgentStatusHookTarget.claudeCode.events {
            let matchers = hooks[event.rawValue] as? [[String: Any]] ?? []
            XCTAssertEqual(matchers.count, 1, "duplicate entries for \(event.rawValue)")
        }
    }

    func testUninstallOnFileWithoutKurottyEntriesIsALeaveItAlone() {
        let foreign: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "echo hi"]]]]],
        ]

        let cleaned = AgentStatusHookInstaller.removingKurottyEntries(from: foreign)

        XCTAssertFalse(AgentStatusHookInstaller.containsKurottyEntries(cleaned))
        let matchers = (cleaned["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        XCTAssertEqual(matchers?.count, 1)
    }

    func testInstallOnMissingFileCreatesItAndFailsSoftOnNonObjectJSON() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let freshURL = directory.appendingPathComponent("nested/settings.json")
        XCTAssertNoThrow(try assertSuccess(AgentStatusHookInstaller.install(at: freshURL)))
        XCTAssertTrue(AgentStatusHookInstaller.containsKurottyEntries(try readJSONObject(at: freshURL)))

        let arrayURL = directory.appendingPathComponent("array.json")
        try Data("[1,2,3]".utf8).write(to: arrayURL)
        guard case .failure(let error) = AgentStatusHookInstaller.install(at: arrayURL) else {
            return XCTFail("expected a soft failure for a non-object settings file")
        }
        XCTAssertEqual(error, .settingsFileNotJSONObject)
        XCTAssertFalse(error.diagnostic.isEmpty)
        XCTAssertEqual(try Data(contentsOf: arrayURL), Data("[1,2,3]".utf8), "file must be left untouched")
    }

    func testGeneratedHookCommandCarriesMarkerAndEnvironmentContract() {
        for target in AgentStatusHookTarget.allCases {
            for event in target.events {
                let command = AgentStatusHookInstaller.command(for: event, target: target)
                XCTAssertTrue(AgentStatusHookInstaller.isManagedCommand(command))
                XCTAssertTrue(command.contains(AppConstants.AgentStatus.paneIdentifierEnvironmentName))
                XCTAssertTrue(command.contains(AppConstants.AgentStatus.hookPortEnvironmentName))
                XCTAssertTrue(command.contains(AppConstants.AgentStatus.hookTokenEnvironmentName))
                XCTAssertTrue(command.contains(AppConstants.AgentStatus.hookLoopbackHost))
                XCTAssertTrue(command.contains(event.reportedState.rawValue))
                XCTAssertTrue(command.contains(target.reportedAgentName))
            }
        }
    }

    // MARK: - Hook server admission (pure)

    func testTokenComparisonRejectsEverythingButAnExactMatch() {
        XCTAssertTrue(AgentStatusHookRequestPolicy.isAuthorized(
            presentedToken: Fixture.token,
            expectedToken: Fixture.token
        ))
        XCTAssertFalse(AgentStatusHookRequestPolicy.isAuthorized(presentedToken: nil, expectedToken: Fixture.token))
        XCTAssertFalse(AgentStatusHookRequestPolicy.isAuthorized(presentedToken: "", expectedToken: Fixture.token))
        XCTAssertFalse(AgentStatusHookRequestPolicy.isAuthorized(
            presentedToken: Fixture.token + "x",
            expectedToken: Fixture.token
        ))
        XCTAssertFalse(AgentStatusHookRequestPolicy.isAuthorized(
            presentedToken: String(Fixture.token.dropLast()),
            expectedToken: Fixture.token
        ))
        // An empty expected token must never authorize anything.
        XCTAssertFalse(AgentStatusHookRequestPolicy.isAuthorized(presentedToken: "", expectedToken: ""))
    }

    func testAdmissionRejectsMissingTokenWrongTokenWrongPathAndWrongMethod() {
        let body = Data(#"{"paneId":"pane-A","state":"working"}"#.utf8)
        func request(
            method: String = "POST",
            path: String = AppConstants.AgentStatus.hookRequestPath,
            token: String? = Fixture.token
        ) -> AgentStatusHookRequestPolicy.Request {
            AgentStatusHookRequestPolicy.Request(method: method, path: path, token: token, body: body)
        }

        XCTAssertEqual(
            rejection(AgentStatusHookRequestPolicy.admit(request: request(token: nil), expectedToken: Fixture.token)),
            .missingToken
        )
        XCTAssertEqual(
            rejection(AgentStatusHookRequestPolicy.admit(
                request: request(token: "wrong"),
                expectedToken: Fixture.token
            )),
            .invalidToken
        )
        XCTAssertEqual(
            rejection(AgentStatusHookRequestPolicy.admit(request: request(path: "/"), expectedToken: Fixture.token)),
            .unknownPath
        )
        XCTAssertEqual(
            rejection(AgentStatusHookRequestPolicy.admit(request: request(method: "GET"), expectedToken: Fixture.token)),
            .unsupportedMethod
        )

        guard case .success(let report) = AgentStatusHookRequestPolicy.admit(
            request: request(),
            expectedToken: Fixture.token
        ) else {
            return XCTFail("a correctly authenticated request must be admitted")
        }
        XCTAssertEqual(report.paneIdentifier, Fixture.paneIdentifier)
        XCTAssertEqual(report.status.state, .working)
    }

    func testAdmissionRejectsOversizedAndMalformedBodies() {
        let oversized = Data(repeating: UInt8(ascii: "x"), count: AppConstants.AgentStatus.hookMaximumBodyBytes + 1)
        XCTAssertEqual(
            rejection(AgentStatusHookRequestPolicy.admit(
                request: AgentStatusHookRequestPolicy.Request(
                    method: "POST",
                    path: AppConstants.AgentStatus.hookRequestPath,
                    token: Fixture.token,
                    body: oversized
                ),
                expectedToken: Fixture.token
            )),
            .bodyTooLarge
        )
        XCTAssertEqual(rejection(AgentStatusHookRequestPolicy.decode(body: Data("nope".utf8))), .malformedBody)
        XCTAssertEqual(
            rejection(AgentStatusHookRequestPolicy.decode(body: Data(#"{"paneId":"","state":"done"}"#.utf8))),
            .malformedBody
        )
        XCTAssertEqual(
            rejection(AgentStatusHookRequestPolicy.decode(body: Data(#"{"paneId":"p","state":"nope"}"#.utf8))),
            .unknownState
        )
    }

    func testRequestParsingWaitsForCompleteHeadersAndBody() {
        let head = "POST \(AppConstants.AgentStatus.hookRequestPath) HTTP/1.1\r\n"
            + "\(AppConstants.AgentStatus.hookTokenHeaderName): \(Fixture.token)\r\n"
            + "Content-Length: 10\r\n"

        XCTAssertNil(AgentStatusHookRequestPolicy.parseRequest(buffer: Data(head.utf8)), "headers incomplete")
        XCTAssertNil(
            AgentStatusHookRequestPolicy.parseRequest(buffer: Data((head + "\r\n12345").utf8)),
            "body incomplete"
        )

        guard case .success(let request)? = AgentStatusHookRequestPolicy.parseRequest(
            buffer: Data((head + "\r\n1234567890").utf8)
        ) else {
            return XCTFail("a complete request must parse")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, AppConstants.AgentStatus.hookRequestPath)
        XCTAssertEqual(request.token, Fixture.token)
        XCTAssertEqual(request.body.count, 10)
    }

    func testRequestParsingRejectsDeclaredBodyOverTheCap() {
        let head = "POST \(AppConstants.AgentStatus.hookRequestPath) HTTP/1.1\r\n"
            + "Content-Length: \(AppConstants.AgentStatus.hookMaximumBodyBytes + 1)\r\n\r\n"

        XCTAssertEqual(
            rejection(AgentStatusHookRequestPolicy.parseRequest(buffer: Data(head.utf8))),
            .bodyTooLarge
        )
    }

    // MARK: - Output channel

    @MainActor
    func testOutputChannelStripsSequenceAndRecordsStatus() {
        let registry = AgentActivityRegistry()
        let channel = AgentStatusOutputChannel(paneIdentifier: Fixture.paneIdentifier, registry: registry)

        let visible = channel.filter("hi " + Fixture.oscPrefix + Fixture.workingPayload + Fixture.bell + "there")

        XCTAssertEqual(visible, "hi there")
        XCTAssertEqual(registry.status(for: Fixture.paneIdentifier)?.state, .working)
    }

    // MARK: - Surface output path

    /// Captures the surface's own `onOutput` hook so a test can push a PTY
    /// chunk through exactly the path the real session uses.
    private final class OutputStubSession: TerminalSession {
        var onOutput: ((String) -> Void)?
        var onRawOutput: ((Data) -> Void)?
        var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
        var onExit: ((TerminalChildExit) -> Void)?

        func start(workingDirectory: String) {}
        func write(_ text: String) {}
        func foregroundProcessName() -> String? { "zsh" }
        func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    /// The whole point of the OSC 9999 channel: the sequence is recorded and
    /// stripped before the surface can append it, so the escape bytes never
    /// reach the screen model and never render as garbage.
    @MainActor
    func testOsc9999IsRecordedAndNeverReachesTheScreenModel() throws {
        let paneIdentifier = "surface-pane-\(UUID().uuidString)"
        let session = OutputStubSession()
        let surface = TerminalSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 200),
            session: session,
            paneIdentifier: paneIdentifier
        )
        addTeardownBlock {
            Task { @MainActor in
                AgentActivityRegistry.shared.removePane(paneIdentifier)
            }
        }

        let chunk = "before"
            + Fixture.oscPrefix + Fixture.workingPayload + Fixture.bell
            + "after"
        let onOutput = try XCTUnwrap(session.onOutput, "the surface must install an output hook")
        onOutput(chunk)
        // Output is delivered on the main queue and then coalesced one display
        // tick, so both hops have to drain before the screen is asserted.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let visibleText = surface.tmuxRestoreStateForTesting.visibleLines.joined()
        XCTAssertTrue(visibleText.contains("beforeafter"))
        XCTAssertFalse(visibleText.contains("9999"), "the OSC number must not render")
        XCTAssertFalse(visibleText.contains("working"), "the status payload must not render")

        let status = try XCTUnwrap(AgentActivityRegistry.shared.status(for: paneIdentifier))
        XCTAssertEqual(status.state, .working)
        XCTAssertEqual(status.agentName, "claude")
        XCTAssertEqual(status.detail, "running tests")
    }

    /// The pane owns the identity; the surface, the PTY environment, and the
    /// registry must all agree on the same string.
    @MainActor
    func testPaneThreadsOneIdentifierIntoItsSurface() {
        let pane = TerminalPaneView(
            frame: .zero,
            session: TmuxPaneSession(writeHandler: { _ in }, resizeHandler: { _, _ in }, stopHandler: {})
        )
        XCTAssertFalse(pane.agentPaneIdentifier.isEmpty)
        XCTAssertEqual(pane.terminalSurface.agentPaneIdentifier, pane.agentPaneIdentifier)
    }

    /// The hook environment has to be assigned before the child is spawned, or
    /// the PTY carries no `KUROTTY_PANE_ID` at all.
    func testSurfaceAppliesTheHookEnvironmentBeforeStartingTheShell() throws {
        let source = try agentStatusSource("Sources/KurottyApp/TerminalSurfaceView.swift")
        let environmentRange = try XCTUnwrap(
            source.range(of: "AgentStatusHookCoordinator.shared.shellEnvironment(paneIdentifier: paneIdentifier)")
        )
        let startRange = try XCTUnwrap(
            source.range(of: "shell.start(workingDirectory: settings.shell.workingDirectory)")
        )
        XCTAssertTrue(environmentRange.lowerBound < startRange.lowerBound)
    }

    /// Both halves of the settings wiring stay source checks, and deliberately.
    /// `AgentStatusHookCoordinator.shared` observes the app-wide settings store
    /// and installs into the real home directory, so the observer refuses to act
    /// unless the app is actually running — which is what stops another suite's
    /// settings broadcast from rewriting the developer's own `~/.claude` and
    /// blocking on a consent modal nobody can answer. That guard is also why the
    /// path cannot be driven from a test. What the observer does once it fires
    /// is covered behaviorally by the `setEnabled` tests above.
    func testHookCoordinatorFollowsTheSettingsObserverPattern() throws {
        let source = try agentStatusSource("Sources/KurottyApp/AgentStatusHookCoordinator.swift")
        XCTAssertTrue(source.contains("AppSettingsStore.didChangeNotification"))
        XCTAssertTrue(source.contains("settings.terminal.agentStatusHooksEnabled"))

        let appDelegateSource = try agentStatusSource("Sources/KurottyApp/AppDelegate.swift")
        XCTAssertTrue(appDelegateSource.contains("AgentStatusHookCoordinator.shared.applyStoredSetting()"))
    }

    // MARK: - Indicator

    @MainActor
    func testIndicatorColorsAndTooltipsAreDistinctPerState() {
        // Status hues are theme-owned, so both ramps have to stay distinct: a
        // shared palette rendered the light theme's status text unreadable.
        for theme in [DesignTokens.ChromeTheme.dark, .light] {
            let colors = AgentActivityState.allCases.map {
                AgentActivityIndicatorView.color(for: $0, theme: theme)
            }
            XCTAssertEqual(Set(colors).count, AgentActivityState.allCases.count)
        }

        // Pinned to English: the tooltip now resolves through AppLocalization,
        // so an explicit language keeps the assertion independent of the
        // machine's system language.
        let tooltip = AgentActivityIndicatorView.tooltip(
            for: AgentActivityStatus(state: .waitingForInput, agentName: "claude", detail: "approve edit"),
            language: .english
        )
        XCTAssertTrue(tooltip.contains("claude"))
        XCTAssertTrue(tooltip.contains("Waiting for input"))
        XCTAssertTrue(tooltip.contains("approve edit"))
    }

    @MainActor
    func testIndicatorHidesWhenStatusIsCleared() {
        let indicator = AgentActivityIndicatorView(frame: .zero)

        indicator.update(status: AgentActivityStatus(state: .working))
        XCTAssertFalse(indicator.isHidden)

        indicator.update(status: nil)
        XCTAssertTrue(indicator.isHidden)
        XCTAssertNil(indicator.status)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurotty-agent-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A stand-in home directory with only the named agents "installed". Every
    /// test that touches an agent configuration goes through this, so the real
    /// `~/.claude` and `~/.codex` are never read or written.
    private func makeTemporaryHome(agents: [AgentStatusHookTarget]) throws -> URL {
        let home = try makeTemporaryDirectory()
        for agent in agents {
            try FileManager.default.createDirectory(
                at: configurationURL(for: agent, in: home).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        return home
    }

    private func configurationURL(for target: AgentStatusHookTarget, in home: URL) -> URL {
        AgentStatusHookInstaller.configurationFileURL(for: target, homeDirectory: home)
    }

    /// Flattens one event's matchers down to the commands they run.
    private func hookCommands(in event: Any?) -> [String] {
        guard let matchers = event as? [[String: Any]] else {
            return []
        }
        return matchers
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
    }

    private func readJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertSuccess(_ result: Result<Void, AgentStatusHookInstaller.InstallError>) throws {
        if case .failure(let error) = result {
            throw error
        }
    }

    private func rejection<Success>(
        _ result: Result<Success, AgentStatusHookRequestPolicy.Rejection>?
    ) -> AgentStatusHookRequestPolicy.Rejection? {
        guard case .failure(let rejection)? = result else {
            return nil
        }
        return rejection
    }
}

private func agentStatusSource(_ relativePath: String) throws -> String {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        root.deleteLastPathComponent()
    }
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}
