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
    enum EventKind: String, Equatable, CustomStringConvertible {
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

    func events(for traceID: TerminalEventTraceID) -> [Event] {
        events.filter { $0.traceID == traceID }
    }

    func conciseDescription(for traceID: TerminalEventTraceID) -> String {
        let traceEvents = events(for: traceID)
        let eventSummary = traceEvents
            .map { "[\($0.description)]" }
            .joined(separator: " ")
        let prefix = "trace=\(traceID) events=\(traceEvents.count) droppedEvents=\(droppedEventCount)"

        return eventSummary.isEmpty ? prefix : "\(prefix) \(eventSummary)"
    }

    private mutating func append(traceID: TerminalEventTraceID, payload: Payload) {
        let event = Event(sequence: nextSequence, traceID: traceID, payload: payload)
        nextSequence += 1

        guard capacity > 0 else {
            droppedEventCount += 1
            return
        }

        events.append(event)

        if events.count > capacity {
            events.removeFirst(events.count - capacity)
            droppedEventCount = nextSequence - events.count
        }
    }
}
