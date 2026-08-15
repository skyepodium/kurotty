import XCTest
@testable import KurottyApp
@testable import KurottyCore

final class TerminalVisibleLinkCacheTests: XCTestCase {
    private func row(_ text: String, wraps: Bool = false, linkURL: String? = nil) -> [TerminalScreenCell] {
        var cells = text.map { TerminalScreenCell(character: $0, linkURL: linkURL) }
        if wraps, !cells.isEmpty {
            cells[cells.count - 1].wrapsToNextRow = true
        }
        return cells
    }

    private func range(row rowIndex: Int = 0) -> TerminalLinkRange {
        TerminalLinkRange(row: rowIndex, startColumn: 0, endColumn: 4, urlString: "https://a.example")
    }

    @MainActor
    func testSameLineIsDetectedOnceAcrossFrames() {
        let cache = TerminalVisibleLinkCache()
        let key = TerminalVisibleLinkCache.Key(rows: [row("https://a.example")], workingDirectory: "/tmp")
        var detectionCount = 0

        cache.beginFrame()
        let first = cache.ranges(for: key) {
            detectionCount += 1
            return [range()]
        }
        cache.beginFrame()
        let second = cache.ranges(for: key) {
            detectionCount += 1
            return [range()]
        }

        XCTAssertEqual(detectionCount, 1)
        XCTAssertEqual(first, second)
    }

    @MainActor
    func testChangedTextChangedLinkMetadataOrChangedDirectoryMissTheCache() {
        let plain = TerminalVisibleLinkCache.Key(rows: [row("cat notes")], workingDirectory: "/tmp")
        let editedText = TerminalVisibleLinkCache.Key(rows: [row("cat note")], workingDirectory: "/tmp")
        let explicitLink = TerminalVisibleLinkCache.Key(
            rows: [row("cat notes", linkURL: "https://b.example")],
            workingDirectory: "/tmp"
        )
        let otherDirectory = TerminalVisibleLinkCache.Key(rows: [row("cat notes")], workingDirectory: "/srv")
        // Same text split across a different wrap boundary maps to different
        // cell ranges and must not reuse the other layout's result.
        let rewrapped = TerminalVisibleLinkCache.Key(
            rows: [row("cat n", wraps: true), row("otes")],
            workingDirectory: "/tmp"
        )

        XCTAssertNotEqual(plain, editedText)
        XCTAssertNotEqual(plain, explicitLink)
        XCTAssertNotEqual(plain, otherDirectory)
        XCTAssertNotEqual(plain, rewrapped)
    }

    @MainActor
    func testLinesUnusedForTwoFramesAreReleased() {
        let cache = TerminalVisibleLinkCache()
        let key = TerminalVisibleLinkCache.Key(rows: [row("https://a.example")], workingDirectory: nil)
        var detectionCount = 0

        cache.beginFrame()
        _ = cache.ranges(for: key) {
            detectionCount += 1
            return [range()]
        }
        XCTAssertEqual(cache.retainedLineCount, 1)

        // Two frames that never reference the line retire both generations.
        cache.beginFrame()
        cache.beginFrame()
        XCTAssertEqual(cache.retainedLineCount, 0)

        _ = cache.ranges(for: key) {
            detectionCount += 1
            return [range()]
        }
        XCTAssertEqual(detectionCount, 2)
    }

    @MainActor
    func testRemoveAllForcesRedetection() {
        let cache = TerminalVisibleLinkCache()
        let key = TerminalVisibleLinkCache.Key(rows: [row("src/main.zig:10:4")], workingDirectory: "/repo")
        var detectionCount = 0

        cache.beginFrame()
        _ = cache.ranges(for: key) {
            detectionCount += 1
            return []
        }
        cache.removeAll()
        _ = cache.ranges(for: key) {
            detectionCount += 1
            return [range()]
        }

        XCTAssertEqual(detectionCount, 2, "a probe answer landing must invalidate memoized results")
    }

    func testShiftedByRowsRebasesOnlyTheRow() {
        let fileTarget = TerminalFileLinkTarget(
            absolutePath: "/repo/src/main.zig",
            line: 10,
            column: 4
        )
        let original = TerminalLinkRange(
            row: 1,
            startColumn: 3,
            endColumn: 9,
            urlString: "file:///repo/src/main.zig",
            fileTarget: fileTarget,
            provenance: .oscHyperlink,
            displayText: "main.zig"
        )

        let shifted = original.shifted(byRows: 7)

        XCTAssertEqual(shifted.row, 8)
        XCTAssertEqual(shifted.startColumn, original.startColumn)
        XCTAssertEqual(shifted.endColumn, original.endColumn)
        XCTAssertEqual(shifted.urlString, original.urlString)
        XCTAssertEqual(shifted.fileTarget, original.fileTarget)
        XCTAssertEqual(shifted.provenance, original.provenance)
        XCTAssertEqual(shifted.displayText, original.displayText)
    }
}
