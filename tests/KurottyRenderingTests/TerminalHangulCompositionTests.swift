import XCTest
@testable import KurottyCore
@testable import KurottyApp

/// Behavioural cover for decomposed-Hangul output.
///
/// macOS filesystems store filenames decomposed, so every Korean path printed by
/// `ls`, `git log` or a build log arrives as conjoining jamo. The contract these
/// tests hold is that such a row ends up indistinguishable from the same text
/// printed precomposed — same cells, same column advance, same serialized
/// snapshot, same search hits — no matter how the PTY chunked the jamo.
@MainActor
final class TerminalHangulCompositionTests: XCTestCase {
    private enum Fixture {
        static let rows = 6
        static let columns = 20

        /// `각` as the filesystem hands it out: initial ᄀ, medial ᅡ, final ᆨ.
        static let decomposedGak = "\u{1100}\u{1161}\u{11A8}"
        static let precomposedGak = "\u{AC01}"
        /// `한글.txt`, fully decomposed, as `ls` prints it.
        static let decomposedFileName =
            "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}.txt"
        static let precomposedFileName = "한글.txt"
        /// Distinct from `.default` so a merged cell that lost its pen is
        /// visibly wrong rather than coincidentally equal.
        static let pen = TerminalTextStyle(
            foreground: SIMD4<Float>(0.9, 0.4, 0.2, 1),
            background: SIMD4<Float>(0.1, 0.3, 0.5, 1)
        )
    }

    private func makeInterpreter(
        rows: Int = Fixture.rows,
        columns: Int = Fixture.columns
    ) -> TerminalOutputInterpreter {
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: .default,
            ansiColors: DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright,
            maxScrollbackRows: 1_000
        )
        interpreter.screen = TerminalScreen(rows: rows, columns: columns)
        interpreter.scrollRegionBottom = rows - 1
        return interpreter
    }

    /// A row compared by scalars rather than by `==`.
    ///
    /// `Character` and `TerminalScreenCell` equality both fold NFD onto NFC
    /// under Swift's canonical equivalence, so asserting a cell "equals 한"
    /// passes whether it holds one scalar or three. Everything that actually
    /// broke — the column count, the glyph run, the serialized bytes, a regex
    /// query — works below that fold, so the assertions do too.
    private func scalarSignature(
        _ row: Int,
        of interpreter: TerminalOutputInterpreter
    ) -> [[UInt32]] {
        interpreter.screen.cells[row].map { cell in
            cell.isContinuation ? [] : cell.character.unicodeScalars.map(\.value)
        }
    }

    /// Row text with continuation cells dropped, which is what a copy or a
    /// snapshot sees.
    private func text(_ row: Int, of interpreter: TerminalOutputInterpreter) -> String {
        String(
            interpreter.screen.cells[row]
                .filter { !$0.isContinuation }
                .map(\.character)
        )
        .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Composition algorithm

    func testLeadingAndMedialJamoComposeIntoASyllable() {
        XCTAssertEqual(
            TerminalHangulComposition.composed("\u{1100}\u{1161}"),
            "\u{AC00}"
        )
    }

    /// Swift already reads `L V T` as one grapheme cluster, so the three-jamo
    /// case is about the scalars inside that cluster, not about how many cells
    /// it takes.
    func testWholeJamoClusterComposesToASingleScalar() {
        let composed = TerminalHangulComposition.composed(Character(Fixture.decomposedGak))

        XCTAssertEqual(composed.unicodeScalars.map(\.value), [0xAC01])
        XCTAssertEqual(String(composed), Fixture.precomposedGak)
        XCTAssertEqual(composed.terminalColumnWidth, 2)
    }

    /// The case Foundation's NFC does not handle: a precomposed `LV` syllable
    /// followed by a trailing jamo, which is exactly what a cross-chunk split
    /// produces once the first two jamo have been written.
    func testPrecomposedSyllablePlusTrailingJamoComposes() {
        XCTAssertEqual(
            TerminalHangulComposition.merging("\u{AC00}", with: "\u{11A8}"),
            "\u{AC01}"
        )
        // Compared by scalars on purpose: Swift's `==` folds these two together
        // under canonical equivalence, which is exactly why the difference goes
        // unnoticed until something scalar-level — a regex, a glyph cache, the
        // serialized bytes — looks at it.
        XCTAssertEqual(
            Array("\u{AC00}\u{11A8}".precomposedStringWithCanonicalMapping.unicodeScalars).count,
            2,
            "if Foundation ever composes this, the hand-rolled algorithm can go"
        )
    }

    /// A syllable that already has a final consonant is complete. A further
    /// trailing jamo is separate text, not more of it.
    func testCompleteSyllableDoesNotAbsorbAnotherTrailingJamo() {
        XCTAssertNil(TerminalHangulComposition.merging("\u{AC01}", with: "\u{11A8}"))
    }

    func testNonHangulTextIsReturnedUntouched() {
        XCTAssertEqual(TerminalHangulComposition.composed("e\u{0301}"), "e\u{0301}")
        XCTAssertEqual(TerminalHangulComposition.composed("git log --oneline"), "git log --oneline")
        XCTAssertEqual(TerminalHangulComposition.composed("😀"), "😀")
    }

    // MARK: - Decomposed output in one chunk

    func testDecomposedKoreanFileNameLandsInPrecomposedCells() {
        let interpreter = makeInterpreter()
        interpreter.interpret(Fixture.decomposedFileName)

        XCTAssertEqual(text(0, of: interpreter), Fixture.precomposedFileName)
        XCTAssertEqual(
            interpreter.screen.cells[0][0].character.unicodeScalars.count,
            1,
            "the cell must hold one precomposed scalar, not three jamo"
        )
        XCTAssertEqual(String(interpreter.screen.cells[0][0].character), "한")
        XCTAssertTrue(interpreter.screen.cells[0][1].isContinuation)
        XCTAssertEqual(String(interpreter.screen.cells[0][2].character), "글")
        XCTAssertTrue(interpreter.screen.cells[0][3].isContinuation)
        XCTAssertEqual(String(interpreter.screen.cells[0][4].character), ".")
        // Two wide syllables plus ".txt".
        XCTAssertEqual(interpreter.cursorColumn, 8)
    }

    func testDecomposedAndPrecomposedOutputProduceTheSameGrid() {
        let decomposed = makeInterpreter()
        decomposed.interpret(Fixture.decomposedFileName)
        let precomposed = makeInterpreter()
        precomposed.interpret(Fixture.precomposedFileName)

        XCTAssertEqual(
            scalarSignature(0, of: decomposed),
            scalarSignature(0, of: precomposed)
        )
        XCTAssertEqual(decomposed.screen.cells[0], precomposed.screen.cells[0])
        XCTAssertEqual(decomposed.cursorColumn, precomposed.cursorColumn)
    }

    // MARK: - Jamo split across feed calls

    /// The PTY read boundary can fall anywhere. Three `interpret` calls, one
    /// jamo each, must converge on the single cell the whole syllable would
    /// have produced — including the column count, which is what a split got
    /// wrong before: a lone `ᄀ` is wide but a lone `ᅡ` and a lone `ᆨ` are not,
    /// so the syllable claimed four columns instead of two.
    func testJamoSplitAcrossThreeFeedsComposeIntoOneCell() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1100}")
        interpreter.interpret("\u{1161}")
        interpreter.interpret("\u{11A8}")

        XCTAssertEqual(scalarSignature(0, of: interpreter)[0], [0xAC01])
        XCTAssertTrue(interpreter.screen.cells[0][1].isContinuation)
        XCTAssertEqual(String(interpreter.screen.cells[0][2].character), " ")
        XCTAssertFalse(interpreter.screen.cells[0][2].isContinuation)
        XCTAssertEqual(interpreter.cursorColumn, 2)
    }

    func testJamoSplitAcrossTwoFeedsComposeIntoOneCell() {
        let afterMedial = makeInterpreter()
        afterMedial.interpret("\u{1100}\u{1161}")
        afterMedial.interpret("\u{11A8}")

        XCTAssertEqual(scalarSignature(0, of: afterMedial)[0], [0xAC01])
        XCTAssertEqual(afterMedial.cursorColumn, 2)

        let afterLeading = makeInterpreter()
        afterLeading.interpret("\u{1100}")
        afterLeading.interpret("\u{1161}\u{11A8}")

        XCTAssertEqual(scalarSignature(0, of: afterLeading)[0], [0xAC01])
        XCTAssertEqual(afterLeading.cursorColumn, 2)
    }

    /// A whole decomposed name delivered one jamo per call, with the text that
    /// follows it landing where it would have anyway.
    func testFileNameFedOneJamoPerCallMatchesTheWholeString() {
        let split = makeInterpreter()
        for character in Fixture.decomposedFileName {
            for scalar in character.unicodeScalars {
                split.interpret(String(scalar))
            }
        }
        let whole = makeInterpreter()
        whole.interpret(Fixture.precomposedFileName)

        XCTAssertEqual(scalarSignature(0, of: split), scalarSignature(0, of: whole))
        XCTAssertEqual(split.screen.cells[0], whole.screen.cells[0])
        XCTAssertEqual(split.cursorColumn, whole.cursorColumn)
    }

    func testMergedSyllableKeepsThePenTheJamoWereWrittenWith() {
        let interpreter = makeInterpreter()
        interpreter.currentStyle = Fixture.pen
        interpreter.interpret("\u{1100}\u{1161}")
        interpreter.interpret("\u{11A8}")

        XCTAssertEqual(interpreter.screen.cells[0][0].style, Fixture.pen)
        XCTAssertEqual(interpreter.screen.cells[0][1].style, Fixture.pen)
    }

    // MARK: - Merge boundaries

    /// A control byte between the syllable and the jamo ends the syllable. The
    /// jamo then belongs to whatever comes next, not to the cell above.
    func testNewlineBetweenChunksEndsTheSyllable() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1100}\u{1161}")
        interpreter.interpret("\r\n")
        interpreter.interpret("\u{11A8}")

        XCTAssertEqual(String(interpreter.screen.cells[0][0].character), "\u{AC00}")
        XCTAssertEqual(String(interpreter.screen.cells[1][0].character), "\u{11A8}")
    }

    /// Cursor addressing between the chunks moves the write somewhere else, so
    /// the pending syllable must not be rewritten from its new position.
    func testCursorMoveBetweenChunksEndsTheSyllable() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1100}\u{1161}")
        interpreter.interpret("\u{1b}[3;5H")
        interpreter.interpret("\u{11A8}")

        XCTAssertEqual(String(interpreter.screen.cells[0][0].character), "\u{AC00}")
        XCTAssertEqual(String(interpreter.screen.cells[2][4].character), "\u{11A8}")
    }

    /// A program that printed a precomposed syllable and then, separately, a
    /// lone trailing jamo meant two things. Decomposed text never contains a
    /// precomposed syllable, so nothing real is lost by refusing this merge.
    func testTrailingJamoAfterAPrecomposedSyllableIsNotFoldedIn() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{AC00}")
        interpreter.interpret("\u{11A8}")

        XCTAssertEqual(String(interpreter.screen.cells[0][0].character), "\u{AC00}")
        XCTAssertEqual(String(interpreter.screen.cells[0][2].character), "\u{11A8}")
    }

    /// A leading jamo begins a new syllable rather than extending the previous
    /// one, so two decomposed syllables in a row stay two cells.
    func testConsecutiveDecomposedSyllablesStayTwoCells() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1100}\u{1161}")
        interpreter.interpret("\u{1102}\u{1161}")

        XCTAssertEqual(scalarSignature(0, of: interpreter)[0], [0xAC00])
        XCTAssertEqual(scalarSignature(0, of: interpreter)[2], [0xB098])
        XCTAssertEqual(interpreter.cursorColumn, 4)
    }

    // MARK: - Scrollback serializer

    /// The snapshot has to be in the same form as the screen, or a restored
    /// pane is searchable by a word the live pane is not.
    func testSerializedScrollbackIsPrecomposed() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1100}")
        interpreter.interpret("\u{1161}\u{11A8}")

        let encoded = TerminalScrollbackSnapshotSerializer.encoded(
            row: interpreter.screen.cells[0],
            defaultStyle: .default
        )

        XCTAssertEqual(encoded, Fixture.precomposedGak)
        XCTAssertEqual(Array(encoded.unicodeScalars).count, 1)
    }

    /// Replaying a snapshot must land on the grid it was taken from.
    func testSerializedScrollbackReplaysIntoTheSameGrid() {
        let source = makeInterpreter()
        source.interpret(Fixture.decomposedFileName)

        let encoded = TerminalScrollbackSnapshotSerializer.encoded(
            row: source.screen.cells[0],
            defaultStyle: .default
        )
        let replayed = makeInterpreter()
        replayed.interpret(encoded)

        XCTAssertEqual(scalarSignature(0, of: replayed), scalarSignature(0, of: source))
        XCTAssertEqual(replayed.screen.cells[0], source.screen.cells[0])
    }

    // MARK: - Search

    private func searchRow(_ interpreter: TerminalOutputInterpreter) -> [[TerminalScreenCell]] {
        [interpreter.screen.cells[0]]
    }

    func testDecomposedQueryFindsDecomposedOutput() {
        let interpreter = makeInterpreter()
        interpreter.interpret(Fixture.decomposedFileName)

        // A name pasted from Finder arrives decomposed, exactly like the output.
        let matches = TerminalSearchMatcher.findAll(
            query: "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}",
            in: searchRow(interpreter)
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.startColumn, 0)
        XCTAssertEqual(matches.first?.endColumn, 4)
    }

    func testPrecomposedQueryFindsDecomposedOutput() {
        let interpreter = makeInterpreter()
        interpreter.interpret(Fixture.decomposedFileName)

        let matches = TerminalSearchMatcher.findAll(query: "한글", in: searchRow(interpreter))

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.startColumn, 0)
    }

    /// The regular-expression path compares scalars and has no canonical
    /// equivalence to fall back on, so it is the one that silently found
    /// nothing before the query was normalized.
    func testDecomposedRegularExpressionQueryFindsDecomposedOutput() {
        let interpreter = makeInterpreter()
        interpreter.interpret(Fixture.decomposedFileName)

        let matches = TerminalSearchMatcher.findAll(
            query: "\u{1112}\u{1161}\u{11AB}.*\\.txt",
            options: TerminalSearchOptions(isCaseSensitive: false, usesRegularExpression: true),
            in: searchRow(interpreter)
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.startColumn, 0)
    }
}
