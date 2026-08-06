import XCTest
@testable import KurottyApp

/// Regression coverage for the command-history garbage seen in the sidebar:
/// arrow keys, bracketed-paste guards, and other escape payloads were being
/// recorded as if the user had typed their literal bytes.
final class TerminalSubmittedCommandRecorderTests: XCTestCase {
    private func submit(_ chunks: String...) -> [String] {
        var recorder = TerminalSubmittedCommandRecorder()
        return chunks.flatMap { recorder.consume($0) }
    }

    // MARK: - The reported failures

    func testArrowKeysAloneRecordNothing() {
        // `ESC [ A` produced a history entry literally named "[A".
        XCTAssertEqual(submit("\u{1b}[A\u{1b}[B\u{1b}[C\u{1b}[D\r"), [])
    }

    func testApplicationCursorArrowsAloneRecordNothing() {
        // `ESC O A` produced "OA".
        XCTAssertEqual(submit("\u{1b}OA\u{1b}OB\r"), [])
    }

    func testArrowKeysInTheMiddleOfAWordDoNotSplice() {
        // This is the `ssOAOBh-real` case: up/down pressed mid-line.
        XCTAssertEqual(submit("ss\u{1b}OA\u{1b}OBh-real\r"), ["ssh-real"])
    }

    func testArrowKeyAfterAPathDoesNotAppend() {
        // The `cd fOA` case.
        XCTAssertEqual(submit("cd f\u{1b}OA\r"), ["cd f"])
    }

    func testBracketedPasteGuardsAreStrippedAndContentKept() {
        let pasted = "\u{1b}[200~curl -X POST 'https://example.com?d=2026-08-04'\u{1b}[201~\r"
        XCTAssertEqual(submit(pasted), ["curl -X POST 'https://example.com?d=2026-08-04'"])
    }

    func testNewlinesInsideABracketedPasteDoNotSubmitEarly() {
        // The shell buffers a multi-line paste until a real Enter arrives, so
        // one paste must not become three history entries. The summariser then
        // flattens the newline, because both the notification body and the
        // history row are single-line surfaces.
        let result = submit("\u{1b}[200~echo one\necho two\u{1b}[201~", "\r")
        XCTAssertEqual(result, ["echo one echo two"])
    }

    // MARK: - Escape families that must be swallowed whole

    func testParameterisedCSISequencesAreSwallowed() {
        // Modified arrows, Home/End/Delete, and cursor position reports.
        XCTAssertEqual(submit("git\u{1b}[1;5C\u{1b}[3~\u{1b}[H status\r"), ["git status"])
    }

    func testOSCRepliesTerminatedByBellAreSwallowed() {
        XCTAssertEqual(submit("ls\u{1b}]11;rgb:0000/0000/0000\u{07} -la\r"), ["ls -la"])
    }

    func testOSCRepliesTerminatedByStringTerminatorAreSwallowed() {
        XCTAssertEqual(submit("ls\u{1b}]7;file://localhost/tmp\u{1b}\\ -la\r"), ["ls -la"])
    }

    func testTwoByteEscapesAreSwallowed() {
        // Alt-B and friends: `ESC b` must not contribute a `b`.
        XCTAssertEqual(submit("make\u{1b}b\u{1b}f test\r"), ["make test"])
    }

    // MARK: - Line editing

    func testBackspaceAndControlUEditTheBuffer() {
        XCTAssertEqual(submit("lss\u{7f}\r"), ["ls"])
        XCTAssertEqual(submit("garbage\u{15}ls\r"), ["ls"])
    }

    func testControlCAbandonsTheLineInsteadOfMergingIt() {
        // Without this the abandoned text prefixed the next command, which is
        // the most likely source of entries like "ybrew outdated".
        XCTAssertEqual(submit("y\u{03}brew outdated\r"), ["brew outdated"])
    }

    func testControlWDeletesTheTrailingWord() {
        XCTAssertEqual(submit("git commit\u{17}status\r"), ["git status"])
    }

    // MARK: - Ordinary behaviour

    func testMultipleCommandsInOneChunkAreReturnedInOrder() {
        XCTAssertEqual(submit("ls\rpwd\r"), ["ls", "pwd"])
    }

    func testBlankSubmissionsAreIgnored() {
        XCTAssertEqual(submit("\r\r   \r"), [])
    }

    func testResetDropsTheInProgressLine() {
        var recorder = TerminalSubmittedCommandRecorder()
        _ = recorder.consume("half-typed")
        recorder.reset()
        XCTAssertEqual(recorder.consume(" ls\r"), ["ls"])
    }

    func testPendingTextIsBoundedByTheCaptureLimit() {
        let limit = 16
        var recorder = TerminalSubmittedCommandRecorder(maximumCharacters: limit)
        _ = recorder.consume(String(repeating: "a", count: limit * 3))
        XCTAssertEqual(recorder.pendingCommandText.count, limit)
    }
}
