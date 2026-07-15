import XCTest
@testable import KurottyApp
@testable import KurottyCore

final class TerminalLinkRangeTests: XCTestCase {
    func testPlainHTTPLinksRemainDetectedAndTrimTrailingPunctuation() {
        let row = cells("Open https://x.ai/grok).")

        let ranges = TerminalLinkRange.findAll(in: row, row: 3)

        XCTAssertEqual(ranges, [
            TerminalLinkRange(row: 3, startColumn: 5, endColumn: 22, urlString: "https://x.ai/grok"),
        ])
    }

    func testLocalFileURLsAreDetectedAndTrimTrailingPunctuation() {
        let fileURL = "file:///Users/skye/Project%20One/README.md"
        let row = cells("Open \(fileURL).")

        let ranges = TerminalLinkRange.findAll(in: row, row: 2)

        XCTAssertEqual(ranges, [
            TerminalLinkRange(
                row: 2,
                startColumn: 5,
                endColumn: 5 + fileURL.count,
                urlString: fileURL
            ),
        ])
    }

    func testLocalhostFileURLsAreDetectedCaseInsensitively() {
        let fileURL = "file://LOCALHOST/tmp/report.txt"
        let row = cells(fileURL)

        XCTAssertEqual(TerminalLinkRange.findAll(in: row, row: 0), [
            TerminalLinkRange(
                row: 0,
                startColumn: 0,
                endColumn: fileURL.count,
                urlString: fileURL
            ),
        ])
    }

    func testWrappedHTTPSLinkUsesCompleteURLOnEveryPhysicalRow() {
        let firstPart = "https://developers.openai."
        let secondPart = "com/mcp"
        let rows = wrappedRows(firstPart, secondPart)

        XCTAssertEqual(TerminalLinkRange.findAll(in: rows, startingRow: 4), [
            TerminalLinkRange(
                row: 4,
                startColumn: 0,
                endColumn: firstPart.count,
                urlString: firstPart + secondPart
            ),
            TerminalLinkRange(
                row: 5,
                startColumn: 0,
                endColumn: secondPart.count,
                urlString: firstPart + secondPart
            ),
        ])
    }

    func testWrappedLocalFileLinkUsesCompleteURLOnEveryPhysicalRow() {
        let firstPart = "file:///Users/skye/Project%20"
        let secondPart = "One/README.md"
        let rows = wrappedRows(firstPart, secondPart)

        let ranges = TerminalLinkRange.findAll(in: rows, startingRow: 0)

        XCTAssertEqual(ranges.map(\.urlString), Array(repeating: firstPart + secondPart, count: 2))
        XCTAssertEqual(ranges.map(\.row), [0, 1])
    }

    func testHardLineBreakDoesNotJoinAdjacentURLText() {
        let firstRow = cells("https://example.com/")
        let secondRow = cells("admin")

        XCTAssertEqual(TerminalLinkRange.findAll(in: [firstRow, secondRow], startingRow: 0), [
            TerminalLinkRange(
                row: 0,
                startColumn: 0,
                endColumn: firstRow.count,
                urlString: "https://example.com/"
            ),
        ])
    }

    func testWrappedDisallowedSchemesRemainInactive() {
        let sshRows = wrappedRows("ssh://example.com/", "repo")
        let remoteFileRows = wrappedRows("file://server/share/", "report.txt")

        XCTAssertTrue(TerminalLinkRange.findAll(in: sshRows, startingRow: 0).isEmpty)
        XCTAssertTrue(TerminalLinkRange.findAll(in: remoteFileRows, startingRow: 0).isEmpty)
    }

    func testAutomaticLinksRespectURLSecurityPolicy() {
        let row = cells("ssh://example.com/repo file://server/share/report.txt")

        XCTAssertTrue(TerminalLinkRange.findAll(in: row, row: 0).isEmpty)
    }

    func testOSC8HyperlinkCellsCreateClickableRangeForVisibleLabel() {
        let row = cells("Ask Grok", linkURL: "https://x.ai/grok")

        let ranges = TerminalLinkRange.findAll(in: row, row: 0)

        XCTAssertEqual(ranges, [
            TerminalLinkRange(row: 0, startColumn: 0, endColumn: 8, urlString: "https://x.ai/grok"),
        ])
        XCTAssertEqual(TerminalLinkRange.find(in: row, row: 0, column: 4)?.urlString, "https://x.ai/grok")
    }

    func testScreenStoresHyperlinkMetadataForWideCellsAndRepeats() {
        var screen = TerminalScreen(rows: 1, columns: 4)

        screen.set(character: "界", row: 0, column: 0, width: 2, linkURL: "https://x.ai/grok")
        screen.set(character: "x", row: 0, column: 2, width: 1, linkURL: "https://x.ai/grok")
        let repeated = screen.repeatPrecedingGraphicCharacter(row: 0, column: 3, count: 1)

        XCTAssertEqual(repeated, 1)
        XCTAssertEqual(screen.cells[0][0].linkURL, "https://x.ai/grok")
        XCTAssertEqual(screen.cells[0][1].linkURL, "https://x.ai/grok")
        XCTAssertTrue(screen.cells[0][1].isContinuation)
        XCTAssertEqual(screen.cells[0][3].linkURL, "https://x.ai/grok")
    }

    func testExplicitHyperlinkTakesPrecedenceOverVisibleURLText() {
        let row = cells("https://visible.example", linkURL: "https://target.example")

        let ranges = TerminalLinkRange.findAll(in: row, row: 1)

        XCTAssertEqual(ranges, [
            TerminalLinkRange(row: 1, startColumn: 0, endColumn: 23, urlString: "https://target.example"),
        ])
    }

    func testOSC8PayloadParsingActivatesClearsOrIgnoresHyperlink() {
        XCTAssertEqual(
            TerminalHyperlinkControl.update(fromOSC8Payload: "id=123;https://x.ai/grok"),
            .activate("https://x.ai/grok")
        )
        XCTAssertEqual(TerminalHyperlinkControl.update(fromOSC8Payload: ";"), .clear)
        XCTAssertEqual(TerminalHyperlinkControl.update(fromOSC8Payload: "missing-uri"), .ignore)
    }

    private func cells(_ text: String, linkURL: String? = nil) -> [TerminalScreenCell] {
        text.map { character in
            TerminalScreenCell(character: character, linkURL: linkURL)
        }
    }

    private func wrappedRows(_ first: String, _ second: String) -> [[TerminalScreenCell]] {
        var firstRow = cells(first)
        firstRow[firstRow.count - 1].wrapsToNextRow = true
        return [firstRow, cells(second)]
    }
}
