import Foundation

enum TerminalNotificationSummary {
    static func latestMeaningfulLine(fromVisibleLines lines: [String]) -> String? {
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isMeaningfulLine(trimmed) else {
                continue
            }
            return trimmed
        }
        return nil
    }

    private static func isMeaningfulLine(_ line: String) -> Bool {
        guard !line.isEmpty else {
            return false
        }
        guard !isDecorativeLine(line) else {
            return false
        }
        guard !isMetadataStatusLine(line) else {
            return false
        }
        guard !isPromptInputLine(line) else {
            return false
        }
        return true
    }

    private static func isDecorativeLine(_ line: String) -> Bool {
        let decorativeScalars = CharacterSet(charactersIn: "-_=─━·•* ")
        return !line.unicodeScalars.contains { !decorativeScalars.contains($0) }
    }

    private static func isMetadataStatusLine(_ line: String) -> Bool {
        let segments = line
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard segments.count >= 5 else {
            return false
        }

        let hasModelSegment = segments.contains { segment in
            segment.range(of: #"^gpt-[0-9]"#, options: .regularExpression) != nil
        }
        let hasCodexStatusSegment = segments.contains { segment in
            segment == "Ready"
                || segment == "Workspace"
                || segment == "No changes"
                || segment == "Clean"
                || segment == "Full Access"
                || segment == "never"
                || segment.hasPrefix("Context ")
        }
        if hasModelSegment && hasCodexStatusSegment {
            return true
        }

        let statusKeywordCount = segments.filter { segment in
            segment == "Ready"
                || segment == "Workspace"
                || segment == "No changes"
                || segment == "Clean"
        }.count
        guard statusKeywordCount >= 2 else {
            return false
        }

        return segments.contains { segment in
            segment.range(of: #"^gpt-[0-9]"#, options: .regularExpression) != nil
                || segment == "medium"
                || segment == "high"
                || segment == "low"
        }
    }

    private static func isPromptInputLine(_ line: String) -> Bool {
        line.range(of: #"^[›>]\s+\S"#, options: .regularExpression) != nil
    }
}
