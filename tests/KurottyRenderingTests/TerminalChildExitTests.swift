import AppKit
import KurottyCore
import XCTest
@testable import KurottyApp

/// A pane whose shell died used to freeze with no message, no exit code, and no
/// way back. The child exit is now a typed event that drives a banner and the
/// schema-18 setting `terminal.closeOnChildExit`.
final class TerminalChildExitTests: XCTestCase {
    /// Keeps the containers built by `attachedPane(session:)` alive for the
    /// length of a test; a pane whose superview is gone stops reporting.
    private var attachedPaneContainers: [NSView] = []

    override func tearDown() {
        attachedPaneContainers.removeAll()
        super.tearDown()
    }

    // MARK: - waitpid status decoding

    /// `waitpid(2)` packs the exit code into the high byte.
    func testNormalExitDecodesItsCode() {
        XCTAssertEqual(TerminalChildExitStatus(waitpidStatus: 0), .exited(code: 0))
        XCTAssertEqual(TerminalChildExitStatus(waitpidStatus: 1 << 8), .exited(code: 1))
        XCTAssertEqual(TerminalChildExitStatus(waitpidStatus: 127 << 8), .exited(code: 127))
    }

    func testSignalDeathDecodesItsSignalNumber() {
        let sigkill: Int32 = 9
        XCTAssertEqual(TerminalChildExitStatus(waitpidStatus: sigkill), .signalled(signal: sigkill))
    }

    /// The point of keeping two cases: `exit 137` and death by `SIGKILL` share
    /// the shell's single reported number and are still different outcomes.
    func testGenuineExit137IsNotConfusedWithSigkill() {
        let sigkill: Int32 = 9
        let killed = TerminalChildExitStatus(waitpidStatus: sigkill)
        let exitedWith137 = TerminalChildExitStatus(waitpidStatus: 137 << 8)

        XCTAssertEqual(killed.shellExitCode, exitedWith137.shellExitCode)
        XCTAssertNotEqual(killed, exitedWith137)
    }

    func testShellExitCodeAddsTheSignalBase() {
        let sigsegv: Int32 = 11
        XCTAssertEqual(TerminalChildExitStatus.signalled(signal: sigsegv).shellExitCode, 128 + sigsegv)
        XCTAssertEqual(TerminalChildExitStatus.exited(code: 3).shellExitCode, 3)
    }

    func testOnlyAZeroStatusExitIsClean() {
        XCTAssertTrue(TerminalChildExitStatus.exited(code: 0).isCleanExit)
        XCTAssertFalse(TerminalChildExitStatus.exited(code: 1).isCleanExit)
        XCTAssertFalse(TerminalChildExitStatus.signalled(signal: 9).isCleanExit)
    }

    // MARK: - Policy

    func testNeverKeepsThePaneWhateverHappened() {
        for status in Self.allOutcomes {
            XCTAssertEqual(
                TerminalChildExitPolicy.action(mode: .never, status: status),
                .presentBanner,
                "never must keep \(status)"
            )
        }
    }

    func testAlwaysClosesThePaneWhateverHappened() {
        for status in Self.allOutcomes {
            XCTAssertEqual(
                TerminalChildExitPolicy.action(mode: .always, status: status),
                .closePane,
                "always must close \(status)"
            )
        }
    }

    func testOnCleanExitClosesOnlyAfterAZeroStatusExit() {
        XCTAssertEqual(
            TerminalChildExitPolicy.action(mode: .onCleanExit, status: .exited(code: 0)),
            .closePane
        )
        XCTAssertEqual(
            TerminalChildExitPolicy.action(mode: .onCleanExit, status: .exited(code: 1)),
            .presentBanner
        )
        XCTAssertEqual(
            TerminalChildExitPolicy.action(mode: .onCleanExit, status: .signalled(signal: 11)),
            .presentBanner
        )
    }

    /// A crash reports `128 + signal` through the shell convention, and must
    /// still keep the pane so the crash output stays readable.
    func testOnCleanExitKeepsAPaneKilledBySignal() {
        let status = TerminalChildExitStatus(waitpidStatus: 9)

        XCTAssertEqual(TerminalChildExitPolicy.action(mode: .onCleanExit, status: status), .presentBanner)
    }

    // MARK: - Runtime text

    func testRuntimeTextFollowsTheMagnitude() {
        XCTAssertEqual(TerminalChildExitRuntimeText.text(seconds: 0.4), "0.4s")
        XCTAssertEqual(TerminalChildExitRuntimeText.text(seconds: 8), "8s")
        XCTAssertEqual(TerminalChildExitRuntimeText.text(seconds: 125), "2m 05s")
        XCTAssertEqual(TerminalChildExitRuntimeText.text(seconds: 3_780), "1h 03m")
    }

    func testRuntimeTextClampsNegativeClockSkew() {
        XCTAssertEqual(TerminalChildExitRuntimeText.text(seconds: -5), "0.0s")
    }

    // MARK: - Banner copy

    func testBannerTitleSeparatesCleanNonzeroAndSignalOutcomes() {
        let clean = TerminalChildExitBannerText.title(for: .exited(code: 0))
        let failed = TerminalChildExitBannerText.title(for: .exited(code: 2))
        let killed = TerminalChildExitBannerText.title(for: .signalled(signal: 9))

        XCTAssertNotEqual(clean, failed)
        XCTAssertNotEqual(failed, killed)
        XCTAssertTrue(failed.contains("2"), "a nonzero exit must show its code: \(failed)")
        XCTAssertTrue(killed.contains("9"), "a signal death must show its number: \(killed)")
    }

    func testBannerOmitsRuntimeWhenTheSessionKeptNoClock() {
        let withoutClock = TerminalChildExit(status: .exited(code: 0))
        let withClock = TerminalChildExit(status: .exited(code: 0), runtimeSeconds: 8)

        XCTAssertNil(TerminalChildExitBannerText.runtimeDetail(for: withoutClock))
        XCTAssertEqual(
            TerminalChildExitBannerText.runtimeDetail(for: withClock)?.contains("8s"),
            true
        )
    }

    @MainActor
    func testBannerIsHiddenUntilPresentedAndHiddenAgainAfterDismiss() {
        let banner = TerminalChildExitBannerView(frame: .zero)
        XCTAssertTrue(banner.isHidden)

        banner.present(exit: TerminalChildExit(status: .exited(code: 1), runtimeSeconds: 3))
        XCTAssertFalse(banner.isHidden)

        banner.dismiss()
        XCTAssertTrue(banner.isHidden)
    }

    @MainActor
    func testBannerRestartAndCloseActionsReachTheirHandlers() {
        let banner = TerminalChildExitBannerView(frame: .zero)
        var restartCount = 0
        var closeCount = 0
        banner.onRestart = { restartCount += 1 }
        banner.onClose = { closeCount += 1 }

        banner.performRestartForTesting()
        banner.performCloseForTesting()

        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(closeCount, 1)
    }

    // MARK: - Pane wiring

    /// The regression this whole feature exists for: the shell dies and the
    /// pane says nothing. The banner must go up whatever the policy decides,
    /// because the close it asks for can be refused.
    @MainActor
    func testAPaneRaisesTheBannerWhenItsChildProcessEnds() {
        let session = StubSession()
        let pane = attachedPane(session: session)
        XCTAssertFalse(pane.isChildExitBannerVisibleForTesting)

        session.onExit?(TerminalChildExit(status: .exited(code: 1), runtimeSeconds: 12))
        drainMainQueue()

        XCTAssertTrue(pane.isChildExitBannerVisibleForTesting)
    }

    /// The pane never removes itself: it asks its owner, which is what lets a
    /// tab's last pane escalate to closing the tab instead.
    @MainActor
    func testAPaneAsksItsOwnerToCloseAfterACleanExit() {
        let session = StubSession()
        let pane = attachedPane(session: session)
        var closeRequests = 0
        pane.childExitCloseRequested = { _ in closeRequests += 1 }

        session.onExit?(TerminalChildExit(status: .exited(code: 0), runtimeSeconds: 1))
        drainMainQueue()

        // The default mode is `onCleanExit`, and a settings file on the machine
        // running the suite may say otherwise, so this asserts the request is
        // routed rather than pinning a count the user's settings can change.
        XCTAssertEqual(
            closeRequests > 0,
            TerminalChildExitPolicy.action(
                mode: ((try? AppSettingsStore.shared.load()) ?? .default).terminal.closeOnChildExit,
                status: .exited(code: 0)
            ) == .closePane
        )
    }

    // MARK: - Settings schema 18

    func testDefaultModeIsOnCleanExit() {
        // Re-pointed at schema 19, which added `terminal.uiTextScalePercent`;
        // the child-exit default below is unchanged.
        // Schema 21 today; `closeOnChildExit` arrived in 18 and its default is
        // unchanged by the keys added since.
        XCTAssertEqual(SettingsDefaults.schemaVersion, 22)
        XCTAssertEqual(SettingsDefaults.closeOnChildExit, .onCleanExit)
        XCTAssertEqual(AppSettings.default.terminal.closeOnChildExit, .onCleanExit)
    }

    func testTheKeyIsLiveApplied() {
        XCTAssertEqual(AppSettingsValidation.lifecycle(for: .terminalCloseOnChildExit), .liveApplied)
    }

    func testEveryModeSurvivesAnEncodeDecodeRoundTrip() throws {
        for mode in TerminalCloseOnChildExitMode.allCases {
            var settings = AppSettings.default
            settings.terminal.closeOnChildExit = mode

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            let normalized = AppSettingsNormalizer.normalized(decoded)

            XCTAssertEqual(normalized.terminal.closeOnChildExit, mode)
        }
    }

    func testTheModeIsPersistedAsItsRawString() throws {
        var settings = AppSettings.default
        settings.terminal.closeOnChildExit = .always

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let terminal = try XCTUnwrap(object["terminal"] as? [String: Any])

        XCTAssertEqual(terminal["closeOnChildExit"] as? String, "always")
    }

    func testSettingsWithoutTheKeyStillDecode() throws {
        // Files written by an older schema must not fail to decode; they take
        // the current default instead. Built by stripping the key off a real
        // encode so the rest of the document stays valid as the schema grows.
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var terminal = try XCTUnwrap(object["terminal"] as? [String: Any])
        terminal.removeValue(forKey: "closeOnChildExit")
        object["terminal"] = terminal
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let settings = try JSONDecoder().decode(AppSettings.self, from: stripped)

        XCTAssertEqual(settings.terminal.closeOnChildExit, SettingsDefaults.closeOnChildExit)
    }

    /// A typo in a hand-edited settings file must cost the user that one key,
    /// not the whole document — decoding the enum directly would throw and
    /// reset every other setting with it.
    func testAnUnknownModeFallsBackWithoutDiscardingTheRestOfTheFile() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var terminal = try XCTUnwrap(object["terminal"] as? [String: Any])
        terminal["closeOnChildExit"] = "onDinnerTime"
        terminal["fontName"] = "Courier"
        object["terminal"] = terminal
        let edited = try JSONSerialization.data(withJSONObject: object)

        let settings = try JSONDecoder().decode(AppSettings.self, from: edited)

        XCTAssertEqual(settings.terminal.closeOnChildExit, SettingsDefaults.closeOnChildExit)
        XCTAssertEqual(settings.terminal.fontName, "Courier")
    }

    func testPreEighteenFilesMigrateToTheDefault() {
        // A pre-18 file cannot carry user intent for a key that did not exist,
        // so migration lands on the default even if a hand-edited file had one.
        var settings = AppSettings.default
        settings.schemaVersion = 17
        settings.terminal.closeOnChildExit = .always

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertEqual(normalized.schemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertEqual(normalized.terminal.closeOnChildExit, SettingsDefaults.closeOnChildExit)
    }

    func testSchemaEighteenPreservesAnExplicitMode() {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion
        settings.terminal.closeOnChildExit = .never

        XCTAssertEqual(AppSettingsNormalizer.normalized(settings).terminal.closeOnChildExit, .never)
    }

    /// The two close-related settings must not contradict each other: this one
    /// only ever runs after the child has already ended, so it never gates a
    /// close that `confirmCloseRunningProcess` would also want to guard.
    func testTheTwoCloseSettingsAreIndependent() {
        var settings = AppSettings.default
        settings.terminal.confirmCloseRunningProcess = false
        settings.terminal.closeOnChildExit = .never

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertFalse(normalized.terminal.confirmCloseRunningProcess)
        XCTAssertEqual(normalized.terminal.closeOnChildExit, .never)
    }

    // MARK: - Fixtures

    private enum Fixture {
        static let paneFrame = NSRect(x: 0, y: 0, width: 500, height: 200)
        /// The surface reports exits through one `DispatchQueue.main.async` hop
        /// so buffered PTY output lands first; this is how long the test lets
        /// that hop run before asserting.
        static let mainQueueDrainSeconds: TimeInterval = 0.2
    }

    private final class StubSession: TerminalSession {
        var onOutput: ((String) -> Void)?
        var onRawOutput: ((Data) -> Void)?
        var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
        var onExit: ((TerminalChildExit) -> Void)?

        func start(workingDirectory: String) {}
        func write(_ text: String) {}
        func foregroundProcessName() -> String? { nil }
        func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    /// A pane inside a container, because a detached pane deliberately ignores
    /// its child's exit: there is nothing left on screen to explain.
    @MainActor
    private func attachedPane(session: any TerminalSession) -> TerminalPaneView {
        let container = NSView(frame: Fixture.paneFrame)
        let pane = TerminalPaneView(frame: Fixture.paneFrame, session: session)
        container.addSubview(pane)
        attachedPaneContainers.append(container)
        return pane
    }

    private func drainMainQueue() {
        RunLoop.current.run(until: Date().addingTimeInterval(Fixture.mainQueueDrainSeconds))
    }

    private static let allOutcomes: [TerminalChildExitStatus] = [
        .exited(code: 0),
        .exited(code: 1),
        .exited(code: 137),
        .signalled(signal: 9),
        .signalled(signal: 11),
    ]
}
