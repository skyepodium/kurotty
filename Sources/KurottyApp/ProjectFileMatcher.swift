import Foundation

/// Ranking for the project file palette.
///
/// The file explorer's `FileExplorerNameFilter` answers a yes/no question about
/// one name; a palette has to put the right file on row one out of tens of
/// thousands, which is a different job. This one matches against the whole
/// relative path and returns an ordering, not a Bool.
///
/// Nothing here touches the filesystem or AppKit: the input is a list of
/// already-enumerated relative paths, so the ordering rules can be pinned
/// without a repository on disk.

// MARK: - Prepared index

/// One path, pre-folded for matching.
///
/// Case folding and boundary detection happen once per listing instead of once
/// per keystroke, because the palette re-ranks every file in the project on
/// every character typed. Boundaries in particular *have* to be computed before
/// folding: `TerminalSurfaceView` case-folds to `terminalsurfaceview`, and the
/// camel humps that make `tsv` a good match are gone by then.
struct ProjectFileIndexEntry: Equatable {
    /// The path exactly as the enumerator produced it, for display.
    let relativePath: String
    /// Diacritic-folded and lowercased, one element per character of
    /// `boundaryFlags`.
    let searchCharacters: [Character]
    /// `true` where the character at the same offset starts a word.
    let boundaryFlags: [Bool]
    /// Offset of the first character after the last path separator.
    let filenameStartOffset: Int
    let depthCOUNT: Int
}

/// Every path in one listing, prepared for matching.
struct ProjectFileIndex: Equatable {
    let entries: [ProjectFileIndexEntry]

    static let empty = ProjectFileIndex(entries: [])

    init(entries: [ProjectFileIndexEntry]) {
        self.entries = entries
    }

    init(relativePaths: [String]) {
        self.entries = relativePaths.map(ProjectFileIndexEntry.init(relativePath:))
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
}

extension ProjectFileIndexEntry {
    init(relativePath: String) {
        // Diacritics go first and case stays, so boundary detection can still
        // see the humps; the lowercased copy for comparison is derived from the
        // same string, which keeps the two arrays index-aligned.
        let folded = Array(relativePath.folding(options: .diacriticInsensitive, locale: nil))
        var searchCharacters: [Character] = []
        var boundaryFlags: [Bool] = []
        searchCharacters.reserveCapacity(folded.count)
        boundaryFlags.reserveCapacity(folded.count)

        var filenameStartOffset = 0
        var depthCount = 0
        var previous: Character?
        for (offset, character) in folded.enumerated() {
            boundaryFlags.append(ProjectFileMatcher.isBoundary(character: character, previous: previous))
            searchCharacters.append(Character(character.lowercased()))
            if character == ProjectFileMatcher.pathSeparator {
                depthCount += 1
                filenameStartOffset = offset + 1
            }
            previous = character
        }

        self.relativePath = relativePath
        self.searchCharacters = searchCharacters
        self.boundaryFlags = boundaryFlags
        self.filenameStartOffset = filenameStartOffset
        self.depthCOUNT = depthCount
    }
}

// MARK: - Rank

/// How well one path answered one query. Lower sorts first.
///
/// The fields are separate rather than folded into a single weighted number so
/// each rule can be stated — and tested — on its own, and so ties break
/// deterministically instead of on whatever order the enumerator produced.
struct ProjectFileRank: Equatable, Comparable {
    /// True when every query character landed inside the file name. A query is
    /// nearly always a file name, so a name match outranks a directory match no
    /// matter how tight the directory match was.
    let matchedFilename: Bool
    /// Characters skipped between consecutive query characters. Zero means the
    /// query appears verbatim; the same query scattered across a path scores
    /// worse than a contiguous run in a longer one.
    let gapCOUNT: Int
    /// Query characters that did *not* land on a word boundary. This is what
    /// makes `tsv` find `TerminalSurfaceView.swift` ahead of a path that merely
    /// happens to contain those three letters.
    let offBoundaryCOUNT: Int
    /// Path separators in the relative path. A file near the root is more often
    /// the one meant than a same-named file buried deep.
    let depthCOUNT: Int
    let lengthCOUNT: Int
    /// Final tiebreak, so two paths equal on every rule above still come back in
    /// a stable order rather than in enumeration order.
    let path: String

    static func < (lhs: ProjectFileRank, rhs: ProjectFileRank) -> Bool {
        if lhs.matchedFilename != rhs.matchedFilename {
            // `true` is the better outcome, so it has to sort first.
            return lhs.matchedFilename
        }
        if lhs.gapCOUNT != rhs.gapCOUNT {
            return lhs.gapCOUNT < rhs.gapCOUNT
        }
        if lhs.offBoundaryCOUNT != rhs.offBoundaryCOUNT {
            return lhs.offBoundaryCOUNT < rhs.offBoundaryCOUNT
        }
        if lhs.depthCOUNT != rhs.depthCOUNT {
            return lhs.depthCOUNT < rhs.depthCOUNT
        }
        if lhs.lengthCOUNT != rhs.lengthCOUNT {
            return lhs.lengthCOUNT < rhs.lengthCOUNT
        }
        return lhs.path < rhs.path
    }
}

struct ProjectFileMatch: Equatable {
    let relativePath: String
    let rank: ProjectFileRank
}

// MARK: - Matcher

enum ProjectFileMatcher {
    static let pathSeparator: Character = "/"

    /// Characters after which the next one starts a new word: the path
    /// separator plus the joiners that appear in practically every source file
    /// name.
    private static let boundaryPredecessors: Set<Character> = ["/", ".", "-", "_", " "]

    /// `nil` when the query is only whitespace. An empty query is not "match
    /// nothing" — the palette shows the head of the listing — so callers need
    /// the distinction rather than an empty result.
    static func normalizedQuery(_ rawQuery: String) -> [Character]? {
        let folded = rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        // Interior whitespace is dropped rather than treated as a token
        // separator: a path never contains a run of query words, so someone
        // typing `terminal surface` means `terminalsurface`.
        let characters = Array(folded.lowercased()).filter { !$0.isWhitespace }
        return characters.isEmpty ? nil : characters
    }

    /// Best rank for one entry, or `nil` when the query is not a subsequence of
    /// it.
    ///
    /// A query containing `/` is matched against the whole relative path only:
    /// typing a separator is how a user says "I mean this directory", and
    /// scoring it against the bare file name would silently ignore that.
    static func rank(entry: ProjectFileIndexEntry, normalizedQuery query: [Character]) -> ProjectFileRank? {
        guard !query.isEmpty else {
            return nil
        }

        // The file name is tried first and wins outright, so a path whose
        // directories happen to contain the query cannot outrank a real name
        // match in a longer path.
        if !query.contains(pathSeparator),
           let filenameMatch = subsequenceMatch(entry: entry, from: entry.filenameStartOffset, query: query) {
            return ProjectFileRank(
                matchedFilename: true,
                gapCOUNT: filenameMatch.gapCOUNT,
                offBoundaryCOUNT: filenameMatch.offBoundaryCOUNT,
                depthCOUNT: entry.depthCOUNT,
                lengthCOUNT: entry.searchCharacters.count,
                path: entry.relativePath
            )
        }

        guard let pathMatch = subsequenceMatch(entry: entry, from: 0, query: query) else {
            return nil
        }
        return ProjectFileRank(
            matchedFilename: false,
            gapCOUNT: pathMatch.gapCOUNT,
            offBoundaryCOUNT: pathMatch.offBoundaryCOUNT,
            depthCOUNT: entry.depthCOUNT,
            lengthCOUNT: entry.searchCharacters.count,
            path: entry.relativePath
        )
    }

    /// Ranked matches, best first, capped at `limit`.
    ///
    /// An empty query returns the head of the index in the order the enumerator
    /// produced it rather than an alphabetised list: ripgrep walks the tree in
    /// directory order, which puts a project's own sources ahead of its
    /// vendored ones, and re-sorting would throw that away.
    static func matches(index: ProjectFileIndex, query: String, limit: Int) -> [ProjectFileMatch] {
        guard limit > 0 else {
            return []
        }
        guard let normalizedQuery = normalizedQuery(query) else {
            return index.entries.prefix(limit).map { entry in
                ProjectFileMatch(
                    relativePath: entry.relativePath,
                    rank: ProjectFileRank(
                        matchedFilename: false,
                        gapCOUNT: 0,
                        offBoundaryCOUNT: 0,
                        depthCOUNT: entry.depthCOUNT,
                        lengthCOUNT: entry.searchCharacters.count,
                        path: entry.relativePath
                    )
                )
            }
        }

        var ranked: [ProjectFileMatch] = []
        for entry in index.entries {
            guard let rank = rank(entry: entry, normalizedQuery: normalizedQuery) else {
                continue
            }
            ranked.append(ProjectFileMatch(relativePath: entry.relativePath, rank: rank))
        }
        ranked.sort { $0.rank < $1.rank }
        return Array(ranked.prefix(limit))
    }

    // MARK: - Subsequence scoring

    private struct SubsequenceMatch {
        let gapCOUNT: Int
        let offBoundaryCOUNT: Int
    }

    /// Greedy left-to-right subsequence walk.
    ///
    /// Greedy rather than optimal: finding the tightest of all possible
    /// alignments is quadratic per candidate, and this runs over every file in
    /// the project on every keystroke. Taking the first occurrence of each query
    /// character is what every fuzzy finder does for the same reason, and the
    /// boundary term recovers most of what the greedy choice gives up.
    private static func subsequenceMatch(
        entry: ProjectFileIndexEntry,
        from startOffset: Int,
        query: [Character]
    ) -> SubsequenceMatch? {
        var queryOffset = 0
        var gapCount = 0
        var offBoundaryCount = 0
        var previousMatchOffset: Int?

        var offset = startOffset
        while offset < entry.searchCharacters.count, queryOffset < query.count {
            if entry.searchCharacters[offset] == query[queryOffset] {
                if let previousMatchOffset {
                    gapCount += offset - previousMatchOffset - 1
                }
                if !entry.boundaryFlags[offset] {
                    offBoundaryCount += 1
                }
                previousMatchOffset = offset
                queryOffset += 1
            }
            offset += 1
        }

        guard queryOffset == query.count else {
            return nil
        }
        return SubsequenceMatch(gapCOUNT: gapCount, offBoundaryCOUNT: offBoundaryCount)
    }

    /// Whether `character` starts a word, given the character before it. Called
    /// on case-preserving text, which is the only place the camel-case rule can
    /// still see a hump.
    static func isBoundary(character: Character, previous: Character?) -> Bool {
        guard let previous else {
            return true
        }
        if boundaryPredecessors.contains(previous) {
            return true
        }
        // A camel hump, and the digit run that behaves like one in names such
        // as `utf8Decoder`.
        return (previous.isLowercase || previous.isNumber) && character.isUppercase
    }
}
