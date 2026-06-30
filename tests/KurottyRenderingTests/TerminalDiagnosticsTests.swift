import Foundation
import XCTest
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
            TerminalScreenCell(character: "s"),
            TerminalScreenCell(character: "e"),
            TerminalScreenCell(character: "c"),
            TerminalScreenCell(character: "r"),
            TerminalScreenCell(character: "e"),
            TerminalScreenCell(character: "t"),
            TerminalScreenCell(character: " "),
        ]

        XCTAssertEqual(TerminalScreenDiagnostics.occupiedCellCount(in: cells), 6)
    }
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

private func sourceRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        url.deleteLastPathComponent()
    }
    return url
}
