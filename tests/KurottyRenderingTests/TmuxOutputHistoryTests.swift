import Foundation
import XCTest
@testable import KurottyApp

final class TmuxOutputHistoryTests: XCTestCase {
    func testViewerBoundsEachPaneHistoryIndependently() {
        var state = TmuxViewerState(paneOutputHistoryByteLimit: 5)

        state.apply(.output(paneID: "%1", data: Data("abc".utf8)))
        state.apply(.output(paneID: "%2", data: Data("123456".utf8)))
        state.apply(.output(paneID: "%1", data: Data("defg".utf8)))

        XCTAssertEqual(state.panes["%1"]?.output, Data("cdefg".utf8))
        XCTAssertEqual(state.panes["%1"]?.outputHistoryStartOffset, 2)
        XCTAssertEqual(state.panes["%1"]?.outputHistoryEndOffset, 7)
        XCTAssertEqual(state.panes["%2"]?.output, Data("23456".utf8))
        XCTAssertEqual(state.panes["%2"]?.outputHistoryStartOffset, 1)
        XCTAssertEqual(state.panes["%2"]?.outputHistoryEndOffset, 6)
    }

    func testReplayUsesAbsoluteOffsetsAndDetectsStaleOrInvalidCursors() throws {
        var state = TmuxViewerState(paneOutputHistoryByteLimit: 5)
        state.apply(.output(paneID: "%1", data: Data("abcdefg".utf8)))
        let pane = try XCTUnwrap(state.panes["%1"])

        XCTAssertEqual(
            pane.replayOutput(),
            TmuxPaneOutputReplay(
                data: Data("cdefg".utf8),
                startOffset: 2,
                nextOffset: 7,
                requiresFullReplay: false
            )
        )
        XCTAssertEqual(
            pane.replayOutput(after: 4),
            TmuxPaneOutputReplay(
                data: Data("efg".utf8),
                startOffset: 4,
                nextOffset: 7,
                requiresFullReplay: false
            )
        )

        for invalidCursor in [UInt64(1), UInt64(99)] {
            XCTAssertEqual(
                pane.replayOutput(after: invalidCursor),
                TmuxPaneOutputReplay(
                    data: Data("cdefg".utf8),
                    startOffset: 2,
                    nextOffset: 7,
                    requiresFullReplay: true
                )
            )
        }

        XCTAssertEqual(
            pane.replayOutput(after: 7),
            TmuxPaneOutputReplay(
                data: Data(),
                startOffset: 7,
                nextOffset: 7,
                requiresFullReplay: false
            )
        )
    }

    func testZeroByteHistoryStillAdvancesItsReplayCursor() throws {
        var state = TmuxViewerState(paneOutputHistoryByteLimit: 0)
        state.apply(.output(paneID: "%1", data: Data("discarded".utf8)))
        let pane = try XCTUnwrap(state.panes["%1"])

        XCTAssertTrue(pane.output.isEmpty)
        XCTAssertEqual(pane.outputHistoryStartOffset, 9)
        XCTAssertEqual(pane.outputHistoryEndOffset, 9)
        XCTAssertEqual(pane.replayOutput().nextOffset, 9)
        XCTAssertTrue(pane.replayOutput(after: 0).requiresFullReplay)
    }

    func testTinyAppendsAreCompactedIntoBoundedChunkMetadata() {
        var history = TmuxBoundedOutputHistory(byteLimit: 4_096)
        for index in 0..<100_000 {
            history.append(Data([UInt8(truncatingIfNeeded: index)]))
        }

        XCTAssertEqual(history.data.count, 4_096)
        XCTAssertLessThanOrEqual(history.storageChunkCount, 2)
        XCTAssertEqual(history.startOffset, 95_904)
        XCTAssertEqual(history.endOffset, 100_000)
    }

    func testSingleLargeAppendRetainsOnlyBoundedChunkAllocations() {
        var history = TmuxBoundedOutputHistory(byteLimit: 40_000)
        let input = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0) })
        history.append(input)

        XCTAssertEqual(history.data, input.suffix(40_000))
        XCTAssertLessThanOrEqual(history.storageChunkCount, 3)
        XCTAssertEqual(history.startOffset, 960_000)
        XCTAssertEqual(history.endOffset, 1_000_000)
    }

    func testPaneSessionReplaysBoundedOutputReceivedBeforeCallbackInstallation() {
        let session = makeSession(pendingOutputByteLimit: 5)
        session.receive("abc")
        session.receive("defg")

        let replayed = expectation(description: "pending tmux output replayed")
        session.onOutput = { output in
            XCTAssertEqual(output, "cdefg")
            replayed.fulfill()
        }

        wait(for: [replayed], timeout: 1)
    }

    func testPaneSessionCombinesSplitUTF8BytesAcrossSeparateOutputDrains() {
        let session = makeSession(pendingOutputByteLimit: 16)
        var outputs: [String] = []
        let replayed = expectation(description: "split UTF-8 output replayed")
        session.onOutput = { output in
            outputs.append(output)
            if output == "😀" { replayed.fulfill() }
        }

        session.receive(Data([0xf0, 0x9f]))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            session.receive(Data([0x98, 0x80]))
        }

        wait(for: [replayed], timeout: 1)
        XCTAssertEqual(outputs, ["😀"])
    }

    @MainActor
    func testManagedTmuxPaneTitleIsNotOverwrittenByPaneOSCNotification() {
        let pane = TerminalPaneView(
            frame: .init(x: 0, y: 0, width: 400, height: 300),
            session: makeSession(pendingOutputByteLimit: 1_024)
        )
        pane.setTmuxDisplayTitle("tmux editor")

        NotificationCenter.default.post(
            name: TerminalSurfaceView.titleDidChangeNotification,
            object: pane.terminalSurface,
            userInfo: [TerminalSurfaceView.titleNotificationKey: "OSC process title"]
        )

        XCTAssertEqual(pane.displayTitle, "tmux editor")
    }

    private func makeSession(pendingOutputByteLimit: Int) -> TmuxPaneSession {
        TmuxPaneSession(
            writeHandler: { _ in },
            resizeHandler: { _, _ in },
            stopHandler: {},
            pendingOutputByteLimit: pendingOutputByteLimit
        )
    }
}
