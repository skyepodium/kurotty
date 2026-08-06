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
    private let sweepCeiling: TimeInterval = 60

    private func makePolicy(isEnabled: Bool = true) -> TerminalCommandProgressPolicy {
        TerminalCommandProgressPolicy(
            isEnabled: isEnabled,
            appearanceDelaySeconds: appearanceDelay,
            failureLingerSeconds: failureLinger,
            sweepCeilingSeconds: sweepCeiling
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
            TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running, motion: .sweeping)
        )
    }

    /// An indeterminate command has exactly two one-shot wake-ups ahead of it and
    /// no repeating timer: the bar becoming due, then its sweep hitting the
    /// ceiling.
    func testTheScheduledWakeUpsAreTheBarBecomingDueThenTheCeiling() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)

        XCTAssertEqual(
            policy.nextPresentationChange(after: start),
            start.addingTimeInterval(appearanceDelay)
        )
        XCTAssertEqual(
            policy.nextPresentationChange(after: start.addingTimeInterval(appearanceDelay)),
            start.addingTimeInterval(sweepCeiling)
        )
        XCTAssertNil(
            policy.nextPresentationChange(after: start.addingTimeInterval(sweepCeiling)),
            "past the ceiling nothing further is pending, so nothing may wake up"
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
            TerminalCommandProgressPresentation(fill: .fraction(0.25), tone: .running, motion: .still)
        )
        XCTAssertNil(policy.nextPresentationChange(after: start))
    }

    func testReportedStatesMapToTheirTones() {
        let cases: [(TerminalCommandProgressReport, TerminalCommandProgressPresentation)] = [
            (
                TerminalCommandProgressReport(state: .error, percent: 40),
                TerminalCommandProgressPresentation(fill: .fraction(0.4), tone: .failed, motion: .still)
            ),
            (
                TerminalCommandProgressReport(state: .paused, percent: 60),
                TerminalCommandProgressPresentation(fill: .fraction(0.6), tone: .paused, motion: .still)
            ),
            (
                TerminalCommandProgressReport(state: .indeterminate, percent: 60),
                TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running, motion: .sweeping)
            ),
            (
                TerminalCommandProgressReport(state: .set, percent: nil),
                TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running, motion: .sweeping)
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
            TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running, motion: .sweeping)
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
            TerminalCommandProgressPresentation(fill: .fraction(1), tone: .failed, motion: .still)
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

    // MARK: - Interactive programs

    /// The bug this section exists for: an interactive program emits OSC 133 `C`
    /// when the shell launches it and no `D` until the user quits, so the
    /// elapsed-time bar would sweep for the whole session.
    func testEnteringTheAlternateScreenTakesTheBarDown() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        XCTAssertNotNil(policy.presentation(at: start.addingTimeInterval(appearanceDelay)))

        policy.alternateScreenDidActivate()

        XCTAssertNil(policy.presentation(at: start.addingTimeInterval(appearanceDelay)))
        XCTAssertNil(policy.presentation(at: start.addingTimeInterval(3_600)))
        XCTAssertNil(
            policy.nextPresentationChange(after: start),
            "a bar that is never coming back has nothing to wake up for"
        )
    }

    /// Nobody types at a batch job they are waiting on. This is the signal that
    /// covers inline TUIs, which never take the alternate screen at all.
    func testAKeystrokeDuringACommandTakesTheBarDown() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        XCTAssertNotNil(policy.presentation(at: start.addingTimeInterval(appearanceDelay)))

        policy.userDidInteract()

        XCTAssertNil(policy.presentation(at: start.addingTimeInterval(appearanceDelay)))
        XCTAssertNil(policy.presentation(at: start.addingTimeInterval(3_600)))
    }

    /// A program the user has started driving does not stop being one because it
    /// went quiet for a while.
    func testInteractivityLatchesForTheRestOfTheCommandSpan() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        policy.userDidInteract()
        policy.didReceive(TerminalCommandProgressReport(state: .indeterminate, percent: nil))

        XCTAssertNil(
            policy.presentation(at: start.addingTimeInterval(10)),
            "an indeterminate report is still only the claim the user can already see"
        )
    }

    /// The signals belong to one command span. The next prompt starts clean, or
    /// one `vim` would mute every build for the rest of the session.
    func testTheNextCommandGetsItsBarBack() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        policy.alternateScreenDidActivate()
        policy.commandDidEnd(exitCode: 0, at: start.addingTimeInterval(600))

        let next = start.addingTimeInterval(700)
        policy.commandDidStart(at: next)

        XCTAssertEqual(
            policy.presentation(at: next.addingTimeInterval(appearanceDelay)),
            TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running, motion: .sweeping)
        )
    }

    /// A percentage is information the pane does not otherwise carry, so it
    /// outlives the signal that removes a bar which only ever said "working".
    func testADeterminatePercentageSurvivesBothInteractivitySignals() {
        for signal in [
            TerminalCommandProgressEvent.alternateScreenEntered,
            TerminalCommandProgressEvent.userDidInteract,
        ] {
            var policy = makePolicy()
            policy.commandDidStart(at: start)
            policy.didReceive(TerminalCommandProgressReport(state: .set, percent: 40))
            switch signal {
            case .alternateScreenEntered:
                policy.alternateScreenDidActivate()
            default:
                policy.userDidInteract()
            }

            XCTAssertEqual(
                policy.presentation(at: start.addingTimeInterval(3_600)),
                TerminalCommandProgressPresentation(fill: .fraction(0.4), tone: .running, motion: .still),
                "\(signal) must not discard a reported percentage"
            )
        }
    }

    /// A failure the user never saw a bar for does not earn one on the way out,
    /// and an interactive program's bar is exactly that: `vim` quit with `:cq`
    /// must not flash red.
    func testAnInteractiveCommandThatExitsNonZeroDoesNotFlashAFailureBar() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        policy.alternateScreenDidActivate()
        let end = start.addingTimeInterval(600)

        policy.commandDidEnd(exitCode: 1, at: end)

        XCTAssertNil(policy.presentation(at: end))
    }

    // MARK: - Sweep ceiling

    /// Past the ceiling the bar stops claiming that progress is happening right
    /// now. It does not leave: without an OSC 133 `D` Kurotty does not know the
    /// command ended, and a bar that vanished on a timer would be saying it did.
    func testTheSweepCeilingStopsTheMotionAndKeepsTheBar() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)

        XCTAssertEqual(
            policy.presentation(at: start.addingTimeInterval(sweepCeiling - 0.01)),
            TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running, motion: .sweeping)
        )
        XCTAssertEqual(
            policy.presentation(at: start.addingTimeInterval(sweepCeiling)),
            TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running, motion: .still)
        )
        XCTAssertEqual(
            policy.presentation(at: start.addingTimeInterval(3_600)),
            TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running, motion: .still)
        )
    }

    /// A producer repeating "I am working" forever is the same forever-sweep the
    /// elapsed-time rule produces, so the ceiling applies to it too.
    func testAReportedIndeterminateStateIsAlsoCapped() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        policy.didReceive(TerminalCommandProgressReport(state: .indeterminate, percent: nil))

        XCTAssertEqual(policy.presentation(at: start)?.motion, .sweeping)
        XCTAssertEqual(policy.presentation(at: start.addingTimeInterval(sweepCeiling))?.motion, .still)
    }

    /// A percentage carries real information for as long as the producer keeps
    /// sending it, and it has no motion to withdraw in the first place.
    func testADeterminateReportIsNotSubjectToTheCeiling() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)
        policy.didReceive(TerminalCommandProgressReport(state: .set, percent: 70))

        let expected = TerminalCommandProgressPresentation(
            fill: .fraction(0.7),
            tone: .running,
            motion: .still
        )
        XCTAssertEqual(policy.presentation(at: start.addingTimeInterval(sweepCeiling)), expected)
        XCTAssertEqual(policy.presentation(at: start.addingTimeInterval(86_400)), expected)
        XCTAssertNil(
            policy.nextPresentationChange(after: start),
            "a determinate bar changes when the producer says so, not on a timer"
        )
    }

    /// The regression this whole change risks: a real batch command must still
    /// raise a real sweeping bar.
    func testAnOrdinarySlowCommandStillRaisesASweepingBar() {
        var policy = makePolicy()
        policy.commandDidStart(at: start)

        XCTAssertNil(policy.presentation(at: start))
        XCTAssertEqual(
            policy.presentation(at: start.addingTimeInterval(appearanceDelay)),
            TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running, motion: .sweeping)
        )
        XCTAssertEqual(
            policy.presentation(at: start.addingTimeInterval(30))?.motion,
            .sweeping,
            "half a minute into a build the sweep is still doing its job"
        )
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

    /// The view must route both take-down events into the policy, not just hold
    /// them: a sweeping bar has a live `CABasicAnimation` that has to be removed.
    @MainActor
    func testEachInteractivitySignalTakesDownASweepingBarView() {
        for signal in [
            TerminalCommandProgressEvent.alternateScreenEntered,
            TerminalCommandProgressEvent.userDidInteract,
        ] {
            let view = makeBarView()
            view.handle(.commandStarted)
            view.handle(.reported(TerminalCommandProgressReport(state: .indeterminate, percent: nil)))
            XCTAssertTrue(view.isSweepingForTesting, "\(signal) needs a sweeping bar to take down")

            view.handle(signal)

            XCTAssertTrue(view.isHidden, "\(signal) must take the bar down")
            XCTAssertFalse(view.isSweepingForTesting, "\(signal) must stop the animation")
        }
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

    // MARK: - Surface signals

    /// The surface is where the two take-down signals actually originate, so
    /// they are asserted from real PTY bytes and a real keystroke rather than
    /// from a hand-made event.
    private final class StubSession: TerminalSession {
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

    private enum SurfaceFixture {
        static let frame = NSRect(x: 0, y: 0, width: 500, height: 120)
        static let enterAlternateScreen = "\u{1b}[?1049h"
        static let leaveAlternateScreen = "\u{1b}[?1049l"
        static let typedCharacter = "y"
    }

    @MainActor
    private func makeSurface() -> (TerminalSurfaceView, () -> [TerminalCommandProgressEvent]) {
        let surface = TerminalSurfaceView(frame: SurfaceFixture.frame, session: StubSession())
        var events: [TerminalCommandProgressEvent] = []
        surface.onCommandProgress = { events.append($0) }
        return (surface, { events })
    }

    @MainActor
    func testTheSurfaceReportsAlternateScreenEntryOnceOnTheRisingEdge() {
        let (surface, events) = makeSurface()

        surface.consumeTmuxRestoreOutputForTesting(Data(SurfaceFixture.enterAlternateScreen.utf8))
        surface.consumeTmuxRestoreOutputForTesting(Data("drawing".utf8))

        XCTAssertEqual(events(), [.alternateScreenEntered])
    }

    /// Only the transition into the alternate screen is a signal. Leaving it is
    /// the program handing the pane back, which raises nothing.
    @MainActor
    func testLeavingTheAlternateScreenReportsNothing() {
        let (surface, events) = makeSurface()
        surface.consumeTmuxRestoreOutputForTesting(Data(SurfaceFixture.enterAlternateScreen.utf8))

        surface.consumeTmuxRestoreOutputForTesting(Data(SurfaceFixture.leaveAlternateScreen.utf8))

        XCTAssertEqual(events(), [.alternateScreenEntered])
    }

    @MainActor
    func testOrdinaryOutputReportsNoInteractivitySignal() {
        let (surface, events) = makeSurface()

        surface.consumeTmuxRestoreOutputForTesting(Data("building...\r\nstill building\r\n".utf8))

        XCTAssertEqual(events(), [])
    }

    @MainActor
    func testTypedTextReportsUserInteractionButProtocolTrafficDoesNot() {
        let (surface, events) = makeSurface()

        // A device-status query the program asked for: the surface answers on
        // the same PTY, and that answer is not the user doing anything.
        surface.consumeTmuxRestoreOutputForTesting(Data("\u{1b}[6n".utf8))
        XCTAssertEqual(events(), [], "a synthesized reply is not user input")

        surface.sendText(SurfaceFixture.typedCharacter)

        XCTAssertEqual(events(), [.userDidInteract])
    }

    // MARK: - Pane layout

    /// The bar sits on the pane's top edge as the user sees it — below the
    /// header, above the terminal grid — and the extra height must not push it
    /// into either neighbour.
    @MainActor
    func testTheBarSitsOnTheTerminalTopEdgeWithoutTouchingTheHeaderOrSearchBar() {
        let pane = TerminalPaneView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            session: StubSession()
        )
        pane.showSearch()
        pane.layoutSubtreeIfNeeded()

        let (progressBar, searchBar, terminal) = pane.topOverlayFramesForTesting

        XCTAssertEqual(progressBar.height, DesignTokens.Component.commandProgressBarHeightPX)
        XCTAssertEqual(progressBar.width, terminal.width, "the bar spans the pane's terminal")
        // Unflipped AppKit coordinates: the top edge is `maxY`.
        XCTAssertEqual(progressBar.maxY, terminal.maxY, "the bar hangs off the terminal's top edge")
        XCTAssertLessThanOrEqual(
            terminal.maxY,
            pane.bounds.maxY,
            "the terminal, and therefore the bar, starts below the pane header"
        )
        XCTAssertFalse(
            searchBar.isEmpty,
            "an unlaid-out search bar would make the overlap assertion vacuous"
        )
        XCTAssertLessThanOrEqual(
            searchBar.maxY,
            progressBar.minY,
            "the search bar clears the bar entirely rather than overlapping it"
        )
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
