import AppKit
import XCTest
@testable import KurottyApp

/// The sidebars were pinned at their minimum width and the dividers did not
/// move: the split view set a frame on every drag and Auto Layout threw it away
/// on the next pass. The split view owns the column frames now, so these cover
/// both halves of that — the drag has to land, and the terminal has to survive
/// a window small enough that two wide sidebars would otherwise erase it.
@MainActor
final class TerminalSidebarResizeTests: XCTestCase {
    private enum Width {
        static let sidebarMin = DesignTokens.Component.commandHistoryPanelMinWidthPX
        static let sidebarMax = DesignTokens.Component.commandHistoryPanelMaxWidthPX
        static let explorerMin = DesignTokens.Component.fileExplorerPanelMinWidthPX
        static let explorerMax = DesignTokens.Component.fileExplorerPanelMaxWidthPX
        static let terminalMin = DesignTokens.Component.terminalColumnMinWidthPX
    }

    /// A divider sits between the columns, so a column lands one thickness short
    /// of the requested position.
    private let tolerance: CGFloat = 2

    /// Window widths wide enough for both sidebars at their default plus the
    /// terminal's floor, so nothing here is testing the over-subscribed case.
    private let roomyWidths: [CGFloat] = [1200, 1400, 1800, 2400]

    private func makeController(
        width: CGFloat = 1400,
        showingHistoryPanel: Bool = true
    ) -> TerminalWindowController {
        let session = TmuxPaneSession(
            writeHandler: { _ in },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let controller = TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: session),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        controller.window?.setContentSize(NSSize(width: width, height: 900))
        // The split view has to have a real width before a panel opens, the way
        // it does when the user hits the toggle on a window already on screen.
        layOut(controller)
        if showingHistoryPanel {
            controller.setCommandHistoryPanelVisible(true)
        }
        controller.setFileExplorerPanelVisible(true)
        layOut(controller)
        return controller
    }

    /// Drags the history divider as far right as the delegate permits.
    private func dragHistoryDividerFullyRight(in controller: TerminalWindowController) {
        controller.commandHistorySplitView.setPosition(.greatestFiniteMagnitude, ofDividerAt: 0)
        layOut(controller)
    }

    private func layOut(_ controller: TerminalWindowController) {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.commandHistorySplitView.layoutSubtreeIfNeeded()
    }

    private func setSidebarWidth(_ width: CGFloat, in controller: TerminalWindowController) {
        controller.commandHistorySplitView.setPosition(width, ofDividerAt: 0)
        layOut(controller)
    }

    /// Drives the explorer's divider the way a drag does. The divider sits
    /// between the terminal and the explorer, so the position that leaves the
    /// explorer `width` is a divider thickness short of the plain difference.
    private func setExplorerWidth(_ width: CGFloat, in controller: TerminalWindowController) {
        let split = controller.commandHistorySplitView
        split.setPosition(
            split.bounds.width - width - split.dividerThickness,
            ofDividerAt: split.arrangedSubviews.count - 2
        )
        layOut(controller)
    }

    func testDraggingTheLeftDividerActuallyResizesTheSidebar() {
        let controller = makeController()
        for width in [Width.sidebarMin, 260, 350, Width.sidebarMax] {
            setSidebarWidth(width, in: controller)
            XCTAssertEqual(
                controller.leftSidebarPanel.frame.width,
                width,
                accuracy: tolerance,
                "sidebar did not follow the divider to \(width)"
            )
        }
    }

    func testDraggingTheRightDividerActuallyResizesTheExplorer() {
        let controller = makeController()
        for width in [Width.explorerMin, 300, Width.explorerMax] {
            setExplorerWidth(width, in: controller)
            XCTAssertEqual(
                controller.fileExplorerPanel.frame.width,
                width,
                accuracy: tolerance,
                "explorer did not follow the divider to \(width)"
            )
        }
    }

    func testEveryColumnStillSpansTheSplitViewHeightAfterADrag() {
        let controller = makeController()
        setSidebarWidth(Width.sidebarMax, in: controller)
        setExplorerWidth(Width.explorerMax, in: controller)
        let splitHeight = controller.commandHistorySplitView.frame.height
        XCTAssertGreaterThan(splitHeight, 0)
        for column in [
            controller.leftSidebarPanel,
            controller.terminalContentHostView,
            controller.fileExplorerPanel,
        ] as [NSView] {
            XCTAssertEqual(column.frame.height, splitHeight, accuracy: 0.5)
        }
    }

    func testTheColumnsFillTheSplitViewWithoutLeavingAHole() {
        let controller = makeController()
        setSidebarWidth(Width.sidebarMax, in: controller)
        setExplorerWidth(Width.explorerMax, in: controller)
        let split = controller.commandHistorySplitView
        let occupied = split.arrangedSubviews.reduce(0) { $0 + $1.frame.width }
            + split.dividerThickness * CGFloat(split.arrangedSubviews.count - 1)
        XCTAssertEqual(occupied, split.frame.width, accuracy: tolerance)
    }

    func testShrinkingTheWindowNeverErasesTheTerminal() {
        let controller = makeController()
        // Both sidebars dragged wide is the case that used to leave no terminal.
        setSidebarWidth(Width.sidebarMax, in: controller)
        setExplorerWidth(Width.explorerMax, in: controller)

        for windowWidth in [CGFloat(1400), 1000, 900, 800, 700] {
            controller.window?.setContentSize(NSSize(width: windowWidth, height: 900))
            layOut(controller)
            XCTAssertGreaterThanOrEqual(
                controller.terminalContentHostView.frame.width,
                Width.terminalMin - tolerance,
                "terminal fell below its floor at window width \(windowWidth)"
            )
        }
    }

    func testSidebarsGiveWidthBackButNeverBelowTheirMinimum() {
        let controller = makeController()
        setSidebarWidth(Width.sidebarMax, in: controller)
        setExplorerWidth(Width.explorerMax, in: controller)
        controller.window?.setContentSize(NSSize(width: 800, height: 900))
        layOut(controller)

        XCTAssertGreaterThanOrEqual(
            controller.leftSidebarPanel.frame.width,
            Width.sidebarMin - tolerance
        )
        XCTAssertGreaterThanOrEqual(
            controller.fileExplorerPanel.frame.width,
            Width.explorerMin - tolerance
        )
    }

    func testAWindowTooNarrowForEveryMinimumStillLaysOutWithoutOverlap() {
        // 200 + 240 + 210 plus dividers does not fit in 640. Nothing can satisfy
        // every floor here; the columns must still tile the width in order.
        let controller = makeController(width: 640)
        let split = controller.commandHistorySplitView
        var previousMaxX: CGFloat = -1
        for column in split.arrangedSubviews {
            XCTAssertGreaterThanOrEqual(column.frame.minX, previousMaxX)
            XCTAssertGreaterThanOrEqual(column.frame.width, 0)
            previousMaxX = column.frame.maxX
        }
        XCTAssertLessThanOrEqual(previousMaxX, split.frame.width + tolerance)
    }

    func testARevealedPanelOpensAtItsDesignedWidthRatherThanTakingTheWindow() {
        let controller = makeController()
        controller.setFileExplorerPanelVisible(false)
        layOut(controller)
        controller.setFileExplorerPanelVisible(true)
        layOut(controller)
        XCTAssertEqual(
            controller.fileExplorerPanel.frame.width,
            DesignTokens.Component.fileExplorerPanelDefaultWidthPX,
            accuracy: tolerance
        )
    }

    // MARK: - The explorer's divider is not always divider 1

    /// With the history panel hidden the explorer's divider *is* divider 0, so
    /// the delegate's limits — keyed off the index — handed the explorer the
    /// history panel's, and it opened at everything right of 460pt: 1339pt in
    /// an 1800pt window. These cover both panel arrangements at every width.

    func testTheExplorerOpensAtItsDefaultWidthWhicheverPanelsAreShown() {
        for showingHistory in [true, false] {
            for windowWidth in roomyWidths {
                let controller = makeController(
                    width: windowWidth,
                    showingHistoryPanel: showingHistory
                )
                XCTAssertEqual(
                    controller.fileExplorerPanel.frame.width,
                    DesignTokens.Component.fileExplorerPanelDefaultWidthPX,
                    accuracy: tolerance,
                    "explorer opened wrong at window \(windowWidth), history shown \(showingHistory)"
                )
            }
        }
    }

    func testTheExplorerStopsAtItsMaximumWhenDraggedWider() {
        for showingHistory in [true, false] {
            for windowWidth in roomyWidths {
                let controller = makeController(
                    width: windowWidth,
                    showingHistoryPanel: showingHistory
                )
                // Past the maximum, and then past the whole window.
                for attempt in [Width.explorerMax + 200, windowWidth] {
                    setExplorerWidth(attempt, in: controller)
                    XCTAssertLessThanOrEqual(
                        controller.fileExplorerPanel.frame.width,
                        Width.explorerMax + tolerance,
                        "explorer passed its maximum dragging to \(attempt) "
                            + "at window \(windowWidth), history shown \(showingHistory)"
                    )
                }
            }
        }
    }

    func testTheExplorerStopsAtItsMinimumWhenDraggedNarrower() {
        for showingHistory in [true, false] {
            for windowWidth in roomyWidths {
                let controller = makeController(
                    width: windowWidth,
                    showingHistoryPanel: showingHistory
                )
                for attempt in [Width.explorerMin - 100, 0] {
                    setExplorerWidth(attempt, in: controller)
                    XCTAssertGreaterThanOrEqual(
                        controller.fileExplorerPanel.frame.width,
                        Width.explorerMin - tolerance,
                        "explorer fell under its minimum dragging to \(attempt) "
                            + "at window \(windowWidth), history shown \(showingHistory)"
                    )
                }
            }
        }
    }

    /// A drag between the limits has to land where it was dropped, not snap to
    /// one of them — that is what "the resize is broken" looked like.
    func testADragInsideTheLimitsLandsWhereItWasDropped() {
        for showingHistory in [true, false] {
            let controller = makeController(width: 1800, showingHistoryPanel: showingHistory)
            for width in [Width.explorerMin, 280, 350, 420, Width.explorerMax] {
                setExplorerWidth(width, in: controller)
                XCTAssertEqual(
                    controller.fileExplorerPanel.frame.width,
                    width,
                    accuracy: tolerance,
                    "explorer did not follow the divider to \(width), "
                        + "history shown \(showingHistory)"
                )
            }
        }
    }

    func testTheExplorerKeepsItsWidthAcrossAWindowResize() {
        for showingHistory in [true, false] {
            let controller = makeController(width: 1400, showingHistoryPanel: showingHistory)
            for windowWidth in roomyWidths + [1400] {
                controller.window?.setContentSize(NSSize(width: windowWidth, height: 900))
                layOut(controller)
                XCTAssertEqual(
                    controller.fileExplorerPanel.frame.width,
                    DesignTokens.Component.fileExplorerPanelDefaultWidthPX,
                    accuracy: tolerance,
                    "explorer drifted at window \(windowWidth), history shown \(showingHistory)"
                )
            }
        }
    }

    // MARK: - Terminal floor

    /// The explorer's divider refused to squeeze the terminal; the history
    /// divider did not, so dragging the history panel to its 460pt maximum left
    /// the terminal at 88pt in a 760pt window and 130pt at 900pt, against its
    /// own 240pt floor.
    func testDraggingTheHistoryPanelWideNeverTakesTheTerminalBelowItsFloor() {
        for width in [760.0, 900.0, 1000.0, 1400.0, 1800.0] {
            let controller = makeController(width: width)
            dragHistoryDividerFullyRight(in: controller)
            XCTAssertGreaterThanOrEqual(
                controller.terminalContentHostView.frame.width,
                DesignTokens.Component.terminalColumnMinWidthPX,
                "terminal was \(controller.terminalContentHostView.frame.width)pt at \(width)pt"
            )
        }
    }

    /// The floor must not cost the history panel its own range on a window with
    /// room for both -- a fix that clamped every width would be a regression
    /// dressed as a fix.
    func testAWideWindowStillLetsTheHistoryPanelReachItsMaximum() {
        let controller = makeController(width: 1800)
        dragHistoryDividerFullyRight(in: controller)
        XCTAssertEqual(
            controller.leftSidebarPanel.frame.width,
            DesignTokens.Component.commandHistoryPanelMaxWidthPX,
            accuracy: 1
        )
    }

    /// When the window cannot satisfy both, the sidebar keeps its own minimum
    /// rather than collapsing -- the same order the explorer's constraint uses.
    func testAnOversubscribedWindowKeepsTheHistoryPanelAtItsMinimum() {
        let controller = makeController(width: 620)
        dragHistoryDividerFullyRight(in: controller)
        XCTAssertGreaterThanOrEqual(
            controller.leftSidebarPanel.frame.width,
            DesignTokens.Component.commandHistoryPanelMinWidthPX - 1
        )
    }
}
