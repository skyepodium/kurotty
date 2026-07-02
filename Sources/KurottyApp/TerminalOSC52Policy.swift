import Foundation

struct TerminalOSC52Policy {
    enum Operation: Equatable {
        case read
        case write
        case invalid
    }

    enum RejectionReason: Equatable {
        case invalidPayload
        case payloadTooLarge
    }

    struct Metadata: Equatable {
        let selection: String
        let origin: TerminalSecurityPolicy.Origin
        let byteCount: Int?
        let decodedPreview: String?
    }

    struct Evaluation: Equatable, CustomStringConvertible {
        let decision: TerminalSecurityPolicy.Decision
        let operation: Operation
        let securityOperation: TerminalSecurityPolicy.ClipboardOperation
        let metadata: Metadata
        let rejectionReason: RejectionReason?

        var description: String {
            "TerminalOSC52Policy.Evaluation(decision: \(decision), operation: \(operation), securityOperation: \(securityOperation), metadata: \(metadata), rejectionReason: \(String(describing: rejectionReason)))"
        }
    }

    static let defaultMaxDecodedBytes = 1_048_576

    let policy: TerminalSecurityPolicy
    let maxDecodedBytes: Int

    init(policy: TerminalSecurityPolicy, maxDecodedBytes: Int = Self.defaultMaxDecodedBytes) {
        self.policy = policy
        self.maxDecodedBytes = max(0, maxDecodedBytes)
    }

    func evaluate(
        selection: String,
        payload: String,
        origin: TerminalSecurityPolicy.Origin
    ) -> Evaluation {
        if payload == "?" {
            return Evaluation(
                decision: policy.decision(for: .osc52Read, origin: origin),
                operation: .read,
                securityOperation: .osc52Read,
                metadata: Metadata(
                    selection: selection,
                    origin: origin,
                    byteCount: 0,
                    decodedPreview: nil
                ),
                rejectionReason: nil
            )
        }

        guard let decodedByteCount = Self.decodedByteCount(forBase64Payload: payload) else {
            return Evaluation(
                decision: .deny,
                operation: .invalid,
                securityOperation: .osc52Write,
                metadata: Metadata(
                    selection: selection,
                    origin: origin,
                    byteCount: nil,
                    decodedPreview: nil
                ),
                rejectionReason: .invalidPayload
            )
        }

        guard decodedByteCount <= maxDecodedBytes else {
            return Evaluation(
                decision: .deny,
                operation: .write,
                securityOperation: .osc52Write,
                metadata: Metadata(
                    selection: selection,
                    origin: origin,
                    byteCount: decodedByteCount,
                    decodedPreview: nil
                ),
                rejectionReason: .payloadTooLarge
            )
        }

        guard Self.isDecodableBase64Payload(payload) else {
            return Evaluation(
                decision: .deny,
                operation: .invalid,
                securityOperation: .osc52Write,
                metadata: Metadata(
                    selection: selection,
                    origin: origin,
                    byteCount: nil,
                    decodedPreview: nil
                ),
                rejectionReason: .invalidPayload
            )
        }

        return Evaluation(
            decision: policy.decision(for: .osc52Write, origin: origin),
            operation: .write,
            securityOperation: .osc52Write,
            metadata: Metadata(
                selection: selection,
                origin: origin,
                byteCount: decodedByteCount,
                decodedPreview: nil
            ),
            rejectionReason: nil
        )
    }

    private static func decodedByteCount(forBase64Payload payload: String) -> Int? {
        let characters = Array(payload)
        guard !characters.isEmpty else {
            return 0
        }

        var paddingStart: Int?
        var explicitPaddingCount = 0

        for (index, character) in characters.enumerated() {
            if character == "=" {
                if paddingStart == nil {
                    paddingStart = index
                }
                explicitPaddingCount += 1
                continue
            }

            guard paddingStart == nil, character.isBase64PayloadCharacter else {
                return nil
            }
        }

        guard explicitPaddingCount <= 2 else {
            return nil
        }

        let remainder = characters.count % 4
        guard remainder != 1 else {
            return nil
        }

        let inferredPaddingCount = remainder == 0 ? 0 : 4 - remainder
        let paddedLength = characters.count + inferredPaddingCount
        let totalPaddingCount = explicitPaddingCount + inferredPaddingCount

        guard totalPaddingCount <= 2 else {
            return nil
        }

        return (paddedLength / 4 * 3) - totalPaddingCount
    }

    private static func isDecodableBase64Payload(_ payload: String) -> Bool {
        var normalizedPayload = payload
        let remainder = normalizedPayload.count % 4
        if remainder != 0 {
            normalizedPayload.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: normalizedPayload) != nil
    }
}

private extension Character {
    var isBase64PayloadCharacter: Bool {
        isASCIIAlphanumeric || self == "+" || self == "/"
    }

    var isASCIIAlphanumeric: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else {
            return false
        }

        return ("A"..."Z").contains(scalar)
            || ("a"..."z").contains(scalar)
            || ("0"..."9").contains(scalar)
    }
}
