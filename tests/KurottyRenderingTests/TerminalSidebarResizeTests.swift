import AppKit
import XCTest
@testable import KurottyApp

/// The sidebars were pinned at their minimum width and the dividers did not
/// move: the split view set a frame on every drag and Auto Layout threw it away
/// on the next pass. The split view owns the column frames now, so these cover
/// both halves of that — the drag has to land, and the terminal has to survive
/// a window small enough that two wide sidebars would otherwise erase it.
///
/// Everything here is written against a *panel*, never against a divider index
/// or a side. The panels swapped sides once already; a suite that spells out
/// "divider 0" is a suite that has to be rewritten every time and, worse, one
/// that goes on passing while testing the wrong column. `setPanelWidth` finds
/// the divider from the split view's own arrangement, which is the observable
/// thing, so these read the layout rather than restating it.
@MainActor
final class TerminalSidebarResizeTests: XCTestCase {
    private enum Width {
        static let historyMin = DesignTokens.Component.commandHistoryPanelMinWidthPX
        static let historyMax = DesignTokens.Component.commandHistoryPanelMaxWidthPX
        static let historyDefault = DesignTokens.Component.commandHistoryPanelDefaultWidthPX
        static let explorerMin = DesignTokens.Component.fileExplorerPanelMinWidthPX
        static let explorerMax = DesignTokens.Component.fileExplorerPanelMaxWidthPX
        static let explorerDefault = DesignTokens.Component.fileExplorerPanelDefaultWidthPX
        static let terminalMin = DesignTokens.Component.terminalColumnMinWidthPX
    }

    /// A divider sits between the columns, so a column lands one thickness short
    /// of the requested position.
    private let tolerance: CGFloat = 2

    /// Window widths wide enough for both sidebars at their default plus the
    /// terminal's floor, so nothing here is testing the over-subscribed case.
    private let roomyWidths: [CGFloat] = [1200, 1400, 1800, 2400]

    /// One sidebar under test, named by content. The tests iterate this so both
    /// panels get identical coverage and neither can quietly lose it.
    private struct Sidebar {
        let name: String
        let panel: (TerminalWindowController) -> NSView
        let minimumPX: CGFloat
        let defaultPX: CGFloat
        let maximumPX: CGFloat
        let setVisible: (TerminalWindowController, Bool) -> Void
    }

    private static let explorer = Sidebar(
        name: "explorer",
        panel: { $0.fileExplorerPanel },
        minimumPX: Width.explorerMin,
        defaultPX: Width.explorerDefault,
        maximumPX: Width.explorerMax,
        setVisible: { $0.setFileExplorerPanelVisible($1) }
    )

    private static let history = Sidebar(
        name: "history",
        panel: { $0.leftSidebarPanel },
        minimumPX: Width.historyMin,
        defaultPX: Width.historyDefault,
        maximumPX: Width.historyMax,
        setVisible: { $0.setCommandHistoryPanelVisible($1) }
    )

    private static let sidebars = [explorer, history]

    private func makeController(
        width: CGFloat = 1400,
        showing: [Sidebar] = sidebars
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
        for sidebar in showing {
            sidebar.setVisible(controller, true)
        }
        layOut(controller)
        return controller
    }

    private func layOut(_ controller: TerminalWindowController) {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.commandHistorySplitView.layoutSubtreeIfNeeded()
    }

    /// Drives a panel's own divider the way a drag does.
    ///
    /// Which divider that is comes from where the panel actually sits: the
    /// leading column owns the divider after it and a trailing column the
    /// divider before it. A trailing column's divider position is measured from
    /// the split view's leading edge, so the position that leaves it `width` is
    /// a divider thickness short of the plain difference.
    private func setPanelWidth(
        _ width: CGFloat,
        of sidebar: Sidebar,
        in controller: TerminalWindowController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let split = controller.commandHistorySplitView
        let panel = sidebar.panel(controller)
        guard let paneIndex = split.arrangedSubviews.firstIndex(of: panel) else {
            XCTFail("the \(sidebar.name) panel is not in the split view", file: file, line: line)
            return
        }
        if paneIndex == 0 {
            split.setPosition(width, ofDividerAt: 0)
        } else {
            split.setPosition(
                split.bounds.width - width - split.dividerThickness,
                ofDividerAt: paneIndex - 1
            )
        }
        layOut(controller)
    }

    /// Drags a panel's divider as far as the delegate permits in one direction.
    private func dragFully(
        _ sidebar: Sidebar,
        wider: Bool,
        in controller: TerminalWindowController
    ) {
        setPanelWidth(wider ? .greatestFiniteMagnitude : 0, of: sidebar, in: controller)
    }

    // MARK: - Which panel is on which side

    /// The explorer is the panel that is read constantly, so it took the
    /// leading side and the history panel moved to the trailing one.
    func testTheExplorerIsTheLeadingColumnAndTheHistoryPanelTheTrailingOne() {
        let controller = makeController()
        XCTAssertEqual(
            controller.commandHistorySplitView.arrangedSubviews,
            [
                controller.fileExplorerPanel,
                controller.terminalContentHostView,
                controller.leftSidebarPanel,
            ]
        )
        XCTAssertLessThan(
            controller.fileExplorerPanel.frame.minX,
            controller.terminalContentHostView.frame.minX
        )
        XCTAssertGreaterThan(
            controller.leftSidebarPanel.frame.minX,
            controller.terminalContentHostView.frame.minX
        )
    }

    /// Each toggle opens the panel on its own side however the other one is
    /// left, so a user who works with one sidebar open never sees the layout
    /// depend on the other.
    func testEachPanelOpensOnItsOwnSideWhicheverPanelsAreShown() {
        for other in Self.sidebars {
            for otherShown in [true, false] {
                for sidebar in Self.sidebars where sidebar.name != other.name {
                    let controller = makeController(showing: otherShown ? [other] : [])
                    sidebar.setVisible(controller, true)
                    layOut(controller)
                    let split = controller.commandHistorySplitView
                    let panel = sidebar.panel(controller)
                    let terminalX = controller.terminalContentHostView.frame.minX
                    let expectedLeading = split.arrangedSubviews.first === panel
                    XCTAssertEqual(
                        panel.frame.minX < terminalX,
                        expectedLeading,
                        "\(sidebar.name) landed on the wrong side of the terminal "
                            + "with \(other.name) shown \(otherShown)"
                    )
                }
            }
        }
    }

    // MARK: - Each panel keeps its own limits

    /// The bug this suite exists for: a divider was identified by its *index*,
    /// so with one panel hidden the other's divider became divider 0 and
    /// inherited the first panel's limits. The explorer opened at everything
    /// right of 460pt — 1339pt in an 1800pt window.
    ///
    /// Swapping the sides moved which panel has the unstable index (the trailing
    /// one now does), so covering only the explorer would leave the same bug
    /// untested on the other side. Both panels are driven here, with the *other*
    /// panel both shown and hidden, at every width.
    func testEachPanelStopsAtItsOwnMaximumWhicheverPanelsAreShown() {
        for sidebar in Self.sidebars {
            for otherShown in [true, false] {
                for windowWidth in roomyWidths {
                    let controller = makeController(
                        width: windowWidth,
                        showing: otherShown ? Self.sidebars : [sidebar]
                    )
                    for attempt in [sidebar.maximumPX + 200, windowWidth] {
                        setPanelWidth(attempt, of: sidebar, in: controller)
                        XCTAssertLessThanOrEqual(
                            sidebar.panel(controller).frame.width,
                            sidebar.maximumPX + tolerance,
                            "\(sidebar.name) passed its maximum dragging to \(attempt) at "
                                + "window \(windowWidth), other shown \(otherShown)"
                        )
                    }
                }
            }
        }
    }

    func testEachPanelStopsAtItsOwnMinimumWhicheverPanelsAreShown() {
        for sidebar in Self.sidebars {
            for otherShown in [true, false] {
                for windowWidth in roomyWidths {
                    let controller = makeController(
                        width: windowWidth,
                        showing: otherShown ? Self.sidebars : [sidebar]
                    )
                    for attempt in [sidebar.minimumPX - 100, 0] {
                        setPanelWidth(attempt, of: sidebar, in: controller)
                        XCTAssertGreaterThanOrEqual(
                            sidebar.panel(controller).frame.width,
                            sidebar.minimumPX - tolerance,
                            "\(sidebar.name) fell under its minimum dragging to \(attempt) at "
                                + "window \(windowWidth), other shown \(otherShown)"
                        )
                    }
                }
            }
        }
    }

    /// The floors above would both pass if the two panels shared one limit, so
    /// this is what makes them mean "its *own* minimum". The explorer's floor is
    /// 10pt above the history panel's; a panel squeezed to a width between them
    /// must land on its own number, not on its neighbour's.
    func testAPanelSqueezedBetweenTheTwoFloorsLandsOnItsOwnOne() {
        XCTAssertNotEqual(
            Width.explorerMin,
            Width.historyMin,
            "this test is only meaningful while the two floors differ"
        )
        let between = (Width.explorerMin + Width.historyMin) / 2
        for sidebar in Self.sidebars {
            for otherShown in [true, false] {
                let controller = makeController(showing: otherShown ? Self.sidebars : [sidebar])
                setPanelWidth(between, of: sidebar, in: controller)
                XCTAssertEqual(
                    sidebar.panel(controller).frame.width,
                    max(between, sidebar.minimumPX),
                    accuracy: tolerance,
                    "\(sidebar.name) clamped to the other panel's floor, "
                        + "other shown \(otherShown)"
                )
            }
        }
    }

    func testEachPanelOpensAtItsOwnDefaultWidthWhicheverPanelsAreShown() {
        for sidebar in Self.sidebars {
            for otherShown in [true, false] {
                for windowWidth in roomyWidths {
                    let controller = makeController(
                        width: windowWidth,
                        showing: otherShown ? Self.sidebars : [sidebar]
                    )
                    XCTAssertEqual(
                        sidebar.panel(controller).frame.width,
                        sidebar.defaultPX,
                        accuracy: tolerance,
                        "\(sidebar.name) opened wrong at window \(windowWidth), "
                            + "other shown \(otherShown)"
                    )
                }
            }
        }
    }

    /// A drag between the limits has to land where it was dropped, not snap to
    /// one of them — that is what "the resize is broken" looked like.
    func testADragInsideTheLimitsLandsWhereItWasDropped() {
        for sidebar in Self.sidebars {
            for otherShown in [true, false] {
                let controller = makeController(
                    width: 1800,
                    showing: otherShown ? Self.sidebars : [sidebar]
                )
                let midpoint = (sidebar.minimumPX + sidebar.maximumPX) / 2
                for width in [sidebar.minimumPX, midpoint, sidebar.maximumPX] {
                    setPanelWidth(width, of: sidebar, in: controller)
                    XCTAssertEqual(
                        sidebar.panel(controller).frame.width,
                        width,
                        accuracy: tolerance,
                        "\(sidebar.name) did not follow the divider to \(width), "
                            + "other shown \(otherShown)"
                    )
                }
            }
        }
    }

    func testEachPanelKeepsItsWidthAcrossAWindowResize() {
        for sidebar in Self.sidebars {
            for otherShown in [true, false] {
                let controller = makeController(
                    width: 1400,
                    showing: otherShown ? Self.sidebars : [sidebar]
                )
                for windowWidth in roomyWidths + [1400] {
                    controller.window?.setContentSize(NSSize(width: windowWidth, height: 900))
                    layOut(controller)
                    XCTAssertEqual(
                        sidebar.panel(controller).frame.width,
                        sidebar.defaultPX,
                        accuracy: tolerance,
                        "\(sidebar.name) drifted at window \(windowWidth), "
                            + "other shown \(otherShown)"
                    )
                }
            }
        }
    }

    // MARK: - Restoring a collapsed panel

    /// Puts a panel into the state a stale autosaved frame leaves it in: zero
    /// width, with the terminal holding the space and the panel's divider
    /// pushed flat against the window edge.
    ///
    /// Assembled by hand because no drag can reach it — `constrainMinCoordinate`
    /// and `constrainMaxCoordinate` stop a divider at the panel's own minimum,
    /// which is the entire reason `restoreSidebarWidthIfCollapsed` exists as a
    /// separate path. Collapsing the panel alone would not do: the divider
    /// would still be sitting where the default width puts it, `setPosition`
    /// would be asked for the position it already has, and the test would pass
    /// on a restore that never ran.
    private func collapseToZeroWidth(_ sidebar: Sidebar, in controller: TerminalWindowController) {
        let split = controller.commandHistorySplitView
        let panel = sidebar.panel(controller)
        let terminal = controller.terminalContentHostView
        let height = split.bounds.height
        if split.arrangedSubviews.first === panel {
            terminal.frame = NSRect(
                x: split.dividerThickness,
                y: 0,
                width: terminal.frame.maxX - split.dividerThickness,
                height: height
            )
            panel.frame = NSRect(x: 0, y: 0, width: 0, height: height)
        } else {
            terminal.frame = NSRect(
                x: terminal.frame.minX,
                y: 0,
                width: split.bounds.width - terminal.frame.minX - split.dividerThickness,
                height: height
            )
            panel.frame = NSRect(x: split.bounds.width, y: 0, width: 0, height: height)
        }
    }

    /// `restoreSidebarWidthIfCollapsed` is the fallback for a panel the
    /// autosaved frames remembered as zero-width. It has to push the divider
    /// belonging to *that* panel: pointed at the wrong one it would widen the
    /// panel the user did not just open and leave the one they did at nothing.
    func testRestoringACollapsedPanelWidensThatPanelAndLeavesTheOtherAlone() {
        for sidebar in Self.sidebars {
            let controller = makeController()
            let other = Self.sidebars.first { $0.name != sidebar.name }!
            let otherWidthBefore = other.panel(controller).frame.width
            collapseToZeroWidth(sidebar, in: controller)
            controller.restoreSidebarWidthIfCollapsed(sidebar.panel(controller))
            layOut(controller)
            XCTAssertEqual(
                sidebar.panel(controller).frame.width,
                sidebar.defaultPX,
                accuracy: tolerance,
                "\(sidebar.name) did not come back at its own default width"
            )
            XCTAssertEqual(
                other.panel(controller).frame.width,
                otherWidthBefore,
                accuracy: tolerance,
                "restoring \(sidebar.name) moved the \(other.name) panel"
            )
        }
    }

    /// AppKit autosaves divider positions by index and records nothing about
    /// which panel was on which side, so v3's frames — written for
    /// [history, terminal, explorer] — would have been replayed onto the
    /// reversed order: a stored 460pt history column is divider 0 at 460, and
    /// divider 0 is now the explorer. The version bump is what drops them.
    func testTheSplitViewAutosaveNameIsNotTheOneTheOldColumnOrderWroteUnder() {
        let controller = makeController()
        XCTAssertEqual(
            controller.commandHistorySplitView.autosaveName,
            AppConstants.CommandHistory.splitViewAutosaveName,
            "the split view has to use the versioned name for the bump to reach it"
        )
        XCTAssertFalse(
            AppConstants.CommandHistory.splitViewAutosaveName.hasSuffix(".v3"),
            "v3 recorded widths for the pre-swap column order and must not be reused"
        )
    }

    // MARK: - Layout invariants

    func testEveryColumnStillSpansTheSplitViewHeightAfterADrag() {
        let controller = makeController()
        for sidebar in Self.sidebars {
            setPanelWidth(sidebar.maximumPX, of: sidebar, in: controller)
        }
        let splitHeight = controller.commandHistorySplitView.frame.height
        XCTAssertGreaterThan(splitHeight, 0)
        for column in controller.commandHistorySplitView.arrangedSubviews {
            XCTAssertEqual(column.frame.height, splitHeight, accuracy: 0.5)
        }
    }

    func testTheColumnsFillTheSplitViewWithoutLeavingAHole() {
        let controller = makeController()
        for sidebar in Self.sidebars {
            setPanelWidth(sidebar.maximumPX, of: sidebar, in: controller)
        }
        let split = controller.commandHistorySplitView
        let occupied = split.arrangedSubviews.reduce(0) { $0 + $1.frame.width }
            + split.dividerThickness * CGFloat(split.arrangedSubviews.count - 1)
        XCTAssertEqual(occupied, split.frame.width, accuracy: tolerance)
    }

    func testShrinkingTheWindowNeverErasesTheTerminal() {
        let controller = makeController()
        // Both sidebars dragged wide is the case that used to leave no terminal.
        for sidebar in Self.sidebars {
            setPanelWidth(sidebar.maximumPX, of: sidebar, in: controller)
        }

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
        for sidebar in Self.sidebars {
            setPanelWidth(sidebar.maximumPX, of: sidebar, in: controller)
        }
        controller.window?.setContentSize(NSSize(width: 800, height: 900))
        layOut(controller)

        for sidebar in Self.sidebars {
            XCTAssertGreaterThanOrEqual(
                sidebar.panel(controller).frame.width,
                sidebar.minimumPX - tolerance,
                "\(sidebar.name) fell under its own minimum"
            )
        }
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
        for sidebar in Self.sidebars {
            let controller = makeController()
            sidebar.setVisible(controller, false)
            layOut(controller)
            sidebar.setVisible(controller, true)
            layOut(controller)
            XCTAssertEqual(
                sidebar.panel(controller).frame.width,
                sidebar.defaultPX,
                accuracy: tolerance,
                "\(sidebar.name) did not reopen at its designed width"
            )
        }
    }

    // MARK: - Terminal floor

    /// Whichever panel is dragged as wide as it will go, the terminal keeps its
    /// floor. Only the trailing panel's divider used to refuse to squeeze it, so
    /// dragging the other one to its 460pt maximum left the terminal at 88pt in
    /// a 760pt window and 130pt at 900pt, against its own 240pt floor.
    func testDraggingEitherPanelWideNeverTakesTheTerminalBelowItsFloor() {
        for sidebar in Self.sidebars {
            for width in [760.0, 900.0, 1000.0, 1400.0, 1800.0] {
                let controller = makeController(width: width)
                dragFully(sidebar, wider: true, in: controller)
                XCTAssertGreaterThanOrEqual(
                    controller.terminalContentHostView.frame.width,
                    Width.terminalMin,
                    "\(sidebar.name): terminal was "
                        + "\(controller.terminalContentHostView.frame.width)pt at \(width)pt"
                )
            }
        }
    }

    /// The floor must not cost a panel its own range on a window with room for
    /// both -- a fix that clamped every width would be a regression dressed as
    /// a fix.
    func testAWideWindowStillLetsEitherPanelReachItsMaximum() {
        for sidebar in Self.sidebars {
            let controller = makeController(width: 1800)
            dragFully(sidebar, wider: true, in: controller)
            XCTAssertEqual(
                sidebar.panel(controller).frame.width,
                sidebar.maximumPX,
                accuracy: 1,
                "\(sidebar.name) could not reach its maximum on a wide window"
            )
        }
    }

    /// When the window cannot satisfy both, a panel keeps its own minimum
    /// rather than collapsing.
    func testAnOversubscribedWindowKeepsEitherPanelAtItsMinimum() {
        for sidebar in Self.sidebars {
            let controller = makeController(width: 620)
            dragFully(sidebar, wider: true, in: controller)
            XCTAssertGreaterThanOrEqual(
                sidebar.panel(controller).frame.width,
                sidebar.minimumPX - 1,
                "\(sidebar.name) collapsed on an over-subscribed window"
            )
        }
    }
}
