import Darwin
import Foundation
import os

private let notificationBridgeLogger = Logger(subsystem: "dev.kurotty.app", category: "notifications")

enum KurottyNotificationBridgeError: Error, Equatable {
    case emptyPayload
    case socketPathTooLong
    case socketUnavailable
    case sendFailed
}

struct KurottyNotificationBridgeSocketLocation {
    static func defaultSocketPath() throws -> URL {
        let directory = try applicationSupportDirectory()
        return directory.appendingPathComponent(AppConstants.Notifications.bridgeSocketFileName)
    }

    static func ensureSocketDirectoryExists() throws -> URL {
        let directory = try applicationSupportDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: AppConstants.Notifications.bridgeSocketDirectoryPermissions],
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

struct KurottyNotificationBridgePayload: Equatable {
    let title: String
    let subtitle: String
    let body: String

    static func fromIncomingText(_ text: String) throws -> KurottyNotificationBridgePayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KurottyNotificationBridgeError.emptyPayload
        }

        if let object = jsonObject(from: trimmed) {
            let title = firstNonEmptyValue(in: object, keys: ["title"])
                ?? AppConstants.Notifications.terminalAlertTitle
            let subtitle = firstNonEmptyValue(in: object, keys: ["subtitle"]) ?? ""
            let body = firstNonEmptyValue(
                in: object,
                keys: [
                    "body",
                    "message",
                    "output_preview",
                    "outputPreview",
                    "last-assistant-message",
                    "last_assistant_message",
                    "lastAssistantMessage",
                    "text",
                    "tmuxTail",
                    "tmux_tail",
                    "summary",
                    "instruction",
                ]
            ) ?? trimmed
            return try KurottyNotificationBridgePayload(title: title, subtitle: subtitle, body: body)
        }

        return try KurottyNotificationBridgePayload(
            title: AppConstants.Notifications.terminalAlertTitle,
            subtitle: "",
            body: trimmed
        )
    }

    init(title: String, subtitle: String, body: String) throws {
        let normalizedTitle = TerminalNotificationPayload.body(fromExplicitPayload: title)
            ?? AppConstants.Notifications.terminalAlertTitle
        let normalizedSubtitle = TerminalNotificationPayload.body(fromExplicitPayload: subtitle) ?? ""
        guard let normalizedBody = TerminalNotificationPayload.body(fromExplicitPayload: body) else {
            throw KurottyNotificationBridgeError.emptyPayload
        }
        self.title = normalizedTitle
        self.subtitle = normalizedSubtitle
        self.body = normalizedBody
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        guard text.first == "{",
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func firstNonEmptyValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = object[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

final class KurottyNotificationBridgeServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.kurotty.notification-bridge")
    private let stateLock = NSLock()
    private var socketDescriptor: Int32 = -1
    private(set) var socketPath: URL?

    func start() {
        installEnvironment()
        do {
            _ = try KurottyNotificationBridgeSocketLocation.ensureSocketDirectoryExists()
            let path = try KurottyNotificationBridgeSocketLocation.defaultSocketPath()
            if KurottyNotificationBridgeSocketProbe.isReachable(path: path.path) {
                notificationBridgeLogger.info("bridge socket already active path=\(path.path, privacy: .public)")
                return
            }
            try? FileManager.default.removeItem(at: path)

            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                notificationBridgeLogger.error("bridge socket create failed errno=\(errno, privacy: .public)")
                return
            }
            setCloseOnExec(descriptor)

            try bindSocket(descriptor, to: path.path)
            guard Darwin.listen(descriptor, AppConstants.Notifications.bridgeSocketBacklog) == 0 else {
                notificationBridgeLogger.error("bridge socket listen failed errno=\(errno, privacy: .public)")
                Darwin.close(descriptor)
                return
            }
            _ = Darwin.chmod(path.path, mode_t(AppConstants.Notifications.bridgeSocketPermissions))
            setSocketState(descriptor: descriptor, path: path)
            setenv(AppConstants.Notifications.bridgeSocketEnvironmentName, path.path, 1)
            notificationBridgeLogger.info("bridge socket listening path=\(path.path, privacy: .public)")
            queue.async { [weak self] in
                self?.acceptLoop(descriptor)
            }
        } catch {
            notificationBridgeLogger.error("bridge socket start failed error=\(String(describing: error), privacy: .public)")
        }
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
        guard let path = try? KurottyNotificationBridgeSocketLocation.defaultSocketPath().path else {
            return
        }
        setenv(AppConstants.Notifications.bridgeSocketEnvironmentName, path, 1)
        setenv(AppConstants.Notifications.bridgeCommandEnvironmentName, Bundle.main.executablePath ?? "", 1)
    }

    private func acceptLoop(_ descriptor: Int32) {
        while currentSocketDescriptor() == descriptor {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                if currentSocketDescriptor() == descriptor {
                    notificationBridgeLogger.error("bridge socket accept failed errno=\(errno, privacy: .public)")
                }
                continue
            }
            handleClient(client)
        }
    }

    private func handleClient(_ client: Int32) {
        defer { Darwin.close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < AppConstants.Notifications.bridgePayloadMaxBytes {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(client, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
            if buffer.prefix(count).contains(10) {
                break
            }
        }
        guard !data.isEmpty else {
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            notificationBridgeLogger.error("bridge payload is not utf8 bytes=\(data.count, privacy: .public)")
            return
        }
        do {
            let payload = try KurottyNotificationBridgePayload.fromIncomingText(text)
            notificationBridgeLogger.info("bridge payload received titleChars=\(payload.title.count, privacy: .public) bodyChars=\(payload.body.count, privacy: .public)")
            Task { @MainActor in
                TerminalNotifier.shared.notifyBridgeNotification(
                    title: payload.title,
                    subtitle: payload.subtitle,
                    body: payload.body
                )
            }
        } catch {
            notificationBridgeLogger.error("bridge payload rejected error=\(String(describing: error), privacy: .public)")
        }
    }

    private func setSocketState(descriptor: Int32, path: URL) {
        stateLock.lock()
        socketDescriptor = descriptor
        socketPath = path
        stateLock.unlock()
    }

    private func clearSocketState() -> (descriptor: Int32, path: URL?) {
        stateLock.lock()
        let previous = (socketDescriptor, socketPath)
        socketDescriptor = -1
        socketPath = nil
        stateLock.unlock()
        return previous
    }

    private func currentSocketDescriptor() -> Int32 {
        stateLock.lock()
        let descriptor = socketDescriptor
        stateLock.unlock()
        return descriptor
    }
}

enum KurottyNotificationBridgeSocketProbe {
    static func isReachable(path: String) -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { Darwin.close(descriptor) }

        do {
            try connectSocket(descriptor, to: path)
            return true
        } catch {
            return false
        }
    }
}

enum KurottyNotificationBridgeClient {
    static func send(_ text: String, socketPath: String? = nil) throws {
        let payload = try KurottyNotificationBridgePayload.fromIncomingText(text)
        let encoded = try encode(payload: payload)
        let path = socketPath
            ?? ProcessInfo.processInfo.environment[AppConstants.Notifications.bridgeSocketEnvironmentName]
            ?? (try? KurottyNotificationBridgeSocketLocation.defaultSocketPath().path)
        guard let path else {
            throw KurottyNotificationBridgeError.socketUnavailable
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw KurottyNotificationBridgeError.socketUnavailable
        }
        defer { Darwin.close(descriptor) }

        try connectSocket(descriptor, to: path)
        try sendAll(encoded, to: descriptor)
    }

    private static func encode(payload: KurottyNotificationBridgePayload) throws -> Data {
        let object = [
            "title": payload.title,
            "subtitle": payload.subtitle,
            "body": payload.body,
        ]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }
}

private func sendAll(_ data: Data, to descriptor: Int32) throws {
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
                throw KurottyNotificationBridgeError.sendFailed
            }
            offset += sent
        }
    }
}

enum KurottyNotificationBridgeCommandLine {
    static func handleIfNeeded(arguments: [String]) -> Bool {
        guard arguments.count >= 2 else {
            return false
        }
        switch arguments[1] {
        case "--notify", "--notify-json":
            let text = arguments.dropFirst(2).joined(separator: " ")
            do {
                try KurottyNotificationBridgeClient.send(text)
                return true
            } catch {
                fputs("kurotty notify failed: \(error)\n", stderr)
                exit(1)
            }
        case "--notify-socket-path":
            do {
                let path = try KurottyNotificationBridgeSocketLocation.defaultSocketPath().path
                print(path)
                return true
            } catch {
                fputs("kurotty notify socket unavailable: \(error)\n", stderr)
                exit(1)
            }
        default:
            return false
        }
    }
}

private func bindSocket(_ descriptor: Int32, to path: String) throws {
    var address = try unixAddress(path: path)
    let length = unixAddressLength(path: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.bind(descriptor, sockaddrPointer, length)
        }
    }
    guard result == 0 else {
        throw KurottyNotificationBridgeError.socketUnavailable
    }
}

private func connectSocket(_ descriptor: Int32, to path: String) throws {
    var address = try unixAddress(path: path)
    let length = unixAddressLength(path: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(descriptor, sockaddrPointer, length)
        }
    }
    guard result == 0 else {
        throw KurottyNotificationBridgeError.socketUnavailable
    }
}

private func unixAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        throw KurottyNotificationBridgeError.socketPathTooLong
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

private func unixAddressLength(path: String) -> socklen_t {
    socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
}

private func setCloseOnExec(_ descriptor: Int32) {
    let flags = Darwin.fcntl(descriptor, F_GETFD)
    if flags >= 0 {
        _ = Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
    }
}
