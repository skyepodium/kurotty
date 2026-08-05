import Foundation

/// The three Preferences panes.
///
/// Lifted out of `PreferencesView` because search has to reason about panes
/// that are not on screen: the index records which pane a setting lives in so a
/// query typed while Terminal is open can switch to Window.
enum PreferencesCategory: Int, CaseIterable {
    case terminal
    case appearance
    case window
}

/// Substring matching for settings search.
///
/// Matching is deliberately dumb — a case-insensitive substring, not a fuzzy or
/// token score. A settings window has a few dozen labels, all of them written by
/// us, so ranking would only make the result order harder to predict.
enum PreferencesSearchMatcher {
    /// Diacritic and width insensitivity are for the Japanese and Korean copy:
    /// a half-width katakana query still has to find a full-width label.
    static let compareOptions: String.CompareOptions = [
        .caseInsensitive,
        .diacriticInsensitive,
        .widthInsensitive,
    ]

    /// `nil` means "no query". Whitespace alone must not filter anything out.
    static func normalizedQuery(_ rawQuery: String) -> String? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func matches(_ text: String, query: String) -> Bool {
        text.range(of: query, options: compareOptions) != nil
    }
}

/// What one card shows for a query.
enum PreferencesCardVisibility: Equatable {
    /// No query, or the query matched something the card cannot hide — its own
    /// title or one of its keywords. The card and every row in it stay visible.
    case whole
    /// Only the rows at these offsets stay visible.
    case matchingRows(Set<Int>)
    case hidden
}

/// Text-only index of every setting in the Preferences window.
///
/// The index is recorded by the same calls that build the window, so a setting
/// cannot exist in the UI without existing in search. Holding no views means the
/// matching rules can be exercised without an `NSWindow`.
struct PreferencesSearchIndex: Equatable {
    /// One settings card: the heading a user reads, plus the labels inside it.
    struct Card: Equatable {
        /// Labels of rows the card is allowed to hide individually.
        var rowLabels: [String] = []
        /// Labels that are searchable but not hideable — the color-well names in
        /// the custom palette, which are a grid rather than a row list. A
        /// keyword hit shows the whole card.
        var keywords: [String] = []

        let title: String

        init(title: String, rowLabels: [String] = [], keywords: [String] = []) {
            self.title = title
            self.rowLabels = rowLabels
            self.keywords = keywords
        }

        func visibility(for query: String?) -> PreferencesCardVisibility {
            guard let query else {
                return .whole
            }
            guard !PreferencesSearchMatcher.matches(title, query: query) else {
                return .whole
            }
            guard !keywords.contains(where: { PreferencesSearchMatcher.matches($0, query: query) }) else {
                return .whole
            }
            let matchingRows = Set(
                rowLabels.indices.filter { PreferencesSearchMatcher.matches(rowLabels[$0], query: query) }
            )
            return matchingRows.isEmpty ? .hidden : .matchingRows(matchingRows)
        }

        func matches(query: String) -> Bool {
            visibility(for: query) != .hidden
        }
    }

    private var cardsByCategory: [PreferencesCategory: [Card]] = [:]

    mutating func setCards(_ cards: [Card], for category: PreferencesCategory) {
        cardsByCategory[category] = cards
    }

    func cards(for category: PreferencesCategory) -> [Card] {
        cardsByCategory[category] ?? []
    }

    func matches(query: String, in category: PreferencesCategory) -> Bool {
        cards(for: category).contains { $0.matches(query: query) }
    }

    func hasAnyMatch(for rawQuery: String) -> Bool {
        guard let query = PreferencesSearchMatcher.normalizedQuery(rawQuery) else {
            return true
        }
        return PreferencesCategory.allCases.contains { matches(query: query, in: $0) }
    }

    /// The pane a query should show.
    ///
    /// Staying wins when the visible pane has a match, so typing never yanks the
    /// user out of the pane they are reading; otherwise the first pane that has
    /// one takes over. A query that matches nothing anywhere leaves the pane
    /// alone and lets the empty state explain itself.
    func resolvedCategory(for rawQuery: String, current: PreferencesCategory) -> PreferencesCategory {
        guard let query = PreferencesSearchMatcher.normalizedQuery(rawQuery) else {
            return current
        }
        guard !matches(query: query, in: current) else {
            return current
        }
        return PreferencesCategory.allCases.first { matches(query: query, in: $0) } ?? current
    }
}
