import Foundation

/// A piece of delayed work that can be cancelled before it runs.
///
/// Cancellation is deliberately not main-actor isolated: the driver cancels
/// everything from `deinit`, which is nonisolated, exactly as it did when these
/// were `Task` values.
struct TmuxScheduledWork: Sendable {
    private let cancelHandler: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        cancelHandler = cancel
    }

    func cancel() {
        cancelHandler()
    }
}

/// Runs a closure on the main actor after a delay.
///
/// This exists so a test can drive the tmux driver's timers by hand. The
/// production path sleeps in an unstructured task, which means a test that
/// waits for a real 10ms timer has concurrency running underneath XCTest while
/// the test method is suspended. On a CI runner that reproduced an abort from
/// the Swift concurrency task allocator in 45-60% of runs, always in the two
/// tests that wait on these timers. A test scheduler removes the sleeping task
/// from those tests entirely rather than trying to time around it.
@MainActor
protocol TmuxDelayScheduling {
    func schedule(
        afterNanoseconds delay: UInt64,
        _ body: @escaping @MainActor () -> Void
    ) -> TmuxScheduledWork
}

/// The production scheduler: an unstructured task that sleeps and then runs.
@MainActor
struct TmuxTaskDelayScheduler: TmuxDelayScheduling {
    func schedule(
        afterNanoseconds delay: UInt64,
        _ body: @escaping @MainActor () -> Void
    ) -> TmuxScheduledWork {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            body()
        }
        return TmuxScheduledWork { task.cancel() }
    }
}

/// A scheduler that never sleeps. Work is held until a test fires it, so a test
/// that exercises a timeout path runs start to finish on one turn of the main
/// actor with nothing suspended.
@MainActor
final class TmuxManualDelayScheduler: TmuxDelayScheduling {
    private struct Entry {
        let identifier: Int
        let delay: UInt64
        let body: @MainActor () -> Void
    }

    /// Cancellation can arrive from a nonisolated `deinit`, so the pending list
    /// lives behind a lock rather than behind the main actor.
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled: Set<Int> = []

        func markCancelled(_ identifier: Int) {
            lock.lock()
            cancelled.insert(identifier)
            lock.unlock()
        }

        func isCancelled(_ identifier: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled.contains(identifier)
        }
    }

    private let storage = Storage()
    private var entries: [Entry] = []
    private var nextIdentifier = 0

    /// Delays of the work still waiting, in the order it was scheduled.
    var pendingDelays: [UInt64] {
        entries.filter { !storage.isCancelled($0.identifier) }.map(\.delay)
    }

    var isEmpty: Bool {
        pendingDelays.isEmpty
    }

    func schedule(
        afterNanoseconds delay: UInt64,
        _ body: @escaping @MainActor () -> Void
    ) -> TmuxScheduledWork {
        nextIdentifier += 1
        let identifier = nextIdentifier
        entries.append(Entry(identifier: identifier, delay: delay, body: body))
        let storage = storage
        return TmuxScheduledWork { storage.markCancelled(identifier) }
    }

    /// Fires everything currently pending, shortest delay first, so work lands
    /// in the order real timers would have fired it.
    ///
    /// Work scheduled *by* that work is left pending for the next call, which
    /// keeps one `fireDue()` from running an unbounded chain.
    @discardableResult
    func fireDue() -> Int {
        let due = entries
            .filter { !storage.isCancelled($0.identifier) }
            .sorted { $0.delay < $1.delay }
        entries.removeAll()
        for entry in due {
            entry.body()
        }
        return due.count
    }

    /// Repeats `fireDue()` until nothing is left, bounded so a timer that
    /// reschedules itself forever fails the test instead of hanging it.
    func fireUntilQuiet(limit: Int = 16) {
        for _ in 0..<limit where !isEmpty {
            fireDue()
        }
    }
}
