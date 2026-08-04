import Foundation
import Network

/// One authenticated status report posted by an agent hook.
struct AgentStatusHookReport: Equatable, Sendable {
    let paneIdentifier: String
    let status: AgentActivityStatus
}

/// Pure request-admission rules for the loopback hook server.
///
/// Everything here is a value transformation so it can be tested without
/// opening a socket. The server itself only does I/O.
enum AgentStatusHookRequestPolicy {
    enum Rejection: String, Error, Equatable, Sendable {
        case malformedRequest
        case unsupportedMethod
        case unknownPath
        case missingToken
        case invalidToken
        case bodyTooLarge
        case malformedBody
        case unknownState
    }

    struct Request: Equatable, Sendable {
        let method: String
        let path: String
        let token: String?
        let body: Data
    }

    /// Constant-time-ish comparison. The token never appears in a log or error.
    static func isAuthorized(presentedToken: String?, expectedToken: String) -> Bool {
        guard !expectedToken.isEmpty else {
            return false
        }
        guard let presentedToken, !presentedToken.isEmpty else {
            return false
        }
        let presented = Array(presentedToken.utf8)
        let expected = Array(expectedToken.utf8)
        guard presented.count == expected.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in 0..<expected.count {
            difference |= presented[index] ^ expected[index]
        }
        return difference == 0
    }

    static func admit(
        request: Request,
        expectedToken: String,
        now: Date = Date()
    ) -> Result<AgentStatusHookReport, Rejection> {
        guard request.method == "POST" else {
            return .failure(.unsupportedMethod)
        }
        guard request.path == AppConstants.AgentStatus.hookRequestPath else {
            return .failure(.unknownPath)
        }
        guard request.token != nil else {
            return .failure(.missingToken)
        }
        guard isAuthorized(presentedToken: request.token, expectedToken: expectedToken) else {
            return .failure(.invalidToken)
        }
        guard request.body.count <= AppConstants.AgentStatus.hookMaximumBodyBytes else {
            return .failure(.bodyTooLarge)
        }
        return decode(body: request.body, now: now)
    }

    private struct Body: Decodable {
        let paneId: String
        let state: String
        let agent: String?
        let detail: String?
    }

    /// Decodes the fixed hook body. The payload is data only: no field is ever
    /// executed, interpolated into a command, or written to disk.
    static func decode(body: Data, now: Date = Date()) -> Result<AgentStatusHookReport, Rejection> {
        guard let payload = try? JSONDecoder().decode(Body.self, from: body) else {
            return .failure(.malformedBody)
        }
        guard !payload.paneId.isEmpty else {
            return .failure(.malformedBody)
        }
        guard let state = AgentActivityState(rawValue: payload.state) else {
            return .failure(.unknownState)
        }
        return .success(AgentStatusHookReport(
            paneIdentifier: payload.paneId,
            status: AgentActivityStatus(
                state: state,
                agentName: payload.agent,
                detail: payload.detail,
                updatedAt: now
            )
        ))
    }

    /// Minimal HTTP/1.1 request-line + header parse. Returns `nil` while the
    /// headers are still incomplete so the caller keeps reading, and rejects
    /// anything larger than the request cap.
    static func parseRequest(buffer: Data) -> Result<Request, Rejection>? {
        guard buffer.count <= AppConstants.AgentStatus.hookMaximumRequestBytes else {
            return .failure(.bodyTooLarge)
        }
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = buffer.range(of: separator) else {
            return nil
        }
        let headerData = buffer[buffer.startIndex..<separatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(.malformedRequest)
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(.malformedRequest)
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            return .failure(.malformedRequest)
        }
        let method = String(requestParts[0]).uppercased()
        let path = String(requestParts[1].split(separator: "?").first ?? requestParts[1])

        var token: String?
        var declaredContentLength = 0
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }
            let name = String(line[line.startIndex..<colonIndex]).lowercased()
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            if name == AppConstants.AgentStatus.hookTokenHeaderName.lowercased() {
                token = value
            } else if name == "content-length" {
                declaredContentLength = Int(value) ?? 0
            }
        }
        guard declaredContentLength <= AppConstants.AgentStatus.hookMaximumBodyBytes else {
            return .failure(.bodyTooLarge)
        }
        let body = buffer[separatorRange.upperBound...]
        guard body.count >= declaredContentLength else {
            return nil
        }
        let boundedBody = body.prefix(declaredContentLength)
        return .success(Request(method: method, path: path, token: token, body: Data(boundedBody)))
    }
}

/// Loopback-only HTTP listener that accepts agent status posts.
///
/// Security decisions, all deliberate:
/// - Binds to `127.0.0.1` on an OS-assigned free port. It is never reachable
///   off-host and no port is published anywhere except the PTY environment.
/// - Requires an exact per-launch random token in `X-Kurotty-Hook-Token`.
///   Requests without it are answered `401` and dropped.
/// - Caps the request at `hookMaximumRequestBytes` and the body at
///   `hookMaximumBodyBytes`, then closes the connection.
/// - The payload is parsed as data only. Nothing in it is executed, spawned,
///   or written to disk, and its contents are never logged.
///
/// Concurrency contract: every mutable field is touched only on `queue`, which
/// is also the listener's callback queue, so the `@unchecked Sendable`
/// conformance is bounded by that single queue.
final class AgentStatusHookServer: @unchecked Sendable {
    /// Called on `queue` for each admitted report.
    var onReport: (@Sendable (AgentStatusHookReport) -> Void)?

    private let queue = DispatchQueue(label: AppConstants.AgentStatus.hookQueueLabel)
    private let token: String
    private var listener: NWListener?
    private var boundPort: UInt16?

    init(token: String = AgentStatusHookServer.makeToken()) {
        self.token = token
    }

    /// A fresh 256-bit token per launch, hex encoded so it is shell-safe.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: AppConstants.AgentStatus.hookTokenByteCount)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Environment the PTY must carry for hooks to reach this server. Empty
    /// until the listener has a bound port, so a failed start injects nothing.
    func shellEnvironment(paneIdentifier: String) -> [String: String] {
        var port: UInt16?
        queue.sync {
            port = boundPort
        }
        guard let port, !paneIdentifier.isEmpty else {
            return [:]
        }
        return [
            AppConstants.AgentStatus.paneIdentifierEnvironmentName: paneIdentifier,
            AppConstants.AgentStatus.hookPortEnvironmentName: String(port),
            AppConstants.AgentStatus.hookTokenEnvironmentName: token,
        ]
    }

    var hookToken: String {
        token
    }

    /// Starts the listener. Failures are reported through `completion` and never
    /// crash: hooks simply stay unavailable.
    func start(completion: (@Sendable (Result<UInt16, Error>) -> Void)? = nil) {
        queue.async { [self] in
            guard listener == nil else {
                if let boundPort {
                    completion?(.success(boundPort))
                }
                return
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(AppConstants.AgentStatus.hookLoopbackHost),
                port: .any
            )
            parameters.allowLocalEndpointReuse = true
            do {
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection: connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else {
                        return
                    }
                    switch state {
                    case .ready:
                        let port = listener.port?.rawValue
                        self.boundPort = port
                        guard let port else {
                            completion?(.failure(AgentStatusHookServerError.portUnavailable))
                            return
                        }
                        completion?(.success(port))
                    case .failed(let error):
                        self.boundPort = nil
                        completion?(.failure(error))
                    default:
                        break
                    }
                }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                completion?(.failure(error))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            boundPort = nil
        }
    }

    private func accept(connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: AppConstants.AgentStatus.hookMaximumRequestBytes
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            guard nextBuffer.count <= AppConstants.AgentStatus.hookMaximumRequestBytes else {
                self.respond(connection: connection, statusLine: "HTTP/1.1 413 Payload Too Large")
                return
            }
            guard let parsed = AgentStatusHookRequestPolicy.parseRequest(buffer: nextBuffer) else {
                guard !isComplete else {
                    self.respond(connection: connection, statusLine: "HTTP/1.1 400 Bad Request")
                    return
                }
                self.receive(connection: connection, buffer: nextBuffer)
                return
            }
            self.handle(parsed: parsed, connection: connection)
        }
    }

    private func handle(
        parsed: Result<AgentStatusHookRequestPolicy.Request, AgentStatusHookRequestPolicy.Rejection>,
        connection: NWConnection
    ) {
        switch parsed {
        case .failure:
            respond(connection: connection, statusLine: "HTTP/1.1 400 Bad Request")
        case .success(let request):
            switch AgentStatusHookRequestPolicy.admit(request: request, expectedToken: token) {
            case .failure(let rejection):
                respond(connection: connection, statusLine: Self.statusLine(for: rejection))
            case .success(let report):
                onReport?(report)
                respond(connection: connection, statusLine: "HTTP/1.1 204 No Content")
            }
        }
    }

    private static func statusLine(for rejection: AgentStatusHookRequestPolicy.Rejection) -> String {
        switch rejection {
        case .missingToken, .invalidToken:
            return "HTTP/1.1 401 Unauthorized"
        case .unknownPath:
            return "HTTP/1.1 404 Not Found"
        case .unsupportedMethod:
            return "HTTP/1.1 405 Method Not Allowed"
        case .bodyTooLarge:
            return "HTTP/1.1 413 Payload Too Large"
        case .malformedRequest, .malformedBody, .unknownState:
            return "HTTP/1.1 400 Bad Request"
        }
    }

    private func respond(connection: NWConnection, statusLine: String) {
        let response = Data("\(statusLine)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum AgentStatusHookServerError: Error {
    case portUnavailable
}
