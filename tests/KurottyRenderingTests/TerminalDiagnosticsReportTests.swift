import XCTest
@testable import KurottyApp

final class TerminalDiagnosticsReportTests: XCTestCase {
    private enum Fixture {
        static let secretWord = "supersecretpassword"
        static let homePath = "/Users/example-person/dev/terminal/kurotty"
        static let paneIdentifier = "11111111-2222-3333-4444-555555555555"
        static let appVersion = "0.9.9 (321)"
        static let gpuName = "Apple M9 Max"
    }

    private func makeLedger() -> TerminalEventLedger {
        var ledger = TerminalEventLedger(capacity: 64)
        ledger.recordPtyRead(traceID: "trace-1", byteCount: 512)
        ledger.recordParserEvent(traceID: "trace-1", event: .printable(byteCount: 512))
        ledger.recordScreenMutation(traceID: "trace-1", mutation: .writeCells(cellCount: 120))
        ledger.recordRenderFrame(
            traceID: "trace-1",
            frame: TerminalEventLedger.RenderFrame(frameIndex: 7, dirtyRegionCount: 3, fullRedraw: false)
        )
        return ledger
    }

    private func makeInput(
        ledger: TerminalEventLedger? = nil,
        workingDirectoryName: String? = "kurotty"
    ) -> TerminalDiagnosticsReportInput {
        let ledger = ledger ?? makeLedger()
        let pane = TerminalDiagnosticsReportInput.Pane(
            paneIdentifier: Fixture.paneIdentifier,
            columns: 120,
            rows: 40,
            cellWidthPX: 8.5,
            cellHeightPX: 17.5,
            isUsingAlternateScreen: true,
            isBracketedPasteEnabled: true,
            isColorSchemeUpdateModeEnabled: false,
            isReplayingScrollback: false,
            workingDirectoryName: workingDirectoryName,
            isRemoteWorkingDirectory: false,
            eventLedger: ledger.diagnostics,
            latestTrace: ledger.timelineSummary(for: "trace-1"),
            resizeSourceOfTruth: nil,
            scrollback: nil,
            renderDamage: "decision=partial policy=immediate-partial-redraw dirtyRects=3",
            recentEvents: ledger.events
        )
        return TerminalDiagnosticsReportInput(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            environment: TerminalDiagnosticsReportInput.Environment(
                appVersion: Fixture.appVersion,
                operatingSystemVersion: "Version 26.5 (Build 26F1)",
                architecture: "arm64",
                rendererName: "metal",
                gpuName: Fixture.gpuName,
                backingScaleFactor: 2,
                languageCode: "en"
            ),
            windowCount: 2,
            panes: [pane],
            coreMutationSource: TerminalCoreMutationSourceDiagnostic(
                sessionMutationOwner: .swiftScaffold,
                frameMutationOwner: .swiftScaffold,
                zigBridgeActive: true,
                reason: "swift-runtime-mutation-with-zig-feed-active"
            ),
            coreRuntimeBoundary: TerminalCoreRuntimeBoundaryDiagnostic(
                feedBridgeParticipant: .zigCore,
                parserMutationOwner: .swiftScaffold,
                screenMutationOwner: .swiftScaffold,
                renderMutationOwner: .swiftScaffold,
                mutationHandoffReady: false,
                dualWriteRisk: .feedBridgeOnly,
                reason: "zig-feed-bridge-active-swift-mutation-owner"
            )
        )
    }

    // MARK: - Contents

    func testReportIncludesEnvironmentAndOwnershipDiagnostics() {
        let report = TerminalDiagnosticsReportBuilder.build(makeInput())
        for expected in [
            Fixture.appVersion,
            "Version 26.5 (Build 26F1)",
            "arm64",
            "metal",
            Fixture.gpuName,
            "zig-feed-bridge-active-swift-mutation-owner",
            "swift-runtime-mutation-with-zig-feed-active",
        ] {
            XCTAssertTrue(report.json.contains(expected), "json missing \(expected)")
            XCTAssertTrue(report.markdown.contains(expected), "markdown missing \(expected)")
        }
    }

    func testReportIncludesPaneCountsCellMetricsAndLedgerSummaries() {
        let report = TerminalDiagnosticsReportBuilder.build(makeInput())
        XCTAssertTrue(report.json.contains("\"paneCount\" : 1"))
        XCTAssertTrue(report.json.contains("\"windowCount\" : 2"))
        XCTAssertTrue(report.json.contains("8.5"))
        XCTAssertTrue(report.json.contains("17.5"))
        XCTAssertTrue(report.json.contains("retainedEvents=4"))
        XCTAssertTrue(report.json.contains("ptyBytes=512"))
        XCTAssertTrue(report.markdown.contains("Grid: 120x40"))
        XCTAssertTrue(report.markdown.contains(Fixture.paneIdentifier))
    }

    func testReportIsValidJson() throws {
        let report = TerminalDiagnosticsReportBuilder.build(makeInput())
        let data = try XCTUnwrap(report.json.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["paneCount"] as? Int, 1)
        XCTAssertNotNil(object["coreBridge"])
        XCTAssertNotNil(object["capturedAt"])
    }

    func testMarkdownEmbedsTheJson() {
        let report = TerminalDiagnosticsReportBuilder.build(makeInput())
        XCTAssertTrue(report.markdown.contains("# Kurotty Diagnostics Report"))
        XCTAssertTrue(report.markdown.contains("```json"))
        XCTAssertTrue(report.markdown.contains(report.json))
    }

    func testRecentEventsAreBounded() {
        var ledger = TerminalEventLedger(capacity: 1_000)
        for index in 0..<200 {
            ledger.recordPtyRead(traceID: "trace-1", byteCount: index)
        }
        let report = TerminalDiagnosticsReportBuilder.build(makeInput(ledger: ledger))
        let eventLines = report.markdown
            .split(separator: "\n")
            .filter { $0.hasPrefix("#") && $0.contains("ptyRead") }
        XCTAssertEqual(eventLines.count, TerminalDiagnosticsReportBuilder.recentEventLimit)
    }

    // MARK: - Redaction

    func testWorkingDirectoryIsReducedToItsLastComponent() {
        XCTAssertEqual(
            TerminalDiagnosticsReportBuilder.workingDirectoryName(fromPath: Fixture.homePath),
            "kurotty"
        )
        XCTAssertNil(TerminalDiagnosticsReportBuilder.workingDirectoryName(fromPath: nil))
        XCTAssertNil(TerminalDiagnosticsReportBuilder.workingDirectoryName(fromPath: ""))
        XCTAssertNil(TerminalDiagnosticsReportBuilder.workingDirectoryName(fromPath: "/"))
    }

    func testReportNeverContainsAFullPath() {
        let report = TerminalDiagnosticsReportBuilder.build(
            makeInput(
                workingDirectoryName: TerminalDiagnosticsReportBuilder.workingDirectoryName(
                    fromPath: Fixture.homePath
                )
            )
        )
        for blob in [report.json, report.markdown] {
            XCTAssertFalse(blob.contains(Fixture.homePath))
            XCTAssertFalse(blob.contains("/Users/"))
            XCTAssertFalse(blob.contains("example-person"))
            XCTAssertTrue(blob.contains("kurotty"))
        }
    }

    func testOscPayloadsAreReducedToTheirCommandCode() {
        var ledger = TerminalEventLedger(capacity: 8)
        ledger.recordParserEvent(
            traceID: "trace-1",
            event: .osc(command: "777;notify;\(Fixture.secretWord);\(Fixture.homePath)", byteCount: 64)
        )
        let report = TerminalDiagnosticsReportBuilder.build(makeInput(ledger: ledger))
        for blob in [report.json, report.markdown] {
            XCTAssertFalse(blob.contains(Fixture.secretWord))
            XCTAssertFalse(blob.contains("notify"))
            XCTAssertFalse(blob.contains(Fixture.homePath))
            XCTAssertTrue(blob.contains("osc command=777"))
        }
    }

    func testNonIdentifierParserKindsAreWithheld() {
        var ledger = TerminalEventLedger(capacity: 8)
        ledger.recordParserEvent(
            traceID: "trace-1",
            event: .control(kind: "echo \(Fixture.secretWord)", byteCount: 4)
        )
        ledger.recordParserEvent(
            traceID: "trace-1",
            event: .escapeSequence(kind: "csi-sgr", byteCount: 4)
        )
        let report = TerminalDiagnosticsReportBuilder.build(makeInput(ledger: ledger))
        XCTAssertFalse(report.json.contains(Fixture.secretWord))
        XCTAssertTrue(
            report.json.contains("kind=\(TerminalDiagnosticsReportBuilder.redactedPlaceholder)")
        )
        XCTAssertTrue(report.json.contains("kind=csi-sgr"))
    }

    func testEventLinesCarryOnlyCountsAndKinds() {
        var ledger = TerminalEventLedger(capacity: 8)
        ledger.recordPtyRead(traceID: "trace-1", byteCount: 99)
        let line = TerminalDiagnosticsReportBuilder.redactedEventLine(ledger.events[0])
        XCTAssertEqual(line, "#0 ptyRead trace=trace-1 bytes=99")
    }

    func testMarkdownStatesWhatIsExcluded() {
        let report = TerminalDiagnosticsReportBuilder.build(makeInput())
        XCTAssertTrue(report.markdown.contains("No terminal output"))
    }

    func testMissingSectionsAreLabeledRatherThanOmitted() {
        let report = TerminalDiagnosticsReportBuilder.build(makeInput())
        XCTAssertTrue(report.json.contains(TerminalDiagnosticsReportBuilder.redactedPlaceholder))
        XCTAssertTrue(report.markdown.contains("Scrollback: \(TerminalDiagnosticsReportBuilder.redactedPlaceholder)"))
    }
}

@MainActor
final class TerminalDiagnosticsReportMenuTests: XCTestCase {
    func testHelpMenuOffersCopyDiagnosticsReport() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/KurottyApp/MainMenu.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("AppLocalization.string(.help)"))
        XCTAssertTrue(source.contains("AppLocalization.string(.copyDiagnosticsReport)"))
        XCTAssertTrue(source.contains("DiagnosticsReportMenuActionTarget.shared"))
        // The Help menu must keep its own action target through the final
        // target-assignment loop.
        XCTAssertTrue(source.contains("item.submenu !== helpMenu"))
    }

    func testDiagnosticsReportCopyPutsMarkdownOnThePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.kurotty.tests.diagnostics"))
        let report = TerminalDiagnosticsReportCollector.copyToPasteboard(
            pasteboard,
            windows: [],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), report.markdown)
        XCTAssertTrue(report.markdown.contains("# Kurotty Diagnostics Report"))
        XCTAssertTrue(report.markdown.contains("Panes: 0"))
    }

    func testDiagnosticsReportLocalizationIsComplete() {
        for language in AppLanguage.allCases {
            for key: L10nKey in [.help, .copyDiagnosticsReport, .diagnosticsReportCopiedTitle, .diagnosticsReportCopiedMessage] {
                XCTAssertTrue(
                    AppLocalization.hasTranslation(for: key, language: language),
                    "missing \(language.rawValue) translation for \(key.rawValue)"
                )
            }
        }
    }
}
