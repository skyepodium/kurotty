import Foundation

struct TerminalActivityCompletionTracker {
    struct Candidate: Equatable {
        let generation: UInt64
        let submittedText: String
        let resultText: String?
    }

    private(set) var generation: UInt64 = 0
    private var submittedText: String?
    private var baselineLines = Set<String>()
    private var observedOutputBytes = 0
    private var didComplete = false

    mutating func begin(submittedText: String, baselineText: String = "") {
        generation &+= 1
        self.submittedText = submittedText
        baselineLines = TerminalActivityOutputSummary.normalizedLines(from: baselineText)
        observedOutputBytes = 0
        didComplete = false
    }

    mutating func recordOutput(byteCount: Int) -> UInt64? {
        guard submittedText != nil, !didComplete, byteCount > 0 else { return nil }
        observedOutputBytes += byteCount
        return generation
    }

    mutating func completeIfCurrent(
        generation expectedGeneration: UInt64,
        currentText: String = ""
    ) -> Candidate? {
        guard generation == expectedGeneration,
              !didComplete,
              observedOutputBytes >= AppConstants.Notifications.activityCompletionMinimumOutputBytes,
              let submittedText else {
            return nil
        }
        didComplete = true
        return Candidate(
            generation: generation,
            submittedText: submittedText,
            resultText: TerminalActivityOutputSummary.make(
                submittedText: submittedText,
                baselineLines: baselineLines,
                currentText: currentText
            )
        )
    }

    mutating func suppressCurrent() {
        didComplete = true
    }
}

enum TerminalActivityOutputSummary {
    static func make(
        submittedText: String,
        baselineLines: Set<String>,
        currentText: String
    ) -> String? {
        let submitted = normalize(submittedText)
        let lines = normalizedLinesInOrder(from: currentText)
        let submittedLineIndex = lines.lastIndex { line in
            looksLikeSubmittedInput(line, submitted: submitted)
        }
        let outputStartIndex = submittedLineIndex.map { lines.index(after: $0) } ?? lines.startIndex
        var blocks = [[String]]()
        var currentBlock = [String]()

        for line in lines[outputStartIndex...] {
            let isResultLine = !line.isEmpty &&
                !baselineLines.contains(line) &&
                !looksLikeSubmittedInput(line, submitted: submitted) &&
                !looksLikeInteractivePrompt(line) &&
                !looksLikeControlHint(line) &&
                !looksLikeShortTimedStatus(line) &&
                !looksLikeTerminalChrome(line)
            if isResultLine {
                currentBlock.append(line)
            } else if !currentBlock.isEmpty {
                blocks.append(currentBlock)
                currentBlock.removeAll(keepingCapacity: true)
            }
        }
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }

        guard let best = blocks.last?.joined(separator: " "), informationScore(best) >= 2 else {
            return nil
        }
        return String(best.prefix(AppConstants.Notifications.activityResultMaxCharacters))
    }

    static func normalizedLines(from text: String) -> Set<String> {
        Set(normalizedLinesInOrder(from: text))
    }

    private static func normalizedLinesInOrder(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map(normalize)
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func informationScore(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { score, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                score += 1
            }
        }
    }

    private static func looksLikeControlHint(_ text: String) -> Bool {
        let shortcutTokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "|" })
            .filter { $0.contains("+") || $0.contains(":") }
        return shortcutTokens.count >= 2
    }

    private static func looksLikeInteractivePrompt(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return "›❯>$#".contains(first)
    }

    private static func looksLikeTerminalChrome(_ text: String) -> Bool {
        let separators = text.filter { "·│|".contains($0) }.count
        guard separators >= 3 else { return false }
        let fields = text.split(whereSeparator: { $0.isWhitespace || "·│|".contains($0) })
        return fields.count >= 4
    }

    private static func looksLikeSubmittedInput(_ text: String, submitted: String) -> Bool {
        guard !submitted.isEmpty else { return false }
        let normalizedText = normalize(text)
        return normalizedText == submitted || normalizedText.hasSuffix(submitted)
    }

    private static func looksLikeShortTimedStatus(_ text: String) -> Bool {
        guard text.count <= 64 else { return false }
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        return tokens.contains { token in
            let normalized = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard normalized.hasSuffix("ms") || normalized.hasSuffix("s") else { return false }
            let number = normalized.hasSuffix("ms")
                ? normalized.dropLast(2)
                : normalized.dropLast()
            return Double(number) != nil
        }
    }
}

enum TerminalNotificationContext {
    static func programName(
        runtimeCommand: String?,
        terminalTitle: String,
        currentDirectory: String
    ) -> String {
        if let runtimeCommand {
            let command = URL(fileURLWithPath: runtimeCommand).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty {
                return command.prefix(1).uppercased() + command.dropFirst()
            }
        }
        let normalizedTitle = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = normalizedTitle.components(separatedBy: " - ")
        let candidate = components.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let directoryName = self.directoryName(from: currentDirectory)
        guard !candidate.isEmpty,
              candidate.count <= 48,
              !candidate.contains("/"),
              candidate.caseInsensitiveCompare(directoryName) != .orderedSame,
              candidate.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
              components.count > 1 || !candidate.contains(where: { $0.isWhitespace }) else {
            return AppConstants.Notifications.defaultProgramTitle
        }
        return candidate.prefix(1).uppercased() + candidate.dropFirst()
    }

    static func directoryName(from path: String) -> String {
        let name = URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? AppConstants.Notifications.defaultDirectoryTitle : name
    }
}

struct TerminalActivityCompletionNotificationContent: Equatable {
    let title: String
    let subtitle: String
    let body: String

    static func make(
        resultText: String?,
        runtimeMetadata: TerminalRuntimeNotificationMetadata?,
        terminalTitle: String,
        currentDirectory: String
    ) -> Self {
        let resolvedDirectory = runtimeMetadata?.workingDirectory ?? currentDirectory
        return Self(
            title: TerminalNotificationContext.programName(
                runtimeCommand: runtimeMetadata?.command,
                terminalTitle: terminalTitle,
                currentDirectory: resolvedDirectory
            ),
            subtitle: TerminalNotificationContext.directoryName(from: resolvedDirectory),
            body: resultText ?? AppConstants.Notifications.activityFinishedFallbackBody
        )
    }
}
