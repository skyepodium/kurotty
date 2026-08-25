import AppKit

/// The slot the extra occupies in the system menu bar.
///
/// A protocol rather than a direct `NSStatusItem` because there is no harmless
/// way to exercise the real one: `NSStatusBar.system.statusItem(withLength:)`
/// takes an actual slot in the menu bar of whoever is running the process, and
/// a suite that leaks one leaves an icon behind. The lifecycle the tests care
/// about — present once, remove on demand, restore afterwards — is entirely
/// expressible here.
@MainActor
protocol MenuBarExtraSlot: AnyObject {
    var isPresented: Bool { get }
    func present(image: NSImage?, menu: NSMenu, accessibilityDescription: String)
    func dismiss()
}

/// The real slot.
///
/// Ownership contract: exactly one, owned by `MenuBarExtraController`, which is
/// owned by the app delegate for the life of the process. The `NSStatusItem` is
/// created on the first `present` and handed back to `NSStatusBar` on
/// `dismiss`, so a disabled setting leaves no slot allocated at all rather than
/// a zero-width one.
@MainActor
final class SystemMenuBarExtraSlot: MenuBarExtraSlot {
    private var statusItem: NSStatusItem?

    var isPresented: Bool { statusItem != nil }

    func present(image: NSImage?, menu: NSMenu, accessibilityDescription: String) {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = image
        item.button?.setAccessibilityLabel(accessibilityDescription)
        // The menu, not a click action: with a menu attached AppKit opens it on
        // mouse-down and handles highlighting and dismissal, which is what makes
        // the extra behave like every other one in the bar.
        item.menu = menu
    }

    func dismiss() {
        guard let statusItem else {
            return
        }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }
}

/// Owns Kurotty's menu-bar extra and keeps it in step with
/// `terminal.menuBarExtraEnabled`.
///
/// Lifecycle contract: one instance, created at launch and held by the app
/// delegate. The setting is live-applied, so turning it on adds the slot at
/// once and turning it off gives it back; nothing waits for a relaunch. The
/// setting defaults on, so the common path at launch takes a slot; a user who
/// turns it off gets it handed back to `NSStatusBar` rather than kept at zero
/// width, so the app leaves nothing behind in a bar it does not own.
///
/// This deliberately does not set `LSUIElement`. The extra is an addition to a
/// normal Dock app, not a conversion into a menu-bar-only one, so the Dock icon
/// and the main menu bar stay exactly as they were.
@MainActor
final class MenuBarExtraController: NSObject {
    private let slot: MenuBarExtraSlot
    private let application: NSApplication
    /// Weak: the app delegate owns this controller, and the menu's rows point
    /// back at the delegate.
    private weak var actionTarget: AnyObject?
    private var isEnabled = false
    private var keepMacAwakeEnabled = false

    init(
        actionTarget: AnyObject?,
        slot: MenuBarExtraSlot = SystemMenuBarExtraSlot(),
        application: NSApplication = .shared,
        observesSettingsChanges: Bool = true
    ) {
        self.actionTarget = actionTarget
        self.slot = slot
        self.application = application
        super.init()
        guard observesSettingsChanges else {
            return
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isPresented: Bool { slot.isPresented }

    /// Applies the persisted value once at launch, before any settings change
    /// has been posted. Separate from the observer for the same reason
    /// `AgentStatusHookCoordinator` keeps the two apart: a first run with the
    /// setting already on has nothing to observe yet.
    func applyStoredSetting() {
        let settings = (try? AppSettingsStore.shared.load()) ?? .default
        setEnabled(settings.terminal.menuBarExtraEnabled)
    }

    /// Safe to call repeatedly with the same value: an already-present slot is
    /// refreshed in place rather than exchanged for a second one, which would
    /// leave two Kurotty icons in the bar.
    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        guard isEnabled else {
            slot.dismiss()
            return
        }
        presentSlot()
    }

    /// Rebuilds the menu after a language switch. A no-op while the extra is
    /// off, so a user who never enabled it cannot make one appear by changing
    /// languages.
    func refreshLocalization() {
        guard isEnabled else {
            return
        }
        presentSlot()
    }

    func setKeepMacAwakeEnabled(_ isEnabled: Bool) {
        keepMacAwakeEnabled = isEnabled
        refreshLocalization()
    }

    private func presentSlot() {
        slot.present(
            image: MenuBarExtraGlyph.makeImage(),
            menu: MenuBarExtraMenuBuilder.makeMenu(
                appDelegate: actionTarget,
                application: application,
                keepMacAwakeEnabled: keepMacAwakeEnabled
            ),
            accessibilityDescription: MenuBarExtraGlyph.accessibilityDescription
        )
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        setEnabled(settings.terminal.menuBarExtraEnabled)
    }
}
