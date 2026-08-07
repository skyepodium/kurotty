import Foundation

/// The first-run checklist.
///
/// Kurotty had no first-run experience at all, and the honest version of one
/// for a terminal is not a wizard. A wizard stands between someone and the
/// prompt they opened the app to use, and every step it could ask about here is
/// something Kurotty can simply go and look at: whether the shell is reporting
/// command boundaries, whether the agent hooks are installed, whether ripgrep
/// exists. So this reports rather than instructs. Every row is the answer to a
/// question about *this* machine, and nothing on it is required.
///
/// Deciding what a row says is pure and lives here; collecting the facts is the
/// caller's job, which is what keeps this testable without an installed app, an
/// agent, or a shell.

// MARK: - Environment

/// Everything the checklist needs to know, gathered by the caller.
///
/// A flat value rather than a set of live queries so the rules below can be
/// exercised against any combination — including the ones that are awkward to
/// produce on a real machine, like consent granted while the feature is off.
struct TerminalSetupEnvironment: Equatable {
    /// Whether Kurotty is launching the configured shell with its bundled OSC 7
    /// and OSC 133 integration loaded.
    ///
    /// This is the launch contract rather than observed traffic, and that is
    /// deliberate: a fresh window has run no commands, so an evidence-based
    /// check would show amber on a perfectly configured machine until the user
    /// happened to run something. The contract is knowable at launch and is the
    /// thing the user can actually act on — it is false when their shell is one
    /// Kurotty ships no integration for.
    let shellInjectsCommandBoundaries: Bool
    let agentStatusHooksEnabled: Bool
    /// One entry per agent Kurotty knows how to install hooks for.
    let agentStatusHookConsents: [AgentStatusHookConsent]
    let agentSessionIndexEnabled: Bool
    let isRipgrepAvailable: Bool
    let isInstalledInApplications: Bool

    init(
        shellInjectsCommandBoundaries: Bool = false,
        agentStatusHooksEnabled: Bool = false,
        agentStatusHookConsents: [AgentStatusHookConsent] = [],
        agentSessionIndexEnabled: Bool = false,
        isRipgrepAvailable: Bool = false,
        isInstalledInApplications: Bool = false
    ) {
        self.shellInjectsCommandBoundaries = shellInjectsCommandBoundaries
        self.agentStatusHooksEnabled = agentStatusHooksEnabled
        self.agentStatusHookConsents = agentStatusHookConsents
        self.agentSessionIndexEnabled = agentSessionIndexEnabled
        self.isRipgrepAvailable = isRipgrepAvailable
        self.isInstalledInApplications = isInstalledInApplications
    }
}

// MARK: - Items

enum TerminalSetupChecklistItemID: String, CaseIterable, Equatable {
    case shellIntegration
    case agentStatus
    case agentSessions
    case projectFiles
    case installLocation
}

/// What one row reports.
///
/// Three states, not two. `unavailable` is the row for something the user has
/// switched off, and it must not read like a failure — a checklist that scolds
/// someone for a preference they set is worse than no checklist. `action` is
/// reserved for things that are off because nobody has been asked yet.
enum TerminalSetupChecklistState: Equatable {
    case ready
    case action
    case unavailable
}

/// Something the row offers to do. Only two exist, because the checklist is a
/// report: it can send the user to the switch that governs a row, or hand them
/// a command to paste. It never installs anything itself.
enum TerminalSetupChecklistAction: Equatable {
    case openSettings
    /// A shell command the row offers to copy. Never executed — the checklist
    /// has no PTY handle and no send path, matching every other surface in
    /// Kurotty that composes a command for the user.
    case copyCommand(String)
}

struct TerminalSetupChecklistItem: Equatable {
    let id: TerminalSetupChecklistItemID
    let state: TerminalSetupChecklistState
    let action: TerminalSetupChecklistAction?
}

// MARK: - Rules

enum TerminalSetupChecklist {
    /// The one command that installs ripgrep on the platform Kurotty runs on.
    ///
    /// Orca detects a package manager by parsing `/etc/os-release`, because it
    /// runs on three platforms. Kurotty is macOS-only, so there is exactly one
    /// answer and no detection to get wrong.
    static let ripgrepInstallCommand = "brew install ripgrep"

    /// Every row, in a fixed order. The order is the order the features matter
    /// to a new user, not the order they were built.
    static func items(environment: TerminalSetupEnvironment) -> [TerminalSetupChecklistItem] {
        [
            shellIntegrationItem(environment),
            agentStatusItem(environment),
            agentSessionsItem(environment),
            projectFilesItem(environment),
            installLocationItem(environment),
        ]
    }

    /// Rows that are neither ready nor deliberately switched off. This is what
    /// a badge would count; a row the user turned off is not outstanding work.
    static func outstandingCOUNT(environment: TerminalSetupEnvironment) -> Int {
        items(environment: environment).filter { $0.state == .action }.count
    }

    /// `unavailable` rather than `action` when the shell has no bundled
    /// integration. There is no switch to flip and no command to paste: the
    /// answer is a different login shell, which is a decision far outside what
    /// a checklist row should be pushing anyone toward. Reporting it plainly is
    /// the whole contribution.
    private static func shellIntegrationItem(_ environment: TerminalSetupEnvironment) -> TerminalSetupChecklistItem {
        TerminalSetupChecklistItem(
            id: .shellIntegration,
            state: environment.shellInjectsCommandBoundaries ? .ready : .unavailable,
            action: nil
        )
    }

    /// Agent status needs the feature on *and* at least one agent to have said
    /// yes. Consent is what actually decides whether anything reports, so the
    /// switch alone is not readiness.
    ///
    /// A user who denied every agent gets `unavailable`, not `action`: they
    /// answered the question, and re-raising it in a checklist is asking twice.
    private static func agentStatusItem(_ environment: TerminalSetupEnvironment) -> TerminalSetupChecklistItem {
        guard environment.agentStatusHooksEnabled else {
            return TerminalSetupChecklistItem(id: .agentStatus, state: .unavailable, action: .openSettings)
        }
        if environment.agentStatusHookConsents.contains(.granted) {
            return TerminalSetupChecklistItem(id: .agentStatus, state: .ready, action: nil)
        }
        let hasUnansweredAgent = environment.agentStatusHookConsents.contains(.unasked)
            || environment.agentStatusHookConsents.isEmpty
        return TerminalSetupChecklistItem(
            id: .agentStatus,
            state: hasUnansweredAgent ? .action : .unavailable,
            action: .openSettings
        )
    }

    /// The switch is the whole check. How many transcripts the index found is
    /// deliberately not consulted: a machine with no agent history is not a
    /// machine with a problem, and there is nothing the user could do about it
    /// from here. Indexing off is a preference, so it reports `unavailable`
    /// rather than asking them to undo it.
    private static func agentSessionsItem(_ environment: TerminalSetupEnvironment) -> TerminalSetupChecklistItem {
        guard environment.agentSessionIndexEnabled else {
            return TerminalSetupChecklistItem(id: .agentSessions, state: .unavailable, action: .openSettings)
        }
        return TerminalSetupChecklistItem(id: .agentSessions, state: .ready, action: nil)
    }

    /// The only row that names an external binary.
    ///
    /// Missing ripgrep is `action`, never a failure, because the feature works
    /// without it — the built-in walk answers the same query with a smaller
    /// answer. The row offers the install command to copy so the user can
    /// decide; it does not run it, and it does not block anything if ignored.
    private static func projectFilesItem(_ environment: TerminalSetupEnvironment) -> TerminalSetupChecklistItem {
        guard environment.isRipgrepAvailable else {
            return TerminalSetupChecklistItem(
                id: .projectFiles,
                state: .action,
                action: .copyCommand(ripgrepInstallCommand)
            )
        }
        return TerminalSetupChecklistItem(id: .projectFiles, state: .ready, action: nil)
    }

    /// Running from the disk image or Downloads breaks automatic updates, and
    /// the existing move-to-Applications prompt only appears at launch. This
    /// row is where that state stays visible afterwards. No action: the prompt
    /// owns the move, and a second mover would be a second thing that can
    /// relaunch the app.
    private static func installLocationItem(_ environment: TerminalSetupEnvironment) -> TerminalSetupChecklistItem {
        TerminalSetupChecklistItem(
            id: .installLocation,
            state: environment.isInstalledInApplications ? .ready : .action,
            action: nil
        )
    }
}

// MARK: - Copy

/// Localized strings for one row. Kept beside the rules so a new row cannot be
/// added without a title and a detail for it.
enum TerminalSetupChecklistCopy {
    static func title(for id: TerminalSetupChecklistItemID, language: AppLanguage) -> String {
        AppLocalization.string(titleKey(for: id), language: language)
    }

    static func detail(for id: TerminalSetupChecklistItemID, language: AppLanguage) -> String {
        AppLocalization.string(detailKey(for: id), language: language)
    }

    static func stateLabel(for state: TerminalSetupChecklistState, language: AppLanguage) -> String {
        switch state {
        case .ready:
            return AppLocalization.string(.gettingStartedStateReady, language: language)
        case .action:
            return AppLocalization.string(.gettingStartedStateAction, language: language)
        case .unavailable:
            return AppLocalization.string(.gettingStartedStateUnavailable, language: language)
        }
    }

    static func actionLabel(for action: TerminalSetupChecklistAction, language: AppLanguage) -> String {
        switch action {
        case .openSettings:
            return AppLocalization.string(.gettingStartedOpenSettings, language: language)
        case .copyCommand:
            return AppLocalization.string(.gettingStartedCopyCommand, language: language)
        }
    }

    private static func titleKey(for id: TerminalSetupChecklistItemID) -> L10nKey {
        switch id {
        case .shellIntegration:
            return .gettingStartedItemShellIntegration
        case .agentStatus:
            return .gettingStartedItemAgentStatus
        case .agentSessions:
            return .gettingStartedItemAgentSessions
        case .projectFiles:
            return .gettingStartedItemProjectFiles
        case .installLocation:
            return .gettingStartedItemInstallLocation
        }
    }

    private static func detailKey(for id: TerminalSetupChecklistItemID) -> L10nKey {
        switch id {
        case .shellIntegration:
            return .gettingStartedItemShellIntegrationDetail
        case .agentStatus:
            return .gettingStartedItemAgentStatusDetail
        case .agentSessions:
            return .gettingStartedItemAgentSessionsDetail
        case .projectFiles:
            return .gettingStartedItemProjectFilesDetail
        case .installLocation:
            return .gettingStartedItemInstallLocationDetail
        }
    }
}
