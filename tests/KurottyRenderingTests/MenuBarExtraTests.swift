import AppKit
import KurottyCore
import XCTest

@testable import KurottyApp

/// The menu-bar extra: what its menu contains, where each row's action goes,
/// whether the mark can be tinted by the bar it lands in, and the on/off
/// lifecycle of the slot itself.
///
/// Nothing here touches `NSStatusBar`. Asking the real one for a status item
/// would take a slot in the menu bar of whoever runs the suite, so the
/// controller is driven through `MenuBarExtraSlot` and every decision it makes
/// is recorded rather than drawn.
@MainActor
final class MenuBarExtraTests: XCTestCase {
    /// Stands in for the app delegate so the menu's targets can be checked
    /// without constructing one — a real `AppDelegate` owns an update
    /// controller and a notification bridge server.
    private final class ActionTargetStub: NSObject {}

    private final class RecordingSlot: MenuBarExtraSlot {
        private(set) var presentCount = 0
        private(set) var dismissCount = 0
        private(set) var presentedImage: NSImage?
        private(set) var presentedMenu: NSMenu?
        private(set) var presentedAccessibilityDescription: String?
        private(set) var isPresented = false

        func present(image: NSImage?, menu: NSMenu, accessibilityDescription: String) {
            presentCount += 1
            presentedImage = image
            presentedMenu = menu
            presentedAccessibilityDescription = accessibilityDescription
            isPresented = true
        }

        func dismiss() {
            dismissCount += 1
            isPresented = false
        }
    }

    private func makeController(
        slot: RecordingSlot,
        actionTarget: AnyObject
    ) -> MenuBarExtraController {
        // Settings observation off: these tests drive `setEnabled` directly, and
        // an observer would also react to any other suite that saves settings.
        MenuBarExtraController(
            actionTarget: actionTarget,
            slot: slot,
            application: .shared,
            observesSettingsChanges: false
        )
    }

    private func makeMenu(target: AnyObject) -> NSMenu {
        MenuBarExtraMenuBuilder.makeMenu(appDelegate: target, application: .shared)
    }

    // MARK: - Item set and order

    func testTheMenuIsTheFourOrcaRowsWithQuitBehindASeparator() {
        XCTAssertEqual(
            MenuBarExtraItem.menu,
            [.openApp, .settings, .checkForUpdates, .separator, .quit]
        )
    }

    func testEveryDeclaredItemAppearsInTheMenu() {
        // A case added to the enum but never placed in the menu would otherwise
        // look wired up while being unreachable.
        XCTAssertEqual(Set(MenuBarExtraItem.menu), Set(MenuBarExtraItem.allCases))
    }

    func testBuiltMenuHasOneRowPerItemInTheSameOrder() {
        let menu = makeMenu(target: ActionTargetStub())

        XCTAssertEqual(menu.items.count, MenuBarExtraItem.menu.count)
        XCTAssertEqual(
            menu.items.map(\.isSeparatorItem),
            MenuBarExtraItem.menu.map(\.isSeparator)
        )
    }

    func testOnlyTheQuitRowIsPrecededByASeparator() {
        let menu = makeMenu(target: ActionTargetStub())
        let separatorIndexes = menu.items.indices.filter { menu.items[$0].isSeparatorItem }

        XCTAssertEqual(separatorIndexes, [MenuBarExtraItem.menu.count - 2])
    }

    // MARK: - Titles

    func testEveryVisibleRowIsTitledFromLocalizationRatherThanLeftBlank() {
        let menu = makeMenu(target: ActionTargetStub())

        for item in menu.items where !item.isSeparatorItem {
            XCTAssertFalse(item.title.isEmpty)
        }
    }

    func testTheOpenRowNamesTheApp() {
        // The one row with a string of its own; the other three reuse the app
        // menu's, which `AppLocalizationTests` already covers in all three
        // languages.
        XCTAssertTrue(MenuBarExtraItem.openApp.title.contains(AppConstants.Bundle.displayName))
        XCTAssertNotEqual(MenuBarExtraItem.openApp.title, L10nKey.openApp.rawValue)
    }

    func testTheReusedRowsCarryExactlyTheAppMenusStrings() {
        XCTAssertEqual(MenuBarExtraItem.settings.title, AppLocalization.string(.settings))
        XCTAssertEqual(MenuBarExtraItem.checkForUpdates.title, AppLocalization.string(.checkForUpdates))
        XCTAssertEqual(
            MenuBarExtraItem.quit.title,
            AppLocalization.format(.quit, AppConstants.Bundle.displayName)
        )
    }

    // MARK: - Routing

    func testEachRowClaimsTheActionItsTitleImplies() {
        XCTAssertEqual(MenuBarExtraItem.openApp.action, #selector(AppDelegate.openKurotty))
        XCTAssertEqual(MenuBarExtraItem.settings.action, #selector(AppDelegate.openPreferences))
        XCTAssertEqual(MenuBarExtraItem.checkForUpdates.action, #selector(AppDelegate.checkForUpdates(_:)))
        XCTAssertEqual(MenuBarExtraItem.quit.action, #selector(NSApplication.terminate(_:)))
        XCTAssertNil(MenuBarExtraItem.separator.action)
    }

    /// The selector existing is not the same as something answering it: a
    /// renamed or removed method leaves the row permanently greyed out.
    func testEveryActionIsImplementedByTheObjectItIsSentTo() {
        for item in MenuBarExtraItem.menu {
            guard let action = item.action else {
                XCTAssertTrue(item.isSeparator)
                continue
            }
            switch item.actionTarget {
            case .appDelegate:
                XCTAssertTrue(AppDelegate.instancesRespond(to: action), "\(item)")
            case .application:
                XCTAssertTrue(NSApplication.instancesRespond(to: action), "\(item)")
            case nil:
                XCTFail("\(item) has an action but no target")
            }
        }
    }

    /// Explicit targets, not the responder chain: the menu opens while Kurotty
    /// may be inactive, and an unresolved target is a greyed-out row.
    func testAppActionsTargetTheAppDelegateAndQuitTargetsTheApplication() {
        let target = ActionTargetStub()
        let menu = makeMenu(target: target)
        let rows = zip(MenuBarExtraItem.menu, menu.items)

        for (item, row) in rows {
            switch item.actionTarget {
            case .appDelegate:
                XCTAssertTrue(row.target === target, "\(item)")
            case .application:
                XCTAssertTrue(row.target === NSApplication.shared, "\(item)")
            case nil:
                XCTAssertTrue(row.isSeparatorItem)
            }
        }
    }

    func testNoRowClaimsAKeyEquivalentTheMainMenuAlreadyOwns() {
        let menu = makeMenu(target: ActionTargetStub())

        XCTAssertEqual(menu.items.map(\.keyEquivalent), Array(repeating: "", count: menu.items.count))
    }

    // MARK: - The mark

    /// The single most common way a menu-bar icon looks broken: a non-template
    /// image keeps one fixed color, so it vanishes on a bar of that color and
    /// stays wrong while the menu is held open.
    func testTheMarkIsATemplateImageSoTheMenuBarCanTintIt() throws {
        let image = try XCTUnwrap(MenuBarExtraGlyph.makeImage())

        XCTAssertTrue(image.isTemplate)
    }

    func testTheTintedIconFactoryWouldNotProduceATemplateImage() throws {
        // Guards the reason `Icon.templateSymbol` exists at all: the tinted
        // factory bakes a palette color in, which is exactly what a menu-bar
        // glyph must not have.
        let tinted = try XCTUnwrap(
            Icon.symbol(IconSymbol.menuBarExtra, .regular, tint: .labelColor)
        )

        XCTAssertFalse(tinted.isTemplate)
    }

    func testThePresentedMarkIsTheTemplateOneAndNotStrippedOnTheWayThrough() {
        let slot = RecordingSlot()
        let controller = makeController(slot: slot, actionTarget: ActionTargetStub())

        controller.setEnabled(true)

        XCTAssertEqual(slot.presentedImage?.isTemplate, true)
    }

    func testThePresentedSlotCarriesAnAccessibilityLabelNamingTheApp() {
        let slot = RecordingSlot()
        let controller = makeController(slot: slot, actionTarget: ActionTargetStub())

        controller.setEnabled(true)

        XCTAssertEqual(
            slot.presentedAccessibilityDescription?.contains(AppConstants.Bundle.displayName),
            true
        )
    }

    // MARK: - Enable and disable lifecycle

    func testTheSlotIsNotTakenUntilTheSettingTurnsItOn() {
        let slot = RecordingSlot()
        _ = makeController(slot: slot, actionTarget: ActionTargetStub())

        XCTAssertEqual(slot.presentCount, 0)
        XCTAssertFalse(slot.isPresented)
    }

    func testTurningItOffRemovesTheSlotAndTurningItOnRestoresIt() {
        let slot = RecordingSlot()
        let controller = makeController(slot: slot, actionTarget: ActionTargetStub())

        controller.setEnabled(true)
        XCTAssertTrue(controller.isPresented)

        controller.setEnabled(false)
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(slot.dismissCount, 1)

        controller.setEnabled(true)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(slot.presentCount, 2)
    }

    /// Two slots would be two Kurotty icons in the bar, and only one of them
    /// would ever be removed again.
    func testEnablingTwiceRefreshesTheSlotInPlaceRatherThanTakingASecondOne() {
        let slot = RecordingSlot()
        let controller = makeController(slot: slot, actionTarget: ActionTargetStub())

        controller.setEnabled(true)
        let firstMenu = slot.presentedMenu
        controller.setEnabled(true)

        XCTAssertTrue(slot.isPresented)
        XCTAssertEqual(slot.dismissCount, 0)
        XCTAssertNotIdentical(slot.presentedMenu, firstMenu)
    }

    func testDisablingWhileAlreadyOffLeavesTheBarAlone() {
        let slot = RecordingSlot()
        let controller = makeController(slot: slot, actionTarget: ActionTargetStub())

        controller.setEnabled(false)

        XCTAssertEqual(slot.presentCount, 0)
        XCTAssertFalse(slot.isPresented)
    }

    func testALanguageSwitchRebuildsTheMenuOnlyWhileTheExtraIsShowing() {
        let slot = RecordingSlot()
        let controller = makeController(slot: slot, actionTarget: ActionTargetStub())

        controller.refreshLocalization()
        XCTAssertEqual(slot.presentCount, 0)

        controller.setEnabled(true)
        controller.refreshLocalization()
        XCTAssertEqual(slot.presentCount, 2)
    }

    // MARK: - Settings schema 20

    /// Off, unlike every other chrome switch. The others govern space inside
    /// Kurotty's own window; this one borrows a slot in a system-wide bar, and
    /// Kurotty is a normal Dock app, so nothing it offers is otherwise
    /// unreachable.
    func testTheMenuBarExtraDefaultsOff() {
        // Re-pointed at schema 21, which added `terminal.agentStatusCodexHookConsent`.
        XCTAssertEqual(SettingsDefaults.schemaVersion, 22)
        XCTAssertFalse(SettingsDefaults.menuBarExtraEnabled)
        XCTAssertFalse(AppSettings.default.terminal.menuBarExtraEnabled)
    }

    func testTheKeyIsLiveApplied() {
        XCTAssertEqual(AppSettingsValidation.lifecycle(for: .terminalMenuBarExtraEnabled), .liveApplied)
    }

    func testSettingsWrittenBeforeSchemaTwentyNormalizeToTheCurrentDefault() {
        var settings = AppSettings.default
        settings.schemaVersion = 19
        settings.terminal.menuBarExtraEnabled = true

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertEqual(normalized.schemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertEqual(normalized.terminal.menuBarExtraEnabled, SettingsDefaults.menuBarExtraEnabled)
    }

    func testCurrentSchemaPreservesAnExplicitMenuBarExtraChoice() {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion
        settings.terminal.menuBarExtraEnabled = true

        XCTAssertTrue(AppSettingsNormalizer.normalized(settings).terminal.menuBarExtraEnabled)
    }

    func testTheChoiceSurvivesAnEncodeDecodeRoundTrip() throws {
        for isEnabled in [true, false] {
            var settings = AppSettings.default
            settings.terminal.menuBarExtraEnabled = isEnabled

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

            XCTAssertEqual(decoded.terminal.menuBarExtraEnabled, isEnabled)
        }
    }

    func testDecodingASettingsFileWithoutTheMenuBarExtraKeyUsesTheDefault() throws {
        let json = """
        {
          "schemaVersion": 19,
          "terminal": {
            "theme": "kurotty",
            "fontName": "Menlo",
            "fontSize": 15,
            "scrollbackLines": 10000,
            "colors": {
              "foreground": "#E5E7EB",
              "background": "#22252B",
              "cursor": "#D7C6F4",
              "ansi": \(defaultAnsiJSON())
            }
          },
          "window": { "width": 1100, "height": 720 },
          "shell": { "workingDirectory": "/tmp" }
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.terminal.menuBarExtraEnabled, SettingsDefaults.menuBarExtraEnabled)
    }

    private func defaultAnsiJSON() -> String {
        let quoted = TerminalColorDefaults.ansiHex.map { "\"\($0)\"" }
        return "[\(quoted.joined(separator: ","))]"
    }
}
