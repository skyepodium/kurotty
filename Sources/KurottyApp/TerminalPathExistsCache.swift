import Foundation

/// Bounded LRU of "does this absolute path exist on disk" answers.
///
/// Link hit-testing runs on every mouse move and on every decoration rebuild, so
/// it may never stat synchronously. The surface reads this cache on the main
/// actor and schedules misses onto `TerminalPathExistsProbe`, which stats off
/// the main actor and writes the answer back.
///
/// Bounded because terminal output can contain unbounded unique paths over a
/// long session; eviction is strict least-recently-used.
final class TerminalPathExistsCache {
    static let maximumEntryCount = AppConstants.TerminalLinks.pathExistsCacheMaximumEntryCount

    private var existsByPath: [String: Bool] = [:]
    /// Least-recently-used first. Bounded by `maximumEntryCount`, so the
    /// front-removal cost stays constant-sized.
    private var recencyOrder: [String] = []
    private let capacity: Int

    init(capacity: Int = TerminalPathExistsCache.maximumEntryCount) {
        self.capacity = max(1, capacity)
    }

    var entryCount: Int { existsByPath.count }

    /// Least-recently-used ordering, oldest first. Exposed for tests.
    var pathsByRecency: [String] { recencyOrder }

    /// `nil` means "never probed"; a probe should be scheduled.
    func exists(_ path: String) -> Bool? {
        guard let value = existsByPath[path] else { return nil }
        touch(path)
        return value
    }

    /// Reads without promoting, for assertions and diagnostics.
    func peek(_ path: String) -> Bool? {
        existsByPath[path]
    }

    func record(path: String, exists: Bool) {
        if existsByPath[path] != nil {
            existsByPath[path] = exists
            touch(path)
            return
        }
        while existsByPath.count >= capacity, let oldest = recencyOrder.first {
            recencyOrder.removeFirst()
            existsByPath.removeValue(forKey: oldest)
        }
        existsByPath[path] = exists
        recencyOrder.append(path)
    }

    /// Drops every answer. Used when the pane's working directory changes, since
    /// relative resolutions become stale.
    func removeAll() {
        existsByPath.removeAll(keepingCapacity: true)
        recencyOrder.removeAll(keepingCapacity: true)
    }

    private func touch(_ path: String) {
        guard let index = recencyOrder.lastIndex(of: path) else { return }
        recencyOrder.remove(at: index)
        recencyOrder.append(path)
    }
}

/// Off-main-actor `stat` for link candidates. Deduplicates in-flight paths so a
/// hover that repeats the same miss does not queue redundant work.
@MainActor
final class TerminalPathExistsProbe {
    static let queueLabel = AppConstants.TerminalLinks.pathExistsProbeQueueLabel
    private static let queue = DispatchQueue(label: queueLabel, qos: .utility)

    private var inFlightPaths: Set<String> = []

    var inFlightPathCount: Int { inFlightPaths.count }

    /// Schedules a regular-file existence check for `path`. `completion` is
    /// delivered on the main queue after the stat completes.
    func probe(path: String, completion: @escaping @MainActor (String, Bool) -> Void) {
        guard !inFlightPaths.contains(path) else { return }
        inFlightPaths.insert(path)
        let handoff = TerminalPathExistsProbeHandoff(
            path: path,
            probe: self,
            completion: completion
        )
        Self.queue.async {
            let exists = TerminalPathExistsProbe.regularFileExists(atPath: path)
            // Explicit main-queue hop; the handoff body only ever runs here.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    handoff.deliver(exists: exists)
                }
            }
        }
    }

    nonisolated static func regularFileExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return found && !isDirectory.boolValue
    }

    fileprivate func finishProbe(path: String) {
        inFlightPaths.remove(path)
    }
}

/// Narrow handoff so the probe result can cross the utility queue back to the
/// main queue. Unchecked because Swift 6 cannot see that `deliver` is only ever
/// called from `DispatchQueue.main.async`.
private final class TerminalPathExistsProbeHandoff: @unchecked Sendable {
    private let path: String
    private weak var probe: TerminalPathExistsProbe?
    private let completion: @MainActor (String, Bool) -> Void

    init(
        path: String,
        probe: TerminalPathExistsProbe,
        completion: @escaping @MainActor (String, Bool) -> Void
    ) {
        self.path = path
        self.probe = probe
        self.completion = completion
    }

    @MainActor
    func deliver(exists: Bool) {
        probe?.finishProbe(path: path)
        completion(path, exists)
    }
}
