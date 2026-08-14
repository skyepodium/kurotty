import Foundation

/// One row in a picker, already decided.
///
/// The presentation model rather than the data: by the time a row exists, the
/// question of *which* row matters has been answered, and the view's only job
/// is to make that answer visible.
struct QuickCommandPickerRow: Equatable {
    /// A glyph standing for what this row is. Emoji rather than an icon set,
    /// for the reason Dia's folders use them: no asset pipeline, and it reads
    /// at a glance.
    let glyph: Character?
    /// What the row is called. The thing being searched for.
    let title: String
    /// What disambiguates two rows with the same title — an image, a namespace,
    /// a path. Quiet, because it is only read when the title is not enough.
    let detail: String
    /// A short state, shown as a chip. Encoded as its own field rather than
    /// appended to the detail so the view can give it a shape and not only a
    /// colour.
    let badge: String?
    /// The row the picker would choose on its own. At most one row is this, and
    /// the view says so, because a common case that takes one keystroke should
    /// look like it takes one keystroke.
    let isRecommended: Bool
    /// Present but visibly not the answer.
    ///
    /// **This is what makes ranking felt rather than merely done.** A sorted
    /// list of twelve containers still looks like a list of twelve; the mesh
    /// proxy has to look like infrastructure or the person still has to read
    /// every line.
    let isSecondary: Bool
    /// What choosing this row fills a template with.
    let values: [String: String]
}

/// What a picker is showing, and which row is under the cursor.
///
/// Pure and Equatable, in the shape `ProjectFileQuickOpenPresenter` already
/// established: every decision here, and the AppKit shell around it holds no
/// state of its own worth testing.
struct QuickCommandPickerPresenter: Equatable {
    private(set) var query = ""
    private(set) var rows: [QuickCommandPickerRow]
    private(set) var visibleRows: [QuickCommandPickerRow]
    private(set) var selectedIndex: Int?
    /// True while the source command is still running. A picker over a cluster
    /// is a network round trip, and pretending otherwise makes an empty list
    /// look like an answer.
    private(set) var isLoading: Bool

    init(rows: [QuickCommandPickerRow] = [], isLoading: Bool = false) {
        self.rows = rows
        self.isLoading = isLoading
        visibleRows = rows
        selectedIndex = Self.firstSelection(in: rows)
    }

    /// Replaces the list when the source command answers.
    ///
    /// The selection lands on the recommended row rather than the first one, so
    /// the ranking is what Return acts on.
    mutating func applyRows(_ rows: [QuickCommandPickerRow]) {
        self.rows = rows
        isLoading = false
        recompute()
    }

    mutating func updateQuery(_ query: String) {
        self.query = query
        recompute()
    }

    mutating func moveSelection(by offset: Int) {
        guard !visibleRows.isEmpty else {
            selectedIndex = nil
            return
        }
        guard let current = selectedIndex else {
            selectedIndex = 0
            return
        }

        // Wraps, because a list this short is faster to cycle than to reverse
        // direction in.
        let count = visibleRows.count
        selectedIndex = ((current + offset) % count + count) % count
    }

    mutating func select(row: Int) {
        guard visibleRows.indices.contains(row) else {
            return
        }
        selectedIndex = row
    }

    var selectedRow: QuickCommandPickerRow? {
        guard let selectedIndex, visibleRows.indices.contains(selectedIndex) else {
            return nil
        }
        return visibleRows[selectedIndex]
    }

    /// Where the hairline goes: the first row that is infrastructure rather
    /// than an answer, or nil when every row is an answer.
    ///
    /// A rule rather than a group, because grouping would reorder and the order
    /// is the ranking.
    var firstSecondaryIndex: Int? {
        visibleRows.firstIndex { $0.isSecondary }
    }

    private mutating func recompute() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            visibleRows = rows
            selectedIndex = Self.firstSelection(in: rows)
            return
        }

        visibleRows = rows.filter { row in
            row.title.range(of: trimmed, options: .caseInsensitive) != nil
                || row.detail.range(of: trimmed, options: .caseInsensitive) != nil
        }
        // Typing is a stronger signal than the ranking: someone who typed
        // `istio` means the proxy, whatever the heuristics think of it.
        selectedIndex = visibleRows.isEmpty ? nil : 0
    }

    private static func firstSelection(in rows: [QuickCommandPickerRow]) -> Int? {
        guard !rows.isEmpty else {
            return nil
        }
        return rows.firstIndex(where: \.isRecommended) ?? 0
    }
}
