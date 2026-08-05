import AppKit
import XCTest
@testable import KurottyApp
@testable import KurottyCore

/// Closing a tab or window used to kill every child process silently — Cmd+W
/// with ssh, vim, or a build running lost work with no warning. Closing now
/// consults `TerminalCloseConfirmation` first, gated by the schema-17 setting
/// `terminal.confirmCloseRunningProcess`.
final class TerminalCloseConfirmationTests: XCTestCase {
    // MARK: - Decision logic

    func testIdleShellNeedsNoConfirmation() {
        let decision = TerminalCloseConfirmation.decision(
            isEnabled: true,
            shellProcessIdentifiers: [100],
            childProcessLister: { _ in [] },
            processNameResolver: { _ in nil }
        )
        XCTAssertFalse(decision.needsConfirmation)
    }

    func testRunningChildNeedsConfirmationWithItsName() {
        let decision = TerminalCloseConfirmation.decision(
            isEnabled: true,
            shellProcessIdentifiers: [100],
            childProcessLister: { pid in pid == 100 ? [200] : [] },
            processNameResolver: { pid in pid == 200 ? "vim" : nil }
        )
        XCTAssertTrue(decision.needsConfirmation)
        XCTAssertEqual(decision.processNames, ["vim"])
    }

    func testDisabledSettingSkipsEvenWithRunningChildren() {
        let decision = TerminalCloseConfirmation.decision(
            isEnabled: false,
            shellProcessIdentifiers: [100],
            childProcessLister: { _ in [200] },
            processNameResolver: { _ in "vim" }
        )
        XCTAssertFalse(decision.needsConfirmation)
    }

    func testUnreadableChildNameStillConfirmsWithPlaceholder() {
        // A process whose name cannot be read is still a running process;
        // hiding it would skip the confirmation exactly when the process is
        // unusual enough to resist inspection.
        let decision = TerminalCloseConfirmation.decision(
            isEnabled: true,
            shellProcessIdentifiers: [100],
            childProcessLister: { _ in [200] },
            processNameResolver: { _ in nil }
        )
        XCTAssertTrue(decision.needsConfirmation)
        XCTAssertEqual(decision.processNames, [TerminalCloseConfirmation.fallbackProcessName])
    }

    func testNamesAreDedupedAcrossPanesAndOrderIsFirstSeen() {
        let decision = TerminalCloseConfirmation.decision(
            isEnabled: true,
            shellProcessIdentifiers: [100, 101],
            childProcessLister: { pid in pid == 100 ? [200, 201] : [202] },
            processNameResolver: { pid in
                switch pid {
                case 200: return "ssh"
                case 201: return "vim"
                case 202: return "ssh"
                default: return nil
                }
            }
        )
        XCTAssertEqual(decision.processNames, ["ssh", "vim"])
    }

    func testInvalidShellPidsAreSkippedBeforeAnyProcessCall() {
        var listedPids: [pid_t] = []
        _ = TerminalCloseConfirmation.decision(
            isEnabled: true,
            shellProcessIdentifiers: [0, -1],
            childProcessLister: { pid in
                listedPids.append(pid)
                return []
            },
            processNameResolver: { _ in nil }
        )
        XCTAssertTrue(listedPids.isEmpty)
    }

    func testDisplayedProcessListIsCapped() {
        let names = ["a", "b", "c", "d", "e", "f"]
        let displayed = TerminalCloseConfirmation.displayedProcessList(names)
        XCTAssertEqual(
            displayed,
            names.prefix(TerminalCloseConfirmation.maximumDisplayedProcessNameCount)
                .joined(separator: ", ")
        )
    }

    // MARK: - Live process reading

    func testLiveChildOfAShellIsDetectedAndNamed() throws {
        // A real `sh` running a real `sleep`: `sh` stands in for the pane's
        // shell, so its child is exactly what the guard must find. The
        // trailing `:` keeps `sh` from exec-ing the single command, which
        // would leave no child at all.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 30; :"]
        try shell.run()
        defer { shell.terminate() }

        let deadline = Date().addingTimeInterval(5)
        var names: [String] = []
        while Date() < deadline {
            names = TerminalCloseConfirmation.runningProcessNames(
                shellProcessIdentifiers: [shell.processIdentifier]
            )
            if !names.isEmpty { break }
            usleep(50_000)
        }
        XCTAssertEqual(names, ["sleep"])
    }

    func testShellWithNoChildrenReportsNoRunningProcesses() throws {
        // `sleep` itself never forks, so as a stand-in shell it must read as
        // idle: no children, no confirmation.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sleep")
        shell.arguments = ["30"]
        try shell.run()
        defer { shell.terminate() }

        let names = TerminalCloseConfirmation.runningProcessNames(
            shellProcessIdentifiers: [shell.processIdentifier]
        )
        XCTAssertEqual(names, [])
    }

    // MARK: - Window wiring

    func testWindowControllerAnswersWindowShouldClose() {
        // `performClose` (last-tab Cmd+W, the red traffic light) only consults
        // the guard if the delegate implements `windowShouldClose`.
        XCTAssertTrue(
            TerminalWindowController.instancesRespond(
                to: #selector(NSWindowDelegate.windowShouldClose(_:))
            )
        )
    }

    func testTabClosePathsConsultTheCloseGuard() throws {
        // Source-shape guard: both tab-close entry points (Cmd+W with several
        // tabs, the tab bar's close button) must ask before `closeTab`.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/KurottyApp/TerminalWindowController.swift"),
            encoding: .utf8
        )
        let guardedCloseCount = source.components(
            separatedBy: "confirmCloseIfRunningProcess(shellProcessIdentifiers:"
        ).count - 1
        XCTAssertEqual(guardedCloseCount, 2)
    }

    // MARK: - Settings schema 17

    func testDefaultIsOn() {
        XCTAssertTrue(SettingsDefaults.confirmCloseRunningProcess)
        XCTAssertTrue(AppSettings.default.terminal.confirmCloseRunningProcess)
    }

    func testSchemaVersionIsSeventeen() {
        XCTAssertEqual(SettingsDefaults.schemaVersion, 17)
    }

    func testSettingsWithoutTheKeyStillDecode() throws {
        // Files written by an older schema must not fail to decode; they take
        // the current default instead. Built by stripping the key off a real
        // encode so the rest of the document stays valid as the schema grows.
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var terminal = try XCTUnwrap(object["terminal"] as? [String: Any])
        terminal.removeValue(forKey: "confirmCloseRunningProcess")
        object["terminal"] = terminal
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let settings = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertEqual(
            settings.terminal.confirmCloseRunningProcess,
            SettingsDefaults.confirmCloseRunningProcess
        )
    }

    func testPreSeventeenFilesMigrateToTheDefault() {
        // A pre-17 file cannot carry user intent for a key that did not exist,
        // so migration lands on the default even if a hand-edited file had it.
        var settings = AppSettings.default
        settings.schemaVersion = 16
        settings.terminal.confirmCloseRunningProcess = false

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertEqual(normalized.schemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertTrue(normalized.terminal.confirmCloseRunningProcess)
    }

    func testSchemaSeventeenPreservesAnExplicitOff() throws {
        var settings = AppSettings.default
        settings.terminal.confirmCloseRunningProcess = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        let normalized = AppSettingsNormalizer.normalized(decoded)

        XCTAssertFalse(normalized.terminal.confirmCloseRunningProcess)
    }
}
