import Foundation
import KurottyCore

struct TerminalResizeGridSize: Equatable, CustomStringConvertible {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        self.columns = Self.clampedDimension(columns)
        self.rows = Self.clampedDimension(rows)
    }

    var description: String {
        "\(columns)x\(rows)"
    }

    private static func clampedDimension(_ dimension: Int) -> Int {
        min(max(1, dimension), Int(UInt16.max))
    }
}

struct TerminalResizeViewportMeasurement: Equatable, CustomStringConvertible {
    let viewSize: TerminalFrameSize

    var description: String {
        "view=\(Self.format(size: viewSize))"
    }

    private static func format(size: TerminalFrameSize) -> String {
        String(format: "%0.2fx%0.2f", size.width, size.height)
    }
}

struct TerminalResizeCellMetrics: Equatable, CustomStringConvertible {
    let cellSize: TerminalFrameSize

    var description: String {
        "cell=\(Self.format(size: cellSize))"
    }

    private static func format(size: TerminalFrameSize) -> String {
        String(format: "%0.2fx%0.2f", size.width, size.height)
    }
}

struct TerminalResizeRendererSnapshot: Equatable, CustomStringConvertible {
    let gridSize: TerminalResizeGridSize
    let drawableSize: TerminalFrameSize?
    let frameSize: TerminalFrameSize?

    init(
        columns: Int,
        rows: Int,
        drawableSize: TerminalFrameSize? = nil,
        frameSize: TerminalFrameSize? = nil
    ) {
        gridSize = TerminalResizeGridSize(columns: columns, rows: rows)
        self.drawableSize = drawableSize
        self.frameSize = frameSize
    }

    var description: String {
        [
            "renderer=\(gridSize)",
            "drawable=\(format(size: drawableSize))",
            "frame=\(format(size: frameSize))",
        ].joined(separator: " ")
    }

    private func format(size: TerminalFrameSize?) -> String {
        guard let size else { return "unavailable" }
        return String(format: "%0.2fx%0.2f", size.width, size.height)
    }
}

struct TerminalResizeCycleSnapshot: Equatable, CustomStringConvertible {
    let traceID: String?
    let source: String?
    let timestamp: TimeInterval?
    let viewport: TerminalResizeViewportMeasurement
    let cellMetrics: TerminalResizeCellMetrics
    let derivedGrid: TerminalResizeGridSize
    let ptyWinsize: TerminalResizeGridSize
    let screenSize: TerminalResizeGridSize
    let renderer: TerminalResizeRendererSnapshot

    init(
        traceID: String? = nil,
        source: String? = nil,
        timestamp: TimeInterval? = nil,
        viewportSize: TerminalFrameSize,
        cellSize: TerminalFrameSize,
        ptyColumns: Int,
        ptyRows: Int,
        screenColumns: Int,
        screenRows: Int,
        rendererColumns: Int,
        rendererRows: Int,
        rendererDrawableSize: TerminalFrameSize? = nil,
        rendererFrameSize: TerminalFrameSize? = nil
    ) {
        self.traceID = traceID
        self.source = source
        self.timestamp = timestamp
        viewport = TerminalResizeViewportMeasurement(viewSize: viewportSize)
        cellMetrics = TerminalResizeCellMetrics(cellSize: cellSize)
        derivedGrid = Self.deriveGrid(viewportSize: viewportSize, cellSize: cellSize)
        ptyWinsize = TerminalResizeGridSize(columns: ptyColumns, rows: ptyRows)
        screenSize = TerminalResizeGridSize(columns: screenColumns, rows: screenRows)
        renderer = TerminalResizeRendererSnapshot(
            columns: rendererColumns,
            rows: rendererRows,
            drawableSize: rendererDrawableSize,
            frameSize: rendererFrameSize
        )
    }

    var validationReport: TerminalResizeLedgerReport {
        TerminalResizeLedgerReport(snapshot: self)
    }

    var description: String {
        var fields: [String] = []
        if let traceID {
            fields.append("trace=\(traceID)")
        }
        if let source {
            fields.append("source=\(source)")
        }
        if let timestamp {
            fields.append(String(format: "timestamp=%0.3f", timestamp))
        }
        fields.append(viewport.description)
        fields.append(cellMetrics.description)
        fields.append("derived=\(derivedGrid)")
        fields.append("pty=\(ptyWinsize)")
        fields.append("screen=\(screenSize)")
        fields.append(renderer.description)
        fields.append("issues=\(validationReport.issues.count)")
        return fields.joined(separator: " ")
    }

    private static func deriveGrid(viewportSize: TerminalFrameSize, cellSize: TerminalFrameSize) -> TerminalResizeGridSize {
        guard cellSize.width.isFinite,
              cellSize.height.isFinite,
              cellSize.width > 0,
              cellSize.height > 0
        else {
            return TerminalResizeGridSize(columns: 1, rows: 1)
        }
        return TerminalResizeGridSize(
            columns: clampedGridDimension(from: viewportSize.width / cellSize.width),
            rows: clampedGridDimension(from: viewportSize.height / cellSize.height)
        )
    }

    private static func clampedGridDimension(from rawDimension: Double) -> Int {
        guard rawDimension.isFinite, rawDimension > 0 else {
            return 1
        }
        let maximum = Double(UInt16.max)
        guard rawDimension < maximum else {
            return Int(UInt16.max)
        }
        return Int(rawDimension)
    }
}

struct TerminalResizeLedger: CustomStringConvertible {
    struct Diagnostics: Equatable, CustomStringConvertible {
        let capacity: Int
        let retainedSnapshotCount: Int
        let droppedSnapshotCount: Int
        let issueCount: Int

        var description: String {
            [
                "capacity=\(capacity)",
                "retainedSnapshots=\(retainedSnapshotCount)",
                "droppedSnapshots=\(droppedSnapshotCount)",
                "issues=\(issueCount)",
            ].joined(separator: " ")
        }
    }

    let capacity: Int
    private(set) var snapshots: [TerminalResizeCycleSnapshot] = []
    private(set) var droppedSnapshotCount = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    var latestSnapshot: TerminalResizeCycleSnapshot? {
        snapshots.last
    }

    var diagnostics: Diagnostics {
        Diagnostics(
            capacity: capacity,
            retainedSnapshotCount: snapshots.count,
            droppedSnapshotCount: droppedSnapshotCount,
            issueCount: snapshots.reduce(0) { $0 + $1.validationReport.issues.count }
        )
    }

    var description: String {
        "TerminalResizeLedger \(diagnostics.description)"
    }

    mutating func record(_ snapshot: TerminalResizeCycleSnapshot) {
        guard capacity > 0 else {
            droppedSnapshotCount += 1
            return
        }

        snapshots.append(snapshot)
        let overflow = snapshots.count - capacity
        if overflow > 0 {
            droppedSnapshotCount += overflow
            snapshots.removeFirst(overflow)
        }
    }

    func snapshots(for traceID: String) -> [TerminalResizeCycleSnapshot] {
        snapshots.filter { $0.traceID == traceID }
    }
}

struct TerminalResizeLedgerReport: Equatable, CustomStringConvertible {
    let issues: [TerminalResizeLedgerIssue]

    init(snapshot: TerminalResizeCycleSnapshot) {
        issues = TerminalResizeLedgerIssue.issues(for: snapshot)
    }

    var isValid: Bool {
        issues.isEmpty
    }

    var description: String {
        guard !issues.isEmpty else { return "resize-ledger ok" }
        return issues.map(\.description).joined(separator: "; ")
    }
}

enum TerminalResizeLedgerParticipant: String, Equatable, CustomStringConvertible {
    case ptyWinsize = "pty"
    case screenGrid = "screen"
    case rendererGrid = "renderer"

    var description: String {
        rawValue
    }
}

struct TerminalResizeSourceOfTruthSummary: Equatable, CustomStringConvertible {
    let source: String?
    let derivedGrid: TerminalResizeGridSize
    let ptyWinsize: TerminalResizeGridSize
    let screenSize: TerminalResizeGridSize
    let rendererGrid: TerminalResizeGridSize
    let rendererDrawableSize: TerminalFrameSize?
    let rendererFrameSize: TerminalFrameSize?
    let disagreeingParticipants: [TerminalResizeLedgerParticipant]
    let isValid: Bool
    let issueCount: Int

    init(snapshot: TerminalResizeCycleSnapshot) {
        source = snapshot.source
        derivedGrid = snapshot.derivedGrid
        ptyWinsize = snapshot.ptyWinsize
        screenSize = snapshot.screenSize
        rendererGrid = snapshot.renderer.gridSize
        rendererDrawableSize = snapshot.renderer.drawableSize
        rendererFrameSize = snapshot.renderer.frameSize
        let report = snapshot.validationReport
        disagreeingParticipants = Self.disagreeingParticipants(from: report.issues)
        isValid = report.isValid
        issueCount = report.issues.count
    }

    var description: String {
        [
            "source=\(source ?? "unknown")",
            "derived=\(derivedGrid)",
            "pty=\(ptyWinsize)",
            "screen=\(screenSize)",
            "renderer=\(rendererGrid)",
            "drawable=\(Self.format(size: rendererDrawableSize))",
            "frame=\(Self.format(size: rendererFrameSize))",
            "disagree=\(Self.format(participants: disagreeingParticipants))",
            "valid=\(isValid)",
            "issueCount=\(issueCount)",
        ].joined(separator: " ")
    }

    private static func disagreeingParticipants(
        from issues: [TerminalResizeLedgerIssue]
    ) -> [TerminalResizeLedgerParticipant] {
        issues.map { issue in
            switch issue {
            case .ptyMismatch:
                return .ptyWinsize
            case .screenMismatch:
                return .screenGrid
            case .rendererMismatch:
                return .rendererGrid
            }
        }
    }

    private static func format(size: TerminalFrameSize?) -> String {
        guard let size else { return "unavailable" }
        return String(format: "%0.2fx%0.2f", size.width, size.height)
    }

    private static func format(participants: [TerminalResizeLedgerParticipant]) -> String {
        guard !participants.isEmpty else { return "none" }
        return participants.map(\.description).joined(separator: ",")
    }
}

enum TerminalResizeLedgerIssue: Equatable, CustomStringConvertible {
    case ptyMismatch(expected: TerminalResizeGridSize, actual: TerminalResizeGridSize)
    case screenMismatch(expected: TerminalResizeGridSize, actual: TerminalResizeGridSize)
    case rendererMismatch(expected: TerminalResizeGridSize, actual: TerminalResizeGridSize)

    var description: String {
        switch self {
        case let .ptyMismatch(expected, actual):
            return "pty mismatch expected=\(expected) actual=\(actual)"
        case let .screenMismatch(expected, actual):
            return "screen mismatch expected=\(expected) actual=\(actual)"
        case let .rendererMismatch(expected, actual):
            return "renderer mismatch expected=\(expected) actual=\(actual)"
        }
    }

    fileprivate static func issues(for snapshot: TerminalResizeCycleSnapshot) -> [TerminalResizeLedgerIssue] {
        var issues: [TerminalResizeLedgerIssue] = []
        if snapshot.ptyWinsize != snapshot.derivedGrid {
            issues.append(.ptyMismatch(expected: snapshot.derivedGrid, actual: snapshot.ptyWinsize))
        }
        if snapshot.screenSize != snapshot.derivedGrid {
            issues.append(.screenMismatch(expected: snapshot.derivedGrid, actual: snapshot.screenSize))
        }
        if snapshot.renderer.gridSize != snapshot.derivedGrid {
            issues.append(.rendererMismatch(expected: snapshot.derivedGrid, actual: snapshot.renderer.gridSize))
        }
        return issues
    }
}
