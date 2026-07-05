import Foundation
import KurottyCore
import simd

struct TerminalNotificationLogMetadata: CustomStringConvertible {
    let identifierPrefix: String
    let titleLength: Int
    let subtitleLength: Int
    let bodyLength: Int

    init(identifierPrefix: String, title: String, subtitle: String = "", body: String) {
        self.identifierPrefix = identifierPrefix
        titleLength = title.count
        subtitleLength = subtitle.count
        bodyLength = body.count
    }

    var description: String {
        "identifierPrefix=\(identifierPrefix) titleLength=\(titleLength) subtitleLength=\(subtitleLength) bodyLength=\(bodyLength)"
    }
}

struct TerminalRawPtyLogMetadata: CustomStringConvertible, Sendable {
    let byteCount: Int

    init(data: Data) {
        byteCount = data.count
    }

    var description: String {
        "byteCount=\(byteCount)"
    }
}

enum TerminalCoreStateSource: String {
    case zigCore = "zig-core"
    case swiftScaffold = "swift-scaffold"
    case unknown = "unknown"
}

struct TerminalCoreCompatibilityDiagnostic: CustomStringConvertible {
    let bridge: TerminalCoreStateSource
    let pty: TerminalCoreStateSource
    let parser: TerminalCoreStateSource
    let screen: TerminalCoreStateSource
    let render: TerminalCoreStateSource

    var description: String {
        [
            "bridge=\(bridge.rawValue)",
            "pty=\(pty.rawValue)",
            "parser=\(parser.rawValue)",
            "screen=\(screen.rawValue)",
            "render=\(render.rawValue)",
        ].joined(separator: " ")
    }
}

protocol TerminalCoreCompatibilityDiagnosing {
    var compatibilityDiagnostic: TerminalCoreCompatibilityDiagnostic { get }
}

struct TerminalCoreMutationSourceDiagnostic: Equatable, CustomStringConvertible {
    let sessionMutationOwner: TerminalCoreStateSource
    let frameMutationOwner: TerminalCoreStateSource
    let zigBridgeActive: Bool
    let reason: String

    var description: String {
        [
            "sessionMutationOwner=\(sessionMutationOwner.rawValue)",
            "frameMutationOwner=\(frameMutationOwner.rawValue)",
            "zigBridgeActive=\(zigBridgeActive)",
            "reason=\(reason)",
        ].joined(separator: " ")
    }
}

protocol TerminalCoreMutationSourceDiagnosing {
    var mutationSourceDiagnostic: TerminalCoreMutationSourceDiagnostic { get }
}

enum TerminalCoreDualWriteRiskStatus: String {
    case none = "none"
    case feedBridgeOnly = "feed-bridge-only"
    case unknown = "unknown"
}

struct TerminalCoreRuntimeBoundaryDiagnostic: Equatable, CustomStringConvertible {
    let feedBridgeParticipant: TerminalCoreStateSource
    let parserMutationOwner: TerminalCoreStateSource
    let screenMutationOwner: TerminalCoreStateSource
    let renderMutationOwner: TerminalCoreStateSource
    let mutationHandoffReady: Bool
    let dualWriteRisk: TerminalCoreDualWriteRiskStatus
    let reason: String

    var description: String {
        [
            "feedBridgeParticipant=\(feedBridgeParticipant.rawValue)",
            "parserMutationOwner=\(parserMutationOwner.rawValue)",
            "screenMutationOwner=\(screenMutationOwner.rawValue)",
            "renderMutationOwner=\(renderMutationOwner.rawValue)",
            "mutationHandoffReady=\(mutationHandoffReady)",
            "dualWriteRisk=\(dualWriteRisk.rawValue)",
            "reason=\(reason)",
        ].joined(separator: " ")
    }
}

protocol TerminalCoreRuntimeBoundaryDiagnosing {
    var runtimeBoundaryDiagnostic: TerminalCoreRuntimeBoundaryDiagnostic { get }
}

struct TerminalTraceCorrelationReport: Equatable, CustomStringConvertible {
    let traceID: TerminalEventTraceID
    let eventSummary: TerminalEventLedger.TraceSummary
    let stageSequence: [TerminalEventLedger.EventKind]
    let resizeSourceOfTruth: TerminalResizeSourceOfTruthSummary?
    let resizeValidationIssues: [TerminalResizeLedgerIssue]

    init(
        eventSummary: TerminalEventLedger.TraceSummary,
        stageSequence: [TerminalEventLedger.EventKind],
        resizeSnapshot: TerminalResizeCycleSnapshot? = nil
    ) {
        traceID = eventSummary.traceID
        self.eventSummary = eventSummary
        self.stageSequence = stageSequence
        if let resizeSnapshot {
            resizeSourceOfTruth = TerminalResizeSourceOfTruthSummary(snapshot: resizeSnapshot)
            resizeValidationIssues = resizeSnapshot.validationReport.issues
        } else {
            resizeSourceOfTruth = nil
            resizeValidationIssues = []
        }
    }

    var hasCompleteRenderPath: Bool {
        containsOrderedStages([
            .ptyRead,
            .parserEvent,
            .screenMutation,
            .renderFrame,
        ])
    }

    var timelineSummary: TerminalTraceTimelineSummary {
        TerminalTraceTimelineSummary(report: self)
    }

    var sourceOfTruthDiagnostic: TerminalTraceSourceOfTruthDiagnostic {
        TerminalTraceSourceOfTruthDiagnostic(report: self)
    }

    var description: String {
        [
            "trace=\(traceID)",
            "path=\(stageSequence.map(\.description).joined(separator: ">"))",
            "complete=\(hasCompleteRenderPath)",
            "resize=\(resizeSourceOfTruth?.description ?? "unavailable")",
            "issues=\(resizeValidationIssues.count)",
            "ptyBytes=\(eventSummary.ptyReadByteCount)",
            "parserBytes=\(eventSummary.parserEventByteCount)",
            "screenMutations=\(eventSummary.screenMutationCount)",
            "renderFrames=\(eventSummary.renderFrameCount)",
            "dirtyRegions=\(eventSummary.dirtyRegionCount)",
            "fullRedraws=\(eventSummary.fullRedrawCount)",
            "droppedEvents=\(eventSummary.droppedEventCount)",
        ].joined(separator: " ")
    }

    private func containsOrderedStages(_ expectedStages: [TerminalEventLedger.EventKind]) -> Bool {
        var searchStart = stageSequence.startIndex
        for expectedStage in expectedStages {
            guard let matchIndex = stageSequence[searchStart...].firstIndex(of: expectedStage) else {
                return false
            }
            searchStart = stageSequence.index(after: matchIndex)
        }
        return true
    }
}

struct TerminalTraceSourceOfTruthDiagnostic: Equatable, CustomStringConvertible {
    static let requiredRenderPathStages: [TerminalEventLedger.EventKind] = [
        .ptyRead,
        .parserEvent,
        .screenMutation,
        .renderFrame,
    ]

    let timelineSummary: TerminalTraceTimelineSummary
    let requiredStages: [TerminalEventLedger.EventKind]
    let missingStages: [TerminalEventLedger.EventKind]

    init(
        report: TerminalTraceCorrelationReport,
        requiredStages: [TerminalEventLedger.EventKind] = Self.requiredRenderPathStages
    ) {
        timelineSummary = report.timelineSummary
        self.requiredStages = requiredStages
        missingStages = requiredStages.filter { !report.stageSequence.contains($0) }
    }

    var traceID: TerminalEventTraceID {
        timelineSummary.traceID
    }

    var missingStageNames: [String] {
        missingStages.map(\.description)
    }

    var isSourceOfTruthComplete: Bool {
        missingStages.isEmpty
            && timelineSummary.hasCompleteRenderPath
            && timelineSummary.droppedEventCount == 0
    }

    var description: String {
        [
            "trace=\(traceID)",
            "sourceOfTruthComplete=\(isSourceOfTruthComplete)",
            "completeRenderPath=\(timelineSummary.hasCompleteRenderPath)",
            "stages=\(timelineSummary.stagePath)",
            "missingStages=\(missingStageDescription)",
            "events=\(timelineSummary.eventCount)",
            "droppedEvents=\(timelineSummary.droppedEventCount)",
            "ptyBytes=\(timelineSummary.ptyReadByteCount)",
            "parserBytes=\(timelineSummary.parserEventByteCount)",
            "screenMutations=\(timelineSummary.screenMutationCount)",
            "renderFrames=\(timelineSummary.renderFrameCount)",
        ].joined(separator: " ")
    }

    private var missingStageDescription: String {
        let names = missingStageNames
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

struct TerminalTraceTimelineSummary: Equatable, CustomStringConvertible {
    let traceID: TerminalEventTraceID
    let stageSequence: [TerminalEventLedger.EventKind]
    let hasCompleteRenderPath: Bool
    let firstSequence: Int?
    let lastSequence: Int?
    let eventCount: Int
    let droppedEventCount: Int
    let resizeIssueCount: Int
    let ptyReadByteCount: Int
    let parserEventByteCount: Int
    let screenMutationCount: Int
    let renderFrameCount: Int
    let dirtyRegionCount: Int
    let fullRedrawCount: Int

    init(report: TerminalTraceCorrelationReport) {
        traceID = report.traceID
        stageSequence = report.stageSequence
        hasCompleteRenderPath = report.hasCompleteRenderPath
        firstSequence = report.eventSummary.firstSequence
        lastSequence = report.eventSummary.lastSequence
        eventCount = report.eventSummary.eventCount
        droppedEventCount = report.eventSummary.droppedEventCount
        resizeIssueCount = report.resizeValidationIssues.count
        ptyReadByteCount = report.eventSummary.ptyReadByteCount
        parserEventByteCount = report.eventSummary.parserEventByteCount
        screenMutationCount = report.eventSummary.screenMutationCount
        renderFrameCount = report.eventSummary.renderFrameCount
        dirtyRegionCount = report.eventSummary.dirtyRegionCount
        fullRedrawCount = report.eventSummary.fullRedrawCount
    }

    var stagePath: String {
        stageSequence.map(\.description).joined(separator: ">")
    }

    var description: String {
        [
            "trace=\(traceID)",
            "stages=\(stagePath)",
            "complete=\(hasCompleteRenderPath)",
            "sequenceRange=\(sequenceRangeDescription)",
            "events=\(eventCount)",
            "droppedEvents=\(droppedEventCount)",
            "resizeIssues=\(resizeIssueCount)",
            "ptyBytes=\(ptyReadByteCount)",
            "parserBytes=\(parserEventByteCount)",
            "screenMutations=\(screenMutationCount)",
            "renderFrames=\(renderFrameCount)",
            "dirtyRegions=\(dirtyRegionCount)",
            "fullRedraws=\(fullRedrawCount)",
        ].joined(separator: " ")
    }

    private var sequenceRangeDescription: String {
        guard let firstSequence, let lastSequence else {
            return "unavailable"
        }
        return "\(firstSequence)...\(lastSequence)"
    }
}

enum TerminalScreenDiagnostics {
    static func occupiedCellCount(in cells: [TerminalScreenCell]) -> Int {
        cells.reduce(0) { count, cell in
            cell.character == " " && cell.style == .default && !cell.isContinuation ? count : count + 1
        }
    }

    static func styleRuns(for styles: [TerminalTextStyle], background: Bool) -> String {
        guard !styles.isEmpty else { return "[]" }
        var runs: [String] = []
        var start = 0
        var color = colorForStyle(styles[0], background: background)
        for index in 1..<styles.count {
            let next = colorForStyle(styles[index], background: background)
            if !sameColor(next, color) {
                runs.append("\(start)-\(index - 1):\(debugRGB(color))")
                start = index
                color = next
            }
        }
        runs.append("\(start)-\(styles.count - 1):\(debugRGB(color))")
        return "[" + runs.joined(separator: ", ") + "]"
    }

    private static func colorForStyle(_ style: TerminalTextStyle, background: Bool) -> SIMD4<Float> {
        background ? style.effectiveBackground : style.effectiveForeground
    }

    private static func sameColor(_ lhs: SIMD4<Float>, _ rhs: SIMD4<Float>) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z && lhs.w == rhs.w
    }

    private static func debugRGB(_ color: SIMD4<Float>) -> String {
        String(format: "(%0.3f,%0.3f,%0.3f,%0.3f)", color.x, color.y, color.z, color.w)
    }
}
