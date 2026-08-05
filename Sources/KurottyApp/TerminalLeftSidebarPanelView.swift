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
/// The child panels are untouched: each still draws its own uppercase section
/// header, search pill, and outline rows, so both sections stay pixel-identical
/// below the selector.
@MainActor
final class TerminalLeftSidebarPanelView: NSView {
    let historyPanel = TerminalCommandHistoryPanelView()
    let agentSessionPanel = TerminalAgentSessionPanelView()

    private let sectionStrip = TerminalLeftSidebarSectionStripView()
    private(set) var selectedSection: TerminalLeftSidebarSection = .commandHistory
    private var chromeTheme = DesignTokens.ChromeTheme.dark

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
        // visible. On screen the underline travels and the lists crossfade.
        guard window != nil, previousSection != section else {
            applySectionVisibility()
            refreshIndexIfNeeded(for: section)
            return
        }
        SidebarMotion.animateSectionChange(
            underline: sectionStrip.underlineView,
            toFrame: sectionStrip.underlineFrame(for: section),
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
        var constraints: [NSLayoutConstraint] = [
            sectionStrip.topAnchor.constraint(
                equalTo: topAnchor,
                constant: DesignTokens.Component.leftSidebarSectionStripTopInsetPX
            ),
            sectionStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            sectionStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
            sectionStrip.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.leftSidebarSectionStripHeightPX
            ),
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
/// inside the panel. A pair of plain views with an accent underline expresses
/// the same choice at the height the sidebar actually wants.
@MainActor
final class TerminalLeftSidebarSectionStripView: NSView {
    var onSelect: ((TerminalLeftSidebarSection) -> Void)?

    var selectedSection: TerminalLeftSidebarSection = .commandHistory {
        didSet { applySelection() }
    }

    /// Selection underline. A real view rather than a per-item `draw` so it can
    /// travel across the strip when the section changes; `SidebarMotion` owns
    /// that animation.
    let underlineView = NSView()

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
        underlineView.layer?.backgroundColor = theme.accent.cgColor
        for itemView in itemViews {
            itemView.applyChromeTheme(theme)
        }
    }

    /// Where the underline sits for a section, in strip coordinates. Inset from
    /// the item's own width so two adjacent selections could never read as one
    /// continuous rule.
    func underlineFrame(for section: TerminalLeftSidebarSection) -> NSRect {
        guard let itemView = itemViews.first(where: { $0.section == section }) else {
            return .zero
        }
        let inset = DesignTokens.Component.leftSidebarSectionUnderlineInsetXPX
        return NSRect(
            x: itemView.frame.minX + inset,
            y: bounds.minY,
            width: max(itemView.frame.width - 2 * inset, 0),
            height: DesignTokens.Component.leftSidebarSectionUnderlineHeightPX
        )
    }

    override func layout() {
        super.layout()
        // A resize repositions the underline outright; only a section change
        // animates it.
        underlineView.frame = underlineFrame(for: selectedSection)
    }

    private func configure() {
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

        // Deliberately not `disableImplicitAnimations`: this is the one chrome
        // layer that is supposed to move.
        underlineView.wantsLayer = true
        underlineView.layer?.cornerRadius = DesignTokens.Radius.xsPX
        underlineView.layer?.backgroundColor = chromeTheme.accent.cgColor
        addSubview(underlineView)

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
            return AppLocalization.string(.agentSessions).localizedUppercase
        }
    }
}

/// One item of the section strip. Owns its own hover, selection, and focus
/// paint so the strip stays a layout container.
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let hoverRect = bounds.insetBy(
            dx: DesignTokens.Component.leftSidebarSectionHoverInsetPX,
            dy: DesignTokens.Component.leftSidebarSectionHoverInsetPX
        )
        if isHovered, !isSelectedSection {
            chromeTheme.hoverFill.setFill()
            NSBezierPath(
                roundedRect: hoverRect,
                xRadius: DesignTokens.Radius.smPX,
                yRadius: DesignTokens.Radius.smPX
            ).fill()
        }
        guard window?.firstResponder === self else {
            return
        }
        chromeTheme.focusRing.setStroke()
        let ringPath = NSBezierPath(
            roundedRect: hoverRect.insetBy(
                dx: -DesignTokens.Component.leftSidebarSectionFocusRingOutsetPX,
                dy: -DesignTokens.Component.leftSidebarSectionFocusRingOutsetPX
            ),
            xRadius: DesignTokens.Radius.smPX,
            yRadius: DesignTokens.Radius.smPX
        )
        ringPath.lineWidth = DesignTokens.Component.leftSidebarSectionFocusRingWidthPX
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
