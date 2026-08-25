import AppKit
import Foundation

struct TerminalKittyOSC {
    static func metadataAndPayload(_ payload: String) -> (metadata: String, payload: String) {
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        return (
            metadata: String(parts.first ?? ""),
            payload: parts.count == 2 ? String(parts[1]) : ""
        )
    }

    static func metadata(_ text: String) -> [String: String]? {
        var result: [String: String] = [:]
        for field in text.split(separator: ":", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty else {
                return nil
            }
            result[String(pair[0])] = String(pair[1])
        }
        return result
    }

    static func decodedBase64Text(_ encoded: String) -> String? {
        guard encoded.count % 4 == 0,
              encoded.unicodeScalars.allSatisfy({ $0.isBase64Scalar }),
              let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    static func strictBase64Data(_ encoded: String) -> Data? {
        guard encoded.count % 4 == 0,
              encoded.unicodeScalars.allSatisfy({ $0.isBase64Scalar })
        else {
            return nil
        }
        return Data(base64Encoded: encoded)
    }

    static func response(code: String, metadata: String, payload: String = "") -> String {
        let body = payload.isEmpty ? "\(code);\(metadata)" : "\(code);\(metadata);\(payload)"
        return "\u{1b}]\(body)\u{1b}\\"
    }
}

struct TerminalKittyClipboardController: Equatable {
    enum Status: String, Equatable {
        case done = "DONE"
        case ok = "OK"
        case data = "DATA"
        case invalid = "EINVAL"
        case permission = "EPERM"
        case unavailable = "ENOSYS"
        case busy = "EBUSY"
        case tooLarge = "EFBIG"
    }

    struct ReadRequest: Equatable {
        let id: String
        let location: Location
        let mimes: [String]
        let listsTypesOnly: Bool
    }

    struct WriteRequest: Equatable {
        let id: String
        let location: Location
        let preferredText: String
        let byteCount: Int
    }

    enum Location: Equatable {
        case clipboard
        case primary
    }

    enum Event: Equatable {
        case ignored
        case read(ReadRequest)
        case write(WriteRequest)
        case respond(String)
    }

    private struct WriteState: Equatable {
        var id: String
        var location: Location
        var chunksByMime: [String: String] = [:]
        var aliasesByMime: [String: [String]] = [:]
        var byteCount = 0
    }

    private enum Limit {
        static let decodedWriteBYTES = 64 * 1_024 * 1_024
        static let responseChunkBYTES = 3_072
        static let idBYTES = 512
    }

    private var writeState: WriteState?

    mutating func dispatch(_ payload: String, policy: TerminalSecurityPolicy, origin: TerminalSecurityPolicy.Origin) -> Event {
        let parts = TerminalKittyOSC.metadataAndPayload(payload)
        guard let metadata = TerminalKittyOSC.metadata(parts.metadata),
              let type = metadata["type"]
        else {
            return .ignored
        }

        switch type {
        case "read":
            return read(metadata: metadata, payload: parts.payload, policy: policy, origin: origin)
        case "write":
            return beginWrite(metadata: metadata, policy: policy, origin: origin)
        case "wdata":
            return writeData(metadata: metadata, payload: parts.payload)
        case "walias":
            return writeAlias(metadata: metadata, payload: parts.payload)
        default:
            return .ignored
        }
    }

    static func response(op: String, status: Status, id: String, mime: String? = nil, payload: String = "") -> String {
        var metadata = "type=\(op):status=\(status.rawValue)"
        if let mime {
            metadata += ":mime=\(Data(mime.utf8).base64EncodedString())"
        }
        if !id.isEmpty {
            metadata += ":id=\(id)"
        }
        return TerminalKittyOSC.response(code: "5522", metadata: metadata, payload: payload)
    }

    static func readSuccessResponses(id: String, contents: [(mime: String, data: Data)]) -> String {
        var output = response(op: "read", status: .ok, id: id)
        for item in contents {
            let chunks = item.data.kittyProtocolChunks(maxBytes: Limit.responseChunkBYTES)
            for chunk in chunks {
                output += response(
                    op: "read",
                    status: .data,
                    id: id,
                    mime: item.mime,
                    payload: chunk.base64EncodedString()
                )
            }
        }
        output += response(op: "read", status: .done, id: id)
        return output
    }

    private func read(
        metadata: [String: String],
        payload: String,
        policy: TerminalSecurityPolicy,
        origin: TerminalSecurityPolicy.Origin
    ) -> Event {
        guard let decoded = TerminalKittyOSC.decodedBase64Text(payload) else {
            return .ignored
        }
        let mimes = decoded.split(separator: " ").map(String.init)
        let listsTypesOnly = mimes == ["."]
        if !listsTypesOnly, policy.decision(for: .osc52Read, origin: origin) != .allow {
            return .respond(Self.response(op: "read", status: .permission, id: id(from: metadata)))
        }
        return .read(
            ReadRequest(
                id: id(from: metadata),
                location: location(from: metadata),
                mimes: listsTypesOnly ? [] : mimes,
                listsTypesOnly: listsTypesOnly
            )
        )
    }

    private mutating func beginWrite(
        metadata: [String: String],
        policy: TerminalSecurityPolicy,
        origin: TerminalSecurityPolicy.Origin
    ) -> Event {
        writeState = nil
        let id = id(from: metadata)
        guard location(from: metadata) == .clipboard else {
            return .respond(Self.response(op: "write", status: .unavailable, id: id))
        }
        guard policy.decision(for: .osc52Write, origin: origin) != .deny else {
            return .respond(Self.response(op: "write", status: .permission, id: id))
        }
        writeState = WriteState(id: id, location: .clipboard)
        return .ignored
    }

    private mutating func writeData(metadata: [String: String], payload: String) -> Event {
        guard var state = writeState else {
            return .ignored
        }
        guard let encodedMime = metadata["mime"] else {
            return commitWrite(state)
        }
        guard let mime = TerminalKittyOSC.decodedBase64Text(encodedMime) else {
            writeState = nil
            return .respond(Self.response(op: "write", status: .invalid, id: state.id))
        }
        guard TerminalKittyOSC.strictBase64Data(payload) != nil else {
            writeState = nil
            return .respond(Self.response(op: "write", status: .invalid, id: state.id))
        }
        state.chunksByMime[mime, default: ""] += payload
        if let decodedCount = TerminalKittyOSC.strictBase64Data(state.chunksByMime[mime] ?? "")?.count {
            state.byteCount = state.chunksByMime.values.compactMap { TerminalKittyOSC.strictBase64Data($0)?.count }.reduce(0, +)
            guard state.byteCount <= Limit.decodedWriteBYTES else {
                writeState = nil
                return .respond(Self.response(op: "write", status: .tooLarge, id: state.id))
            }
            _ = decodedCount
        }
        writeState = state
        return .ignored
    }

    private mutating func writeAlias(metadata: [String: String], payload: String) -> Event {
        guard var state = writeState else {
            return .ignored
        }
        guard let encodedMime = metadata["mime"],
              let mime = TerminalKittyOSC.decodedBase64Text(encodedMime),
              let aliasList = TerminalKittyOSC.decodedBase64Text(payload)
        else {
            writeState = nil
            return .respond(Self.response(op: "write", status: .invalid, id: state.id))
        }
        state.aliasesByMime[mime, default: []].append(contentsOf: aliasList.split(separator: " ").map(String.init))
        writeState = state
        return .ignored
    }

    private mutating func commitWrite(_ state: WriteState) -> Event {
        defer { writeState = nil }
        let preferredMimes = ["text/plain;charset=utf-8", "text/plain", "text/utf8", "UTF8_STRING", "public.utf8-plain-text"]
        for mime in preferredMimes {
            if let encoded = state.chunksByMime[mime],
               let data = TerminalKittyOSC.strictBase64Data(encoded),
               let text = String(data: data, encoding: .utf8) {
                return .write(WriteRequest(id: state.id, location: state.location, preferredText: text, byteCount: data.count))
            }
        }
        guard let first = state.chunksByMime.sorted(by: { $0.key < $1.key }).first,
              let data = TerminalKittyOSC.strictBase64Data(first.value),
              let text = String(data: data, encoding: .utf8)
        else {
            return .respond(Self.response(op: "write", status: .invalid, id: state.id))
        }
        return .write(WriteRequest(id: state.id, location: state.location, preferredText: text, byteCount: data.count))
    }

    private func id(from metadata: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_+.")
        let sanitized = (metadata["id"] ?? "")
            .unicodeScalars
            .filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(sanitized)).prefixBytes(Limit.idBYTES)
    }

    private func location(from metadata: [String: String]) -> Location {
        metadata["loc"] == "primary" ? .primary : .clipboard
    }
}

struct TerminalKittyDragAndDropController: Equatable {
    struct DropPayload: Equatable {
        let mimes: [String]
        let dataByMime: [String: Data]
    }

    enum Event: Equatable {
        case ignored
        case response(String)
        case requestData(index: Int)
        case complete
    }

    private(set) var acceptsDrops = false
    private(set) var acceptedMimes: [String] = []
    private(set) var acceptedOperation = 0
    private(set) var activeDrop: DropPayload?

    private enum Limit {
        static let responseChunkBYTES = 3_072
    }

    mutating func dispatch(_ payload: String) -> Event {
        let parts = TerminalKittyOSC.metadataAndPayload(payload)
        guard let metadata = TerminalKittyOSC.metadata(parts.metadata),
              let type = metadata["t"]
        else {
            return .ignored
        }

        switch type {
        case "a":
            acceptsDrops = true
            acceptedMimes = parts.payload.split(separator: " ").map(String.init)
            return .ignored
        case "A":
            acceptsDrops = false
            activeDrop = nil
            acceptedMimes = []
            acceptedOperation = 0
            return .ignored
        case "m":
            acceptedOperation = Int(metadata["o"] ?? "0") ?? 0
            let wanted = parts.payload.split(separator: " ").map(String.init)
            if !wanted.isEmpty {
                acceptedMimes = wanted
            }
            return .ignored
        case "r":
            if let operation = metadata["o"], operation != "0" {
                activeDrop = nil
                return .complete
            }
            guard let rawIndex = metadata["x"], let index = Int(rawIndex) else {
                return .ignored
            }
            return .requestData(index: index)
        case "q":
            let id = metadata["i"].map { ":i=\($0)" } ?? ""
            return .response(TerminalKittyOSC.response(code: "72", metadata: "t=q\(id)", payload: "Kurotty"))
        default:
            return .ignored
        }
    }

    mutating func beginDrop(urls: [URL]) -> String {
        let uriList = urls.map(\.absoluteString).joined(separator: "\r\n")
        let plain = urls.map(\.path).joined(separator: "\n")
        activeDrop = DropPayload(
            mimes: ["text/uri-list", "text/plain"],
            dataByMime: [
                "text/uri-list": Data(uriList.utf8),
                "text/plain": Data(plain.utf8),
            ]
        )
        return TerminalKittyOSC.response(
            code: "72",
            metadata: "t=M:x=0:y=0:X=0:Y=0:o=1",
            payload: "text/uri-list text/plain"
        )
    }

    mutating func leaveDrop() -> String {
        activeDrop = nil
        return TerminalKittyOSC.response(code: "72", metadata: "t=m:x=-1:y=-1:X=0:Y=0:o=0")
    }

    func dataResponse(index: Int) -> String {
        guard let drop = activeDrop, index > 0, index <= drop.mimes.count else {
            return TerminalKittyOSC.response(code: "72", metadata: "t=R:x=\(index)", payload: "ENOENT")
        }
        let mime = drop.mimes[index - 1]
        guard let data = drop.dataByMime[mime] else {
            return TerminalKittyOSC.response(code: "72", metadata: "t=R:x=\(index)", payload: "ENOENT")
        }

        var output = ""
        for chunk in data.kittyProtocolChunks(maxBytes: Limit.responseChunkBYTES) {
            output += TerminalKittyOSC.response(
                code: "72",
                metadata: "t=r:x=\(index):m=1",
                payload: chunk.base64EncodedString()
            )
        }
        output += TerminalKittyOSC.response(code: "72", metadata: "t=r:x=\(index):m=0")
        return output
    }
}

private extension Data {
    func kittyProtocolChunks(maxBytes: Int) -> [Data] {
        guard !isEmpty else { return [Data()] }
        var result: [Data] = []
        var offset = 0
        while offset < count {
            let end = Swift.min(offset + maxBytes, count)
            result.append(subdata(in: offset..<end))
            offset = end
        }
        return result
    }
}

private extension String {
    func prefixBytes(_ byteLimit: Int) -> String {
        guard byteLimit >= 0 else { return "" }
        var result = ""
        var used = 0
        for character in self {
            let bytes = String(character).utf8.count
            guard used + bytes <= byteLimit else { break }
            result.append(character)
            used += bytes
        }
        return result
    }
}

private extension UnicodeScalar {
    var isBase64Scalar: Bool {
        ("A"..."Z").contains(String(self))
            || ("a"..."z").contains(String(self))
            || ("0"..."9").contains(String(self))
            || self == "+"
            || self == "/"
            || self == "="
    }
}
