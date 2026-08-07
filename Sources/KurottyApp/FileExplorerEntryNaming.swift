import Foundation

/// Everything the explorer decides about a new or renamed entry *before* it
/// touches disk: which directory the entry belongs in, whether the typed name
/// can exist at all, and whether it would land on a sibling that is already
/// there.
///
/// Pure on purpose. Creating a file, creating a folder, and renaming an entry
/// all funnel through the same rules, and those rules are the only thing
/// standing between a side panel and a clobbered file, so they are asserted
/// directly rather than inferred from what ended up on a volume.

// MARK: - Where a new entry goes

enum FileExplorerCreationTarget {
    /// Directory a newly created entry belongs in, given the selected row.
    ///
    /// Finder's rule, and the one the user already has in their hands: inside a
    /// selected folder, beside a selected file, and in the panel's root when
    /// nothing is selected.
    static func directory(forSelectedNode node: FileExplorerNode?, rootDirectory: URL) -> URL {
        guard let node else {
            return rootDirectory
        }
        switch node.kind {
        case .directory:
            return node.url
        case .file:
            return node.url.deletingLastPathComponent()
        }
    }
}

// MARK: - Which write actions are legal right now

enum FileExplorerEntryAction: CaseIterable, Equatable, Sendable {
    case newFile
    case newFolder
    case rename
    case moveToTrash
}

/// The disk and session facts that decide whether a write action is offered.
///
/// Gathered by the panel — existence and writability are `FileManager`
/// questions — but judged here, so the context menu, the keyboard shortcuts,
/// and the handlers all reach the same verdict from one rule instead of three
/// guard clauses that drift apart.
struct FileExplorerEntryActionContext: Equatable, Sendable {
    /// The pane's working directory is on another machine. Nothing in this
    /// panel can write there, so no write action is offered at all.
    let isRemote: Bool
    /// The panel has a local root, so a create has somewhere to land.
    let hasRootDirectory: Bool
    let hasSelection: Bool
    /// The selected row's path is still on disk. False is the watcher being a
    /// beat behind something that moved the file out from under it.
    let selectionExists: Bool
    /// Directory a create would land in — see `FileExplorerCreationTarget`.
    let isCreationDirectoryWritable: Bool
    /// Directory holding the selection. Renaming and trashing both write to
    /// the *parent*, not to the entry, which is where the permission lives.
    let isSelectionDirectoryWritable: Bool

    static let unavailable = FileExplorerEntryActionContext(
        isRemote: false,
        hasRootDirectory: false,
        hasSelection: false,
        selectionExists: false,
        isCreationDirectoryWritable: false,
        isSelectionDirectoryWritable: false
    )
}

extension FileExplorerEntryAction {
    func isAvailable(in context: FileExplorerEntryActionContext) -> Bool {
        guard !context.isRemote, context.hasRootDirectory else {
            return false
        }
        switch self {
        case .newFile, .newFolder:
            return context.isCreationDirectoryWritable
        case .rename, .moveToTrash:
            return context.hasSelection
                && context.selectionExists
                && context.isSelectionDirectoryWritable
        }
    }
}

// MARK: - Why a name was refused

enum FileExplorerNameRejection: Equatable, Sendable {
    /// Nothing was typed, or the whole entry was whitespace.
    case empty
    /// `.` and `..` are directory entries every directory already has; asking
    /// for one is asking to rename the directory itself or its parent.
    case reservedDotName
    /// `/` separates path components and NUL terminates the C string the kernel
    /// receives, so neither can be part of a single name.
    case pathSeparator
    case tooLong(limitBYTES: Int)
    /// A sibling already occupies this name. Carries the sibling's own
    /// spelling, which is what makes a case-only clash legible: the user typed
    /// `readme.md` and the message can say `README.md` is already there.
    case collides(existingName: String)
}

// MARK: - The decision

enum FileExplorerNameDecision: Equatable, Sendable {
    /// Safe to write. `name` is the normalized spelling, which can differ from
    /// what the user typed — see `FileExplorerNameRule.normalizedInput`.
    case accepted(name: String)
    /// A rename whose target is the entry's current name. Not an error and not
    /// a write: there is simply nothing to do.
    case unchanged
    case rejected(FileExplorerNameRejection)
}

// MARK: - The rules

enum FileExplorerNameRule {
    /// `NAME_MAX` on APFS and HFS+, counted in UTF-8 bytes rather than
    /// characters because that is the unit the kernel enforces: a 200-character
    /// Korean name is 600 bytes and fails a check that counted characters.
    static let maximumNameBYTES = 255

    private static let pathSeparator: Character = "/"
    private static let nulCharacter: Character = "\0"
    private static let currentDirectoryName = "."
    private static let parentDirectoryName = ".."

    /// The name as it will actually be written.
    ///
    /// Surrounding whitespace is trimmed rather than rejected, which is what
    /// Finder does and what the user meant. macOS is happy to store
    /// `notes.txt ` with a trailing space, and it then reliably confuses
    /// everyone downstream: the tab-completed path in the terminal beside this
    /// panel does not match what the eye read, and `rm notes.txt` fails on a
    /// file the user is looking at. A leading dot survives untouched, because
    /// `.gitignore` is an ordinary name and hiding it would be the surprise.
    static func normalizedInput(_ proposedName: String) -> String {
        proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves a typed name against the directory it would be written into.
    ///
    /// - Parameters:
    ///   - existingSiblingNames: every entry already in the target directory,
    ///     read from disk immediately before the write.
    ///   - currentName: the entry's present name when this is a rename; `nil`
    ///     when creating. A rename never collides with itself, so this is
    ///     excluded from the sibling set — which is also what lets
    ///     `README.md` → `readme.md` through on a case-insensitive volume,
    ///     a rename Finder allows and the volume performs.
    ///   - volumeIsCaseSensitive: read from the target volume. Defaulting to
    ///     `false` is the safe direction: on the case-insensitive volume macOS
    ///     ships with, `README.md` and `readme.md` are one file, and a check
    ///     that compared exactly would hand a clobber to the filesystem call.
    static func decide(
        proposedName: String,
        existingSiblingNames: [String],
        currentName: String? = nil,
        volumeIsCaseSensitive: Bool = false
    ) -> FileExplorerNameDecision {
        let name = normalizedInput(proposedName)
        guard !name.isEmpty else {
            return .rejected(.empty)
        }
        guard name != currentDirectoryName, name != parentDirectoryName else {
            return .rejected(.reservedDotName)
        }
        guard !name.contains(pathSeparator), !name.contains(nulCharacter) else {
            return .rejected(.pathSeparator)
        }
        guard name.utf8.count <= maximumNameBYTES else {
            return .rejected(.tooLong(limitBYTES: maximumNameBYTES))
        }
        if let currentName, name == currentName {
            return .unchanged
        }
        let collision = existingSiblingNames.first { sibling in
            sibling != currentName
                && namesReferToSameEntry(sibling, name, volumeIsCaseSensitive: volumeIsCaseSensitive)
        }
        if let collision {
            return .rejected(.collides(existingName: collision))
        }
        return .accepted(name: name)
    }

    /// Whether two spellings would address the same directory entry.
    static func namesReferToSameEntry(
        _ left: String,
        _ right: String,
        volumeIsCaseSensitive: Bool
    ) -> Bool {
        guard !volumeIsCaseSensitive else {
            // Nothing extra is needed for normalization: Swift compares strings
            // by canonical equivalence, which is the same normalization
            // insensitivity APFS and HFS+ have in *both* case modes. A
            // precomposed `é` and a decomposed `e` + combining acute are one
            // directory entry, and they are already equal here.
            return left == right
        }
        // Case folding rather than `lowercased()`: folding is the Unicode
        // operation a case-insensitive volume itself performs, and it is what
        // makes `README.md` and `readme.md` one file rather than two.
        return left.folding(options: .caseInsensitive, locale: nil)
            == right.folding(options: .caseInsensitive, locale: nil)
    }
}
