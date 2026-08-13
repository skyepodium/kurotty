import Foundation

/// Decides when a pane whose agent has stopped and is waiting on a person is
/// worth a macOS banner, and when the banner it already raised has to come back
/// down.
///
/// An agent state reaches the status bar as a coloured dot, which is only ever
/// seen by someone already looking at the window — so an agent blocked on a
/// permission prompt in a background tab waits until the user happens to check.
/// This routes the same reported state into the notification path that already
/// carries OSC 9/777/1337, under the focus rule
/// `TerminalCommandFinishNotificationPolicy` established.
///
/// One instance per pane, deliberately a value type with no AppKit and no
/// notifier reference: the interesting part is *when* a banner is owed, and that
/// has to be answerable without a window. The caller owns the identifier, the
/// delivery, and the withdrawal.
struct AgentWaitingNotificationPolicy {
    /// What the caller should do with this pane's banner right now.
    enum Decision: Equatable {
        /// Nothing to present and nothing to take back.
        case doNothing
        /// Present this pane's banner, replacing one already showing for it.
        case notify(state: AgentActivityState)
        /// Take back the banner this pane posted; the prompt behind it is gone.
        case withdraw
    }

    /// States that mean the agent has stopped and cannot continue without a
    /// person. `working` is progress and `done` is a finished turn: neither is
    /// something the user is holding up.
    static func requiresAttention(_ state: AgentActivityState) -> Bool {
        switch state {
        case .waitingForInput, .blocked:
            return true
        case .working, .done:
            return false
        }
    }

    /// Shortest gap between two banners for the same pane. An agent that reports
    /// `waiting` and `blocked` a moment apart, or flaps back through `working`
    /// between two prompts, is one interruption, not three.
    private let debounceSeconds: TimeInterval
    /// The last state seen, whether or not it was notified. Held even for the
    /// focused pane so that leaving the window afterwards is not itself read as
    /// a transition into waiting.
    private var lastReportedState: AgentActivityState?
    private var lastNotifiedAt: Date?
    /// Whether a banner this policy asked for is still believed to be on
    /// screen. It gates `withdraw`, so a pane that never notified never asks
    /// the notification center for anything.
    private var hasOutstandingNotification = false

    init(debounceSeconds: TimeInterval = AppConstants.AgentStatus.waitingNotificationDebounceSeconds) {
        self.debounceSeconds = debounceSeconds
    }

    /// Call on every reported status change **and** on every focus change, with
    /// the pane's current state each time.
    ///
    /// - Parameters:
    ///   - state: the pane's resolved state, `nil` once the registry has cleared
    ///     it or its staleness window has expired. Absence is a resolved prompt
    ///     as far as the banner is concerned.
    ///   - isEnabled: the user's setting. A pane that turns it off mid-wait has
    ///     its banner taken back rather than left parked.
    ///   - isFocused: the pane is the one the user is looking at, resolved by
    ///     the caller through the same rule the command-finish path uses.
    mutating func decide(
        state: AgentActivityState?,
        isEnabled: Bool,
        isFocused: Bool,
        now: Date
    ) -> Decision {
        let previousState = lastReportedState
        lastReportedState = state

        guard isEnabled else {
            return withdrawIfOutstanding()
        }
        guard let state, Self.requiresAttention(state) else {
            return withdrawIfOutstanding()
        }
        // The user is looking at the prompt, so nothing is being missed, and a
        // banner still up for it is stale the moment they arrive.
        guard !isFocused else {
            return withdrawIfOutstanding()
        }
        // Only the transition into a waiting state notifies. A repeat of the
        // same state is a heartbeat, and heartbeats must not stack banners.
        guard previousState != state else {
            return .doNothing
        }
        guard !isWithinDebounceWindow(now: now) else {
            return .doNothing
        }

        lastNotifiedAt = now
        hasOutstandingNotification = true
        return .notify(state: state)
    }

    private mutating func withdrawIfOutstanding() -> Decision {
        guard hasOutstandingNotification else {
            return .doNothing
        }
        hasOutstandingNotification = false
        return .withdraw
    }

    /// A timestamp older than the last banner (a clock change, or a status
    /// stamped in the past) must not be able to silence a pane, so only a
    /// forward gap shorter than the window suppresses.
    private func isWithinDebounceWindow(now: Date) -> Bool {
        guard let lastNotifiedAt else {
            return false
        }
        let elapsed = now.timeIntervalSince(lastNotifiedAt)
        return elapsed >= 0 && elapsed < debounceSeconds
    }
}

/// The fields of a waiting banner.
///
/// Every producer-supplied value here arrived through the OSC 9999 payload or
/// the loopback hook body and nothing is read off the screen. The pane's own
/// title supplies the subtitle, so the banner says *which tab or split* is
/// waiting — the question the user actually has — and never which vendor's agent
/// is running there. Nothing about a specific agent product appears anywhere in
/// this type; the fallbacks describe the reported state and nothing else.
struct AgentWaitingNotificationContent: Equatable {
    let title: String
    let subtitle: String
    let body: String

    /// - Parameters:
    ///   - agentName: the producer's own label for itself, when it sent one.
    ///     Its absence is normal, and the fallback is a role, not a brand.
    ///   - detail: the producer's own description of what it is waiting for.
    ///   - paneTitle: how the pane names itself in Kurotty's chrome.
    static func make(
        state: AgentActivityState,
        agentName: String?,
        detail: String?,
        paneTitle: String
    ) -> AgentWaitingNotificationContent {
        AgentWaitingNotificationContent(
            title: sanitized(agentName) ?? AppConstants.Notifications.agentWaitingDefaultTitle,
            subtitle: sanitized(paneTitle) ?? "",
            body: sanitized(detail) ?? stateBody(for: state)
        )
    }

    private static func stateBody(for state: AgentActivityState) -> String {
        switch state {
        case .blocked:
            return AppConstants.Notifications.agentBlockedBody
        case .waitingForInput, .working, .done:
            return AppConstants.Notifications.agentWaitingForInputBody
        }
    }

    /// Same normalization the explicit OSC payloads get: control bytes stripped,
    /// trimmed, length-capped, and empty treated as absent.
    private static func sanitized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        return TerminalNotificationPayload.body(fromExplicitPayload: value)
    }
}
