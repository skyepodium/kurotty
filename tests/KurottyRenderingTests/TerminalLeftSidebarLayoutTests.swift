import AppKit
import XCTest
@testable import KurottyApp

/// Layout regression coverage for the left sidebar container and its two
/// sections. The empty state must occupy the list region only: it may never
/// overlap the section header, the search pill, or the section selector, at
/// any supported panel width.
@MainActor
final class TerminalLeftSidebarLayoutTests: XCTestCase {
    /// The UI text scale is process-wide and the tokens read it on every build,
    /// so a test that moves it has to restore it or it leaks into every test
    /// that runs afterwards.
    override func tearDown() {
        DesignTokens.UIScale.setPercent(DesignTokens.UIScale.defaultPercent)
        super.tearDown()
    }

    private enum PanelWidth {
        /// Mirrors `DesignTokens.Component.leftSidebarPanel*WidthPX`.
        static let minimumPX: CGFloat = 200
        static let defaultPX: CGFloat = 350
        static let maximumPX: CGFloat = 460
        static let allPX: [CGFloat] = [minimumPX, defaultPX, maximumPX]
    }

    private static let panelHeightPX: CGFloat = 620

    func testDesignTokenSidebarWidthsMatchTheCoveredRange() {
        XCTAssertEqual(DesignTokens.Component.commandHistoryPanelMinWidthPX, PanelWidth.minimumPX)
        XCTAssertEqual(DesignTokens.Component.commandHistoryPanelDefaultWidthPX, PanelWidth.defaultPX)
        XCTAssertEqual(DesignTokens.Component.commandHistoryPanelMaxWidthPX, PanelWidth.maximumPX)
    }

    func testEmptyStateNeverOverlapsHeaderOrSearchPillAtEverySupportedWidth() {
        for width in PanelWidth.allPX {
            let sidebar = makeLaidOutSidebar(width: width)
            for section in TerminalLeftSidebarSection.allCases {
                sidebar.showSection(section)
                layOut(sidebar, width: width)
                assertNoEmptyStateOverlap(in: sidebar, section: section, width: width)
            }
        }
    }

    func testSwitchingSectionsRepeatedlyKeepsTheEmptyStateInTheListRegion() {
        let width = PanelWidth.minimumPX
        let sidebar = makeLaidOutSidebar(width: width)
        let visitOrder: [TerminalLeftSidebarSection] = [
            .agentSessions, .commandHistory, .agentSessions, .commandHistory, .agentSessions,
        ]
        for section in visitOrder {
            sidebar.showSection(section)
            layOut(sidebar, width: width)
            assertNoEmptyStateOverlap(in: sidebar, section: section, width: width)
        }
    }

    func testOnlyTheSelectedSectionSubtreeIsVisible() {
        let sidebar = makeLaidOutSidebar(width: PanelWidth.defaultPX)
        for section in TerminalLeftSidebarSection.allCases {
            sidebar.showSection(section)
            layOut(sidebar, width: PanelWidth.defaultPX)
            let visiblePanels = [
                sidebar.historyPanel as NSView,
                sidebar.agentSessionPanel as NSView,
            ].filter { !$0.isHiddenOrHasHiddenAncestor }
            XCTAssertEqual(
                visiblePanels.count,
                1,
                "exactly one section subtree may be visible for \(section)"
            )
        }
    }

    func testEmptyStateIsHiddenOnceTheSectionHasRows() {
        let width = PanelWidth.minimumPX
        let store = TerminalCommandHistoryStore(
            historyURL: temporaryHistoryURL(),
            isRecordingEnabled: true,
            observesSettingsChanges: false
        )
        store.record(
            TerminalCommandHistoryEntry(
                commandText: "swift test",
                cwd: "/tmp/kurotty",
                exitCode: 0,
                finishedAt: Date()
            )
        )
        let panel = TerminalCommandHistoryPanelView(store: store)
        layOut(panel, width: width, height: Self.panelHeightPX)
        XCTAssertFalse(panel.visibleGroupsForTesting.isEmpty)
        XCTAssertTrue(panel.emptyStateIsHiddenForTesting)
        XCTAssertTrue(panel.emptyStateFrameForTesting.isEmpty || panel.emptyStateIsHiddenForTesting)
    }

    // MARK: - Section strip

    /// `NSSegmentedControl` has no legal 22pt height, which is why the old
    /// selector rendered squashed and needed `setWidth(0…)` plus a lowered
    /// compression resistance. The replacement must not reintroduce it.
    func testSectionSelectorIsNotASegmentedControl() {
        let sidebar = makeLaidOutSidebar(width: PanelWidth.defaultPX)
        let segmentedControls = descendants(of: sidebar).filter { $0 is NSSegmentedControl }
        XCTAssertTrue(segmentedControls.isEmpty)
        XCTAssertEqual(
            sidebar.sectionControlFrameForTesting.height,
            DesignTokens.Component.leftSidebarSectionStripHeightPX
        )
    }

    /// `.fillEqually` hands out whole points, so a strip whose usable width does
    /// not divide by the item count leaves a remainder of one point on a single
    /// item. That is AppKit dividing correctly, not the layout breaking, and it
    /// only surfaces at some combinations of panel width and UI text scale --
    /// 175% at 200pt gives 93 and 92. Asserting exact equality made this an
    /// intermittent failure that depended on whether an earlier test had left
    /// the scale somewhere other than 100%. The bound is what the assertion
    /// always meant: no item may be visibly wider than another.
    func testSectionStripItemsSplitTheStripEvenlyAtEveryWidth() {
        for scale in [DesignTokens.UIScale.defaultPercent, DesignTokens.UIScale.maximumPercent] {
            DesignTokens.UIScale.setPercent(scale)
            for width in PanelWidth.allPX {
                let sidebar = makeLaidOutSidebar(width: width)
                let items = descendants(of: sidebar).compactMap { $0 as? TerminalLeftSidebarSectionItemView }
                XCTAssertEqual(items.count, TerminalLeftSidebarSection.allCases.count)
                let widths = items.map(\.frame.width)
                let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
                XCTAssertLessThanOrEqual(
                    spread,
                    1,
                    "section items differed by \(spread)pt at \(width)pt, scale \(scale): \(widths)"
                )
            }
        }
    }

    /// The list used to sit 2pt below the strip, which read as glued to it.
    func testListStartsAFullSpacingStepBelowTheStrip() {
        let sidebar = makeLaidOutSidebar(width: PanelWidth.defaultPX)
        let stripFrame = sidebar.sectionControlFrameForTesting
        let panelFrame = sidebar.historyPanel.frame
        XCTAssertEqual(
            stripFrame.minY - panelFrame.maxY,
            DesignTokens.Component.leftSidebarSectionStripBottomGapPX,
            accuracy: 0.01
        )
        XCTAssertEqual(
            DesignTokens.Component.leftSidebarSectionStripBottomGapPX,
            DesignTokens.Space.x3PX
        )
    }

    func testSelectingASectionMovesTheSelectedItem() {
        let sidebar = makeLaidOutSidebar(width: PanelWidth.defaultPX)
        let items = descendants(of: sidebar).compactMap { $0 as? TerminalLeftSidebarSectionItemView }
        sidebar.showSection(.agentSessions)
        XCTAssertEqual(items.filter(\.isSelectedSection).map(\.section), [.agentSessions])
        sidebar.showSection(.commandHistory)
        XCTAssertEqual(items.filter(\.isSelectedSection).map(\.section), [.commandHistory])
    }

    // MARK: - Shared search pill

    /// All three sidebar sections had their own near-identical pill before it
    /// was extracted; they must now share exactly one implementation.
    func testEverySidebarSectionUsesTheSharedSearchPill() {
        let sidebar = makeLaidOutSidebar(width: PanelWidth.defaultPX)
        let explorer = TerminalFileExplorerPanelView()
        layOut(explorer, width: PanelWidth.defaultPX)
        for panel in [sidebar.historyPanel as NSView, sidebar.agentSessionPanel as NSView, explorer] {
            let pills = descendants(of: panel).compactMap { $0 as? TerminalSidebarSearchPillView }
            XCTAssertEqual(pills.count, 1, "\(type(of: panel)) must host exactly one shared pill")
            XCTAssertEqual(
                pills.first?.frame.height,
                DesignTokens.Component.sidebarSearchPillHeightPX
            )
        }
    }

    func testSearchPillShowsItsClearButtonOnlyWhileItHasText() {
        let pill = TerminalSidebarSearchPillView(placeholder: { "filter" })
        layOut(pill, width: 200, height: DesignTokens.Component.sidebarSearchPillHeightPX)
        XCTAssertFalse(pill.isClearButtonVisibleForTesting)
        pill.stringValue = "swift"
        XCTAssertTrue(pill.isClearButtonVisibleForTesting)
        pill.stringValue = ""
        XCTAssertFalse(pill.isClearButtonVisibleForTesting)
    }

    // MARK: - Helpers

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func makeLaidOutSidebar(width: CGFloat) -> TerminalLeftSidebarPanelView {
        let sidebar = TerminalLeftSidebarPanelView()
        layOut(sidebar, width: width, height: Self.panelHeightPX)
        return sidebar
    }

    private func layOut(_ view: NSView, width: CGFloat, height: CGFloat = TerminalLeftSidebarLayoutTests.panelHeightPX) {
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
    }

    private func assertNoEmptyStateOverlap(
        in sidebar: TerminalLeftSidebarPanelView,
        section: TerminalLeftSidebarSection,
        width: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let panel: NSView
        let emptyStateFrame: NSRect
        let labelFrame: NSRect
        let textOverflows: Bool
        let searchPillFrame: NSRect
        let headerFrame: NSRect
        let listFrame: NSRect
        switch section {
        case .commandHistory:
            panel = sidebar.historyPanel
            emptyStateFrame = sidebar.historyPanel.emptyStateFrameForTesting
            labelFrame = sidebar.historyPanel.emptyStateLabelFrameForTesting
            textOverflows = sidebar.historyPanel.emptyStateTextOverflowsFrameForTesting
            searchPillFrame = sidebar.historyPanel.searchPillFrameForTesting
            headerFrame = sidebar.historyPanel.sectionHeaderFrameForTesting
            listFrame = sidebar.historyPanel.listRegionFrameForTesting
        case .agentSessions:
            panel = sidebar.agentSessionPanel
            emptyStateFrame = sidebar.agentSessionPanel.emptyStateFrameForTesting
            labelFrame = sidebar.agentSessionPanel.emptyStateLabelFrameForTesting
            textOverflows = sidebar.agentSessionPanel.emptyStateTextOverflowsFrameForTesting
            searchPillFrame = sidebar.agentSessionPanel.searchPillFrameForTesting
            headerFrame = sidebar.agentSessionPanel.sectionHeaderFrameForTesting
            listFrame = sidebar.agentSessionPanel.listRegionFrameForTesting
        }
        let context = "section=\(section) width=\(width) empty=\(emptyStateFrame) list=\(listFrame)"

        // The original bug: the wrapping label had no determinate width, so it
        // resolved to a 4pt-wide frame and drew its sentence far outside that
        // frame, over the search pill and the header. Both halves are pinned
        // here — the label must fill the list region's text column, and the
        // message must fit inside the label's own frame.
        // `NSTextField` frames are a couple of points wider than their
        // alignment rect, so this is a lower bound, not an equality.
        XCTAssertGreaterThanOrEqual(
            labelFrame.width,
            listFrame.width - 2 * DesignTokens.Component.commandHistoryPanelInsetXPX,
            "empty-state label must span the list region's text column: \(context) label=\(labelFrame)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            textOverflows,
            "empty-state message must fit inside its own frame: \(context) label=\(labelFrame)",
            file: file,
            line: line
        )
        XCTAssertFalse(emptyStateFrame.isEmpty, "empty state must be laid out: \(context)", file: file, line: line)
        XCTAssertFalse(
            emptyStateFrame.intersects(searchPillFrame),
            "empty state must not overlap the search pill: \(context) pill=\(searchPillFrame)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            emptyStateFrame.intersects(headerFrame),
            "empty state must not overlap the section header: \(context) header=\(headerFrame)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            listFrame.contains(emptyStateFrame),
            "empty state must stay inside the list region: \(context)",
            file: file,
            line: line
        )
        // The section selector lives above every panel, so the panel origin
        // already excludes it; assert the container never lets a panel ride up
        // over the selector.
        let selectorFrame = sidebar.sectionControlFrameForTesting
        let emptyStateInSidebar = panel.convert(emptyStateFrame, to: sidebar)
        XCTAssertFalse(
            emptyStateInSidebar.intersects(selectorFrame),
            "empty state must not overlap the section selector: \(context) selector=\(selectorFrame)",
            file: file,
            line: line
        )
    }

    private func temporaryHistoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-sidebar-layout-tests-\(UUID().uuidString)")
            .appendingPathComponent("command-history.json")
    }
}
