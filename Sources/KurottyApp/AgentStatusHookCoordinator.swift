import AppKit
import Foundation

/// Owns the hook path: the loopback server, the Claude Code settings entries,
/// and the PTY environment contract.
///
/// Lifecycle contract: one instance, started from app launch and stopped on
/// termination. When `terminal.agentStatusHooksEnabled` is false nothing is
/// started, nothing is installed, and `shellEnvironment(paneIdentifier:)`
/// returns an empty dictionary, so the PTY carries no hook variables at all.
///
/// The setting now defaults to on, which is why the install path runs through
/// `AgentStatusHookConsentPolicy`: a default must never be the reason a file
/// Kurotty does not own gets rewritten. Nothing here writes to
/// `~/.claude/settings.json` until the user has answered once.
///
/// The OSC 9999 channel is independent of this coordinator and always on.
@MainActor
final class AgentStatusHookCoordinator: NSObject {
    static let shared = AgentStatusHookCoordinator()

    private let registry: AgentActivityRegistry
    private let server: AgentStatusHookServer
    private let consentStore: AgentStatusHookConsentStore
    /// Returns true when the user allows the write. Injected so tests never
    /// raise a modal, and so the decision is separable from the presentation.
    private let requestConsent: @MainActor () -> Bool
    private(set) var isEnabled = false
    private(set) var lastDiagnostic: String?

    init(
        registry: AgentActivityRegistry = .shared,
        server: AgentStatusHookServer = AgentStatusHookServer(),
        observesSettingsChanges: Bool = true,
        consentStore: AgentStatusHookConsentStore = .appSettings,
        requestConsent: @escaping @MainActor () -> Bool = AgentStatusHookConsentPrompt.ask
    ) {
        self.registry = registry
        self.server = server
        self.consentStore = consentStore
        self.requestConsent = requestConsent
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

    /// Applies the persisted value once at launch. Separate from the observer
    /// so a first run with the setting already on still starts the listener.
    func applyStoredSetting() {
        let settings = (try? AppSettingsStore.shared.load()) ?? .default
        setEnabled(settings.terminal.agentStatusHooksEnabled, isExplicitUserRequest: false)
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        // Settings only change because someone edited them, so this path is the
        // user asking — unlike `applyStoredSetting`, which is just a launch.
        setEnabled(settings.terminal.agentStatusHooksEnabled, isExplicitUserRequest: true)
    }

    /// Applies the setting. Safe to call repeatedly with the same value.
    ///
    /// Turning it on may do nothing at all: an unanswered or refused consent
    /// leaves the listener stopped and the user's configuration untouched, so
    /// `isEnabled` reports what actually happened rather than what the setting
    /// asked for.
    func setEnabled(
        _ enabled: Bool,
        settingsFileURL: URL? = nil,
        isExplicitUserRequest: Bool = true
    ) {
        guard enabled else {
            guard isEnabled else { return }
            isEnabled = false
            server.stop()
            applyUninstall(settingsFileURL: settingsFileURL)
            return
        }
        guard !isEnabled else { return }

        switch AgentStatusHookConsentPolicy.decision(
            isEnabled: true,
            consent: consentStore.read(),
            hasExistingManagedEntries: hasManagedEntries(settingsFileURL: settingsFileURL),
            isExplicitUserRequest: isExplicitUserRequest
        ) {
        case .leaveConfigurationAlone:
            return
        case .askBeforeInstalling:
            let granted = requestConsent()
            consentStore.record(granted ? .granted : .denied)
            guard granted else { return }
            // Recording posts a settings change, and the observer may have
            // already run this same path to completion before we get here.
            guard !isEnabled else { return }
        case .install:
            break
        }

        isEnabled = true
        startServer()
        applyInstall(settingsFileURL: settingsFileURL)
    }

    /// True when the target file already carries Kurotty's marker, which makes
    /// an install a refresh rather than a first intrusion.
    private func hasManagedEntries(settingsFileURL: URL?) -> Bool {
        let target = settingsFileURL ?? AgentStatusHookInstaller.settingsFileURL()
        guard let data = try? Data(contentsOf: target),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return AgentStatusHookInstaller.containsKurottyEntries(object)
    }

    /// Environment for a PTY spawn. Empty unless hooks are enabled and the
    /// listener is bound.
    func shellEnvironment(paneIdentifier: String) -> [String: String] {
        guard isEnabled else {
            return [:]
        }
        return server.shellEnvironment(paneIdentifier: paneIdentifier)
    }

    private func startServer() {
        // The server callback runs on its own queue. The main-queue hop below is
        // the proof of isolation for touching the main-actor registry.
        server.onReport = { report in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentActivityRegistry.shared.record(
                        report.status,
                        paneIdentifier: report.paneIdentifier
                    )
                }
            }
        }
        server.start { [weak self] result in
            guard case .failure(let error) = result else {
                return
            }
            let description = String(describing: error)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.lastDiagnostic = "Kurotty agent status hooks: listener unavailable (\(description))"
                }
            }
        }
    }

    private func applyInstall(settingsFileURL: URL?) {
        guard case .failure(let error) = AgentStatusHookInstaller.install(at: settingsFileURL) else {
            lastDiagnostic = nil
            return
        }
        lastDiagnostic = error.diagnostic
        NSLog("%@", error.diagnostic)
    }

    private func applyUninstall(settingsFileURL: URL?) {
        guard case .failure(let error) = AgentStatusHookInstaller.uninstall(at: settingsFileURL) else {
            lastDiagnostic = nil
            return
        }
        lastDiagnostic = error.diagnostic
        NSLog("%@", error.diagnostic)
    }
}

/// The modal that asks for hook consent, kept apart from the coordinator so the
/// decision path stays free of AppKit. The path is spelled out in the message
/// because the file being changed is the user's, not Kurotty's.
enum AgentStatusHookConsentPrompt {
    @MainActor
    static func ask() -> Bool {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.agentStatusHookConsentTitle)
        alert.informativeText = AppLocalization.format(
            .agentStatusHookConsentMessage,
            AgentStatusHookInstaller.settingsFileURL().path
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: AppLocalization.string(.agentStatusHookConsentAllow))
        alert.addButton(withTitle: AppLocalization.string(.agentStatusHookConsentDeny))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
