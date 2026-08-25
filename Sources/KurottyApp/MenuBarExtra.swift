import AppKit

/// What the menu behind the menu-bar icon contains.
///
/// The whole menu is decided here, holding no AppKit state, because the thing
/// that presents it cannot be created in a test: asking `NSStatusBar.system`
/// for a status item takes a real slot in the menu bar of whoever is running
/// the suite. The item set, its order, the selector each row claims, and the
/// object that selector must reach are all answerable without one.
enum MenuBarExtraItem: Equatable, CaseIterable {
    /// The way back into the app, which is the row a menu-bar extra exists for.
    case openApp
    case settings
    case keepMacAwake
    case checkForUpdates
    case separator
    case quit

    /// Which object AppKit must send the selector to.
    ///
    /// Nothing here is left to the responder chain. The menu can be opened
    /// while Kurotty is not the active app, and a row whose target does not
    /// resolve is drawn greyed out rather than failing loudly, so every row
    /// names its target.
    enum ActionTarget: Equatable {
        case appDelegate
        case application
    }

    /// The menu, in order. Quit sits behind a separator so it cannot be hit by
    /// a click that overshot the row above it.
    static let menu: [MenuBarExtraItem] = [
        .openApp,
        .settings,
        .keepMacAwake,
        .checkForUpdates,
        .separator,
        .quit,
    ]

    var isSeparator: Bool { self == .separator }

    /// Three of the four rows reuse the app menu's strings rather than adding a
    /// near-duplicate of "Settings" or "Quit" in three languages; only the way
    /// back into the app is a sentence the app menu has no reason to own.
    var title: String {
        switch self {
        case .openApp:
            return AppLocalization.format(.openApp, AppConstants.Bundle.displayName)
        case .settings:
            return AppLocalization.string(.settings)
        case .keepMacAwake:
            return AppLocalization.string(.keepMacAwake)
        case .checkForUpdates:
            return AppLocalization.string(.checkForUpdates)
        case .separator:
            return ""
        case .quit:
            return AppLocalization.format(.quit, AppConstants.Bundle.displayName)
        }
    }

    /// The same selectors the main menu bar sends, so there is one
    /// implementation of each action rather than a menu-bar copy of it.
    var action: Selector? {
        switch self {
        case .openApp:
            return #selector(AppDelegate.openKurotty)
        case .settings:
            return #selector(AppDelegate.openPreferences)
        case .keepMacAwake:
            return #selector(AppDelegate.toggleKeepMacAwake(_:))
        case .checkForUpdates:
            return #selector(AppDelegate.checkForUpdates(_:))
        case .separator:
            return nil
        case .quit:
            return #selector(NSApplication.terminate(_:))
        }
    }

    var actionTarget: ActionTarget? {
        switch self {
        case .openApp, .settings, .keepMacAwake, .checkForUpdates:
            return .appDelegate
        case .separator:
            return nil
        case .quit:
            return .application
        }
    }
}

/// Turns `MenuBarExtraItem.menu` into the `NSMenu` the status item shows.
enum MenuBarExtraMenuBuilder {
    /// `appDelegate` is taken as `AnyObject` so the menu can be built and
    /// inspected without standing up an `AppDelegate`, which owns an update
    /// controller and a notification server that a test has no business
    /// starting. The selectors are still checked against `AppDelegate` at
    /// compile time by `MenuBarExtraItem.action`.
    @MainActor
    static func makeMenu(
        appDelegate: AnyObject?,
        application: NSApplication,
        keepMacAwakeEnabled: Bool = false
    ) -> NSMenu {
        let menu = NSMenu()
        for item in MenuBarExtraItem.menu {
            menu.addItem(makeMenuItem(
                item,
                appDelegate: appDelegate,
                application: application,
                keepMacAwakeEnabled: keepMacAwakeEnabled
            ))
        }
        return menu
    }

    @MainActor
    private static func makeMenuItem(
        _ item: MenuBarExtraItem,
        appDelegate: AnyObject?,
        application: NSApplication,
        keepMacAwakeEnabled: Bool
    ) -> NSMenuItem {
        guard !item.isSeparator else {
            return .separator()
        }
        // No key equivalents: the main menu bar already owns Cmd+, and Cmd+Q,
        // and a second claim on either would be a duplicate the user sees in
        // two places.
        let menuItem = NSMenuItem(title: item.title, action: item.action, keyEquivalent: "")
        menuItem.target = target(for: item, appDelegate: appDelegate, application: application)
        if item == .keepMacAwake {
            menuItem.state = keepMacAwakeEnabled ? .on : .off
        }
        return menuItem
    }

    @MainActor
    static func target(
        for item: MenuBarExtraItem,
        appDelegate: AnyObject?,
        application: NSApplication
    ) -> AnyObject? {
        switch item.actionTarget {
        case .appDelegate:
            return appDelegate
        case .application:
            return application
        case nil:
            return nil
        }
    }
}

/// The mark the extra shows.
enum MenuBarExtraGlyph {
    /// Always a template image. macOS tints a template for the bar it is in and
    /// inverts it while the menu is held open; a non-template glyph keeps one
    /// fixed color through all of that, which is the single most common way a
    /// menu-bar icon ends up invisible or inverted for half the users.
    ///
    /// Non-optional, unlike every SF Symbol call site in the app: the mark is a
    /// path this app draws, so there is no name for the system to fail to
    /// resolve and no failure for a caller to handle.
    static func makeImage() -> NSImage {
        let side = DesignTokens.Component.menuBarExtraMarkSizePT
        // The drawing handler, not a one-off bitmap: AppKit re-runs it for the
        // backing scale of whichever display the bar is on, so the mark is
        // resolution-independent instead of a 2x asset upscaled onto a 3x panel.
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            // Any opaque colour would do — a template keeps only coverage — but
            // black is what the mark looks like if something ever renders it
            // without honouring the flag.
            NSColor.black.setFill()
            MenuBarExtraMark.path(in: bounds).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    static var accessibilityDescription: String {
        AppLocalization.format(.menuBarExtraAccessibility, AppConstants.Bundle.displayName)
    }
}
