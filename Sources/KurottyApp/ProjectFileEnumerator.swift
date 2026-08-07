import Foundation

/// Where the project file palette gets its list of files.
///
/// Two enumerators, in preference order: ripgrep when the user has it, and a
/// bounded breadth-first walk when they do not. The split mirrors
/// `TerminalGitWorktreeService` — everything that decides something is a pure
/// function, and the only impure part is the runner that produces the output.

// MARK: - Model

/// Which enumerator produced a listing.
///
/// The distinction is user-visible and has to stay that way: ripgrep reads the
/// repository's ignore rules and walks the whole tree, while the built-in walk
/// knows nothing about `.gitignore` and stops at a fixed budget. The palette
/// says which one it got, so a short result list is never mistaken for a small
/// project.
enum ProjectFileListingSource: Equatable, Sendable {
    case ripgrep
    case directoryWalk
}

struct ProjectFileListing: Equatable, Sendable {
    /// Paths relative to the root that was scanned, in enumeration order.
    let relativePaths: [String]
    let source: ProjectFileListingSource
    /// True when the enumerator stopped before it ran out of files, so the list
    /// is a prefix of the project rather than all of it.
    let isTruncated: Bool

    static let empty = ProjectFileListing(relativePaths: [], source: .directoryWalk, isTruncated: false)
}

// MARK: - Ripgrep output

/// Pure parsing of `rg --files` output.
enum ProjectFileRipgrepOutput {
    /// One path per line. Blank lines are dropped and each path is taken
    /// verbatim: a file name may legally contain spaces, quotes, or a leading
    /// dot, and none of those are separators here.
    ///
    /// The cap is applied after parsing rather than by killing rg early. A
    /// killed process very often leaves half a path in the pipe, and a name on
    /// screen that does not exist on disk is worse than reading a few extra
    /// kilobytes of output.
    static func relativePaths(from output: String, limit: Int) -> (paths: [String], isTruncated: Bool) {
        let paths = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard paths.count > limit else {
            return (paths, false)
        }
        return (Array(paths.prefix(limit)), true)
    }
}

// MARK: - Breadth-first fallback walk

/// The enumerator used when ripgrep is not installed.
///
/// Breadth-first, not depth-first, and that is the whole point. The file
/// explorer's filter walks depth-first under the same kind of budget, which in
/// a checkout with a `.build` or `node_modules` directory means the budget is
/// spent inside the first heavy subtree before the walk ever reaches the
/// project's own sources. Breadth-first spends the budget on the shallowest
/// files instead, which are the ones a person is most likely reaching for.
///
/// It is still not a substitute for ripgrep: nothing here reads `.gitignore`,
/// so a large vendored directory does consume part of the budget. The listing
/// reports `isTruncated` and the palette says so rather than pretending the
/// result is the whole project.
enum ProjectFileDirectoryWalk {
    static func listing(
        rootDirectory: URL,
        limit: Int = AppConstants.ProjectFiles.walkResultMaximumCOUNT,
        maximumVisitedEntryCount: Int = AppConstants.ProjectFiles.walkVisitedEntryMaximumCOUNT,
        childProvider: (URL) -> [FileExplorerNode] = FileExplorerDirectoryLister.listChildren(of:)
    ) -> ProjectFileListing {
        var relativePaths: [String] = []
        var visitedCount = 0
        var isTruncated = false
        // Each element is a directory plus the prefix that turns its children's
        // names into paths relative to the scanned root.
        var queue: [(url: URL, prefix: String)] = [(rootDirectory, "")]
        var queueIndex = 0

        while queueIndex < queue.count {
            let (directory, prefix) = queue[queueIndex]
            queueIndex += 1
            for node in childProvider(directory) {
                guard visitedCount < maximumVisitedEntryCount else {
                    isTruncated = true
                    return ProjectFileListing(
                        relativePaths: relativePaths,
                        source: .directoryWalk,
                        isTruncated: isTruncated
                    )
                }
                visitedCount += 1
                let relativePath = prefix.isEmpty ? node.name : prefix + "/" + node.name
                switch node.kind {
                case .directory:
                    // `.git` is skipped by the lister's own contract; skipping
                    // it here too would be a second rule saying the same thing.
                    guard !node.isGitDirectory else {
                        continue
                    }
                    queue.append((node.url, relativePath))
                case .file:
                    guard relativePaths.count < limit else {
                        isTruncated = true
                        return ProjectFileListing(
                            relativePaths: relativePaths,
                            source: .directoryWalk,
                            isTruncated: isTruncated
                        )
                    }
                    relativePaths.append(relativePath)
                }
            }
        }

        return ProjectFileListing(relativePaths: relativePaths, source: .directoryWalk, isTruncated: isTruncated)
    }
}

// MARK: - Runner

/// Blocking enumeration. Only call off the main actor.
enum ProjectFileEnumerationRunner {
    enum Command {
        static let envExecutablePath = "/usr/bin/env"
        static let ripgrepExecutableName = "rg"
        /// `--files` lists paths without searching content, and honours
        /// `.gitignore` on the way — which is the entire reason to prefer it
        /// over a hand-rolled walk. `--color=never` is belt and braces: the
        /// output is a pipe, so rg already disables colour, but a user's
        /// `RIPGREP_CONFIG_PATH` can force it back on and paint every path with
        /// escape sequences.
        ///
        /// `--follow` is deliberately absent. Following symlinks lets the walk
        /// leave the directory the user is actually in, and a self-referential
        /// link turns the listing into an unbounded loop.
        static let ripgrepArguments = ["--files", "--color=never"]
    }

    /// A listing for `rootDirectory`, from ripgrep when it is installed and
    /// from the bounded walk when it is not.
    ///
    /// A missing binary is never an error state here. Kurotty did not ship
    /// ripgrep and cannot assume it, so "not installed" has to be an ordinary
    /// branch with a working answer behind it, not a dead feature with an
    /// install prompt where the results should be.
    /// `executableName` exists so the absent-binary branch is reachable from a
    /// test. Whether ripgrep happens to be installed on the machine running the
    /// suite is not something a test may assume, and it is the branch that most
    /// needs covering.
    static func listing(
        rootDirectory: URL,
        limit: Int = AppConstants.ProjectFiles.resultMaximumCOUNT,
        executableName: String = Command.ripgrepExecutableName
    ) -> ProjectFileListing {
        if let listing = ripgrepListing(
            rootDirectory: rootDirectory,
            limit: limit,
            executableName: executableName
        ) {
            return listing
        }
        return ProjectFileDirectoryWalk.listing(rootDirectory: rootDirectory)
    }

    /// `nil` when ripgrep could not be run at all — not installed, not
    /// executable, or it failed before printing anything. A nonzero exit with
    /// output is still used: rg exits nonzero when it could not read some
    /// subdirectory, and a listing missing one unreadable directory is far
    /// better than no listing.
    static func ripgrepListing(
        rootDirectory: URL,
        limit: Int,
        executableName: String = Command.ripgrepExecutableName
    ) -> ProjectFileListing? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Command.envExecutablePath)
        process.arguments = [executableName] + Command.ripgrepArguments
        process.currentDirectoryURL = rootDirectory
        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        // stderr is discarded, so it must not be an unread Pipe: a chatty rg
        // fills the ~64 KB pipe buffer, blocks, and wedges this queue — the
        // same trap `TerminalGitWorktreeRunner` documents.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let outputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: outputData, encoding: .utf8) else {
            return nil
        }
        let parsed = ProjectFileRipgrepOutput.relativePaths(from: output, limit: limit)
        // `env` exits 127 when the command does not exist, and rg itself never
        // does, so an empty result at 127 is "ripgrep is not installed" rather
        // than "this project has no files".
        guard !parsed.paths.isEmpty || process.terminationStatus == 0 else {
            return nil
        }
        return ProjectFileListing(
            relativePaths: parsed.paths,
            source: .ripgrep,
            isTruncated: parsed.isTruncated
        )
    }

    /// Whether ripgrep can be run at all. Used by the setup checklist, which
    /// reports the state rather than acting on it.
    ///
    /// Deliberately uncached. A negative answer would otherwise outlive the
    /// `brew install` that fixed it and keep telling the user to do something
    /// they already did.
    static func isRipgrepAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Command.envExecutablePath)
        process.arguments = [Command.ripgrepExecutableName, "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - Async service

/// What the palette needs from an enumerator. The palette depends on this
/// rather than on the concrete service, so a test can drive it without a
/// repository on disk.
@MainActor
protocol ProjectFileEnumerating: AnyObject {
    func requestListing(
        rootDirectory: URL,
        completion: @escaping @MainActor (ProjectFileListing) -> Void
    )
}

/// Owns one utility queue for project scans. Requests are generation-stamped so
/// a newer request drops a stale completion; the completion always runs on the
/// main actor. Same shape as `TerminalGitWorktreeService`.
@MainActor
final class ProjectFileEnumerator: ProjectFileEnumerating {
    private enum QueueToken {
        static let label = "com.kurotty.project-files.enumerator"
    }

    private let queue = DispatchQueue(label: QueueToken.label, qos: .userInitiated)
    private var generation = 0

    func requestListing(
        rootDirectory: URL,
        completion: @escaping @MainActor (ProjectFileListing) -> Void
    ) {
        generation += 1
        let requestGeneration = generation
        queue.async { [weak self] in
            let listing = ProjectFileEnumerationRunner.listing(rootDirectory: rootDirectory)
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration else {
                    return
                }
                completion(listing)
            }
        }
    }
}
