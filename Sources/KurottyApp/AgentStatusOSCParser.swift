import Foundation

/// Chunk-safe parser for Kurotty's out-of-band agent activity channel.
///
/// ## Wire contract
///
/// ```
/// ESC ] 9999 ; <json> BEL
/// ESC ] 9999 ; <json> ESC \        (ST terminator, equally valid)
/// ```
///
/// The JSON payload is a single object:
///
/// ```json
/// { "state": "working|waiting|blocked|done", "agent": "claude", "detail": "running tests" }
/// ```
///
/// - `state` is required and must be one of the four documented values.
///   Unknown values are ignored, not guessed.
/// - `agent` and `detail` are optional display metadata, length-capped by
///   `AppConstants.AgentStatus`.
///
/// ## Behavior contract
///
/// - The sequence is **always** stripped from the visible stream, including
///   malformed, oversized, and unknown-state payloads. It must never render.
/// - A sequence split across PTY reads is reassembled through a bounded carry
///   buffer (`AppConstants.AgentStatus.maximumSequenceBytes`). On overflow the
///   buffered bytes are dropped and the parser discards input up to the next
///   terminator, so an oversized payload can neither grow memory nor leak text.
/// - Only prefixes of `ESC ] 9999 ;` are ever carried, so unrelated escape
///   sequences are passed through untouched (at most a trailing `ESC` waits one
///   chunk, which is unavoidable: the byte is genuinely ambiguous until more
///   input arrives).
/// - Nothing throws. Garbage in produces passthrough text and no status.
///
/// The parser is a value type holding only its carry state, so a pane owns one
/// and there is no shared mutable state.
struct AgentStatusOSCParser {
    private enum Control {
        static let escape: UnicodeScalar = "\u{1B}"
        static let bell: UnicodeScalar = "\u{07}"
        static let stringTerminatorFinal: UnicodeScalar = "\\"
        static let oscIntroducer: UnicodeScalar = "]"
    }

    /// `ESC ] 9999 ;`
    private static let marker: [UnicodeScalar] = {
        var scalars: [UnicodeScalar] = [Control.escape, Control.oscIntroducer]
        scalars.append(contentsOf: AppConstants.AgentStatus.oscNumber.unicodeScalars)
        scalars.append(";")
        return scalars
    }()

    /// Bytes of a partially received sequence, always starting at `ESC`.
    private var carry: [UnicodeScalar] = []
    /// Set after an overflow: input is dropped until the next terminator.
    private var isDiscardingUntilTerminator = false

    init() {}

    var hasPendingCarryForTesting: Bool {
        !carry.isEmpty || isDiscardingUntilTerminator
    }

    /// Splits a PTY chunk into the text that may render and the statuses the
    /// producer reported. Single call site: the pane output path.
    mutating func parse(chunk: String) -> (passthroughText: String, statuses: [AgentActivityStatus]) {
        guard !chunk.isEmpty || !carry.isEmpty else {
            return ("", [])
        }
        var buffer = carry
        carry = []
        buffer.append(contentsOf: chunk.unicodeScalars)

        var passthrough = String.UnicodeScalarView()
        var statuses: [AgentActivityStatus] = []
        var index = 0

        while index < buffer.count {
            if isDiscardingUntilTerminator {
                guard let terminatorEnd = Self.terminatorEnd(in: buffer, from: index) else {
                    // Whole remainder belongs to the discarded sequence.
                    return (String(passthrough), statuses)
                }
                isDiscardingUntilTerminator = false
                index = terminatorEnd
                continue
            }

            guard let escapeIndex = Self.nextEscapeIndex(in: buffer, from: index) else {
                passthrough.append(contentsOf: buffer[index...])
                index = buffer.count
                break
            }
            passthrough.append(contentsOf: buffer[index..<escapeIndex])
            index = escapeIndex

            switch Self.matchMarker(in: buffer, at: index) {
            case .mismatch:
                // Some other escape sequence: emit the ESC and keep scanning.
                passthrough.append(buffer[index])
                index += 1
            case .incomplete:
                if buffer.count - index > AppConstants.AgentStatus.maximumSequenceBytes {
                    isDiscardingUntilTerminator = true
                    index = buffer.count
                    break
                }
                carry = Array(buffer[index...])
                return (String(passthrough), statuses)
            case .matched(let payloadStart):
                guard let terminatorEnd = Self.terminatorEnd(in: buffer, from: payloadStart) else {
                    guard buffer.count - index <= AppConstants.AgentStatus.maximumSequenceBytes else {
                        isDiscardingUntilTerminator = true
                        index = buffer.count
                        break
                    }
                    carry = Array(buffer[index...])
                    return (String(passthrough), statuses)
                }
                let payloadEnd = Self.payloadEnd(in: buffer, terminatorEnd: terminatorEnd)
                if let status = Self.decodeStatus(scalars: buffer[payloadStart..<payloadEnd]) {
                    statuses.append(status)
                }
                index = terminatorEnd
            }
        }

        return (String(passthrough), statuses)
    }

    /// Drops any partially received sequence. Call on PTY restart so a stale
    /// half-sequence cannot merge with fresh output.
    mutating func reset() {
        carry = []
        isDiscardingUntilTerminator = false
    }

    // MARK: - Scanning helpers

    private enum MarkerMatch {
        case matched(payloadStart: Int)
        case incomplete
        case mismatch
    }

    private static func nextEscapeIndex(in buffer: [UnicodeScalar], from start: Int) -> Int? {
        var index = start
        while index < buffer.count {
            if buffer[index] == Control.escape {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func matchMarker(in buffer: [UnicodeScalar], at start: Int) -> MarkerMatch {
        var offset = 0
        while offset < marker.count {
            let bufferIndex = start + offset
            guard bufferIndex < buffer.count else {
                return .incomplete
            }
            guard buffer[bufferIndex] == marker[offset] else {
                return .mismatch
            }
            offset += 1
        }
        return .matched(payloadStart: start + marker.count)
    }

    /// Index just past a BEL or `ESC \` terminator, or `nil` if unterminated.
    private static func terminatorEnd(in buffer: [UnicodeScalar], from start: Int) -> Int? {
        var index = start
        while index < buffer.count {
            if buffer[index] == Control.bell {
                return index + 1
            }
            if buffer[index] == Control.escape {
                guard index + 1 < buffer.count else {
                    return nil
                }
                if buffer[index + 1] == Control.stringTerminatorFinal {
                    return index + 2
                }
            }
            index += 1
        }
        return nil
    }

    private static func payloadEnd(in buffer: [UnicodeScalar], terminatorEnd: Int) -> Int {
        let lastScalarIndex = terminatorEnd - 1
        guard lastScalarIndex >= 0, buffer[lastScalarIndex] == Control.stringTerminatorFinal, terminatorEnd - 2 >= 0
        else {
            return terminatorEnd - 1
        }
        return terminatorEnd - 2
    }

    // MARK: - Payload decoding

    private struct Payload: Decodable {
        let state: String
        let agent: String?
        let detail: String?
    }

    private static func decodeStatus(scalars: ArraySlice<UnicodeScalar>) -> AgentActivityStatus? {
        guard !scalars.isEmpty, scalars.count <= AppConstants.AgentStatus.maximumSequenceBytes else {
            return nil
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let json = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !json.isEmpty, let data = json.data(using: .utf8) else {
            return nil
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        guard let state = AgentActivityState(rawValue: payload.state) else {
            return nil
        }
        return AgentActivityStatus(state: state, agentName: payload.agent, detail: payload.detail)
    }
}

/// Per-pane adapter that turns the parser into a single call on the output path
/// and publishes what it decodes.
///
/// Integration point: `TerminalSurfaceView.shell.onOutput` should route text
/// through `filter(_:)` before it reaches `enqueueOutput`.
@MainActor
final class AgentStatusOutputChannel {
    let paneIdentifier: String
    private var parser = AgentStatusOSCParser()
    private let registry: AgentActivityRegistry

    init(paneIdentifier: String, registry: AgentActivityRegistry = .shared) {
        self.paneIdentifier = paneIdentifier
        self.registry = registry
    }

    /// Returns the text that may render, recording any status it stripped.
    func filter(_ text: String) -> String {
        let result = parser.parse(chunk: text)
        for status in result.statuses {
            registry.record(status, paneIdentifier: paneIdentifier)
        }
        return result.passthroughText
    }

    func reset() {
        parser.reset()
    }
}
