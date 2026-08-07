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
    func testTheMarkIsATemplateImageSoTheMenuBarCanTintIt() {
        XCTAssertTrue(MenuBarExtraGlyph.makeImage().isTemplate)
    }

    func testTheTintedIconFactoryWouldNotProduceATemplateImage() throws {
        // Guards the reason the mark is drawn rather than built through the
        // ordinary chrome icon factory: that factory bakes a palette color in,
        // which clears the template flag and is exactly what a menu-bar glyph
        // must not have. Any symbol shows it; the factory is the subject.
        let tinted = try XCTUnwrap(Icon.symbol(IconSymbol.agent, .regular, tint: .labelColor))

        XCTAssertFalse(tinted.isTemplate)
    }

    // MARK: - The mark reads at menu-bar size

    /// Rasterizes the mark the way the menu bar does — at its own point size,
    /// at a backing scale — and returns per-pixel coverage. A template image is
    /// nothing but coverage, so this is the whole of what the user sees.
    private func markCoverage(scale: Int) throws -> (alpha: (Int, Int) -> CGFloat, side: Int) {
        let image = MenuBarExtraGlyph.makeImage()
        let side = Int(image.size.width) * scale
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        // Bitmap rows run top-down, which is how the mark is authored, so the
        // caller can name features the way they read on screen.
        return ({ x, y in bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }, side)
    }

    /// The mark is a head with two holes in it. If either hole closes, the cat
    /// becomes a blob — which is the failure this whole shape is chosen to
    /// avoid, and the one that a "does it draw at all" test cannot see.
    func testTheEyesAreStillOpenHolesAtMenuBarSize() throws {
        for scale in [1, 2] {
            let (alpha, side) = try markCoverage(scale: scale)
            let row = Int(0.635 * CGFloat(side))

            for (name, centerX) in [("left", 0.315), ("right", 0.685)] as [(String, CGFloat)] {
                let column = Int(centerX * CGFloat(side))
                XCTAssertLessThan(
                    alpha(column, row), 0.1,
                    "\(name) eye is filled in at \(scale)x"
                )
            }
            // The bridge between the eyes and the cheeks either side of them
            // are ink, so the holes read as eyes in a face rather than as a
            // gap in the silhouette.
            XCTAssertGreaterThan(alpha(side / 2, row), 0.9, "bridge between the eyes at \(scale)x")
            XCTAssertGreaterThan(alpha(Int(0.10 * CGFloat(side)), row), 0.9, "left cheek at \(scale)x")
            XCTAssertGreaterThan(alpha(Int(0.90 * CGFloat(side)), row), 0.9, "right cheek at \(scale)x")
        }
    }

    /// Ears are the other half of what makes the silhouette a cat, and they are
    /// the feature a naive extraction from the app icon loses first. Ink at the
    /// two tips, empty between them and in the top corners: that pattern is
    /// only produced by two ears with a notch between them.
    func testTheEarsSurviveWithANotchBetweenThem() throws {
        for scale in [1, 2] {
            let (alpha, side) = try markCoverage(scale: scale)
            let earRow = Int(0.12 * CGFloat(side))

            XCTAssertGreaterThan(alpha(Int(0.225 * CGFloat(side)), earRow), 0.5, "left ear at \(scale)x")
            XCTAssertGreaterThan(alpha(Int(0.775 * CGFloat(side)), earRow), 0.5, "right ear at \(scale)x")
            XCTAssertLessThan(alpha(side / 2, earRow), 0.1, "notch between the ears at \(scale)x")
            XCTAssertLessThan(alpha(0, 0), 0.1, "top-left corner at \(scale)x")
            XCTAssertLessThan(alpha(side - 1, 0), 0.1, "top-right corner at \(scale)x")
        }
    }

    /// The mark fills the square macOS gives it. A mark that quietly drew at
    /// half size would still pass every assertion above.
    func testTheMarkFillsTheBoxMacOSGivesIt() {
        let image = MenuBarExtraGlyph.makeImage()

        XCTAssertEqual(image.size.width, DesignTokens.Component.menuBarExtraMarkSizePT)
        XCTAssertEqual(image.size.height, DesignTokens.Component.menuBarExtraMarkSizePT)
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

    /// On, like every other chrome switch. It stays a switch because it is the
    /// one that borrows a slot in a system-wide bar rather than spending space
    /// inside Kurotty's own window.
    func testTheMenuBarExtraDefaultsOn() {
        // Re-pointed at schema 21, which added `terminal.agentStatusCodexHookConsent`.
        // Re-pointed at schema 22, which added `terminal.promptNavigatorRailEnabled`.
        XCTAssertEqual(SettingsDefaults.schemaVersion, 22)
        XCTAssertTrue(SettingsDefaults.menuBarExtraEnabled)
        XCTAssertTrue(AppSettings.default.terminal.menuBarExtraEnabled)
    }

    /// The flip carries no schema bump. Pinning that here rather than leaving
    /// it implied: adding one would drag every stored `false` back to the new
    /// default, including the ones a user chose.
    func testFlippingTheDefaultDidNotIntroduceANewSchemaVersion() {
        XCTAssertEqual(SettingsDefaults.schemaVersion, 22)
    }

    func testTheKeyIsLiveApplied() {
        XCTAssertEqual(AppSettingsValidation.lifecycle(for: .terminalMenuBarExtraEnabled), .liveApplied)
    }

    /// A file that predates the key records no intent about it, so it lands on
    /// the current default — which is now on, so these installs do gain the
    /// extra.
    func testSettingsWrittenBeforeSchemaTwentyNormalizeToTheCurrentDefault() {
        var settings = AppSettings.default
        settings.schemaVersion = 19
        settings.terminal.menuBarExtraEnabled = false

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertEqual(normalized.schemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertTrue(normalized.terminal.menuBarExtraEnabled)
    }

    func testCurrentSchemaPreservesAnExplicitMenuBarExtraChoice() {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion
        settings.terminal.menuBarExtraEnabled = true

        XCTAssertTrue(AppSettingsNormalizer.normalized(settings).terminal.menuBarExtraEnabled)
    }

    /// The case the flip must not break: a user who turned the extra off keeps
    /// it off across the upgrade that made it default on. Their file is at the
    /// current schema and says `false`, and nothing may drag it back.
    func testAUserWhoTurnedTheExtraOffKeepsItOffAcrossTheDefaultFlip() {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion
        settings.terminal.menuBarExtraEnabled = false

        XCTAssertFalse(AppSettingsNormalizer.normalized(settings).terminal.menuBarExtraEnabled)
    }

    /// The same file arriving from the schema the extra was introduced at, and
    /// from every schema since. `false` is preserved the whole way, so the flip
    /// cannot reach a stored choice through an intermediate version either.
    func testAStoredOffChoiceIsPreservedFromEverySchemaSinceTheKeyExisted() {
        for schemaVersion in 20...SettingsDefaults.schemaVersion {
            var settings = AppSettings.default
            settings.schemaVersion = schemaVersion
            settings.terminal.menuBarExtraEnabled = false

            XCTAssertFalse(
                AppSettingsNormalizer.normalized(settings).terminal.menuBarExtraEnabled,
                "schema \(schemaVersion)"
            )
        }
    }

    /// A fresh install has no file at all, so it never goes through the
    /// normalizer's stored-value path and simply gets the default.
    func testAFreshInstallWithNoStoredValueGetsTheExtra() {
        XCTAssertTrue(AppSettings.default.terminal.menuBarExtraEnabled)
        XCTAssertTrue(AppSettingsNormalizer.normalized(.default).terminal.menuBarExtraEnabled)
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
