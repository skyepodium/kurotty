import Foundation

/// Bounded, persistent quick-command list backed by
/// `Application Support/Kurotty/quick-commands.json`.
///
/// Lifecycle contract: owned for the app lifetime through `shared`; commands
/// are loaded lazily on first access, saves are debounced and written on a
/// private persistence queue with an atomic replace, so the main actor never
/// blocks on the filesystem for a write. Capacity is bounded by
/// `AppConstants.QuickCommands.maximumCommandCount`.
///
/// Privacy contract: only user-authored names and command text are persisted.
/// No terminal output, pasteboard content, or environment data is stored.
@MainActor
final class QuickCommandStore: NSObject {
    static let shared = QuickCommandStore()
    static let didChangeNotification = Notification.Name(
        AppConstants.QuickCommands.didChangeNotificationName
    )

    let storeURL: URL
    private let saveDebounceSeconds: TimeInterval
    private let seedsWhenFileIsMissing: Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let persistenceQueue = DispatchQueue(label: AppConstants.QuickCommands.persistenceQueueLabel)
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var loadedCommands: [QuickCommand]?

    init(
        storeURL: URL? = nil,
        saveDebounceSeconds: TimeInterval = AppConstants.QuickCommands.saveDebounceSeconds,
        seedsWhenFileIsMissing: Bool = true
    ) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        self.saveDebounceSeconds = saveDebounceSeconds
        self.seedsWhenFileIsMissing = seedsWhenFileIsMissing
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        super.init()
    }

    /// Normalized commands in author order.
    var commands: [QuickCommand] {
        loadedCommandsOrLoad()
    }

    var commandCount: Int {
        commands.count
    }

    func command(withID id: String) -> QuickCommand? {
        commands.first { $0.id == id }
    }

    /// Commands offered for a pane whose working directory is `cwd`.
    func commands(forWorkingDirectory cwd: String?) -> [QuickCommand] {
        QuickCommandNormalizer.visibleCommands(commands, inWorkingDirectory: cwd)
    }

    /// Applies one add/replace/remove and persists. Returns the new list.
    @discardableResult
    func apply(_ mutation: QuickCommandMutation) -> [QuickCommand] {
        let merged = QuickCommandNormalizer.apply(mutation, to: loadedCommandsOrLoad())
        return replaceAll(merged)
    }

    /// Replaces the whole list. Always normalized, so the cap, the identifier
    /// uniqueness rule, and the length limits hold for every stored command.
    @discardableResult
    func replaceAll(_ commands: [QuickCommand]) -> [QuickCommand] {
        let normalized = QuickCommandNormalizer.normalize(commands)
        loadedCommands = normalized
        scheduleDebouncedSave()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return normalized
    }

    /// Cancels any pending debounce and writes synchronously. Used by tests
    /// and shutdown paths that need a durable file immediately.
    func saveImmediately() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        guard let data = encodedDocument() else {
            return
        }
        let storeURL = storeURL
        persistenceQueue.sync {
            Self.write(data, to: storeURL)
        }
    }

    private func loadedCommandsOrLoad() -> [QuickCommand] {
        if let loadedCommands {
            return loadedCommands
        }
        let loaded = loadCommandsFromDisk()
        loadedCommands = loaded
        return loaded
    }

    /// A missing file seeds the starter commands exactly once: `nil` data means
    /// the user has never had a quick-command file, while unreadable or
    /// undecodable data means an existing file we must not overwrite with
    /// seeds. The filesystem read happens on the persistence queue.
    private func loadCommandsFromDisk() -> [QuickCommand] {
        let storeURL = storeURL
        let data = persistenceQueue.sync { () -> Data? in
            try? Data(contentsOf: storeURL)
        }
        guard let data else {
            guard seedsWhenFileIsMissing else {
                return []
            }
            let seeds = QuickCommandSeeds.starterCommands()
            scheduleDebouncedSaveForSeeds(seeds)
            return seeds
        }
        guard let document = try? decoder.decode(QuickCommandsDocument.self, from: data) else {
            return []
        }
        return QuickCommandNormalizer.normalize(records: document.commands)
    }

    private func scheduleDebouncedSaveForSeeds(_ seeds: [QuickCommand]) {
        loadedCommands = seeds
        scheduleDebouncedSave()
    }

    private func encodedDocument() -> Data? {
        let document = QuickCommandsDocument(
            commands: loadedCommandsOrLoad().map(QuickCommandNormalizer.record(for:))
        )
        return try? encoder.encode(document)
    }

    private func scheduleDebouncedSave() {
        pendingSaveWorkItem?.cancel()
        // Scheduled on DispatchQueue.main below, so the work item always runs
        // on the main actor's executor; this mirrors the command-history store.
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
        guard let data = encodedDocument() else {
            return
        }
        let storeURL = storeURL
        persistenceQueue.async {
            Self.write(data, to: storeURL)
        }
    }

    private nonisolated static func write(_ data: Data, to storeURL: URL) {
        let directoryURL = storeURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func defaultStoreURL() -> URL {
        AppSettingsStore.shared.settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent(AppConstants.QuickCommands.storageFileName)
    }
}

/// Starter commands written once, only when no quick-command file exists.
///
/// Every seed is insert-only (`appendEnter == false`), so a fresh install can
/// never execute anything the user did not type Return for themselves.
enum QuickCommandSeeds {
    private enum Identifier {
        static let gitStatus = "seed-git-status"
        static let gitDiffStat = "seed-git-diff-stat"
        static let gitLogGraph = "seed-git-log-graph"
        static let claudeResume = "seed-claude-resume"
    }

    private enum CommandText {
        static let gitStatus = "git status"
        static let gitDiffStat = "git diff --stat"
        static let gitLogGraph = "git log --oneline --graph -20"
        static let claudeResume = "claude --resume"
    }

    static func starterCommands() -> [QuickCommand] {
        [
            QuickCommand(
                id: Identifier.gitStatus,
                name: AppLocalization.string(.quickCommandSeedGitStatus),
                action: .terminalCommand(text: CommandText.gitStatus, appendEnter: false)
            ),
            QuickCommand(
                id: Identifier.gitDiffStat,
                name: AppLocalization.string(.quickCommandSeedGitDiffStat),
                action: .terminalCommand(text: CommandText.gitDiffStat, appendEnter: false)
            ),
            QuickCommand(
                id: Identifier.gitLogGraph,
                name: AppLocalization.string(.quickCommandSeedGitLogGraph),
                action: .terminalCommand(text: CommandText.gitLogGraph, appendEnter: false)
            ),
            QuickCommand(
                id: Identifier.claudeResume,
                name: AppLocalization.string(.quickCommandSeedClaudeResume),
                action: .terminalCommand(text: CommandText.claudeResume, appendEnter: false)
            ),
        ]
    }
}
