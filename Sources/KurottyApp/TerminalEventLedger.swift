import Foundation

struct TerminalEventTraceID: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.init(value)
    }

    var description: String {
        rawValue
    }
}

struct TerminalEventLedger: CustomStringConvertible {
    enum EventKind: String, CaseIterable, Equatable, CustomStringConvertible {
        case ptyRead
        case parserEvent
        case screenMutation
        case renderFrame

        var description: String {
            rawValue
        }
    }

    enum ParserEvent: Equatable, CustomStringConvertible {
        case printable(byteCount: Int)
        case control(kind: String, byteCount: Int)
        case escapeSequence(kind: String, byteCount: Int)
        case osc(command: String, byteCount: Int)

        var byteCount: Int {
            switch self {
            case let .printable(byteCount):
                return byteCount
            case let .control(_, byteCount):
                return byteCount
            case let .escapeSequence(_, byteCount):
                return byteCount
            case let .osc(_, byteCount):
                return byteCount
            }
        }

        var description: String {
            switch self {
            case let .printable(byteCount):
                return "printable bytes=\(byteCount)"
            case let .control(kind, byteCount):
                return "control kind=\(kind) bytes=\(byteCount)"
            case let .escapeSequence(kind, byteCount):
                return "escapeSequence kind=\(kind) bytes=\(byteCount)"
            case let .osc(command, byteCount):
                return "osc command=\(command) bytes=\(byteCount)"
            }
        }
    }

    enum ScreenMutation: Equatable, CustomStringConvertible {
        case writeCells(cellCount: Int)
        case eraseInDisplay(rowsAffected: Int)
        case scroll(rowsAffected: Int)
        case resize(columns: Int, rows: Int)

        var description: String {
            switch self {
            case let .writeCells(cellCount):
                return "writeCells cells=\(cellCount)"
            case let .eraseInDisplay(rowsAffected):
                return "eraseInDisplay rows=\(rowsAffected)"
            case let .scroll(rowsAffected):
                return "scroll rows=\(rowsAffected)"
            case let .resize(columns, rows):
                return "resize columns=\(columns) rows=\(rows)"
            }
        }
    }

    struct RenderFrame: Equatable, CustomStringConvertible {
        let frameIndex: Int
        let dirtyRegionCount: Int
        let fullRedraw: Bool

        var description: String {
            "frame=\(frameIndex) dirtyRegions=\(dirtyRegionCount) fullRedraw=\(fullRedraw)"
        }
    }

    struct RecordedEvent: Equatable {
        let traceID: TerminalEventTraceID
        let payload: Payload

        static func ptyRead(traceID: TerminalEventTraceID, byteCount: Int) -> RecordedEvent {
            RecordedEvent(traceID: traceID, payload: .ptyRead(byteCount: byteCount))
        }

        static func parserEvent(traceID: TerminalEventTraceID, event: ParserEvent) -> RecordedEvent {
            RecordedEvent(traceID: traceID, payload: .parserEvent(event))
        }

        static func screenMutation(traceID: TerminalEventTraceID, mutation: ScreenMutation) -> RecordedEvent {
            RecordedEvent(traceID: traceID, payload: .screenMutation(mutation))
        }

        static func renderFrame(traceID: TerminalEventTraceID, frame: RenderFrame) -> RecordedEvent {
            RecordedEvent(traceID: traceID, payload: .renderFrame(frame))
        }
    }

    struct Event: Equatable, CustomStringConvertible {
        let sequence: Int
        let traceID: TerminalEventTraceID
        let payload: Payload

        var kind: EventKind {
            payload.kind
        }

        var description: String {
            "#\(sequence) \(kind) \(payload)"
        }
    }

    struct TraceSummary: Equatable, CustomStringConvertible {
        let traceID: TerminalEventTraceID
        let eventCount: Int
        let kindCounts: [EventKind: Int]
        let ptyReadByteCount: Int
        let parserEventByteCount: Int
        let screenMutationCount: Int
        let renderFrameCount: Int
        let dirtyRegionCount: Int
        let fullRedrawCount: Int
        let firstSequence: Int?
        let lastSequence: Int?
        let droppedEventCount: Int

        var description: String {
            let kindSummary = EventKind.allCases
                .map { "\($0)=\(kindCounts[$0, default: 0])" }
                .joined(separator: " ")

            return [
                "trace=\(traceID)",
                "events=\(eventCount)",
                kindSummary,
                "ptyBytes=\(ptyReadByteCount)",
                "parserBytes=\(parserEventByteCount)",
                "screenMutations=\(screenMutationCount)",
                "renderFrames=\(renderFrameCount)",
                "dirtyRegions=\(dirtyRegionCount)",
                "fullRedraws=\(fullRedrawCount)",
                "firstSequence=\(firstSequence.map(String.init) ?? "nil")",
                "lastSequence=\(lastSequence.map(String.init) ?? "nil")",
                "droppedEvents=\(droppedEventCount)",
            ].joined(separator: " ")
        }
    }

    struct Diagnostics: Equatable, CustomStringConvertible {
        let capacity: Int
        let retainedEventCount: Int
        let droppedEventCount: Int
        let firstRetainedSequence: Int?
        let nextSequence: Int

        var description: String {
            [
                "capacity=\(capacity)",
                "retainedEvents=\(retainedEventCount)",
                "droppedEvents=\(droppedEventCount)",
                "firstRetainedSequence=\(firstRetainedSequence.map(String.init) ?? "nil")",
                "nextSequence=\(nextSequence)",
            ].joined(separator: " ")
        }
    }

    enum Payload: Equatable, CustomStringConvertible {
        case ptyRead(byteCount: Int)
        case parserEvent(ParserEvent)
        case screenMutation(ScreenMutation)
        case renderFrame(RenderFrame)

        var kind: EventKind {
            switch self {
            case .ptyRead:
                return .ptyRead
            case .parserEvent:
                return .parserEvent
            case .screenMutation:
                return .screenMutation
            case .renderFrame:
                return .renderFrame
            }
        }

        var description: String {
            switch self {
            case let .ptyRead(byteCount):
                return "bytes=\(byteCount)"
            case let .parserEvent(event):
                return event.description
            case let .screenMutation(mutation):
                return mutation.description
            case let .renderFrame(frame):
                return frame.description
            }
        }
    }

    let capacity: Int
    private(set) var events: [Event] = []
    private var nextSequence = 0
    private var droppedEventCount = 0
    private var droppedEventCountsByTraceID: [TerminalEventTraceID: Int] = [:]

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    var diagnostics: Diagnostics {
        Diagnostics(
            capacity: capacity,
            retainedEventCount: events.count,
            droppedEventCount: droppedEventCount,
            firstRetainedSequence: events.first?.sequence,
            nextSequence: nextSequence
        )
    }

    var eventsByTraceID: [TerminalEventTraceID: [Event]] {
        Dictionary(grouping: events, by: \.traceID)
    }

    var traceSummariesByTraceID: [TerminalEventTraceID: TraceSummary] {
        eventsByTraceID.mapValues { traceEvents in
            makeSummary(traceID: traceEvents[0].traceID, events: traceEvents)
        }
    }

    var description: String {
        "TerminalEventLedger \(diagnostics.description)"
    }

    mutating func recordPtyRead(traceID: TerminalEventTraceID, data: Data) {
        recordPtyRead(traceID: traceID, byteCount: data.count)
    }

    mutating func recordPtyRead(traceID: TerminalEventTraceID, byteCount: Int) {
        append(traceID: traceID, payload: .ptyRead(byteCount: byteCount))
    }

    mutating func recordParserEvent(traceID: TerminalEventTraceID, event: ParserEvent) {
        append(traceID: traceID, payload: .parserEvent(event))
    }

    mutating func recordScreenMutation(traceID: TerminalEventTraceID, mutation: ScreenMutation) {
        append(traceID: traceID, payload: .screenMutation(mutation))
    }

    mutating func recordRenderFrame(traceID: TerminalEventTraceID, frame: RenderFrame) {
        append(traceID: traceID, payload: .renderFrame(frame))
    }

    @discardableResult
    mutating func recordBatch(_ recordedEvents: [RecordedEvent]) -> [Event] {
        recordedEvents.map { append(traceID: $0.traceID, payload: $0.payload) }
    }

    func events(for traceID: TerminalEventTraceID) -> [Event] {
        events.filter { $0.traceID == traceID }
    }

    func summary(for traceID: TerminalEventTraceID) -> TraceSummary {
        makeSummary(traceID: traceID, events: events(for: traceID))
    }

    func traceCorrelationReport(
        for traceID: TerminalEventTraceID,
        resizeSnapshot: TerminalResizeCycleSnapshot? = nil
    ) -> TerminalTraceCorrelationReport {
        let traceEvents = events(for: traceID)
        return TerminalTraceCorrelationReport(
            eventSummary: makeSummary(traceID: traceID, events: traceEvents),
            stageSequence: traceEvents.map(\.kind),
            resizeSnapshot: resizeSnapshot
        )
    }

    func conciseDescription(for traceID: TerminalEventTraceID) -> String {
        let traceEvents = events(for: traceID)
        let eventSummary = traceEvents
            .map { "[\($0.description)]" }
            .joined(separator: " ")
        let prefix = "trace=\(traceID) events=\(traceEvents.count) droppedEvents=\(droppedEventCount)"

        return eventSummary.isEmpty ? prefix : "\(prefix) \(eventSummary)"
    }

    private func makeSummary(traceID: TerminalEventTraceID, events traceEvents: [Event]) -> TraceSummary {
        let kindCounts = Dictionary(grouping: traceEvents, by: \.kind)
            .mapValues(\.count)

        let ptyReadByteCount = traceEvents.reduce(0) { count, event in
            guard case let .ptyRead(byteCount) = event.payload else {
                return count
            }
            return count + byteCount
        }

        let parserEventByteCount = traceEvents.reduce(0) { count, event in
            guard case let .parserEvent(parserEvent) = event.payload else {
                return count
            }
            return count + parserEvent.byteCount
        }

        let renderFrames = traceEvents.compactMap { event -> RenderFrame? in
            guard case let .renderFrame(frame) = event.payload else {
                return nil
            }
            return frame
        }

        return TraceSummary(
            traceID: traceID,
            eventCount: traceEvents.count,
            kindCounts: kindCounts,
            ptyReadByteCount: ptyReadByteCount,
            parserEventByteCount: parserEventByteCount,
            screenMutationCount: kindCounts[.screenMutation, default: 0],
            renderFrameCount: renderFrames.count,
            dirtyRegionCount: renderFrames.reduce(0) { $0 + $1.dirtyRegionCount },
            fullRedrawCount: renderFrames.filter(\.fullRedraw).count,
            firstSequence: traceEvents.first?.sequence,
            lastSequence: traceEvents.last?.sequence,
            droppedEventCount: droppedEventCountsByTraceID[traceID, default: 0]
        )
    }

    @discardableResult
    private mutating func append(traceID: TerminalEventTraceID, payload: Payload) -> Event {
        let event = Event(sequence: nextSequence, traceID: traceID, payload: payload)
        nextSequence += 1

        guard capacity > 0 else {
            droppedEventCount += 1
            droppedEventCountsByTraceID[traceID, default: 0] += 1
            return event
        }

        events.append(event)

        if events.count > capacity {
            let overflowCount = events.count - capacity
            recordDroppedEvents(events.prefix(overflowCount))
            events.removeFirst(overflowCount)
            droppedEventCount = nextSequence - events.count
        }

        return event
    }

    private mutating func recordDroppedEvents(_ droppedEvents: ArraySlice<Event>) {
        for event in droppedEvents {
            droppedEventCountsByTraceID[event.traceID, default: 0] += 1
        }
    }
}

struct TerminalRuntimeEventBatch: CustomStringConvertible {
    let traceID: TerminalEventTraceID
    let capacity: Int
    private(set) var recordedEvents: [TerminalEventLedger.RecordedEvent] = []
    private(set) var droppedEventCount = 0

    init(traceID: TerminalEventTraceID, capacity: Int = 1_024) {
        self.traceID = traceID
        self.capacity = max(0, capacity)
    }

    var summary: TerminalEventLedger.TraceSummary {
        let kindCounts = Dictionary(grouping: recordedEvents, by: \.payload.kind)
            .mapValues(\.count)

        let ptyReadByteCount = recordedEvents.reduce(0) { count, event in
            guard case let .ptyRead(byteCount) = event.payload else {
                return count
            }
            return count + byteCount
        }

        let parserEventByteCount = recordedEvents.reduce(0) { count, event in
            guard case let .parserEvent(parserEvent) = event.payload else {
                return count
            }
            return count + parserEvent.byteCount
        }

        let renderFrames = recordedEvents.compactMap { event -> TerminalEventLedger.RenderFrame? in
            guard case let .renderFrame(frame) = event.payload else {
                return nil
            }
            return frame
        }

        return TerminalEventLedger.TraceSummary(
            traceID: traceID,
            eventCount: recordedEvents.count,
            kindCounts: kindCounts,
            ptyReadByteCount: ptyReadByteCount,
            parserEventByteCount: parserEventByteCount,
            screenMutationCount: kindCounts[.screenMutation, default: 0],
            renderFrameCount: renderFrames.count,
            dirtyRegionCount: renderFrames.reduce(0) { $0 + $1.dirtyRegionCount },
            fullRedrawCount: renderFrames.filter(\.fullRedraw).count,
            firstSequence: nil,
            lastSequence: nil,
            droppedEventCount: droppedEventCount
        )
    }

    var description: String {
        summary.description
    }

    mutating func recordPtyRead(metadata: TerminalRawPtyLogMetadata) {
        recordPtyRead(byteCount: metadata.byteCount)
    }

    mutating func recordPtyRead(byteCount: Int) {
        append(.ptyRead(traceID: traceID, byteCount: byteCount))
    }

    mutating func recordParserEvent(_ event: TerminalEventLedger.ParserEvent) {
        append(.parserEvent(traceID: traceID, event: event))
    }

    mutating func recordScreenMutation(_ mutation: TerminalEventLedger.ScreenMutation) {
        append(.screenMutation(traceID: traceID, mutation: mutation))
    }

    mutating func recordRenderFrame(_ frame: TerminalEventLedger.RenderFrame) {
        append(.renderFrame(traceID: traceID, frame: frame))
    }

    @discardableResult
    func commit(to ledger: inout TerminalEventLedger) -> TerminalEventLedger.TraceSummary {
        ledger.recordBatch(recordedEvents)
        return ledger.summary(for: traceID)
    }

    private mutating func append(_ event: TerminalEventLedger.RecordedEvent) {
        guard capacity > 0 else {
            droppedEventCount += 1
            return
        }

        recordedEvents.append(event)
        let overflow = recordedEvents.count - capacity
        if overflow > 0 {
            droppedEventCount += overflow
            recordedEvents.removeFirst(overflow)
        }
    }
}
