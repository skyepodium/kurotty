import AppKit

/// Hosts the read-only transcript viewer in its own window.
///
/// Presentation choice: a center editor tab would be the better home, but the
/// editor-tab mechanism lives in `TerminalWindowEditorTabs.swift`. Until that
/// integration lands, one window per session keeps the viewer usable and keeps
/// the transcript code free of any terminal-window coupling. The single
/// integration point is `AgentSessionTranscriptPresenter.present`.
@MainActor
final class AgentSessionTranscriptWindowController: NSWindowController {
    /// Strings and sizes that belong in `AppLocalization`/`DesignTokens` once
    /// this wave's file ownership split ends.
    private enum Copy {
        static let windowTitleSeparator = " — "
    }

    private enum Metric {
        static let defaultWidthPX: CGFloat = 720
        static let defaultHeightPX: CGFloat = 640
        static let minimumWidthPX: CGFloat = 420
        static let minimumHeightPX: CGFloat = 320
    }

    let transcriptView: AgentSessionTranscriptView

    init(record: AgentSessionRecord, chromeTheme: DesignTokens.ChromeTheme = .dark) {
        let controller = AgentSessionTranscriptController(record: record)
        transcriptView = AgentSessionTranscriptView(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Metric.defaultWidthPX,
                height: Metric.defaultHeightPX
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = record.title + Copy.windowTitleSeparator + record.agent.displayName
        window.minSize = NSSize(width: Metric.minimumWidthPX, height: Metric.minimumHeightPX)
        window.contentView = transcriptView
        window.appearance = chromeTheme.windowAppearance
        window.isReleasedWhenClosed = false
        super.init(window: window)
        transcriptView.applyChromeTheme(chromeTheme)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Keeps one viewer per session and fronts an existing one instead of opening
/// duplicates.
///
/// The presenter is an instance, not a singleton: whichever object owns the
/// agent-session sidebar owns the presenter and drops it with the sidebar.
@MainActor
final class AgentSessionTranscriptPresenter {
    private var controllersBySessionKey: [String: AgentSessionTranscriptWindowController] = [:]
    private var chromeTheme = DesignTokens.ChromeTheme.dark

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        for controller in controllersBySessionKey.values {
            controller.window?.appearance = theme.windowAppearance
            controller.transcriptView.applyChromeTheme(theme)
        }
    }

    /// A session is identified by agent plus id, so the same id from two agents
    /// opens two viewers.
    static func sessionKey(for record: AgentSessionRecord) -> String {
        "\(record.agent.rawValue)/\(record.sessionID)"
    }

    @discardableResult
    func present(record: AgentSessionRecord) -> AgentSessionTranscriptWindowController {
        let key = Self.sessionKey(for: record)
        if let existing = controllersBySessionKey[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = AgentSessionTranscriptWindowController(record: record, chromeTheme: chromeTheme)
        controllersBySessionKey[key] = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.controllersBySessionKey.removeValue(forKey: key)
            }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    var openSessionKeysForTesting: Set<String> {
        Set(controllersBySessionKey.keys)
    }
}
