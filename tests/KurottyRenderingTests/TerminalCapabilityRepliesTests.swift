import XCTest
import KurottyCore
@testable import KurottyApp

/// Exact reply bytes for every capability probe Claude Code and Codex send at
/// startup, plus the replay suppression guard that keeps restored scrollback
/// from re-answering a previous session's queries into the live shell.
@MainActor
final class TerminalCapabilityRepliesTests: XCTestCase {
    private enum Fixture {
        static let columns = 80
        static let rows = 24
        static let cellWidthPX = 8.0
        static let cellHeightPX = 17.0
        static let textAreaWidthPX = 640
        static let textAreaHeightPX = 408
    }

    private func makeMetrics() -> TerminalCapabilityMetrics {
        TerminalCapabilityMetrics(
            columns: Fixture.columns,
            rows: Fixture.rows,
            cellWidthPX: Fixture.cellWidthPX,
            cellHeightPX: Fixture.cellHeightPX
        )
    }

    // MARK: - Pure query classification and reply bytes

    func testDeviceAttributeRepliesUseTheDocumentedBytes() {
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters("")), "\u{1b}[?1;2c")
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters("0")), "\u{1b}[?1;2c")
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters(">")), "\u{1b}[>0;0;0c")
    }

    func testTextAreaSizeInPixelsReply() {
        let query = TerminalCapabilityReplies.query(
            final: "t",
            rawParameters: "14",
            parsed: CsiParameters("14")
        )
        XCTAssertEqual(query, .textAreaSizePixels)
        XCTAssertEqual(
            TerminalCapabilityReplies.reply(
                for: .textAreaSizePixels,
                metrics: makeMetrics(),
                colorSchemeUpdateModeEnabled: false
            ),
            "\u{1b}[4;\(Fixture.textAreaHeightPX);\(Fixture.textAreaWidthPX)t"
        )
    }

    func testCellSizeInPixelsReply() {
        let query = TerminalCapabilityReplies.query(
            final: "t",
            rawParameters: "16",
            parsed: CsiParameters("16")
        )
        XCTAssertEqual(query, .cellSizePixels)
        XCTAssertEqual(
            TerminalCapabilityReplies.reply(
                for: .cellSizePixels,
                metrics: makeMetrics(),
                colorSchemeUpdateModeEnabled: false
            ),
            "\u{1b}[6;17;8t"
        )
    }

    func testTextAreaSizeInCharactersReply() {
        let query = TerminalCapabilityReplies.query(
            final: "t",
            rawParameters: "18",
            parsed: CsiParameters("18")
        )
        XCTAssertEqual(query, .textAreaSizeCharacters)
        XCTAssertEqual(
            TerminalCapabilityReplies.reply(
                for: .textAreaSizeCharacters,
                metrics: makeMetrics(),
                colorSchemeUpdateModeEnabled: false
            ),
            "\u{1b}[8;\(Fixture.rows);\(Fixture.columns)t"
        )
    }

    func testPixelQueriesAreUnansweredWithoutMetrics() {
        for query: TerminalCapabilityQuery in [.textAreaSizePixels, .cellSizePixels, .textAreaSizeCharacters] {
            XCTAssertNil(
                TerminalCapabilityReplies.reply(
                    for: query,
                    metrics: nil,
                    colorSchemeUpdateModeEnabled: false
                )
            )
        }
    }

    func testUnrelatedWindowOperationsAreNotCapabilityQueries() {
        // `CSI 1t` (deiconify) and `CSI 8;24;80t` (resize request) must not be
        // mistaken for reports Kurotty answers.
        XCTAssertNil(TerminalCapabilityReplies.query(final: "t", rawParameters: "1", parsed: CsiParameters("1")))
        XCTAssertNil(
            TerminalCapabilityReplies.query(final: "t", rawParameters: "8;24;80", parsed: CsiParameters("8;24;80"))
        )
        XCTAssertNil(TerminalCapabilityReplies.query(final: "t", rawParameters: "?14", parsed: CsiParameters("?14")))
    }

    func testColorSchemeUpdateModeReport() {
        let query = TerminalCapabilityReplies.query(
            final: "p",
            rawParameters: "?2031$",
            parsed: CsiParameters("?2031$")
        )
        XCTAssertEqual(query, .colorSchemeUpdateModeReport)
        XCTAssertEqual(
            TerminalCapabilityReplies.reply(
                for: .colorSchemeUpdateModeReport,
                metrics: nil,
                colorSchemeUpdateModeEnabled: true
            ),
            "\u{1b}[?2031;1$y"
        )
        XCTAssertEqual(
            TerminalCapabilityReplies.reply(
                for: .colorSchemeUpdateModeReport,
                metrics: nil,
                colorSchemeUpdateModeEnabled: false
            ),
            "\u{1b}[?2031;2$y"
        )
    }

    func testModeRequestWithoutTheDecrqmIntermediateIsIgnored() {
        // Without the `$` intermediate this is not DECRQM and must not answer.
        XCTAssertNil(
            TerminalCapabilityReplies.query(final: "p", rawParameters: "?2031", parsed: CsiParameters("?2031"))
        )
        XCTAssertNil(
            TerminalCapabilityReplies.query(final: "p", rawParameters: "?1049$", parsed: CsiParameters("?1049$"))
        )
    }

    func testColorSchemeNotificationBytes() {
        XCTAssertEqual(TerminalCapabilityReplies.colorSchemeNotification(.dark), "\u{1b}[?997;1n")
        XCTAssertEqual(TerminalCapabilityReplies.colorSchemeNotification(.light), "\u{1b}[?997;2n")
    }

    func testColorSchemeModeFollowsTerminalBackground() {
        XCTAssertEqual(TerminalColorSchemeMode(isLightBackground: true), .light)
        XCTAssertEqual(TerminalColorSchemeMode(isLightBackground: false), .dark)
    }

    // MARK: - Interpreter integration

    private func makeInterpreter(
        metrics: TerminalCapabilityMetrics?,
        responses: TerminalResponseRecorder
    ) -> TerminalOutputInterpreter {
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: .default,
            ansiColors: DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright,
            maxScrollbackRows: 1_000
        )
        interpreter.host = TerminalOutputInterpreterHost(
            sendTerminalResponse: { responses.terminalResponses.append($0) },
            respondToOscQuery: { responses.oscQueries.append($0) },
            dispatchTerminalIntegrationOsc: { _ in .ignored },
            publishTitle: {},
            handleTerminalIntegrationEvent: { _ in },
            handleDesktopNotificationEvent: { _ in },
            handleClipboardWriteEvent: { _ in },
            ringTerminalBell: {},
            updateScrollIndicator: {},
            maxScrollbackOffset: { _ in 0 },
            reportTerminalFocusIfNeeded: {},
            terminalCapabilityMetrics: { metrics },
            terminalColorSchemeMode: { .dark }
        )
        return interpreter
    }

    func testInterpreterAnswersEveryStartupProbe() {
        let responses = TerminalResponseRecorder()
        let interpreter = makeInterpreter(metrics: makeMetrics(), responses: responses)
        interpreter.interpret("\u{1b}[c\u{1b}[>c\u{1b}[14t\u{1b}[16t\u{1b}[18t\u{1b}[?2031$p")
        XCTAssertEqual(responses.terminalResponses, [
            "\u{1b}[?1;2c",
            "\u{1b}[>0;0;0c",
            "\u{1b}[4;\(Fixture.textAreaHeightPX);\(Fixture.textAreaWidthPX)t",
            "\u{1b}[6;17;8t",
            "\u{1b}[8;\(Fixture.rows);\(Fixture.columns)t",
            "\u{1b}[?2031;2$y",
        ])
    }

    func testDecsetAndDecrstToggleTheColorSchemeUpdateMode() {
        let responses = TerminalResponseRecorder()
        let interpreter = makeInterpreter(metrics: makeMetrics(), responses: responses)
        XCTAssertFalse(interpreter.colorSchemeUpdateModeEnabled)
        interpreter.interpret("\u{1b}[?2031h")
        XCTAssertTrue(interpreter.colorSchemeUpdateModeEnabled)
        interpreter.interpret("\u{1b}[?2031$p")
        XCTAssertEqual(responses.terminalResponses.last, "\u{1b}[?2031;1$y")
        interpreter.interpret("\u{1b}[?2031l")
        XCTAssertFalse(interpreter.colorSchemeUpdateModeEnabled)
        interpreter.interpret("\u{1b}[?2031$p")
        XCTAssertEqual(responses.terminalResponses.last, "\u{1b}[?2031;2$y")
    }

    func testCapabilityQueriesNeverReachTheScreenModel() {
        let responses = TerminalResponseRecorder()
        let interpreter = makeInterpreter(metrics: makeMetrics(), responses: responses)
        interpreter.interpret("\u{1b}[c\u{1b}[>c\u{1b}[14t\u{1b}[16t\u{1b}[18t\u{1b}[?2031$p\u{1b}[?2031h")
        for row in 0..<interpreter.screen.rows {
            let text = String(interpreter.screen.cells[row].map(\.character))
            XCTAssertEqual(
                text.trimmingCharacters(in: .whitespaces),
                "",
                "capability query leaked into screen row \(row): \(text.debugDescription)"
            )
        }
        XCTAssertEqual(interpreter.cursorRow, 0)
        XCTAssertEqual(interpreter.cursorColumn, 0)
    }

    func testReplayingScrollbackSuppressesEveryReply() {
        let responses = TerminalResponseRecorder()
        let interpreter = makeInterpreter(metrics: makeMetrics(), responses: responses)
        interpreter.isReplayingScrollback = true
        interpreter.interpret("\u{1b}[c\u{1b}[>c\u{1b}[14t\u{1b}[16t\u{1b}[18t\u{1b}[?2031$p\u{1b}[6n\u{1b}]11;?\u{7}")
        XCTAssertEqual(responses.terminalResponses, [])
        XCTAssertEqual(responses.oscQueries, [])
    }

    func testRepliesResumeAfterReplayEnds() {
        let responses = TerminalResponseRecorder()
        let interpreter = makeInterpreter(metrics: makeMetrics(), responses: responses)
        interpreter.isReplayingScrollback = true
        interpreter.interpret("\u{1b}[c")
        XCTAssertEqual(responses.terminalResponses, [])
        interpreter.isReplayingScrollback = false
        interpreter.interpret("\u{1b}[c")
        XCTAssertEqual(responses.terminalResponses, ["\u{1b}[?1;2c"])
    }

    func testReplayFlagDefaultsToFalse() {
        let responses = TerminalResponseRecorder()
        let interpreter = makeInterpreter(metrics: nil, responses: responses)
        XCTAssertFalse(interpreter.isReplayingScrollback)
    }
}

@MainActor
final class TerminalResponseRecorder {
    var terminalResponses: [String] = []
    var oscQueries: [String] = []
}
