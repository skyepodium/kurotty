import Foundation

/// Filesystem change notification for one transcript file.
///
/// Two mechanisms run together and the split is deliberate:
///
/// - a `DispatchSource` vnode watch on the transcript's **parent directory** is
///   an accelerator. Watching the parent survives target-file replacement on
///   macOS, which watching the file itself does not: an atomic rewrite swaps
///   the inode and a file-level watch goes deaf without an error.
/// - a polling reconciler owns liveness. Native watches can silently fail on
///   network and virtualized filesystems, so the timer is what guarantees the
///   view eventually catches up, and the watch only makes it feel instant.
///
/// The source and timer are owned by this object and cancelled on `stop()` and
/// `deinit`; nothing here is global.
/// `@unchecked Sendable` is narrow and deliberate: the mutable state is only
/// touched from the owning main actor (`start`/`stop`) and the dispatch
/// handlers capture nothing but the immutable `onChange` closure.
final class AgentSessionTranscriptWatcher: @unchecked Sendable {
    private enum Queue {
        static let label = "com.kurotty.agent-transcript-watcher"
    }

    /// Reconciliation cadence. Slow enough to be free while idle, fast enough
    /// that a broken native watch is not user-visible.
    static let reconcileIntervalSeconds: TimeInterval = 1.5
    static let reconcileLeewaySeconds: TimeInterval = 0.5

    private let fileURL: URL
    private let onChange: @Sendable () -> Void
    private let queue: DispatchQueue
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1
    private var reconcileTimer: DispatchSourceTimer?
    private var isStopped = false

    init(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.onChange = onChange
        queue = DispatchQueue(label: Queue.label, qos: .utility)
    }

    deinit {
        directorySource?.cancel()
        reconcileTimer?.cancel()
        if directoryDescriptor >= 0 {
            close(directoryDescriptor)
        }
    }

    /// True when the native accelerator bound. A false return is not a failure:
    /// the reconciler still runs.
    @discardableResult
    func start() -> Bool {
        guard !isStopped else {
            return false
        }
        startReconciler()
        return bindDirectorySource()
    }

    func stop() {
        isStopped = true
        directorySource?.cancel()
        directorySource = nil
        reconcileTimer?.cancel()
        reconcileTimer = nil
    }

    var isNativeWatchActive: Bool {
        directorySource != nil
    }

    private func bindDirectorySource() -> Bool {
        guard directorySource == nil else {
            return true
        }
        let directoryPath = fileURL.deletingLastPathComponent().path
        let descriptor = open(directoryPath, O_EVTONLY)
        guard descriptor >= 0 else {
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        let onChange = onChange
        source.setEventHandler {
            onChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directoryDescriptor = descriptor
        directorySource = source
        source.resume()
        return true
    }

    private func startReconciler() {
        guard reconcileTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.reconcileIntervalSeconds,
            repeating: Self.reconcileIntervalSeconds,
            leeway: .milliseconds(Int(Self.reconcileLeewaySeconds * 1_000))
        )
        let onChange = onChange
        timer.setEventHandler {
            onChange()
        }
        reconcileTimer = timer
        timer.resume()
    }
}
