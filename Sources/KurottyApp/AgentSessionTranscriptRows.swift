import Foundation

/// A tool call together with the result that answered it.
///
/// Transcript blocks carry no tool identifiers, so calls and results pair by
/// FIFO ordinal exactly as the agent emitted them.
struct AgentTranscriptToolRun: Equatable, Sendable {
    var call: AgentTranscriptToolCall?
    var result: AgentTranscriptToolResult?

    /// Row label, for example `Edit  src/foo.swift`.
    var summary: String {
        guard let call else {
            return ""
        }
        return call.preview.isEmpty ? call.name : "\(call.name)  \(call.preview)"
    }
}

/// One row in the transcript list.
///
/// Tool runs are flat inline rows, not boxed cards: a collapsed run is a single
/// `▸ Edit  src/foo.swift` line that expands in place, so a turn with ten tool
/// calls stays readable instead of turning into ten nested panels.
enum AgentTranscriptRow: Equatable, Sendable {
    /// Role banner starting a turn.
    case turnHeader(id: String, role: AgentTranscriptRole, timestamp: Date?)
    case text(id: String, role: AgentTranscriptRole, text: String)
    case toolRun(id: String, run: AgentTranscriptToolRun, isExpanded: Bool)
    /// Expanded body of the tool run immediately above.
    case toolDetail(id: String, detail: String)
    case toolDiff(id: String, diff: AgentTranscriptDiff)
    case toolOutput(id: String, output: String, isError: Bool)

    var id: String {
        switch self {
        case let .turnHeader(id, _, _),
             let .text(id, _, _),
             let .toolRun(id, _, _),
             let .toolDetail(id, _),
             let .toolDiff(id, _),
             let .toolOutput(id, _, _):
            return id
        }
    }
}

/// Which tool runs the user has opened. Collapsed is the default so a long
/// session opens as a readable conversation rather than a wall of JSON.
struct AgentTranscriptFoldState: Equatable, Sendable {
    private var expandedRunIDs: Set<String> = []

    init(expandedRunIDs: Set<String> = []) {
        self.expandedRunIDs = expandedRunIDs
    }

    func isExpanded(_ runID: String) -> Bool {
        expandedRunIDs.contains(runID)
    }

    /// Toggles a run and reports its new state.
    @discardableResult
    mutating func toggle(_ runID: String) -> Bool {
        guard expandedRunIDs.contains(runID) else {
            expandedRunIDs.insert(runID)
            return true
        }
        expandedRunIDs.remove(runID)
        return false
    }

    mutating func collapseAll() {
        expandedRunIDs.removeAll()
    }
}

/// Pure message-list to row-list projection. Free of AppKit so folding,
/// pairing, and noise filtering stay unit testable.
enum AgentTranscriptRowBuilder {
    private enum Separator {
        static let runID = "#run-"
        static let detailID = "#detail"
        static let diffID = "#diff"
        static let outputID = "#output"
        static let headerID = "#header"
        static let textID = "#text-"
    }

    /// Merges tool-only turns into the assistant turn they belong to, so a
    /// tool result never opens a new visual turn of its own.
    static func folded(_ messages: [AgentTranscriptMessage]) -> [AgentTranscriptMessage] {
        var output: [AgentTranscriptMessage] = []
        for message in messages {
            guard message.isToolOnly,
                  let previous = output.last,
                  previous.role == .assistant
            else {
                output.append(message)
                continue
            }
            output[output.count - 1].blocks += message.blocks
        }
        return output
    }

    /// Pairs tool calls with results by FIFO ordinal.
    static func toolRuns(in blocks: [AgentTranscriptBlock]) -> [AgentTranscriptToolRun] {
        var runs: [AgentTranscriptToolRun] = []
        var callSlots: [Int] = []
        var resultOrdinal = 0
        for block in blocks {
            switch block {
            case .text:
                continue
            case let .toolCall(call):
                callSlots.append(runs.count)
                runs.append(AgentTranscriptToolRun(call: call))
            case let .toolResult(result):
                guard resultOrdinal < callSlots.count else {
                    runs.append(AgentTranscriptToolRun(result: result))
                    continue
                }
                runs[callSlots[resultOrdinal]].result = result
                resultOrdinal += 1
            }
        }
        return runs
    }

    /// Full projection: noise filtered, tool turns folded, rows expanded
    /// according to `foldState`.
    static func rows(
        messages: [AgentTranscriptMessage],
        foldState: AgentTranscriptFoldState = AgentTranscriptFoldState()
    ) -> [AgentTranscriptRow] {
        var rows: [AgentTranscriptRow] = []
        for message in folded(AgentTranscriptNoise.stripped(messages)) {
            rows.append(.turnHeader(
                id: message.id + Separator.headerID,
                role: message.role,
                timestamp: message.timestamp
            ))
            for (index, block) in message.blocks.enumerated() {
                guard case let .text(text) = block else {
                    continue
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    continue
                }
                rows.append(.text(
                    id: "\(message.id)\(Separator.textID)\(index)",
                    role: message.role,
                    text: trimmed
                ))
            }
            for (index, run) in toolRuns(in: message.blocks).enumerated() {
                let runID = "\(message.id)\(Separator.runID)\(index)"
                let isExpanded = foldState.isExpanded(runID)
                rows.append(.toolRun(id: runID, run: run, isExpanded: isExpanded))
                guard isExpanded else {
                    continue
                }
                if let diff = run.call?.diff {
                    rows.append(.toolDiff(id: runID + Separator.diffID, diff: diff))
                } else if let detail = run.call?.detail, !detail.isEmpty {
                    rows.append(.toolDetail(id: runID + Separator.detailID, detail: detail))
                }
                if let result = run.result, !result.output.isEmpty {
                    rows.append(.toolOutput(
                        id: runID + Separator.outputID,
                        output: result.output,
                        isError: result.isError
                    ))
                }
            }
        }
        return rows
    }
}
