import AppKit

struct TerminalCommandPaletteEntry: Equatable {
    let command: TerminalCommand
    let title: String
    let id: String
    let category: TerminalCommandCategory
    let categoryTitle: String
    let shortcutLabel: String?
    let aliases: [String]
}

struct TerminalCommandSpanPaletteEntry: Equatable {
    let command: TerminalCommandSpanCommand
    let title: String
    let subtitle: String
    let id: String
    let categoryTitle: String
    let requiresExplicitApproval: Bool
    let aliases: [String]
}

struct TerminalCommandPalette {
    let entries: [TerminalCommandPaletteEntry]
    let commandSpanEntries: [TerminalCommandSpanPaletteEntry]

    init(
        registry: TerminalCommandRegistry = .default,
        includesCommandSpanCommands: Bool = false
    ) {
        self.entries = registry.windowCommands.map { command in
            TerminalCommandPaletteEntry(
                command: command,
                title: command.title,
                id: command.id.rawValue,
                category: command.category,
                categoryTitle: command.category.paletteTitle,
                shortcutLabel: command.shortcut?.paletteDisplayLabel,
                aliases: command.searchTokens
            )
        }
        self.commandSpanEntries = includesCommandSpanCommands
            ? registry.commandSpanCommands.map { command in
                TerminalCommandSpanPaletteEntry(
                    command: command,
                    title: command.title,
                    subtitle: command.subtitle,
                    id: command.id.rawValue,
                    categoryTitle: command.category.paletteTitle,
                    requiresExplicitApproval: command.approvalPolicy == .explicitUserConfirmation,
                    aliases: command.searchTokens
                )
            }
            : []
    }

    func results(
        for query: String,
        category: TerminalCommandCategory? = nil
    ) -> [TerminalCommandPaletteEntry] {
        let visibleEntries = entries.filter { entry in
            category == nil || entry.category == category
        }
        let normalizedQuery = query.paletteSearchText

        guard !normalizedQuery.isEmpty else {
            return visibleEntries
        }

        return visibleEntries
            .enumerated()
            .compactMap { index, entry -> RankedCommandPaletteEntry? in
                guard let rank = entry.matchRank(for: normalizedQuery) else {
                    return nil
                }
                return RankedCommandPaletteEntry(entry: entry, rank: rank, index: index)
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                return lhs.index < rhs.index
            }
            .map(\.entry)
    }

    func commandSpanResults(for query: String) -> [TerminalCommandSpanPaletteEntry] {
        let normalizedQuery = query.paletteSearchText

        guard !normalizedQuery.isEmpty else {
            return commandSpanEntries
        }

        return commandSpanEntries
            .enumerated()
            .compactMap { index, entry -> RankedCommandSpanPaletteEntry? in
                guard let rank = entry.matchRank(for: normalizedQuery) else {
                    return nil
                }
                return RankedCommandSpanPaletteEntry(entry: entry, rank: rank, index: index)
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                return lhs.index < rhs.index
            }
            .map(\.entry)
    }
}

enum TerminalCommandSpanPaletteActions {
    static func executableCommands(
        for span: TerminalCommandSpan?,
        registry: TerminalCommandRegistry = .default
    ) -> [TerminalCommandSpanCommand] {
        guard let span else {
            return []
        }

        var commandIDs: [TerminalCommandSpanCommandID] = [.copyReference]
        if span.replayCandidate != nil {
            commandIDs.append(.replay)
        }

        return commandIDs.compactMap { id in
            registry.commandSpanCommand(for: id)
        }
    }

    static func registryForPalette(
        commandSpanCommands: [TerminalCommandSpanCommand],
        registry: TerminalCommandRegistry = .default
    ) -> TerminalCommandRegistry {
        TerminalCommandRegistry(
            windowCommands: registry.windowCommands,
            commandSpanCommands: commandSpanCommands
        )
    }
}

private struct RankedCommandPaletteEntry {
    let entry: TerminalCommandPaletteEntry
    let rank: Int
    let index: Int
}

private struct RankedCommandSpanPaletteEntry {
    let entry: TerminalCommandSpanPaletteEntry
    let rank: Int
    let index: Int
}

private extension TerminalCommandPaletteEntry {
    func matchRank(for query: String) -> Int? {
        let normalizedTitle = title.paletteSearchText
        let normalizedID = id.paletteSearchText
        let normalizedCategory = categoryTitle.paletteSearchText
        let normalizedShortcut = shortcutLabel?.paletteSearchText ?? ""
        let normalizedAliases = aliases.map(\.paletteSearchText)

        if normalizedTitle == query {
            return 0
        }
        if normalizedTitle.hasPrefix(query) {
            return 1
        }
        if normalizedTitle.contains(query) {
            return 2
        }
        if normalizedID.hasPrefix(query) {
            return 3
        }
        if normalizedID.contains(query) {
            return 4
        }
        if normalizedCategory.hasPrefix(query) || normalizedCategory.contains(query) {
            return 5
        }
        if normalizedShortcut.contains(query) {
            return 6
        }
        if normalizedAliases.contains(where: { $0.hasPrefix(query) || $0.contains(query) }) {
            return 7
        }
        if normalizedTitle.paletteContainsTokens(in: query) || normalizedTitle.paletteContainsSubsequence(query) {
            return 8
        }
        return nil
    }
}

private extension TerminalCommandSpanPaletteEntry {
    func matchRank(for query: String) -> Int? {
        let normalizedTitle = title.paletteSearchText
        let normalizedID = id.paletteSearchText
        let normalizedCategory = categoryTitle.paletteSearchText
        let normalizedSubtitle = subtitle.paletteSearchText
        let normalizedAliases = aliases.map(\.paletteSearchText)

        if normalizedTitle == query {
            return 0
        }
        if normalizedTitle.hasPrefix(query) {
            return 1
        }
        if normalizedTitle.contains(query) {
            return 2
        }
        if normalizedID.hasPrefix(query) {
            return 3
        }
        if normalizedID.contains(query) {
            return 4
        }
        if normalizedCategory.hasPrefix(query) || normalizedCategory.contains(query) {
            return 5
        }
        if normalizedSubtitle.hasPrefix(query) || normalizedSubtitle.contains(query) {
            return 6
        }
        if normalizedAliases.contains(where: { $0.hasPrefix(query) || $0.contains(query) }) {
            return 7
        }
        if normalizedTitle.paletteContainsTokens(in: query)
            || normalizedSubtitle.paletteContainsTokens(in: query)
            || normalizedTitle.paletteContainsSubsequence(query) {
            return 8
        }
        return nil
    }
}

private extension TerminalCommandCategory {
    var paletteTitle: String {
        switch self {
        case .tabs:
            return "Tabs"
        case .panes:
            return "Panes"
        case .navigation:
            return "Navigation"
        }
    }
}

private extension TerminalCommandSpanCategory {
    var paletteTitle: String {
        switch self {
        case .commandSpans:
            return "Command Spans"
        }
    }
}

private extension TerminalCommandShortcut {
    var paletteDisplayLabel: String {
        var label = ""
        if modifiers.contains(.control) {
            label += "⌃"
        }
        if modifiers.contains(.option) {
            label += "⌥"
        }
        if modifiers.contains(.shift) {
            label += "⇧"
        }
        if modifiers.contains(.command) {
            label += "⌘"
        }

        if let keyEquivalent {
            label += keyEquivalent.uppercased()
        } else if let keyCode {
            label += keyCode.paletteDisplayLabel
        }

        return label
    }
}

private extension UInt16 {
    var paletteDisplayLabel: String {
        switch self {
        case 123:
            return "←"
        case 124:
            return "→"
        case 125:
            return "↓"
        case 126:
            return "↑"
        default:
            return "#\(self)"
        }
    }
}

private extension String {
    var paletteSearchText: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func paletteContainsTokens(in query: String) -> Bool {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard !tokens.isEmpty else {
            return false
        }
        return tokens.allSatisfy { contains($0) }
    }

    func paletteContainsSubsequence(_ query: String) -> Bool {
        guard !query.isEmpty else {
            return false
        }

        var searchIndex = startIndex
        for character in query where !character.isWhitespace {
            guard let matchIndex = self[searchIndex...].firstIndex(of: character) else {
                return false
            }
            searchIndex = index(after: matchIndex)
        }
        return true
    }
}
