import AppKit
import XCTest
@testable import KurottyCore
@testable import KurottyApp

/// What happens to the viewport while the user is reading scrollback and the
/// shell keeps writing.
///
/// These replace source-text assertions in `GlyphRenderingRegressionTests` that
/// matched statements like `"let shouldFollowOutput = scrollbackOffset == 0"`.
/// The statement being present proved nothing about whether a page of output
/// yanks the reader back to the prompt, which is the bug they were written for.
@MainActor
final class TerminalSurfaceScrollbackFollowTests: XCTestCase {
    private enum Fixture {
        static let frame = NSRect(x: 0, y: 0, width: 500, height: 120)
        static let filler = (0..<60).map { "row \($0)" }.joined(separator: "\r\n")
        /// The live output path coalesces on the main queue before rendering.
        static let outputFlushSeconds: TimeInterval = 0.12
    }

    private func makeSurface() -> (TerminalSurfaceView, StubSession) {
        let session = StubSession()
        let surface = TerminalSurfaceView(frame: Fixture.frame, session: session)
        surface.consumeTmuxRestoreOutputForTesting(Data(Fixture.filler.utf8))
        return (surface, session)
    }

    private func emit(_ text: String, from session: StubSession) {
        session.onOutput?(text)
        RunLoop.current.run(until: Date().addingTimeInterval(Fixture.outputFlushSeconds))
    }

    private func scrollUp(_ surface: TerminalSurfaceView, rows: Int) throws {
        for _ in 0..<rows {
            surface.scrollWheel(with: try discreteScrollEvent(deltaY: 1))
        }
    }

    /// The regression: any output at all reset the offset to zero, so reading
    /// scrollback under a running build was impossible.
    func testOutputArrivingWhileReadingScrollbackDoesNotSnapBackToThePrompt() throws {
        let (surface, session) = makeSurface()
        try scrollUp(surface, rows: 3)
        let offsetWhileReading = surface.searchStateForTesting.scrollbackOffset
        XCTAssertGreaterThan(offsetWhileReading, 0)

        emit("new line one\r\nnew line two\r\n", from: session)

        XCTAssertGreaterThan(
            surface.searchStateForTesting.scrollbackOffset,
            0,
            "output must not drag the reader back to the live cursor"
        )
    }

    /// The other half of the same contract: the offset grows by however many
    /// rows scrolled off, so the rows the user was looking at stay put.
    func testTheReadersRowsStayInPlaceAsNewOutputPushesThemUp() throws {
        let (surface, session) = makeSurface()
        try scrollUp(surface, rows: 4)
        let before = surface.searchStateForTesting.scrollbackOffset

        emit((0..<3).map { "pushed \($0)" }.joined(separator: "\r\n") + "\r\n", from: session)

        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, before + 3)
    }

    /// A surface already at the live cursor keeps following.
    func testOutputStillFollowsWhenTheUserIsAtTheLiveCursor() {
        let (surface, session) = makeSurface()
        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, 0)

        emit("more output\r\n", from: session)

        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, 0)
    }

    /// Typing means the user wants the prompt, so the viewport returns to it.
    func testTypingReturnsTheViewportToTheLiveCursor() throws {
        let (surface, _) = makeSurface()
        try scrollUp(surface, rows: 3)
        XCTAssertGreaterThan(surface.searchStateForTesting.scrollbackOffset, 0)

        surface.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, 0)
    }

    /// Starting an IME composition is the same intent as typing, and the
    /// composition has to be visible while it is being composed.
    func testStartingAnIMECompositionReturnsTheViewportToTheLiveCursor() throws {
        let (surface, _) = makeSurface()
        try scrollUp(surface, rows: 3)
        XCTAssertGreaterThan(surface.searchStateForTesting.scrollbackOffset, 0)

        surface.setMarkedText(
            "하",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, 0)
    }

    /// The offset is clamped to the content that exists; scrolling past the top
    /// of scrollback must not leave the viewport addressing rows that are gone.
    func testScrollingPastTheTopClampsToTheOldestRetainedRow() throws {
        let (surface, _) = makeSurface()

        try scrollUp(surface, rows: 500)
        let clamped = surface.searchStateForTesting.scrollbackOffset

        XCTAssertGreaterThan(clamped, 0)
        XCTAssertLessThanOrEqual(clamped, surface.contentRowCountForTesting)
    }

    /// Selection is anchored to content rows, not to screen rows. Scrolling used
    /// to leave the highlight behind on whatever now occupied those screen rows.
    func testSelectionStaysOnItsContentRowsWhileScrolling() throws {
        let (surface, _) = makeSurface()
        let anchor = TerminalCellPosition(row: 5, column: 0)
        let focus = TerminalCellPosition(row: 5, column: 4)
        surface.setSelectionForTesting(anchor: anchor, focus: focus)

        try scrollUp(surface, rows: 4)

        XCTAssertEqual(surface.selectionForTesting.anchor, anchor)
        XCTAssertEqual(surface.selectionForTesting.focus, focus)
    }

    private func discreteScrollEvent(deltaY: CGFloat) throws -> NSEvent {
        try XCTUnwrap(
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(deltaY), wheel2: 0, wheel3: 0)
                .flatMap(NSEvent.init(cgEvent:))
        )
    }
}

private final class StubSession: TerminalSession {
    var onOutput: ((String) -> Void)?
    var onRawOutput: ((Data) -> Void)?
    var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
    var onExit: ((TerminalChildExit) -> Void)?
    private(set) var writes: [String] = []

    func start(workingDirectory: String) {}
    func write(_ text: String) { writes.append(text) }
    func foregroundProcessName() -> String? { nil }
    func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
    func resize(columns: Int, rows: Int) {}
    func stop() {}
}
