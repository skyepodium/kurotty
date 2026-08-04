import AppKit

/// Standalone window hosting `QuickCommandsEditorView`.
///
/// Owned by `QuickCommandsEditorPresenter` for the app lifetime once opened;
/// the controller releases the window on close and the presenter clears its
/// reference, so no window or view outlives its use.
@MainActor
final class QuickCommandsEditorWindowController: NSWindowController, NSWindowDelegate {
    private let editorView: QuickCommandsEditorView
    private var onClose: (() -> Void)?

    init(store: QuickCommandStore = .shared, onClose: (() -> Void)? = nil) {
        editorView = QuickCommandsEditorView(store: store)
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DesignTokens.Component.quickCommandEditorWidthPX,
                height: DesignTokens.Component.quickCommandEditorHeightPX
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppLocalization.string(.quickCommandsEditorTitle)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let theme = DesignTokens.ChromeTheme.theme(
            for: (try? AppSettingsStore.shared.load()) ?? .default
        )
        window.appearance = theme.windowAppearance
        editorView.applyChromeTheme(theme)
        editorView.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView = window.contentView else {
            return
        }
        contentView.addSubview(editorView)
        NSLayoutConstraint.activate([
            editorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: contentView.topAnchor),
            editorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // The store debounces saves; force the pending write so a command the
        // user just typed is durable even if the app quits right after.
        QuickCommandStore.shared.saveImmediately()
        onClose?()
        onClose = nil
    }
}

/// Single retained presenter for the quick-command editor window.
///
/// Lifecycle contract: at most one editor window exists; reopening focuses the
/// existing one, and closing clears the reference.
@MainActor
enum QuickCommandsEditorPresenter {
    private static var controller: QuickCommandsEditorWindowController?

    static var isPresented: Bool {
        controller != nil
    }

    static func presentQuickCommandsEditor() {
        if let controller {
            controller.present()
            return
        }
        let controller = QuickCommandsEditorWindowController(
            store: .shared,
            onClose: { Self.controller = nil }
        )
        Self.controller = controller
        controller.present()
    }
}

/// Menu-item target for the quick-command surfaces.
///
/// `MainMenu` builds items against `@objc` selectors on an owner object; this
/// class exists so the menu item can be added without this feature editing
/// `AppDelegate` or `MainMenu`. See the integration notes: the menu item's
/// target should be `QuickCommandsMenuActionTarget.shared`.
@MainActor
final class QuickCommandsMenuActionTarget: NSObject {
    static let shared = QuickCommandsMenuActionTarget()

    @objc func showQuickCommandsEditor(_ sender: Any?) {
        QuickCommandsEditorPresenter.presentQuickCommandsEditor()
    }
}
