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
    }

    private func makeSurface() -> (TerminalSurfaceView, StubSession) {
        let session = StubSession()
        let surface = TerminalSurfaceView(frame: Fixture.frame, session: session)
        surface.consumeTmuxRestoreOutputForTesting(Data(Fixture.filler.utf8))
        return (surface, session)
    }

    private func emit(_ text: String, from session: StubSession, surface: TerminalSurfaceView) {
        session.onOutput?(text)
        surface.flushPendingOutputForTesting()
        XCTAssertFalse(surface.hasPendingOutputForTesting, "test output drain left pending data")
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

        emit("new line one\r\nnew line two\r\n", from: session, surface: surface)

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

        emit(
            (0..<3).map { "pushed \($0)" }.joined(separator: "\r\n") + "\r\n",
            from: session,
            surface: surface
        )

        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, before + 3)
    }

    /// A surface already at the live cursor keeps following.
    func testOutputStillFollowsWhenTheUserIsAtTheLiveCursor() {
        let (surface, session) = makeSurface()
        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, 0)

        emit("more output\r\n", from: session, surface: surface)

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

    /// A drag near the viewport edge scrolls the viewport, but the selection
    /// endpoints are already content-absolute. Rewriting the anchor with the
    /// viewport delta teleports it toward row zero and makes the highlight
    /// appear to slide across most of the screen.
    func testSelectionAnchorStaysOnItsContentRowDuringDragAutoscroll() throws {
        let (surface, _) = makeSurface()
        try scrollUp(surface, rows: 4)
        let offsetBeforeDrag = surface.searchStateForTesting.scrollbackOffset
        XCTAssertGreaterThan(offsetBeforeDrag, 0)

        let anchor = TerminalCellPosition(row: 40, column: 3)
        surface.setSelectionForTesting(
            anchor: anchor,
            focus: TerminalCellPosition(row: 41, column: 7)
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 20, y: 0),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        surface.autoscrollSelectionForTesting(with: event)

        XCTAssertLessThan(surface.searchStateForTesting.scrollbackOffset, offsetBeforeDrag)
        XCTAssertEqual(surface.selectionForTesting.anchor, anchor)
    }

    /// The first and last visible text rows are still part of the viewport.
    /// Merely dragging through them must not repeatedly scroll the content out
    /// from under the pointer; autoscroll starts only beyond the content edge.
    func testDraggingInsideBottomVisibleRowDoesNotAutoscroll() throws {
        let (surface, _) = makeSurface()
        try scrollUp(surface, rows: 4)
        let offsetBeforeDrag = surface.searchStateForTesting.scrollbackOffset
        XCTAssertGreaterThan(offsetBeforeDrag, 0)

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 20, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        surface.autoscrollSelectionForTesting(with: event)

        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, offsetBeforeDrag)
    }

    func testDraggingInsideTopVisibleRowDoesNotAutoscroll() throws {
        let (surface, _) = makeSurface()
        try scrollUp(surface, rows: 4)
        let offsetBeforeDrag = surface.searchStateForTesting.scrollbackOffset

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 20, y: Fixture.frame.height - 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        surface.autoscrollSelectionForTesting(with: event)

        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, offsetBeforeDrag)
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
