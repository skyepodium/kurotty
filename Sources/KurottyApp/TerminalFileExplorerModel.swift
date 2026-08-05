import Foundation

/// Pure model layer for the file-explorer panel: node values, sorting, name
/// filtering, directory listing, and git-status overlay math. No AppKit.
enum FileExplorerModelConstants {
    static let gitDirectoryName = ".git"
    static let relativePathSeparator: Character = "/"
    static let hiddenFileNamePrefix = "."
}

// MARK: - Nodes

enum FileExplorerNodeKind: Equatable, Sendable {
    case directory
    case file
}

struct FileExplorerNode: Equatable, Sendable {
    let url: URL
    let kind: FileExplorerNodeKind

    var name: String {
        url.lastPathComponent
    }

    var isHiddenFile: Bool {
        name.hasPrefix(FileExplorerModelConstants.hiddenFileNamePrefix)
    }

    var isGitDirectory: Bool {
        kind == .directory && name == FileExplorerModelConstants.gitDirectoryName
    }
}

// MARK: - Sorting

enum FileExplorerSorter {
    /// Directories before files, then case-insensitive alphabetical name order
    /// with a case-sensitive tie break so ordering stays deterministic.
    static func sorted(_ nodes: [FileExplorerNode]) -> [FileExplorerNode] {
        nodes.sorted { left, right in
            if left.kind != right.kind {
                return left.kind == .directory
            }
            let comparison = left.name.caseInsensitiveCompare(right.name)
            guard comparison == .orderedSame else {
                return comparison == .orderedAscending
            }
            return left.name < right.name
        }
    }
}

// MARK: - Name filter

enum FileExplorerNameFilter {
    /// Case-insensitive substring match first, then a character-subsequence
    /// fuzzy match so `tfe` still finds `TerminalFileExplorer.swift`.
    static func matches(name: String, query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else {
            return false
        }
        let loweredName = name.lowercased()
        let loweredQuery = trimmedQuery.lowercased()
        if loweredName.contains(loweredQuery) {
            return true
        }
        return isSubsequence(loweredQuery, of: loweredName)
    }

    private static func isSubsequence(_ query: String, of name: String) -> Bool {
        var queryIndex = query.startIndex
        for character in name {
            guard queryIndex < query.endIndex else {
                return true
            }
            if character == query[queryIndex] {
                queryIndex = query.index(after: queryIndex)
            }
        }
        return queryIndex == query.endIndex
    }
}

// MARK: - Filter projection

struct FileExplorerFilterMatch: Equatable, Sendable {
    let node: FileExplorerNode
    /// Path relative to the searched root, for disambiguating display.
    let relativeDisplayPath: String
}

enum FileExplorerFilterProjection {
    static let defaultMaxDepthCOUNT = 6
    static let defaultMaxVisitedEntryCOUNT = 4000

    /// Depth-first bounded scan over a directory tree supplied by
    /// `childProvider`, returning nodes whose name matches `query`.
    /// The visit budget bounds work on huge trees; `.git` contents are
    /// excluded by the child provider contract.
    static func matches(
        rootDirectory: URL,
        query: String,
        childProvider: (URL) -> [FileExplorerNode],
        maxDepth: Int = defaultMaxDepthCOUNT,
        maxVisitedEntryCount: Int = defaultMaxVisitedEntryCOUNT
    ) -> [FileExplorerFilterMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else {
            return []
        }
        var matches: [FileExplorerFilterMatch] = []
        var visitedCount = 0
        collectMatches(
            in: rootDirectory,
            relativePrefix: "",
            depth: 0,
            query: trimmedQuery,
            childProvider: childProvider,
            maxDepth: maxDepth,
            maxVisitedEntryCount: maxVisitedEntryCount,
            visitedCount: &visitedCount,
            matches: &matches
        )
        return matches
    }

    private static func collectMatches(
        in directory: URL,
        relativePrefix: String,
        depth: Int,
        query: String,
        childProvider: (URL) -> [FileExplorerNode],
        maxDepth: Int,
        maxVisitedEntryCount: Int,
        visitedCount: inout Int,
        matches: inout [FileExplorerFilterMatch]
    ) {
        guard depth <= maxDepth else {
            return
        }
        for node in childProvider(directory) {
            guard visitedCount < maxVisitedEntryCount else {
                return
            }
            visitedCount += 1
            let relativePath = relativePrefix.isEmpty
                ? node.name
                : relativePrefix + String(FileExplorerModelConstants.relativePathSeparator) + node.name
            if FileExplorerNameFilter.matches(name: node.name, query: query) {
                matches.append(FileExplorerFilterMatch(node: node, relativeDisplayPath: relativePath))
            }
            if node.kind == .directory, !node.isGitDirectory {
                collectMatches(
                    in: node.url,
                    relativePrefix: relativePath,
                    depth: depth + 1,
                    query: query,
                    childProvider: childProvider,
                    maxDepth: maxDepth,
                    maxVisitedEntryCount: maxVisitedEntryCount,
                    visitedCount: &visitedCount,
                    matches: &matches
                )
            }
        }
    }
}

// MARK: - Directory listing

enum FileExplorerDirectoryLister {
    /// Sorted children of one directory. Contents of `.git` are never listed
    /// so the panel cannot recurse into repository internals.
    static func listChildren(of directoryURL: URL) -> [FileExplorerNode] {
        guard directoryURL.lastPathComponent != FileExplorerModelConstants.gitDirectoryName else {
            return []
        }
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
        guard let childURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) else {
            return []
        }
        let nodes = childURLs.map { url -> FileExplorerNode in
            let isDirectory = (try? url.resourceValues(forKeys: Set(resourceKeys)))?.isDirectory ?? false
            return FileExplorerNode(
                url: url.standardizedFileURL,
                kind: isDirectory ? .directory : .file
            )
        }
        return FileExplorerSorter.sorted(nodes)
    }
}

// MARK: - Git overlay

enum FileExplorerGitBadge: Equatable, Sendable {
    /// Both sides of a merge touched the path. The only state the user has to
    /// resolve, so it outranks every other badge at a shared ancestor.
    case conflicted
    case modified
    /// Staged in the index with no further worktree change.
    case staged
    case untracked
    case ignored

    /// Which badge survives when two states meet at a shared ancestor folder.
    /// Higher wins; `ignored` never propagates and is resolved separately.
    var ancestorPrecedenceRANK: Int {
        switch self {
        case .conflicted: return 4
        case .modified: return 3
        case .staged: return 2
        case .untracked: return 1
        case .ignored: return 0
        }
    }
}

/// Immutable overlay mapping absolute paths under a repository root to git
/// badges, with ancestor propagation precomputed: a folder containing a
/// modified file reports `.modified`, ignored directories cover their
/// contents, and the higher `ancestorPrecedenceRANK` wins where two states meet.
struct FileExplorerGitOverlay: Equatable, Sendable {
    static let empty = FileExplorerGitOverlay(repositoryRootPath: "", snapshot: .empty)

    let repositoryRootPath: String
    private let badgeByRelativePath: [String: FileExplorerGitBadge]
    private let ignoredRelativePaths: Set<String>

    init(repositoryRootPath: String, snapshot: GitStatusSnapshot) {
        self.repositoryRootPath = Self.normalizedRootPath(repositoryRootPath)
        var badges: [String: FileExplorerGitBadge] = [:]
        for path in snapshot.untrackedRelativePaths {
            Self.assign(.untracked, toPathAndAncestors: path, in: &badges)
        }
        for path in snapshot.stagedRelativePaths {
            Self.assign(.staged, toPathAndAncestors: path, in: &badges)
        }
        for path in snapshot.modifiedRelativePaths {
            Self.assign(.modified, toPathAndAncestors: path, in: &badges)
        }
        for path in snapshot.conflictedRelativePaths {
            Self.assign(.conflicted, toPathAndAncestors: path, in: &badges)
        }
        badgeByRelativePath = badges
        ignoredRelativePaths = Set(snapshot.ignoredRelativePaths)
    }

    func badge(forAbsolutePath absolutePath: String) -> FileExplorerGitBadge? {
        guard let relativePath = relativePath(forAbsolutePath: absolutePath) else {
            return nil
        }
        if isIgnored(relativePath: relativePath) {
            return .ignored
        }
        return badgeByRelativePath[relativePath]
    }

    private func isIgnored(relativePath: String) -> Bool {
        var current = relativePath
        while !current.isEmpty {
            if ignoredRelativePaths.contains(current) {
                return true
            }
            current = Self.parentPath(of: current)
        }
        return false
    }

    private func relativePath(forAbsolutePath absolutePath: String) -> String? {
        guard !repositoryRootPath.isEmpty else {
            return nil
        }
        let rootPrefix = repositoryRootPath + String(FileExplorerModelConstants.relativePathSeparator)
        guard absolutePath.hasPrefix(rootPrefix) else {
            return nil
        }
        return String(absolutePath.dropFirst(rootPrefix.count))
    }

    private static func normalizedRootPath(_ path: String) -> String {
        let separator = String(FileExplorerModelConstants.relativePathSeparator)
        guard path.count > 1, path.hasSuffix(separator) else {
            return path
        }
        return String(path.dropLast())
    }

    private static func assign(
        _ badge: FileExplorerGitBadge,
        toPathAndAncestors path: String,
        in badges: inout [String: FileExplorerGitBadge]
    ) {
        var current = path
        while !current.isEmpty {
            let existingRank = badges[current]?.ancestorPrecedenceRANK ?? 0
            if badge.ancestorPrecedenceRANK >= existingRank {
                badges[current] = badge
            }
            current = parentPath(of: current)
        }
    }

    private static func parentPath(of relativePath: String) -> String {
        guard let separatorIndex = relativePath.lastIndex(
            of: FileExplorerModelConstants.relativePathSeparator
        ) else {
            return ""
        }
        return String(relativePath[..<separatorIndex])
    }
}
