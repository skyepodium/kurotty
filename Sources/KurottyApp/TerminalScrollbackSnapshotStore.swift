import Foundation

/// Filesystem half of scrollback persistence.
///
/// Every path is derived from a validated versioned hash reference, so nothing a
/// caller supplies can escape the snapshot directory. Writes are atomic: bytes
/// land in a uniquely named temporary file that is renamed over the target, and
/// a failed write removes the temporary file rather than leaving a partial
/// snapshot behind.
///
/// This type never touches AppKit and is safe to use from a background queue.
/// `TerminalScrollbackSnapshotWriter` owns the queue that callers should use.
struct TerminalScrollbackSnapshotStore {
    struct PruneReport: Equatable {
        /// Snapshots removed because no live pane references them.
        var unreferencedRemovedCount: Int
        /// Snapshots removed to bring the directory under its total budget.
        var overBudgetRemovedCount: Int
        var retainedByteCount: Int

        static let empty = PruneReport(
            unreferencedRemovedCount: 0,
            overBudgetRemovedCount: 0,
            retainedByteCount: 0
        )
    }

    enum StoreError: Error, Equatable {
        case invalidRef(String)
        case unavailableRoot
    }

    private enum Permission {
        /// Snapshots hold rendered terminal output, so the directory and files
        /// stay owner-only.
        static let directory: Int16 = 0o700
        static let file: Int16 = 0o600
    }

    private enum TemporaryFile {
        static let suffix = "tmp"
    }

    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    /// `~/Library/Application Support/Kurotty/terminal-scrollback`.
    static func defaultRootURL(fileManager: FileManager = .default) -> URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            return nil
        }
        return base
            .appendingPathComponent(AppConstants.Storage.applicationSupportDirectoryName)
            .appendingPathComponent(TerminalScrollbackSnapshotFormat.directoryName)
    }

    func fileURL(forRef ref: String) -> URL? {
        TerminalScrollbackSnapshotFormat.fileName(forRef: ref).map(rootURL.appendingPathComponent)
    }

    /// Writes `payload` for `ref`, clipped to the store budget. An empty
    /// payload removes any existing snapshot instead of writing a zero-byte
    /// file, so a cleared pane does not resurrect stale output.
    @discardableResult
    func write(
        ref: String,
        payload: Data,
        maximumBytes: Int = TerminalScrollbackSnapshotFormat.Budget.storeBytesPerPane
    ) throws -> URL? {
        guard let url = fileURL(forRef: ref) else {
            throw StoreError.invalidRef(ref)
        }
        let clipped = TerminalScrollbackSnapshotFormat.trailingUTF8Bytes(payload, maximumBytes: maximumBytes)
        guard !clipped.isEmpty else {
            delete(ref: ref)
            return nil
        }

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Permission.directory]
        )
        let temporaryURL = rootURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).\(TemporaryFile.suffix)"
        )
        do {
            try clipped.write(to: temporaryURL, options: [.withoutOverwriting])
            try? fileManager.setAttributes([.posixPermissions: Permission.file], ofItemAtPath: temporaryURL.path)
            _ = try replaceItem(at: url, withItemAt: temporaryURL)
            return url
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Stored bytes for `ref`, or `nil` when the pane has no snapshot.
    func read(ref: String) -> Data? {
        guard let url = fileURL(forRef: ref) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Bytes to feed the screen model: the trailing replay budget, clipped to a
    /// UTF-8 scalar and then to a row boundary.
    func readReplayPayload(
        ref: String,
        maximumBytes: Int = TerminalScrollbackSnapshotFormat.Budget.replayBytesPerPane
    ) -> Data? {
        guard let stored = read(ref: ref), !stored.isEmpty else {
            return nil
        }
        let payload = TerminalScrollbackSnapshotFormat.replayPayload(from: stored, maximumBytes: maximumBytes)
        return payload.isEmpty ? nil : payload
    }

    func delete(ref: String) {
        guard let url = fileURL(forRef: ref) else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    /// Drops snapshots for panes that no longer exist, then enforces the total
    /// directory budget by removing the least recently modified files first.
    @discardableResult
    func prune(
        keepingRefs referencedRefs: Set<String>,
        totalByteBudget: Int = TerminalScrollbackSnapshotFormat.Budget.totalStoreBytes
    ) -> PruneReport {
        var report = PruneReport.empty
        var survivors: [(url: URL, modifiedAt: Date, byteCount: Int)] = []

        for url in snapshotFileURLs() {
            let ref = url.deletingPathExtension().lastPathComponent
            guard referencedRefs.contains(ref) else {
                try? fileManager.removeItem(at: url)
                report.unreferencedRemovedCount += 1
                continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            survivors.append((
                url: url,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                byteCount: values?.fileSize ?? 0
            ))
        }

        survivors.sort { $0.modifiedAt > $1.modifiedAt }
        var retainedBytes = 0
        for survivor in survivors {
            let candidate = retainedBytes + survivor.byteCount
            guard candidate <= totalByteBudget else {
                try? fileManager.removeItem(at: survivor.url)
                report.overBudgetRemovedCount += 1
                continue
            }
            retainedBytes = candidate
        }
        report.retainedByteCount = retainedBytes
        return report
    }

    func totalByteCount() -> Int {
        snapshotFileURLs().reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    func snapshotFileURLs() -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        return contents.filter { url in
            url.pathExtension == TerminalScrollbackSnapshotFormat.fileExtension
                && TerminalScrollbackSnapshotFormat.isValidRef(url.deletingPathExtension().lastPathComponent)
        }
    }

    private func replaceItem(at url: URL, withItemAt temporaryURL: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else {
            try fileManager.moveItem(at: temporaryURL, to: url)
            return url
        }
        return try fileManager.replaceItemAt(
            url,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: []
        )
    }
}

/// Serial off-main owner for snapshot writes and pruning.
///
/// Snapshot IO happens while a window is closing or on a periodic save, both of
/// which run on the main actor; this type keeps the filesystem work off it and
/// gives the queue a single explicit owner instead of a global.
final class TerminalScrollbackSnapshotWriter: @unchecked Sendable {
    private enum Queue {
        static let label = "com.kurotty.terminal-scrollback-snapshot"
    }

    /// Only the root path crosses the queue boundary; `FileManager` is created
    /// on the queue so no non-Sendable state is captured.
    private let rootURL: URL
    private let queue: DispatchQueue

    init(store: TerminalScrollbackSnapshotStore) {
        rootURL = store.rootURL
        queue = DispatchQueue(label: Queue.label, qos: .utility)
    }

    /// Enqueues an atomic write. Failures are swallowed: a missing snapshot
    /// degrades to an empty pane, which is the pre-persistence behavior.
    func write(ref: String, payload: Data, completion: (@Sendable (URL?) -> Void)? = nil) {
        let rootURL = rootURL
        queue.async {
            let store = TerminalScrollbackSnapshotStore(rootURL: rootURL, fileManager: FileManager())
            let url = try? store.write(ref: ref, payload: payload)
            completion?(url ?? nil)
        }
    }

    func prune(
        keepingRefs referencedRefs: Set<String>,
        completion: (@Sendable (TerminalScrollbackSnapshotStore.PruneReport) -> Void)? = nil
    ) {
        let rootURL = rootURL
        queue.async {
            let store = TerminalScrollbackSnapshotStore(rootURL: rootURL, fileManager: FileManager())
            // Pruning must run whether or not anyone wants the report. Passing
            // it straight into `completion?(...)` made the whole call a no-op
            // when `completion` was nil, because optional chaining skips
            // evaluating the argument.
            let report = store.prune(keepingRefs: referencedRefs)
            completion?(report)
        }
    }

    /// Blocks until previously enqueued work has finished. Used by app
    /// termination and by tests; never call it from the write queue itself.
    func waitForPendingWork() {
        queue.sync {}
    }
}
