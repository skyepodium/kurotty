import Foundation

/// In-memory index of agent session transcripts that already exist on disk,
/// gated by `terminal.agentSessionIndexEnabled`.
///
/// Privacy contract: nothing is written. The store never copies transcript
/// content into Kurotty's own storage; it holds `AgentSessionRecord` metadata
/// in memory for the process lifetime and drops it when indexing is disabled.
///
/// Lifecycle contract: owned for the app lifetime through `shared`. Every scan
/// runs on a detached task, so no filesystem work touches the main actor;
/// results are published on the main actor through `didChangeNotification`,
/// mirroring `TerminalCommandHistoryStore`.
@MainActor
final class AgentSessionIndexStore: NSObject {
    static let shared = AgentSessionIndexStore()
    static let didChangeNotification = Notification.Name("dev.kurotty.agentSessionIndex.didChange")

    /// Reuse key for an already-parsed transcript. A file is re-read only when
    /// its modification date or size changed.
    private struct CacheEntry: Sendable {
        let modificationDate: Date
        let sizeBytes: Int
        let record: AgentSessionRecord
    }

    private struct ScanOutcome: Sendable {
        let records: [AgentSessionRecord]
        let cache: [String: CacheEntry]
    }

    /// Records ordered newest-updated first and capped at
    /// `AppConstants.AgentSessions.maximumSessionCount`.
    private(set) var records: [AgentSessionRecord] = []
    private(set) var isIndexingEnabled: Bool
    private(set) var isScanning = false
    private(set) var hasCompletedInitialScan = false

    private let homeDirectory: URL
    private let scanners: [any AgentSessionScanning]
    private var cache: [String: CacheEntry] = [:]
    private var wantsRescanAfterCurrentScan = false

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        scanners: [any AgentSessionScanning] = [ClaudeSessionScanner(), CodexSessionScanner()],
        isIndexingEnabled: Bool? = nil,
        observesSettingsChanges: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.scanners = scanners
        self.isIndexingEnabled = isIndexingEnabled
            ?? ((try? AppSettingsStore.shared.load())?.terminal.agentSessionIndexEnabled
                ?? AppSettings.default.terminal.agentSessionIndexEnabled)
        super.init()
        guard observesSettingsChanges else {
            return
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        setIndexingEnabled(settings.terminal.agentSessionIndexEnabled)
    }

    /// Live-applied mirror of `terminal.agentSessionIndexEnabled`. Turning the
    /// setting off drops every indexed record immediately.
    func setIndexingEnabled(_ enabled: Bool) {
        guard isIndexingEnabled != enabled else {
            return
        }
        isIndexingEnabled = enabled
        guard enabled else {
            records = []
            cache = [:]
            hasCompletedInitialScan = false
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            return
        }
        refresh()
    }

    /// Starts a background rescan. Safe to call redundantly: a scan already in
    /// flight is not duplicated, and one follow-up pass is queued instead.
    /// Returns immediately; no filesystem work happens on the main actor.
    func refresh() {
        guard isIndexingEnabled else {
            guard !records.isEmpty else {
                return
            }
            records = []
            cache = [:]
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            return
        }
        guard !isScanning else {
            wantsRescanAfterCurrentScan = true
            return
        }
        isScanning = true
        let cacheSnapshot = cache
        let homeDirectory = homeDirectory
        let scanners = scanners
        Task.detached(priority: .utility) { [weak self] in
            let outcome = Self.scan(
                scanners: scanners,
                homeDirectory: homeDirectory,
                cache: cacheSnapshot
            )
            await MainActor.run {
                self?.applyScanOutcome(outcome)
            }
        }
    }

    /// Test seam: replaces the indexed records without touching the filesystem.
    func setRecordsForTesting(_ records: [AgentSessionRecord]) {
        self.records = AgentSessionRowBuilder.sorted(records, by: .updated)
        hasCompletedInitialScan = true
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func applyScanOutcome(_ outcome: ScanOutcome) {
        isScanning = false
        hasCompletedInitialScan = true
        guard isIndexingEnabled else {
            records = []
            cache = [:]
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            return
        }
        records = outcome.records
        cache = outcome.cache
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        guard wantsRescanAfterCurrentScan else {
            return
        }
        wantsRescanAfterCurrentScan = false
        refresh()
    }

    // MARK: - Background scan

    /// Pure-ish scan step executed off the main actor: walks each scanner's
    /// root, reuses cached records for unchanged files, and parses the rest
    /// through the bounded transcript reader.
    private nonisolated static func scan(
        scanners: [any AgentSessionScanning],
        homeDirectory: URL,
        cache: [String: CacheEntry]
    ) -> ScanOutcome {
        // FileManager.default is shared app-wide; a private instance keeps the
        // background enumeration off it.
        let fileManager = FileManager()
        var records: [AgentSessionRecord] = []
        var nextCache: [String: CacheEntry] = [:]

        for scanner in scanners {
            let rootURL = scanner.rootURL(homeDirectory: homeDirectory)
            for fileURL in scanner.sessionFileURLs(rootURL: rootURL, fileManager: fileManager) {
                guard let attributes = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                ),
                    let modificationDate = attributes.contentModificationDate,
                    let sizeBytes = attributes.fileSize
                else {
                    continue
                }
                let path = fileURL.path
                if let cached = cache[path],
                   cached.modificationDate == modificationDate,
                   cached.sizeBytes == sizeBytes {
                    nextCache[path] = cached
                    records.append(cached.record)
                    continue
                }
                guard let read = AgentSessionTranscriptReader.read(fileURL: fileURL, sizeBytes: sizeBytes),
                      let record = scanner.parse(
                          contents: read.contents,
                          fileURL: fileURL,
                          modifiedAt: modificationDate,
                          isTranscriptTruncated: read.isTruncated
                      )
                else {
                    continue
                }
                nextCache[path] = CacheEntry(
                    modificationDate: modificationDate,
                    sizeBytes: sizeBytes,
                    record: record
                )
                records.append(record)
            }
        }

        let newestFirst = AgentSessionRowBuilder.sorted(records, by: .updated)
        let capped = Array(newestFirst.prefix(AppConstants.AgentSessions.maximumSessionCount))
        // Only keep cache entries for the records that survived the cap so the
        // cache cannot outgrow the published index.
        let keptPaths = Set(capped.map(\.filePath))
        return ScanOutcome(
            records: capped,
            cache: nextCache.filter { keptPaths.contains($0.key) }
        )
    }
}
