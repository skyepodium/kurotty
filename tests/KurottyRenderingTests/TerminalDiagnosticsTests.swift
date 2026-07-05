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

    func testExplicitTerminalNotificationPayloadUsesOnlyPayloadText() {
        let payload = "  gpt-5.5 medium · Ready\nCodex-like status text is still explicit payload  "

        XCTAssertEqual(
            TerminalNotificationPayload.body(fromExplicitPayload: payload),
            "gpt-5.5 medium · Ready\nCodex-like status text is still explicit payload"
        )
    }

    func testExplicitTerminalNotificationPayloadStripsControlsAndBoundsLength() {
        let payload = "\u{1b}Build finished\u{7f}\n" + String(repeating: "x", count: AppConstants.Notifications.terminalNotificationMaxCharacters + 10)
        let body = TerminalNotificationPayload.body(fromExplicitPayload: payload)

        XCTAssertEqual(body?.count, AppConstants.Notifications.terminalNotificationMaxCharacters)
        XCTAssertFalse(body?.contains("\u{1b}") ?? true)
        XCTAssertFalse(body?.contains("\u{7f}") ?? true)
        XCTAssertTrue(body?.hasPrefix("Build finished\n") ?? false)
    }

    func testOSC777NotificationPayloadUsesNotifyTitleAndBodyFields() {
        let content = TerminalNotificationPayload.contentFromOSC777Payload(
            "notify;Build finished;All tests passed"
        )

        XCTAssertEqual(content?.title, "Build finished")
        XCTAssertEqual(content?.body, "All tests passed")
    }

    func testOSC777NotificationPayloadRejectsNonNotifyShape() {
        XCTAssertNil(TerminalNotificationPayload.contentFromOSC777Payload("progress;50"))
        XCTAssertNil(TerminalNotificationPayload.contentFromOSC777Payload("notify;Missing body"))
    }

    func testSubmittedCommandSummaryNormalizesOnlySubmittedInput() {
        XCTAssertEqual(
            TerminalSubmittedCommandSummary.notificationBody(from: "  swift test\n--filter TerminalDiagnosticsTests  "),
            "swift test --filter TerminalDiagnosticsTests"
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

    func testTraceCorrelationReportExposesProductionTimelineSummary() {
        let traceID = TerminalEventTraceID("timeline-pipeline")
        let summary = TerminalEventLedger.TraceSummary(
            traceID: traceID,
            eventCount: 4,
            kindCounts: [
                .ptyRead: 1,
                .parserEvent: 1,
                .screenMutation: 1,
                .renderFrame: 1,
            ],
            ptyReadByteCount: 11,
            parserEventByteCount: 5,
            screenMutationCount: 1,
            renderFrameCount: 1,
            dirtyRegionCount: 3,
            fullRedrawCount: 1,
            firstSequence: 12,
            lastSequence: 15,
            droppedEventCount: 2
        )
        let resize = TerminalResizeCycleSnapshot(
            traceID: "timeline-pipeline",
            source: "runtime-resize",
            viewportSize: TerminalFrameSize(width: 800, height: 400),
            cellSize: TerminalFrameSize(width: 8, height: 16),
            ptyColumns: 100,
            ptyRows: 25,
            screenColumns: 100,
            screenRows: 24,
            rendererColumns: 100,
            rendererRows: 25
        )
        let report = TerminalTraceCorrelationReport(
            eventSummary: summary,
            stageSequence: [.ptyRead, .parserEvent, .screenMutation, .renderFrame],
            resizeSnapshot: resize
        )

        let timeline = report.timelineSummary

        XCTAssertEqual(timeline.traceID, traceID)
        XCTAssertEqual(timeline.stagePath, "ptyRead>parserEvent>screenMutation>renderFrame")
        XCTAssertEqual(timeline.firstSequence, 12)
        XCTAssertEqual(timeline.lastSequence, 15)
        XCTAssertEqual(timeline.resizeIssueCount, 1)
        XCTAssertTrue(timeline.hasCompleteRenderPath)
        XCTAssertEqual(
            timeline.description,
            "trace=timeline-pipeline stages=ptyRead>parserEvent>screenMutation>renderFrame complete=true sequenceRange=12...15 events=4 droppedEvents=2 resizeIssues=1 ptyBytes=11 parserBytes=5 screenMutations=1 renderFrames=1 dirtyRegions=3 fullRedraws=1"
        )
        XCTAssertFalse(timeline.description.contains("CSI"))
        XCTAssertFalse(timeline.description.contains("secret"))
    }

    func testTraceSourceOfTruthDiagnosticExposesMissingStagesWithoutPayloadText() {
        let traceID = TerminalEventTraceID("missing-stage-pipeline")
        let summary = TerminalEventLedger.TraceSummary(
            traceID: traceID,
            eventCount: 2,
            kindCounts: [
                .ptyRead: 1,
                .screenMutation: 1,
            ],
            ptyReadByteCount: 12,
            parserEventByteCount: 0,
            screenMutationCount: 1,
            renderFrameCount: 0,
            dirtyRegionCount: 0,
            fullRedrawCount: 0,
            firstSequence: 4,
            lastSequence: 5,
            droppedEventCount: 0
        )
        let report = TerminalTraceCorrelationReport(
            eventSummary: summary,
            stageSequence: [.ptyRead, .screenMutation]
        )

        let diagnostic = report.sourceOfTruthDiagnostic

        XCTAssertFalse(diagnostic.isSourceOfTruthComplete)
        XCTAssertEqual(diagnostic.missingStages, [.parserEvent, .renderFrame])
        XCTAssertEqual(diagnostic.missingStageNames, ["parserEvent", "renderFrame"])
        XCTAssertEqual(
            diagnostic.description,
            "trace=missing-stage-pipeline sourceOfTruthComplete=false completeRenderPath=false stages=ptyRead>screenMutation missingStages=parserEvent,renderFrame events=2 droppedEvents=0 ptyBytes=12 parserBytes=0 screenMutations=1 renderFrames=0"
        )
        XCTAssertFalse(diagnostic.description.contains("CSI"))
        XCTAssertFalse(diagnostic.description.contains("token=secret"))
    }

    func testTraceSourceOfTruthDiagnosticMarksCompleteOrderedUndroppedTrace() {
        let traceID = TerminalEventTraceID("complete-live-fixture")
        let summary = TerminalEventLedger.TraceSummary(
            traceID: traceID,
            eventCount: 4,
            kindCounts: [
                .ptyRead: 1,
                .parserEvent: 1,
                .screenMutation: 1,
                .renderFrame: 1,
            ],
            ptyReadByteCount: 8,
            parserEventByteCount: 8,
            screenMutationCount: 1,
            renderFrameCount: 1,
            dirtyRegionCount: 1,
            fullRedrawCount: 0,
            firstSequence: 0,
            lastSequence: 3,
            droppedEventCount: 0
        )
        let report = TerminalTraceCorrelationReport(
            eventSummary: summary,
            stageSequence: [.ptyRead, .parserEvent, .screenMutation, .renderFrame]
        )

        let diagnostic = report.sourceOfTruthDiagnostic

        XCTAssertTrue(diagnostic.isSourceOfTruthComplete)
        XCTAssertTrue(diagnostic.missingStages.isEmpty)
        XCTAssertEqual(diagnostic.missingStageNames, [])
        XCTAssertTrue(diagnostic.description.contains("sourceOfTruthComplete=true"))
        XCTAssertTrue(diagnostic.description.contains("missingStages=none"))
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

    func testCoreBridgeReportsMutationSourceContractWhenZigCoreIsUnavailable() {
        let bridge = CoreBridge(cols: 2, rows: 1, loadSymbols: false)
        let diagnostic = bridge.mutationSourceDiagnostic

        XCTAssertEqual(diagnostic.sessionMutationOwner, .swiftScaffold)
        XCTAssertEqual(diagnostic.frameMutationOwner, .swiftScaffold)
        XCTAssertFalse(diagnostic.zigBridgeActive)
        XCTAssertEqual(diagnostic.reason, "zig-core-unavailable")
        XCTAssertTrue(diagnostic.description.contains("sessionMutationOwner=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("frameMutationOwner=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("zigBridgeActive=false"))
        XCTAssertTrue(diagnostic.description.contains("reason=zig-core-unavailable"))
    }

    func testCoreBridgeKeepsSwiftMutationOwnerWhenZigFeedBridgeIsActive() {
        let bridge = CoreBridge(cols: 2, rows: 1)
        let diagnostic = bridge.mutationSourceDiagnostic

        XCTAssertEqual(diagnostic.sessionMutationOwner, .swiftScaffold)
        XCTAssertEqual(diagnostic.frameMutationOwner, .swiftScaffold)
        XCTAssertEqual(diagnostic.zigBridgeActive, diagnostic.reason == "swift-runtime-mutation-with-zig-feed-active")
    }

    func testTerminalCoreFactoryExposesMutationSourceDiagnosticForTypeErasedCore() {
        let core: any TerminalCore = CoreBridge(cols: 2, rows: 1, loadSymbols: false)
        let diagnostic = TerminalCoreFactory.mutationSourceDiagnostic(for: core)

        XCTAssertEqual(diagnostic.sessionMutationOwner, .swiftScaffold)
        XCTAssertEqual(diagnostic.frameMutationOwner, .swiftScaffold)
        XCTAssertFalse(diagnostic.zigBridgeActive)
        XCTAssertEqual(diagnostic.reason, "zig-core-unavailable")
    }

    func testTerminalCoreFactoryReportsUnknownMutationSourceForNonDiagnosingCore() {
        let core: any TerminalCore = NonDiagnosingTerminalCore()
        let diagnostic = TerminalCoreFactory.mutationSourceDiagnostic(for: core)

        XCTAssertEqual(diagnostic.sessionMutationOwner, .unknown)
        XCTAssertEqual(diagnostic.frameMutationOwner, .unknown)
        XCTAssertFalse(diagnostic.zigBridgeActive)
        XCTAssertEqual(diagnostic.reason, "diagnostic-unavailable")
    }

    func testCoreBridgeReportsRuntimeBoundaryContractWhenZigCoreIsUnavailable() {
        let bridge = CoreBridge(cols: 2, rows: 1, loadSymbols: false)
        let diagnostic = bridge.runtimeBoundaryDiagnostic

        XCTAssertEqual(diagnostic.feedBridgeParticipant, .swiftScaffold)
        XCTAssertEqual(diagnostic.parserMutationOwner, .swiftScaffold)
        XCTAssertEqual(diagnostic.screenMutationOwner, .swiftScaffold)
        XCTAssertEqual(diagnostic.renderMutationOwner, .swiftScaffold)
        XCTAssertFalse(diagnostic.mutationHandoffReady)
        XCTAssertEqual(diagnostic.dualWriteRisk, .none)
        XCTAssertEqual(diagnostic.reason, "zig-core-unavailable")
        XCTAssertTrue(diagnostic.description.contains("feedBridgeParticipant=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("parserMutationOwner=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("screenMutationOwner=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("renderMutationOwner=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("mutationHandoffReady=false"))
        XCTAssertTrue(diagnostic.description.contains("dualWriteRisk=none"))
        XCTAssertFalse(diagnostic.description.contains("token=secret"))
    }

    func testCoreBridgeRuntimeBoundaryKeepsSwiftMutationOwnersWhenZigFeedBridgeIsActive() {
        let bridge = CoreBridge(cols: 2, rows: 1)
        let diagnostic = bridge.runtimeBoundaryDiagnostic

        XCTAssertEqual(diagnostic.parserMutationOwner, .swiftScaffold)
        XCTAssertEqual(diagnostic.screenMutationOwner, .swiftScaffold)
        XCTAssertEqual(diagnostic.renderMutationOwner, .swiftScaffold)
        XCTAssertFalse(diagnostic.mutationHandoffReady)
        XCTAssertEqual(
            diagnostic.feedBridgeParticipant == .zigCore,
            diagnostic.dualWriteRisk == .feedBridgeOnly
        )
    }

    func testTerminalCoreFactoryExposesRuntimeBoundaryDiagnosticForTypeErasedCore() {
        let core: any TerminalCore = CoreBridge(cols: 2, rows: 1, loadSymbols: false)
        let diagnostic = TerminalCoreFactory.runtimeBoundaryDiagnostic(for: core)

        XCTAssertEqual(diagnostic.feedBridgeParticipant, .swiftScaffold)
        XCTAssertEqual(diagnostic.parserMutationOwner, .swiftScaffold)
        XCTAssertEqual(diagnostic.screenMutationOwner, .swiftScaffold)
        XCTAssertEqual(diagnostic.renderMutationOwner, .swiftScaffold)
        XCTAssertFalse(diagnostic.mutationHandoffReady)
        XCTAssertEqual(diagnostic.dualWriteRisk, .none)
        XCTAssertEqual(diagnostic.reason, "zig-core-unavailable")
    }

    func testTerminalCoreFactoryReportsUnknownRuntimeBoundaryForNonDiagnosingCore() {
        let core: any TerminalCore = NonDiagnosingTerminalCore()
        let diagnostic = TerminalCoreFactory.runtimeBoundaryDiagnostic(for: core)

        XCTAssertEqual(diagnostic.feedBridgeParticipant, .unknown)
        XCTAssertEqual(diagnostic.parserMutationOwner, .unknown)
        XCTAssertEqual(diagnostic.screenMutationOwner, .unknown)
        XCTAssertEqual(diagnostic.renderMutationOwner, .unknown)
        XCTAssertFalse(diagnostic.mutationHandoffReady)
        XCTAssertEqual(diagnostic.dualWriteRisk, .unknown)
        XCTAssertEqual(diagnostic.reason, "diagnostic-unavailable")
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
