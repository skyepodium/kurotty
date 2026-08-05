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
        selectedSection = section
        sectionStrip.selectedSection = section
        applySectionVisibility()
        guard section == .agentSessions else {
            return
        }
        agentSessionPanel.refreshIndex()
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
        for itemView in itemViews {
            itemView.applyChromeTheme(theme)
        }
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
        if isSelectedSection {
            chromeTheme.accent.setFill()
            NSBezierPath(
                roundedRect: underlineRect,
                xRadius: DesignTokens.Radius.xsPX,
                yRadius: DesignTokens.Radius.xsPX
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

    /// Accent underline at the strip's bottom edge, item width minus 8.
    private var underlineRect: NSRect {
        let inset = DesignTokens.Component.leftSidebarSectionUnderlineInsetXPX
        let height = DesignTokens.Component.leftSidebarSectionUnderlineHeightPX
        return NSRect(
            x: bounds.minX + inset,
            y: bounds.minY,
            width: max(bounds.width - 2 * inset, 0),
            height: height
        )
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
