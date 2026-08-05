import Foundation

/// Which AI coding agent wrote a transcript. Adding a third agent means adding
/// a case here plus one `AgentSessionScanning` implementation; nothing in the
/// panel or the store is agent-specific.
enum AgentSessionKind: String, CaseIterable, Codable, Sendable {
    case claudeCode
    case codex

    /// Product names are proper nouns and stay untranslated.
    var displayName: String {
        switch self {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex"
        }
    }

    var shortLabel: String {
        switch self {
        case .claudeCode:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }

    var symbolName: String {
        switch self {
        case .claudeCode:
            return "sparkles"
        case .codex:
            return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Executable invoked to resume a stored session.
    var resumeExecutable: String {
        switch self {
        case .claudeCode:
            return "claude"
        case .codex:
            return "codex"
        }
    }

    /// Arguments placed between the executable and the session identifier.
    /// `claude --resume <id>` versus `codex resume <id>`.
    var resumeArgumentsBeforeSessionID: [String] {
        switch self {
        case .claudeCode:
            return ["--resume"]
        case .codex:
            return ["resume"]
        }
    }
}

/// Index metadata for one agent session transcript that already exists on disk.
///
/// Privacy contract: this is metadata only. Kurotty never copies transcript
/// content into its own storage; records live in memory for the lifetime of
/// the process and the prompt excerpts exist purely to label a row.
struct AgentSessionRecord: Equatable, Sendable {
    let agent: AgentSessionKind
    let sessionID: String
    let title: String
    let cwd: String
    let gitBranch: String?
    let updatedAt: Date
    let createdAt: Date
    let messageCount: Int
    /// True when the transcript was larger than the full-read threshold and
    /// only a bounded head/tail window was parsed, so `messageCount` is a
    /// lower bound rather than an exact total.
    let isTranscriptTruncated: Bool
    let firstUserPrompt: String?
    let lastUserPrompt: String?
    let filePath: String

    init(
        agent: AgentSessionKind,
        sessionID: String,
        title: String,
        cwd: String,
        gitBranch: String? = nil,
        updatedAt: Date,
        createdAt: Date,
        messageCount: Int,
        isTranscriptTruncated: Bool = false,
        firstUserPrompt: String? = nil,
        lastUserPrompt: String? = nil,
        filePath: String
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.messageCount = messageCount
        self.isTranscriptTruncated = isTranscriptTruncated
        self.firstUserPrompt = firstUserPrompt
        self.lastUserPrompt = lastUserPrompt
        self.filePath = filePath
    }
}

/// How index rows are bucketed into outline groups.
enum AgentSessionGrouping: String, CaseIterable, Sendable {
    /// One group per working directory, labeled by its last path component.
    case project
    /// One group per parent folder of the working directory.
    case folder
    /// One group per agent kind.
    case agent
}

enum AgentSessionSort: String, CaseIterable, Sendable {
    case updated
    case created
}

/// One expandable node for the agent-session sidebar outline, mirroring
/// `TerminalCommandHistoryPanelGroup`.
struct AgentSessionPanelGroup: Equatable {
    let display: TerminalCommandHistoryDirectoryDisplay
    let sessionsNewestFirst: [AgentSessionRecord]
}

/// Pure builder that turns index records into presentable outline groups.
/// Free of AppKit so grouping, filtering, ordering, and formatting stay unit
/// testable without touching the user's home directory.
enum AgentSessionRowBuilder {
    private enum Format {
        static let unknownDirectoryLabel = "unknown directory"
        static let detailSeparator = "·"
        static let truncatedCountSuffix = "+"
    }

    static func sorted(_ records: [AgentSessionRecord], by sort: AgentSessionSort) -> [AgentSessionRecord] {
        records.sorted { lhs, rhs in
            let lhsDate = sort == .updated ? lhs.updatedAt : lhs.createdAt
            let rhsDate = sort == .updated ? rhs.updatedAt : rhs.createdAt
            guard lhsDate == rhsDate else {
                return lhsDate > rhsDate
            }
            return lhs.sessionID < rhs.sessionID
        }
    }

    /// Builds outline groups: records are filtered, sorted newest first, then
    /// bucketed by the grouping key in first-appearance order so the most
    /// recently touched group leads.
    static func groups(
        records: [AgentSessionRecord],
        grouping: AgentSessionGrouping = .project,
        sort: AgentSessionSort = .updated,
        filter: String = "",
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [AgentSessionPanelGroup] {
        let visible = sorted(records, by: sort).filter { matches(record: $0, filter: filter) }
        guard !visible.isEmpty else {
            return []
        }

        var groupOrder: [String] = []
        var grouped: [String: [AgentSessionRecord]] = [:]
        for record in visible {
            let key = groupKey(for: record, grouping: grouping)
            if grouped[key] == nil {
                groupOrder.append(key)
            }
            grouped[key, default: []].append(record)
        }

        return groupOrder.map { key in
            AgentSessionPanelGroup(
                display: groupDisplay(
                    key: key,
                    grouping: grouping,
                    homeDirectory: homeDirectory
                ),
                sessionsNewestFirst: grouped[key] ?? []
            )
        }
    }

    static func groupKey(for record: AgentSessionRecord, grouping: AgentSessionGrouping) -> String {
        let cwd = record.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        switch grouping {
        case .project:
            return cwd
        case .folder:
            guard !cwd.isEmpty else {
                return ""
            }
            let parent = (cwd as NSString).deletingLastPathComponent
            return parent.isEmpty ? cwd : parent
        case .agent:
            return record.agent.rawValue
        }
    }

    private static func groupDisplay(
        key: String,
        grouping: AgentSessionGrouping,
        homeDirectory: String
    ) -> TerminalCommandHistoryDirectoryDisplay {
        guard grouping != .agent else {
            let agent = AgentSessionKind(rawValue: key)
            return TerminalCommandHistoryDirectoryDisplay(
                path: "",
                lastComponent: agent?.displayName ?? Format.unknownDirectoryLabel,
                parentDisplay: ""
            )
        }
        return TerminalCommandHistoryRowBuilder.directoryDisplay(
            for: key,
            homeDirectory: homeDirectory
        )
    }

    /// Case-insensitive token match over title, prompts, cwd, branch, and
    /// agent name. Each token matches as a substring, or as a subsequence so a
    /// typed abbreviation such as "krt" still finds "kurotty".
    static func matches(record: AgentSessionRecord, filter: String) -> Bool {
        let tokens = filter
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else {
            return true
        }
        let haystack = [
            record.title,
            record.firstUserPrompt ?? "",
            record.lastUserPrompt ?? "",
            record.cwd,
            record.gitBranch ?? "",
            record.agent.displayName,
        ]
        .joined(separator: " ")
        .lowercased()

        return tokens.allSatisfy { token in
            haystack.contains(token) || fuzzyMatches(haystack: haystack, needle: token)
        }
    }

    /// In-order subsequence match; both inputs are already lowercased.
    static func fuzzyMatches(haystack: String, needle: String) -> Bool {
        guard !needle.isEmpty else {
            return true
        }
        var needleIndex = needle.startIndex
        for character in haystack {
            guard needleIndex < needle.endIndex else {
                break
            }
            if character == needle[needleIndex] {
                needleIndex = needle.index(after: needleIndex)
            }
        }
        return needleIndex == needle.endIndex
    }

    /// Home-abbreviated working directory shown dimmed under the title.
    static func directoryLabel(
        for record: AgentSessionRecord,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let cwd = record.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else {
            return Format.unknownDirectoryLabel
        }
        return TerminalCommandHistoryRowBuilder.abbreviatedPath(cwd, homeDirectory: homeDirectory)
    }

    /// Trailing relative age for a session row, matching the history panel's
    /// compact "now/3m/2h/5d" vocabulary.
    static func relativeTimeLabel(for record: AgentSessionRecord, now: Date) -> String {
        TerminalCommandHistoryRowBuilder.relativeTimeLabel(from: record.updatedAt, to: now)
    }

    /// Message-count badge text. Partially read transcripts report a lower
    /// bound so the badge never claims an exact total it did not observe.
    static func messageCountLabel(for record: AgentSessionRecord) -> String {
        guard record.isTranscriptTruncated else {
            return "\(record.messageCount)"
        }
        return "\(record.messageCount)\(Format.truncatedCountSuffix)"
    }

    /// Secondary detail used in tooltips: agent name plus git branch.
    static func agentDetailLabel(for record: AgentSessionRecord) -> String {
        guard let branch = record.gitBranch, !branch.isEmpty else {
            return record.agent.displayName
        }
        return "\(record.agent.displayName) \(Format.detailSeparator) \(branch)"
    }
}

/// Pure construction of the shell command that resumes a stored session.
///
/// The command is only ever inserted at the prompt: there is no execute path
/// in v1, so the user always presses Return themselves.
enum AgentSessionResumeCommand {
    private enum Syntax {
        static let changeDirectory = "cd"
        static let separator = "&&"
        /// Characters that never need shell quoting. Session identifiers are
        /// UUIDs in practice, so they stay bare; anything unexpected is quoted.
        static let safeCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        )
    }

    /// `cd '<cwd>' && claude --resume <id>`, or just the resume invocation when
    /// the transcript never recorded a working directory.
    static func command(for record: AgentSessionRecord) -> String {
        let resume = resumeInvocation(for: record)
        let cwd = record.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else {
            return resume
        }
        let quotedDirectory = TerminalShellPathQuoting.quoted(cwd)
        return "\(Syntax.changeDirectory) \(quotedDirectory) \(Syntax.separator) \(resume)"
    }

    static func resumeInvocation(for record: AgentSessionRecord) -> String {
        let arguments = [record.agent.resumeExecutable]
            + record.agent.resumeArgumentsBeforeSessionID
            + [quotedIfNeeded(record.sessionID)]
        return arguments.joined(separator: " ")
    }

    private static func quotedIfNeeded(_ value: String) -> String {
        guard !value.isEmpty else {
            return TerminalShellPathQuoting.quoted(value)
        }
        let isSafe = value.unicodeScalars.allSatisfy { Syntax.safeCharacters.contains($0) }
        return isSafe ? value : TerminalShellPathQuoting.quoted(value)
    }
}
