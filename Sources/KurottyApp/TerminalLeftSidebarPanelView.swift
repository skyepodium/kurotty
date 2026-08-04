import AppKit

/// Which section the left sidebar is showing.
enum TerminalLeftSidebarSection: Int, CaseIterable {
    case commandHistory
    case agentSessions
}

/// Container for the left sidebar. Hosts the existing command-history panel and
/// the agent-session panel behind a segmented control, so the left split pane
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

    private let sectionControl = NSSegmentedControl()
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
        // NSSegmentedControl draws from the window appearance, which the
        // controller already switches with the chrome theme, so the selector
        // needs no explicit tint of its own.
        historyPanel.applyChromeTheme(theme)
        agentSessionPanel.applyChromeTheme(theme)
    }

    /// Selects a section and gives its search field focus. Showing the
    /// agent-session section is the only thing that ever asks the index to
    /// scan; the setting still decides whether a scan actually happens.
    func showSection(_ section: TerminalLeftSidebarSection) {
        selectedSection = section
        sectionControl.selectedSegment = section.rawValue
        applySectionVisibility()
        guard section == .agentSessions else {
            return
        }
        agentSessionPanel.refreshIndex()
    }

    var sectionControlFrameForTesting: NSRect {
        convert(sectionControl.bounds, from: sectionControl)
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

        sectionControl.segmentStyle = .roundRect
        sectionControl.trackingMode = .selectOne
        sectionControl.segmentCount = TerminalLeftSidebarSection.allCases.count
        sectionControl.setLabel(
            AppLocalization.string(.commandHistorySectionTitle),
            forSegment: TerminalLeftSidebarSection.commandHistory.rawValue
        )
        sectionControl.setLabel(
            AppLocalization.string(.agentSessions),
            forSegment: TerminalLeftSidebarSection.agentSessions.rawValue
        )
        for section in TerminalLeftSidebarSection.allCases {
            sectionControl.setWidth(0, forSegment: section.rawValue)
        }
        sectionControl.selectedSegment = selectedSection.rawValue
        sectionControl.target = self
        sectionControl.action = #selector(sectionControlChanged(_:))
        // Localized labels can be wider than the sidebar. Without a low
        // compression resistance the control's intrinsic width would push the
        // panel past its maximum width on every layout pass, so the segments
        // must be allowed to squeeze instead.
        sectionControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sectionControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sectionControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionControl)

        for panel in [historyPanel as NSView, agentSessionPanel as NSView] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(panel)
        }

        let insetX = DesignTokens.Component.leftSidebarSegmentedControlInsetXPX
        // The trailing edge stretches the control across the panel when there
        // is room, but only at a low priority: the required constraint is the
        // `lessThanOrEqualTo` one, so a wide control never widens the panel.
        let stretchToTrailing = sectionControl.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -insetX
        )
        stretchToTrailing.priority = .defaultLow
        var constraints: [NSLayoutConstraint] = [
            sectionControl.topAnchor.constraint(
                equalTo: topAnchor,
                constant: DesignTokens.Component.leftSidebarSegmentedControlTopInsetPX
            ),
            sectionControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            sectionControl.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -insetX
            ),
            stretchToTrailing,
            sectionControl.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.leftSidebarSegmentedControlHeightPX
            ),
        ]
        for panel in [historyPanel as NSView, agentSessionPanel as NSView] {
            constraints.append(contentsOf: [
                panel.topAnchor.constraint(
                    equalTo: sectionControl.bottomAnchor,
                    constant: DesignTokens.Component.leftSidebarSegmentedControlBottomGapPX
                ),
                panel.leadingAnchor.constraint(equalTo: leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)
    }

    @objc private func sectionControlChanged(_ sender: NSSegmentedControl) {
        guard let section = TerminalLeftSidebarSection(rawValue: sender.selectedSegment) else {
            return
        }
        showSection(section)
    }

    private func applySectionVisibility() {
        historyPanel.isHidden = selectedSection != .commandHistory
        agentSessionPanel.isHidden = selectedSection != .agentSessions
    }
}
