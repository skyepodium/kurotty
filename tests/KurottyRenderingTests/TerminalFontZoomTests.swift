import XCTest
@testable import KurottyApp
@testable import KurottyCore

final class TerminalFontZoomTests: XCTestCase {
    private let minimumPT = SettingsDefaults.minimumTerminalFontSizePT
    private let maximumPT = SettingsDefaults.maximumTerminalFontSizePT

    func testIncreaseAndDecreaseMoveOneStepFromTheCurrentSize() {
        XCTAssertEqual(
            TerminalFontZoom.fontSizePT(applying: .increase, currentPT: 15, configuredPT: 15),
            15 + TerminalFontZoom.stepPT
        )
        XCTAssertEqual(
            TerminalFontZoom.fontSizePT(applying: .decrease, currentPT: 15, configuredPT: 15),
            15 - TerminalFontZoom.stepPT
        )
    }

    func testZoomStopsAtTheConfiguredBoundsInsteadOfRunningPastThem() {
        XCTAssertEqual(
            TerminalFontZoom.fontSizePT(applying: .increase, currentPT: maximumPT, configuredPT: 15),
            maximumPT
        )
        XCTAssertEqual(
            TerminalFontZoom.fontSizePT(applying: .decrease, currentPT: minimumPT, configuredPT: 15),
            minimumPT
        )
    }

    func testRepeatedPressesAtTheBoundReverseImmediatelyRatherThanUnwindingSlack() {
        var sizePT = maximumPT
        for _ in 0..<10 {
            sizePT = TerminalFontZoom.fontSizePT(applying: .increase, currentPT: sizePT, configuredPT: 15)
        }
        XCTAssertEqual(sizePT, maximumPT)

        sizePT = TerminalFontZoom.fontSizePT(applying: .decrease, currentPT: sizePT, configuredPT: 15)
        XCTAssertEqual(sizePT, maximumPT - TerminalFontZoom.stepPT)
    }

    func testResetReturnsToTheConfiguredSizeRegardlessOfTheCurrentOne() {
        XCTAssertEqual(
            TerminalFontZoom.fontSizePT(applying: .reset, currentPT: 32, configuredPT: 13),
            13
        )
        XCTAssertEqual(
            TerminalFontZoom.fontSizePT(applying: .reset, currentPT: minimumPT, configuredPT: 13),
            13
        )
    }

    func testAnOutOfRangeConfiguredSizeIsClampedByEveryStepIncludingReset() {
        XCTAssertEqual(
            TerminalFontZoom.fontSizePT(applying: .reset, currentPT: 15, configuredPT: 400),
            maximumPT
        )
        XCTAssertEqual(
            TerminalFontZoom.fontSizePT(applying: .increase, currentPT: 1, configuredPT: 15),
            minimumPT + TerminalFontZoom.stepPT
        )
        XCTAssertEqual(
            TerminalFontZoom.fontSizePT(applying: .decrease, currentPT: 400, configuredPT: 15),
            maximumPT - TerminalFontZoom.stepPT
        )
    }

    @MainActor
    func testCoordinatorLayersTheZoomOverTheConfiguredSizeWithoutWritingItBack() {
        var configuredFontSizePT = 15.0
        let coordinator = TerminalFontZoomCoordinator { configuredFontSizePT }

        XCTAssertEqual(coordinator.fontSizePT(configuredFontSizePT: configuredFontSizePT), 15)

        coordinator.apply(.increase)
        coordinator.apply(.increase)
        XCTAssertEqual(coordinator.fontSizePT(configuredFontSizePT: configuredFontSizePT), 17)
        XCTAssertEqual(configuredFontSizePT, 15, "the zoom must never write back into the configured size")

        coordinator.apply(.reset)
        XCTAssertEqual(coordinator.fontSizePT(configuredFontSizePT: configuredFontSizePT), 15)
    }

    @MainActor
    func testEditingTheConfiguredSizeInPreferencesWinsOverAnActiveZoom() {
        var configuredFontSizePT = 15.0
        let coordinator = TerminalFontZoomCoordinator { configuredFontSizePT }

        coordinator.apply(.increase)
        XCTAssertEqual(coordinator.fontSizePT(configuredFontSizePT: configuredFontSizePT), 16)

        configuredFontSizePT = 20
        XCTAssertEqual(coordinator.fontSizePT(configuredFontSizePT: configuredFontSizePT), 20)
    }

    @MainActor
    func testTheCoordinatorOnlyNotifiesWhenTheResolvedSizeActuallyMoves() {
        let coordinator = TerminalFontZoomCoordinator { SettingsDefaults.maximumTerminalFontSizePT }
        var changeCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: TerminalFontZoomCoordinator.didChangeNotification,
            object: coordinator,
            queue: nil
        ) { _ in changeCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.apply(.increase)
        XCTAssertEqual(changeCount, 0, "already at the maximum, so nothing changed")

        coordinator.apply(.decrease)
        XCTAssertEqual(changeCount, 1)

        coordinator.apply(.reset)
        XCTAssertEqual(changeCount, 2)

        coordinator.apply(.reset)
        XCTAssertEqual(changeCount, 2, "resetting an unzoomed terminal is a no-op")
    }
}
