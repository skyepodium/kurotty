import AppKit

/// The file explorer's write side: create a file, create a folder, rename an
/// entry, move one to the Trash.
///
/// Every write is a pre-flight decision (`FileExplorerNameRule`) followed by a
/// single filesystem call made with the non-clobbering option, and every
/// failure comes back as a typed value rather than a thrown `NSError` the panel
/// would have to decode. The panel beside a terminal is not a place to learn
/// what `NSFileWriteFileExistsError` means.
///
/// The calls run on the main actor, like the panel's existing directory
/// listing: these are one syscall each, started by a user action, not the
/// bulk-scan path.

// MARK: - Failures

enum FileExplorerEntryFailure: Error, Equatable, Sendable {
    /// The typed name never reached disk.
    case name(FileExplorerNameRejection)
    /// The entry or its directory is gone — most often because the watcher's
    /// tree is a moment behind something the terminal beside it just did.
    case missing
    case denied
    case readOnlyVolume
    /// Anything the writer cannot classify, carrying the system's own wording
    /// so the panel is never reduced to "something went wrong".
    case unclassified(description: String)
}

// MARK: - Writer

@MainActor
struct FileExplorerEntryWriter {
    private let fileManager: FileManager
    /// Injected so a test can assert that delete routes to the Trash without
    /// moving a fixture into the developer's real Trash.
    private let recycle: @MainActor (URL, @escaping (Error?) -> Void) -> Void

    static let live = FileExplorerEntryWriter()

    init(
        fileManager: FileManager = .default,
        recycle: @escaping @MainActor (URL, @escaping (Error?) -> Void) -> Void = Self.workspaceRecycle
    ) {
        self.fileManager = fileManager
        self.recycle = recycle
    }

    /// The only delete this panel performs. `NSWorkspace.recycle` puts the
    /// entry in the Trash with a Put Back destination, so the action is
    /// undoable from Finder; unlinking would not be, and a side panel that sits
    /// against the user's real work does not get to make that call.
    static func workspaceRecycle(_ url: URL, completion: @escaping (Error?) -> Void) {
        NSWorkspace.shared.recycle([url]) { _, error in
            completion(error)
        }
    }

    // MARK: Create

    func createFile(named proposedName: String, in directory: URL) -> Result<URL, FileExplorerEntryFailure> {
        create(named: proposedName, in: directory) { url in
            // `.withoutOverwriting` is `O_EXCL`, so the kernel refuses an
            // existing entry even though the sibling scan above already said
            // there was none. That scan is a check and this is the write; on a
            // directory the terminal beside this panel is also writing to,
            // anything can happen between them. `FileManager.createFile`
            // truncates instead, which is the one outcome this must not have.
            try Data().write(to: url, options: .withoutOverwriting)
        }
    }

    func createDirectory(named proposedName: String, in directory: URL) -> Result<URL, FileExplorerEntryFailure> {
        create(named: proposedName, in: directory) { url in
            // `withIntermediateDirectories: false` is load-bearing: `true`
            // succeeds silently on a directory that already exists, which would
            // report a create that created nothing.
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    private func create(
        named proposedName: String,
        in directory: URL,
        write: (URL) throws -> Void
    ) -> Result<URL, FileExplorerEntryFailure> {
        guard let siblingNames = siblingNames(in: directory) else {
            return .failure(.missing)
        }
        let decision = FileExplorerNameRule.decide(
            proposedName: proposedName,
            existingSiblingNames: siblingNames,
            volumeIsCaseSensitive: volumeIsCaseSensitive(at: directory)
        )
        guard case let .accepted(name) = decision else {
            return .failure(failure(forNonAccepted: decision))
        }
        let url = directory.appendingPathComponent(name)
        do {
            try write(url)
            return .success(url.standardizedFileURL)
        } catch {
            return .failure(Self.failure(from: error))
        }
    }

    // MARK: Rename

    func rename(_ url: URL, to proposedName: String) -> Result<URL, FileExplorerEntryFailure> {
        let directory = url.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: url.path), let siblingNames = siblingNames(in: directory) else {
            return .failure(.missing)
        }
        let decision = FileExplorerNameRule.decide(
            proposedName: proposedName,
            existingSiblingNames: siblingNames,
            currentName: url.lastPathComponent,
            volumeIsCaseSensitive: volumeIsCaseSensitive(at: directory)
        )
        switch decision {
        case .unchanged:
            // Retyping the same name is a no-op, not a collision with itself.
            return .success(url.standardizedFileURL)
        case let .accepted(name):
            let destination = directory.appendingPathComponent(name)
            do {
                try fileManager.moveItem(at: url, to: destination)
                return .success(destination.standardizedFileURL)
            } catch {
                return .failure(Self.failure(from: error))
            }
        case .rejected:
            return .failure(failure(forNonAccepted: decision))
        }
    }

    // MARK: Trash

    /// `completion` is delivered on the main actor because it drives the
    /// outline; `NSWorkspace` promises nothing about which queue answers.
    func moveToTrash(
        _ url: URL,
        completion: @escaping @MainActor (FileExplorerEntryFailure?) -> Void
    ) {
        guard fileManager.fileExists(atPath: url.path) else {
            completion(.missing)
            return
        }
        recycle(url) { error in
            Task { @MainActor in
                completion(error.map(Self.failure(from:)))
            }
        }
    }

    // MARK: Support

    /// `nil` when the directory cannot be read at all, which is the same
    /// situation for the user whether it was deleted or never readable: the row
    /// they acted on is not somewhere this panel can write.
    private func siblingNames(in directory: URL) -> [String]? {
        try? fileManager.contentsOfDirectory(atPath: directory.path)
    }

    /// Defaults to case-insensitive when the volume will not say, matching the
    /// safe direction of `FileExplorerNameRule`.
    private func volumeIsCaseSensitive(at directory: URL) -> Bool {
        let values = try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames ?? false
    }

    private func failure(forNonAccepted decision: FileExplorerNameDecision) -> FileExplorerEntryFailure {
        guard case let .rejected(rejection) = decision else {
            // `.accepted` and `.unchanged` are handled by every caller before
            // reaching here; treating them as a name failure keeps the switch
            // total without inventing a success.
            return .unclassified(description: String(describing: decision))
        }
        return .name(rejection)
    }

    private static func failure(from error: Error) -> FileExplorerEntryFailure {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else {
            return .unclassified(description: nsError.localizedDescription)
        }
        switch nsError.code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return .denied
        case NSFileWriteVolumeReadOnlyError:
            return .readOnlyVolume
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .missing
        case NSFileWriteFileExistsError:
            // The sibling scan missed it, so something else wrote the path
            // between the check and the call. Reported as a collision because
            // that is what happened, and the write did not clobber it.
            return .name(.collides(existingName: nsError.userInfo[NSFilePathErrorKey] as? String ?? ""))
        default:
            return .unclassified(description: nsError.localizedDescription)
        }
    }
}

// MARK: - Failure copy

/// Localized wording for a failed entry action. Split from the writer and the
/// panel so the sentence a user reads can be asserted without a volume or a
/// window.
enum FileExplorerEntryFailureCopy {
    static func message(
        for failure: FileExplorerEntryFailure,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        switch failure {
        case let .name(rejection):
            return message(for: rejection, language: language)
        case .missing:
            return AppLocalization.string(.fileExplorerErrorMissing, language: language)
        case .denied:
            return AppLocalization.string(.fileExplorerErrorDenied, language: language)
        case .readOnlyVolume:
            return AppLocalization.string(.fileExplorerErrorReadOnlyVolume, language: language)
        case let .unclassified(description):
            return AppLocalization.format(.fileExplorerErrorUnclassified, language: language, description)
        }
    }

    private static func message(
        for rejection: FileExplorerNameRejection,
        language: AppLanguage
    ) -> String {
        switch rejection {
        case .empty:
            return AppLocalization.string(.fileExplorerErrorNameEmpty, language: language)
        case .reservedDotName:
            return AppLocalization.string(.fileExplorerErrorNameReserved, language: language)
        case .pathSeparator:
            return AppLocalization.string(.fileExplorerErrorNameSeparator, language: language)
        case let .tooLong(limitBYTES):
            return AppLocalization.format(.fileExplorerErrorNameTooLong, language: language, limitBYTES)
        case let .collides(existingName):
            return AppLocalization.format(.fileExplorerErrorNameExists, language: language, existingName)
        }
    }
}

// MARK: - Name prompt

/// The one modal in this feature. Naming a new entry is a blocking question by
/// nature — there is nothing to create until it is answered — while the
/// failures that follow are ordinary and stay inline in the panel.
@MainActor
enum FileExplorerNamePrompt {
    /// `nil` when the user cancelled.
    static func run(
        messageText: String,
        confirmTitle: String,
        initialName: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: AppLocalization.string(.cancel))

        let field = NSTextField(frame: NSRect(
            x: 0,
            y: 0,
            width: DesignTokens.Component.fileExplorerNamePromptFieldWidthPX,
            height: DesignTokens.Component.fileExplorerNamePromptFieldHeightPX
        ))
        field.stringValue = initialName
        field.font = DesignTokens.Typography.rowTitle.font
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return field.stringValue
    }
}
