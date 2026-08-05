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

    // MARK: - Hook setting default

    func testHookSettingDefaultsToFalse() {
        XCTAssertFalse(AppConstants.AgentStatus.hooksEnabledDefault)
        XCTAssertFalse(AgentStatusHookSettings.defaultValue)
        XCTAssertFalse(AgentStatusHookSettings.isEnabled())
        XCTAssertTrue(AgentStatusHookSettings.isEnabled(decodedSettingValue: true))
        XCTAssertEqual(AgentStatusHookSettings.settingsKeyPath, "terminal.agentStatusHooksEnabled")
    }

    @MainActor
    func testCoordinatorInjectsNoEnvironmentWhileDisabled() {
        let coordinator = AgentStatusHookCoordinator(server: AgentStatusHookServer(token: Fixture.token))

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertTrue(coordinator.shellEnvironment(paneIdentifier: Fixture.paneIdentifier).isEmpty)
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
        for event in AgentStatusHookEvent.allCases {
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

        let hooks = installedTwice[AppConstants.AgentStatus.claudeHooksKey] as? [String: Any] ?? [:]
        for event in AgentStatusHookEvent.allCases {
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
        for event in AgentStatusHookEvent.allCases {
            let command = AgentStatusHookInstaller.command(for: event)
            XCTAssertTrue(AgentStatusHookInstaller.isManagedCommand(command))
            XCTAssertTrue(command.contains(AppConstants.AgentStatus.paneIdentifierEnvironmentName))
            XCTAssertTrue(command.contains(AppConstants.AgentStatus.hookPortEnvironmentName))
            XCTAssertTrue(command.contains(AppConstants.AgentStatus.hookTokenEnvironmentName))
            XCTAssertTrue(command.contains(AppConstants.AgentStatus.hookLoopbackHost))
            XCTAssertTrue(command.contains(event.reportedState.rawValue))
        }
        XCTAssertEqual(AgentStatusHookEvent.userPromptSubmit.reportedState, .working)
        XCTAssertEqual(AgentStatusHookEvent.notification.reportedState, .waitingForInput)
        XCTAssertEqual(AgentStatusHookEvent.stop.reportedState, .done)
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
        var onExit: ((Int32) -> Void)?

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
