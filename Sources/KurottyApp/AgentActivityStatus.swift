import Foundation

/// Whether an AI coding agent running in a pane is working, needs the user, is
/// blocked, or has finished its turn.
///
/// The raw values are the wire values of the OSC 9999 payload and of the
/// loopback hook body. They are protocol identifiers, not display strings.
enum AgentActivityState: String, Codable, Equatable, Sendable, CaseIterable {
    case working
    case waitingForInput = "waiting"
    case blocked
    case done
}

/// One reported activity sample for a pane.
///
/// `agentName` and `detail` are producer-supplied and already length-capped by
/// the channel that decoded them; nothing here is scraped from rendered output.
struct AgentActivityStatus: Equatable, Sendable {
    let state: AgentActivityState
    let agentName: String?
    let detail: String?
    let updatedAt: Date

    init(state: AgentActivityState, agentName: String? = nil, detail: String? = nil, updatedAt: Date = Date()) {
        self.state = state
        self.agentName = AgentActivityStatus.trimmed(
            agentName,
            maximumCharacters: AppConstants.AgentStatus.maximumAgentNameCharacters
        )
        self.detail = AgentActivityStatus.trimmed(
            detail,
            maximumCharacters: AppConstants.AgentStatus.maximumDetailCharacters
        )
        self.updatedAt = updatedAt
    }

    private static func trimmed(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.count > maximumCharacters else {
            return trimmed
        }
        return String(trimmed.prefix(maximumCharacters))
    }
}

/// Pure staleness policy.
///
/// An agent can be killed, suspended, or disconnected without ever emitting a
/// terminal state, so every state carries a maximum age. Past that age the
/// status is cleared rather than downgraded, which is why the resolver returns
/// an optional instead of an "unknown" case: absence is the display contract.
enum AgentActivityStalenessPolicy {
    static func maximumAgeSeconds(for state: AgentActivityState) -> TimeInterval {
        switch state {
        case .working:
            return AppConstants.AgentStatus.workingStaleAfterSeconds
        case .waitingForInput:
            return AppConstants.AgentStatus.waitingForInputStaleAfterSeconds
        case .blocked:
            return AppConstants.AgentStatus.blockedStaleAfterSeconds
        case .done:
            return AppConstants.AgentStatus.doneStaleAfterSeconds
        }
    }

    static func isStale(_ status: AgentActivityStatus, now: Date) -> Bool {
        let age = now.timeIntervalSince(status.updatedAt)
        // A status stamped in the future (clock change) is treated as fresh.
        guard age > 0 else {
            return false
        }
        return age > maximumAgeSeconds(for: status.state)
    }

    /// The status a pane should display, or `nil` when nothing should render.
    static func resolved(_ status: AgentActivityStatus?, now: Date) -> AgentActivityStatus? {
        guard let status, !isStale(status, now: now) else {
            return nil
        }
        return status
    }
}

/// Bounded per-pane store of agent activity, published on the main actor.
///
/// Capacity contract: at most `maximumTrackedPaneCount` panes, each keeping at
/// most `maximumHistoryCountPerPane` samples. When the pane cap is exceeded the
/// least recently updated pane is evicted. Nothing is persisted: this is live
/// session state, not settings, and it never touches the filesystem.
///
/// Lifecycle contract: `shared` is owned for the app lifetime; panes must call
/// `removePane(_:)` when they are torn down. Changes are published through
/// `didChangeNotification` with the affected pane identifier in `userInfo`,
/// mirroring `TerminalCommandHistoryStore` and `AgentSessionIndexStore`.
@MainActor
final class AgentActivityRegistry {
    static let shared = AgentActivityRegistry()
    static let didChangeNotification = Notification.Name("dev.kurotty.agentActivity.didChange")
    static let paneIdentifierNotificationKey = "paneIdentifier"

    private struct PaneEntry {
        var history: [AgentActivityStatus]

        var latest: AgentActivityStatus? {
            history.last
        }
    }

    private var panes: [String: PaneEntry] = [:]

    init() {}

    var trackedPaneIdentifiers: [String] {
        Array(panes.keys)
    }

    /// Records a reported status. Redundant repeats of the same state refresh
    /// the timestamp in place instead of growing history, so a chatty producer
    /// cannot flood the ring.
    func record(_ status: AgentActivityStatus, paneIdentifier: String) {
        guard !paneIdentifier.isEmpty else {
            return
        }
        var entry = panes[paneIdentifier] ?? PaneEntry(history: [])
        if let latest = entry.latest,
           latest.state == status.state,
           latest.agentName == status.agentName,
           latest.detail == status.detail {
            entry.history[entry.history.count - 1] = status
        } else {
            entry.history.append(status)
            if entry.history.count > AppConstants.AgentStatus.maximumHistoryCountPerPane {
                entry.history.removeFirst(entry.history.count - AppConstants.AgentStatus.maximumHistoryCountPerPane)
            }
        }
        panes[paneIdentifier] = entry
        evictOldestPaneIfNeeded(keeping: paneIdentifier)
        postChange(paneIdentifier: paneIdentifier)
    }

    /// Current status for a pane after applying the staleness policy.
    func status(for paneIdentifier: String, now: Date = Date()) -> AgentActivityStatus? {
        AgentActivityStalenessPolicy.resolved(panes[paneIdentifier]?.latest, now: now)
    }

    /// Newest-last history for a pane, without staleness filtering.
    func history(for paneIdentifier: String) -> [AgentActivityStatus] {
        panes[paneIdentifier]?.history ?? []
    }

    func clear(paneIdentifier: String) {
        guard panes[paneIdentifier] != nil else {
            return
        }
        panes[paneIdentifier] = PaneEntry(history: [])
        postChange(paneIdentifier: paneIdentifier)
    }

    /// Drops every sample for a pane. Call this from pane teardown.
    func removePane(_ paneIdentifier: String) {
        guard panes.removeValue(forKey: paneIdentifier) != nil else {
            return
        }
        postChange(paneIdentifier: paneIdentifier)
    }

    func removeAll() {
        guard !panes.isEmpty else {
            return
        }
        panes.removeAll()
        postChange(paneIdentifier: nil)
    }

    /// Drops stale entries. Views resolve staleness on read, so this is only a
    /// memory hygiene pass; it is safe to call on a coarse timer or never.
    @discardableResult
    func pruneStale(now: Date = Date()) -> [String] {
        var pruned: [String] = []
        for (paneIdentifier, entry) in panes {
            guard let latest = entry.latest,
                  AgentActivityStalenessPolicy.isStale(latest, now: now)
            else {
                continue
            }
            panes[paneIdentifier] = PaneEntry(history: [])
            pruned.append(paneIdentifier)
        }
        for paneIdentifier in pruned {
            postChange(paneIdentifier: paneIdentifier)
        }
        return pruned
    }

    private func evictOldestPaneIfNeeded(keeping paneIdentifier: String) {
        guard panes.count > AppConstants.AgentStatus.maximumTrackedPaneCount else {
            return
        }
        let evictionCandidates = panes
            .filter { $0.key != paneIdentifier }
            .sorted { left, right in
                let leftDate = left.value.latest?.updatedAt ?? .distantPast
                let rightDate = right.value.latest?.updatedAt ?? .distantPast
                return leftDate < rightDate
            }
        let excessCount = panes.count - AppConstants.AgentStatus.maximumTrackedPaneCount
        for candidate in evictionCandidates.prefix(excessCount) {
            panes.removeValue(forKey: candidate.key)
        }
    }

    private func postChange(paneIdentifier: String?) {
        var userInfo: [String: String] = [:]
        if let paneIdentifier {
            userInfo[Self.paneIdentifierNotificationKey] = paneIdentifier
        }
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: userInfo
        )
    }
}
