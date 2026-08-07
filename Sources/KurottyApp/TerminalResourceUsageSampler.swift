import Foundation

#if os(macOS)
import Darwin
#endif

/// Reads resident memory and cumulative CPU time for a pane's shell process
/// tree through `libproc`.
///
/// Cost contract: one `proc_listchildpids` plus one `proc_pidinfo` per process
/// in the subtree, per sample. A typical pane is a shell plus zero to three
/// descendants, so a four-pane window costs roughly a dozen syscalls every two
/// seconds and never forks a helper process. The walk is bounded by
/// `processTreeMaximumDepthCOUNT` and `processTreeMaximumProcessCOUNT` so a
/// runaway fork bomb cannot turn a sample into an unbounded traversal.
///
/// Every function here is `nonisolated` and free of app state: it runs off the
/// main actor, and its results are handed back to the main actor by the caller.
enum TerminalProcessTreeReader {
    #if os(macOS)
    /// `proc_taskinfo` CPU counters are mach absolute time units, not
    /// nanoseconds; converting needs the machine's timebase.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Resident bytes and CPU seconds for `rootProcessIdentifier` and its
    /// descendants, or `nil` when the process is gone.
    nonisolated static func sample(
        rootProcessIdentifier: pid_t,
        uptimeSeconds: Double
    ) -> TerminalProcessCounterSample? {
        guard rootProcessIdentifier > 1 else {
            return nil
        }
        var residentBytes: UInt64 = 0
        var cpuTimeSeconds: Double = 0
        var visitedCount = 0
        var didReadAnyProcess = false
        var detectedAgentName: String?

        var frontier: [(processIdentifier: pid_t, depth: Int)] = [(rootProcessIdentifier, 0)]
        while let entry = frontier.popLast() {
            guard visitedCount < AppConstants.StatusBar.processTreeMaximumProcessCOUNT else {
                break
            }
            visitedCount += 1
            if let counters = processCounters(processIdentifier: entry.processIdentifier) {
                didReadAnyProcess = true
                residentBytes = residentBytes
                    .addingReportingOverflow(counters.residentBytes)
                    .partialValue
                cpuTimeSeconds += counters.cpuTimeSeconds
            }
            if detectedAgentName == nil,
               let commandName = TerminalProcessArguments.commandName(pid: entry.processIdentifier) {
                detectedAgentName = TerminalAgentProcessDetector.agentName(forCommandName: commandName)
            }
            guard entry.depth < AppConstants.StatusBar.processTreeMaximumDepthCOUNT else {
                continue
            }
            for child in childProcessIdentifiers(of: entry.processIdentifier) {
                frontier.append((child, entry.depth + 1))
            }
        }

        guard didReadAnyProcess else {
            return nil
        }
        return TerminalProcessCounterSample(
            residentBytes: residentBytes,
            cpuTimeSeconds: cpuTimeSeconds,
            uptimeSeconds: uptimeSeconds,
            detectedAgentName: detectedAgentName
        )
    }

    nonisolated static func childProcessIdentifiers(of processIdentifier: pid_t) -> [pid_t] {
        var buffer = [pid_t](
            repeating: 0,
            count: AppConstants.StatusBar.processTreeMaximumProcessCOUNT
        )
        let byteCapacity = Int32(buffer.count * MemoryLayout<pid_t>.size)
        let writtenCount = proc_listchildpids(processIdentifier, &buffer, byteCapacity)
        guard writtenCount > 0 else {
            return []
        }
        return Array(buffer.prefix(min(Int(writtenCount), buffer.count))).filter { $0 > 1 }
    }

    private nonisolated static func processCounters(
        processIdentifier: pid_t
    ) -> (residentBytes: UInt64, cpuTimeSeconds: Double)? {
        var info = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let readSize = proc_pidinfo(processIdentifier, PROC_PIDTASKINFO, 0, &info, expectedSize)
        guard readSize == expectedSize else {
            return nil
        }
        let machTicks = Double(info.pti_total_user) + Double(info.pti_total_system)
        let nanoseconds = machTicks * Double(timebase.numer) / Double(timebase.denom)
        return (info.pti_resident_size, nanoseconds / Double(NSEC_PER_SEC))
    }
    #else
    nonisolated static func sample(
        rootProcessIdentifier: pid_t,
        uptimeSeconds: Double
    ) -> TerminalProcessCounterSample? {
        nil
    }

    nonisolated static func childProcessIdentifiers(of processIdentifier: pid_t) -> [pid_t] {
        []
    }
    #endif
}

/// Maps process invocation names onto the small set of agents whose presence
/// Kurotty can identify without reading terminal output. It deliberately does
/// not infer activity state: hooks/OSC override this fallback when available.
enum TerminalAgentProcessDetector {
    nonisolated static func agentName(forCommandName commandName: String) -> String? {
        let name = URL(fileURLWithPath: commandName).lastPathComponent.lowercased()
        if name == "codex" || name.hasPrefix("codex-") {
            return AppConstants.AgentStatus.codexReportedAgentName
        }
        if name == "claude" || name.hasPrefix("claude-") {
            return AppConstants.AgentStatus.claudeReportedAgentName
        }
        return nil
    }
}

/// Timer-driven sampler for one window.
///
/// Lifecycle contract: owned by the status bar view, which owns the timer. The
/// timer is created on `start()` and invalidated on `stop()`/`deinit`; ticks
/// that fail `TerminalStatusBarSamplingPolicy` do no work at all, so a hidden or
/// occluded window costs one timer wakeup and nothing else. Previous-sample
/// state is pruned to the currently sampled pids on every publish, so a closed
/// pane cannot leak an entry.
@MainActor
final class TerminalResourceUsageSampler {
    /// Descriptors to sample, supplied by the window controller.
    var paneDescriptorsProvider: (() -> [TerminalStatusBarPaneDescriptor])?
    /// Visibility/occlusion inputs for the sampling gate.
    var samplingContextProvider: (() -> TerminalStatusBarSamplingContext)?
    /// Delivered on the main actor, only when the rendered values changed.
    var onUsageChanged: ((TerminalWindowResourceUsage) -> Void)?

    private(set) var latestUsage = TerminalWindowResourceUsage.empty
    private let intervalSeconds: TimeInterval
    private let processorCount: Int
    /// Narrow handoff box so `deinit`, which is nonisolated, can invalidate the
    /// main-run-loop timer through an explicit main-queue hop. The timer itself
    /// is only ever touched on the main actor.
    private final class TimerBox: @unchecked Sendable {
        var timer: Timer?

        func invalidate() {
            timer?.invalidate()
            timer = nil
        }
    }

    private let timerBox = TimerBox()
    private var previousSamples: [pid_t: TerminalProcessCounterSample] = [:]
    private var isSampleInFlight = false

    init(
        intervalSeconds: TimeInterval = AppConstants.StatusBar.samplingIntervalSeconds,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.intervalSeconds = intervalSeconds
        self.processorCount = max(processorCount, 1)
    }

    deinit {
        let timerBox = timerBox
        DispatchQueue.main.async {
            timerBox.invalidate()
        }
    }

    var isRunning: Bool {
        timerBox.timer != nil
    }

    func start() {
        guard timerBox.timer == nil else {
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            // Timer callbacks are delivered on the main run loop, which is the
            // main actor; the hop keeps that explicit for Swift concurrency.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
        }
        // Sampling is background telemetry: let the system coalesce wakeups.
        timer.tolerance = intervalSeconds / 2
        timerBox.timer = timer
        tick()
    }

    func stop() {
        timerBox.invalidate()
    }

    /// Re-evaluates the gate immediately, for occlusion/visibility changes.
    func sampleNow() {
        tick()
    }

    /// Clears delta state so the next sample is treated as a first sample.
    /// Call when panes are added or removed.
    func resetDeltaState() {
        previousSamples.removeAll()
    }

    private func tick() {
        let context = samplingContextProvider?() ?? TerminalStatusBarSamplingContext(
            isWindowVisible: false,
            isWindowOccluded: true,
            paneCount: 0
        )
        guard TerminalStatusBarSamplingPolicy.shouldSample(context) else {
            return
        }
        guard !isSampleInFlight else {
            return
        }
        let descriptors = paneDescriptorsProvider?() ?? []
        guard !descriptors.isEmpty else {
            return
        }
        isSampleInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let uptimeSeconds = ProcessInfo.processInfo.systemUptime
            var samples: [String: TerminalProcessCounterSample] = [:]
            for descriptor in descriptors {
                guard let processIdentifier = descriptor.shellProcessIdentifier else {
                    continue
                }
                guard let sample = TerminalProcessTreeReader.sample(
                    rootProcessIdentifier: processIdentifier,
                    uptimeSeconds: uptimeSeconds
                ) else {
                    continue
                }
                samples[descriptor.paneIdentifier] = sample
            }
            let readSamples = samples
            await MainActor.run { [weak self] in
                self?.applySamples(readSamples, descriptors: descriptors)
            }
        }
    }

    private func applySamples(
        _ samples: [String: TerminalProcessCounterSample],
        descriptors: [TerminalStatusBarPaneDescriptor]
    ) {
        isSampleInFlight = false
        var paneUsages: [TerminalPaneResourceUsage] = []
        var nextPreviousSamples: [pid_t: TerminalProcessCounterSample] = [:]
        for descriptor in descriptors {
            guard let processIdentifier = descriptor.shellProcessIdentifier,
                  let sample = samples[descriptor.paneIdentifier]
            else {
                continue
            }
            let cpuPercent = TerminalProcessCPUUsage.percent(
                previous: previousSamples[processIdentifier],
                current: sample,
                processorCount: processorCount
            )
            nextPreviousSamples[processIdentifier] = sample
            paneUsages.append(TerminalPaneResourceUsage(
                paneIdentifier: descriptor.paneIdentifier,
                title: descriptor.title,
                processIdentifier: processIdentifier,
                residentBytes: sample.residentBytes,
                cpuPercent: cpuPercent,
                detectedAgentName: sample.detectedAgentName
            ))
        }
        previousSamples = nextPreviousSamples
        let usage = TerminalResourceUsageAggregator.aggregate(paneUsages)
        // Redraw only on a real change: the bar sits under a terminal surface
        // that repaints while the user types, and an unchanged label must not
        // add layout work to that path.
        guard usage != latestUsage else {
            return
        }
        latestUsage = usage
        onUsageChanged?(usage)
    }

    /// SIGTERM now, SIGKILL after the grace period if the process is still
    /// alive. The caller is responsible for the kill policy and the
    /// confirmation; this only performs an already-approved termination.
    nonisolated static func terminate(
        processIdentifier: pid_t,
        gracePeriodSeconds: TimeInterval = TerminalProcessKillPolicy.gracePeriodSeconds
    ) {
        #if os(macOS)
        guard processIdentifier > 1 else {
            return
        }
        kill(processIdentifier, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gracePeriodSeconds) {
            // `kill(pid, 0)` probes liveness without signaling; ESRCH means the
            // process already exited and the pid must not be reused-killed.
            guard kill(processIdentifier, 0) == 0 else {
                return
            }
            kill(processIdentifier, SIGKILL)
        }
        #endif
    }
}
