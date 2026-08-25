import Darwin
import Foundation
import KurottyCore
import os

private let screenReadBridgeLogger = Logger(subsystem: "dev.kurotty.app", category: "screen-read")

enum KurottyScreenReadBridgeError: Error, Equatable, CustomStringConvertible {
    case emptyPaneIdentifier
    case unsupportedVersion(Int)
    case malformedRequest
    case paneUnavailable
    case socketPathTooLong
    case socketUnavailable
    case sendFailed
    case responseTooLarge

    var description: String {
        switch self {
        case .emptyPaneIdentifier: "empty pane identifier"
        case .unsupportedVersion(let version): "unsupported version \(version)"
        case .malformedRequest: "malformed request"
        case .paneUnavailable: "pane unavailable"
        case .socketPathTooLong: "socket path too long"
        case .socketUnavailable: "socket unavailable"
        case .sendFailed: "send failed"
        case .responseTooLarge: "response too large"
        }
    }
}

struct KurottyScreenReadSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let paneID: String
    let rows: Int
    let columns: Int
    let cursorRow: Int
    let cursorColumn: Int
    let scrollbackOffset: Int
    let alternateScreen: Bool
    let lines: [String]

    var text: String {
        lines.joined(separator: "\n")
    }
}

struct KurottyScreenReadRequest: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let paneID: String

    init(version: Int = currentVersion, paneID: String) throws {
        guard version == Self.currentVersion else {
            throw KurottyScreenReadBridgeError.unsupportedVersion(version)
        }
        let normalizedPaneID = paneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPaneID.isEmpty else {
            throw KurottyScreenReadBridgeError.emptyPaneIdentifier
        }
        self.version = version
        self.paneID = normalizedPaneID
    }
}

private struct KurottyScreenReadResponse: Codable {
    let ok: Bool
    let error: String?
    let screen: KurottyScreenReadSnapshot?

    static func success(_ snapshot: KurottyScreenReadSnapshot) -> Self {
        KurottyScreenReadResponse(ok: true, error: nil, screen: snapshot)
    }

    static func failure(_ error: KurottyScreenReadBridgeError) -> Self {
        KurottyScreenReadResponse(ok: false, error: error.description, screen: nil)
    }
}

struct KurottyScreenReadBridgeSocketLocation {
    static func defaultSocketPath() throws -> URL {
        let directory = try applicationSupportDirectory()
        return directory.appendingPathComponent(AppConstants.ScreenRead.bridgeSocketFileName)
    }

    static func ensureSocketDirectoryExists() throws -> URL {
        let directory = try applicationSupportDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: AppConstants.ScreenRead.bridgeSocketDirectoryPermissions],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(AppConstants.Settings.directoryName, isDirectory: true)
    }
}

struct KurottyScreenReadBridgeEnvironment {
    static func shellEnvironment(
        paneIdentifier: String,
        executablePath: String? = Bundle.main.executablePath,
        socketPath: String? = try? KurottyScreenReadBridgeSocketLocation.defaultSocketPath().path
    ) -> [String: String] {
        guard !paneIdentifier.isEmpty,
              let executablePath, !executablePath.isEmpty,
              let socketPath, !socketPath.isEmpty else {
            return [:]
        }
        return [
            AppConstants.ScreenRead.bridgeCommandEnvironmentName: executablePath,
            AppConstants.ScreenRead.bridgeSocketEnvironmentName: socketPath,
            AppConstants.ScreenRead.paneIdentifierEnvironmentName: paneIdentifier,
        ]
    }
}

@MainActor
final class TerminalScreenReadRegistry {
    static let shared = TerminalScreenReadRegistry()

    private var providers: [String: () -> KurottyScreenReadSnapshot?] = [:]

    func register(paneID: String, provider: @escaping () -> KurottyScreenReadSnapshot?) {
        guard !paneID.isEmpty else { return }
        providers[paneID] = provider
    }

    func unregister(paneID: String) {
        providers.removeValue(forKey: paneID)
    }

    func snapshot(for paneID: String) -> KurottyScreenReadSnapshot? {
        guard let provider = providers[paneID] else {
            return nil
        }
        return provider()
    }
}

final class KurottyScreenReadBridgeServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.kurotty.screen-read-bridge")
    private let stateLock = NSLock()
    private var socketDescriptor: Int32 = -1
    private var socketPath: URL?

    func start() {
        installEnvironment()
        claimBridgeSocket()
    }

    func stop() {
        let previousState = clearSocketState()
        if previousState.descriptor >= 0 {
            Darwin.close(previousState.descriptor)
        }
        if let path = previousState.path {
            try? FileManager.default.removeItem(at: path)
        }
    }

    private func installEnvironment() {
        guard let executablePath = Bundle.main.executablePath,
              let socketPath = try? KurottyScreenReadBridgeSocketLocation.defaultSocketPath().path else {
            return
        }
        setenv(AppConstants.ScreenRead.bridgeCommandEnvironmentName, executablePath, 1)
        setenv(AppConstants.ScreenRead.bridgeSocketEnvironmentName, socketPath, 1)
    }

    private func claimBridgeSocket() {
        do {
            _ = try KurottyScreenReadBridgeSocketLocation.ensureSocketDirectoryExists()
            let path = try KurottyScreenReadBridgeSocketLocation.defaultSocketPath()
            guard currentSocketDescriptor() < 0 else {
                return
            }
            try? FileManager.default.removeItem(at: path)

            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                screenReadBridgeLogger.error("screen-read socket create failed errno=\(errno, privacy: .public)")
                return
            }

            do {
                screenReadSetCloseOnExec(descriptor)
                try screenReadBindSocket(descriptor, to: path.path)
                guard Darwin.listen(descriptor, AppConstants.ScreenRead.bridgeSocketBacklog) == 0 else {
                    screenReadBridgeLogger.error("screen-read socket listen failed errno=\(errno, privacy: .public)")
                    Darwin.close(descriptor)
                    return
                }
            } catch {
                Darwin.close(descriptor)
                throw error
            }

            _ = Darwin.chmod(path.path, mode_t(AppConstants.ScreenRead.bridgeSocketPermissions))
            setSocketState(descriptor: descriptor, path: path)
            setenv(AppConstants.ScreenRead.bridgeSocketEnvironmentName, path.path, 1)
            screenReadBridgeLogger.info("screen-read socket listening path=\(path.path, privacy: .public)")
            queue.async { [weak self] in
                self?.acceptLoop(descriptor)
            }
        } catch {
            screenReadBridgeLogger.error("screen-read socket start failed error=\(String(describing: error), privacy: .public)")
        }
    }

    private func acceptLoop(_ descriptor: Int32) {
        while currentSocketDescriptor() == descriptor {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR {
                    continue
                }
                break
            }
            screenReadSetCloseOnExec(client)
            handle(client: client)
        }
    }

    private func handle(client descriptor: Int32) {
        let response: KurottyScreenReadResponse
        do {
            let data = try readRequest(from: descriptor)
            let request = try decodeRequest(data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let response: KurottyScreenReadResponse
                    if let snapshot = TerminalScreenReadRegistry.shared.snapshot(for: request.paneID) {
                        response = .success(snapshot)
                    } else {
                        response = .failure(.paneUnavailable)
                    }
                    self.queue.async {
                        self.write(response: response, to: descriptor)
                        Darwin.close(descriptor)
                    }
                }
            }
            return
        } catch let error as KurottyScreenReadBridgeError {
            response = .failure(error)
        } catch {
            response = .failure(.malformedRequest)
        }
        write(response: response, to: descriptor)
        Darwin.close(descriptor)
    }

    private func readRequest(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count <= AppConstants.ScreenRead.maximumRequestBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.last == 10 {
                    break
                }
                continue
            }
            if count == -1 && errno == EINTR {
                continue
            }
            break
        }
        guard data.count <= AppConstants.ScreenRead.maximumRequestBytes else {
            throw KurottyScreenReadBridgeError.malformedRequest
        }
        guard !data.isEmpty else {
            throw KurottyScreenReadBridgeError.malformedRequest
        }
        return data
    }

    private func decodeRequest(_ data: Data) throws -> KurottyScreenReadRequest {
        let decoded = try JSONDecoder().decode(KurottyScreenReadRequest.self, from: data)
        return try KurottyScreenReadRequest(version: decoded.version, paneID: decoded.paneID)
    }

    private func write(response: KurottyScreenReadResponse, to descriptor: Int32) {
        do {
            let encoded = try KurottyScreenReadBridgeClient.encode(response: response)
            try screenReadSendAll(encoded, to: descriptor)
        } catch {
            screenReadBridgeLogger.error("screen-read response send failed error=\(String(describing: error), privacy: .public)")
        }
    }

    private func currentSocketDescriptor() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return socketDescriptor
    }

    private func setSocketState(descriptor: Int32, path: URL) {
        stateLock.lock()
        socketDescriptor = descriptor
        socketPath = path
        stateLock.unlock()
    }

    private func clearSocketState() -> (descriptor: Int32, path: URL?) {
        stateLock.lock()
        let state = (socketDescriptor, socketPath)
        socketDescriptor = -1
        socketPath = nil
        stateLock.unlock()
        return state
    }
}

enum KurottyScreenReadBridgeClient {
    static func readScreen(paneID: String, socketPath: String? = nil) throws -> KurottyScreenReadSnapshot {
        let request = try KurottyScreenReadRequest(paneID: paneID)
        let path = socketPath
            ?? ProcessInfo.processInfo.environment[AppConstants.ScreenRead.bridgeSocketEnvironmentName]
            ?? (try? KurottyScreenReadBridgeSocketLocation.defaultSocketPath().path)
        guard let path else {
            throw KurottyScreenReadBridgeError.socketUnavailable
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KurottyScreenReadBridgeError.socketUnavailable
        }
        defer { Darwin.close(descriptor) }

        try screenReadConnectSocket(descriptor, to: path)
        try screenReadSendAll(try encode(request: request), to: descriptor)
        Darwin.shutdown(descriptor, SHUT_WR)
        let response = try decodeResponse(try readResponse(from: descriptor))
        guard response.ok, let screen = response.screen else {
            throw KurottyScreenReadBridgeError.paneUnavailable
        }
        return screen
    }

    static func encode(request: KurottyScreenReadRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(10)
        return data
    }

    fileprivate static func encode(response: KurottyScreenReadResponse) throws -> Data {
        var data = try JSONEncoder().encode(response)
        data.append(10)
        return data
    }

    private static func readResponse(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= AppConstants.ScreenRead.maximumResponseBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == -1 && errno == EINTR {
                continue
            }
            break
        }
        guard data.count <= AppConstants.ScreenRead.maximumResponseBytes else {
            throw KurottyScreenReadBridgeError.responseTooLarge
        }
        guard !data.isEmpty else {
            throw KurottyScreenReadBridgeError.socketUnavailable
        }
        return data
    }

    private static func decodeResponse(_ data: Data) throws -> KurottyScreenReadResponse {
        try JSONDecoder().decode(KurottyScreenReadResponse.self, from: data)
    }
}

enum KurottyScreenReadBridgeCommandLine {
    static func handleIfNeeded(arguments: [String]) -> Bool {
        guard arguments.count >= 2 else {
            return false
        }
        switch arguments[1] {
        case "--read-screen", "--read-screen-json":
            do {
                let paneID = try paneIdentifier(from: arguments)
                let screen = try KurottyScreenReadBridgeClient.readScreen(paneID: paneID)
                if arguments[1] == "--read-screen-json" {
                    let data = try JSONEncoder().encode(screen)
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    print(screen.text)
                }
                return true
            } catch {
                fputs("kurotty read-screen failed: \(error)\n", stderr)
                exit(1)
            }
        case "--read-screen-socket-path":
            do {
                let path = try KurottyScreenReadBridgeSocketLocation.defaultSocketPath().path
                print(path)
                return true
            } catch {
                fputs("kurotty read-screen socket unavailable: \(error)\n", stderr)
                exit(1)
            }
        default:
            return false
        }
    }

    private static func paneIdentifier(from arguments: [String]) throws -> String {
        if let index = arguments.firstIndex(of: "--pane-id"),
           arguments.indices.contains(index + 1) {
            return try KurottyScreenReadRequest(paneID: arguments[index + 1]).paneID
        }
        if let paneID = ProcessInfo.processInfo.environment[AppConstants.ScreenRead.paneIdentifierEnvironmentName] {
            return try KurottyScreenReadRequest(paneID: paneID).paneID
        }
        throw KurottyScreenReadBridgeError.emptyPaneIdentifier
    }
}

private func screenReadBindSocket(_ descriptor: Int32, to path: String) throws {
    var address = try screenReadUnixAddress(path: path)
    let length = screenReadUnixAddressLength(path: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.bind(descriptor, sockaddrPointer, length)
        }
    }
    guard result == 0 else {
        throw KurottyScreenReadBridgeError.socketUnavailable
    }
}

private func screenReadConnectSocket(_ descriptor: Int32, to path: String) throws {
    var address = try screenReadUnixAddress(path: path)
    let length = screenReadUnixAddressLength(path: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(descriptor, sockaddrPointer, length)
        }
    }
    guard result == 0 else {
        throw KurottyScreenReadBridgeError.socketUnavailable
    }
}

private func screenReadUnixAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        throw KurottyScreenReadBridgeError.socketPathTooLong
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        for index in rawBuffer.indices {
            rawBuffer[index] = 0
        }
        rawBuffer.copyBytes(from: bytes)
    }
    return address
}

private func screenReadUnixAddressLength(path: String) -> socklen_t {
    socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
}

private func screenReadSetCloseOnExec(_ descriptor: Int32) {
    let flags = Darwin.fcntl(descriptor, F_GETFD)
    if flags >= 0 {
        _ = Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
    }
}

private func screenReadSendAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let sent = Darwin.send(
                descriptor,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset,
                0
            )
            guard sent > 0 else {
                throw KurottyScreenReadBridgeError.sendFailed
            }
            offset += sent
        }
    }
}
