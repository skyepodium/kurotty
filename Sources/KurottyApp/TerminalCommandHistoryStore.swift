import Foundation

/// One completed shell command captured through OSC 133 shell integration.
/// Privacy contract: only the submitted command text, working directory, and
/// exit metadata are persisted. Raw terminal output is never stored.
struct TerminalCommandHistoryEntry: Codable, Equatable {
    var commandText: String
    var cwd: String?
    /// `user@host` when the command ran on a remote machine over SSH; `nil`
    /// for this Mac.
    ///
    /// Schema migration: the key is absent from every history file written
    /// before remote tracking existed. `Codable` decodes a missing optional as
    /// `nil`, which is exactly the "local" meaning those entries had, so old
    /// files load unchanged and gain the key on the next save.
    var cwdHost: String?
    var exitCode: Int?
    var startedAt: Date?
    var finishedAt: Date
    var duration: TimeInterval?
    var useCount: Int

    /// True when the entry's directory only exists on another machine, so
    /// `cd`/reveal actions must not be pointed at the local filesystem.
    var isRemote: Bool {
        cwdHost != nil
    }

    init(
        commandText: String,
        cwd: String?,
        cwdHost: String? = nil,
        exitCode: Int?,
        startedAt: Date? = nil,
        finishedAt: Date,
        duration: TimeInterval? = nil,
        useCount: Int = 1
    ) {
        self.commandText = commandText
        self.cwd = cwd
        self.cwdHost = cwdHost
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.duration = duration
        self.useCount = useCount
    }
}

/// Bounded, persistent, app-wide command history backed by
/// `Application Support/Kurotty/command-history.json`.
///
/// Lifecycle contract: owned for the app lifetime through `shared`; entries are
/// loaded lazily on first access, saves are debounced and written on a private
/// persistence queue so the main actor never touches the filesystem directly.
/// Capacity is bounded by `AppConstants.CommandHistory.maximumEntryCount` with
/// FIFO eviction.
@MainActor
final class TerminalCommandHistoryStore: NSObject {
    static let shared = TerminalCommandHistoryStore()
    static let didChangeNotification = Notification.Name("dev.kurotty.commandHistory.didChange")

    let historyURL: URL
    private let maximumEntryCount: Int
    private let saveDebounceSeconds: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let persistenceQueue = DispatchQueue(label: AppConstants.CommandHistory.persistenceQueueLabel)
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var loadedEntries: [TerminalCommandHistoryEntry]?
    /// Set by debug seeding: sample entries must stay in memory only, so every
    /// disk write is disabled for the rest of the process lifetime.
    private var isPersistenceDisabledForDebugPreview = false

    /// Live-applied mirror of `terminal.commandHistoryEnabled`.
    private(set) var isRecordingEnabled: Bool

    init(
        historyURL: URL? = nil,
        isRecordingEnabled: Bool? = nil,
        maximumEntryCount: Int = AppConstants.CommandHistory.maximumEntryCount,
        saveDebounceSeconds: TimeInterval = AppConstants.CommandHistory.saveDebounceSeconds,
        observesSettingsChanges: Bool = true
    ) {
        self.historyURL = historyURL ?? Self.defaultHistoryURL()
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.saveDebounceSeconds = saveDebounceSeconds
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.isRecordingEnabled = isRecordingEnabled
            ?? ((try? AppSettingsStore.shared.load())?.terminal.commandHistoryEnabled
                ?? AppSettings.default.terminal.commandHistoryEnabled)
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
        setRecordingEnabled(settings.terminal.commandHistoryEnabled)
    }

    /// Entries ordered newest first for presentation.
    var entriesNewestFirst: [TerminalCommandHistoryEntry] {
        entries().reversed()
    }

    var entryCount: Int {
        entries().count
    }

    func setRecordingEnabled(_ enabled: Bool) {
        guard isRecordingEnabled != enabled else {
            return
        }
        isRecordingEnabled = enabled
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Records a completed command span. Empty or whitespace-only commands are
    /// skipped, and a command identical to the newest entry in the same working
    /// directory is deduplicated in place (latest timestamps win, use count grows).
    func record(completion context: TerminalCommandCompletionContext) {
        guard isRecordingEnabled, let commandText = context.commandText else {
            return
        }
        let finishedAt = Date()
        let entry = TerminalCommandHistoryEntry(
            commandText: commandText,
            cwd: context.cwd,
            cwdHost: context.cwdHost,
            exitCode: context.exitCode,
            startedAt: context.duration.map { finishedAt.addingTimeInterval(-$0) },
            finishedAt: finishedAt,
            duration: context.duration
        )
        record(entry)
    }

    func record(_ entry: TerminalCommandHistoryEntry) {
        guard isRecordingEnabled else {
            return
        }
        let commandText = entry.commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandText.isEmpty, maximumEntryCount > 0 else {
            return
        }

        var normalized = entry
        normalized.commandText = commandText
        var nextEntries = entries()
        // The host is part of the identity: the same command in the same path
        // on two different machines must never collapse into one entry.
        if var newest = nextEntries.last,
           newest.commandText == commandText,
           newest.cwd == normalized.cwd,
           newest.cwdHost == normalized.cwdHost {
            newest.exitCode = normalized.exitCode
            newest.startedAt = normalized.startedAt
            newest.finishedAt = normalized.finishedAt
            newest.duration = normalized.duration
            newest.useCount += 1
            nextEntries[nextEntries.count - 1] = newest
        } else {
            nextEntries.append(normalized)
            let overflow = nextEntries.count - maximumEntryCount
            if overflow > 0 {
                nextEntries.removeFirst(overflow)
            }
        }
        loadedEntries = nextEntries
        scheduleDebouncedSave()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Debug-only preview seeding: replaces the in-memory entries and disables
    /// persistence so sample data never reaches the user's history file.
    func seedInMemoryEntriesForDebugPreview(_ entries: [TerminalCommandHistoryEntry]) {
        isPersistenceDisabledForDebugPreview = true
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        loadedEntries = entries.sorted { $0.finishedAt < $1.finishedAt }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Cancels any pending debounce and writes the current entries synchronously.
    /// Used by tests and shutdown paths that need a durable file immediately.
    func saveImmediately() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        guard !isPersistenceDisabledForDebugPreview else {
            return
        }
        guard let data = try? encoder.encode(entries()) else {
            return
        }
        let historyURL = historyURL
        persistenceQueue.sync {
            Self.write(data, to: historyURL)
        }
    }

    private func entries() -> [TerminalCommandHistoryEntry] {
        if let loadedEntries {
            return loadedEntries
        }
        let loaded = loadEntriesFromDisk()
        loadedEntries = loaded
        return loaded
    }

    private func loadEntriesFromDisk() -> [TerminalCommandHistoryEntry] {
        let historyURL = historyURL
        let data = persistenceQueue.sync { () -> Data? in
            try? Data(contentsOf: historyURL)
        }
        guard let data,
              let decoded = try? decoder.decode([TerminalCommandHistoryEntry].self, from: data)
        else {
            return []
        }
        guard decoded.count > maximumEntryCount else {
            return decoded
        }
        return Array(decoded.suffix(maximumEntryCount))
    }

    private func scheduleDebouncedSave() {
        pendingSaveWorkItem?.cancel()
        // The work item is scheduled on DispatchQueue.main below, so it always
        // executes on the main actor's executor; this mirrors the
        // PreferencesView autosave debounce pattern.
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.performDebouncedSave()
            }
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceSeconds, execute: workItem)
    }

    private func performDebouncedSave() {
        pendingSaveWorkItem = nil
        guard !isPersistenceDisabledForDebugPreview else {
            return
        }
        guard let data = try? encoder.encode(entries()) else {
            return
        }
        let historyURL = historyURL
        persistenceQueue.async {
            Self.write(data, to: historyURL)
        }
    }

    private nonisolated static func write(_ data: Data, to historyURL: URL) {
        let directoryURL = historyURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        try? data.write(to: historyURL, options: .atomic)
    }

    private static func defaultHistoryURL() -> URL {
        AppSettingsStore.shared.settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent(AppConstants.CommandHistory.fileName)
    }
}

/// Realistic in-memory sample entries for `--debug-seed-history` screenshot
/// and visual-verification runs. Never persisted: the store disables disk
/// writes when seeded with this data.
enum TerminalCommandHistoryDebugSeed {
    private struct Sample {
        let commandText: String
        let relativeCwd: String
        let exitCode: Int
        let ageSeconds: TimeInterval
        let durationSeconds: TimeInterval
    }

    private enum Directory {
        static let kurotty = "dev/terminal/kurotty"
        static let toonatic = "dev/toonatic"
        static let kiri = "dev/kiri"
    }

    private static let samples: [Sample] = [
        Sample(commandText: "git status", relativeCwd: Directory.kurotty, exitCode: 0, ageSeconds: 40, durationSeconds: 0.2),
        Sample(commandText: "swift test", relativeCwd: Directory.kurotty, exitCode: 0, ageSeconds: 300, durationSeconds: 42),
        Sample(commandText: "swift build", relativeCwd: Directory.kurotty, exitCode: 0, ageSeconds: 720, durationSeconds: 18),
        Sample(commandText: "git diff --stat", relativeCwd: Directory.kurotty, exitCode: 0, ageSeconds: 1_500, durationSeconds: 0.3),
        Sample(commandText: "./scripts/install-app.sh", relativeCwd: Directory.kurotty, exitCode: 0, ageSeconds: 5_400, durationSeconds: 65),
        Sample(commandText: "npm run dev", relativeCwd: Directory.toonatic, exitCode: 0, ageSeconds: 7_200, durationSeconds: 3),
        Sample(commandText: "npm test", relativeCwd: Directory.toonatic, exitCode: 1, ageSeconds: 10_800, durationSeconds: 12),
        Sample(commandText: "git push origin main", relativeCwd: Directory.toonatic, exitCode: 0, ageSeconds: 18_000, durationSeconds: 2.5),
        Sample(commandText: "npm install", relativeCwd: Directory.toonatic, exitCode: 0, ageSeconds: 86_400, durationSeconds: 34),
        Sample(commandText: "python main.py", relativeCwd: Directory.kiri, exitCode: 2, ageSeconds: 172_800, durationSeconds: 1.1),
        Sample(commandText: "python -m pytest", relativeCwd: Directory.kiri, exitCode: 0, ageSeconds: 176_400, durationSeconds: 21),
        Sample(commandText: "pip install -r requirements.txt", relativeCwd: Directory.kiri, exitCode: 0, ageSeconds: 259_200, durationSeconds: 27),
    ]

    static func sampleEntries(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: Date = Date()
    ) -> [TerminalCommandHistoryEntry] {
        samples.map { sample in
            let finishedAt = now.addingTimeInterval(-sample.ageSeconds)
            return TerminalCommandHistoryEntry(
                commandText: sample.commandText,
                cwd: homeDirectory + "/" + sample.relativeCwd,
                exitCode: sample.exitCode,
                startedAt: finishedAt.addingTimeInterval(-sample.durationSeconds),
                finishedAt: finishedAt,
                duration: sample.durationSeconds
            )
        }
    }
}
