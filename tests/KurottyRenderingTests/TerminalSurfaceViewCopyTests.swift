import AppKit
import KurottyCore
import XCTest
@testable import KurottyApp

final class TerminalSurfaceViewCopyTests: XCTestCase {
    private final class StubSession: TerminalSession {
        var onOutput: ((String) -> Void)?
        var onRawOutput: ((Data) -> Void)?
        var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
        var onExit: ((Int32) -> Void)?
        var writes: [String] = []

        func start(workingDirectory: String) {}
        func write(_ text: String) { writes.append(text) }
        func foregroundProcessName() -> String? { "zsh" }
        func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    private enum Fixture {
        static let surfaceFrame = NSRect(x: 0, y: 0, width: 500, height: 120)
        static let pasteboardSentinelText = "pasteboard-sentinel"
        static let helloBase64Payload = "aGVsbG8="
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
    private func makeSurface(output: String) -> TerminalSurfaceView {
        let surface = TerminalSurfaceView(frame: Fixture.surfaceFrame, session: StubSession())
        surface.consumeTmuxRestoreOutputForTesting(Data(output.utf8))
        return surface
    }

    private func setPasteboardSentinel() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Fixture.pasteboardSentinelText, forType: .string)
    }

    @MainActor
    func testCopyWithoutSelectionLeavesPasteboardUntouched() {
        let surface = makeSurface(output: "hello world\r\nsecond line")
        setPasteboardSentinel()

        surface.copy(nil)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            Fixture.pasteboardSentinelText
        )
    }

    @MainActor
    func testCopyWithSelectionCopiesOnlySelectedCells() {
        let surface = makeSurface(output: "hello world\r\nsecond line")
        surface.setSelectionForTesting(
            anchor: TerminalCellPosition(row: 0, column: 0),
            focus: TerminalCellPosition(row: 0, column: 4)
        )

        surface.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")
    }

    @MainActor
    func testCopyWideCharacterSelectionDoesNotInjectContinuationSpaces() {
        let surface = makeSurface(output: "고등학교")
        surface.setSelectionForTesting(
            anchor: TerminalCellPosition(row: 0, column: 0),
            focus: TerminalCellPosition(row: 0, column: 7)
        )

        surface.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "고등학교")
    }

    @MainActor
    func testSelectionSurvivesSynthesizedTerminalResponse() {
        let surface = makeSurface(output: "hello world")
        surface.setSelectionForTesting(
            anchor: TerminalCellPosition(row: 0, column: 0),
            focus: TerminalCellPosition(row: 0, column: 4)
        )

        // A cursor-position query makes the surface write a DSR response to the
        // PTY. Protocol traffic is not user input and must not clear the
        // selection (regression: focus-out reports wiped an active selection).
        surface.consumeTmuxRestoreOutputForTesting(Data("\u{1b}[6n".utf8))

        surface.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")
    }

    @MainActor
    func testOSC52WriteFromShellOutputUpdatesPasteboard() {
        setPasteboardSentinel()

        _ = makeSurface(output: "\u{1b}]52;c;\(Fixture.helloBase64Payload)\u{7}")

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")
    }

    @MainActor
    func testOSC52WriteWithInvalidPayloadLeavesPasteboardUntouched() {
        setPasteboardSentinel()

        _ = makeSurface(output: "\u{1b}]52;c;not-base64!\u{7}")

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            Fixture.pasteboardSentinelText
        )
    }
}
