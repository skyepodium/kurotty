import Foundation

/// Read-only transcript session: initial tail paint plus incremental
/// tail-follow.
///
/// Concurrency contract: every file read and every JSON decode runs on this
/// object's private queue. The main actor only ever receives an already-built
/// row list, and appends arrive in batches so a fast-writing agent cannot spin
/// the UI once per record.
///
/// There is no send path of any kind. The controller owns a file URL and a
/// decoder; it never holds a PTY, a session, or a writer.
@MainActor
final class AgentSessionTranscriptController {
    struct Snapshot: Equatable {
        var rows: [AgentTranscriptRow]
        var messageCount: Int
        var hasOlderRecords: Bool
        var oversizedRecordCount: Int
        var isNativeWatchActive: Bool

        static let empty = Snapshot(
            rows: [],
            messageCount: 0,
            hasOlderRecords: false,
            oversizedRecordCount: 0,
            isNativeWatchActive: false
        )
    }

    private enum Queue {
        static let label = "com.kurotty.agent-transcript-reader"
    }

    /// Upper bound on retained messages so an always-open viewer on a busy
    /// session stays bounded.
    static let maximumRetainedMessageCount = 4_000

    let record: AgentSessionRecord
    var onChange: ((Snapshot) -> Void)?

    private let fileURL: URL
    private let decoder: AgentSessionTranscriptDecoding
    private let readQueue: DispatchQueue
    private var watcher: AgentSessionTranscriptWatcher?
    private var incrementalReader: AgentSessionTranscriptIncrementalReader
    private var messages: [AgentTranscriptMessage] = []
    private var foldState = AgentTranscriptFoldState()
    private var hasOlderRecords = false
    private var oversizedRecordCount = 0
    private var isReadInFlight = false
    private var isFollowRequestPending = false

    init(record: AgentSessionRecord) {
        self.record = record
        fileURL = URL(fileURLWithPath: record.filePath)
        decoder = AgentSessionTranscriptDecoderFactory.decoder(for: record.agent)
        readQueue = DispatchQueue(label: Queue.label, qos: .userInitiated)
        incrementalReader = AgentSessionTranscriptIncrementalReader()
    }

    deinit {
        watcher?.stop()
    }

    var snapshot: Snapshot {
        Snapshot(
            rows: AgentTranscriptRowBuilder.rows(messages: messages, foldState: foldState),
            messageCount: messages.count,
            hasOlderRecords: hasOlderRecords,
            oversizedRecordCount: oversizedRecordCount,
            isNativeWatchActive: watcher?.isNativeWatchActive ?? false
        )
    }

    /// Paints the tail, then starts following. Safe to call once per viewer.
    func start() {
        loadInitialTail()
        let watcher = AgentSessionTranscriptWatcher(fileURL: fileURL) { [weak self] in
            DispatchQueue.main.async {
                self?.followTail()
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Expands or collapses one tool run. Purely a projection change: no file
    /// is touched.
    func toggleToolRun(id: String) {
        foldState.toggle(id)
        onChange?(snapshot)
    }

    func collapseAllToolRuns() {
        foldState.collapseAll()
        onChange?(snapshot)
    }

    // MARK: - Reading

    private func loadInitialTail() {
        let fileURL = fileURL
        let decoder = decoder
        let filePath = record.filePath
        readQueue.async { [weak self] in
            let result = AgentSessionTranscriptTailReader.readTail(fileURL: fileURL)
            let decoded = Self.decode(
                lines: result.lines,
                decoder: decoder,
                filePath: filePath
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.messages = decoded
                self.hasOlderRecords = result.hasMore
                self.oversizedRecordCount = result.oversizedRecordCount
                self.incrementalReader = AgentSessionTranscriptIncrementalReader(offset: result.consumedTo)
                self.onChange?(self.snapshot)
            }
        }
    }

    /// Coalesces overlapping change notifications: the watcher fires far more
    /// often than the file actually grows, and a reconcile tick can land while
    /// a read is still running.
    private func followTail() {
        guard !isReadInFlight else {
            isFollowRequestPending = true
            return
        }
        isReadInFlight = true

        let fileURL = fileURL
        let decoder = decoder
        let filePath = record.filePath
        var reader = incrementalReader
        readQueue.async { [weak self] in
            let sizeBytes = (try? FileManager().attributesOfItem(atPath: filePath)[.size] as? Int)
                .flatMap { $0 } ?? 0
            let didReset = reader.resetIfFileShrank(fileSizeBytes: sizeBytes)
            let lines = reader.readAppendedLines(fileURL: fileURL)
            let decoded = Self.decode(lines: lines, decoder: decoder, filePath: filePath)
            let batches = stride(
                from: 0,
                to: decoded.count,
                by: AppConstants.AgentTranscript.appendBatchMessageCount
            ).map { start in
                Array(decoded[start..<min(start + AppConstants.AgentTranscript.appendBatchMessageCount, decoded.count)])
            }
            let updatedReader = reader
            let oversizedRecordCount = reader.oversizedRecordCount
            DispatchQueue.main.async {
                guard let self else { return }
                self.incrementalReader = updatedReader
                self.oversizedRecordCount = max(self.oversizedRecordCount, oversizedRecordCount)
                if didReset {
                    self.messages.removeAll()
                }
                for batch in batches {
                    self.appendBatch(batch)
                }
                if !batches.isEmpty || didReset {
                    self.onChange?(self.snapshot)
                }
                self.isReadInFlight = false
                guard self.isFollowRequestPending else { return }
                self.isFollowRequestPending = false
                self.followTail()
            }
        }
    }

    private func appendBatch(_ batch: [AgentTranscriptMessage]) {
        messages += batch
        guard messages.count > Self.maximumRetainedMessageCount else {
            return
        }
        messages.removeFirst(messages.count - Self.maximumRetainedMessageCount)
        hasOlderRecords = true
    }

    /// Explicitly `nonisolated`: this runs on `readQueue`, and a main-actor
    /// isolated helper would trap on `_swift_task_checkIsolatedSwift` the
    /// moment the read queue touched it.
    private nonisolated static func decode(
        lines: [AgentTranscriptLine],
        decoder: AgentSessionTranscriptDecoding,
        filePath: String
    ) -> [AgentTranscriptMessage] {
        lines.compactMap { line in
            decoder.decode(
                line: line.text,
                fallbackID: AgentTranscriptFallbackID.make(
                    filePath: filePath,
                    byteOffset: line.byteOffset
                ),
                byteOffset: line.byteOffset
            )
        }
    }
}
