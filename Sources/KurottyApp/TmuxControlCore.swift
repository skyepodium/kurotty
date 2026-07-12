import Foundation

enum TmuxControlEvent: Equatable, Sendable {
    case entered
    case exited(reason: String?)
    case locallyAborted(reason: String)
    case blockBegan(timestamp: UInt64, number: UInt64, flags: UInt64)
    case blockEnded(timestamp: UInt64, number: UInt64, flags: UInt64)
    case blockFailed(timestamp: UInt64, number: UInt64, flags: UInt64)
    case output(paneID: String, data: Data)
    case windowAdded(id: String)
    case windowClosed(id: String)
    case windowRenamed(id: String, name: String)
    case windowOrderChanged(ids: [String])
    case layoutChanged(
        windowID: String,
        layout: TmuxLayoutNode,
        visibleLayout: TmuxLayoutNode,
        flags: String
    )
    case sessionChanged(id: String, name: String)
    case sessionRenamed(id: String?, name: String)
    case sessionsChanged
    case clientSessionChanged(clientID: String, sessionID: String, name: String)
    case activeWindowChanged(sessionID: String, windowID: String)
    case activePaneChanged(windowID: String, paneID: String)
    case paneFocused(id: String)
    case paneFocusChanged(id: String, isFocused: Bool)
    case subscriptionChanged(
        name: String,
        sessionID: String,
        windowID: String,
        windowIndex: Int?,
        paneID: String,
        value: String
    )
    case paneTitleChanged(sessionID: String, paneID: String, title: String)
    case configurationError(message: String)
    case responseLine(String)
    case notification(name: String, arguments: String)
    case malformed(line: String)
}

private struct TmuxControlBlock: Equatable, Sendable {
    let timestamp: UInt64
    let number: UInt64
    let flags: UInt64
}

struct TmuxControlParser: Sendable {
    private static let enterMarker = Data([0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]) // ESC P1000p
    private static let exitMarker = Data([0x1b, 0x5c]) // ESC \
    static let unexpectedExitReason = "protocol stream ended unexpectedly"

    private let maxControlLineBytes: Int
    private var buffer = Data()
    private var passthrough = Data()
    private var openResponseBlock: TmuxControlBlock?
    private var didEmitExitNotification = false
    private(set) var isInControlMode = false

    init(maxControlLineBytes: Int = 1024 * 1024) {
        self.maxControlLineBytes = max(1, maxControlLineBytes)
    }

    /// Returns ordinary terminal bytes removed while scanning for control-mode markers.
    /// The bridge should feed these bytes to the normal terminal emulator unchanged.
    mutating func takePassthroughData() -> Data {
        defer { passthrough.removeAll(keepingCapacity: true) }
        return passthrough
    }

    mutating func consume(_ data: Data) -> [TmuxControlEvent] {
        buffer.append(data)
        var events: [TmuxControlEvent] = []

        while true {
            if !isInControlMode {
                guard let range = buffer.range(of: Self.enterMarker) else {
                    retainPossibleMarkerPrefix(Self.enterMarker)
                    break
                }
                passthrough.append(buffer[..<range.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                isInControlMode = true
                openResponseBlock = nil
                didEmitExitNotification = false
                events.append(.entered)
            }

            if let exitRange = buffer.range(of: Self.exitMarker),
               !hasNewline(before: exitRange.lowerBound) {
                let prefix = buffer[..<exitRange.lowerBound]
                let hasUnexpectedPlainPrefix = openResponseBlock == nil
                    && prefix.first.map { $0 != 0x25 } == true
                if hasUnexpectedPlainPrefix {
                    passthrough.append(prefix)
                } else if !prefix.isEmpty {
                    parseCompleteLines(in: Data(prefix), into: &events, includeTrailingLine: true)
                }
                buffer.removeSubrange(buffer.startIndex..<exitRange.upperBound)
                isInControlMode = false
                openResponseBlock = nil
                if !didEmitExitNotification {
                    events.append(.exited(
                        reason: hasUnexpectedPlainPrefix ? Self.unexpectedExitReason : nil
                    ))
                }
                didEmitExitNotification = false
                continue
            }

            if openResponseBlock == nil,
               let firstByte = buffer.first,
               firstByte != 0x25,
               !Self.exitMarker.starts(with: buffer) {
                if let newline = buffer.firstIndex(of: 0x0a) {
                    passthrough.append(buffer[...newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                } else {
                    passthrough.append(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if let exit = abortControlMode(reason: Self.unexpectedExitReason) {
                    events.append(exit)
                }
                continue
            }

            guard let newline = buffer.firstIndex(of: 0x0a) else {
                if buffer.count > maxControlLineBytes {
                    let message = "tmux control line exceeded \(maxControlLineBytes) bytes"
                    buffer.removeAll(keepingCapacity: true)
                    events.append(.malformed(line: message))
                    if let exit = abortControlMode(reason: message) { events.append(exit) }
                }
                break
            }
            let lineByteCount = buffer.distance(from: buffer.startIndex, to: newline)
            if lineByteCount > maxControlLineBytes {
                let message = "tmux control line exceeded \(maxControlLineBytes) bytes"
                buffer.removeSubrange(buffer.startIndex...newline)
                events.append(.malformed(line: message))
                if let exit = abortControlMode(reason: message) { events.append(exit) }
                continue
            }
            let lineData = Data(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            events.append(parseLine(lineData))
        }
        return events
    }

    mutating func abortControlMode() {
        buffer.removeAll(keepingCapacity: true)
        openResponseBlock = nil
        isInControlMode = false
        didEmitExitNotification = false
    }

    mutating func abandonOpenResponseBlock() {
        buffer.removeAll(keepingCapacity: true)
        openResponseBlock = nil
    }

    @discardableResult
    private mutating func abortControlMode(reason: String) -> TmuxControlEvent? {
        openResponseBlock = nil
        isInControlMode = false
        let shouldEmitExit = !didEmitExitNotification
        didEmitExitNotification = false
        return shouldEmitExit ? .locallyAborted(reason: reason) : nil
    }

    private mutating func retainPossibleMarkerPrefix(_ marker: Data) {
        let limit = min(buffer.count, marker.count - 1)
        for count in stride(from: limit, through: 1, by: -1) {
            if buffer.suffix(count) == marker.prefix(count) {
                passthrough.append(buffer.dropLast(count))
                buffer = Data(buffer.suffix(count))
                return
            }
        }
        passthrough.append(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private func hasNewline(before index: Data.Index) -> Bool {
        buffer[..<index].contains(0x0a)
    }

    private mutating func parseCompleteLines(
        in data: Data,
        into events: inout [TmuxControlEvent],
        includeTrailingLine: Bool
    ) {
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0a {
            events.append(parseLine(Data(data[start..<index])))
            start = data.index(after: index)
        }
        if includeTrailingLine, start < data.endIndex {
            events.append(parseLine(Data(data[start...])))
        }
    }

    private mutating func parseLine(_ raw: Data) -> TmuxControlEvent {
        var raw = raw
        if raw.last == 0x0d { raw.removeLast() }
        guard let line = String(data: raw, encoding: .utf8) else {
            return .malformed(line: String(decoding: raw, as: UTF8.self))
        }
        if openResponseBlock != nil {
            if let terminator = parseBlockTerminator(line, matching: openResponseBlock) {
                openResponseBlock = nil
                return terminator
            }
            return .responseLine(line)
        }
        guard line.first == "%" else { return .malformed(line: line) }
        let (name, arguments) = splitFirst(line.dropFirst())
        switch name {
        case "begin":
            guard let block = parseBlock(arguments) else { return .malformed(line: line) }
            openResponseBlock = block
            return .blockBegan(timestamp: block.timestamp, number: block.number, flags: block.flags)
        case "end", "error":
            return .malformed(line: line)
        case "output", "extended-output":
            let (paneID, encoded) = splitFirst(arguments[...])
            let payload: String
            if name == "extended-output" {
                guard let separator = encoded.range(of: " : ") else { return .malformed(line: line) }
                payload = String(encoded[separator.upperBound...])
            } else {
                payload = encoded
            }
            guard !paneID.isEmpty, let decoded = Self.decodeEscapedBytes(payload) else {
                return .malformed(line: line)
            }
            return .output(paneID: paneID, data: decoded)
        case "window-add":
            return arguments.isEmpty ? .malformed(line: line) : .windowAdded(id: arguments)
        case "window-close":
            return arguments.isEmpty ? .malformed(line: line) : .windowClosed(id: arguments)
        case "window-renamed":
            let (id, value) = splitFirst(arguments[...])
            return id.isEmpty ? .malformed(line: line) : .windowRenamed(id: id, name: value)
        case "layout-change":
            let fields = arguments.split(separator: " ", maxSplits: 3).map(String.init)
            guard fields.count >= 3,
                  let layout = try? TmuxLayoutParser.parse(fields[1]),
                  let visibleLayout = try? TmuxLayoutParser.parse(fields[2])
            else {
                return .malformed(line: line)
            }
            return .layoutChanged(
                windowID: fields[0],
                layout: layout,
                visibleLayout: visibleLayout,
                flags: fields.count == 4 ? fields[3] : ""
            )
        case "session-changed":
            let (id, value) = splitFirst(arguments[...])
            return id.isEmpty ? .malformed(line: line) : .sessionChanged(id: id, name: value)
        case "session-renamed":
            let (first, remainder) = splitFirst(arguments[...])
            guard !first.isEmpty else { return .malformed(line: line) }
            if first.first == "$", !remainder.isEmpty {
                return .sessionRenamed(id: first, name: remainder)
            }
            return .sessionRenamed(id: nil, name: arguments)
        case "sessions-changed":
            return arguments.isEmpty ? .sessionsChanged : .malformed(line: line)
        case "client-session-changed":
            let fields = arguments.split(separator: " ", maxSplits: 2).map(String.init)
            return fields.count == 3
                ? .clientSessionChanged(clientID: fields[0], sessionID: fields[1], name: fields[2])
                : .malformed(line: line)
        case "session-window-changed":
            let (session, window) = splitFirst(arguments[...])
            return session.isEmpty || window.isEmpty
                ? .malformed(line: line)
                : .activeWindowChanged(sessionID: session, windowID: window)
        case "window-pane-changed":
            let (window, pane) = splitFirst(arguments[...])
            return window.isEmpty || pane.isEmpty
                ? .malformed(line: line)
                : .activePaneChanged(windowID: window, paneID: pane)
        case "pane-focus-in", "pane-focus-out":
            guard !arguments.isEmpty else { return .malformed(line: line) }
            return .paneFocusChanged(id: arguments, isFocused: name == "pane-focus-in")
        case "subscription-changed":
            guard let valueSeparator = arguments.range(of: " : ") else {
                return .malformed(line: line)
            }
            let metadata = arguments[..<valueSeparator.lowerBound]
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard metadata.count >= 5 else { return .malformed(line: line) }
            return .subscriptionChanged(
                name: metadata[0],
                sessionID: metadata[1],
                windowID: metadata[2],
                windowIndex: Int(metadata[3]),
                paneID: metadata[4],
                value: String(arguments[valueSeparator.upperBound...])
            )
        case "config-error":
            return arguments.isEmpty ? .malformed(line: line) : .configurationError(message: arguments)
        case "exit":
            didEmitExitNotification = true
            return .exited(reason: arguments.isEmpty ? nil : arguments)
        default: return .notification(name: name, arguments: arguments)
        }
    }

    private func parseBlockTerminator(
        _ line: String,
        matching openBlock: TmuxControlBlock?
    ) -> TmuxControlEvent? {
        guard line.first == "%" else { return nil }
        let (name, arguments) = splitFirst(line.dropFirst())
        guard name == "end" || name == "error",
              let openBlock,
              let block = parseBlock(arguments),
              block == openBlock
        else { return nil }
        if name == "end" {
            return .blockEnded(timestamp: block.timestamp, number: block.number, flags: block.flags)
        }
        return .blockFailed(timestamp: block.timestamp, number: block.number, flags: block.flags)
    }

    private func parseBlock(_ arguments: String) -> TmuxControlBlock? {
        let fields = arguments.split(separator: " ")
        guard fields.count == 3,
              let timestamp = UInt64(fields[0]),
              let number = UInt64(fields[1]),
              let flags = UInt64(fields[2])
        else { return nil }
        return .init(timestamp: timestamp, number: number, flags: flags)
    }

    private func splitFirst<S: StringProtocol>(_ value: S) -> (String, String) {
        guard let separator = value.firstIndex(of: " ") else { return (String(value), "") }
        return (String(value[..<separator]), String(value[value.index(after: separator)...]))
    }

    static func decodeEscapedBytes(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        var result = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] != 0x5c {
                result.append(bytes[index]); index += 1; continue
            }
            guard index + 1 < bytes.count else { return nil }
            if bytes[index + 1] == 0x5c {
                result.append(0x5c); index += 2; continue
            }
            guard index + 3 < bytes.count,
                  bytes[(index + 1)...(index + 3)].allSatisfy({ (0x30...0x37).contains($0) })
            else { return nil }
            let number = Int(bytes[index + 1] - 0x30) * 64
                + Int(bytes[index + 2] - 0x30) * 8
                + Int(bytes[index + 3] - 0x30)
            guard number <= UInt8.max else { return nil }
            result.append(UInt8(number)); index += 4
        }
        return result
    }
}

struct TmuxLayoutRect: Equatable, Sendable {
    let width: Int
    let height: Int
    let x: Int
    let y: Int
}

indirect enum TmuxLayoutNode: Equatable, Sendable {
    enum Axis: Equatable, Sendable { case horizontal, vertical }
    case pane(id: String, rect: TmuxLayoutRect)
    case split(axis: Axis, rect: TmuxLayoutRect, children: [TmuxLayoutNode])

    var paneIDs: [String] {
        switch self {
        case let .pane(id, _): [id]
        case let .split(_, _, children): children.flatMap(\.paneIDs)
        }
    }
}

enum TmuxLayoutParseError: Error, Equatable { case invalidLayout }

enum TmuxLayoutParser {
    static func parse(_ value: String) throws -> TmuxLayoutNode {
        var body = value[...]
        if let comma = body.firstIndex(of: ","), body[..<comma].allSatisfy({ $0.isHexDigit }) {
            body = body[body.index(after: comma)...]
        }
        var cursor = Cursor(input: body)
        let node = try cursor.node()
        guard cursor.isAtEnd else { throw TmuxLayoutParseError.invalidLayout }
        return node
    }

    private struct Cursor {
        let input: Substring
        var index: Substring.Index
        init(input: Substring) { self.input = input; index = input.startIndex }
        var isAtEnd: Bool { index == input.endIndex }

        mutating func node() throws -> TmuxLayoutNode {
            let rect = try rectangle()
            guard !isAtEnd else { throw TmuxLayoutParseError.invalidLayout }
            if input[index] == "," {
                advance()
                let id = try token(until: [",", "}", "]"])
                guard !id.isEmpty else { throw TmuxLayoutParseError.invalidLayout }
                let paneID = id.first == "%" ? id : "%\(id)"
                return .pane(id: paneID, rect: rect)
            }
            let opener = input[index]
            guard opener == "{" || opener == "[" else { throw TmuxLayoutParseError.invalidLayout }
            let closer: Character = opener == "{" ? "}" : "]"
            let axis: TmuxLayoutNode.Axis = opener == "{" ? .horizontal : .vertical
            advance()
            var children: [TmuxLayoutNode] = []
            while true {
                children.append(try node())
                guard !isAtEnd else { throw TmuxLayoutParseError.invalidLayout }
                if input[index] == closer { advance(); break }
                guard input[index] == "," else { throw TmuxLayoutParseError.invalidLayout }
                advance()
            }
            guard children.count >= 2 else { throw TmuxLayoutParseError.invalidLayout }
            return .split(axis: axis, rect: rect, children: children)
        }

        mutating func rectangle() throws -> TmuxLayoutRect {
            let width = try integer(); try expect("x")
            let height = try integer(); try expect(",")
            let x = try integer(); try expect(",")
            let y = try integer()
            return .init(width: width, height: height, x: x, y: y)
        }

        mutating func integer() throws -> Int {
            let value = try token(until: ["x", ",", "{", "["])
            guard let number = Int(value), number >= 0 else { throw TmuxLayoutParseError.invalidLayout }
            return number
        }

        mutating func token(until delimiters: Set<Character>) throws -> String {
            let start = index
            while !isAtEnd, !delimiters.contains(input[index]) { advance() }
            guard start != index else { throw TmuxLayoutParseError.invalidLayout }
            return String(input[start..<index])
        }

        mutating func expect(_ character: Character) throws {
            guard !isAtEnd, input[index] == character else { throw TmuxLayoutParseError.invalidLayout }
            advance()
        }
        mutating func advance() { index = input.index(after: index) }
    }
}
