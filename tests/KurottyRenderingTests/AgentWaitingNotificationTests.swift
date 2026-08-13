import XCTest
@testable import KurottyCore
@testable import KurottyApp

/// An agent that stops on a permission prompt in a pane the user is not looking
/// at used to reach them through a coloured dot in the status bar and nothing
/// else, so the prompt waited until someone happened to check. These cover the
/// decision path from a reported state to a banner and back down again.
final class AgentWaitingNotificationTests: XCTestCase {
    private let debounceSeconds: TimeInterval = 10
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func makePolicy() -> AgentWaitingNotificationPolicy {
        AgentWaitingNotificationPolicy(debounceSeconds: debounceSeconds)
    }

    /// Convenience for the common case: enabled, unfocused, at `start`.
    private func decideUnfocused(
        _ policy: inout AgentWaitingNotificationPolicy,
        state: AgentActivityState?,
        at offsetSeconds: TimeInterval = 0
    ) -> AgentWaitingNotificationPolicy.Decision {
        policy.decide(
            state: state,
            isEnabled: true,
            isFocused: false,
            now: start.addingTimeInterval(offsetSeconds)
        )
    }

    // MARK: - Which states are worth an interruption

    func testOnlyStatesThatCannotProceedWithoutAPersonRequireAttention() {
        XCTAssertTrue(AgentWaitingNotificationPolicy.requiresAttention(.waitingForInput))
        XCTAssertTrue(AgentWaitingNotificationPolicy.requiresAttention(.blocked))
        XCTAssertFalse(AgentWaitingNotificationPolicy.requiresAttention(.working))
        XCTAssertFalse(
            AgentWaitingNotificationPolicy.requiresAttention(.done),
            "a finished turn is not something the user is holding up"
        )
    }

    // MARK: - Transitions in

    func testTheTransitionIntoWaitingNotifies() {
        var policy = makePolicy()

        XCTAssertEqual(decideUnfocused(&policy, state: .working), .doNothing)
        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))
    }

    func testTheTransitionIntoBlockedNotifies() {
        var policy = makePolicy()

        XCTAssertEqual(decideUnfocused(&policy, state: .working), .doNothing)
        XCTAssertEqual(decideUnfocused(&policy, state: .blocked), .notify(state: .blocked))
    }

    func testAFirstReportThatIsAlreadyWaitingNotifies() {
        // A pane that is adopted mid-prompt — the hook's first report, or a
        // status restored after a reconnect — has no previous state to leave.
        var policy = makePolicy()

        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))
    }

    func testRepeatsOfTheSameWaitingStateDoNotStackBanners() {
        // Producers refresh their state on a heartbeat; the registry posts a
        // change for every one of them.
        var policy = makePolicy()

        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))
        for repeatIndex in 1...5 {
            XCTAssertEqual(
                decideUnfocused(&policy, state: .waitingForInput, at: TimeInterval(repeatIndex) * debounceSeconds * 2),
                .doNothing,
                "repeat \(repeatIndex) is a heartbeat, not a new prompt"
            )
        }
    }

    func testProgressAndCompletionNeverNotify() {
        var policy = makePolicy()

        XCTAssertEqual(decideUnfocused(&policy, state: .working), .doNothing)
        XCTAssertEqual(decideUnfocused(&policy, state: .done), .doNothing)
        XCTAssertEqual(decideUnfocused(&policy, state: nil), .doNothing)
    }

    // MARK: - Focus gating

    func testTheFocusedPaneNeverNotifies() {
        var policy = makePolicy()

        XCTAssertEqual(
            policy.decide(state: .waitingForInput, isEnabled: true, isFocused: true, now: start),
            .doNothing
        )
    }

    func testLeavingTheWindowWhileTheAgentIsAlreadyWaitingIsNotATransition() {
        // The rule is "notifies when it starts waiting", not "notifies whenever
        // the user looks away", or every alt-tab would raise a banner for every
        // pane already sitting at a prompt.
        var policy = makePolicy()

        XCTAssertEqual(
            policy.decide(state: .waitingForInput, isEnabled: true, isFocused: true, now: start),
            .doNothing
        )
        XCTAssertEqual(
            decideUnfocused(&policy, state: .waitingForInput, at: debounceSeconds * 10),
            .doNothing
        )
    }

    func testReachingTheWaitingPaneWithdrawsItsBanner() {
        var policy = makePolicy()
        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))

        XCTAssertEqual(
            policy.decide(state: .waitingForInput, isEnabled: true, isFocused: true, now: start.addingTimeInterval(5)),
            .withdraw,
            "the user is looking at the prompt, so the banner about it is stale"
        )
        XCTAssertEqual(
            policy.decide(state: .waitingForInput, isEnabled: true, isFocused: true, now: start.addingTimeInterval(6)),
            .doNothing,
            "nothing left to withdraw"
        )
    }

    func testLeavingAgainAfterAnsweringNothingDoesNotReRaiseTheBanner() {
        var policy = makePolicy()
        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))
        XCTAssertEqual(
            policy.decide(state: .waitingForInput, isEnabled: true, isFocused: true, now: start.addingTimeInterval(1)),
            .withdraw
        )

        XCTAssertEqual(
            decideUnfocused(&policy, state: .waitingForInput, at: debounceSeconds * 10),
            .doNothing,
            "the same prompt the user already saw must not come back as a new banner"
        )
    }

    // MARK: - Debounce

    func testASecondWaitingStateInsideTheDebounceWindowIsOneInterruption() {
        // An agent that reports `waiting` and then `blocked` while it settles
        // into a prompt is one event to the user.
        var policy = makePolicy()

        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))
        XCTAssertEqual(decideUnfocused(&policy, state: .blocked, at: 0.4), .doNothing)
    }

    func testFlappingThroughWorkingInsideTheDebounceWindowIsOneInterruption() {
        var policy = makePolicy()

        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))
        XCTAssertEqual(decideUnfocused(&policy, state: .working, at: 1), .withdraw)
        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput, at: 2), .doNothing)
    }

    func testANewPromptAfterTheDebounceWindowNotifiesAgain() {
        var policy = makePolicy()

        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))
        XCTAssertEqual(decideUnfocused(&policy, state: .working, at: 1), .withdraw)
        XCTAssertEqual(
            decideUnfocused(&policy, state: .waitingForInput, at: debounceSeconds + 1),
            .notify(state: .waitingForInput)
        )
    }

    func testAClockThatMovesBackwardCannotSilenceAPane() {
        var policy = makePolicy()
        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))
        XCTAssertEqual(decideUnfocused(&policy, state: .working, at: 1), .withdraw)

        XCTAssertEqual(
            decideUnfocused(&policy, state: .waitingForInput, at: -3_600),
            .notify(state: .waitingForInput)
        )
    }

    // MARK: - Withdrawal

    func testTheBannerComesDownWhenTheAgentResumesWork() {
        var policy = makePolicy()
        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))

        XCTAssertEqual(decideUnfocused(&policy, state: .working, at: 1), .withdraw)
    }

    func testTheBannerComesDownWhenTheStatusIsClearedOrExpires() {
        // The registry resolves staleness on read, so a killed agent surfaces
        // here as `nil` rather than as a terminal state.
        var policy = makePolicy()
        XCTAssertEqual(decideUnfocused(&policy, state: .blocked), .notify(state: .blocked))

        XCTAssertEqual(decideUnfocused(&policy, state: nil, at: 1), .withdraw)
    }

    func testWithdrawalHappensOnceForOneBanner() {
        var policy = makePolicy()
        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))

        XCTAssertEqual(decideUnfocused(&policy, state: .done, at: 1), .withdraw)
        XCTAssertEqual(decideUnfocused(&policy, state: nil, at: 2), .doNothing)
        XCTAssertEqual(decideUnfocused(&policy, state: .working, at: 3), .doNothing)
    }

    func testAPaneThatNeverNotifiedNeverWithdraws() {
        var policy = makePolicy()

        XCTAssertEqual(decideUnfocused(&policy, state: .working), .doNothing)
        XCTAssertEqual(decideUnfocused(&policy, state: .done, at: 1), .doNothing)
        XCTAssertEqual(decideUnfocused(&policy, state: nil, at: 2), .doNothing)
    }

    // MARK: - The setting

    func testTheSettingOffNeverNotifies() {
        var policy = makePolicy()

        XCTAssertEqual(
            policy.decide(state: .waitingForInput, isEnabled: false, isFocused: false, now: start),
            .doNothing
        )
    }

    func testTurningTheSettingOffTakesDownABannerThatIsAlreadyUp() {
        var policy = makePolicy()
        XCTAssertEqual(decideUnfocused(&policy, state: .waitingForInput), .notify(state: .waitingForInput))

        XCTAssertEqual(
            policy.decide(
                state: .waitingForInput,
                isEnabled: false,
                isFocused: false,
                now: start.addingTimeInterval(1)
            ),
            .withdraw
        )
    }

    func testAgentWaitingNotificationsDefaultOn() {
        XCTAssertTrue(SettingsDefaults.notifyOnAgentWaiting)
        XCTAssertTrue(AppSettings.default.terminal.notifyOnAgentWaiting)
    }

    func testSettingsWrittenBeforeTheKeyExistedNormalizeToTheCurrentDefault() {
        var settings = AppSettings.default
        settings.schemaVersion = 22
        settings.terminal.notifyOnAgentWaiting = false

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertEqual(normalized.schemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertEqual(normalized.terminal.notifyOnAgentWaiting, SettingsDefaults.notifyOnAgentWaiting)
    }

    func testCurrentSchemaPreservesAnExplicitChoice() {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion
        settings.terminal.notifyOnAgentWaiting = false

        XCTAssertFalse(AppSettingsNormalizer.normalized(settings).terminal.notifyOnAgentWaiting)
    }

    func testDecodingASettingsFileWithoutTheKeyUsesTheDefault() throws {
        let json = """
        {
          "schemaVersion": 22,
          "terminal": {
            "theme": "kurotty",
            "fontName": "Menlo",
            "fontSize": 15,
            "scrollbackLines": 10000,
            "colors": {
              "foreground": "#E5E7EB",
              "background": "#22252B",
              "cursor": "#D7C6F4",
              "ansi": [
                "#2F333A", "#FF5F67", "#5FD38D", "#E5C07B",
                "#61AFEF", "#C792EA", "#56B6C2", "#D7DAE0",
                "#60646C", "#FF7B86", "#8EE8A3", "#F0D28A",
                "#7AB7FF", "#D7A8FF", "#7FDCE3", "#F5F7FA"
              ]
            }
          },
          "window": { "width": 1100, "height": 720 },
          "shell": { "workingDirectory": "/tmp" }
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.terminal.notifyOnAgentWaiting, SettingsDefaults.notifyOnAgentWaiting)
    }

    func testAnExplicitChoiceSurvivesAnEncodeDecodeRoundTrip() throws {
        for choice in [true, false] {
            var settings = AppSettings.default
            settings.terminal.notifyOnAgentWaiting = choice

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

            XCTAssertEqual(decoded.terminal.notifyOnAgentWaiting, choice)
        }
    }

    // MARK: - Banner content

    func testTheProducersOwnFieldsAreWhatTheBannerShows() {
        let status = AgentActivityStatus(
            state: .waitingForInput,
            agentName: "example-runner",
            detail: "Approve writing to src/main.swift?"
        )

        let content = AgentWaitingNotificationContent.make(
            state: status.state,
            agentName: status.agentName,
            detail: status.detail,
            paneTitle: "~/projects/kurotty (build)"
        )

        XCTAssertEqual(content.title, "example-runner")
        XCTAssertEqual(content.body, "Approve writing to src/main.swift?")
        XCTAssertEqual(
            content.subtitle,
            "~/projects/kurotty (build)",
            "the banner identifies the pane, which is the question the user actually has"
        )
    }

    func testAProducerThatSentNoFieldsGetsARoleAndTheReportedState() {
        let content = AgentWaitingNotificationContent.make(
            state: .waitingForInput,
            agentName: nil,
            detail: nil,
            paneTitle: "~/projects/kurotty"
        )

        XCTAssertEqual(content.title, AppConstants.Notifications.agentWaitingDefaultTitle)
        XCTAssertEqual(content.body, AppConstants.Notifications.agentWaitingForInputBody)
    }

    func testBlockedAndWaitingReadDifferentlyWhenTheProducerSuppliedNoDetail() {
        let waiting = AgentWaitingNotificationContent.make(
            state: .waitingForInput,
            agentName: nil,
            detail: nil,
            paneTitle: ""
        )
        let blocked = AgentWaitingNotificationContent.make(
            state: .blocked,
            agentName: nil,
            detail: nil,
            paneTitle: ""
        )

        XCTAssertNotEqual(waiting.body, blocked.body)
        XCTAssertEqual(blocked.body, AppConstants.Notifications.agentBlockedBody)
    }

    func testBlankProducerFieldsFallBackRatherThanShowingEmptyText() {
        let content = AgentWaitingNotificationContent.make(
            state: .blocked,
            agentName: "   ",
            detail: "\n\t ",
            paneTitle: "   "
        )

        XCTAssertEqual(content.title, AppConstants.Notifications.agentWaitingDefaultTitle)
        XCTAssertEqual(content.body, AppConstants.Notifications.agentBlockedBody)
        XCTAssertEqual(content.subtitle, "")
    }

    func testControlBytesInAProducerPayloadDoNotReachTheBanner() {
        let content = AgentWaitingNotificationContent.make(
            state: .waitingForInput,
            agentName: "runner\u{07}",
            detail: "Approve\u{1B}[31m this?",
            paneTitle: "pane"
        )

        XCTAssertEqual(content.title, "runner")
        XCTAssertEqual(content.body, "Approve[31m this?")
    }

    func testAPaneKeepsOneBannerIdentitySoANewStateReplacesTheOldBanner() {
        let paneIdentifier = "05F0A1B2-3C4D-5E6F-7A8B-9C0D1E2F3A4B"

        XCTAssertEqual(
            TerminalNotifier.agentWaitingIdentifier(paneIdentifier: paneIdentifier),
            TerminalNotifier.agentWaitingIdentifier(paneIdentifier: paneIdentifier),
            "the identifier is what replaces and withdraws a pane's banner, so it must be stable"
        )
        XCTAssertNotEqual(
            TerminalNotifier.agentWaitingIdentifier(paneIdentifier: paneIdentifier),
            TerminalNotifier.agentWaitingIdentifier(paneIdentifier: "other-pane"),
            "two panes waiting at once are two banners"
        )
    }

    // MARK: - Registry integration

    /// The registry is what both reporting channels — the OSC 9999 stream and
    /// the loopback hook — publish into, so a pane's decision has to follow what
    /// it resolves rather than what any one channel saw.
    @MainActor
    func testAStatusThatExpiresInTheRegistryWithdrawsTheBanner() {
        let registry = AgentActivityRegistry()
        let paneIdentifier = "pane-under-test"
        var policy = makePolicy()

        registry.record(
            AgentActivityStatus(state: .waitingForInput, updatedAt: start),
            paneIdentifier: paneIdentifier
        )
        XCTAssertEqual(
            policy.decide(
                state: registry.status(for: paneIdentifier, now: start)?.state,
                isEnabled: true,
                isFocused: false,
                now: start
            ),
            .notify(state: .waitingForInput)
        )

        let afterExpiry = start.addingTimeInterval(
            AppConstants.AgentStatus.waitingForInputStaleAfterSeconds + 1
        )
        XCTAssertNil(registry.status(for: paneIdentifier, now: afterExpiry))
        XCTAssertEqual(
            policy.decide(
                state: registry.status(for: paneIdentifier, now: afterExpiry)?.state,
                isEnabled: true,
                isFocused: false,
                now: afterExpiry
            ),
            .withdraw
        )
    }
}
