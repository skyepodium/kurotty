import Foundation

#if os(macOS)
import Darwin
#endif

/// Pure model layer for the terminal window's bottom status bar.
///
/// Everything in this file is deterministic and free of AppKit, timers, and
/// syscalls so it can be unit-tested directly: byte/percent formatting, the CPU
/// delta between two counter samples, aggregation across panes, the process
/// kill guard, the occlusion/sampling gate, the responsive-truncation
/// breakpoints, and the agent-label composition.
///
/// Values and copy that belong in `DesignTokens` / `AppLocalization` are staged
/// in `TerminalStatusBarCopy.swift` because those files are owned elsewhere;
/// both tables are listed in the handoff so they can be migrated verbatim.

// MARK: - Session capability

/// Optional capability for sessions that own a real child process.
///
/// Deliberately separate from `TerminalSession`, matching
/// `TerminalShellLaunchConfigurable`: tmux placeholders, test doubles, and any
/// future non-PTY session stay conformant without inventing a pid.
///
/// Integration point: `DarwinPTYTerminalSession` must adopt this and return its
/// `childPid`. Until then `TerminalPaneView.shellProcessIdentifier` is `nil`
/// and the status bar reports no per-pane process rows.
protocol TerminalShellProcessIdentifying: AnyObject {
    /// The pane's direct shell child. Values <= 1 mean "not started" or
    /// "already exited" and are never sampled or signaled.
    var shellProcessIdentifier: pid_t { get }
}

// MARK: - Pane identity

/// What the status bar needs to know about one pane. The window controller
/// builds these from its live panes; nothing here holds a view reference, so
/// the sampler can carry them across actor boundaries.
struct TerminalStatusBarPaneDescriptor: Equatable, Sendable {
    /// `TerminalPaneView.agentPaneIdentifier`: the same identity the agent
    /// activity registry and the pane's PTY environment already agree on.
    let paneIdentifier: String
    let title: String
    /// The pane's shell child process, or `nil` when the session does not own a
    /// real child (tmux placeholder, test double, PTY not started yet).
    let shellProcessIdentifier: pid_t?
    /// OSC 7 working directory, used to look up a resumable agent session.
    let workingDirectoryPath: String
    /// True when OSC 7 reported that directory on another machine. Local-only
    /// lookups such as the git worktree segment must not run against a remote
    /// path that happens to exist on this Mac too.
    let isWorkingDirectoryRemote: Bool

    init(
        paneIdentifier: String,
        title: String,
        shellProcessIdentifier: pid_t?,
        workingDirectoryPath: String,
        isWorkingDirectoryRemote: Bool = false
    ) {
        self.paneIdentifier = paneIdentifier
        self.title = title
        self.shellProcessIdentifier = shellProcessIdentifier
        self.workingDirectoryPath = workingDirectoryPath
        self.isWorkingDirectoryRemote = isWorkingDirectoryRemote
    }
}

// MARK: - Counter samples and CPU delta

/// One raw counter reading for a process tree.
///
/// `cpuTimeSeconds` is a cumulative counter, so a single sample says nothing
/// about utilization; percentages only exist as a delta between two samples.
struct TerminalProcessCounterSample: Equatable, Sendable {
    let residentBytes: UInt64
    let cpuTimeSeconds: Double
    /// Monotonic clock reading, not wall time: a clock change must not be able
    /// to manufacture a CPU spike.
    let uptimeSeconds: Double

    init(residentBytes: UInt64, cpuTimeSeconds: Double, uptimeSeconds: Double) {
        self.residentBytes = residentBytes
        self.cpuTimeSeconds = cpuTimeSeconds
        self.uptimeSeconds = uptimeSeconds
    }
}

/// CPU percentage from two cumulative samples.
///
/// Percent is normalized against the whole machine (all cores), so 100 means
/// every core is saturated by this pane. That is the scale the warning/error
/// thresholds are written against.
enum TerminalProcessCPUUsage {
    /// `nil` whenever a delta cannot be trusted: no previous sample, a
    /// non-positive elapsed interval, or a counter that moved backwards
    /// (process exit plus pid reuse, or a 64-bit counter wraparound). Callers
    /// render "—" for `nil` rather than a fabricated 0%.
    static func percent(
        previous: TerminalProcessCounterSample?,
        current: TerminalProcessCounterSample,
        processorCount: Int
    ) -> Double? {
        guard let previous else {
            return nil
        }
        guard processorCount > 0 else {
            return nil
        }
        let elapsedSeconds = current.uptimeSeconds - previous.uptimeSeconds
        guard elapsedSeconds > 0 else {
            return nil
        }
        let cpuSeconds = current.cpuTimeSeconds - previous.cpuTimeSeconds
        guard cpuSeconds >= 0 else {
            return nil
        }
        let percent = (cpuSeconds / (elapsedSeconds * Double(processorCount))) * 100
        return clampedPercent(percent)
    }

    static func clampedPercent(_ percent: Double) -> Double {
        guard percent.isFinite else {
            return 0
        }
        return min(max(percent, 0), AppConstants.StatusBar.maximumCPUPercentRATIO)
    }
}

// MARK: - Usage aggregation

struct TerminalPaneResourceUsage: Equatable, Sendable {
    let paneIdentifier: String
    let title: String
    let processIdentifier: pid_t?
    let residentBytes: UInt64
    /// `nil` until a second sample exists for this pane.
    let cpuPercent: Double?

    init(
        paneIdentifier: String,
        title: String,
        processIdentifier: pid_t?,
        residentBytes: UInt64,
        cpuPercent: Double?
    ) {
        self.paneIdentifier = paneIdentifier
        self.title = title
        self.processIdentifier = processIdentifier
        self.residentBytes = residentBytes
        self.cpuPercent = cpuPercent
    }
}

/// Window-level totals plus the per-pane rows the popover lists.
struct TerminalWindowResourceUsage: Equatable, Sendable {
    let residentBytes: UInt64
    let cpuPercent: Double?
    /// Sorted by resident bytes descending, then CPU descending.
    let panes: [TerminalPaneResourceUsage]

    static let empty = TerminalWindowResourceUsage(residentBytes: 0, cpuPercent: nil, panes: [])

    var isEmpty: Bool {
        panes.isEmpty
    }
}

enum TerminalResourceUsageAggregator {
    /// Sums resident bytes and CPU across panes. CPU stays `nil` until at least
    /// one pane has a usable delta, so the first sample after launch shows "—"
    /// instead of a fake 0%.
    static func aggregate(_ panes: [TerminalPaneResourceUsage]) -> TerminalWindowResourceUsage {
        guard !panes.isEmpty else {
            return .empty
        }
        var residentBytes: UInt64 = 0
        var cpuPercent: Double?
        for pane in panes {
            residentBytes = residentBytes.addingReportingOverflow(pane.residentBytes).partialValue
            guard let paneCPU = pane.cpuPercent else {
                continue
            }
            cpuPercent = (cpuPercent ?? 0) + paneCPU
        }
        return TerminalWindowResourceUsage(
            residentBytes: residentBytes,
            cpuPercent: cpuPercent.map(TerminalProcessCPUUsage.clampedPercent),
            panes: sortedDescending(panes)
        )
    }

    static func sortedDescending(_ panes: [TerminalPaneResourceUsage]) -> [TerminalPaneResourceUsage] {
        panes.sorted { left, right in
            guard left.residentBytes == right.residentBytes else {
                return left.residentBytes > right.residentBytes
            }
            return (left.cpuPercent ?? -1) > (right.cpuPercent ?? -1)
        }
    }
}

// MARK: - Formatting

/// Severity of a displayed metric. Drives the value color only; it never
/// changes layout, so a threshold crossing cannot reflow the bar.
enum TerminalStatusBarSeverity: Equatable, Sendable {
    case normal
    case warning
    case error
}

/// Pure formatting for the right segment.
///
/// Unit choice, rounding, and thresholds live here so the view only assigns
/// already-final strings. Follows Orca's `resource-memory-metric-copy.ts` copy
/// shape: a short column label (`RSS`) for popover columns and a summed
/// description for the tooltip.
enum TerminalResourceUsageFormatter {
    static let memoryColumnLabel = AppConstants.StatusBar.memoryColumnLabel
    static let memorySummaryLabel = AppConstants.StatusBar.memorySummaryLabel
    static let memoryDescription = AppLocalization.string(.statusBarMemoryDescription)
    static let unavailableValueText = AppConstants.StatusBar.unavailableValue

    /// `412 MB`, `1.2 GB`, `768 KB`. Binary units throughout (1 MB = 1024 KB),
    /// whole numbers below the gigabyte boundary and one decimal above it, so
    /// the string width stays stable while the value moves.
    static func memoryText(bytes: UInt64) -> String {
        let kilobytes = Double(bytes) / AppConstants.StatusBar.bytesPerKilobyteRATIO
        guard kilobytes >= AppConstants.StatusBar.bytesPerKilobyteRATIO else {
            return "\(Int(kilobytes.rounded())) \(AppConstants.StatusBar.kilobyteUnit)"
        }
        let megabytes = kilobytes / AppConstants.StatusBar.bytesPerKilobyteRATIO
        guard megabytes >= AppConstants.StatusBar.bytesPerKilobyteRATIO else {
            return "\(Int(megabytes.rounded())) \(AppConstants.StatusBar.megabyteUnit)"
        }
        let gigabytes = megabytes / AppConstants.StatusBar.bytesPerKilobyteRATIO
        let rounded = (gigabytes * 10).rounded() / 10
        return String(format: "%.1f \(AppConstants.StatusBar.gigabyteUnit)", rounded)
    }

    /// `3%`. Rounded to a whole percent and clamped into 0...100.
    static func cpuText(percent: Double?) -> String {
        guard let percent else {
            return unavailableValueText
        }
        let clamped = TerminalProcessCPUUsage.clampedPercent(percent)
        return "\(Int(clamped.rounded()))\(AppConstants.StatusBar.percentUnit)"
    }

    /// Compact one-line summary used for tooltips and accessibility:
    /// `RAM 412 MB · CPU 3%`.
    static func summaryText(bytes: UInt64, cpuPercent: Double?) -> String {
        let memory = "\(AppConstants.StatusBar.memoryPrefix) \(memoryText(bytes: bytes))"
        let cpu = "\(AppConstants.StatusBar.cpuPrefix) \(cpuText(percent: cpuPercent))"
        return "\(memory) \(AppConstants.StatusBar.summarySeparator) \(cpu)"
    }

    static func severity(cpuPercent: Double?) -> TerminalStatusBarSeverity {
        severity(percent: cpuPercent)
    }

    /// Memory severity is expressed as a share of installed physical memory;
    /// `totalPhysicalBytes` is passed in so this stays a pure function.
    static func severity(residentBytes: UInt64, totalPhysicalBytes: UInt64) -> TerminalStatusBarSeverity {
        guard totalPhysicalBytes > 0 else {
            return .normal
        }
        return severity(percent: Double(residentBytes) / Double(totalPhysicalBytes) * 100)
    }

    private static func severity(percent: Double?) -> TerminalStatusBarSeverity {
        guard let percent, percent.isFinite else {
            return .normal
        }
        if percent >= AppConstants.StatusBar.errorPercentRATIO {
            return .error
        }
        if percent >= AppConstants.StatusBar.warningPercentRATIO {
            return .warning
        }
        return .normal
    }
}

// MARK: - Sampling gate

/// Inputs that decide whether a sampling tick should do any work.
struct TerminalStatusBarSamplingContext: Equatable, Sendable {
    let isWindowVisible: Bool
    let isWindowOccluded: Bool
    let paneCount: Int
    let isStatusBarVisible: Bool

    init(
        isWindowVisible: Bool,
        isWindowOccluded: Bool,
        paneCount: Int,
        isStatusBarVisible: Bool = true
    ) {
        self.isWindowVisible = isWindowVisible
        self.isWindowOccluded = isWindowOccluded
        self.paneCount = paneCount
        self.isStatusBarVisible = isStatusBarVisible
    }
}

/// Pure gate for the sampling timer. Sampling costs syscalls per pane subtree,
/// so a miniaturized, hidden, or fully occluded window must not pay for numbers
/// nobody can read.
enum TerminalStatusBarSamplingPolicy {
    static func shouldSample(_ context: TerminalStatusBarSamplingContext) -> Bool {
        guard context.isWindowVisible, !context.isWindowOccluded else {
            return false
        }
        guard context.isStatusBarVisible else {
            return false
        }
        return context.paneCount > 0
    }
}

// MARK: - Kill policy

/// Result of asking whether a "Quit process" row action may proceed.
enum TerminalProcessKillDecision: Equatable, Sendable {
    /// pid 0 (kernel/process group wildcard) and pid 1 (launchd) are never
    /// signalable targets; `kill(0, ...)` would signal our own process group.
    case refusedReservedProcess
    /// The pid is not one of this window's pane shells. Kurotty only ever
    /// signals processes it spawned.
    case refusedUnownedProcess
    /// Valid target, but the destructive confirmation has not been answered.
    case requiresConfirmation
    case terminate
}

/// Pure guard in front of the destructive row action.
enum TerminalProcessKillPolicy {
    static let gracePeriodSeconds: TimeInterval = AppConstants.StatusBar.killGracePeriodSeconds

    static func decision(
        processIdentifier: pid_t,
        ownedProcessIdentifiers: Set<pid_t>,
        isConfirmed: Bool
    ) -> TerminalProcessKillDecision {
        guard processIdentifier > 1 else {
            return .refusedReservedProcess
        }
        guard ownedProcessIdentifiers.contains(processIdentifier) else {
            return .refusedUnownedProcess
        }
        guard isConfirmed else {
            return .requiresConfirmation
        }
        return .terminate
    }
}

// MARK: - Responsive truncation

/// Which parts of the bar survive at the current width. Segments are dropped
/// whole; nothing is ever clipped mid-glyph, and every dropped part moves into
/// the segment's tooltip.
struct TerminalStatusBarVisibility: Equatable, Sendable {
    let showsAgentLabel: Bool
    let showsAgentDetail: Bool
    let showsCPUMetric: Bool
    let showsMemoryValue: Bool
    /// The worktree segment is dropped whole rather than reduced to its icon:
    /// a branch glyph without a branch name locates nothing.
    let showsWorktree: Bool
    /// The quota segment is a meter plus a percentage, and both are needed for
    /// it to say anything, so it too is dropped whole.
    let showsQuota: Bool

    init(
        showsAgentLabel: Bool,
        showsAgentDetail: Bool,
        showsCPUMetric: Bool,
        showsMemoryValue: Bool,
        showsWorktree: Bool = false,
        showsQuota: Bool = false
    ) {
        self.showsAgentLabel = showsAgentLabel
        self.showsAgentDetail = showsAgentDetail
        self.showsCPUMetric = showsCPUMetric
        self.showsMemoryValue = showsMemoryValue
        self.showsWorktree = showsWorktree
        self.showsQuota = showsQuota
    }

    static let full = TerminalStatusBarVisibility(
        showsAgentLabel: true,
        showsAgentDetail: true,
        showsCPUMetric: true,
        showsMemoryValue: true,
        showsWorktree: true,
        showsQuota: true
    )
}

/// Pure width -> visibility mapping, applied in the documented order as the
/// window narrows: the worktree segment and the agent detail go first, then the
/// CPU metric, then the agent label, and finally the memory value.
enum TerminalStatusBarLayoutPolicy {
    static func visibility(barWidthPX: CGFloat) -> TerminalStatusBarVisibility {
        guard barWidthPX >= DesignTokens.Component.StatusBar.iconOnlyBreakpointPX else {
            return TerminalStatusBarVisibility(
                showsAgentLabel: false,
                showsAgentDetail: false,
                showsCPUMetric: false,
                showsMemoryValue: false
            )
        }
        guard barWidthPX >= DesignTokens.Component.StatusBar.agentLabelBreakpointPX else {
            return TerminalStatusBarVisibility(
                showsAgentLabel: false,
                showsAgentDetail: false,
                showsCPUMetric: false,
                showsMemoryValue: true
            )
        }
        guard barWidthPX >= DesignTokens.Component.StatusBar.cpuMetricBreakpointPX else {
            return TerminalStatusBarVisibility(
                showsAgentLabel: true,
                showsAgentDetail: false,
                showsCPUMetric: false,
                showsMemoryValue: true
            )
        }
        guard barWidthPX >= DesignTokens.Component.StatusBar.agentDetailBreakpointPX else {
            return TerminalStatusBarVisibility(
                showsAgentLabel: true,
                showsAgentDetail: false,
                showsCPUMetric: true,
                showsMemoryValue: true
            )
        }
        // Quota shares the widest breakpoint with the agent detail and the
        // worktree: all three are context the popovers still carry, so they go
        // together before anything that only exists in the bar.
        return .full
    }
}

// MARK: - Agent segment composition

/// How the left segment's status dot renders.
enum TerminalStatusBarDotStyle: Equatable, Sendable {
    case filled(TerminalStatusBarDotRole)
    /// Hollow ring: an agent channel exists but nothing is reporting now.
    case hollowRing
    /// No dot at all: no agent has ever reported and hooks are not installed.
    case none
}

/// Semantic color role, resolved against the chrome theme by the view.
enum TerminalStatusBarDotRole: Equatable, Sendable {
    case idle
    case working
    case waiting
    case error
}

/// What clicking the left segment should do.
enum TerminalStatusBarAgentAction: Equatable, Sendable {
    /// Hooks are not installed and nothing has ever reported: offer to enable
    /// them instead of opening an empty popover.
    case offerToEnableStatusHooks
    /// Show the bounded status history the registry already keeps.
    case showStatusHistory
}

/// Everything the left segment renders, resolved from registry state.
struct TerminalStatusBarAgentSummary: Equatable, Sendable {
    let dot: TerminalStatusBarDotStyle
    let label: String
    let detail: String?
    let showsSpinner: Bool
    let showsAgentGlyph: Bool
    /// Count badge when more than one agent is reporting in the window; the
    /// segment always shows exactly one state, never one segment per agent.
    let agentCount: Int
    let isCallToAction: Bool
    let action: TerminalStatusBarAgentAction
    /// Full text for the tooltip, used verbatim when truncation hides parts.
    let tooltip: String
}

/// Pure composition of the left segment from resolved registry statuses.
enum TerminalStatusBarAgentComposer {
    /// Highest-priority state wins when several panes report at once.
    /// Priority: error > waiting > working > idle.
    static func priority(of state: AgentActivityState) -> Int {
        switch state {
        case .blocked:
            return 3
        case .waitingForInput:
            return 2
        case .working:
            return 1
        case .done:
            return 0
        }
    }

    static func dominant(_ statuses: [AgentActivityStatus]) -> AgentActivityStatus? {
        statuses.max { left, right in
            guard priority(of: left.state) == priority(of: right.state) else {
                return priority(of: left.state) < priority(of: right.state)
            }
            return left.updatedAt < right.updatedAt
        }
    }

    /// - Parameters:
    ///   - statuses: already staleness-resolved statuses for the window.
    ///   - areStatusHooksInstalled: `AgentStatusHookCoordinator.isEnabled`.
    ///   - hasEverReported: whether any pane has non-empty registry history, so
    ///     a finished agent reads as "No agent" rather than "Connect an agent".
    static func summary(
        statuses: [AgentActivityStatus],
        areStatusHooksInstalled: Bool,
        hasEverReported: Bool,
        language: AppLanguage = AppLocalization.language
    ) -> TerminalStatusBarAgentSummary {
        guard let dominant = dominant(statuses) else {
            return emptySummary(
                areStatusHooksInstalled: areStatusHooksInstalled,
                hasEverReported: hasEverReported,
                language: language
            )
        }
        let stateLabel = TerminalStatusBarStrings.stateLabel(for: dominant.state, language: language)
        let label = dominant.agentName.map {
            "\($0) \(AppConstants.StatusBar.labelSeparator) \(stateLabel)"
        } ?? stateLabel
        let tooltip = dominant.detail.map { "\(label) \(AppConstants.StatusBar.detailSeparator) \($0)" } ?? label
        return TerminalStatusBarAgentSummary(
            dot: .filled(role(for: dominant.state)),
            label: label,
            detail: dominant.detail,
            showsSpinner: dominant.state == .working,
            showsAgentGlyph: true,
            agentCount: statuses.count,
            isCallToAction: false,
            action: .showStatusHistory,
            tooltip: tooltip
        )
    }

    private static func emptySummary(
        areStatusHooksInstalled: Bool,
        hasEverReported: Bool,
        language: AppLanguage
    ) -> TerminalStatusBarAgentSummary {
        guard areStatusHooksInstalled || hasEverReported else {
            let label = AppLocalization.string(.statusBarConnectAnAgent, language: language)
            return TerminalStatusBarAgentSummary(
                dot: .none,
                label: label,
                detail: nil,
                showsSpinner: false,
                showsAgentGlyph: false,
                agentCount: 0,
                isCallToAction: true,
                action: .offerToEnableStatusHooks,
                tooltip: AppLocalization.string(.statusBarConnectAnAgentTooltip, language: language)
            )
        }
        let label = AppLocalization.string(.statusBarNoAgent, language: language)
        return TerminalStatusBarAgentSummary(
            dot: .hollowRing,
            label: label,
            detail: nil,
            showsSpinner: false,
            showsAgentGlyph: false,
            agentCount: 0,
            isCallToAction: false,
            action: .showStatusHistory,
            tooltip: label
        )
    }

    static func role(for state: AgentActivityState) -> TerminalStatusBarDotRole {
        switch state {
        case .working:
            return .working
        case .waitingForInput:
            return .waiting
        case .blocked:
            return .error
        case .done:
            return .idle
        }
    }
}

// MARK: - Quota segment composition

/// Everything the quota segment renders, condensed from the per-agent summary.
///
/// The bar shows exactly one number, and it is the *fullest* live window across
/// every agent, because that is the one that stops work first. Which agent and
/// window it belongs to is in the label and, in full, in the popover — a bar
/// that grew a segment per window would reflow every time a plan changed.
struct TerminalStatusBarQuotaSummary: Equatable, Sendable {
    /// Fraction of the tightest window consumed, 0...1.
    let usedFraction: Double
    /// `Codex 5h`, naming what the number belongs to.
    let label: String
    let percentText: String
    let severity: TerminalStatusBarSeverity
    let tooltip: String

    /// Nothing to show. The segment hides itself rather than rendering a dash:
    /// a quota nobody reports is not a metric that is temporarily unavailable.
    static let absent = TerminalStatusBarQuotaSummary(
        usedFraction: 0,
        label: "",
        percentText: "",
        severity: .normal,
        tooltip: ""
    )

    var isPresent: Bool {
        !percentText.isEmpty
    }
}

enum TerminalStatusBarQuotaComposer {
    /// Maps quota pressure onto the bar's existing severity ladder so an amber
    /// quota and an amber CPU mean the same degree of trouble.
    static func severity(for pressure: AgentRateLimitQuotaCopy.Pressure) -> TerminalStatusBarSeverity {
        switch pressure {
        case .comfortable:
            return .normal
        case .warning:
            return .warning
        case .exhausted:
            return .error
        }
    }

    static func summary(
        for quotaSummary: AgentRateLimitQuotaSummary,
        now: Date,
        language: AppLanguage = AppLocalization.language
    ) -> TerminalStatusBarQuotaSummary {
        guard let tightest = quotaSummary.tightestWindow else {
            return .absent
        }
        let windowLabel = AgentRateLimitQuotaCopy.windowLabel(minutes: tightest.window.windowMinutes)
        let tooltip = AgentRateLimitQuotaCopy.summaryTooltip(
            for: quotaSummary,
            now: now,
            language: language
        )
        return TerminalStatusBarQuotaSummary(
            usedFraction: tightest.window.usedFraction,
            label: "\(tightest.agent.shortLabel) \(windowLabel)",
            percentText: "\(AgentRateLimitQuotaCopy.percent(tightest.window.usedFraction))"
                + AppConstants.StatusBar.percentUnit,
            severity: severity(
                for: AgentRateLimitQuotaCopy.pressure(forFraction: tightest.window.usedFraction)
            ),
            tooltip: tooltip ?? ""
        )
    }
}
