import Foundation

/// Display metadata for one working-directory group in the history panel.
struct TerminalCommandHistoryDirectoryDisplay: Equatable {
    /// Raw directory path; empty when the shell never reported OSC 7.
    let path: String
    /// Final path component shown emphasized ("terminal" for `~/dev/terminal`).
    let lastComponent: String
    /// Home-abbreviated parent path shown dimmed ("~/dev" for `~/dev/terminal`).
    let parentDisplay: String
}

/// One expandable working-directory node for the history sidebar outline:
/// group metadata plus its commands ordered newest first.
struct TerminalCommandHistoryPanelGroup: Equatable {
    let display: TerminalCommandHistoryDirectoryDisplay
    let entriesNewestFirst: [TerminalCommandHistoryEntry]
}

/// Pure builder that turns persisted history entries into presentable outline
/// groups. Free of AppKit so grouping, filtering, ordering, and formatting
/// stay unit testable.
enum TerminalCommandHistoryRowBuilder {
    private enum Format {
        static let unknownDirectoryLabel = "unknown directory"
        static let homeSymbol = "~"
        static let nowLabel = "now"
        static let detailSeparator = "·"
        static let secondsPerMinute: TimeInterval = 60
        static let secondsPerHour: TimeInterval = 3_600
        static let secondsPerDay: TimeInterval = 86_400
    }

    /// Builds outline groups from newest-first entries: groups are keyed by
    /// working directory, ordered by their most recent command, and each group
    /// lists its commands newest first.
    static func groups(
        entriesNewestFirst: [TerminalCommandHistoryEntry],
        filter: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [TerminalCommandHistoryPanelGroup] {
        let visibleEntries = entriesNewestFirst.filter { entry in
            matches(entry: entry, filter: filter)
        }
        guard !visibleEntries.isEmpty else {
            return []
        }

        var groupOrder: [String] = []
        var groupedEntries: [String: [TerminalCommandHistoryEntry]] = [:]
        for entry in visibleEntries {
            let key = entry.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if groupedEntries[key] == nil {
                groupOrder.append(key)
            }
            groupedEntries[key, default: []].append(entry)
        }

        return groupOrder.map { key in
            TerminalCommandHistoryPanelGroup(
                display: directoryDisplay(for: key, homeDirectory: homeDirectory),
                entriesNewestFirst: groupedEntries[key] ?? []
            )
        }
    }

    /// Case-insensitive substring/token match over command text and directory.
    static func matches(entry: TerminalCommandHistoryEntry, filter: String) -> Bool {
        let tokens = filter
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else {
            return true
        }
        let haystack = "\(entry.commandText) \(entry.cwd ?? "")".lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }

    static func directoryDisplay(
        for path: String,
        homeDirectory: String
    ) -> TerminalCommandHistoryDirectoryDisplay {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TerminalCommandHistoryDirectoryDisplay(
                path: "",
                lastComponent: Format.unknownDirectoryLabel,
                parentDisplay: ""
            )
        }

        let abbreviated = abbreviatedPath(trimmed, homeDirectory: homeDirectory)
        guard abbreviated != Format.homeSymbol else {
            return TerminalCommandHistoryDirectoryDisplay(
                path: trimmed,
                lastComponent: Format.homeSymbol,
                parentDisplay: ""
            )
        }

        let components = abbreviated.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let lastComponent = components.last else {
            return TerminalCommandHistoryDirectoryDisplay(
                path: trimmed,
                lastComponent: abbreviated,
                parentDisplay: ""
            )
        }
        var parentDisplay = components.dropLast().joined(separator: "/")
        if abbreviated.hasPrefix("/"), !parentDisplay.hasPrefix(Format.homeSymbol) {
            parentDisplay = "/" + parentDisplay
        }
        return TerminalCommandHistoryDirectoryDisplay(
            path: trimmed,
            lastComponent: lastComponent,
            parentDisplay: parentDisplay
        )
    }

    static func abbreviatedPath(_ path: String, homeDirectory: String) -> String {
        guard !homeDirectory.isEmpty else {
            return path
        }
        if path == homeDirectory {
            return Format.homeSymbol
        }
        if path.hasPrefix(homeDirectory + "/") {
            return Format.homeSymbol + "/" + path.dropFirst(homeDirectory.count + 1)
        }
        return path
    }

    /// Compact relative age: "now" under a minute, then "3m", "2h", "5d".
    /// Future or invalid timestamps clamp to "now".
    static func relativeTimeLabel(from date: Date, to now: Date) -> String {
        let elapsedSeconds = now.timeIntervalSince(date)
        guard elapsedSeconds >= Format.secondsPerMinute else {
            return Format.nowLabel
        }
        if elapsedSeconds < Format.secondsPerHour {
            return "\(Int(elapsedSeconds / Format.secondsPerMinute))m"
        }
        if elapsedSeconds < Format.secondsPerDay {
            return "\(Int(elapsedSeconds / Format.secondsPerHour))h"
        }
        return "\(Int(elapsedSeconds / Format.secondsPerDay))d"
    }

    /// Trailing detail for a command row: relative age, plus the dimmed exit
    /// code after the time for failed commands ("3m · 1").
    static func trailingDetailLabel(for entry: TerminalCommandHistoryEntry, now: Date) -> String {
        let time = relativeTimeLabel(from: entry.finishedAt, to: now)
        guard let exitCode = entry.exitCode, exitCode != 0 else {
            return time
        }
        return "\(time) \(Format.detailSeparator) \(exitCode)"
    }
}

/// Replay support for persisted history entries. Persisted entries have no live
/// terminal span, so a synthetic replay candidate carries the command text into
/// the existing dispatcher gate, which refuses to run without explicit user
/// confirmation.
enum TerminalCommandHistoryReplay {
    /// Synthetic span identity for history-sourced replay candidates; history
    /// entries are not addressable terminal spans.
    private static let syntheticSpanID = -1

    static func replayCandidate(for entry: TerminalCommandHistoryEntry) -> TerminalCommandReplayCandidate? {
        let commandText = entry.commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandText.isEmpty else {
            return nil
        }
        return TerminalCommandReplayCandidate(
            spanID: syntheticSpanID,
            reference: TerminalCommandSpanReference(
                spanID: syntheticSpanID,
                startBoundarySequence: 0,
                endBoundarySequence: nil
            ),
            commandText: commandText,
            cwd: entry.cwd,
            exitCode: entry.exitCode,
            requiresExplicitUserConfirmation: true
        )
    }
}
