import XCTest
@testable import KurottyApp

/// Rules for the first-run checklist.
///
/// The distinction under test throughout is `action` versus `unavailable`:
/// something nobody has been asked about yet, versus something the user turned
/// off. Getting that wrong turns a report into nagging.
final class TerminalSetupChecklistTests: XCTestCase {
    private func item(
        _ id: TerminalSetupChecklistItemID,
        _ environment: TerminalSetupEnvironment
    ) -> TerminalSetupChecklistItem {
        let items = TerminalSetupChecklist.items(environment: environment)
        guard let match = items.first(where: { $0.id == id }) else {
            XCTFail("no row for \(id)")
            return TerminalSetupChecklistItem(id: id, state: .unavailable, action: nil)
        }
        return match
    }

    // MARK: - Composition

    func testEveryDefinedRowAppearsExactlyOnce() {
        let ids = TerminalSetupChecklist.items(environment: TerminalSetupEnvironment()).map(\.id)
        XCTAssertEqual(Set(ids), Set(TerminalSetupChecklistItemID.allCases))
        XCTAssertEqual(ids.count, TerminalSetupChecklistItemID.allCases.count)
    }

    func testRowOrderIsStableAcrossEnvironments() {
        // The order is editorial — how much each feature matters to a new user
        // — so it must not reshuffle as checks flip.
        let empty = TerminalSetupChecklist.items(environment: TerminalSetupEnvironment()).map(\.id)
        let full = TerminalSetupChecklist.items(environment: TerminalSetupEnvironment(
            shellInjectsCommandBoundaries: true,
            agentStatusHooksEnabled: true,
            agentStatusHookConsents: [.granted],
            agentSessionIndexEnabled: true,
            isRipgrepAvailable: true,
            isInstalledInApplications: true
        )).map(\.id)
        XCTAssertEqual(empty, full)
    }

    func testAFullyConfiguredMachineHasNothingOutstanding() {
        let environment = TerminalSetupEnvironment(
            shellInjectsCommandBoundaries: true,
            agentStatusHooksEnabled: true,
            agentStatusHookConsents: [.granted, .granted],
            agentSessionIndexEnabled: true,
            isRipgrepAvailable: true,
            isInstalledInApplications: true
        )
        XCTAssertEqual(TerminalSetupChecklist.outstandingCOUNT(environment: environment), 0)
        XCTAssertTrue(
            TerminalSetupChecklist.items(environment: environment).allSatisfy { $0.state == .ready }
        )
    }

    func testASwitchedOffFeatureIsNotCountedAsOutstandingWork() {
        // A row the user deliberately turned off is not work waiting to be
        // done, and a badge that counted it would keep asking them to undo a
        // choice they made.
        let environment = TerminalSetupEnvironment(
            shellInjectsCommandBoundaries: true,
            agentStatusHooksEnabled: false,
            agentSessionIndexEnabled: false,
            isRipgrepAvailable: true,
            isInstalledInApplications: true
        )
        XCTAssertEqual(TerminalSetupChecklist.outstandingCOUNT(environment: environment), 0)
    }

    // MARK: - Shell integration

    func testShellIntegrationIsReadyWhenTheShellGetsBundledBoundaries() {
        let row = item(.shellIntegration, TerminalSetupEnvironment(shellInjectsCommandBoundaries: true))
        XCTAssertEqual(row.state, .ready)
        XCTAssertNil(row.action)
    }

    func testAnUnsupportedShellIsReportedAsOffRatherThanAsSomethingToFix() {
        // There is no switch to flip and no command to paste: the answer would
        // be a different login shell, which a checklist row has no business
        // pushing anyone toward.
        let row = item(.shellIntegration, TerminalSetupEnvironment(shellInjectsCommandBoundaries: false))
        XCTAssertEqual(row.state, .unavailable)
        XCTAssertNil(row.action)
    }

    // MARK: - Agent status

    func testAgentStatusNeedsConsentAndNotOnlyTheSwitch() {
        // Consent is what actually decides whether anything reports, so a
        // switch that is on with nothing granted is not readiness.
        let row = item(.agentStatus, TerminalSetupEnvironment(
            agentStatusHooksEnabled: true,
            agentStatusHookConsents: [.unasked, .unasked]
        ))
        XCTAssertEqual(row.state, .action)
        XCTAssertEqual(row.action, .openSettings)
    }

    func testOneGrantedAgentIsEnoughForAgentStatusToBeReady() {
        let row = item(.agentStatus, TerminalSetupEnvironment(
            agentStatusHooksEnabled: true,
            agentStatusHookConsents: [.denied, .granted]
        ))
        XCTAssertEqual(row.state, .ready)
    }

    func testDenyingEveryAgentIsReportedAsOffRatherThanAsOutstanding() {
        // The user answered the question. Re-raising it in a checklist is
        // asking twice.
        let row = item(.agentStatus, TerminalSetupEnvironment(
            agentStatusHooksEnabled: true,
            agentStatusHookConsents: [.denied, .denied]
        ))
        XCTAssertEqual(row.state, .unavailable)
    }

    func testTurningTheAgentStatusSwitchOffOverridesAnyRecordedConsent() {
        let row = item(.agentStatus, TerminalSetupEnvironment(
            agentStatusHooksEnabled: false,
            agentStatusHookConsents: [.granted]
        ))
        XCTAssertEqual(row.state, .unavailable)
    }

    // MARK: - Agent sessions

    func testIndexingOnIsReadyWithoutConsultingHowMuchWasFound() {
        // A machine with no agent history is not a machine with a problem, so
        // the row reports the switch and nothing else.
        let row = item(.agentSessions, TerminalSetupEnvironment(agentSessionIndexEnabled: true))
        XCTAssertEqual(row.state, .ready)
        XCTAssertNil(row.action)
    }

    func testIndexingOffIsAPreferenceRatherThanAGap() {
        let row = item(.agentSessions, TerminalSetupEnvironment(agentSessionIndexEnabled: false))
        XCTAssertEqual(row.state, .unavailable)
        XCTAssertEqual(row.action, .openSettings)
    }

    // MARK: - Project files and the external binary

    func testMissingRipgrepOffersTheInstallCommandRatherThanReportingAFailure() {
        // The feature works without it — the built-in walk answers the same
        // query with a smaller answer — so this is an offer, not an error.
        let row = item(.projectFiles, TerminalSetupEnvironment(isRipgrepAvailable: false))
        XCTAssertEqual(row.state, .action)
        XCTAssertEqual(row.action, .copyCommand("brew install ripgrep"))
    }

    func testTheInstallCommandIsNeverExecutedOnlyOffered() {
        // Kurotty composes commands and refuses to run them, the same position
        // the worktree popover and the session resume row already take. The
        // action vocabulary has no run case at all, which is what makes that
        // structural rather than a convention.
        guard case let .copyCommand(command) = item(
            .projectFiles,
            TerminalSetupEnvironment(isRipgrepAvailable: false)
        ).action else {
            return XCTFail("expected a copyable command")
        }
        XCTAssertEqual(command, TerminalSetupChecklist.ripgrepInstallCommand)
    }

    func testInstalledRipgrepIsReadyWithNothingToDo() {
        let row = item(.projectFiles, TerminalSetupEnvironment(isRipgrepAvailable: true))
        XCTAssertEqual(row.state, .ready)
        XCTAssertNil(row.action)
    }

    // MARK: - Install location

    func testRunningOutsideApplicationsIsOutstandingButOffersNoActionOfItsOwn() {
        // The launch-time move prompt owns the move. A second mover would be a
        // second thing that can relaunch the app.
        let row = item(.installLocation, TerminalSetupEnvironment(isInstalledInApplications: false))
        XCTAssertEqual(row.state, .action)
        XCTAssertNil(row.action)
    }

    // MARK: - Copy

    func testEveryRowHasATitleAndADetailInEveryLanguage() {
        for language in AppLanguage.allCases {
            for id in TerminalSetupChecklistItemID.allCases {
                XCTAssertFalse(
                    TerminalSetupChecklistCopy.title(for: id, language: language).isEmpty,
                    "\(id) has no title in \(language)"
                )
                XCTAssertFalse(
                    TerminalSetupChecklistCopy.detail(for: id, language: language).isEmpty,
                    "\(id) has no detail in \(language)"
                )
            }
        }
    }

    func testTheThreeStatesReadDifferentlyInEveryLanguage() {
        for language in AppLanguage.allCases {
            let labels = [
                TerminalSetupChecklistCopy.stateLabel(for: .ready, language: language),
                TerminalSetupChecklistCopy.stateLabel(for: .action, language: language),
                TerminalSetupChecklistCopy.stateLabel(for: .unavailable, language: language),
            ]
            XCTAssertEqual(Set(labels).count, 3, "state labels collide in \(language)")
        }
    }

    func testBothActionsAreLabelledInEveryLanguage() {
        for language in AppLanguage.allCases {
            XCTAssertFalse(
                TerminalSetupChecklistCopy.actionLabel(for: .openSettings, language: language).isEmpty
            )
            XCTAssertFalse(
                TerminalSetupChecklistCopy.actionLabel(for: .copyCommand("x"), language: language).isEmpty
            )
        }
    }
}
