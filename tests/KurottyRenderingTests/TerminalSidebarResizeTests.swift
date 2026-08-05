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

    private func makeController(width: CGFloat = 1400) -> TerminalWindowController {
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
        controller.setCommandHistoryPanelVisible(true)
        controller.setFileExplorerPanelVisible(true)
        layOut(controller)
        return controller
    }

    private func layOut(_ controller: TerminalWindowController) {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.commandHistorySplitView.layoutSubtreeIfNeeded()
    }

    private func setSidebarWidth(_ width: CGFloat, in controller: TerminalWindowController) {
        controller.commandHistorySplitView.setPosition(width, ofDividerAt: 0)
        layOut(controller)
    }

    private func setExplorerWidth(_ width: CGFloat, in controller: TerminalWindowController) {
        let split = controller.commandHistorySplitView
        split.setPosition(split.bounds.width - width, ofDividerAt: split.arrangedSubviews.count - 2)
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
}
