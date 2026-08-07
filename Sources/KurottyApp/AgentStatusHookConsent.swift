import Foundation
import KurottyCore

/// The user's one-time answer to editing one agent's hook configuration.
///
/// Recorded per agent rather than once for all of them. The prompt names the
/// exact file it is about, so an answer about `~/.claude/settings.json` is not
/// an answer about `~/.codex/hooks.json` — and a machine that gains Codex a
/// year later would otherwise have its configuration written on the strength of
/// a yes given about a different program's file.
///
/// Stored as a raw string in Kurotty's settings file, like `terminal.theme`: an
/// unreadable value must not make the document undecodable, and it falls back to
/// `unasked` because the safe reading of a damaged record is "nobody said yes".
enum AgentStatusHookConsent: String, CaseIterable, Equatable {
    /// The question has never been put to the user.
    case unasked
    /// The user allowed Kurotty to manage its hook entries.
    case granted
    /// The user declined. Kurotty never asks again and never writes.
    case denied

    static let `default` = AgentStatusHookConsent(
        rawValue: SettingsDefaults.agentStatusHookConsent
    ) ?? .unasked

    static func parse(_ rawValue: String) -> AgentStatusHookConsent? {
        AgentStatusHookConsent(
            rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}

/// Stands between `terminal.agentStatusHooksEnabled` being on and Kurotty
/// writing into a file it does not own.
///
/// The setting defaults to on, so without this the first launch of a fresh
/// install would silently rewrite the user's agent configuration. The setting
/// states intent; consent decides whether that intent may touch the file. Pure
/// so the whole matrix is testable without a modal or a home directory.
enum AgentStatusHookConsentPolicy {
    enum Decision: Equatable {
        /// Install now: consent is on record, or Kurotty's entries are already
        /// in the file and this is a refresh rather than a first intrusion.
        case install
        /// Ask the user before the first write.
        case askBeforeInstalling
        /// Leave the user's configuration exactly as it is.
        case leaveConfigurationAlone
    }

    /// - Parameter hasExistingManagedEntries: whether the file already carries
    ///   Kurotty's marker. Users who enabled hooks before consent existed are
    ///   already installed, so re-asking them would be a question about a
    ///   decision they made long ago.
    /// - Parameter isExplicitUserRequest: `true` when the user just turned the
    ///   setting on, `false` when Kurotty is applying the stored value at
    ///   launch. A past refusal silences the launch path forever, but it must
    ///   not make the Preferences checkbox a dead switch: someone who asks for
    ///   hooks again gets asked again.
    static func decision(
        isEnabled: Bool,
        consent: AgentStatusHookConsent,
        hasExistingManagedEntries: Bool,
        isExplicitUserRequest: Bool = false
    ) -> Decision {
        guard isEnabled else {
            return .leaveConfigurationAlone
        }
        if hasExistingManagedEntries {
            return .install
        }
        switch consent {
        case .granted:
            return .install
        case .denied:
            return isExplicitUserRequest ? .askBeforeInstalling : .leaveConfigurationAlone
        case .unasked:
            return .askBeforeInstalling
        }
    }
}

/// Reads and records the answers through Kurotty's own settings file, the same
/// store every other user choice lives in. Injected as closures so tests can
/// exercise the coordinator without touching Application Support.
///
/// `disableHooksSetting` is separate from `record` because whether the visible
/// checkbox should go off is not a fact about one agent's answer: it is only
/// true once no agent on this machine will be written to at all. The coordinator
/// knows which agents are installed, so it makes that call.
struct AgentStatusHookConsentStore {
    var read: (AgentStatusHookTarget) -> AgentStatusHookConsent
    var record: (AgentStatusHookTarget, AgentStatusHookConsent) -> Void
    var disableHooksSetting: () -> Void

    @MainActor
    static let appSettings = AgentStatusHookConsentStore(
        read: { target in
            let settings = (try? AppSettingsStore.shared.load()) ?? .default
            return settings.terminal.agentStatusHookConsentChoice(for: target)
        },
        record: { target, consent in
            guard var settings = try? AppSettingsStore.shared.load() else {
                return
            }
            settings.terminal.setAgentStatusHookConsent(consent, for: target)
            try? AppSettingsStore.shared.save(settings)
        },
        disableHooksSetting: {
            // Leaving the toggle on while every agent write is refused would
            // show a checkbox that does nothing — and a refusal silences the
            // launch path forever, so the only way back is turning the setting
            // off and on again.
            guard var settings = try? AppSettingsStore.shared.load(),
                  settings.terminal.agentStatusHooksEnabled
            else {
                return
            }
            settings.terminal.agentStatusHooksEnabled = false
            try? AppSettingsStore.shared.save(settings)
        }
    )
}
