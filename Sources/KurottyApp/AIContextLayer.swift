import Foundation

struct AIContextRedactor {
    func redacted(_ text: String) -> String {
        var redactedText = text
        for rule in Self.rules {
            redactedText = rule.apply(to: redactedText)
        }
        return redactedText
    }

    private static let rules: [RedactionRule] = [
        RedactionRule(pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, replacement: "[REDACTED_AWS_KEY]"),
        RedactionRule(pattern: #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, replacement: "[REDACTED_GITHUB_TOKEN]"),
        RedactionRule(pattern: #"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"#, replacement: "[REDACTED_GITHUB_TOKEN]"),
        RedactionRule(pattern: #"\bsk-[A-Za-z0-9][A-Za-z0-9_-]{20,}\b"#, replacement: "[REDACTED_OPENAI_TOKEN]"),
        RedactionRule(
            pattern: #"\b(Authorization\s*:?\s*Bearer\s+)([^\s]+)"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED_BEARER_TOKEN]"
        ),
        RedactionRule(
            pattern: #"\b(password|token|api_key)\s*=\s*([^\s&;]+)"#,
            options: [.caseInsensitive],
            replacement: "$1=[REDACTED_SECRET]"
        ),
    ]
}

struct AIContextEvent: Equatable, CustomStringConvertible {
    let source: String
    let text: String

    var description: String {
        "source=\(source) text=\(text)"
    }
}

struct AIContextSnapshot: Equatable, CustomStringConvertible {
    let command: String
    let output: String
    let cwd: String
    let exitCode: Int?
    let auditSource: String
    let auditNote: String
    let events: [AIContextEvent]

    var description: String {
        let exitCodeText = exitCode.map(String.init) ?? "nil"
        let eventText = events.map(\.description).joined(separator: "\n")
        return """
        AIContextSnapshot auditSource=\(auditSource) auditNote=\(auditNote) exitCode=\(exitCodeText)
        cwd=\(cwd)
        command=\(command)
        output=\(output)
        events=[
        \(eventText)
        ]
        """
    }
}

struct AIContextEventLog {
    private static let redactionLookaheadCharacters = 256

    private let maxEvents: Int
    private let maxTextLength: Int
    private let redactor: AIContextRedactor
    private(set) var events: [AIContextEvent] = []

    init(maxEvents: Int, maxTextLength: Int, redactor: AIContextRedactor = AIContextRedactor()) {
        self.maxEvents = max(0, maxEvents)
        self.maxTextLength = max(0, maxTextLength)
        self.redactor = redactor
    }

    mutating func record(source: String, text: String) {
        events.append(
            AIContextEvent(
                source: sanitized(source),
                text: sanitized(text)
            )
        )
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    func snapshot(
        command: String,
        output: String,
        cwd: String,
        exitCode: Int?,
        auditSource: String,
        auditNote: String
    ) -> AIContextSnapshot {
        AIContextSnapshot(
            command: sanitized(command),
            output: sanitized(output),
            cwd: sanitized(cwd),
            exitCode: exitCode,
            auditSource: sanitized(auditSource),
            auditNote: sanitized(auditNote),
            events: events
        )
    }

    private func sanitized(_ text: String) -> String {
        let boundedText = String(text.prefix(maxTextLength + Self.redactionLookaheadCharacters))
        return String(redactor.redacted(boundedText).prefix(maxTextLength))
    }
}

private struct RedactionRule {
    let pattern: String
    let options: NSRegularExpression.Options
    let replacement: String

    init(
        pattern: String,
        options: NSRegularExpression.Options = [],
        replacement: String
    ) {
        self.pattern = pattern
        self.options = options
        self.replacement = replacement
    }

    func apply(to text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}
