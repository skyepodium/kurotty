import Foundation

/// Everything the project file palette decides, with no AppKit in it.
///
/// The palette is a list, a query, a selection, and two ways to act on the
/// selected row. All four live here so they can be exercised without an
/// `NSWindow`, which is the same split `CommandPalettePresenter` already uses.

/// What pressing Return does to the selected row.
///
/// Inserting the path is the default because this is a terminal: the reason to
/// find a file by name is almost always that a command is waiting for it at the
/// prompt. Opening it in an editor tab is the modified action, not the other way
/// round.
enum ProjectFileQuickOpenActivation: Equatable {
    case insertPath
    case openInEditor

    static func forReturnKey(commandModifierHeld: Bool) -> ProjectFileQuickOpenActivation {
        commandModifierHeld ? .openInEditor : .insertPath
    }
}

/// The chosen row plus what to do with it. The palette hands this to the window
/// controller, which owns the two mechanisms; nothing here writes anything.
enum ProjectFileQuickOpenOutcome: Equatable {
    /// Absolute path, to be quoted and put on the prompt with no trailing
    /// newline, exactly like the file explorer's insert action.
    case insertPath(String)
    case openInEditor(URL)
}

/// What the footer says. Held as a state rather than a string so the copy can be
/// localized at the view and the rules can be asserted here.
enum ProjectFileQuickOpenStatus: Equatable {
    /// The scan has not come back yet.
    case scanning
    /// The scan finished and found nothing at all. Distinct from `noMatches`:
    /// one means the query is wrong, the other means the directory is empty or
    /// unreadable.
    case emptyProject
    case noMatches
    /// `totalCOUNT` is how many files matched, `shownCOUNT` how many rows fit.
    case results(
        source: ProjectFileListingSource,
        isListingTruncated: Bool,
        shownCOUNT: Int,
        totalCOUNT: Int
    )
}

struct ProjectFileQuickOpenPresenter: Equatable {
    /// The directory paths are relative to. Kept so a selected row can be
    /// resolved back to something the shell and the editor can both use.
    let rootDirectory: URL
    private(set) var query: String
    private(set) var visibleMatches: [ProjectFileMatch]
    private(set) var selectedIndex: Int?
    private(set) var isScanning: Bool

    private var index: ProjectFileIndex
    private var listingSource: ProjectFileListingSource
    private var isListingTruncated: Bool
    /// Matches before the visible cap, so the footer can say "50 of 812".
    private var totalMatchCount: Int
    private let visibleLimit: Int
    private let queryLimit: Int

    init(
        rootDirectory: URL,
        listing: ProjectFileListing? = nil,
        query: String = "",
        visibleLimit: Int = AppConstants.ProjectFiles.visibleResultMaximumCOUNT,
        queryLimit: Int = AppConstants.ProjectFiles.queryMaximumCharacterCOUNT
    ) {
        self.rootDirectory = rootDirectory
        self.visibleLimit = visibleLimit
        self.queryLimit = queryLimit
        self.query = query
        self.index = ProjectFileIndex(relativePaths: listing?.relativePaths ?? [])
        self.listingSource = listing?.source ?? .directoryWalk
        self.isListingTruncated = listing?.isTruncated ?? false
        self.isScanning = listing == nil
        self.visibleMatches = []
        self.totalMatchCount = 0
        self.selectedIndex = nil
        recomputeMatches()
    }

    // MARK: - Input

    /// Adopts a completed scan. The query is deliberately kept: the scan is
    /// asynchronous and a fast typist has already entered one by the time it
    /// lands, so throwing it away would eat their keystrokes.
    mutating func applyListing(_ listing: ProjectFileListing) {
        index = ProjectFileIndex(relativePaths: listing.relativePaths)
        listingSource = listing.source
        isListingTruncated = listing.isTruncated
        isScanning = false
        recomputeMatches()
    }

    mutating func updateQuery(_ query: String) {
        self.query = query
        recomputeMatches()
    }

    /// Clamps rather than wraps, matching `CommandPalettePresenter`. Two
    /// palettes in the same app that disagree about what Down does at the last
    /// row is a worse outcome than either behavior on its own.
    mutating func moveSelection(by offset: Int) {
        guard !visibleMatches.isEmpty else {
            selectedIndex = nil
            return
        }
        let currentIndex = selectedIndex ?? 0
        selectedIndex = min(max(currentIndex + offset, 0), visibleMatches.count - 1)
    }

    mutating func select(row: Int) {
        guard visibleMatches.indices.contains(row) else {
            selectedIndex = nil
            return
        }
        selectedIndex = row
    }

    // MARK: - Output

    var selectedMatch: ProjectFileMatch? {
        guard let selectedIndex, visibleMatches.indices.contains(selectedIndex) else {
            return nil
        }
        return visibleMatches[selectedIndex]
    }

    /// `nil` when nothing is selected, so an empty list cannot dispatch.
    func outcome(for activation: ProjectFileQuickOpenActivation) -> ProjectFileQuickOpenOutcome? {
        guard let selectedMatch else {
            return nil
        }
        let url = rootDirectory.appendingPathComponent(selectedMatch.relativePath)
        switch activation {
        case .insertPath:
            return .insertPath(url.path)
        case .openInEditor:
            return .openInEditor(url)
        }
    }

    var status: ProjectFileQuickOpenStatus {
        guard !isScanning else {
            return .scanning
        }
        guard !index.isEmpty else {
            return .emptyProject
        }
        guard !visibleMatches.isEmpty else {
            return .noMatches
        }
        return .results(
            source: listingSource,
            isListingTruncated: isListingTruncated,
            shownCOUNT: visibleMatches.count,
            totalCOUNT: totalMatchCount
        )
    }

    // MARK: - Ranking

    private mutating func recomputeMatches() {
        // An over-long query is answered with no results rather than by
        // ranking it: a paste of a whole file cannot be a path, and the only
        // thing scoring it against every entry achieves is a stalled window.
        guard query.count <= queryLimit else {
            visibleMatches = []
            totalMatchCount = 0
            selectedIndex = nil
            return
        }

        // Ranking is done once at the full result cap and then sliced, so the
        // footer can distinguish "50 matches" from "50 of 812".
        let ranked = ProjectFileMatcher.matches(
            index: index,
            query: query,
            limit: AppConstants.ProjectFiles.resultMaximumCOUNT
        )
        totalMatchCount = ranked.count
        visibleMatches = Array(ranked.prefix(visibleLimit))
        // Selection resets to the top on every query change: the ranking has
        // moved, so keeping an offset would keep a row the user never chose.
        selectedIndex = visibleMatches.isEmpty ? nil : 0
    }
}
