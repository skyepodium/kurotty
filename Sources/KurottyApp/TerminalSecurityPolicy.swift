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
        allowedURLSchemes: ["http", "https", "ssh"],
        trustedURLSchemes: ["http", "https", "file"],
        allowLocalFileLinksWithConfirmation: true,
        aiContextMetadata: AIContextMetadata(
            secretExposure: .redacted,
            rawOutputIncludedByDefault: false
        )
    )

    /// Schemes Kurotty is willing to hand to the system at all. Anything outside
    /// this set is never surfaced as a link and never opened.
    let allowedURLSchemes: Set<String>
    /// Schemes whose destination is inspectable before it is followed: the URL
    /// text is on screen, and opening one lands in a browser or the Finder
    /// rather than executing anything. See `userActivatedLinkDecision`.
    let trustedURLSchemes: Set<String>
    let allowLocalFileLinksWithConfirmation: Bool
    let aiContextMetadata: AIContextMetadata

    init(
        allowedURLSchemes: Set<String>,
        trustedURLSchemes: Set<String> = [],
        allowLocalFileLinksWithConfirmation: Bool,
        aiContextMetadata: AIContextMetadata
    ) {
        self.allowedURLSchemes = allowedURLSchemes
        self.trustedURLSchemes = trustedURLSchemes
        self.allowLocalFileLinksWithConfirmation = allowLocalFileLinksWithConfirmation
        self.aiContextMetadata = aiContextMetadata
    }

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

    /// The decision for a link the user activated themselves, with the modifier
    /// held, on text they can read.
    ///
    /// That gesture is already the intent, so a trusted scheme opens with no
    /// second dialog; confirming the safe 95% only teaches people to dismiss the
    /// sheet unread, which is exactly when it stops protecting them. An
    /// allowlisted-but-untrusted scheme — `ssh` today, since following one can
    /// start a connection — still asks, and a scheme outside the allowlist stays
    /// refused rather than being downgraded to a question.
    ///
    /// This is deliberately separate from `linkOpenDecision`, which also gates
    /// automatic link detection and agent-initiated URL opens; neither of those
    /// carries a user gesture and neither may inherit this relaxation.
    func userActivatedLinkDecision(for url: URL) -> Decision {
        let decision = linkOpenDecision(for: url)
        guard decision == .ask, let scheme = url.scheme?.lowercased() else {
            return decision
        }
        return trustedURLSchemes.contains(scheme) ? .allow : .ask
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
        return host.lowercased() == "localhost"
    }
}
