import AppKit

/// Which section the left sidebar is showing.
enum TerminalLeftSidebarSection: Int, CaseIterable {
    case commandHistory
    case agentSessions
}

/// Container for the left sidebar. Hosts the existing command-history panel and
/// the agent-session panel behind a two-item tab strip, so the left split pane
/// keeps a single arranged subview and both sections reuse the same width,
/// divider, and collapse behavior.
///
/// Neither child panel draws a title of its own: the strip is the title, and a
/// panel header repeating it was the same string twice with a list underneath.
/// Below the strip both sections are pixel-identical — search pill, then rows.
@MainActor
final class TerminalLeftSidebarPanelView: NSView {
    let historyPanel = TerminalCommandHistoryPanelView()
    let agentSessionPanel = TerminalAgentSessionPanelView()

    private let sectionStrip = TerminalLeftSidebarSectionStripView()
    private(set) var selectedSection: TerminalLeftSidebarSection = .commandHistory
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    /// The strip's height; the item labels inside it come back from
    /// `applyChromeTheme` on their own.
    private let metrics = ChromeMetricBindings()

    init() {
        super.init(frame: .zero)
        configure()
        applySectionVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = theme.topChromeBackground.cgColor
        metrics.reapply()
        sectionStrip.applyChromeTheme(theme)
        historyPanel.applyChromeTheme(theme)
        agentSessionPanel.applyChromeTheme(theme)
    }

    /// Selects a section and gives its search field focus. Showing the
    /// agent-session section is the only thing that ever asks the index to
    /// scan; the setting still decides whether a scan actually happens.
    func showSection(_ section: TerminalLeftSidebarSection) {
        let previousSection = selectedSection
        selectedSection = section
        sectionStrip.selectedSection = section
        // Off-screen (tests, a panel built but never installed) there is nothing
        // to animate, and a queued completion handler would leave both lists
        // visible. On screen the pill travels and the lists crossfade.
        guard window != nil, previousSection != section else {
            applySectionVisibility()
            refreshIndexIfNeeded(for: section)
            return
        }
        SidebarMotion.animateSectionChange(
            selectionPill: sectionStrip.selectionPillView,
            toFrame: sectionStrip.selectionPillFrame(for: section),
            outgoing: panelView(for: previousSection),
            incoming: panelView(for: section)
        )
        refreshIndexIfNeeded(for: section)
    }

    private func refreshIndexIfNeeded(for section: TerminalLeftSidebarSection) {
        guard section == .agentSessions else {
            return
        }
        agentSessionPanel.refreshIndex()
    }

    private func panelView(for section: TerminalLeftSidebarSection) -> NSView {
        switch section {
        case .commandHistory:
            return historyPanel
        case .agentSessions:
            return agentSessionPanel
        }
    }

    var sectionControlFrameForTesting: NSRect {
        convert(sectionStrip.bounds, from: sectionStrip)
    }

    func focusFilterField() {
        switch selectedSection {
        case .commandHistory:
            historyPanel.focusFilterField()
        case .agentSessions:
            agentSessionPanel.focusFilterField()
        }
    }

    private func configure() {
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor

        sectionStrip.selectedSection = selectedSection
        sectionStrip.onSelect = { [weak self] section in
            self?.showSection(section)
        }
        sectionStrip.applyChromeTheme(chromeTheme)
        sectionStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionStrip)

        for panel in [historyPanel as NSView, agentSessionPanel as NSView] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(panel)
        }

        let insetX = DesignTokens.Component.leftSidebarSectionStripInsetXPX
        let stripHeight = metrics.bind(sectionStrip.heightAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.leftSidebarSectionStripHeightPX
        }
        var constraints: [NSLayoutConstraint] = [
            sectionStrip.topAnchor.constraint(
                equalTo: topAnchor,
                constant: DesignTokens.Component.leftSidebarSectionStripTopInsetPX
            ),
            sectionStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            sectionStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
            stripHeight,
        ]
        for panel in [historyPanel as NSView, agentSessionPanel as NSView] {
            constraints.append(contentsOf: [
                panel.topAnchor.constraint(
                    equalTo: sectionStrip.bottomAnchor,
                    constant: DesignTokens.Component.leftSidebarSectionStripBottomGapPX
                ),
                panel.leadingAnchor.constraint(equalTo: leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func applySectionVisibility() {
        historyPanel.isHidden = selectedSection != .commandHistory
        agentSessionPanel.isHidden = selectedSection != .agentSessions
    }
}

// MARK: - Section strip

/// Two-item tab strip for the left sidebar.
///
/// Deliberately not `NSSegmentedControl`: AppKit has no legal 22pt
/// segmented-control height, so forcing one rendered a squashed control and
/// needed `setWidth(0…)` plus a lowered compression resistance just to stay
/// inside the panel. A pair of plain views expresses the same choice at the
/// height the sidebar actually wants.
///
/// The strip used to mark its selected tab with a bare 2pt accent underline,
/// which made this the third selection language in one window: the terminal tab
/// bar raises a `surfaceRaised` tab under an accent rail, the sidebar lists
/// raise a `surfaceRaised` pill under an accent rail, and this drew a rule and
/// nothing else. Three devices for one meaning is three things to learn, and
/// the weakest of them was carrying the sidebar's own navigation. It now uses
/// the list's device — the *same* `TerminalSidebarRowHighlight` appearance, the
/// same surface, the same hairline, the same accent rail — with the rail on the
/// bottom edge, because that is the edge nearest the list the tab introduces.
@MainActor
final class TerminalLeftSidebarSectionStripView: NSView {
    var onSelect: ((TerminalLeftSidebarSection) -> Void)?

    var selectedSection: TerminalLeftSidebarSection = .commandHistory {
        didSet { applySelection() }
    }

    /// The selection pill. A real view rather than a per-item `draw` so it can
    /// travel across the strip when the section changes; `SidebarMotion` owns
    /// that animation.
    let selectionPillView = TerminalLeftSidebarSectionSelectionView()

    private var itemViews: [TerminalLeftSidebarSectionItemView] = []
    private var chromeTheme = DesignTokens.ChromeTheme.dark

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        selectionPillView.chromeTheme = theme
        for itemView in itemViews {
            itemView.applyChromeTheme(theme)
        }
    }

    /// Where the pill sits for a section, in strip coordinates: the item's own
    /// frame. The shared painter applies the row inset inside it, so the pill's
    /// gutter is the list's gutter rather than a second set of numbers.
    func selectionPillFrame(for section: TerminalLeftSidebarSection) -> NSRect {
        itemViews.first { $0.section == section }?.frame ?? .zero
    }

    override func layout() {
        super.layout()
        // A resize repositions the pill outright; only a section change
        // animates it.
        selectionPillView.frame = selectionPillFrame(for: selectedSection)
    }

    private func configure() {
        // Deliberately not `disableImplicitAnimations`: this is the one chrome
        // layer that is supposed to move. Added before the items so the pill
        // sits behind the labels rather than over them.
        addSubview(selectionPillView)
        selectionPillView.chromeTheme = chromeTheme

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        for section in TerminalLeftSidebarSection.allCases {
            let itemView = TerminalLeftSidebarSectionItemView(
                section: section,
                title: Self.title(for: section)
            )
            itemView.onSelect = { [weak self] selected in
                self?.selectedSection = selected
                self?.onSelect?(selected)
            }
            itemView.onSelectNeighbor = { [weak self] offset in
                self?.selectNeighbor(of: section, offset: offset)
            }
            itemViews.append(itemView)
            stackView.addArrangedSubview(itemView)
        }

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applySelection()
    }

    private func selectNeighbor(of section: TerminalLeftSidebarSection, offset: Int) {
        let sections = TerminalLeftSidebarSection.allCases
        guard let index = sections.firstIndex(of: section) else {
            return
        }
        let nextIndex = (index + offset + sections.count) % sections.count
        let next = sections[nextIndex]
        selectedSection = next
        onSelect?(next)
        window?.makeFirstResponder(itemViews[nextIndex])
    }

    private func applySelection() {
        for itemView in itemViews {
            itemView.isSelectedSection = itemView.section == selectedSection
        }
        needsLayout = true
    }

    private static func title(for section: TerminalLeftSidebarSection) -> String {
        switch section {
        case .commandHistory:
            return AppLocalization.string(.commandHistorySectionTitle).localizedUppercase
        case .agentSessions:
            return AppLocalization.string(.agentSessionsSectionTitle).localizedUppercase
        }
    }
}

/// The travelling selection pill behind the strip's selected tab.
///
/// Holds no state of its own beyond the theme: the paint comes from
/// `TerminalSidebarRowHighlight.appearance(for:theme:)` for a selected row, so
/// the strip cannot drift from the lists it sits above. If the pill ever stops
/// matching a sidebar row it will be because that one function changed, which
/// is the point.
@MainActor
final class TerminalLeftSidebarSectionSelectionView: NSView {
    var chromeTheme: DesignTokens.ChromeTheme = .dark {
        didSet { refresh() }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // The pill's drop shadow lives outside its own bounds, so a clipping
        // layer would cut it into a hard edge — the same reason
        // `TerminalSidebarRowView` unsets this.
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Always the *active* selection appearance, whether or not the window is
    /// key. This is the one place the strip departs from a list row, and the
    /// reason is that the two are not the same kind of selection.
    ///
    /// A selected list row is a selection the user made; a background window
    /// demoting it — dropping the accent rail and the elevation — is the window
    /// saying "nothing here is being acted on". The strip's selected tab is not
    /// that. It is a statement about which list is on screen right now, and
    /// that stays true while the window is in the background. Demoting it made
    /// the light theme's strip a white pill on near-white with a hairline that
    /// measures about 1.06:1 — a background window simply stopped saying which
    /// section it was showing.
    ///
    /// The terminal tab bar already draws this distinction the same way: its
    /// active tab keeps its accent rail in a background window, because it too
    /// answers "which one am I looking at" rather than "which one is focused".
    var currentAppearance: TerminalSidebarRowHighlight.Appearance {
        TerminalSidebarRowHighlight.appearance(
            for: .init(isSelected: true, isWindowActive: true),
            theme: chromeTheme
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        TerminalSidebarRowHighlight.paint(currentAppearance, in: bounds, railEdge: .bottom)
    }

    override func layout() {
        super.layout()
        applyShadow()
    }

    private func refresh() {
        needsDisplay = true
        applyShadow()
    }

    /// Same reason as `TerminalSidebarRowView`: `shadowPath` is not clipped to
    /// the layer's contents, so the shadow can sit outside the pill.
    private func applyShadow() {
        guard let layer else {
            return
        }
        layer.masksToBounds = false
        guard let shadow = currentAppearance.shadow, !bounds.isEmpty else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
            return
        }
        shadow.apply(to: layer)
        layer.shadowPath = TerminalSidebarRowHighlight.Geometry.highlightPath(in: bounds)
    }
}

/// One item of the section strip. Owns its own hover and focus paint; the
/// selected state is the strip's travelling pill, not a per-item fill.
@MainActor
final class TerminalLeftSidebarSectionItemView: NSView {
    let section: TerminalLeftSidebarSection

    var onSelect: ((TerminalLeftSidebarSection) -> Void)?
    /// `-1` / `+1`: arrow-key movement between items.
    var onSelectNeighbor: ((Int) -> Void)?

    var isSelectedSection = false {
        didSet { applyAppearance() }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    private enum KeyCode {
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let space: UInt16 = 49
        static let returnKey: UInt16 = 36
    }

    init(section: TerminalLeftSidebarSection, title: String) {
        self.section = section
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        applyAppearance()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?(section)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyCode.leftArrow:
            onSelectNeighbor?(-1)
        case KeyCode.rightArrow:
            onSelectNeighbor?(1)
        case KeyCode.space, KeyCode.returnKey:
            onSelect?(section)
        default:
            super.keyDown(with: event)
        }
    }

    /// Hover and focus only. Selection is painted by the strip's pill, which
    /// sits behind this view, so a selected item must draw no fill of its own —
    /// a hover wash over the pill would be the two-opacities-of-one-paint
    /// mistake `TerminalSidebarRowHighlight` exists to prevent.
    ///
    /// Geometry comes from the shared row geometry rather than from strip-local
    /// insets, so the hover target and the focus ring line up with the pill
    /// underneath instead of merely looking about right.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered, !isSelectedSection {
            let hovered = TerminalSidebarRowHighlight.appearance(
                for: .init(isHovered: true, isWindowActive: window?.isKeyWindow ?? false),
                theme: chromeTheme
            )
            TerminalSidebarRowHighlight.paint(hovered, in: bounds, railEdge: .bottom)
        }
        guard window?.firstResponder === self else {
            return
        }
        chromeTheme.focusRing.setStroke()
        let ringPath = NSBezierPath(
            roundedRect: TerminalSidebarRowHighlight.Geometry.focusRingRect(in: bounds),
            xRadius: TerminalSidebarRowHighlight.Geometry.focusRingCornerRadiusPX,
            yRadius: TerminalSidebarRowHighlight.Geometry.focusRingCornerRadiusPX
        )
        ringPath.lineWidth = TerminalSidebarRowHighlight.Geometry.focusRingWidthPX
        ringPath.stroke()
    }

    private func applyAppearance() {
        DesignTokens.Typography.sectionHeader.apply(to: titleLabel, color: titleColor)
        needsDisplay = true
    }

    private var titleColor: NSColor {
        guard !isSelectedSection else {
            return chromeTheme.textPrimary
        }
        return isHovered ? chromeTheme.textSecondary : chromeTheme.textTertiary
    }
}
