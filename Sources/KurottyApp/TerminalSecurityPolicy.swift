import Foundation

struct TerminalSecurityPolicy: Equatable {
    enum Decision: Equatable {
        case allow
        case ask
        case deny
    }

    enum Origin: Equatable {
        case local
        case remote
        case unknown
    }

    enum ClipboardOperation: Equatable {
        case clipboardRead
        case clipboardWrite
        case osc52Read
        case osc52Write
    }

    enum SecretExposure: Equatable {
        case redacted
        case raw
    }

    struct AIContextRequest: Equatable {
        let rawOutputRequested: Bool
        let secretRedactionEnabled: Bool
    }

    struct AIContextMetadata: Equatable {
        let secretExposure: SecretExposure
        let rawOutputIncludedByDefault: Bool
    }

    static let `default` = TerminalSecurityPolicy(
        allowedURLSchemes: ["http", "https"],
        allowLocalFileLinksWithConfirmation: true,
        aiContextMetadata: AIContextMetadata(
            secretExposure: .redacted,
            rawOutputIncludedByDefault: false
        )
    )

    let allowedURLSchemes: Set<String>
    let allowLocalFileLinksWithConfirmation: Bool
    let aiContextMetadata: AIContextMetadata

    func decision(for operation: ClipboardOperation, origin: Origin) -> Decision {
        switch operation {
        case .clipboardRead, .osc52Read:
            return origin == .remote ? .deny : .ask
        case .clipboardWrite, .osc52Write:
            return origin == .local ? .allow : .ask
        }
    }

    func linkOpenDecision(for url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .deny
        }

        if scheme == "file" {
            guard allowLocalFileLinksWithConfirmation, Self.isLocalFileURLHost(url.host) else {
                return .deny
            }
            return .ask
        }

        return allowedURLSchemes.contains(scheme) ? .ask : .deny
    }

    func aiContextExportDecision(_ request: AIContextRequest) -> Decision {
        guard request.secretRedactionEnabled else {
            return .deny
        }
        return request.rawOutputRequested ? .ask : .allow
    }

    private static func isLocalFileURLHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else {
            return true
        }
        return host == "localhost"
    }
}
