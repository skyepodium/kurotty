import Foundation

enum TerminalSubmittedCommandSummary {
    static func notificationBody(from submittedInputText: String) -> String? {
        let summary = submittedInputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard !summary.isEmpty else {
            return nil
        }
        guard summary.count > AppConstants.Notifications.backgroundTaskSummaryMaxCharacters else {
            return summary
        }
        return String(summary.prefix(AppConstants.Notifications.backgroundTaskSummaryMaxCharacters))
    }
}

struct TerminalBackgroundTaskNotificationContent: Equatable {
    let title: String
    let subtitle: String
    let body: String

    static func make(submittedCommand: String?, outputText: String) -> TerminalBackgroundTaskNotificationContent {
        let command = TerminalSubmittedCommandSummary.notificationBody(from: submittedCommand ?? "")
        let body = notificationBody(command: command, outputText: outputText)
        let isCodex = command?.lowercased().split(whereSeparator: { $0.isWhitespace }).first == "codex"
        let title: String
        if isCodex {
            title = codexTitle(for: body)
        } else {
            title = AppConstants.Notifications.backgroundTaskTitle
        }
        return TerminalBackgroundTaskNotificationContent(
            title: title,
            subtitle: command ?? "",
            body: body
        )
    }

    private static func notificationBody(command: String?, outputText: String) -> String {
        if let outputSummary = TerminalNotificationSummary.notificationBodyText(fromOutputText: outputText) {
            return trimmed(outputSummary)
        }
        if let command {
            return trimmed(command)
        }
        return AppConstants.Notifications.backgroundTaskFinishedBody
    }

    private static func codexTitle(for body: String) -> String {
        let lowercasedBody = body.lowercased()
        if lowercasedBody.contains("approval required")
            || lowercasedBody.contains("requires approval")
            || lowercasedBody.contains("needs input")
            || lowercasedBody.contains("waiting for input") {
            return AppConstants.Notifications.codexNeedsInputTitle
        }
        if lowercasedBody.contains("error:")
            || lowercasedBody.contains("failed")
            || lowercasedBody.contains("failure") {
            return AppConstants.Notifications.codexFailedTitle
        }
        return AppConstants.Notifications.codexFinishedTitle
    }

    private static func trimmed(_ body: String) -> String {
        guard body.count > AppConstants.Notifications.backgroundTaskSummaryMaxCharacters else {
            return body
        }
        return String(body.prefix(AppConstants.Notifications.backgroundTaskSummaryMaxCharacters))
    }
}

enum TerminalNotificationSummary {
    static func latestMeaningfulLine(fromVisibleLines lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let meaningfulLine = meaningfulContentLine(from: line) else {
                continue
            }
            return meaningfulLine
        }
        return nil
    }

    static func latestMeaningfulLine(fromOutputText text: String) -> String? {
        let normalizedText = stripTerminalControls(from: text)
            .replacingOccurrences(of: "\r", with: "\n")
        return latestMeaningfulLine(fromVisibleLines: normalizedText.components(separatedBy: .newlines))
    }

    static func latestMeaningfulText(fromOutputText text: String) -> String? {
        let normalizedText = stripTerminalControls(from: text)
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText.components(separatedBy: .newlines)
        var block = [String]()
        for line in lines.reversed() {
            if let meaningfulLine = meaningfulContentLine(from: line) {
                block.append(meaningfulLine)
                continue
            }
            if !block.isEmpty {
                break
            }
        }

        guard !block.isEmpty else {
            return nil
        }
        return block.reversed().joined(separator: "\n")
    }

    static func notificationBodyText(fromOutputText text: String) -> String? {
        let normalizedText = stripTerminalControls(from: text)
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = [String]()
        var previousWasBlank = false
        for line in normalizedText.components(separatedBy: .newlines) {
            guard let meaningfulLine = meaningfulNotificationLine(from: line) else {
                if !lines.isEmpty {
                    previousWasBlank = true
                }
                continue
            }
            if previousWasBlank, !lines.isEmpty {
                lines.append("")
            }
            lines.append(meaningfulLine)
            previousWasBlank = false
        }
        while lines.last == "" {
            lines.removeLast()
        }
        guard !lines.isEmpty else {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    private static func meaningfulNotificationLine(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMeaningfulLine(trimmed) else {
            return nil
        }
        let cleaned = removingInlineStatusFragment(from: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMeaningfulLine(cleaned) else {
            return nil
        }
        if cleaned == trimmed {
            return line.trimmingCharacters(in: .newlines)
        }
        return cleaned
    }

    private static func meaningfulContentLine(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMeaningfulLine(trimmed) else {
            return nil
        }

        let cleaned = removingInlineStatusFragment(from: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMeaningfulLine(cleaned) else {
            return nil
        }
        return cleaned
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
        guard !isUsageStatusLine(line) else {
            return false
        }
        guard !isPromptInputLine(line) else {
            return false
        }
        guard !isShellPromptLine(line) else {
            return false
        }
        return true
    }

    private static func removingInlineStatusFragment(from line: String) -> String {
        guard line.count > 1 else {
            return line
        }

        var searchIndex = line.index(after: line.startIndex)
        while searchIndex < line.endIndex {
            guard let markerRange = line.range(
                of: #"[·•]"#,
                options: .regularExpression,
                range: searchIndex..<line.endIndex
            ) else {
                return line
            }

            let suffix = String(line[markerRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isInlineStatusFragment(suffix) {
                return String(line[..<markerRange.lowerBound])
            }
            searchIndex = markerRange.upperBound
        }

        return line
    }

    private static func isInlineStatusFragment(_ suffix: String) -> Bool {
        guard !suffix.isEmpty else {
            return false
        }

        let firstSegment = suffix
            .components(separatedBy: CharacterSet(charactersIn: "·•"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstSegment.isEmpty else {
            return false
        }

        if firstSegment == "Ready"
            || firstSegment == "Workspace"
            || firstSegment == "No changes"
            || firstSegment == "Clean"
            || firstSegment == "Full Access"
            || firstSegment == "never"
            || firstSegment == "medium"
            || firstSegment == "high"
            || firstSegment == "low"
            || firstSegment.hasPrefix("Context ") {
            return true
        }

        if firstSegment.range(of: #"^gpt-[0-9]"#, options: .regularExpression) != nil {
            return true
        }

        if firstSegment.range(of: #"^Work(?:space)?[0-9]*$"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func stripTerminalControls(from text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\u{1b}" {
                index = Self.index(afterSkippingEscapeSequenceIn: text, from: index)
                continue
            }
            if character.unicodeScalars.allSatisfy({ $0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) {
                index = text.index(after: index)
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    private static func index(afterSkippingEscapeSequenceIn text: String, from escapeIndex: String.Index) -> String.Index {
        var index = text.index(after: escapeIndex)
        guard index < text.endIndex else {
            return index
        }

        if text[index] == "]" {
            index = text.index(after: index)
            while index < text.endIndex {
                if text[index] == "\u{7}" {
                    return text.index(after: index)
                }
                if text[index] == "\u{1b}" {
                    let nextIndex = text.index(after: index)
                    if nextIndex < text.endIndex, text[nextIndex] == "\\" {
                        return text.index(after: nextIndex)
                    }
                }
                index = text.index(after: index)
            }
            return index
        }

        if text[index] == "[" {
            index = text.index(after: index)
            while index < text.endIndex {
                let scalar = text[index].unicodeScalars.first?.value ?? 0
                if (0x40...0x7E).contains(scalar) {
                    return text.index(after: index)
                }
                index = text.index(after: index)
            }
            return index
        }

        return text.index(after: index)
    }

    private static func isDecorativeLine(_ line: String) -> Bool {
        let scalars = line.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else {
            return true
        }

        guard !scalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            return false
        }

        return scalars.allSatisfy { scalar in
            decorativeCharacterScalars().contains(scalar)
                || isBoxDrawingOrBlockElement(scalar)
                || isDashLikeScalar(scalar)
        }
    }

    private static func decorativeCharacterScalars() -> CharacterSet {
        CharacterSet(charactersIn: "-_=+|\\/.:,;`'\"~^·•*…⎯")
    }

    private static func isBoxDrawingOrBlockElement(_ scalar: UnicodeScalar) -> Bool {
        (0x2500...0x259F).contains(Int(scalar.value))
            || (0x2800...0x28FF).contains(Int(scalar.value))
    }

    private static func isDashLikeScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x2010...0x2015).contains(Int(scalar.value))
            || scalar.value == 0x2212
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

    private static func isUsageStatusLine(_ line: String) -> Bool {
        if line == "Weekly limit:" || line == "5h limit:" || line == "Context window:" {
            return true
        }
        if line.range(of: #"^[0-9]+% left \(resets .+\) \|?$"#, options: .regularExpression) != nil {
            return true
        }
        if line.range(of: #"^\[[\s\u{2580}-\u{259F}\u{2800}-\u{28FF}|]+\]\|?$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func isPromptInputLine(_ line: String) -> Bool {
        line.range(of: #"^[›>]\s+\S"#, options: .regularExpression) != nil
    }

    private static func isShellPromptLine(_ line: String) -> Bool {
        if line == "%" || line == "$" || line == "#" {
            return true
        }
        let normalizedLine = line
            .replacingOccurrences(of: "\u{fffd}", with: " ")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        let parts = normalizedLine
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard parts.count >= 2 else {
            return false
        }

        guard promptUsernames().contains(parts[0]) else {
            return false
        }

        return parts.dropFirst().contains { part in
            part == "~" || part.hasPrefix("~/") || part.hasPrefix("/")
        }
    }

    private static func promptUsernames() -> Set<String> {
        var names = Set<String>()
        let userName = NSUserName()
        if !userName.isEmpty {
            names.insert(userName)
        }
        if let environmentUser = ProcessInfo.processInfo.environment["USER"], !environmentUser.isEmpty {
            names.insert(environmentUser)
        }
        return names
    }
}
