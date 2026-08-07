import AppKit
import Foundation

/// Owns the hook path: the loopback server, the per-agent hook entries, and the
/// PTY environment contract.
///
/// Lifecycle contract: one instance, started from app launch and stopped on
/// termination. When `terminal.agentStatusHooksEnabled` is false nothing is
/// started, nothing is installed, and `shellEnvironment(paneIdentifier:)`
/// returns an empty dictionary, so the PTY carries no hook variables at all.
///
/// The setting now defaults to on, which is why the install path runs through
/// `AgentStatusHookConsentPolicy`: a default must never be the reason a file
/// Kurotty does not own gets rewritten. Nothing here writes to an agent's
/// configuration until the user has answered for that agent.
///
/// The OSC 9999 channel is independent of this coordinator and always on.
@MainActor
final class AgentStatusHookCoordinator: NSObject {
    static let shared = AgentStatusHookCoordinator()

    private let registry: AgentActivityRegistry
    private let server: AgentStatusHookServer
    private let consentStore: AgentStatusHookConsentStore
    /// Returns true when the user allows the write into that agent's file.
    /// Injected so tests never raise a modal, and so the decision is separable
    /// from the presentation.
    private let requestConsent: @MainActor (AgentStatusHookTarget) -> Bool
    /// Where the agent configuration files are looked up. Injected rather than
    /// resolved per call because the settings observer reaches `setEnabled`
    /// without arguments, and a test that could not redirect it would write into
    /// the real `~/.claude` and `~/.codex`.
    private let homeDirectory: URL
    /// Recording an answer saves Kurotty's settings, which posts a change the
    /// observer turns straight back into `setEnabled`. Re-entering mid-pass
    /// would put the same question twice, so a nested call is dropped and the
    /// pass already running finishes the job.
    private var isApplyingSetting = false
    private(set) var isEnabled = false
    private(set) var lastDiagnostic: String?

    init(
        registry: AgentActivityRegistry = .shared,
        server: AgentStatusHookServer = AgentStatusHookServer(),
        observesSettingsChanges: Bool = true,
        consentStore: AgentStatusHookConsentStore = .appSettings,
        requestConsent: @escaping @MainActor (AgentStatusHookTarget) -> Bool = AgentStatusHookConsentPrompt.ask,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.registry = registry
        self.server = server
        self.consentStore = consentStore
        self.requestConsent = requestConsent
        self.homeDirectory = homeDirectory
        super.init()
        guard observesSettingsChanges else {
            return
        }
        // Scoped to Kurotty's own store, like every other settings observer in
        // the app. An unscoped registration would let anything in the process
        // that posts this name trigger a write into the user's agent
        // configuration; only the store has the standing to say the setting
        // changed.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: AppSettingsStore.shared
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
        // Live-apply belongs to a running app. Outside one there is no user to
        // put the consent question to and no session the install serves, and
        // this broadcast is reachable by anything in the process — a unit test
        // exercising another observer of the same notification will otherwise
        // rewrite the developer's own `~/.claude` and block on a modal nobody
        // can answer.
        guard NSApplication.shared.isRunning else {
            return
        }
        // Settings only change because someone edited them, so this path is the
        // user asking — unlike `applyStoredSetting`, which is just a launch.
        setEnabled(settings.terminal.agentStatusHooksEnabled, isExplicitUserRequest: true)
    }

    /// Applies the setting. Safe to call repeatedly with the same value.
    ///
    /// Turning it on may do nothing at all: an unanswered or refused consent
    /// leaves the listener stopped and that agent's configuration untouched, so
    /// `isEnabled` reports what actually happened rather than what the setting
    /// asked for. It becomes true when at least one agent was installed.
    func setEnabled(
        _ enabled: Bool,
        isExplicitUserRequest: Bool = true
    ) {
        guard !isApplyingSetting else { return }
        isApplyingSetting = true
        defer { isApplyingSetting = false }

        guard enabled else {
            guard isEnabled else { return }
            isEnabled = false
            server.stop()
            applyToEachTarget { target, fileURL in
                AgentStatusHookInstaller.uninstall(for: target, at: fileURL)
            }
            return
        }
        guard !isEnabled else { return }

        var permittedTargets: [AgentStatusHookTarget] = []
        var wasAnythingRefused = false
        for target in AgentStatusHookTarget.allCases where target.isInstallable(homeDirectory: homeDirectory) {
            switch AgentStatusHookConsentPolicy.decision(
                isEnabled: true,
                consent: consentStore.read(target),
                hasExistingManagedEntries: hasManagedEntries(for: target),
                isExplicitUserRequest: isExplicitUserRequest
            ) {
            case .leaveConfigurationAlone:
                continue
            case .askBeforeInstalling:
                let granted = requestConsent(target)
                consentStore.record(target, granted ? .granted : .denied)
                guard granted else {
                    wasAnythingRefused = true
                    continue
                }
            case .install:
                break
            }
            permittedTargets.append(target)
        }

        guard !permittedTargets.isEmpty else {
            if wasAnythingRefused {
                consentStore.disableHooksSetting()
            }
            return
        }

        isEnabled = true
        startServer()
        var diagnostics: [String] = []
        for target in permittedTargets {
            guard case .failure(let error) = AgentStatusHookInstaller.install(
                for: target,
                at: configurationFileURL(for: target)
            ) else {
                continue
            }
            diagnostics.append(error.diagnostic)
            NSLog("%@", error.diagnostic)
        }
        lastDiagnostic = diagnostics.isEmpty ? nil : diagnostics.joined(separator: "; ")
    }

    /// True when the agent's file already carries Kurotty's marker, which makes
    /// an install a refresh rather than a first intrusion.
    private func hasManagedEntries(for target: AgentStatusHookTarget) -> Bool {
        guard let data = try? Data(contentsOf: configurationFileURL(for: target)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return AgentStatusHookInstaller.containsKurottyEntries(object)
    }

    private func configurationFileURL(for target: AgentStatusHookTarget) -> URL {
        AgentStatusHookInstaller.configurationFileURL(for: target, homeDirectory: homeDirectory)
    }

    private func applyToEachTarget(
        _ body: (AgentStatusHookTarget, URL) -> Result<Void, AgentStatusHookInstaller.InstallError>
    ) {
        var diagnostics: [String] = []
        for target in AgentStatusHookTarget.allCases {
            guard case .failure(let error) = body(target, configurationFileURL(for: target)) else {
                continue
            }
            diagnostics.append(error.diagnostic)
            NSLog("%@", error.diagnostic)
        }
        lastDiagnostic = diagnostics.isEmpty ? nil : diagnostics.joined(separator: "; ")
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

}

/// The modal that asks for hook consent, kept apart from the coordinator so the
/// decision path stays free of AppKit. The agent and the exact path are spelled
/// out because the file being changed is the user's, not Kurotty's — and
/// because the answer is recorded for that agent only.
enum AgentStatusHookConsentPrompt {
    @MainActor
    static func ask(for target: AgentStatusHookTarget) -> Bool {
        let alert = NSAlert()
        alert.messageText = AppLocalization.format(.agentStatusHookConsentTitle, target.productName)
        alert.informativeText = AppLocalization.format(
            .agentStatusHookConsentMessage,
            AgentStatusHookInstaller.configurationFileURL(for: target).path
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: AppLocalization.string(.agentStatusHookConsentAllow))
        alert.addButton(withTitle: AppLocalization.string(.agentStatusHookConsentDeny))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
