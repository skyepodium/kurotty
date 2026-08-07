import AppKit
import XCTest
@testable import KurottyApp

/// Layout regression coverage for the left sidebar container and its two
/// sections. The empty state must occupy the list region only: it may never
/// overlap the search pill or the section selector, at any supported panel
/// width.
///
/// Neither section draws a title of its own any more -- the section strip is
/// the title -- so there is no panel header left to overlap.
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

    // MARK: - Row rhythm

    /// The reference sidebars this borrows from list about twenty items and can
    /// afford a 40pt row. This list holds hundreds, so the rhythm is spent on
    /// the section headers -- the directory rows -- and nowhere else.
    func testVerticalRhythmIsSpentOnSectionHeadersNotOnLeafRows() {
        let air = DesignTokens.Component.commandHistoryGroupRowTopAirPX
        XCTAssertGreaterThan(air, 0, "a directory row has to be separated from the group above it")
        XCTAssertEqual(
            DesignTokens.Component.commandHistoryGroupRowHeightPX,
            DesignTokens.Component.commandHistoryGroupContentHeightPX + air,
            accuracy: 0.01,
            "the extra height is air, not a bigger content band"
        )
        // The leaf row is the one that repeats hundreds of times, so it is the
        // one that must not grow.
        XCTAssertLessThanOrEqual(
            DesignTokens.Component.commandHistoryCommandRowHeightPX,
            DesignTokens.Component.commandHistoryGroupContentHeightPX
        )
    }

    /// Guards the trade directly: a taller leaf row buys rhythm by taking rows
    /// off the screen, and this is how many rows that costs.
    func testARealisticHistoryStillFillsTheListWithLeafRows() {
        let listHeightPX: CGFloat = 560
        let visibleLeafRows = Int(
            (listHeightPX / DesignTokens.Component.commandHistoryCommandRowHeightPX)
                .rounded(.down)
        )
        XCTAssertGreaterThanOrEqual(
            visibleLeafRows,
            18,
            "a 40pt row would show 14 here; the panel is a history, not a list of twenty threads"
        )
    }

    /// The count badge and the relative time are different views on different
    /// row types, and they are the same column.
    func testTrailingColumnsShareOneRightEdgeAcrossRowTypes() {
        let theme = DesignTokens.ChromeTheme.dark
        let widthPX: CGFloat = 300
        let groupCell = TerminalCommandHistoryGroupCellView(
            group: TerminalCommandHistoryRowBuilder.groups(
                entriesNewestFirst: [historyEntry(command: "swift test")],
                filter: ""
            )[0],
            chromeTheme: theme
        )
        layOut(groupCell, width: widthPX, height: DesignTokens.Component.commandHistoryGroupRowHeightPX)
        let commandCell = TerminalCommandHistoryCommandCellView(
            entry: historyEntry(command: "swift test"),
            chromeTheme: theme,
            now: Date()
        )
        layOut(commandCell, width: widthPX, height: DesignTokens.Component.commandHistoryCommandRowHeightPX)

        let badgeRightEdge = trailingEdge(of: groupCell, ofType: TerminalSidebarCountBadgeView.self)
        let timeRightEdge = rightAlignedLabelTrailingEdge(in: commandCell)
        XCTAssertEqual(badgeRightEdge, timeRightEdge, accuracy: 0.01)
    }

    /// The reserved leading slot exists because SF Symbols are not one width.
    /// A folder row and a file row must start their names at the same x.
    func testExplorerNameColumnDoesNotDependOnTheRowsIconGlyph() {
        let theme = DesignTokens.ChromeTheme.dark
        let widthPX: CGFloat = 300
        let leadingEdges = [FileExplorerNodeKind.directory, .file].map { kind -> CGFloat in
            let cell = TerminalFileExplorerRowCellView(
                item: TerminalFileExplorerOutlineItem(
                    node: FileExplorerNode(
                        url: URL(fileURLWithPath: "/tmp/kurotty/entry"),
                        kind: kind
                    )
                ),
                badge: nil,
                chromeTheme: theme
            )
            layOut(cell, width: widthPX, height: DesignTokens.Component.fileExplorerRowHeightPX)
            return leadingEdgeOfNameLabel(in: cell)
        }
        XCTAssertEqual(leadingEdges[0], leadingEdges[1], accuracy: 0.01)
        XCTAssertGreaterThan(leadingEdges[0], 0)
    }

    /// A command row is one outline level below the directory row that owns it,
    /// so its status slot is one level narrower and the two text columns land on
    /// the same x. This used to hold by accident.
    func testCommandColumnIsDerivedFromTheDirectoryColumn() {
        XCTAssertEqual(
            DesignTokens.Component.sidebarRowStatusSlotWidthPX
                + DesignTokens.Component.commandHistoryOutlineIndentationPX,
            DesignTokens.Component.sidebarRowIconSlotWidthPX,
            accuracy: 0.01
        )
        XCTAssertGreaterThanOrEqual(
            DesignTokens.Component.sidebarRowStatusSlotWidthPX,
            DesignTokens.Component.commandHistoryStatusDotSizePX,
            "the slot must at least hold the dot it centres"
        )
    }

    // MARK: - Keyboard hint

    func testKeyHintShowsOnlyWhileTheFieldIsIdle() {
        let pill = TerminalSidebarSearchPillView(placeholder: { "filter" })
        layOut(pill, width: 260, height: DesignTokens.Component.sidebarSearchPillHeightPX)
        XCTAssertTrue(pill.isKeyHintVisibleForTesting)
        XCTAssertFalse(pill.isClearButtonVisibleForTesting)

        pill.stringValue = "swift"
        XCTAssertFalse(pill.isKeyHintVisibleForTesting, "a hint competes with the query it sits beside")
        XCTAssertTrue(pill.isClearButtonVisibleForTesting)

        pill.stringValue = ""
        XCTAssertTrue(pill.isKeyHintVisibleForTesting)
    }

    /// The cap is a trailing accessory. Left unbounded it stretched across the
    /// whole field and rendered as a bare `/` floating mid-pill.
    func testKeyHintSitsAgainstTheTrailingEdgeOfTheField() {
        let widthPX: CGFloat = 260
        let pill = TerminalSidebarSearchPillView(placeholder: { "filter" })
        layOut(pill, width: widthPX, height: DesignTokens.Component.sidebarSearchPillHeightPX)
        pill.layoutSubtreeIfNeeded()

        let hint = pill.keyHintFrameForTesting
        XCTAssertEqual(
            hint.maxX,
            widthPX - DesignTokens.Component.sidebarSearchPillEdgeInsetXPX,
            accuracy: 0.5
        )
        XCTAssertLessThanOrEqual(
            hint.width,
            DesignTokens.Component.sidebarSearchHintBadgeMinWidthPX
                + 2 * DesignTokens.Component.sidebarSearchHintBadgeTextInsetXPX,
            "the cap hugs its glyph: \(hint)"
        )
        XCTAssertEqual(hint.height, DesignTokens.Component.sidebarSearchHintBadgeHeightPX, accuracy: 0.5)
    }

    /// Every sidebar advertises the same key, and every sidebar routes it.
    func testAllThreeSidebarSectionsAdvertiseTheFilterKey() {
        let sidebar = makeLaidOutSidebar(width: PanelWidth.defaultPX)
        let explorer = TerminalFileExplorerPanelView()
        layOut(explorer, width: PanelWidth.defaultPX)
        for panel in [sidebar.historyPanel as NSView, sidebar.agentSessionPanel as NSView, explorer] {
            let pill = descendants(of: panel).compactMap { $0 as? TerminalSidebarSearchPillView }.first
            XCTAssertEqual(pill?.isKeyHintVisibleForTesting, true, "\(type(of: panel))")
        }
    }

    // MARK: - Helpers

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func historyEntry(command: String) -> TerminalCommandHistoryEntry {
        TerminalCommandHistoryEntry(
            commandText: command,
            cwd: "/Users/kurotty/dev/kurotty",
            exitCode: 0,
            finishedAt: Date()
        )
    }

    /// Alignment rects, not frames. `NSTextField` draws a frame a couple of
    /// points wider than the box Auto Layout positioned, so comparing raw
    /// frames says two columns are 2pt apart when the ink lines up exactly.
    private func alignmentRect(of view: NSView) -> NSRect {
        view.alignmentRect(forFrame: view.frame)
    }

    private func trailingEdge<T: NSView>(of cell: NSView, ofType type: T.Type) -> CGFloat {
        let match = descendants(of: cell).compactMap { $0 as? T }.first
        return match.map { alignmentRect(of: $0).maxX } ?? .nan
    }

    /// The relative-time label is the only right-aligned label in a command row.
    private func rightAlignedLabelTrailingEdge(in cell: NSView) -> CGFloat {
        let match = descendants(of: cell)
            .compactMap { $0 as? NSTextField }
            .first { $0.alignment == .right }
        return match.map { alignmentRect(of: $0).maxX } ?? .nan
    }

    /// The name label is the only left-aligned text field in an explorer row.
    private func leadingEdgeOfNameLabel(in cell: NSView) -> CGFloat {
        let match = descendants(of: cell).compactMap { $0 as? NSTextField }.first
        return match.map { alignmentRect(of: $0).minX } ?? .nan
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
        let listFrame: NSRect
        switch section {
        case .commandHistory:
            panel = sidebar.historyPanel
            emptyStateFrame = sidebar.historyPanel.emptyStateFrameForTesting
            labelFrame = sidebar.historyPanel.emptyStateLabelFrameForTesting
            textOverflows = sidebar.historyPanel.emptyStateTextOverflowsFrameForTesting
            searchPillFrame = sidebar.historyPanel.searchPillFrameForTesting
            listFrame = sidebar.historyPanel.listRegionFrameForTesting
        case .agentSessions:
            panel = sidebar.agentSessionPanel
            emptyStateFrame = sidebar.agentSessionPanel.emptyStateFrameForTesting
            labelFrame = sidebar.agentSessionPanel.emptyStateLabelFrameForTesting
            textOverflows = sidebar.agentSessionPanel.emptyStateTextOverflowsFrameForTesting
            searchPillFrame = sidebar.agentSessionPanel.searchPillFrameForTesting
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
