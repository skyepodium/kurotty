import Foundation

/// Git status collection for the file-explorer panel: a pure porcelain `-z`
/// parser plus a cancellation-safe async runner that shells out to the `git`
/// CLI off the main actor and completes on the main actor.

// MARK: - Snapshot

struct GitStatusSnapshot: Equatable, Sendable {
    var modifiedRelativePaths: [String] = []
    /// Staged in the index with a clean worktree side.
    var stagedRelativePaths: [String] = []
    /// Unmerged: both sides of a merge touched the path.
    var conflictedRelativePaths: [String] = []
    var untrackedRelativePaths: [String] = []
    var ignoredRelativePaths: [String] = []

    static let empty = GitStatusSnapshot()
}

// MARK: - Porcelain parser

/// Parses `git status --porcelain=v1 -z --ignored=matching` output.
///
/// `-z` framing: records are NUL-terminated, paths are raw bytes without C
/// quoting (spaces and quotes pass through verbatim), and rename/copy records
/// are followed by one extra NUL-terminated origin-path field that must be
/// consumed without being classified as its own entry.
struct GitPorcelainParser {
    private enum Field {
        static let recordSeparator: Character = "\u{0}"
        static let statusLetterCount = 2
        /// Two status letters plus the separating space.
        static let pathOffsetCount = 3
        /// Shortest valid record: `XY` + space + one path character.
        static let minimumRecordCount = 4
        static let ignoredStatus = "!!"
        static let untrackedStatus = "??"
        static let unmergedStatusLetter: Character = "U"
        /// Porcelain v1 unmerged records that carry no `U` at all.
        static let unmergedPairStatuses: Set<String> = ["AA", "DD"]
        static let unchangedStatusLetter: Character = " "
        static let renameStatusLetter: Character = "R"
        static let copyStatusLetter: Character = "C"
        static let directorySuffix = "/"
    }

    /// Splits a tracked porcelain record into conflicted / staged / modified.
    ///
    /// Porcelain v1 spells the index state in the first letter and the worktree
    /// state in the second. A record is unmerged when either letter is `U`, or
    /// when both letters are the same add/delete pair (`AA`, `DD`); it is purely
    /// staged when the index letter is set and the worktree letter is a space.
    private static func classifyTrackedRecord(
        statusField: String,
        path: String,
        into snapshot: inout GitStatusSnapshot
    ) {
        let indexLetter = statusField.first ?? Field.unchangedStatusLetter
        let worktreeLetter = statusField.last ?? Field.unchangedStatusLetter
        guard !isUnmerged(statusField: statusField, indexLetter: indexLetter, worktreeLetter: worktreeLetter) else {
            snapshot.conflictedRelativePaths.append(path)
            return
        }
        guard worktreeLetter == Field.unchangedStatusLetter,
              indexLetter != Field.unchangedStatusLetter
        else {
            snapshot.modifiedRelativePaths.append(path)
            return
        }
        snapshot.stagedRelativePaths.append(path)
    }

    private static func isUnmerged(
        statusField: String,
        indexLetter: Character,
        worktreeLetter: Character
    ) -> Bool {
        indexLetter == Field.unmergedStatusLetter
            || worktreeLetter == Field.unmergedStatusLetter
            || Field.unmergedPairStatuses.contains(statusField)
    }

    static func parse(porcelainZOutput output: String) -> GitStatusSnapshot {
        var snapshot = GitStatusSnapshot()
        let records = output
            .split(separator: Field.recordSeparator, omittingEmptySubsequences: true)
            .map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count >= Field.minimumRecordCount else {
                continue
            }
            let statusField = String(record.prefix(Field.statusLetterCount))
            let path = normalizedPath(String(record.dropFirst(Field.pathOffsetCount)))
            if statusField.contains(Field.renameStatusLetter) || statusField.contains(Field.copyStatusLetter) {
                // Skip the origin-path field of a rename/copy record.
                index += 1
            }
            switch statusField {
            case Field.ignoredStatus:
                snapshot.ignoredRelativePaths.append(path)
            case Field.untrackedStatus:
                snapshot.untrackedRelativePaths.append(path)
            default:
                classifyTrackedRecord(statusField: statusField, path: path, into: &snapshot)
            }
        }
        return snapshot
    }

    /// Git reports untracked/ignored directories with a trailing slash.
    private static func normalizedPath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix(Field.directorySuffix) else {
            return path
        }
        return String(path.dropLast())
    }
}

// MARK: - Runner

struct TerminalGitStatusResult: Equatable, Sendable {
    let repositoryRootPath: String
    let snapshot: GitStatusSnapshot
}

/// Blocking git invocations. Only call off the main actor.
enum TerminalGitStatusRunner {
    private enum GitCommand {
        static let envExecutablePath = "/usr/bin/env"
        static let gitExecutableName = "git"
        static let workingDirectoryFlag = "-C"
        static let repositoryRootArguments = ["rev-parse", "--show-toplevel"]
        static let statusArguments = ["status", "--porcelain=v1", "-z", "--ignored=matching"]
    }

    /// Returns `nil` for directories that are not inside a git work tree or
    /// when git is unavailable, so callers render without badges.
    static func collectStatus(rootDirectoryPath: String) -> TerminalGitStatusResult? {
        let rootArguments = [GitCommand.workingDirectoryFlag, rootDirectoryPath]
        guard
            let repositoryRootOutput = runGit(arguments: rootArguments + GitCommand.repositoryRootArguments)
        else {
            return nil
        }
        let repositoryRootPath = repositoryRootOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryRootPath.isEmpty else {
            return nil
        }
        guard let statusOutput = runGit(arguments: rootArguments + GitCommand.statusArguments) else {
            return nil
        }
        return TerminalGitStatusResult(
            repositoryRootPath: repositoryRootPath,
            snapshot: GitPorcelainParser.parse(porcelainZOutput: statusOutput)
        )
    }

    private static func runGit(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitCommand.envExecutablePath)
        process.arguments = [GitCommand.gitExecutableName] + arguments
        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = Pipe()
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

/// Owns one utility queue for git work. Requests are generation-stamped so a
/// newer request or `cancelPendingRequests()` drops stale completions; the
/// completion always runs on the main actor.
@MainActor
final class TerminalGitStatusService {
    private enum QueueToken {
        static let label = "com.kurotty.file-explorer.git-status"
    }

    private let queue = DispatchQueue(label: QueueToken.label, qos: .utility)
    private var generation = 0

    func requestStatus(
        rootDirectory: URL,
        completion: @escaping @MainActor (TerminalGitStatusResult?) -> Void
    ) {
        generation += 1
        let requestGeneration = generation
        let rootDirectoryPath = rootDirectory.path
        queue.async { [weak self] in
            let result = TerminalGitStatusRunner.collectStatus(rootDirectoryPath: rootDirectoryPath)
            // Hop from the service-owned queue to the main actor; the
            // generation check on the main actor keeps cancellation safe.
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration else {
                    return
                }
                completion(result)
            }
        }
    }

    func cancelPendingRequests() {
        generation += 1
    }
}
