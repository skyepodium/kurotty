import XCTest
import KurottyCore
@testable import KurottyApp

/// `CSI 20 t` / `CSI 21 t` (title reports) and `CSI 22/23 ; Ps t` (the title
/// stack).
///
/// The reports hand a string the child itself wrote back on the child's *input*
/// stream, so the tests that matter here are the ones about what cannot come
/// back: nothing at all while the setting is off, and nothing that is a control
/// character or unbounded in length while it is on.
@MainActor
final class TerminalTitleReportTests: XCTestCase {
    private enum Fixture {
        static let title = "kurotty"
        static let otherTitle = "second"
        static let bell = "\u{7}"
        static let escape = "\u{1b}"
        static let stringTerminator = "\u{1b}\\"
        static let windowTitleReportPrefix = "\u{1b}]l"
        static let iconTitleReportPrefix = "\u{1b}]L"
        static let reportWindowTitle = "\u{1b}[21t"
        static let reportIconTitle = "\u{1b}[20t"
        static let pushTitle = "\u{1b}[22t"
        static let popTitle = "\u{1b}[23t"
        /// `CSI 22 ; Ps t` / `CSI 23 ; Ps t` targets: both titles, icon, window.
        static let stackTargets = [0, 1, 2]
        /// The scalar ranges a report must never carry: C0 below the first
        /// printable scalar, DEL, and C1.
        static let firstPrintableScalar: UInt32 = 0x20
        static let deleteScalar: UInt32 = 0x7f
        static let c1ScalarRange: ClosedRange<UInt32> = 0x80...0x9f
        /// Every scalar of the first two Unicode blocks, which is every control
        /// a single byte can name plus the printable characters around them.
        static let latin1ScalarRange: ClosedRange<UInt32> = 0x00...0xff
    }

    private final class TitleRecorder {
        var responses: [String] = []
        var publishedTitleCount = 0
    }

    private func makeInterpreter(
        titleReportsEnabled: Bool,
        recorder: TitleRecorder
    ) -> TerminalOutputInterpreter {
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: .default,
            ansiColors: DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright,
            maxScrollbackRows: 1_000
        )
        interpreter.titleReportsEnabled = titleReportsEnabled
        interpreter.host = TerminalOutputInterpreterHost(
            sendTerminalResponse: { recorder.responses.append($0) },
            respondToOscQuery: { _ in },
            dispatchTerminalIntegrationOsc: { _ in .ignored },
            publishTitle: { recorder.publishedTitleCount += 1 },
            handleTerminalIntegrationEvent: { _ in },
            handleDesktopNotificationEvent: { _ in },
            handleClipboardWriteEvent: { _ in },
            ringTerminalBell: {},
            updateScrollIndicator: {},
            maxScrollbackOffset: { _ in 0 },
            reportTerminalFocusIfNeeded: {},
            terminalCapabilityMetrics: { nil },
            terminalColorSchemeMode: { .dark }
        )
        return interpreter
    }

    /// The title carried by a report, or `nil` when the response is not framed
    /// as one. Reading the payload back out is what lets a test assert about the
    /// title without restating the framing bytes.
    private func reportedTitle(_ response: String, prefix: String) -> String? {
        guard response.hasPrefix(prefix), response.hasSuffix(Fixture.stringTerminator) else {
            return nil
        }
        return String(response.dropFirst(prefix.count).dropLast(Fixture.stringTerminator.count))
    }

    private func setTitle(_ title: String, on interpreter: TerminalOutputInterpreter) {
        interpreter.interpret("\(Fixture.escape)]0;\(title)\(Fixture.bell)")
    }

    // MARK: - Off by default

    func testTitleReportsAreOffByDefault() {
        XCTAssertFalse(SettingsDefaults.titleReportsEnabled)
        XCTAssertFalse(AppSettings.default.terminal.titleReportsEnabled)
    }

    func testAnInterpreterNobodyConfiguredDoesNotReportTitles() {
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: .default,
            ansiColors: DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright,
            maxScrollbackRows: 1_000
        )
        XCTAssertFalse(interpreter.titleReportsEnabled)
    }

    func testTitleQueriesAnswerNothingWhileTheSettingIsOff() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: false, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)

        interpreter.interpret(Fixture.reportWindowTitle + Fixture.reportIconTitle)

        XCTAssertEqual(recorder.responses, [])
    }

    func testASuppressedTitleQueryPaintsNothingAndLeavesTheCursorAlone() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: false, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)

        interpreter.interpret(Fixture.reportWindowTitle + Fixture.reportIconTitle)

        for row in 0..<interpreter.screen.rows {
            let text = String(interpreter.screen.cells[row].map(\.character))
            XCTAssertEqual(
                text.trimmingCharacters(in: .whitespaces),
                "",
                "a suppressed title query leaked into screen row \(row): \(text.debugDescription)"
            )
        }
        XCTAssertEqual(interpreter.cursorRow, 0)
        XCTAssertEqual(interpreter.cursorColumn, 0)
        XCTAssertTrue(interpreter.isParsingBetweenSequences)
    }

    // MARK: - Framing when enabled

    func testWindowTitleReportIsFramedAsAnOscLowercaseL() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)

        interpreter.interpret(Fixture.reportWindowTitle)

        XCTAssertEqual(recorder.responses, [
            Fixture.windowTitleReportPrefix + Fixture.title + Fixture.stringTerminator,
        ])
    }

    func testIconTitleReportIsFramedAsAnOscUppercaseL() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)

        interpreter.interpret(Fixture.reportIconTitle)

        XCTAssertEqual(recorder.responses, [
            Fixture.iconTitleReportPrefix + Fixture.title + Fixture.stringTerminator,
        ])
    }

    func testTheReportFollowsTheTitleTheChildJustSet() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)
        interpreter.interpret(Fixture.reportWindowTitle)
        setTitle(Fixture.otherTitle, on: interpreter)
        interpreter.interpret(Fixture.reportWindowTitle)

        XCTAssertEqual(
            recorder.responses.map { reportedTitle($0, prefix: Fixture.windowTitleReportPrefix) },
            [Fixture.title, Fixture.otherTitle]
        )
    }

    func testWindowSizeQueriesStillAnswerWhileTitleReportsAreOff() {
        // The title parameters share the final byte with the size probes Claude
        // Code and Codex block on at startup; gating one must not touch the
        // other.
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: false, recorder: recorder)
        interpreter.host = TerminalOutputInterpreterHost(
            sendTerminalResponse: { recorder.responses.append($0) },
            respondToOscQuery: { _ in },
            dispatchTerminalIntegrationOsc: { _ in .ignored },
            publishTitle: { recorder.publishedTitleCount += 1 },
            handleTerminalIntegrationEvent: { _ in },
            handleDesktopNotificationEvent: { _ in },
            handleClipboardWriteEvent: { _ in },
            ringTerminalBell: {},
            updateScrollIndicator: {},
            maxScrollbackOffset: { _ in 0 },
            reportTerminalFocusIfNeeded: {},
            terminalCapabilityMetrics: {
                TerminalCapabilityMetrics(columns: 80, rows: 24, cellWidthPX: 8, cellHeightPX: 17)
            },
            terminalColorSchemeMode: { .dark }
        )

        interpreter.interpret("\u{1b}[18t")

        XCTAssertEqual(recorder.responses, ["\u{1b}[8;24;80t"])
    }

    // MARK: - Hardening: control characters

    func testAReportedTitleCarriesNoControlCharacterTheChildPutInIt() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        // Assigned rather than written through OSC on purpose: the OSC parser
        // abandons a title at a bare ESC, so this is the only way to prove the
        // report itself is the boundary that strips one.
        interpreter.terminalTitle = "a\nb\rc\u{1b}[31md\u{7f}e\u{9b}31mf\u{85}g"

        interpreter.interpret(Fixture.reportWindowTitle)

        let payload = reportedTitle(recorder.responses.first ?? "", prefix: Fixture.windowTitleReportPrefix)
        XCTAssertEqual(payload, "abc[31mde31mfg")
    }

    func testEveryScalarInAReportedTitleIsPrintable() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        interpreter.terminalTitle = String(
            String.UnicodeScalarView(Fixture.latin1ScalarRange.compactMap(UnicodeScalar.init))
        )

        interpreter.interpret(Fixture.reportWindowTitle)

        let payload = reportedTitle(recorder.responses.first ?? "", prefix: Fixture.windowTitleReportPrefix)
        XCTAssertNotNil(payload)
        for scalar in (payload ?? "").unicodeScalars {
            let isControl = scalar.value < Fixture.firstPrintableScalar
                || scalar.value == Fixture.deleteScalar
                || Fixture.c1ScalarRange.contains(scalar.value)
            XCTAssertFalse(
                isControl,
                "control scalar U+\(String(scalar.value, radix: 16, uppercase: true)) survived into a title report"
            )
        }
    }

    func testANewlineWrittenThroughOscNeverComesBackOnTheInputStream() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        // The whole attack in one line: the child sets a title that is a command
        // and a newline, then asks for it back.
        setTitle("rm -rf ~\ntouch pwned\r", on: interpreter)

        interpreter.interpret(Fixture.reportWindowTitle)

        let response = recorder.responses.first ?? ""
        XCTAssertFalse(response.contains("\n"))
        XCTAssertFalse(response.contains("\r"))
        XCTAssertEqual(
            reportedTitle(response, prefix: Fixture.windowTitleReportPrefix),
            "rm -rf ~touch pwned"
        )
    }

    // MARK: - Hardening: length

    func testALongTitleIsCappedInTheReport() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        let cap = AppConstants.Terminal.maximumReportedTitleScalarCount
        interpreter.terminalTitle = String(repeating: "a", count: cap * 4)

        interpreter.interpret(Fixture.reportWindowTitle)

        let payload = reportedTitle(recorder.responses.first ?? "", prefix: Fixture.windowTitleReportPrefix)
        XCTAssertEqual(payload?.unicodeScalars.count, cap)
    }

    func testTheCapCountsWhatSurvivedStrippingRatherThanWhatArrived() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        let cap = AppConstants.Terminal.maximumReportedTitleScalarCount
        let visibleCount = 8
        interpreter.terminalTitle = String(repeating: "\u{1}", count: cap * 2)
            + String(repeating: "b", count: visibleCount)

        interpreter.interpret(Fixture.reportWindowTitle)

        let payload = reportedTitle(recorder.responses.first ?? "", prefix: Fixture.windowTitleReportPrefix)
        XCTAssertEqual(payload, String(repeating: "b", count: visibleCount))
    }

    // MARK: - Title stack

    func testPushAndPopRestoreThePreviousTitle() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: false, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)

        interpreter.interpret(Fixture.pushTitle)
        setTitle(Fixture.otherTitle, on: interpreter)
        XCTAssertEqual(interpreter.terminalTitle, Fixture.otherTitle)

        interpreter.interpret(Fixture.popTitle)

        XCTAssertEqual(interpreter.terminalTitle, Fixture.title)
    }

    func testThePopThatRestoresATitlePublishesIt() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: false, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)
        interpreter.interpret(Fixture.pushTitle)
        setTitle(Fixture.otherTitle, on: interpreter)
        let publishedBeforePop = recorder.publishedTitleCount

        interpreter.interpret(Fixture.popTitle)

        XCTAssertEqual(recorder.publishedTitleCount, publishedBeforePop + 1)
    }

    func testEveryStackTargetAddressesTheSameSingleTitle() {
        for target in Fixture.stackTargets {
            let recorder = TitleRecorder()
            let interpreter = makeInterpreter(titleReportsEnabled: false, recorder: recorder)
            setTitle(Fixture.title, on: interpreter)

            interpreter.interpret("\u{1b}[22;\(target)t")
            setTitle(Fixture.otherTitle, on: interpreter)
            interpreter.interpret("\u{1b}[23;\(target)t")

            XCTAssertEqual(interpreter.terminalTitle, Fixture.title, "target \(target)")
        }
    }

    func testPoppingAnEmptyStackLeavesTheTitleAlone() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: false, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)
        let publishedBeforePop = recorder.publishedTitleCount

        interpreter.interpret(Fixture.popTitle + Fixture.popTitle)

        XCTAssertEqual(interpreter.terminalTitle, Fixture.title)
        XCTAssertEqual(recorder.publishedTitleCount, publishedBeforePop)
    }

    func testTheStackIsBoundedAndDropsItsOldestEntry() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: false, recorder: recorder)
        let depth = AppConstants.Terminal.maximumTitleStackDepth
        let overflowCount = 2
        let pushedTitles = (0..<(depth + overflowCount)).map { "title-\($0)" }
        for title in pushedTitles {
            setTitle(title, on: interpreter)
            interpreter.interpret(Fixture.pushTitle)
        }
        let finalTitle = "final"
        setTitle(finalTitle, on: interpreter)

        // The most recent `depth` pushes come back in order...
        var restored: [String] = []
        for _ in 0..<depth {
            interpreter.interpret(Fixture.popTitle)
            restored.append(interpreter.terminalTitle)
        }
        XCTAssertEqual(restored, Array(pushedTitles.suffix(depth).reversed()))

        // ...and the two that overflowed are gone rather than queued behind them.
        interpreter.interpret(Fixture.popTitle)
        XCTAssertEqual(interpreter.terminalTitle, pushedTitles[overflowCount])
    }

    func testStackSequencesNeverAnswerOnTheInputStream() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)

        interpreter.interpret(Fixture.pushTitle + Fixture.popTitle)

        XCTAssertEqual(recorder.responses, [])
    }

    func testAnUnknownStackTargetIsNotATitleOperation() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: false, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)

        interpreter.interpret("\u{1b}[22;9t")
        setTitle(Fixture.otherTitle, on: interpreter)
        interpreter.interpret("\u{1b}[23;9t")

        XCTAssertEqual(interpreter.terminalTitle, Fixture.otherTitle)
    }

    // MARK: - Replay guard

    func testReplayingScrollbackSuppressesTitleReportsEvenWhenEnabled() {
        // A restored snapshot can contain the *previous* session's `CSI 21 t`.
        // Answering it would type an old title into the fresh shell.
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)
        interpreter.isReplayingScrollback = true

        interpreter.interpret(Fixture.reportWindowTitle + Fixture.reportIconTitle)

        XCTAssertEqual(recorder.responses, [])
    }

    func testTitleReportsResumeAfterReplayEnds() {
        let recorder = TitleRecorder()
        let interpreter = makeInterpreter(titleReportsEnabled: true, recorder: recorder)
        setTitle(Fixture.title, on: interpreter)
        interpreter.isReplayingScrollback = true
        interpreter.interpret(Fixture.reportWindowTitle)
        XCTAssertEqual(recorder.responses, [])

        interpreter.isReplayingScrollback = false
        interpreter.interpret(Fixture.reportWindowTitle)

        XCTAssertEqual(recorder.responses, [
            Fixture.windowTitleReportPrefix + Fixture.title + Fixture.stringTerminator,
        ])
    }

    // MARK: - Settings schema

    func testSettingsWrittenBeforeTheKeyExistedNormalizeToTheCurrentDefault() {
        var settings = AppSettings.default
        settings.schemaVersion = 23
        settings.terminal.titleReportsEnabled = true

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertEqual(normalized.schemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertEqual(normalized.terminal.titleReportsEnabled, SettingsDefaults.titleReportsEnabled)
    }

    func testCurrentSchemaPreservesAnExplicitOptIn() {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion
        settings.terminal.titleReportsEnabled = true

        XCTAssertTrue(AppSettingsNormalizer.normalized(settings).terminal.titleReportsEnabled)
    }

    func testAnExplicitChoiceSurvivesAnEncodeDecodeRoundTrip() throws {
        for choice in [true, false] {
            var settings = AppSettings.default
            settings.terminal.titleReportsEnabled = choice

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

            XCTAssertEqual(decoded.terminal.titleReportsEnabled, choice)
        }
    }

    func testDecodingASettingsFileWithoutTheKeyLeavesReportsOff() throws {
        let json = """
        {
          "schemaVersion": 23,
          "terminal": {
            "theme": "kurotty",
            "fontName": "Menlo",
            "fontSize": 15,
            "scrollbackLines": 10000,
            "colors": {
              "foreground": "#E5E7EB",
              "background": "#22252B",
              "cursor": "#D7C6F4",
              "ansi": [
                "#2F333A", "#FF5F67", "#5FD38D", "#E5C07B",
                "#61AFEF", "#C792EA", "#56B6C2", "#D7DAE0",
                "#60646C", "#FF7B86", "#8EE8A3", "#F0D28A",
                "#7AB7FF", "#D7A8FF", "#7FDCE3", "#F5F7FA"
              ]
            }
          },
          "window": { "width": 1100, "height": 720 },
          "shell": { "workingDirectory": "/tmp" }
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertFalse(decoded.terminal.titleReportsEnabled)
    }

    func testTheSettingIsLiveApplied() {
        XCTAssertEqual(AppSettingsValidation.lifecycle(for: .terminalTitleReportsEnabled), .liveApplied)
    }
}
