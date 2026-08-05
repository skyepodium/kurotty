import Foundation

/// Git worktree awareness for the bottom status bar: a pure
/// `git worktree list --porcelain` parser, pure containment/attribution rules,
/// and a cancellation-safe async runner that shells out to the `git` CLI off
/// the main actor and completes on the main actor.
///
/// The split mirrors `TerminalGitStatusService`: everything that decides
/// something is a pure function over process output, and the only impure part
/// is the runner that produces that output.

// MARK: - Model

/// One entry of `git worktree list --porcelain`.
///
/// Git prints the main worktree first and every linked worktree after it, so
/// `isMain` is positional rather than a porcelain attribute. A bare repository
/// occupies that first record without a checkout, which is why `headSHA` and
/// `branchReference` are both optional.
struct GitWorktree: Equatable, Sendable {
    let path: String
    let headSHA: String?
    /// The ref exactly as git reports it (`refs/heads/topic`); `nil` for a
    /// detached HEAD and for the bare record.
    let branchReference: String?
    let isBare: Bool
    let isDetached: Bool
    let isLocked: Bool
    /// Free text git was given at `worktree lock --reason`; `nil` when the
    /// worktree is unlocked or was locked without a reason.
    let lockReason: String?
    let isPrunable: Bool
    /// True for the repository's main worktree, which git always lists first.
    let isMain: Bool

    init(
        path: String,
        headSHA: String? = nil,
        branchReference: String? = nil,
        isBare: Bool = false,
        isDetached: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false,
        isMain: Bool = false
    ) {
        self.path = path
        self.headSHA = headSHA
        self.branchReference = branchReference
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.isMain = isMain
    }

    /// `refs/heads/feature/one` -> `feature/one`. `nil` when there is no branch.
    var branchName: String? {
        guard let branchReference else {
            return nil
        }
        guard branchReference.hasPrefix(GitWorktreePorcelain.branchReferencePrefix) else {
            return branchReference
        }
        return String(branchReference.dropFirst(GitWorktreePorcelain.branchReferencePrefix.count))
    }

    /// Abbreviated commit for a detached checkout, matching git's own default
    /// short-object length.
    var shortHeadSHA: String? {
        guard let headSHA, headSHA.count >= GitWorktreePorcelain.shortObjectLengthCOUNT else {
            return headSHA
        }
        return String(headSHA.prefix(GitWorktreePorcelain.shortObjectLengthCOUNT))
    }

    /// Last path component, used when a worktree has no branch to name it.
    var directoryName: String {
        (path as NSString).lastPathComponent
    }
}

/// Field names of the porcelain format, shared by the parser and the model.
enum GitWorktreePorcelain {
    static let worktreeKey = "worktree"
    static let headKey = "HEAD"
    static let branchKey = "branch"
    static let detachedKey = "detached"
    static let bareKey = "bare"
    static let lockedKey = "locked"
    static let prunableKey = "prunable"
    static let branchReferencePrefix = "refs/heads/"
    static let shortObjectLengthCOUNT = 7
    static let keyValueSeparator: Character = " "
    static let lineSeparator: Character = "\n"
}

// MARK: - Porcelain parser

/// Parses `git worktree list --porcelain`.
///
/// Format: one record per worktree, records separated by a blank line. A record
/// opens with `worktree <path>` and continues with attribute lines that are
/// either bare labels (`detached`, `bare`) or a key plus a value
/// (`HEAD <sha>`, `branch <ref>`, `locked <reason>`, `prunable <reason>`).
/// Paths are printed verbatim, so a path containing spaces is the whole
/// remainder of the line and must never be split on whitespace.
enum GitWorktreeListParser {
    static func parse(porcelainOutput output: String) -> [GitWorktree] {
        var worktrees: [GitWorktree] = []
        var record = PartialRecord()
        for line in output.split(separator: GitWorktreePorcelain.lineSeparator, omittingEmptySubsequences: false) {
            let text = String(line)
            guard !text.isEmpty else {
                append(&record, to: &worktrees)
                continue
            }
            let (key, value) = splitField(text)
            guard key != GitWorktreePorcelain.worktreeKey else {
                // A new `worktree` line always opens a record, even when the
                // previous one was not terminated by a blank line.
                append(&record, to: &worktrees)
                record.path = value
                continue
            }
            apply(key: key, value: value, to: &record)
        }
        append(&record, to: &worktrees)
        return worktrees
    }

    /// Splits `key value` on the first space. A line without a space is a bare
    /// label and yields an empty value.
    private static func splitField(_ line: String) -> (key: String, value: String?) {
        guard let separatorIndex = line.firstIndex(of: GitWorktreePorcelain.keyValueSeparator) else {
            return (line, nil)
        }
        let value = String(line[line.index(after: separatorIndex)...])
        return (String(line[..<separatorIndex]), value.isEmpty ? nil : value)
    }

    private static func apply(key: String, value: String?, to record: inout PartialRecord) {
        switch key {
        case GitWorktreePorcelain.headKey:
            record.headSHA = value
        case GitWorktreePorcelain.branchKey:
            record.branchReference = value
        case GitWorktreePorcelain.detachedKey:
            record.isDetached = true
        case GitWorktreePorcelain.bareKey:
            record.isBare = true
        case GitWorktreePorcelain.lockedKey:
            record.isLocked = true
            record.lockReason = value
        case GitWorktreePorcelain.prunableKey:
            record.isPrunable = true
        default:
            // Unknown attributes are ignored so a newer git cannot break the
            // records Kurotty does understand.
            break
        }
    }

    private static func append(_ record: inout PartialRecord, to worktrees: inout [GitWorktree]) {
        defer {
            record = PartialRecord()
        }
        guard let path = record.path, !path.isEmpty else {
            return
        }
        worktrees.append(GitWorktree(
            path: path,
            headSHA: record.headSHA,
            branchReference: record.branchReference,
            isBare: record.isBare,
            isDetached: record.isDetached,
            isLocked: record.isLocked,
            lockReason: record.lockReason,
            isPrunable: record.isPrunable,
            isMain: worktrees.isEmpty
        ))
    }

    private struct PartialRecord {
        var path: String?
        var headSHA: String?
        var branchReference: String?
        var isBare = false
        var isDetached = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false
    }
}

// MARK: - Containment

/// Which worktree a directory belongs to.
///
/// Worktrees can nest — a linked worktree created inside the main checkout is
/// contained by both — so the deepest match wins. Matching is path-component
/// aware: `/repo/feature-two` is not inside `/repo/feature`.
enum GitWorktreeLocator {
    private enum Path {
        static let separator = "/"
    }

    static func worktree(containing directoryPath: String, in worktrees: [GitWorktree]) -> GitWorktree? {
        let directory = normalized(directoryPath)
        guard !directory.isEmpty else {
            return nil
        }
        return worktrees
            .filter { !$0.isBare && contains(worktreePath: $0.path, directoryPath: directory) }
            .max { normalized($0.path).count < normalized($1.path).count }
    }

    static func contains(worktreePath: String, directoryPath: String) -> Bool {
        let root = normalized(worktreePath)
        let directory = normalized(directoryPath)
        guard !root.isEmpty, !directory.isEmpty else {
            return false
        }
        guard directory != root else {
            return true
        }
        return directory.hasPrefix(root + Path.separator)
    }

    /// Trims whitespace and any trailing separator so `/repo` and `/repo/`
    /// compare equal.
    static func normalized(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix(Path.separator) {
            trimmed.removeLast()
        }
        return trimmed
    }
}

// MARK: - Dirty state

/// Whether a checkout has anything uncommitted.
enum GitWorktreeDirtyState {
    /// Any record in `git status --porcelain=v1 -z` output means the checkout
    /// differs from HEAD. Ignored files are deliberately not requested, so a
    /// build directory cannot make every worktree look dirty.
    static func isDirty(porcelainZOutput output: String) -> Bool {
        !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Snapshot and rows

/// Everything one collection pass learned about the repository containing the
/// active pane's working directory.
struct TerminalGitWorktreeSnapshot: Equatable, Sendable {
    let worktrees: [GitWorktree]
    /// Paths of worktrees with uncommitted changes.
    let dirtyPaths: Set<String>
    /// The worktree the pane's working directory is in, resolved by git itself
    /// rather than by string matching; `nil` when the directory is inside the
    /// repository's administrative area only.
    let currentWorktreePath: String?

    static let empty = TerminalGitWorktreeSnapshot(worktrees: [], dirtyPaths: [], currentWorktreePath: nil)

    var currentWorktree: GitWorktree? {
        guard let currentWorktreePath else {
            return nil
        }
        return worktrees.first { GitWorktreeLocator.normalized($0.path) == GitWorktreeLocator.normalized(currentWorktreePath) }
    }
}

/// One presentable row of the worktree popover.
struct GitWorktreeRow: Equatable, Sendable {
    let worktree: GitWorktree
    let isDirty: Bool
    /// Indexed agent sessions whose `cwd` is inside this worktree.
    let agentSessionCount: Int
    let isCurrent: Bool
}

/// Pure composition of popover rows from a snapshot plus the agent session
/// index. Bare records are dropped: they hold no checkout, so there is nothing
/// to change into and nothing that can be dirty.
enum GitWorktreeRowBuilder {
    static func rows(
        snapshot: TerminalGitWorktreeSnapshot,
        records: [AgentSessionRecord]
    ) -> [GitWorktreeRow] {
        let checkouts = snapshot.worktrees.filter { !$0.isBare }
        let counts = sessionCounts(worktrees: checkouts, records: records)
        let currentPath = snapshot.currentWorktreePath.map(GitWorktreeLocator.normalized)
        return checkouts.map { worktree in
            GitWorktreeRow(
                worktree: worktree,
                isDirty: snapshot.dirtyPaths.contains(worktree.path),
                agentSessionCount: counts[worktree.path] ?? 0,
                isCurrent: GitWorktreeLocator.normalized(worktree.path) == currentPath
            )
        }
    }

    /// Each record is attributed to exactly one worktree — the deepest one that
    /// contains its `cwd` — so a linked worktree nested inside the main
    /// checkout does not have its sessions counted twice.
    static func sessionCounts(
        worktrees: [GitWorktree],
        records: [AgentSessionRecord]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in records {
            guard let owner = GitWorktreeLocator.worktree(containing: record.cwd, in: worktrees) else {
                continue
            }
            counts[owner.path, default: 0] += 1
        }
        return counts
    }
}

// MARK: - Runner

/// Blocking git invocations. Only call off the main actor.
enum TerminalGitWorktreeRunner {
    private enum GitCommand {
        static let envExecutablePath = "/usr/bin/env"
        static let gitExecutableName = "git"
        static let workingDirectoryFlag = "-C"
        /// Resolves the *containing* worktree: inside a linked worktree this
        /// returns that worktree's root, not the main checkout.
        static let currentWorktreeArguments = ["rev-parse", "--show-toplevel"]
        static let listArguments = ["worktree", "list", "--porcelain"]
        static let dirtyArguments = ["status", "--porcelain=v1", "-z"]
    }

    /// Returns `nil` when the directory is not inside a git work tree or when
    /// git is unavailable, so the status bar renders no worktree segment at all.
    static func collectSnapshot(workingDirectoryPath: String) -> TerminalGitWorktreeSnapshot? {
        let directoryArguments = [GitCommand.workingDirectoryFlag, workingDirectoryPath]
        guard let listOutput = runGit(arguments: directoryArguments + GitCommand.listArguments) else {
            return nil
        }
        let worktrees = GitWorktreeListParser.parse(porcelainOutput: listOutput)
        guard !worktrees.isEmpty else {
            return nil
        }
        let currentWorktreePath = runGit(arguments: directoryArguments + GitCommand.currentWorktreeArguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TerminalGitWorktreeSnapshot(
            worktrees: worktrees,
            dirtyPaths: dirtyPaths(worktrees: worktrees),
            currentWorktreePath: (currentWorktreePath?.isEmpty ?? true) ? nil : currentWorktreePath
        )
    }

    /// One `git status` per checkout, bounded: a repository with dozens of
    /// worktrees must not turn one refresh into dozens of processes.
    private static func dirtyPaths(worktrees: [GitWorktree]) -> Set<String> {
        var dirtyPaths: Set<String> = []
        for worktree in worktrees.filter({ !$0.isBare }).prefix(AppConstants.GitWorktree.dirtyCheckMaximumCOUNT) {
            let arguments = [GitCommand.workingDirectoryFlag, worktree.path] + GitCommand.dirtyArguments
            guard let output = runGit(arguments: arguments),
                  GitWorktreeDirtyState.isDirty(porcelainZOutput: output)
            else {
                continue
            }
            dirtyPaths.insert(worktree.path)
        }
        return dirtyPaths
    }

    private static func runGit(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitCommand.envExecutablePath)
        process.arguments = [GitCommand.gitExecutableName] + arguments
        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        // stderr is discarded, so it must not be an unread Pipe: a chatty git
        // fills the ~64 KB pipe buffer, blocks, and wedges this serial queue
        // (and every queued request behind it) forever.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let outputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(data: outputData, encoding: .utf8)
    }
}

// MARK: - Async service

/// What the status bar needs from a worktree collector. The bar depends on this
/// rather than on the concrete service, so a test can drive the segment without
/// a repository on disk.
@MainActor
protocol TerminalGitWorktreeProviding: AnyObject {
    func requestSnapshot(
        workingDirectoryPath: String,
        completion: @escaping @MainActor (TerminalGitWorktreeSnapshot?) -> Void
    )
    func cancelPendingRequests()
}

/// Owns one utility queue for worktree lookups. Requests are generation-stamped
/// so a newer request or `cancelPendingRequests()` drops stale completions; the
/// completion always runs on the main actor.
@MainActor
final class TerminalGitWorktreeService: TerminalGitWorktreeProviding {
    private enum QueueToken {
        static let label = "com.kurotty.status-bar.git-worktree"
    }

    private let queue = DispatchQueue(label: QueueToken.label, qos: .utility)
    private var generation = 0

    func requestSnapshot(
        workingDirectoryPath: String,
        completion: @escaping @MainActor (TerminalGitWorktreeSnapshot?) -> Void
    ) {
        generation += 1
        let requestGeneration = generation
        queue.async { [weak self] in
            let snapshot = TerminalGitWorktreeRunner.collectSnapshot(workingDirectoryPath: workingDirectoryPath)
            // Hop from the service-owned queue to the main actor; the
            // generation check on the main actor keeps cancellation safe.
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration else {
                    return
                }
                completion(snapshot)
            }
        }
    }

    func cancelPendingRequests() {
        generation += 1
    }
}
