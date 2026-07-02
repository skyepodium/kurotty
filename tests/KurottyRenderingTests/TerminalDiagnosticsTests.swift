import Foundation
import XCTest
@testable import KurottyCore
@testable import KurottyApp

final class TerminalDiagnosticsTests: XCTestCase {
    func testInputClientDebugLoggingUsesMetadataOnly() throws {
        let source = try terminalTextInputRouterSource()

        XCTAssertTrue(source.contains("source=\\(source)"))
        XCTAssertTrue(source.contains("utf8ByteCount=\\(text.utf8.count)"))
        XCTAssertTrue(source.contains("characterCount=\\(text.count)"))
        XCTAssertTrue(source.contains("replacement=\\(NSStringFromRange(replacementRange))"))
        XCTAssertTrue(source.contains("selected=\\(NSStringFromRange(selectedRange))"))
        XCTAssertTrue(source.contains("keyCode=\\(event.keyCode)"))
        XCTAssertTrue(source.contains("flags=\\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)"))

        XCTAssertFalse(source.contains("String(format: \"%02X\""))
        XCTAssertFalse(source.contains("debugText("))
        XCTAssertFalse(source.contains("chars=\\("))
        XCTAssertFalse(source.contains("ignoring=\\("))
        XCTAssertFalse(source.contains("text=\\("))
    }

    func testNotificationSummarySkipsMetadataStatusLines() {
        let statusLine = "gpt-5.5 medium · ~/dev/kurotty · gpt-5.5 · medium · kurotty · develop · No changes · Ready · Workspace · Ask fo..."
        let answerLine = "• 안녕하세요. 무엇을 도와드릴까요?"

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "────────────────────────────────────────",
                answerLine,
                statusLine,
            ]),
            answerLine
        )
    }

    func testNotificationSummarySkipsCodexContextStatusLines() {
        let answerLine = "작업 완료: 알림 본문은 마지막 완료 요약을 보여줍니다."
        let statusLine = "gpt-5.5 medium · ~/dev · gpt-5.5 · medium · Ready · Full Access · never · Context 100% left · Context 0% used · 5h 7..."

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                answerLine,
                statusLine,
            ]),
            answerLine
        )
    }

    func testNotificationSummarySkipsPromptPlaceholderLines() {
        let answerLine = "원인 잡아서 고쳤습니다."

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "────────────────────────────────────────",
                answerLine,
                "› Explain this codebase",
            ]),
            answerLine
        )
    }

    func testNotificationSummarySkipsShellPromptLines() {
        let answerLine = "작업 완료: 알림 본문은 이 줄이어야 합니다."
        let promptLine = "\(NSUserName()) ~/dev kurotty"

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                answerLine,
                promptLine,
            ]),
            answerLine
        )
    }

    func testNotificationSummaryDoesNotReturnOnlyShellPrompt() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "\(NSUserName()) ~/dev",
                "\(NSUserName()) /Users/\(NSUserName())/dev/kurotty",
            ])
        )
    }

    func testNotificationSummaryDoesNotReturnOnlyPromptPlaceholder() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "› Explain this codebase",
                "> Ask anything",
            ])
        )
    }

    func testNotificationSummaryDoesNotReturnOnlyStatusOrDecoration() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "────────────────────────────────────────",
                "gpt-5.5 medium · ~/dev/kurotty · gpt-5.5 · medium · kurotty · develop · No changes · Ready · Workspace",
            ])
        )
    }

    func testNotificationSummarySkipsSeparatorVariantsAfterAnswer() {
        let answerLine = "안녕. 오늘은 Kurotty 작업 도와줄까, 아니면 다른 얘기할까?"

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                answerLine,
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━…",
                "⎯⎯⎯⎯⎯⎯⎯⎯",
                "╭────────────────────────╮",
            ]),
            answerLine
        )
    }

    func testNotificationSummaryUsesLatestAnswerFromOutputText() {
        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromOutputText: """
            \u{1b}[2m•\u{1b}[0m 안녕하세요. 무엇을 도와드릴까요?

            ────────────────────────────────────────

            › 아녕

            • 안녕! 편하게 말씀해 주세요.
            """),
            "• 안녕! 편하게 말씀해 주세요."
        )
    }

    func testNotificationSummaryUsesLatestMeaningfulOutputBlock() {
        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulText(fromOutputText: """
            build step 1 passed
            build step 2 passed
            tests failed: 2 regressions

            ────────────────────────────────────────

            \(NSUserName()) ~/dev/kurotty
            """),
            """
            build step 1 passed
            build step 2 passed
            tests failed: 2 regressions
            """
        )
    }

    func testNotificationSummaryUsesLatestCodexAnswerBlockInsteadOfSubmittedPrompt() {
        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulText(fromOutputText: """
            Tip: Use /side to start a side conversation in a temporary fork

            • You have 4 usage limit resets available. Run /usage to use one.

            ⚠ failed to parse hooks config /Users/skyepodium/.codex/hooks.json
              column 9

            › 안녕하세요

            • superpowers:using-superpowers 지침을 먼저 확인한 뒤, 간단히 응답

            • Explored
              └ Read SKILL.md (superpowers:using-superpowers skill)

            • 안녕하세요. 무엇을 도와드릴까요?

            ────────────────────────────────────────

            › Summarize recent commits
            """),
            "• 안녕하세요. 무엇을 도와드릴까요?"
        )
    }

    func testNotificationSummaryRemovesInlineCodexStatusFragments() {
        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulText(fromOutputText: """
            • 안녕하세요. 무엇을 도와드릴까요?•Work55
            """),
            "• 안녕하세요. 무엇을 도와드릴까요?"
        )

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulText(fromOutputText: """
            • 안녕하세요. 무엇을 도와드릴까요? · Ready · Workspace
            """),
            "• 안녕하세요. 무엇을 도와드릴까요?"
        )
    }

    func testNotificationSummarySkipsUsageStatusFromOutputText() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromOutputText: """
            Weekly limit:
            [██████████████████████████████]
            100% left (resets 05:23 on 8 Jul) |
            """)
        )
    }

    func testNotificationSummaryDoesNotReturnOnlySeparatorVariants() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━…",
                "⎯⎯⎯⎯⎯⎯⎯⎯",
                "╰────────────────────────╯",
                "••••••••••",
            ])
        )
    }

    func testNotificationLogMetadataDoesNotExposeTitleOrBody() {
        let metadata = TerminalNotificationLogMetadata(
            identifierPrefix: "dev.kurotty.terminal.osc9",
            title: "Build finished",
            body: "secret terminal output /Users/example/private"
        )

        XCTAssertEqual(metadata.identifierPrefix, "dev.kurotty.terminal.osc9")
        XCTAssertEqual(metadata.titleLength, 14)
        XCTAssertEqual(metadata.bodyLength, 45)
        XCTAssertFalse(metadata.description.contains("Build finished"))
        XCTAssertFalse(metadata.description.contains("secret terminal output"))
        XCTAssertFalse(metadata.description.contains("/Users/example/private"))
    }

    func testRawPtyLogMetadataDoesNotExposeBytesOrDecodedText() {
        let data = Data("token=secret\n".utf8)
        let metadata = TerminalRawPtyLogMetadata(data: data)

        XCTAssertEqual(metadata.byteCount, data.count)
        XCTAssertFalse(metadata.description.contains("token=secret"))
        XCTAssertFalse(metadata.description.contains("746F6B656E"))
    }

    func testCoreCompatibilityDiagnosticDescribesStateSourcesWithoutTerminalContent() {
        let diagnostic = TerminalCoreCompatibilityDiagnostic(
            bridge: .zigCore,
            pty: .swiftScaffold,
            parser: .swiftScaffold,
            screen: .swiftScaffold,
            render: .swiftScaffold
        )

        XCTAssertEqual(diagnostic.bridge, .zigCore)
        XCTAssertEqual(diagnostic.screen, .swiftScaffold)
        XCTAssertEqual(diagnostic.render, .swiftScaffold)
        XCTAssertTrue(diagnostic.description.contains("bridge=zig-core"))
        XCTAssertTrue(diagnostic.description.contains("pty=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("parser=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("screen=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("render=swift-scaffold"))
        XCTAssertFalse(diagnostic.description.contains("token=secret"))
        XCTAssertFalse(diagnostic.description.contains("terminal text"))
    }

    func testTraceCorrelationReportRequiresOrderedPipelineStages() {
        let traceID = TerminalEventTraceID("diagnostic-pipeline")
        let completeSummary = TerminalEventLedger.TraceSummary(
            traceID: traceID,
            eventCount: 4,
            kindCounts: [
                .ptyRead: 1,
                .parserEvent: 1,
                .screenMutation: 1,
                .renderFrame: 1,
            ],
            ptyReadByteCount: 5,
            parserEventByteCount: 5,
            screenMutationCount: 1,
            renderFrameCount: 1,
            dirtyRegionCount: 2,
            fullRedrawCount: 0,
            firstSequence: 0,
            lastSequence: 3,
            droppedEventCount: 0
        )
        let outOfOrder = TerminalTraceCorrelationReport(
            eventSummary: completeSummary,
            stageSequence: [.ptyRead, .screenMutation, .parserEvent, .renderFrame]
        )

        XCTAssertFalse(outOfOrder.hasCompleteRenderPath)
        XCTAssertEqual(
            outOfOrder.description,
            "trace=diagnostic-pipeline path=ptyRead>screenMutation>parserEvent>renderFrame complete=false resize=unavailable issues=0 ptyBytes=5 parserBytes=5 screenMutations=1 renderFrames=1 dirtyRegions=2 fullRedraws=0 droppedEvents=0"
        )
        XCTAssertFalse(outOfOrder.description.contains("token=secret"))
    }

    func testCoreBridgeReportsSwiftScaffoldDiagnosticWhenZigCoreIsUnavailable() {
        let bridge = CoreBridge(cols: 2, rows: 1, loadSymbols: false)

        XCTAssertEqual(bridge.compatibilityDiagnostic.bridge, .swiftScaffold)
        XCTAssertEqual(bridge.compatibilityDiagnostic.screen, .swiftScaffold)
        XCTAssertEqual(bridge.compatibilityDiagnostic.render, .swiftScaffold)
        XCTAssertTrue(bridge.compatibilityDiagnostic.description.contains("bridge=swift-scaffold"))
        XCTAssertTrue(bridge.compatibilityDiagnostic.description.contains("screen=swift-scaffold"))
    }

    func testTerminalCoreFactoryExposesCompatibilityDiagnosticForTypeErasedCore() {
        let core: any TerminalCore = CoreBridge(cols: 2, rows: 1, loadSymbols: false)
        let diagnostic = TerminalCoreFactory.compatibilityDiagnostic(for: core)

        XCTAssertEqual(diagnostic.bridge, .swiftScaffold)
        XCTAssertEqual(diagnostic.pty, .swiftScaffold)
        XCTAssertEqual(diagnostic.parser, .swiftScaffold)
        XCTAssertEqual(diagnostic.screen, .swiftScaffold)
        XCTAssertEqual(diagnostic.render, .swiftScaffold)
    }

    func testTerminalCoreFactoryReportsUnknownForNonDiagnosingCore() {
        let core: any TerminalCore = NonDiagnosingTerminalCore()
        let diagnostic = TerminalCoreFactory.compatibilityDiagnostic(for: core)

        XCTAssertEqual(diagnostic.bridge, .unknown)
        XCTAssertEqual(diagnostic.pty, .unknown)
        XCTAssertEqual(diagnostic.parser, .unknown)
        XCTAssertEqual(diagnostic.screen, .unknown)
        XCTAssertEqual(diagnostic.render, .unknown)
    }

    func testResizeTraceClampsRequestedDimensionsToPtyWinsizeRange() {
        let trace = TerminalResizeTrace(
            requestedColumns: 0,
            requestedRows: 70_000,
            cellSize: nil,
            viewSize: nil,
            ioctlResult: 0,
            ioctlErrno: nil,
            didSendSIGWINCH: true
        )

        XCTAssertEqual(trace.requestedColumns, 0)
        XCTAssertEqual(trace.requestedRows, 70_000)
        XCTAssertEqual(trace.clampedColumns, 1)
        XCTAssertEqual(trace.clampedRows, Int(UInt16.max))
        XCTAssertTrue(trace.description.contains("requested=0x70000"))
        XCTAssertTrue(trace.description.contains("clamped=1x65535"))
        XCTAssertTrue(trace.description.contains("sigwinch=sent"))
    }

    func testResizeTraceFormatsOptionalViewAndIoctlMetadataOnly() {
        let trace = TerminalResizeTrace(
            requestedColumns: 120,
            requestedRows: 40,
            cellSize: TerminalFrameSize(width: 9.25, height: 18.5),
            viewSize: TerminalFrameSize(width: 1110.0, height: 740.0),
            ioctlResult: -1,
            ioctlErrno: 25,
            didSendSIGWINCH: false
        )

        XCTAssertEqual(trace.clampedColumns, 120)
        XCTAssertEqual(trace.clampedRows, 40)
        XCTAssertTrue(trace.description.contains("requested=120x40"))
        XCTAssertTrue(trace.description.contains("clamped=120x40"))
        XCTAssertTrue(trace.description.contains("cell=9.25x18.50"))
        XCTAssertTrue(trace.description.contains("view=1110.00x740.00"))
        XCTAssertTrue(trace.description.contains("ioctl=-1 errno=25"))
        XCTAssertTrue(trace.description.contains("sigwinch=not-sent"))
        XCTAssertFalse(trace.description.contains("token="))
        XCTAssertFalse(trace.description.contains("/Users/"))
    }

    func testDarwinResizeLogsTraceMetadataWhenPtyLoggingIsEnabled() throws {
        let source = try shellSessionSource()

        XCTAssertTrue(source.contains("TerminalResizeTrace("))
        XCTAssertTrue(source.contains("UInt16(trace.clampedRows)"))
        XCTAssertTrue(source.contains("UInt16(trace.clampedColumns)"))
        XCTAssertTrue(source.contains("ioctlResult == -1 ? errno : nil"))
        XCTAssertTrue(source.contains("if DebugOptions.ptyLog"))
        XCTAssertTrue(source.contains("Kurotty PTY resize"))
        XCTAssertFalse(source.contains("UInt16(max(1, rows))"))
        XCTAssertFalse(source.contains("UInt16(max(1, columns))"))
    }

    func testStyleRunSummaryReportsRangesWithoutCellText() {
        let red = TerminalTextStyle(
            foreground: SIMD4<Float>(1, 0, 0, 1),
            background: SIMD4<Float>(0, 0, 0, 1)
        )
        let green = TerminalTextStyle(
            foreground: SIMD4<Float>(0, 1, 0, 1),
            background: SIMD4<Float>(0, 0, 0, 1)
        )

        let summary = TerminalScreenDiagnostics.styleRuns(
            for: [.default, .default, red, green],
            background: false
        )

        XCTAssertTrue(summary.contains("0-1"))
        XCTAssertTrue(summary.contains("2-2"))
        XCTAssertTrue(summary.contains("3-3"))
        XCTAssertFalse(summary.contains("secret"))
    }

    func testScreenDumpSourceDoesNotLogCellText() throws {
        let source = try terminalSurfaceViewSource()
        guard let start = source.range(of: "private func logScreenDumpIfNeeded")?.lowerBound,
              let end = source.range(of: "private func currentCursorCellRectInViewCoordinates")?.lowerBound else {
            XCTFail("missing screen dump source region")
            return
        }
        let screenDumpSource = String(source[start..<end])

        XCTAssertTrue(screenDumpSource.contains("occupiedCells="))
        XCTAssertTrue(screenDumpSource.contains("TerminalScreenDiagnostics.occupiedCellCount"))
        XCTAssertFalse(screenDumpSource.contains("text='%@'"))
        XCTAssertFalse(screenDumpSource.contains("String(row.map(\\.character))"))
    }

    func testOccupiedCellCountDoesNotExposeCellText() {
        let cells = [
            KurottyCore.TerminalScreenCell(character: "s"),
            KurottyCore.TerminalScreenCell(character: "e"),
            KurottyCore.TerminalScreenCell(character: "c"),
            KurottyCore.TerminalScreenCell(character: "r"),
            KurottyCore.TerminalScreenCell(character: "e"),
            KurottyCore.TerminalScreenCell(character: "t"),
            KurottyCore.TerminalScreenCell(character: " "),
        ]

        XCTAssertEqual(TerminalScreenDiagnostics.occupiedCellCount(in: cells), 6)
    }
}

private final class NonDiagnosingTerminalCore: TerminalCore {
    func feed(_ text: String) {}
    func recordKeyEvent() {}
    func recordFramePresented() {}
    func beginFrame(visibleCells: UInt32) -> UInt32 { visibleCells }
    func endFrame() {}
    func lastLatencyMicros() -> UInt64 { 0 }
    func resize(cols: UInt32, rows: UInt32) {}
    func cell(row: UInt32, col: UInt32) -> UInt8 { 0 }
    func copyRow(_ row: UInt32, into buffer: inout [UInt8]) -> Int { 0 }
}

private func terminalTextInputRouterSource() throws -> String {
    try String(
        contentsOf: sourceRoot()
            .appendingPathComponent("Sources/KurottyApp/TerminalTextInputRouter.swift"),
        encoding: .utf8
    )
}

private func terminalSurfaceViewSource() throws -> String {
    try String(
        contentsOf: sourceRoot()
            .appendingPathComponent("Sources/KurottyApp/TerminalSurfaceView.swift"),
        encoding: .utf8
    )
}

private func shellSessionSource() throws -> String {
    try String(
        contentsOf: sourceRoot()
            .appendingPathComponent("Sources/KurottyApp/ShellSession.swift"),
        encoding: .utf8
    )
}

private func sourceRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        url.deleteLastPathComponent()
    }
    return url
}
