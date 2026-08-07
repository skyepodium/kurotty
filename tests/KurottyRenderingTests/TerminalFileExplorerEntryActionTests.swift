import XCTest
@testable import KurottyApp

/// The explorer's write side. Nothing here reads a source file as text: every
/// assertion is either a pure decision or a real directory under
/// `FileManager.temporaryDirectory` that the test creates and removes.

// MARK: - Name rules (no disk)

final class FileExplorerNameRuleTests: XCTestCase {
    private enum Fixture {
        static let siblings = ["README.md", "Sources", "notes.txt"]
        static let overlongNameCOUNT = 256
    }

    private func decide(
        _ proposedName: String,
        siblings: [String] = Fixture.siblings,
        currentName: String? = nil,
        volumeIsCaseSensitive: Bool = false
    ) -> FileExplorerNameDecision {
        FileExplorerNameRule.decide(
            proposedName: proposedName,
            existingSiblingNames: siblings,
            currentName: currentName,
            volumeIsCaseSensitive: volumeIsCaseSensitive
        )
    }

    func testANameThatCannotExistIsRefusedBeforeAnythingIsWritten() {
        XCTAssertEqual(decide(""), .rejected(.empty))
        XCTAssertEqual(decide("   "), .rejected(.empty))
        XCTAssertEqual(decide("."), .rejected(.reservedDotName))
        XCTAssertEqual(decide(".."), .rejected(.reservedDotName))
        XCTAssertEqual(decide("docs/notes.txt"), .rejected(.pathSeparator))
        XCTAssertEqual(decide("/"), .rejected(.pathSeparator))
        XCTAssertEqual(decide("na\0me"), .rejected(.pathSeparator))
        XCTAssertEqual(
            decide(String(repeating: "x", count: Fixture.overlongNameCOUNT)),
            .rejected(.tooLong(limitBYTES: FileExplorerNameRule.maximumNameBYTES))
        )
    }

    /// The byte limit is a byte limit: 200 Korean characters are 600 bytes and
    /// a rule that counted characters would wave them through to an `ENAMETOOLONG`.
    func testTheLengthLimitCountsBytesRatherThanCharacters() {
        let name = String(repeating: "가", count: 100)
        XCTAssertEqual(name.count, 100)
        XCTAssertGreaterThan(name.utf8.count, FileExplorerNameRule.maximumNameBYTES)
        XCTAssertEqual(
            decide(name),
            .rejected(.tooLong(limitBYTES: FileExplorerNameRule.maximumNameBYTES))
        )
    }

    func testALeadingDotIsAnOrdinaryName() {
        XCTAssertEqual(decide(".gitignore"), .accepted(name: ".gitignore"))
        XCTAssertEqual(decide(".env.local"), .accepted(name: ".env.local"))
    }

    /// macOS stores `notes.txt ` happily and then everything downstream — tab
    /// completion in the terminal beside this panel most of all — disagrees
    /// with what the eye read. Finder trims; so does this.
    func testSurroundingWhitespaceIsTrimmedRatherThanStored() {
        XCTAssertEqual(decide("notes2.txt "), .accepted(name: "notes2.txt"))
        XCTAssertEqual(decide("  notes2.txt"), .accepted(name: "notes2.txt"))
        XCTAssertEqual(decide("notes2.txt\n"), .accepted(name: "notes2.txt"))
        // Trimming is not a licence to collide: the trimmed name is what gets
        // compared against the siblings.
        XCTAssertEqual(decide("README.md "), .rejected(.collides(existingName: "README.md")))
    }

    func testACaseOnlyClashIsACollisionOnTheVolumeMacOSShips() {
        XCTAssertEqual(decide("readme.md"), .rejected(.collides(existingName: "README.md")))
        XCTAssertEqual(decide("SOURCES"), .rejected(.collides(existingName: "Sources")))
    }

    func testACaseOnlyClashIsAllowedOnACaseSensitiveVolume() {
        XCTAssertEqual(
            decide("readme.md", volumeIsCaseSensitive: true),
            .accepted(name: "readme.md")
        )
    }

    /// APFS and HFS+ are normalization-insensitive whichever case mode they are
    /// in, so two spellings of the same accented name are one directory entry.
    func testTwoUnicodeSpellingsOfOneNameCollide() {
        let precomposed = "caf\u{00E9}.txt"
        let decomposed = "cafe\u{0301}.txt"
        XCTAssertNotEqual(
            Array(precomposed.unicodeScalars),
            Array(decomposed.unicodeScalars),
            "the fixture must be two different scalar sequences to be worth testing"
        )
        XCTAssertEqual(
            decide(decomposed, siblings: [precomposed]),
            .rejected(.collides(existingName: precomposed))
        )
        XCTAssertEqual(
            decide(decomposed, siblings: [precomposed], volumeIsCaseSensitive: true),
            .rejected(.collides(existingName: precomposed))
        )
    }

    func testRenamingToTheCurrentNameIsNothingToDoRatherThanACollision() {
        XCTAssertEqual(decide("README.md", currentName: "README.md"), .unchanged)
    }

    /// The entry never collides with itself, which is also what lets a case-only
    /// rename through — a rename Finder offers and the volume performs.
    func testAnEntryCanBeRenamedToADifferentSpellingOfItsOwnName() {
        XCTAssertEqual(
            decide("readme.md", currentName: "README.md"),
            .accepted(name: "readme.md")
        )
        XCTAssertEqual(
            decide("Sources", currentName: "README.md"),
            .rejected(.collides(existingName: "Sources"))
        )
    }
}

// MARK: - Where a new entry lands (no disk)

final class FileExplorerCreationTargetTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Users/tester/dev/project", isDirectory: true)

    /// Compared by `path`: `deletingLastPathComponent()` leaves a trailing
    /// slash that `appendingPathComponent` does not, and the two spell the same
    /// directory.
    private func targetPath(forSelectedNode node: FileExplorerNode?) -> String {
        FileExplorerCreationTarget.directory(forSelectedNode: node, rootDirectory: root)
            .standardizedFileURL
            .path
    }

    func testNothingSelectedCreatesInThePanelRoot() {
        XCTAssertEqual(targetPath(forSelectedNode: nil), "/Users/tester/dev/project")
    }

    func testASelectedFolderTakesTheNewEntryInside() {
        let node = FileExplorerNode(url: root.appendingPathComponent("Sources"), kind: .directory)
        XCTAssertEqual(targetPath(forSelectedNode: node), "/Users/tester/dev/project/Sources")
    }

    func testASelectedFilePutsTheNewEntryBesideIt() {
        let node = FileExplorerNode(
            url: root.appendingPathComponent("Sources/Main.swift"),
            kind: .file
        )
        XCTAssertEqual(targetPath(forSelectedNode: node), "/Users/tester/dev/project/Sources")
    }
}

// MARK: - Which actions are legal (no disk)

final class FileExplorerEntryActionAvailabilityTests: XCTestCase {
    private func context(
        isRemote: Bool = false,
        hasRootDirectory: Bool = true,
        hasSelection: Bool = true,
        selectionExists: Bool = true,
        isCreationDirectoryWritable: Bool = true,
        isSelectionDirectoryWritable: Bool = true
    ) -> FileExplorerEntryActionContext {
        FileExplorerEntryActionContext(
            isRemote: isRemote,
            hasRootDirectory: hasRootDirectory,
            hasSelection: hasSelection,
            selectionExists: selectionExists,
            isCreationDirectoryWritable: isCreationDirectoryWritable,
            isSelectionDirectoryWritable: isSelectionDirectoryWritable
        )
    }

    func testARemoteWorkingDirectoryOffersNoWriteAtAll() {
        let remote = context(isRemote: true)
        for action in FileExplorerEntryAction.allCases {
            XCTAssertFalse(action.isAvailable(in: remote), "\(action) offered on a remote host")
        }
    }

    func testCreateNeedsNoSelectionButRenameAndTrashDo() {
        let noSelection = context(hasSelection: false, selectionExists: false)
        XCTAssertTrue(FileExplorerEntryAction.newFile.isAvailable(in: noSelection))
        XCTAssertTrue(FileExplorerEntryAction.newFolder.isAvailable(in: noSelection))
        XCTAssertFalse(FileExplorerEntryAction.rename.isAvailable(in: noSelection))
        XCTAssertFalse(FileExplorerEntryAction.moveToTrash.isAvailable(in: noSelection))
    }

    /// A row whose path went away under the watcher is still on screen for a
    /// beat. Acting on it is the one thing that must not be offered.
    func testARowWhosePathHasVanishedCannotBeRenamedOrTrashed() {
        let vanished = context(selectionExists: false)
        XCTAssertFalse(FileExplorerEntryAction.rename.isAvailable(in: vanished))
        XCTAssertFalse(FileExplorerEntryAction.moveToTrash.isAvailable(in: vanished))
        XCTAssertTrue(FileExplorerEntryAction.newFile.isAvailable(in: vanished))
    }

    func testAnUnwritableDirectoryWithholdsTheActionThatWouldWriteToIt() {
        XCTAssertFalse(
            FileExplorerEntryAction.newFile.isAvailable(in: context(isCreationDirectoryWritable: false))
        )
        XCTAssertFalse(
            FileExplorerEntryAction.rename.isAvailable(in: context(isSelectionDirectoryWritable: false))
        )
        XCTAssertFalse(
            FileExplorerEntryAction.moveToTrash
                .isAvailable(in: context(isSelectionDirectoryWritable: false))
        )
    }
}

// MARK: - Writes against a real temporary directory

@MainActor
final class FileExplorerEntryWriterTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-entry-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore any permission the test dropped, or the fixture cannot be removed.
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for name in contents {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: root.appendingPathComponent(name).path
                )
            }
        }
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func writeFile(_ name: String, contents: String = "original\n") throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func volumeIsCaseSensitive() -> Bool {
        let values = try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames ?? false
    }

    private func failure<T>(_ result: Result<T, FileExplorerEntryFailure>) -> FileExplorerEntryFailure? {
        guard case let .failure(failure) = result else {
            return nil
        }
        return failure
    }

    func testCreatingAFileAndAFolderInAnEmptyDirectory() throws {
        let writer = FileExplorerEntryWriter()
        XCTAssertEqual(
            try XCTUnwrap(try? writer.createFile(named: "notes.txt", in: root).get()).lastPathComponent,
            "notes.txt"
        )
        XCTAssertEqual(
            try XCTUnwrap(try? writer.createDirectory(named: "docs", in: root).get()).lastPathComponent,
            "docs"
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("docs").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// The whole point of the feature's care: a create that lands on an
    /// existing entry has to fail, and the entry has to still hold what it held.
    func testCreatingOntoACaseOnlyVariantRefusesAndLeavesTheFileIntact() throws {
        try XCTSkipIf(volumeIsCaseSensitive(), "README.md and readme.md are two files here")
        let existing = try writeFile("README.md")
        let result = FileExplorerEntryWriter().createFile(named: "readme.md", in: root)
        XCTAssertEqual(failure(result), .name(.collides(existingName: "README.md")))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["README.md"])
    }

    func testCreatingAFolderOntoAnExistingFolderRefusesRatherThanSucceedingSilently() throws {
        let writer = FileExplorerEntryWriter()
        _ = try writer.createDirectory(named: "docs", in: root).get()
        XCTAssertEqual(
            failure(writer.createDirectory(named: "docs", in: root)),
            .name(.collides(existingName: "docs"))
        )
    }

    func testRenamingOntoAnExistingNameRefusesAndLeavesBothFiles() throws {
        let source = try writeFile("a.txt", contents: "a\n")
        _ = try writeFile("b.txt", contents: "b\n")
        let result = FileExplorerEntryWriter().rename(source, to: "b.txt")
        XCTAssertEqual(failure(result), .name(.collides(existingName: "b.txt")))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "a\n")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8),
            "b\n"
        )
    }

    func testRenamingToTheSameNameSucceedsWithoutTouchingTheFile() throws {
        let source = try writeFile("a.txt", contents: "a\n")
        let renamed = try FileExplorerEntryWriter().rename(source, to: "a.txt").get()
        XCTAssertEqual(renamed.lastPathComponent, "a.txt")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "a\n")
    }

    func testAnEntryCanBeRenamedToADifferentSpellingOfItsOwnName() throws {
        try XCTSkipIf(volumeIsCaseSensitive(), "a case-only rename is an ordinary rename here")
        let source = try writeFile("README.md")
        let renamed = try FileExplorerEntryWriter().rename(source, to: "readme.md").get()
        XCTAssertEqual(renamed.lastPathComponent, "readme.md")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["readme.md"])
    }

    func testRenamingSomethingThatIsNoLongerThereReportsItAsMissing() {
        let gone = root.appendingPathComponent("gone.txt")
        XCTAssertEqual(failure(FileExplorerEntryWriter().rename(gone, to: "still-gone.txt")), .missing)
    }

    func testCreatingInsideADirectoryWithNoWritePermissionIsDenied() throws {
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        try XCTSkipIf(
            FileManager.default.isWritableFile(atPath: locked.path),
            "the test process can write regardless of mode"
        )
        XCTAssertEqual(failure(FileExplorerEntryWriter().createFile(named: "x.txt", in: locked)), .denied)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locked.path), [])
    }

    func testDeleteGoesToTheTrashAndNeverUnlinks() throws {
        let file = try writeFile("doomed.txt")
        var recycled: [URL] = []
        // The fake records the call and deliberately leaves the file alone, so
        // a panel that unlinked on its own would be caught by the file still
        // being expected on disk afterwards.
        let writer = FileExplorerEntryWriter(recycle: { url, completion in
            recycled.append(url)
            completion(nil)
        })
        let completed = expectation(description: "trash completed")
        writer.moveToTrash(file) { failure in
            XCTAssertNil(failure)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(recycled, [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeletingSomethingAlreadyGoneNeverReachesTheTrash() {
        var recycleCallCOUNT = 0
        let writer = FileExplorerEntryWriter(recycle: { _, completion in
            recycleCallCOUNT += 1
            completion(nil)
        })
        var reported: FileExplorerEntryFailure?
        writer.moveToTrash(root.appendingPathComponent("gone.txt")) { reported = $0 }
        XCTAssertEqual(reported, .missing)
        XCTAssertEqual(recycleCallCOUNT, 0)
    }
}

// MARK: - The panel, end to end

@MainActor
final class TerminalFileExplorerEntryActionPanelTests: XCTestCase {
    private enum PanelFixture {
        static let widthPX: CGFloat = 320
        static let heightPX: CGFloat = 400
    }

    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-explorer-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for name in contents {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: root.appendingPathComponent(name).path
                )
            }
        }
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makePanel(entryWriter: FileExplorerEntryWriter = FileExplorerEntryWriter())
        -> TerminalFileExplorerPanelView {
        let panel = TerminalFileExplorerPanelView(
            agentSessionIndexStore: AgentSessionIndexStore(
                homeDirectory: root,
                scanners: [],
                isIndexingEnabled: false,
                observesSettingsChanges: false
            ),
            entryWriter: entryWriter
        )
        panel.frame = NSRect(x: 0, y: 0, width: PanelFixture.widthPX, height: PanelFixture.heightPX)
        panel.update(rootDirectory: root)
        panel.layoutSubtreeIfNeeded()
        return panel
    }

    private func volumeIsCaseSensitive() -> Bool {
        let values = try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames ?? false
    }

    func testCreatingInAnEmptyRootShowsTheNewRowAndSelectsIt() {
        let panel = makePanel()
        XCTAssertEqual(panel.rowNamesForTesting(), [])
        panel.createForTesting(.newFile, named: "notes.txt")
        XCTAssertEqual(panel.rowNamesForTesting(), ["notes.txt"])
        XCTAssertEqual(panel.selectedRowNameForTesting, "notes.txt")
        XCTAssertNil(panel.actionErrorMessageForTesting)
    }

    func testCreatingWithAFileSelectedLandsBesideItAndWithAFolderSelectedLandsInside() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let panel = makePanel()
        // Directories sort first, so row 0 is `docs` and row 1 is `a.txt`.
        XCTAssertEqual(panel.rowNamesForTesting(), ["docs", "a.txt"])

        panel.selectRowForTesting(1)
        panel.createForTesting(.newFile, named: "beside.txt")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("beside.txt").path
        ))

        panel.selectRowForTesting(0)
        panel.createForTesting(.newFile, named: "inside.txt")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("docs/inside.txt").path
        ))
        // The new row is revealed rather than hidden inside a collapsed folder.
        XCTAssertEqual(panel.selectedRowNameForTesting, "inside.txt")
    }

    func testACaseOnlyCollisionFailsInlineAndLeavesTheExistingFileAlone() throws {
        try XCTSkipIf(volumeIsCaseSensitive(), "README.md and readme.md are two files here")
        let existing = root.appendingPathComponent("README.md")
        try "original\n".write(to: existing, atomically: true, encoding: .utf8)
        let panel = makePanel()

        panel.createForTesting(.newFile, named: "readme.md")

        XCTAssertEqual(
            panel.actionErrorMessageForTesting,
            AppLocalization.format(.fileExplorerErrorNameExists, "README.md")
        )
        XCTAssertEqual(panel.rowNamesForTesting(), ["README.md"])
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original\n")
    }

    func testEveryNameThatCannotWorkIsRefusedWithItsOwnSentence() {
        let panel = makePanel()
        let cases: [(name: String, key: L10nKey)] = [
            ("", .fileExplorerErrorNameEmpty),
            ("   ", .fileExplorerErrorNameEmpty),
            (".", .fileExplorerErrorNameReserved),
            ("..", .fileExplorerErrorNameReserved),
            ("docs/notes.txt", .fileExplorerErrorNameSeparator),
        ]
        for testCase in cases {
            panel.createForTesting(.newFile, named: testCase.name)
            XCTAssertEqual(
                panel.actionErrorMessageForTesting,
                AppLocalization.string(testCase.key),
                "wrong message for \(testCase.name.debugDescription)"
            )
            XCTAssertEqual(panel.rowNamesForTesting(), [], "\(testCase.name.debugDescription) was created")
        }
        panel.createForTesting(.newFile, named: String(repeating: "x", count: 256))
        XCTAssertEqual(
            panel.actionErrorMessageForTesting,
            AppLocalization.format(
                .fileExplorerErrorNameTooLong,
                FileExplorerNameRule.maximumNameBYTES
            )
        )
        XCTAssertEqual(panel.rowNamesForTesting(), [])

        // A leading dot is a name, not a rejection.
        panel.createForTesting(.newFile, named: ".gitignore")
        XCTAssertNil(panel.actionErrorMessageForTesting)
        XCTAssertEqual(panel.rowNamesForTesting(), [".gitignore"])
    }

    func testASucceedingActionClearsTheFailureLeftByTheOneBeforeIt() {
        let panel = makePanel()
        panel.createForTesting(.newFile, named: ".")
        XCTAssertNotNil(panel.actionErrorMessageForTesting)
        panel.createForTesting(.newFile, named: "notes.txt")
        XCTAssertNil(panel.actionErrorMessageForTesting)
    }

    func testRenamingOntoAnExistingNameFailsInlineAndKeepsBothRows() throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let panel = makePanel()
        panel.selectRowForTesting(0)

        panel.renameSelectionForTesting(to: "b.txt")

        XCTAssertEqual(
            panel.actionErrorMessageForTesting,
            AppLocalization.format(.fileExplorerErrorNameExists, "b.txt")
        )
        XCTAssertEqual(panel.rowNamesForTesting(), ["a.txt", "b.txt"])
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8),
            "b\n"
        )
    }

    func testRenamingToTheSameNameIsNotAnError() throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let panel = makePanel()
        panel.selectRowForTesting(0)

        panel.renameSelectionForTesting(to: "a.txt")

        XCTAssertNil(panel.actionErrorMessageForTesting)
        XCTAssertEqual(panel.rowNamesForTesting(), ["a.txt"])
    }

    func testARenameReplacesTheRowRatherThanAddingASecondOne() throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let panel = makePanel()
        panel.selectRowForTesting(0)

        panel.renameSelectionForTesting(to: "renamed.txt")

        XCTAssertEqual(panel.rowNamesForTesting(), ["renamed.txt"])
        XCTAssertEqual(panel.selectedRowNameForTesting, "renamed.txt")
    }

    /// The panel re-lists from disk instead of inserting a row of its own, so
    /// the watcher's own debounced refresh arriving afterwards is a second
    /// re-list of the same directory rather than a duplicate row.
    func testTheWatcherRefreshArrivingAfterACreateCannotDuplicateTheRow() {
        let panel = makePanel()
        panel.createForTesting(.newFile, named: "notes.txt")
        XCTAssertEqual(panel.rowNamesForTesting(), ["notes.txt"])
        panel.refresh()
        panel.refresh()
        XCTAssertEqual(panel.rowNamesForTesting(), ["notes.txt"])
    }

    func testAWriteThatIsRefusedByPermissionsSaysSoInline() throws {
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        try XCTSkipIf(
            FileManager.default.isWritableFile(atPath: locked.path),
            "the test process can write regardless of mode"
        )
        let panel = makePanel()
        panel.selectRowForTesting(0)
        XCTAssertEqual(panel.selectedRowNameForTesting, "locked")

        // The menu withholds the action, and the write underneath refuses it
        // too — the check and the guarantee are separate on purpose.
        XCTAssertFalse(panel.entryActionIsAvailableForTesting(.newFile))
        panel.createForTesting(.newFile, named: "x.txt")
        XCTAssertEqual(
            panel.actionErrorMessageForTesting,
            AppLocalization.string(.fileExplorerErrorDenied)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locked.path), [])
    }

    func testTrashTakesTheRowAwayWithoutThePanelUnlinkingAnything() throws {
        let file = root.appendingPathComponent("doomed.txt")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        var recycled: [URL] = []
        let writer = FileExplorerEntryWriter(recycle: { url, completion in
            recycled.append(url)
            // Stands in for the Trash: the entry leaves the directory, and it
            // is this closure — never the panel — that moves it.
            try? FileManager.default.removeItem(at: url)
            completion(nil)
        })
        let panel = makePanel(entryWriter: writer)
        panel.selectRowForTesting(0)

        panel.moveSelectionToTrashForTesting()
        let settled = expectation(description: "trash completion reached the panel")
        Task { @MainActor in settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(recycled.map(\.lastPathComponent), ["doomed.txt"])
        XCTAssertEqual(panel.rowNamesForTesting(), [])
        XCTAssertNil(panel.actionErrorMessageForTesting)
    }

    func testAFailedTrashSaysSoAndLeavesTheRow() throws {
        let file = root.appendingPathComponent("doomed.txt")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        let writer = FileExplorerEntryWriter(recycle: { _, completion in
            completion(NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError,
                userInfo: nil
            ))
        })
        let panel = makePanel(entryWriter: writer)
        panel.selectRowForTesting(0)

        panel.moveSelectionToTrashForTesting()
        let settled = expectation(description: "trash completion reached the panel")
        Task { @MainActor in settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(
            panel.actionErrorMessageForTesting,
            AppLocalization.string(.fileExplorerErrorDenied)
        )
        XCTAssertEqual(panel.rowNamesForTesting(), ["doomed.txt"])
    }

    /// The explorer browses local files only, so a working directory on another
    /// machine gets no write action offered — not a disabled one that fails.
    func testARemoteWorkingDirectoryDisablesEveryWriteActionInTheMenu() throws {
        let panel = makePanel()
        panel.update(location: TerminalWorkingDirectoryLocation(
            path: "/srv/app",
            remoteHost: "tester@build-box"
        ))
        panel.layoutSubtreeIfNeeded()

        for action in FileExplorerEntryAction.allCases {
            XCTAssertFalse(
                panel.entryActionIsAvailableForTesting(action),
                "\(action) offered while the working directory is remote"
            )
        }
        let menu = try XCTUnwrap(panel.contextMenuForTesting)
        menu.delegate?.menuNeedsUpdate?(menu)
        let writeTitles = [
            AppLocalization.string(.fileExplorerNewFile),
            AppLocalization.string(.fileExplorerNewFolder),
            AppLocalization.string(.fileExplorerRenameEntry),
            AppLocalization.string(.fileExplorerMoveToTrash),
        ]
        for title in writeTitles {
            let item = try XCTUnwrap(menu.items.first { $0.title == title }, "missing item \(title)")
            XCTAssertFalse(item.isEnabled, "\(title) enabled on a remote host")
        }
    }

    func testTheMenuSeparatesReadingActionsFromWritingOnesAndPutsTrashLast() throws {
        let menu = try XCTUnwrap(makePanel().contextMenuForTesting)
        let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        let firstSeparator = try XCTUnwrap(titles.firstIndex(of: "-"))
        let newFileIndex = try XCTUnwrap(
            titles.firstIndex(of: AppLocalization.string(.fileExplorerNewFile))
        )
        let trashIndex = try XCTUnwrap(
            titles.firstIndex(of: AppLocalization.string(.fileExplorerMoveToTrash))
        )
        XCTAssertLessThan(firstSeparator, newFileIndex)
        XCTAssertLessThan(
            titles.firstIndex(of: AppLocalization.string(.copyPath)) ?? .max,
            firstSeparator
        )
        XCTAssertEqual(trashIndex, titles.count - 1)
        XCTAssertTrue(menu.items[trashIndex - 1].isSeparatorItem)
    }

    /// Return renames the way Finder does. The binding lives on the outline
    /// view because a contextual menu's key equivalent only fires while that
    /// menu is open; the menu item still shows it so the shortcut is findable.
    func testTheRenameAndTrashShortcutsAreShownWhereTheActionsAre() throws {
        let menu = try XCTUnwrap(makePanel().contextMenuForTesting)
        let rename = try XCTUnwrap(
            menu.items.first { $0.title == AppLocalization.string(.fileExplorerRenameEntry) }
        )
        XCTAssertEqual(rename.keyEquivalent, "\r")
        XCTAssertTrue(rename.keyEquivalentModifierMask.isEmpty)
        let trash = try XCTUnwrap(
            menu.items.first { $0.title == AppLocalization.string(.fileExplorerMoveToTrash) }
        )
        XCTAssertEqual(trash.keyEquivalent, String(UnicodeScalar(NSBackspaceCharacter)!))
        XCTAssertEqual(trash.keyEquivalentModifierMask, .command)
    }

    /// A panel that has refused nothing keeps exactly the layout it had before
    /// this feature existed, and gives the space back once the failure clears.
    func testTheInlineErrorRowTakesNoSpaceUntilThereIsSomethingToSay() {
        let panel = makePanel()
        let quietListHeight = panel.listContainerHeightForTesting
        XCTAssertEqual(panel.actionErrorRowHeightForTesting, 0)

        panel.createForTesting(.newFile, named: ".")
        panel.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(panel.actionErrorRowHeightForTesting, 0)
        XCTAssertLessThan(panel.listContainerHeightForTesting, quietListHeight)

        panel.createForTesting(.newFile, named: "notes.txt")
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.actionErrorRowHeightForTesting, 0)
        XCTAssertEqual(panel.listContainerHeightForTesting, quietListHeight)
    }
}

// MARK: - Copy

final class FileExplorerEntryFailureCopyTests: XCTestCase {
    func testEveryFailureHasAWordingInEveryLanguage() {
        let failures: [FileExplorerEntryFailure] = [
            .name(.empty),
            .name(.reservedDotName),
            .name(.pathSeparator),
            .name(.tooLong(limitBYTES: FileExplorerNameRule.maximumNameBYTES)),
            .name(.collides(existingName: "README.md")),
            .missing,
            .denied,
            .readOnlyVolume,
            .unclassified(description: "disk quota exceeded"),
        ]
        for language in AppLanguage.allCases {
            for failure in failures {
                let message = FileExplorerEntryFailureCopy.message(for: failure, language: language)
                XCTAssertFalse(message.isEmpty, "\(language.rawValue) has no wording for \(failure)")
                XCTAssertFalse(
                    message.contains("%"),
                    "\(language.rawValue) left a format specifier unsubstituted for \(failure)"
                )
            }
        }
    }

    /// A dropped specifier would print the format string at the user instead of
    /// the name they typed, and the global localization test cannot see that.
    func testTheSubstitutingStringsKeepTheirSpecifierInEveryLanguage() {
        for language in AppLanguage.allCases {
            XCTAssertTrue(
                AppLocalization.string(.fileExplorerErrorNameExists, language: language).contains("%@")
            )
            XCTAssertTrue(
                AppLocalization.string(.fileExplorerErrorUnclassified, language: language).contains("%@")
            )
            XCTAssertTrue(
                AppLocalization.string(.fileExplorerErrorNameTooLong, language: language).contains("%d")
            )
            for key in [L10nKey.fileExplorerNewFilePrompt, .fileExplorerNewFolderPrompt, .fileExplorerRenamePrompt] {
                XCTAssertTrue(
                    AppLocalization.string(key, language: language).contains("%@"),
                    "\(language.rawValue) lost the name placeholder in \(key.rawValue)"
                )
            }
        }
    }
}
