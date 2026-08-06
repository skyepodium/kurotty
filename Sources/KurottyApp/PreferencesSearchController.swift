import AppKit

/// Search across every Preferences pane.
///
/// The controller owns the three things the surface would otherwise scatter:
/// the query field in the header, the text index of every setting in every
/// pane, and the rules that turn a query into hidden rows and hidden cards.
/// `PreferencesView` only reports what it is building and hands over the
/// finished card and row views.
///
/// The index is recorded, not declared. A second hand-written list of settings
/// would drift away from the pane builders the first time a card moved, so the
/// builders are the source of truth and this type just listens.
@MainActor
final class PreferencesSearchController {
    /// A card and the rows in it, as views. The text half of the same record
    /// lives in `PreferencesSearchIndex`, which is what makes cross-pane search
    /// possible: views exist only for the pane on screen, text exists for all
    /// three.
    private final class CardRecord {
        let view: NSStackView
        let isAvailable: () -> Bool
        var rowViews: [NSView] = []
        var indexCard: PreferencesSearchIndex.Card

        init(view: NSStackView, title: String, isAvailable: @escaping () -> Bool) {
            self.view = view
            self.isAvailable = isAvailable
            indexCard = PreferencesSearchIndex.Card(title: title)
        }
    }

    /// Asks the window to show another pane because the query matched there.
    /// The window rebuilds, which re-records the index and re-applies the
    /// filter, so this controller does not touch the detail area itself.
    var onCategoryRequested: ((PreferencesCategory) -> Void)?

    let queryField: TerminalSidebarSearchPillView
    let emptyStateView: NSStackView

    private let emptyStateIconView = NSImageView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let noResultsFormat: () -> String
    private var index = PreferencesSearchIndex()
    private var cards: [CardRecord] = []
    private var visibleCategory = PreferencesCategory.terminal
    private var chromeTheme = DesignTokens.ChromeTheme.dark

    init(
        placeholder: @escaping () -> String,
        noResultsFormat: @escaping () -> String
    ) {
        self.noResultsFormat = noResultsFormat
        queryField = TerminalSidebarSearchPillView(placeholder: placeholder)
        emptyStateView = NSStackView()
        configureQueryField(placeholder: placeholder)
        configureEmptyState()
    }

    // MARK: Query

    var query: String {
        get { queryField.stringValue }
        set {
            queryField.stringValue = newValue
            queryChanged()
        }
    }

    func focusQueryField() {
        queryField.focus()
    }

    // MARK: Recording
    //
    // One pane build is one recording pass: `begin`, every card and row as it is
    // created, then `end`.

    func beginRecording(_ category: PreferencesCategory) {
        visibleCategory = category
        cards = []
    }

    func registerCard(
        _ view: NSStackView,
        title: String,
        isAvailable: @escaping () -> Bool = { true }
    ) {
        cards.append(CardRecord(view: view, title: title, isAvailable: isAvailable))
    }

    func registerRow(_ view: NSView, label: String, in card: NSStackView) {
        guard let record = record(for: card) else { return }
        record.rowViews.append(view)
        record.indexCard.rowLabels.append(label)
    }

    func registerKeyword(_ keyword: String, in card: NSStackView) {
        guard let record = record(for: card) else { return }
        record.indexCard.keywords.append(keyword)
    }

    /// Cards a setting has switched off are left out of the index, so a query
    /// never sends the user to a pane to show them nothing. The custom palette
    /// is the only such card today, and changing the theme that gates it
    /// rebuilds the pane, which re-records this.
    func endRecording() {
        index.setCards(cards.filter { $0.isAvailable() }.map(\.indexCard), for: visibleCategory)
    }

    // MARK: Filtering

    /// Applies the current query to the pane on screen. Safe to call whenever
    /// visibility could have gone stale — after a rebuild, or after settings
    /// changed which cards are relevant at all.
    func applyFilter() {
        let query = PreferencesSearchMatcher.normalizedQuery(queryField.stringValue)
        var hasVisibleCard = false

        for card in cards {
            let visibility = card.indexCard.visibility(for: query)
            let isVisible = card.isAvailable() && visibility != .hidden
            card.view.isHidden = !isVisible
            apply(visibility, to: card)
            hasVisibleCard = hasVisibleCard || isVisible
        }

        let hasQuery = query != nil
        emptyStateView.isHidden = !hasQuery || hasVisibleCard
        guard let query else { return }
        emptyStateLabel.stringValue = String(format: noResultsFormat(), query)
    }

    private func apply(_ visibility: PreferencesCardVisibility, to card: CardRecord) {
        guard case let .matchingRows(offsets) = visibility else {
            card.rowViews.forEach { $0.isHidden = false }
            return
        }
        for (offset, rowView) in card.rowViews.enumerated() {
            rowView.isHidden = !offsets.contains(offset)
        }
    }

    private func queryChanged() {
        let category = index.resolvedCategory(for: queryField.stringValue, current: visibleCategory)
        guard category == visibleCategory else {
            onCategoryRequested?(category)
            return
        }
        applyFilter()
    }

    // MARK: Appearance

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        queryField.applyChromeTheme(theme)
        applyEmptyStateIcon(tint: theme.textTertiary)
        emptyStateLabel.textColor = theme.textTertiary
        emptyStateIconView.alphaValue = DesignTokens.Component.sidebarEmptyStateIconAlphaRATIO
        emptyStateLabel.alphaValue = DesignTokens.Component.sidebarEmptyStateLabelAlphaRATIO
    }

    // MARK: Test hooks

    var visibleCardTitlesForTesting: [String] {
        cards.filter { !$0.view.isHidden }.map(\.indexCard.title)
    }

    /// Laid-out widths of the visible cards, for the elastic-column tests: the
    /// cards have no width of their own to assert against any more.
    var visibleCardWidthsForTesting: [CGFloat] {
        cards.filter { !$0.view.isHidden }.map(\.view.frame.width)
    }

    var visibleRowLabelsForTesting: [String] {
        cards.filter { !$0.view.isHidden }.flatMap { card in
            card.indexCard.rowLabels.enumerated()
                .filter { offset, _ in !card.rowViews[offset].isHidden }
                .map(\.element)
        }
    }

    /// True while the window's first responder is the query field or the field
    /// editor AppKit installs inside it.
    var isQueryFieldFocusedForTesting: Bool {
        guard let responder = queryField.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: queryField)
    }

    var isEmptyStateVisibleForTesting: Bool {
        !emptyStateView.isHidden
    }

    var emptyStateMessageForTesting: String {
        emptyStateLabel.stringValue
    }

    var indexForTesting: PreferencesSearchIndex {
        index
    }

    // MARK: Setup

    private func configureQueryField(placeholder: @escaping () -> String) {
        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.setAccessibilityLabel(placeholder())
        queryField.onQueryChanged = { [weak self] in
            self?.queryChanged()
        }
    }

    /// Restrained by contract: one quiet glyph and one line of copy. A settings
    /// page that finds nothing should look like a settings page, not like an
    /// error.
    ///
    /// The width comes from the surface, which pins this to its elastic content
    /// column: the empty state is as wide as the cards it replaces.
    private func configureEmptyState() {
        applyEmptyStateIcon(tint: chromeTheme.textTertiary)
        emptyStateIconView.imageScaling = .scaleNone

        DesignTokens.Typography.prefsBody.apply(to: emptyStateLabel, color: chromeTheme.textTertiary)
        emptyStateLabel.alignment = .center
        emptyStateLabel.lineBreakMode = .byTruncatingTail

        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = DesignTokens.Component.preferencesSearchEmptyStateGapPX
        emptyStateView.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Component.preferencesSearchEmptyStateTopGapPX,
            left: 0,
            bottom: 0,
            right: 0
        )
        emptyStateView.addArrangedSubview(emptyStateIconView)
        emptyStateView.addArrangedSubview(emptyStateLabel)
        emptyStateView.isHidden = true
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Palette-tinted symbols bake their color into the image, so a theme change
    /// rebuilds the glyph instead of retinting a template.
    private func applyEmptyStateIcon(tint: NSColor) {
        emptyStateIconView.image = Icon.symbol(
            IconSymbol.search,
            pointSizePT: DesignTokens.Component.preferencesSearchEmptyStateIconPointSizePT,
            weight: .regular,
            tint: tint
        )
    }

    private func record(for card: NSStackView) -> CardRecord? {
        cards.last { $0.view === card }
    }
}
