import AppKit
import XCTest
@testable import KurottyApp

final class TerminalWindowControllerSettingsTests: XCTestCase {
    private enum Fixture {
        static let offCenterOrigin = NSPoint(x: 123, y: 145)
        static let windowWidthDeltaPX: Double = 96
    }

    @MainActor
    private func makeController() -> TerminalWindowController {
        let session = TmuxPaneSession(
            writeHandler: { _ in },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        return TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: session),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
    }

    @MainActor
    private func postSettingsChange(_ settings: AppSettings) {
        NotificationCenter.default.post(
            name: AppSettingsStore.didChangeNotification,
            object: AppSettingsStore.shared,
            userInfo: [AppSettingsStore.notificationSettingsKey: settings]
        )
    }

    @MainActor
    private func loadedSettings() -> AppSettings {
        (try? AppSettingsStore.shared.load()) ?? .default
    }

    @MainActor
    func testThemeAndFontSettingsChangeDoesNotResizeOrRecenterWindow() throws {
        let controller = makeController()
        // Leaked controllers keep observing global notifications (settings,
        // tmux activation) and destabilize unrelated suites in the same
        // process, so every test must close its window deterministically.
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(Fixture.offCenterOrigin)
        let frameBeforeChange = window.frame

        var settings = loadedSettings()
        settings.terminal.fontSize += 1
        settings.terminal.theme = TerminalThemePreset.customName
        postSettingsChange(settings)

        XCTAssertEqual(
            window.frame,
            frameBeforeChange,
            "color/theme/font edits must not resize or move the window"
        )
    }

    @MainActor
    func testWindowSizeSettingsChangeResizesWindow() throws {
        let controller = makeController()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)

        var settings = loadedSettings()
        settings.window.width += Fixture.windowWidthDeltaPX
        postSettingsChange(settings)

        XCTAssertEqual(
            Double(window.contentRect(forFrameRect: window.frame).width),
            settings.window.width,
            accuracy: 0.5,
            "a window-size settings change must still apply the configured size"
        )
    }

    @MainActor
    func testRepeatedUnchangedWindowSettingsDoNotMoveWindow() throws {
        let controller = makeController()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)

        var settings = loadedSettings()
        settings.window.width += Fixture.windowWidthDeltaPX
        postSettingsChange(settings)

        window.setFrameOrigin(Fixture.offCenterOrigin)
        let frameAfterFirstApply = window.frame

        // Same window settings again (e.g. a color edit later): no re-center.
        settings.terminal.theme = TerminalThemePreset.customName
        postSettingsChange(settings)

        XCTAssertEqual(window.frame, frameAfterFirstApply)
    }
}
