import Foundation

/// Owns the opt-in hook path: the loopback server, the Claude Code settings
/// entries, and the PTY environment contract.
///
/// Lifecycle contract: one instance, started from app launch and stopped on
/// termination. When `terminal.agentStatusHooksEnabled` is false nothing is
/// started, nothing is installed, and `shellEnvironment(paneIdentifier:)`
/// returns an empty dictionary, so the PTY carries no hook variables at all.
///
/// The OSC 9999 channel is independent of this coordinator and always on.
@MainActor
final class AgentStatusHookCoordinator: NSObject {
    static let shared = AgentStatusHookCoordinator()

    private let registry: AgentActivityRegistry
    private let server: AgentStatusHookServer
    private(set) var isEnabled = false
    private(set) var lastDiagnostic: String?

    init(
        registry: AgentActivityRegistry = .shared,
        server: AgentStatusHookServer = AgentStatusHookServer(),
        observesSettingsChanges: Bool = true
    ) {
        self.registry = registry
        self.server = server
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
        setEnabled(settings.terminal.agentStatusHooksEnabled)
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        setEnabled(settings.terminal.agentStatusHooksEnabled)
    }

    /// Applies the setting. Safe to call repeatedly with the same value.
    func setEnabled(_ enabled: Bool, settingsFileURL: URL? = nil) {
        guard isEnabled != enabled else {
            return
        }
        isEnabled = enabled
        guard enabled else {
            server.stop()
            applyUninstall(settingsFileURL: settingsFileURL)
            return
        }
        startServer()
        applyInstall(settingsFileURL: settingsFileURL)
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
