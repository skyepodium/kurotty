import AppKit
import XCTest
@testable import KurottyApp

final class TmuxNativeLayoutTests: XCTestCase {
    @MainActor
    func testNativeSplitUsesTmuxLayoutAxisAndProportions() throws {
        let session0 = makeSession()
        let session1 = makeSession()
        let pane0 = TerminalPaneView(frame: .zero, session: session0)
        let pane1 = TerminalPaneView(frame: .zero, session: session1)
        let split = SplitTerminalView(
            axis: .horizontal,
            pane: nil,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        split.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        let layout = try TmuxLayoutParser.parse("100x40,0,0{29x40,0,0,0,70x40,30,0,1}")

        split.installTmuxLayout(layout, panes: ["%0": pane0, "%1": pane1])
        split.layoutSubtreeIfNeeded()

        XCTAssertTrue(split.isVertical)
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        XCTAssertLessThan(pane0.frame.width, pane1.frame.width)
        XCTAssertEqual(pane0.frame.width / pane1.frame.width, 29.0 / 70.0, accuracy: 0.04)
    }

    @MainActor
    func testTmuxSizeOnlyLayoutUpdateKeepsHorizontalPaneViewsAttached() throws {
        let pane0 = TerminalPaneView(frame: .zero, session: makeSession())
        let pane1 = TerminalPaneView(frame: .zero, session: makeSession())
        let panes = ["%0": pane0, "%1": pane1]
        let split = SplitTerminalView(
            axis: .vertical,
            pane: nil,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        split.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let initial = try TmuxLayoutParser.parse("100x40,0,0[100x19,0,0,0,100x20,0,20,1]")
        let resized = try TmuxLayoutParser.parse("120x50,0,0[120x24,0,0,0,120x25,0,25,1]")

        split.installTmuxLayout(initial, panes: panes)
        let originalSuperview0 = pane0.superview
        let originalSuperview1 = pane1.superview
        split.installTmuxLayout(resized, panes: panes)

        XCTAssertTrue(pane0.superview === originalSuperview0)
        XCTAssertTrue(pane1.superview === originalSuperview1)
        XCTAssertTrue(split.arrangedSubviews[0] === pane0)
        XCTAssertTrue(split.arrangedSubviews[1] === pane1)
    }

    @MainActor
    func testNestedTmuxLayoutInstallsEveryPaneExactlyOnce() throws {
        let panes = Dictionary(uniqueKeysWithValues: (0..<3).map { index in
            ("%\(index)", TerminalPaneView(frame: .zero, session: makeSession()))
        })
        let split = SplitTerminalView(
            axis: .vertical,
            pane: nil,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        split.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let layout = try TmuxLayoutParser.parse(
            "120x50,0,0{59x50,0,0,0,60x50,60,0[60x24,60,0,1,60x25,60,25,2]}"
        )

        split.installTmuxLayout(layout, panes: panes)
        split.layoutSubtreeIfNeeded()

        XCTAssertEqual(layout.paneIDs, ["%0", "%1", "%2"])
        for pane in panes.values {
            XCTAssertTrue(split.containsPane(pane))
            XCTAssertNotNil(pane.superview)
        }
    }

    @MainActor
    func testZoomedVisibleLayoutCanHideAndRestoreNativePanes() throws {
        let pane0 = TerminalPaneView(frame: .zero, session: makeSession())
        let pane1 = TerminalPaneView(frame: .zero, session: makeSession())
        let panes = ["%0": pane0, "%1": pane1]
        let split = SplitTerminalView(
            axis: .vertical,
            pane: nil,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        split.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let fullLayout = try TmuxLayoutParser.parse("100x40,0,0{49x40,0,0,0,50x40,50,0,1}")
        let zoomedLayout = try TmuxLayoutParser.parse("100x40,0,0,1")

        split.installTmuxLayout(fullLayout, panes: panes)
        XCTAssertTrue(split.containsPane(pane0))
        XCTAssertTrue(split.containsPane(pane1))

        split.installTmuxLayout(zoomedLayout, panes: panes)
        XCTAssertFalse(split.containsPane(pane0))
        XCTAssertTrue(split.containsPane(pane1))

        split.installTmuxLayout(fullLayout, panes: panes)
        XCTAssertTrue(split.containsPane(pane0))
        XCTAssertTrue(split.containsPane(pane1))
    }

    @MainActor
    func testNestedPlaceholderOnlyTreeUsesRequestedFallbackAxis() throws {
        let dragCoordinator = TerminalPaneDragCoordinator()
        let pane0 = TerminalPaneView(frame: .zero, session: makeSession())
        let pane1 = TerminalPaneView(frame: .zero, session: makeSession())
        let nested = SplitTerminalView(
            axis: .vertical,
            pane: pane0,
            paneDragCoordinator: dragCoordinator
        )
        nested.appendDetachedPaneAsTabRoot(pane1)
        let root = SplitTerminalView(
            axis: .vertical,
            pane: nil,
            paneDragCoordinator: dragCoordinator
        )
        root.addArrangedSubview(nested)

        XCTAssertNotNil(root.replacePaneWithTmuxPlaceholder(pane0))
        XCTAssertNotNil(root.replacePaneWithTmuxPlaceholder(pane1))
        XCTAssertEqual(root.projectionPlaceholderCount, 2)
        XCTAssertEqual(root.arrangedSubviews.count, 1)

        root.split(direction: .down)

        XCTAssertFalse(root.isVertical)
        XCTAssertEqual(root.arrangedSubviews.count, 2)
        XCTAssertTrue(root.arrangedSubviews[0] === nested)
        XCTAssertEqual(root.projectionPlaceholderCount, 2)
        XCTAssertEqual(root.terminalPanesInLayoutOrder.count, 1)
    }

    @MainActor
    func testControlTranscriptCreatesNativeTabsAndRestoresGatewayOnExit() async {
        var writes: [String] = []
        let gateway = TmuxPaneSession(
            writeHandler: { writes.append($0) },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let controller = TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: gateway),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        XCTAssertFalse(controller.commandPaletteRegistry().windowCommands.contains { $0.category == .tmux })

        gateway.onOutput?("\u{1b}P1000p%begin 1 1 0\n%end 1 1 0\n%session-changed $0 local\n")
        let activated = await eventually { controller.hasActiveTmuxControlSession }
        XCTAssertTrue(activated)
        XCTAssertFalse(controller.commandPaletteRegistry().windowCommands.contains { $0.category == .tmux })
        XCTAssertTrue(writes.contains { $0.hasPrefix("list-windows") })

        let layout = "100x40,0,0{49x40,0,0,0,50x40,50,0,1}"
        gateway.onOutput?("%begin 1 2 0\n@0|\(layout)|\(layout)|*|1|main\n%end 1 2 0\n")
        let listedPanes = await eventually { writes.contains { $0.hasPrefix("list-panes") } }
        XCTAssertTrue(listedPanes)
        let snapshotWriteIndex = writes.count
        gateway.onOutput?("%begin 1 3 0\n@0|%0|1|editor\n@0|%1|0|logs\n%end 1 3 0\n")

        let capturedPanes = await completePaneSnapshots(
            session: gateway,
            writes: { writes },
            startingAt: snapshotWriteIndex,
            panes: [
                (paneID: "%0", currentText: "first pane history"),
                (paneID: "%1", currentText: "second pane history"),
            ],
            firstResponseNumber: 4
        )
        XCTAssertTrue(capturedPanes)

        let renderedNativeTab = await eventually { controller.nativeTmuxTabIDs == ["@0"] }
        XCTAssertTrue(renderedNativeTab)
        XCTAssertTrue(controller.hasActiveTmuxControlSession)
        XCTAssertTrue(controller.commandPaletteRegistry().windowCommands.contains { $0.category == .tmux })
        let synchronizedSize = await eventually(timeoutIterations: 200) {
            writes.contains { $0.hasPrefix("refresh-client -C") }
        }
        XCTAssertTrue(synchronizedSize, "tmux writes: \(writes)")

        gateway.onOutput?("%exit detached\n\u{1b}\\")
        let detached = await eventually { !controller.hasActiveTmuxControlSession }
        XCTAssertTrue(detached)
        XCTAssertTrue(controller.nativeTmuxTabIDs.isEmpty)

        gateway.onOutput?("\u{1b}P1000p%session-changed $1 reattached\n")
        let reattached = await eventually { controller.hasActiveTmuxControlSession }
        XCTAssertTrue(reattached)
        XCTAssertGreaterThanOrEqual(writes.filter { $0.hasPrefix("list-windows") }.count, 2)
        gateway.onOutput?("%exit detached-again\n\u{1b}\\")
        _ = await eventually { !controller.hasActiveTmuxControlSession }
    }

    @MainActor
    func testTwoWindowControllersKeepControlSessionsIsolated() async {
        func makeController(session: TmuxPaneSession) -> TerminalWindowController {
            TerminalWindowController(
                detachedPane: TerminalPaneView(frame: .zero, session: session),
                paneDragCoordinator: TerminalPaneDragCoordinator()
            )
        }
        let sessionA = makeSession()
        let sessionB = makeSession()
        let controllerA = makeController(session: sessionA)
        let controllerB = makeController(session: sessionB)

        sessionA.onOutput?("\u{1b}P1000p%session-changed $0 alpha\n")
        sessionB.onOutput?("\u{1b}P1000p%session-changed $1 beta\n")
        let bothActivated = await eventually {
            controllerA.hasActiveTmuxControlSession && controllerB.hasActiveTmuxControlSession
        }

        XCTAssertTrue(bothActivated)
        sessionA.onOutput?("%exit alpha-done\n\u{1b}\\")
        let firstExited = await eventually { !controllerA.hasActiveTmuxControlSession }
        XCTAssertTrue(firstExited)
        XCTAssertTrue(controllerB.hasActiveTmuxControlSession)
        sessionB.onOutput?("%exit beta-done\n\u{1b}\\")
        _ = await eventually { !controllerB.hasActiveTmuxControlSession }
    }

    @MainActor
    func testLocalTabsRemainLocalWhileAnotherTabHostsTmuxControlMode() async {
        var writes: [String] = []
        let gateway = TmuxPaneSession(
            writeHandler: { writes.append($0) },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let controller = TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: gateway),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        controller.newTab()

        gateway.onOutput?("\u{1b}P1000p%session-changed $0 local\n")
        let listedWindows = await eventually { writes.contains { $0.hasPrefix("list-windows") } }
        XCTAssertTrue(listedWindows)
        let layout = "80x24,0,0,0"
        gateway.onOutput?("%begin 1 1 0\n@0|\(layout)|\(layout)|*|1|main\n%end 1 1 0\n")
        let listedPanes = await eventually { writes.contains { $0.hasPrefix("list-panes") } }
        XCTAssertTrue(listedPanes)
        let snapshotWriteIndex = writes.count
        gateway.onOutput?("%begin 1 2 0\n@0|%0|1|main-pane\n%end 1 2 0\n")
        let capturedPane = await completePaneSnapshots(
            session: gateway,
            writes: { writes },
            startingAt: snapshotWriteIndex,
            panes: [(paneID: "%0", currentText: "ready")],
            firstResponseNumber: 3
        )
        XCTAssertTrue(capturedPane)
        let renderedTmuxTab = await eventually { controller.nativeTmuxTabIDs == ["@0"] }
        XCTAssertTrue(renderedTmuxTab)

        XCTAssertFalse(controller.commandPaletteRegistry().windowCommands.contains { $0.category == .tmux })
        let resizedLayout = "90x30,0,0,0"
        gateway.onOutput?(
            "%layout-change @0 \(resizedLayout) \(resizedLayout) *\n"
                + "%window-renamed @0 background-update\n"
        )
        let appliedBackgroundUpdate = await eventually {
            controller.nativeTmuxTabLabels["@0"] == "background-update"
        }
        XCTAssertTrue(appliedBackgroundUpdate)
        XCTAssertFalse(controller.commandPaletteRegistry().windowCommands.contains { $0.category == .tmux })
        let tmuxMutationCount = writes.filter {
            $0.hasPrefix("split-window") || $0.hasPrefix("kill-pane")
                || $0.hasPrefix("kill-window") || $0.hasPrefix("new-window")
        }.count

        controller.splitVertically()
        controller.closeCurrentPane()
        controller.newTab()
        controller.closeCurrentTab()

        XCTAssertEqual(
            writes.filter {
                $0.hasPrefix("split-window") || $0.hasPrefix("kill-pane")
                    || $0.hasPrefix("kill-window") || $0.hasPrefix("new-window")
            }.count,
            tmuxMutationCount
        )
        gateway.onOutput?("%exit detached\n\u{1b}\\")
        _ = await eventually { !controller.hasActiveTmuxControlSession }
    }

    @MainActor
    func testMultipleControlSessionsPreserveTabGroupsAndRouteDuplicateWindowIDsIndependently() async {
        var writesA: [String] = []
        var writesB: [String] = []
        let gatewayA = TmuxPaneSession(
            writeHandler: { writesA.append($0) },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let gatewayB = TmuxPaneSession(
            writeHandler: { writesB.append($0) },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let controller = TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: gatewayA),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        controller.newTab()
        controller.attachDraggedPaneAsTab(TerminalPaneView(frame: .zero, session: gatewayB))
        controller.newTab()
        let originalTabOrder = controller.tabIdentifiersInOrder
        XCTAssertEqual(originalTabOrder.count, 4)

        let attachedA = await completeSnapshot(
            session: gatewayA,
            writes: { writesA },
            sessionID: "$0",
            sessionName: "alpha",
            windows: [
                (windowID: "@0", paneID: "%0", name: "alpha-main"),
                (windowID: "@1", paneID: "%1", name: "alpha-tools"),
            ]
        )
        XCTAssertTrue(attachedA)
        let attachedB = await completeSnapshot(
            session: gatewayB,
            writes: { writesB },
            sessionID: "$1",
            sessionName: "beta",
            windows: [(windowID: "@0", paneID: "%0", name: "beta-main")]
        )
        XCTAssertTrue(attachedB)
        let bothAttached = await eventually { controller.activeTmuxControlSessionCount == 2 }
        XCTAssertTrue(bothAttached)
        XCTAssertEqual(controller.nativeTmuxTabIDs, ["@0", "@1", "@0"])

        let scopedIDs = controller.nativeTmuxScopedTabIDs
        XCTAssertEqual(scopedIDs.count, 3)
        XCTAssertEqual(Set(scopedIDs).count, 3)
        XCTAssertEqual(
            controller.tabIdentifiersInOrder,
            [scopedIDs[0], scopedIDs[1], originalTabOrder[1], scopedIDs[2], originalTabOrder[3]]
        )

        controller.selectPreviousTab()
        controller.splitVertically()
        let betaReceivedSplit = await driveResponses(
            session: gatewayB,
            until: { writesB.contains { $0.hasPrefix("split-window") } }
        )
        XCTAssertTrue(betaReceivedSplit)
        XCTAssertFalse(writesA.contains { $0.hasPrefix("split-window") })

        controller.detachTmuxClient()
        let betaReceivedDetach = await driveResponses(
            session: gatewayB,
            until: { writesB.contains { $0.hasPrefix("detach-client") } }
        )
        XCTAssertTrue(betaReceivedDetach)
        XCTAssertFalse(writesA.contains { $0.hasPrefix("detach-client") })
        gatewayB.onOutput?("%exit beta-detached\n\u{1b}\\")
        let betaDetached = await eventually { controller.activeTmuxControlSessionCount == 1 }
        XCTAssertTrue(betaDetached)
        XCTAssertEqual(controller.nativeTmuxTabIDs, ["@0", "@1"])
        XCTAssertEqual(
            controller.tabIdentifiersInOrder,
            [scopedIDs[0], scopedIDs[1], originalTabOrder[1], originalTabOrder[2], originalTabOrder[3]]
        )

        controller.selectPreviousTab()
        controller.selectPreviousTab()
        controller.newTab()
        let alphaReceivedNewWindow = await driveResponses(
            session: gatewayA,
            until: { writesA.contains { $0.hasPrefix("new-window") } }
        )
        XCTAssertTrue(alphaReceivedNewWindow)
        XCTAssertFalse(writesB.contains { $0.hasPrefix("new-window") })

        controller.detachTmuxClient()
        let alphaReceivedDetach = await driveResponses(
            session: gatewayA,
            until: { writesA.contains { $0.hasPrefix("detach-client") } }
        )
        XCTAssertTrue(alphaReceivedDetach)
        XCTAssertEqual(writesB.filter { $0.hasPrefix("detach-client") }.count, 1)
        gatewayA.onOutput?("%exit alpha-detached\n\u{1b}\\")
        let alphaDetached = await eventually { controller.activeTmuxControlSessionCount == 0 }
        XCTAssertTrue(alphaDetached)
        XCTAssertEqual(controller.nativeTmuxTabIDs, [])
        XCTAssertEqual(controller.tabIdentifiersInOrder, originalTabOrder)
    }

    @MainActor
    func testLiveSessionChangeClearsOldNativeTopologyAndRejectsStalePaneMutations() async throws {
        var writes: [String] = []
        let gateway = TmuxPaneSession(
            writeHandler: { writes.append($0) },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let gatewayPane = TerminalPaneView(frame: .zero, session: gateway)
        let controller = TerminalWindowController(
            detachedPane: gatewayPane,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )

        let attachedAlpha = await completeSnapshot(
            session: gateway,
            writes: { writes },
            sessionID: "$0",
            sessionName: "alpha",
            windows: [(windowID: "@0", paneID: "%0", name: "alpha-main")]
        )
        XCTAssertTrue(attachedAlpha)
        let renderedAlpha = await eventually { controller.nativeTmuxTabIDs == ["@0"] }
        XCTAssertTrue(renderedAlpha)
        let stalePane = try XCTUnwrap(controller.selectedTerminalPanesInLayoutOrder.first)

        NotificationCenter.default.post(
            name: TerminalSurfaceView.titleDidChangeNotification,
            object: stalePane.terminalSurface,
            userInfo: [TerminalSurfaceView.titleNotificationKey: "pane-osc-title"]
        )
        XCTAssertEqual(controller.nativeTmuxTabLabels["@0"], "alpha-main")

        let listWindowCount = writes.filter { $0.hasPrefix("list-windows") }.count
        gateway.onOutput?("%session-changed $1 beta\n")
        let resetImmediately = await eventually {
            controller.nativeTmuxTabIDs.isEmpty
                && writes.filter { $0.hasPrefix("list-windows") }.count > listWindowCount
        }
        XCTAssertTrue(resetImmediately)
        XCTAssertTrue(controller.hasActiveTmuxControlSession)
        XCTAssertNil(stalePane.closeRequested)

        let staleSendCount = writes.filter { $0.hasPrefix("send-keys") }.count
        stalePane.sendText("must-not-reach-beta")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(writes.filter { $0.hasPrefix("send-keys") }.count, staleSendCount)

        let attachedBeta = await completeSnapshotAfterSessionChange(
            session: gateway,
            writes: { writes },
            windows: [(windowID: "@0", paneID: "%0", name: "beta-main")],
            responseEpoch: 17
        )
        XCTAssertTrue(attachedBeta)
        let renderedBeta = await eventually {
            controller.nativeTmuxTabIDs == ["@0"]
                && controller.nativeTmuxTabLabels["@0"] == "beta-main"
        }
        XCTAssertTrue(renderedBeta)
        let betaPane = try XCTUnwrap(controller.selectedTerminalPanesInLayoutOrder.first)
        XCTAssertFalse(betaPane === stalePane)
        XCTAssertEqual(betaPane.displayTitle, "beta-main-pane")

        gateway.onOutput?("%subscription-changed kurotty-pane-title $1 @0 0 %0 : live | title: 한글\n")
        let liveTitleApplied = await eventually { betaPane.displayTitle == "live | title: 한글" }
        XCTAssertTrue(liveTitleApplied)
        NotificationCenter.default.post(
            name: TerminalSurfaceView.titleDidChangeNotification,
            object: betaPane.terminalSurface,
            userInfo: [TerminalSurfaceView.titleNotificationKey: "pane-osc-must-not-win"]
        )
        XCTAssertEqual(betaPane.displayTitle, "live | title: 한글")

        gateway.onOutput?("%exit detached\n\u{1b}\\")
        _ = await eventually { !controller.hasActiveTmuxControlSession }
    }

    @MainActor
    func testSplitGatewayPlaceholderKeepsSiblingAndRestoresExactSlotAfterSiblingChanges() async throws {
        var writes: [String] = []
        let gateway = TmuxPaneSession(
            writeHandler: { writes.append($0) },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let gatewayPane = TerminalPaneView(frame: .zero, session: gateway)
        let siblingPane = TerminalPaneView(frame: .zero, session: makeSession())
        let controller = TerminalWindowController(
            detachedPane: gatewayPane,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        let hostSplit = try XCTUnwrap(controller.selectedSplitViewForTesting)
        hostSplit.appendDetachedPaneAsTabRoot(siblingPane)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        hostSplit.layoutSubtreeIfNeeded()
        if hostSplit.bounds.width > 0 {
            hostSplit.setPosition(hostSplit.bounds.width * 0.35, ofDividerAt: 0)
        }
        gatewayPane.focusTerminal()
        let activationProportions = hostSplit.layoutSlotProportions
        let hostOrder = controller.tabIdentifiersInOrder

        let attached = await completeSnapshot(
            session: gateway,
            writes: { writes },
            sessionID: "$0",
            sessionName: "split-host",
            windows: [(windowID: "@0", paneID: "%0", name: "remote")]
        )
        XCTAssertTrue(attached)
        let rendered = await eventually { controller.nativeTmuxTabIDs == ["@0"] }
        XCTAssertTrue(rendered)
        XCTAssertTrue(controller.commandPaletteRegistry().windowCommands.contains { $0.category == .tmux })
        controller.selectPreviousTab()
        XCTAssertEqual(controller.selectedProjectionPlaceholderCount, 1)
        XCTAssertEqual(controller.selectedLayoutSlotCount, 2)
        XCTAssertEqual(controller.selectedTerminalPanesInLayoutOrder.count, 1)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder[0] === siblingPane)
        assertProportions(controller.selectedLayoutSlotProportions, equalTo: activationProportions)

        let orderWithProjection = controller.tabIdentifiersInOrder
        controller.closeCurrentTab()
        XCTAssertEqual(controller.tabIdentifiersInOrder, orderWithProjection, "active projection host must not close")

        siblingPane.closeRequested?(siblingPane)
        XCTAssertEqual(controller.selectedProjectionPlaceholderCount, 1)
        XCTAssertEqual(controller.selectedLayoutSlotCount, 1)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder.isEmpty)

        controller.splitHorizontally()
        XCTAssertEqual(controller.selectedProjectionPlaceholderCount, 1)
        XCTAssertEqual(controller.selectedLayoutSlotCount, 2)
        XCTAssertFalse(hostSplit.isVertical)
        let replacementSibling = try XCTUnwrap(controller.selectedTerminalPanesInLayoutOrder.first)
        let proportionsBeforeRestore = controller.selectedLayoutSlotProportions

        controller.selectNextTab()
        controller.detachTmuxClient()
        let sentDetach = await driveResponses(
            session: gateway,
            until: { writes.contains { $0.hasPrefix("detach-client") } }
        )
        XCTAssertTrue(sentDetach)
        gateway.onOutput?("%exit detached\n\u{1b}\\")
        let restored = await eventually { !controller.hasActiveTmuxControlSession }
        XCTAssertTrue(restored)

        XCTAssertEqual(controller.nativeTmuxTabIDs, [])
        XCTAssertEqual(controller.tabIdentifiersInOrder, hostOrder)
        XCTAssertEqual(controller.selectedProjectionPlaceholderCount, 0)
        XCTAssertEqual(controller.selectedLayoutSlotCount, 2)
        XCTAssertEqual(controller.selectedTerminalPanesInLayoutOrder.count, 2)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder[0] === gatewayPane)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder[1] === replacementSibling)
        assertProportions(controller.selectedLayoutSlotProportions, equalTo: proportionsBeforeRestore)
    }

    @MainActor
    func testSiblingControlClientsRouteDuplicateIDsAndRestoreInReverseActivationOrder() async throws {
        var writesA: [String] = []
        var writesB: [String] = []
        let gatewayA = TmuxPaneSession(
            writeHandler: { writesA.append($0) },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let gatewayB = TmuxPaneSession(
            writeHandler: { writesB.append($0) },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let paneA = TerminalPaneView(frame: .zero, session: gatewayA)
        let paneB = TerminalPaneView(frame: .zero, session: gatewayB)
        let controller = TerminalWindowController(
            detachedPane: paneA,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        let hostSplit = try XCTUnwrap(controller.selectedSplitViewForTesting)
        hostSplit.appendDetachedPaneAsTabRoot(paneB)
        paneA.focusTerminal()
        let originalHostOrder = controller.tabIdentifiersInOrder

        let attachedA = await completeSnapshot(
            session: gatewayA,
            writes: { writesA },
            sessionID: "$0",
            sessionName: "alpha",
            windows: [(windowID: "@0", paneID: "%0", name: "alpha-main")]
        )
        XCTAssertTrue(attachedA)
        let attachedB = await completeSnapshot(
            session: gatewayB,
            writes: { writesB },
            sessionID: "$1",
            sessionName: "beta",
            windows: [(windowID: "@0", paneID: "%0", name: "beta-main")]
        )
        XCTAssertTrue(attachedB)
        let bothAttached = await eventually { controller.activeTmuxControlSessionCount == 2 }
        XCTAssertTrue(bothAttached)
        XCTAssertEqual(controller.nativeTmuxTabIDs, ["@0", "@0"])
        controller.selectPreviousTab()
        XCTAssertEqual(controller.selectedProjectionPlaceholderCount, 2)
        XCTAssertEqual(controller.selectedLayoutSlotCount, 2)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder.isEmpty)

        let orderBeforeBlockedClose = controller.tabIdentifiersInOrder
        controller.closeCurrentTab()
        XCTAssertEqual(controller.tabIdentifiersInOrder, orderBeforeBlockedClose)

        controller.selectNextTab()
        controller.splitVertically()
        let routedSplitA = await driveResponses(
            session: gatewayA,
            until: { writesA.contains { $0.hasPrefix("split-window") } }
        )
        XCTAssertTrue(routedSplitA)
        XCTAssertFalse(writesB.contains { $0.hasPrefix("split-window") })

        controller.selectNextTab()
        controller.splitHorizontally()
        let routedSplitB = await driveResponses(
            session: gatewayB,
            until: { writesB.contains { $0.hasPrefix("split-window") } }
        )
        XCTAssertTrue(routedSplitB)
        XCTAssertEqual(writesA.filter { $0.hasPrefix("split-window") }.count, 1)

        controller.selectPreviousTab()
        let hostSelectionMutationCounts = (
            writesA.filter { $0.hasPrefix("select-window") }.count,
            writesB.filter { $0.hasPrefix("select-window") }.count
        )
        controller.selectPreviousTab()
        XCTAssertEqual(writesA.filter { $0.hasPrefix("select-window") }.count, hostSelectionMutationCounts.0)
        XCTAssertEqual(writesB.filter { $0.hasPrefix("select-window") }.count, hostSelectionMutationCounts.1)

        controller.selectNextTab()
        controller.selectNextTab()
        controller.detachTmuxClient()
        let detachedBCommand = await driveResponses(
            session: gatewayB,
            until: { writesB.contains { $0.hasPrefix("detach-client") } }
        )
        XCTAssertTrue(detachedBCommand)
        XCTAssertFalse(writesA.contains { $0.hasPrefix("detach-client") })
        gatewayB.onOutput?("%exit beta-detached\n\u{1b}\\")
        let restoredB = await eventually { controller.activeTmuxControlSessionCount == 1 }
        XCTAssertTrue(restoredB)
        XCTAssertEqual(controller.nativeTmuxTabIDs, ["@0"])
        XCTAssertEqual(controller.selectedProjectionPlaceholderCount, 1)
        XCTAssertEqual(controller.selectedTerminalPanesInLayoutOrder.count, 1)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder[0] === paneB)

        controller.selectNextTab()
        controller.detachTmuxClient()
        let detachedACommand = await driveResponses(
            session: gatewayA,
            until: { writesA.contains { $0.hasPrefix("detach-client") } }
        )
        XCTAssertTrue(detachedACommand)
        gatewayA.onOutput?("%exit alpha-detached\n\u{1b}\\")
        let restoredA = await eventually { controller.activeTmuxControlSessionCount == 0 }
        XCTAssertTrue(restoredA)
        XCTAssertEqual(controller.tabIdentifiersInOrder, originalHostOrder)
        XCTAssertEqual(controller.selectedProjectionPlaceholderCount, 0)
        XCTAssertEqual(controller.selectedTerminalPanesInLayoutOrder.count, 2)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder[0] === paneA)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder[1] === paneB)

        gatewayA.onOutput?("%exit duplicate-alpha\n\u{1b}\\")
        gatewayB.onOutput?("%exit duplicate-beta\n\u{1b}\\")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.selectedTerminalPanesInLayoutOrder.count, 2)
    }

    @MainActor
    func testSiblingControlClientFailureRestoresOnlyItsPaneBeforeOtherDetach() async throws {
        var writesA: [String] = []
        var writesB: [String] = []
        let gatewayA = TmuxPaneSession(
            writeHandler: { writesA.append($0) },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let gatewayB = TmuxPaneSession(
            writeHandler: { writesB.append($0) },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let paneA = TerminalPaneView(frame: .zero, session: gatewayA)
        let paneB = TerminalPaneView(frame: .zero, session: gatewayB)
        let controller = TerminalWindowController(
            detachedPane: paneA,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        let hostSplit = try XCTUnwrap(controller.selectedSplitViewForTesting)
        hostSplit.appendDetachedPaneAsTabRoot(paneB)

        gatewayA.onOutput?("\u{1b}P1000p%session-changed $0 alpha\n")
        gatewayB.onOutput?("\u{1b}P1000p%session-changed $1 beta\n")
        let bothActivated = await eventually { controller.activeTmuxControlSessionCount == 2 }
        XCTAssertTrue(bothActivated)
        XCTAssertEqual(controller.selectedProjectionPlaceholderCount, 2)

        gatewayA.onOutput?("%exit server exited unexpectedly\n\u{1b}\\")
        let restoredA = await eventually { controller.activeTmuxControlSessionCount == 1 }
        XCTAssertTrue(restoredA)
        XCTAssertEqual(controller.selectedProjectionPlaceholderCount, 1)
        XCTAssertEqual(controller.selectedTerminalPanesInLayoutOrder.count, 1)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder[0] === paneA)

        gatewayB.onOutput?("%exit detached\n\u{1b}\\")
        let restoredB = await eventually { controller.activeTmuxControlSessionCount == 0 }
        XCTAssertTrue(restoredB)
        XCTAssertEqual(controller.selectedProjectionPlaceholderCount, 0)
        XCTAssertEqual(controller.selectedTerminalPanesInLayoutOrder.count, 2)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder[0] === paneA)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder[1] === paneB)
    }

    @MainActor
    private func completeSnapshot(
        session: TmuxPaneSession,
        writes: @escaping @MainActor () -> [String],
        sessionID: String,
        sessionName: String,
        windows: [(windowID: String, paneID: String, name: String)]
    ) async -> Bool {
        session.onOutput?("\u{1b}P1000p%session-changed \(sessionID) \(sessionName)\n")
        guard await eventually({ writes().contains { $0.hasPrefix("list-windows") } }) else {
            return false
        }
        let windowLines = windows.enumerated().map { index, window in
            let flags = index == 0 ? "*" : "-"
            let active = index == 0 ? "1" : "0"
            let paneNumber = window.paneID.dropFirst()
            let layout = "80x24,0,0,\(paneNumber)"
            return "\(window.windowID)|\(layout)|\(layout)|\(flags)|\(active)|\(window.name)"
        }.joined(separator: "\n")
        session.onOutput?("%begin 7 1 0\n\(windowLines)\n%end 7 1 0\n")
        guard await eventually({ writes().contains { $0.hasPrefix("list-panes") } }) else {
            return false
        }
        let paneLines = windows.enumerated().map { index, window in
            "\(window.windowID)|\(window.paneID)|\(index == 0 ? 1 : 0)|\(window.name)-pane"
        }.joined(separator: "\n")
        let snapshotWriteIndex = writes().count
        session.onOutput?("%begin 7 2 0\n\(paneLines)\n%end 7 2 0\n")
        return await completePaneSnapshots(
            session: session,
            writes: writes,
            startingAt: snapshotWriteIndex,
            panes: windows.map { (paneID: $0.paneID, currentText: "\($0.name) history") },
            firstResponseNumber: 3
        )
    }

    @MainActor
    private func completeSnapshotAfterSessionChange(
        session: TmuxPaneSession,
        writes: @escaping @MainActor () -> [String],
        windows: [(windowID: String, paneID: String, name: String)],
        responseEpoch: Int
    ) async -> Bool {
        let listPanesCount = writes().filter { $0.hasPrefix("list-panes") }.count
        let windowLines = windows.enumerated().map { index, window in
            let flags = index == 0 ? "*" : "-"
            let active = index == 0 ? "1" : "0"
            let paneNumber = window.paneID.dropFirst()
            let layout = "80x24,0,0,\(paneNumber)"
            return "\(window.windowID)|\(layout)|\(layout)|\(flags)|\(active)|\(window.name)"
        }.joined(separator: "\n")
        session.onOutput?("%begin \(responseEpoch) 1 0\n\(windowLines)\n%end \(responseEpoch) 1 0\n")
        guard await eventually({
            writes().filter { $0.hasPrefix("list-panes") }.count > listPanesCount
        }) else {
            return false
        }

        let paneLines = windows.enumerated().map { index, window in
            "\(window.windowID)|\(window.paneID)|\(index == 0 ? 1 : 0)|\(window.name)-pane"
        }.joined(separator: "\n")
        let snapshotWriteIndex = writes().count
        session.onOutput?("%begin \(responseEpoch) 2 0\n\(paneLines)\n%end \(responseEpoch) 2 0\n")
        return await completePaneSnapshots(
            session: session,
            writes: writes,
            startingAt: snapshotWriteIndex,
            panes: windows.map { (paneID: $0.paneID, currentText: "\($0.name) history") },
            firstResponseNumber: 3
        )
    }

    @MainActor
    private func completePaneSnapshots(
        session: TmuxPaneSession,
        writes: @escaping @MainActor () -> [String],
        startingAt initialWriteIndex: Int,
        panes: [(paneID: String, currentText: String)],
        firstResponseNumber: Int
    ) async -> Bool {
        var writeIndex = initialWriteIndex
        var responseNumber = firstResponseNumber

        for pane in panes {
            let stages: [(matches: (String) -> Bool, responseLine: String?)] = [
                ({ command in
                    command.hasPrefix("display-message -p -t '\(pane.paneID)'")
                        && command.contains("#{session_attached}")
                }, "1"),
                ({ command in
                    command.hasPrefix("refresh-client -A '")
                        && command.contains("\(pane.paneID):off")
                }, nil),
                ({ command in
                    command.hasPrefix("capture-pane -p -e")
                        && !command.contains(" -a ")
                        && !command.contains(" -P ")
                }, pane.currentText),
                ({ command in
                    command.hasPrefix("capture-pane -p -e") && command.contains(" -a ")
                }, nil),
                ({ command in
                    command.hasPrefix("list-panes -t '\(pane.paneID)' ")
                        && command.contains(" -F ")
                }, paneStateResponse(paneID: pane.paneID)),
                ({ command in
                    command.hasPrefix("capture-pane -p -P -C -t '\(pane.paneID)'")
                }, nil),
                ({ command in
                    command.hasPrefix("refresh-client -A '")
                        && command.contains("\(pane.paneID):on")
                }, nil),
            ]

            for stage in stages {
                let expectedWriteIndex = writeIndex
                guard await eventually({ writes().count > expectedWriteIndex }) else {
                    return false
                }
                let command = writes()[expectedWriteIndex]
                guard stage.matches(command) else {
                    XCTFail("unexpected tmux snapshot command: \(command)")
                    return false
                }
                let body = stage.responseLine.map { "\($0)\n" } ?? ""
                session.onOutput?(
                    "%begin 9 \(responseNumber) 0\n"
                        + body
                        + "%end 9 \(responseNumber) 0\n"
                )
                writeIndex = expectedWriteIndex + 1
                responseNumber += 1
            }
        }

        for _ in 0..<16 {
            let expectedWriteIndex = writeIndex
            guard await eventually({ writes().count > expectedWriteIndex }) else { return false }
            let command = writes()[expectedWriteIndex]
            if command.hasPrefix("refresh-client -B ") {
                guard command.contains("kurotty-window-index:@*"),
                      command.contains("kurotty-pane-title:%*")
                else {
                    XCTFail("unexpected tmux subscription command: \(command)")
                    return false
                }
                session.onOutput?(
                    "%begin 9 \(responseNumber) 0\n"
                        + "%end 9 \(responseNumber) 0\n"
                )
                return true
            }
            guard command.hasPrefix("refresh-client -C ") || command.hasPrefix("resize-pane ") else {
                XCTFail("unexpected command before tmux subscriptions: \(command)")
                return false
            }
            session.onOutput?(
                "%begin 9 \(responseNumber) 0\n"
                    + "%end 9 \(responseNumber) 0\n"
            )
            writeIndex = expectedWriteIndex + 1
            responseNumber += 1
        }
        XCTFail("tmux subscription registration was starved by resize commands")
        return false
    }

    private func paneStateResponse(paneID: String) -> String {
        [
            "pane_id=\(paneID)",
            "pane_width=80",
            "pane_height=24",
            "alternate_on=0",
            "alternate_saved_x=0",
            "alternate_saved_y=0",
            "cursor_x=0",
            "cursor_y=0",
            "scroll_region_upper=0",
            "scroll_region_lower=23",
            "pane_tabs=8,16,24",
            "cursor_flag=1",
            "insert_flag=0",
            "origin_flag=0",
            "keypad_cursor_flag=0",
            "keypad_flag=0",
            "wrap_flag=1",
            "mouse_standard_flag=0",
            "mouse_button_flag=0",
            "mouse_any_flag=0",
            "mouse_utf8_flag=0",
            "mouse_sgr_flag=0",
            "bracket_paste_flag=0",
            "pane_key_mode=VT10x",
            "extended_keys_format=xterm",
            "session_attached=1",
        ].joined(separator: "\t")
    }

    @MainActor
    private func driveResponses(
        session: TmuxPaneSession,
        until condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for number in 100..<140 {
            if condition() { return true }
            session.onOutput?("%begin 8 \(number) 0\n%end 8 \(number) 0\n")
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeSession() -> TmuxPaneSession {
        TmuxPaneSession(writeHandler: { _ in }, resizeHandler: { _, _ in }, stopHandler: {})
    }

    private func assertProportions(
        _ actual: [Double]?,
        equalTo expected: [Double]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual, let expected else {
            XCTAssertEqual(actual == nil, expected == nil, file: file, line: line)
            return
        }
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(actualValue, expectedValue, accuracy: 0.02, file: file, line: line)
        }
    }

    @MainActor
    private func eventually(
        timeoutIterations: Int = 100,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<timeoutIterations {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
