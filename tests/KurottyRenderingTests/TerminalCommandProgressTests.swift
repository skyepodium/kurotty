import AppKit
import KurottyCore
import XCTest

@testable import KurottyApp

/// The per-pane command progress bar: what OSC 9;4 actually says, when the bar
/// is allowed on screen, and what reduced motion does to it.
///
/// Every visibility rule is asserted against the pure policy with explicit
/// dates, so none of it depends on a window, a PTY, or wall-clock waiting.
final class TerminalCommandProgressTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let appearanceDelay: TimeInterval = 0.5
    private let failureLinger: TimeInterval = 1.6

    private func makePolicy(isEnabled: Bool = true) -> TerminalCommandProgressPolicy {
        TerminalCommandProgressPolicy(
            isEnabled: isEnabled,
            appearanceDelaySeconds: appearanceDelay,
            failureLingerSeconds: failureLinger
        )
    }

    // MARK: - OSC 9;4 parsing

    func testProgressReportCarriesStateAndPercent() {
        let report = TerminalCommandProgressReport.parse(oscPayload: "4;1;42")

        XCTAssertEqual(report, TerminalCommandProgressReport(state: .set, percent: 42))
    }

    func testEveryDocumentedProgressStateParses() {
        let states: [(String, TerminalCommandProgressReport.State)] = [
            ("0", .cleared),
            ("1", .set),
            ("2", .error),
            ("3", .indeterminate),
            ("4", .paused),
        ]

        for (wireValue, state) in states {
            XCTAssertEqual(
                TerminalCommandProgressReport.parse(oscPayload: "4;\(wireValue)")?.state,
                state,
                "state \(wireValue) must parse"
            )
        }
    }

    /// A producer that omits the percentage said "I am working", not "I am at
    /// zero", and the bar must not render the two the same way.
    func testMissingOrUnreadablePercentIsNotZeroPercent() {
        XCTAssertEqual(TerminalCommandProgressReport.parse(oscPayload: "4;1")?.percent, nil)
        XCTAssertEqual(TerminalCommandProgressReport.parse(oscPayload: "4;1;")?.percent, nil)
        XCTAssertEqual(TerminalCommandProgressReport.parse(oscPayload: "4;1;abc")?.percent, nil)
        XCTAssertEqual(TerminalCommandProgressReport.parse(oscPayload: "4;1;12.5")?.percent, nil)
        XCTAssertEqual(TerminalCommandProgressReport.parse(oscPayload: "4;1;0")?.percent, 0)
    }

    func testOutOfRangePercentIsClampedRatherThanDropped() {
        XCTAssertEqual(TerminalCommandProgressReport.parse(oscPayload: "4;1;150")?.percent, 100)
        XCTAssertEqual(TerminalCommandProgressReport.parse(oscPayload: "4;1;-20")?.percent, 0)
        XCTAssertEqual(
            TerminalCommandProgressReport.parse(oscPayload: "4;1;99999999999999999999")?.percent,
            nil,
            "a value no Int can hold is unreadable, not a clamp"
        )
    }

    func testMalformedProgressPayloadsAreNotProgressReports() {
        for payload in ["", "4", "4;", "4;x;50", "4;5;50", "4;-1;50", "3;1;50", "notify;a;b"] {
            XCTAssertNil(
                TerminalCommandProgressReport.parse(oscPayload: payload),
                "\(payload) must not parse as a progress report"
            )
        }
    }

    func testDispatcherRoutesProgressToProgressAndTextToNotification() {
        var dispatcher = TerminalOSCDispatcher(osc52Policy: TerminalOSC52Policy(policy: .default))

        XCTAssertEqual(
            dispatcher.dispatch("9;4;1;50", origin: .local),
            .commandProgress(TerminalCommandProgressReport(state: .set, percent: 50))
        )
        XCTAssertEqual(
            dispatcher.dispatch("9;Build finished", origin: .local),
            .desktopNotification(
                TerminalNotificationPayload.Content(
                    source: .osc9,
                    title: "",
                    subtitle: "",
                    body: "Build finished"
                )
            )
        )
        XCTAssertEqual(
            dispatcher.dispatch("9;7;1;50", origin: .local),
            .ignored,
            "an unknown numeric OSC 9 extension is still neither progress nor a message"
        )
    }

    // MARK: - Visibility policy

    func testIdlePaneShowsNothing() {
        let policy = makePolicy()

        XCTAssertNil(policy.presentation(at: start))
        XCTAssertNil(policy.nextPresentationChange(after: start))
    }

    func testShortCommandNeverShowsABar() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)

        XCTAssertNil(policy.presentation(at: start))
        XCTAssertNil(policy.presentation(at: start.addingTimeInterval(appearanceDelay - 0.01)))

        policy.commandDidEnd(exitCode: 0, at: start.addingTimeInterval(appearanceDelay - 0.01))

        XCTAssertNil(policy.presentation(at: start.addingTimeInterval(appearanceDelay + 5)))
    }

    func testCommandPastTheThresholdSweeps() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)

        XCTAssertEqual(
            policy.presentation(at: start.addingTimeInterval(appearanceDelay)),
            TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running)
        )
    }

    func testTheOnlyScheduledWakeUpIsTheMomentTheBarBecomesDue() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)

        XCTAssertEqual(
            policy.nextPresentationChange(after: start),
            start.addingTimeInterval(appearanceDelay)
        )
        XCTAssertNil(
            policy.nextPresentationChange(after: start.addingTimeInterval(appearanceDelay)),
            "once the bar is up nothing further is pending, so nothing may wake up"
        )
    }

    /// An explicit report is a producer declaring a long operation, so it does
    /// not wait out the anti-flash delay.
    func testAReportedPercentageAppearsImmediately() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        policy.didReceive(TerminalCommandProgressReport(state: .set, percent: 25))

        XCTAssertEqual(
            policy.presentation(at: start),
            TerminalCommandProgressPresentation(fill: .fraction(0.25), tone: .running)
        )
        XCTAssertNil(policy.nextPresentationChange(after: start))
    }

    func testReportedStatesMapToTheirTones() {
        let cases: [(TerminalCommandProgressReport, TerminalCommandProgressPresentation)] = [
            (
                TerminalCommandProgressReport(state: .error, percent: 40),
                TerminalCommandProgressPresentation(fill: .fraction(0.4), tone: .failed)
            ),
            (
                TerminalCommandProgressReport(state: .paused, percent: 60),
                TerminalCommandProgressPresentation(fill: .fraction(0.6), tone: .paused)
            ),
            (
                TerminalCommandProgressReport(state: .indeterminate, percent: 60),
                TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running)
            ),
            (
                TerminalCommandProgressReport(state: .set, percent: nil),
                TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running)
            ),
        ]

        for (report, expected) in cases {
            var policy = makePolicy()
            policy.commandDidStart(at: start)
            policy.didReceive(report)

            XCTAssertEqual(policy.presentation(at: start), expected, "\(report) rendered wrong")
        }
    }

    /// State 0 withdraws the producer's number instead of reporting zero, so the
    /// bar falls back to the elapsed-time rule rather than to an empty track.
    func testClearingProgressFallsBackToTheElapsedTimeRule() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        policy.didReceive(TerminalCommandProgressReport(state: .set, percent: 25))
        policy.didReceive(TerminalCommandProgressReport(state: .cleared, percent: nil))

        XCTAssertNil(policy.presentation(at: start))
        XCTAssertEqual(
            policy.presentation(at: start.addingTimeInterval(appearanceDelay)),
            TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running)
        )
    }

    /// Kurotty knows exactly when a command runs. A bar raised by a stray
    /// sequence outside a command span has nothing guaranteed to take it down.
    func testProgressReportedOutsideACommandSpanIsIgnored() {
        var policy = makePolicy()
        policy.didReceive(TerminalCommandProgressReport(state: .set, percent: 50))

        XCTAssertNil(policy.presentation(at: start))
    }

    func testTheNextCommandDoesNotInheritTheLastOnesPercentage() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        policy.didReceive(TerminalCommandProgressReport(state: .set, percent: 80))
        policy.commandDidEnd(exitCode: 0, at: start.addingTimeInterval(1))
        policy.commandDidStart(at: start.addingTimeInterval(2))

        XCTAssertNil(policy.presentation(at: start.addingTimeInterval(2)))
    }

    func testASuccessfulCommandTakesItsBarDownImmediately() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        let end = start.addingTimeInterval(30)
        policy.commandDidEnd(exitCode: 0, at: end)

        XCTAssertNil(policy.presentation(at: end))
    }

    func testAFailedLongCommandHoldsAnErrorBarBrieflyThenClears() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        let end = start.addingTimeInterval(30)
        policy.commandDidEnd(exitCode: 2, at: end)

        XCTAssertEqual(
            policy.presentation(at: end),
            TerminalCommandProgressPresentation(fill: .fraction(1), tone: .failed)
        )
        XCTAssertEqual(policy.nextPresentationChange(after: end), end.addingTimeInterval(failureLinger))
        XCTAssertNil(policy.presentation(at: end.addingTimeInterval(failureLinger)))
        XCTAssertNil(policy.nextPresentationChange(after: end.addingTimeInterval(failureLinger)))
    }

    /// A failure the user never saw a bar for does not earn one on the way out:
    /// a mistyped command that returns 127 in 20ms must stay silent.
    func testAFastFailureNeverRaisesABar() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        let end = start.addingTimeInterval(0.02)
        policy.commandDidEnd(exitCode: 127, at: end)

        XCTAssertNil(policy.presentation(at: end))
    }

    /// OSC 133 `D` with no status says nothing about the outcome, so it must not
    /// paint one.
    func testAnUnknownExitStatusIsNotTreatedAsAFailure() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        let end = start.addingTimeInterval(30)
        policy.commandDidEnd(exitCode: nil, at: end)

        XCTAssertNil(policy.presentation(at: end))
    }

    func testTheSettingSuppressesEverythingIncludingReportedProgress() {
        var policy = makePolicy(isEnabled: false)
        policy.commandDidStart(at: start)
        policy.didReceive(TerminalCommandProgressReport(state: .set, percent: 50))

        XCTAssertNil(policy.presentation(at: start))
        XCTAssertNil(policy.presentation(at: start.addingTimeInterval(60)))
        XCTAssertNil(policy.nextPresentationChange(after: start))
    }

    func testTurningTheSettingOffTakesDownABarThatIsAlreadyUp() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        let now = start.addingTimeInterval(appearanceDelay)
        XCTAssertNotNil(policy.presentation(at: now))

        policy.isEnabled = false

        XCTAssertNil(policy.presentation(at: now))
    }

    // MARK: - Rendering and reduced motion

    @MainActor
    func testReducedMotionSuppressesTheSweepAnimationEntirely() {
        let layer = CALayer()

        ChromeMotion.startCommandProgressSweep(on: layer, fromX: 0, toX: 100, prefersReducedMotion: true)
        XCTAssertFalse(ChromeMotion.isCommandProgressSweeping(layer))

        ChromeMotion.startCommandProgressSweep(on: layer, fromX: 0, toX: 100, prefersReducedMotion: false)
        XCTAssertTrue(ChromeMotion.isCommandProgressSweeping(layer))

        ChromeMotion.stopCommandProgressSweep(on: layer)
        XCTAssertFalse(ChromeMotion.isCommandProgressSweeping(layer))
    }

    @MainActor
    func testTheSweepRunsOnCoreAnimationAtTheTokenDuration() throws {
        let layer = CALayer()
        ChromeMotion.startCommandProgressSweep(on: layer, fromX: -10, toX: 210, prefersReducedMotion: false)

        let animation = try XCTUnwrap(
            layer.animation(forKey: "dev.kurotty.commandProgress.sweep") as? CABasicAnimation
        )
        XCTAssertEqual(
            animation.duration,
            DesignTokens.Motion.seconds(fromMS: DesignTokens.Motion.commandProgressSweepDurationMS),
            accuracy: 0.0001
        )
        XCTAssertEqual(animation.repeatCount, .greatestFiniteMagnitude)
        XCTAssertEqual(animation.fromValue as? CGFloat, -10)
        XCTAssertEqual(animation.toValue as? CGFloat, 210)
    }

    @MainActor
    func testTheBarSweepsForAnIndeterminateCommandAndStopsWhenItEnds() {
        let view = makeBarView()

        view.handle(.commandStarted)
        view.handle(.reported(TerminalCommandProgressReport(state: .indeterminate, percent: nil)))

        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.presentationForTesting?.fill, .indeterminate)
        XCTAssertTrue(view.isSweepingForTesting)

        view.handle(.commandEnded(exitCode: 0))

        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(view.isSweepingForTesting)
    }

    @MainActor
    func testAReducedMotionBarIsStillShownButNeverAnimates() {
        let view = makeBarView()
        view.prefersReducedMotion = true

        view.handle(.commandStarted)
        view.handle(.reported(TerminalCommandProgressReport(state: .indeterminate, percent: nil)))

        XCTAssertFalse(view.isHidden, "reduced motion quiets the bar, it does not remove the status")
        XCTAssertFalse(view.isSweepingForTesting)
    }

    /// A determinate bar has a real number to show, so it never sweeps — and a
    /// paused one is not moving, which is the whole content of "paused".
    @MainActor
    func testDeterminateAndPausedBarsDoNotSweep() {
        let view = makeBarView()

        view.handle(.commandStarted)
        view.handle(.reported(TerminalCommandProgressReport(state: .set, percent: 50)))
        XCTAssertEqual(view.presentationForTesting?.fill, .fraction(0.5))
        XCTAssertFalse(view.isSweepingForTesting)

        view.handle(.reported(TerminalCommandProgressReport(state: .paused, percent: nil)))
        XCTAssertEqual(view.presentationForTesting?.tone, .paused)
        XCTAssertFalse(view.isSweepingForTesting)
    }

    @MainActor
    func testDisablingTheBarHidesItWhileACommandIsStillRunning() {
        let view = makeBarView()

        view.handle(.commandStarted)
        view.handle(.reported(TerminalCommandProgressReport(state: .set, percent: 50)))
        XCTAssertFalse(view.isHidden)

        view.setEnabled(false)

        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(view.isSweepingForTesting)
    }

    @MainActor
    private func makeBarView() -> TerminalCommandProgressBarView {
        let view = TerminalCommandProgressBarView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 200,
                height: DesignTokens.Component.commandProgressBarHeightPX
            )
        )
        view.prefersReducedMotion = false
        return view
    }

    // MARK: - Setting

    func testTheProgressBarSettingDefaultsOn() {
        XCTAssertTrue(SettingsDefaults.commandProgressIndicatorEnabled)
        XCTAssertTrue(AppSettings.default.terminal.commandProgressIndicatorEnabled)
    }

    /// Files written before schema 19 predate the bar, so the key carries no
    /// user intent and migration lands it on the current default.
    func testSettingsWrittenBeforeSchemaNineteenNormalizeToTheDefault() {
        var settings = AppSettings.default
        settings.schemaVersion = 18
        settings.terminal.commandProgressIndicatorEnabled = false

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertEqual(normalized.schemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertTrue(normalized.terminal.commandProgressIndicatorEnabled)
    }

    func testCurrentSchemaPreservesAnExplicitOffChoice() {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion
        settings.terminal.commandProgressIndicatorEnabled = false

        XCTAssertFalse(AppSettingsNormalizer.normalized(settings).terminal.commandProgressIndicatorEnabled)
    }

    func testDecodingAFileWithoutTheKeyUsesTheDefaultRatherThanFailing() throws {
        let ansiColors = Array(repeating: "\"#000000\"", count: 16).joined(separator: ", ")
        let json = """
        {
          "schemaVersion": 18,
          "terminal": {
            "theme": "Kurotty",
            "fontName": "Menlo",
            "fontSize": 15,
            "scrollbackLines": 10000,
            "colors": {
              "foreground": "#E5E7EB",
              "background": "#22252B",
              "cursor": "#D7C6F4",
              "ansi": [\(ansiColors)]
            }
          },
          "shell": { "workingDirectory": "/tmp" }
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(
            decoded.terminal.commandProgressIndicatorEnabled,
            SettingsDefaults.commandProgressIndicatorEnabled
        )
    }

    func testTheSettingSurvivesAnEncodeDecodeRoundTrip() throws {
        var settings = AppSettings.default
        settings.terminal.commandProgressIndicatorEnabled = false

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertFalse(decoded.terminal.commandProgressIndicatorEnabled)
    }

    func testTheSettingIsDeclaredLiveApplied() {
        XCTAssertEqual(
            AppSettingsValidation.lifecycle(for: .terminalCommandProgressIndicatorEnabled),
            .liveApplied
        )
    }
}
