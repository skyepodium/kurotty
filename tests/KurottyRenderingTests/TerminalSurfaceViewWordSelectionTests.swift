import AppKit
import KurottyCore
import XCTest
@testable import KurottyApp

/// Double-click word selection, addressed the way the gesture addresses it.
///
/// `mouseDown` resolves a click to a *content-absolute* row — scrollback plus
/// screen — before handing it to word selection. A viewport slice indexed with
/// that row agrees only while nothing has scrolled off; afterwards a double
/// click selected the wrong word, or ran past the slice and cleared the
/// selection so `Cmd+C` copied nothing.
final class TerminalSurfaceViewWordSelectionTests: XCTestCase {
    private final class StubSession: TerminalSession {
        var onOutput: ((String) -> Void)?
        var onRawOutput: ((Data) -> Void)?
        var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
        var onExit: ((TerminalChildExit) -> Void)?

        func start(workingDirectory: String) {}
        func write(_ text: String) {}
        func foregroundProcessName() -> String? { "zsh" }
        func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    private enum Fixture {
        static let surfaceFrame = NSRect(x: 0, y: 0, width: 500, height: 120)
        static let gridColumnCOUNT = 30
        static let gridRowCOUNT = 8
        static let overflowingLineCOUNT = 40
        static let pasteboardSentinelText = "pasteboard-sentinel"
        /// A column inside `bbbb` on `aaaa bbbb cccc`.
        static let columnInsideSecondWord = 6
        static let secondWord = "bbbb"
    }

    private var savedPasteboardText: String?

    override func setUp() {
        super.setUp()
        savedPasteboardText = NSPasteboard.general.string(forType: .string)
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        if let savedPasteboardText {
            NSPasteboard.general.setString(savedPasteboardText, forType: .string)
        }
        super.tearDown()
    }

    @MainActor
    private func makeSurfaceWithScrollback() -> TerminalSurfaceView {
        let surface = TerminalSurfaceView(frame: Fixture.surfaceFrame, session: StubSession())
        surface.resizeGridForTesting(columns: Fixture.gridColumnCOUNT, rows: Fixture.gridRowCOUNT)
        let output = (0..<Fixture.overflowingLineCOUNT)
            .map { _ in "aaaa bbbb cccc" }
            .joined(separator: "\r\n")
        surface.consumeTmuxRestoreOutputForTesting(Data(output.utf8))
        return surface
    }

    @MainActor
    func testDoubleClickSelectsTheWordAfterContentHasScrolledIntoScrollback() {
        let surface = makeSurfaceWithScrollback()
        let totalRows = surface.contentRowCountForTesting
        XCTAssertGreaterThan(
            totalRows,
            Fixture.gridRowCOUNT,
            "fixture must overflow the visible screen into scrollback"
        )

        // A row deep inside scrollback, addressed the way a click addresses it.
        let position = TerminalCellPosition(
            row: totalRows - Fixture.gridRowCOUNT,
            column: Fixture.columnInsideSecondWord
        )
        surface.selectWordForTesting(at: position)

        let selection = surface.selectionForTesting
        XCTAssertEqual(selection.anchor?.row, position.row)
        XCTAssertEqual(selection.focus?.row, position.row)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Fixture.pasteboardSentinelText, forType: .string)
        surface.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), Fixture.secondWord)
    }

    @MainActor
    func testDoubleClickPastTheEndOfTheContentBufferClearsTheSelection() {
        let surface = makeSurfaceWithScrollback()
        surface.setSelectionForTesting(
            anchor: TerminalCellPosition(row: 0, column: 0),
            focus: TerminalCellPosition(row: 0, column: 3)
        )

        surface.selectWordForTesting(at: TerminalCellPosition(
            row: surface.contentRowCountForTesting,
            column: 0
        ))

        XCTAssertNil(surface.selectionForTesting.anchor)
        XCTAssertNil(surface.selectionForTesting.focus)
    }
}
