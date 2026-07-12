import Foundation
import XCTest
@testable import KurottyApp

final class TmuxControlCoreTests: XCTestCase {
    private final class WriteRecorder {
        var commands: [String] = []
    }

    func testParserIsChunkSafeAcrossMarkersLinesAndOctalOutput() {
        var parser = TmuxControlParser()
        var events: [TmuxControlEvent] = []
        let fixture = Data("noise\u{1b}P1000p%window-add @1\r\n%output %2 hello\\040world\\012\n\u{1b}\\tail".utf8)
        for byte in fixture { events += parser.consume(Data([byte])) }
        XCTAssertEqual(events, [
            .entered,
            .windowAdded(id: "@1"),
            .output(paneID: "%2", data: Data("hello world\n".utf8)),
            .exited(reason: nil),
        ])
        XCTAssertFalse(parser.isInControlMode)
        XCTAssertEqual(parser.takePassthroughData(), Data("noisetail".utf8))
    }

    func testParserPreservesOrdinaryTerminalBytesWhileMatchingPartialMarker() {
        var parser = TmuxControlParser()
        XCTAssertTrue(parser.consume(Data("ordinary\u{1b}P10".utf8)).isEmpty)
        XCTAssertEqual(parser.takePassthroughData(), Data("ordinary".utf8))
        XCTAssertTrue(parser.consume(Data("not-a-marker".utf8)).isEmpty)
        XCTAssertEqual(parser.takePassthroughData(), Data("\u{1b}P10not-a-marker".utf8))
    }

    func testParserAbortsControlModeAndRestoresUnexpectedPlainBytes() {
        var parser = TmuxControlParser()
        let events = parser.consume(Data("\u{1b}P1000pshell output\nprompt$ ".utf8))
        XCTAssertEqual(events, [
            .entered,
            .locallyAborted(reason: TmuxControlParser.unexpectedExitReason),
        ])
        XCTAssertEqual(parser.takePassthroughData(), Data("shell output\nprompt$ ".utf8))
        XCTAssertFalse(parser.isInControlMode)
    }

    func testParserBoundsAnUnterminatedControlLineAndAbortsLocally() {
        var parser = TmuxControlParser(maxControlLineBytes: 8)
        let events = parser.consume(Data("\u{1b}P1000p%123456789".utf8))
        XCTAssertEqual(events, [
            .entered,
            .malformed(line: "tmux control line exceeded 8 bytes"),
            .locallyAborted(reason: "tmux control line exceeded 8 bytes"),
        ])
        XCTAssertFalse(parser.isInControlMode)
    }

    func testParserReturnsPlainTrailingBytesBeforeSTAndEmitsOneExit() {
        var parser = TmuxControlParser()
        let events = parser.consume(Data("\u{1b}P1000pprompt$ \u{1b}\\".utf8))
        XCTAssertEqual(events, [
            .entered,
            .exited(reason: TmuxControlParser.unexpectedExitReason),
        ])
        XCTAssertEqual(parser.takePassthroughData(), Data("prompt$ ".utf8))
    }

    func testParserTreatsPercentLinesInsideMatchingResponseBlockAsPayload() {
        var parser = TmuxControlParser()
        let fixture = """
        \u{1b}P1000p%begin 1710000000 7 1
        %window-add @payload
        %end 1710000000 7 1
        %session-changed $0 work
        %session-window-changed $0 @2
        %window-renamed @2 editor
        %window-pane-changed @2 %4

        """
        XCTAssertEqual(parser.consume(Data(fixture.utf8)), [
            .entered,
            .blockBegan(timestamp: 1_710_000_000, number: 7, flags: 1),
            .responseLine("%window-add @payload"),
            .blockEnded(timestamp: 1_710_000_000, number: 7, flags: 1),
            .sessionChanged(id: "$0", name: "work"),
            .activeWindowChanged(sessionID: "$0", windowID: "@2"),
            .windowRenamed(id: "@2", name: "editor"),
            .activePaneChanged(windowID: "@2", paneID: "%4"),
        ])
    }

    func testParserOnlyAcceptsMatchingResponseBlockTerminator() {
        var parser = TmuxControlParser()
        let fixture = """
        \u{1b}P1000p%begin 100 9 1
        %end 1 2 3
        body
        %end 100 9 1

        """
        XCTAssertEqual(parser.consume(Data(fixture.utf8)), [
            .entered,
            .blockBegan(timestamp: 100, number: 9, flags: 1),
            .responseLine("%end 1 2 3"),
            .responseLine("body"),
            .blockEnded(timestamp: 100, number: 9, flags: 1),
        ])
    }

    func testParserRecognizesLayoutSessionAndPaneNotifications() throws {
        var parser = TmuxControlParser()
        let canonicalText = "8205,80x24,0,0{40x24,0,0,1,39x24,41,0,2}"
        let visibleText = "b260,80x24,0,0,2"
        let fixture = """
        \u{1b}P1000p%layout-change @2 \(canonicalText) \(visibleText) *Z
        %session-renamed $0 renamed work
        %sessions-changed
        %client-session-changed /dev/ttys001 $0 renamed work
        %pane-focus-in %2
        %pane-focus-out %2
        %config-error bad option

        """
        XCTAssertEqual(parser.consume(Data(fixture.utf8)), [
            .entered,
            .layoutChanged(
                windowID: "@2",
                layout: try TmuxLayoutParser.parse(canonicalText),
                visibleLayout: try TmuxLayoutParser.parse(visibleText),
                flags: "*Z"
            ),
            .sessionRenamed(id: "$0", name: "renamed work"),
            .sessionsChanged,
            .clientSessionChanged(clientID: "/dev/ttys001", sessionID: "$0", name: "renamed work"),
            .paneFocusChanged(id: "%2", isFocused: true),
            .paneFocusChanged(id: "%2", isFocused: false),
            .configurationError(message: "bad option"),
        ])
    }

    func testExitNotificationAndDCSMarkerProduceOneExitEvent() {
        var parser = TmuxControlParser()
        let events = parser.consume(Data("\u{1b}P1000p%exit detached from session\n\u{1b}\\tail".utf8))
        XCTAssertEqual(events, [.entered, .exited(reason: "detached from session")])
        XCTAssertEqual(parser.takePassthroughData(), Data("tail".utf8))
        XCTAssertFalse(parser.isInControlMode)
    }

    func testMalformedNotificationsAndEscapesFailSafely() {
        var parser = TmuxControlParser()
        let events = parser.consume(Data("\u{1b}P1000p%layout-change @1 nonsense\n%output\n".utf8))
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.first, .entered)
        guard case .malformed = events[1], case .malformed = events[2] else {
            return XCTFail("invalid protocol lines should be surfaced without trapping")
        }
        XCTAssertNil(TmuxControlParser.decodeEscapedBytes("\\777"))
        XCTAssertNil(TmuxControlParser.decodeEscapedBytes("\\q"))
    }

    func testExtendedOutputDropsAgeMetadata() {
        var parser = TmuxControlParser()
        let events = parser.consume(Data("\u{1b}P1000p%extended-output %3 12 future : delayed\\040text\n".utf8))
        XCTAssertEqual(events, [
            .entered,
            .output(paneID: "%3", data: Data("delayed text".utf8)),
        ])
    }

    func testLayoutParserBuildsNestedNativeSplitTree() throws {
        let layout = try TmuxLayoutParser.parse(
            "b25d,120x40,0,0{60x40,0,0,1,59x40,61,0[59x20,61,0,2,59x19,61,21,3]}"
        )
        XCTAssertEqual(layout.paneIDs, ["%1", "%2", "%3"])
        guard case let .split(axis, rect, children) = layout else { return XCTFail("expected root split") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(rect, .init(width: 120, height: 40, x: 0, y: 0))
        XCTAssertEqual(children.count, 2)
        guard case let .split(nestedAxis, _, nestedChildren) = children[1] else {
            return XCTFail("expected nested split")
        }
        XCTAssertEqual(nestedAxis, .vertical)
        XCTAssertEqual(nestedChildren.count, 2)
    }

    func testLayoutParserRejectsTruncatedOrSingleChildSplits() {
        XCTAssertThrowsError(try TmuxLayoutParser.parse("80x24,0,0{80x24,0,0,1}"))
        XCTAssertThrowsError(try TmuxLayoutParser.parse("80x24,0,0[40x24,0,0,1"))
    }

    func testViewerUsesVisibleZoomLayoutAndTracksActivePanePerWindow() throws {
        let canonical = try TmuxLayoutParser.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        let visible = try TmuxLayoutParser.parse("80x24,0,0,2")
        var state = TmuxViewerState()
        state.apply([
            .entered,
            .sessionChanged(id: "$0", name: "work"),
            .windowAdded(id: "@1"),
            .windowRenamed(id: "@1", name: "shell"),
            .layoutChanged(windowID: "@1", layout: canonical, visibleLayout: visible, flags: "*Z"),
            .activeWindowChanged(sessionID: "$0", windowID: "@1"),
            .activePaneChanged(windowID: "@1", paneID: "%2"),
            .output(paneID: "%2", data: Data("abc".utf8)),
        ])
        XCTAssertEqual(state.windows["@1"]?.layout, visible)
        XCTAssertEqual(state.windows["@1"]?.canonicalLayout, canonical)
        XCTAssertTrue(state.windows["@1"]?.isZoomed == true)
        XCTAssertEqual(state.windows["@1"]?.activePaneID, "%2")
        XCTAssertEqual(state.focusedPaneID, "%2")
        XCTAssertEqual(state.panes["%2"]?.output, Data("abc".utf8))
    }

    func testViewerPrunesPaneHistoryRemovedFromCanonicalLayout() throws {
        let twoPanes = try TmuxLayoutParser.parse("80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        let onePane = try TmuxLayoutParser.parse("80x24,0,0,1")
        var state = TmuxViewerState()
        state.apply(.layoutChanged(windowID: "@1", layout: twoPanes, visibleLayout: twoPanes, flags: "*"))
        state.apply(.output(paneID: "%2", data: Data("history".utf8)))
        XCTAssertNotNil(state.panes["%2"])
        state.apply(.layoutChanged(windowID: "@1", layout: onePane, visibleLayout: onePane, flags: "*"))
        XCTAssertNil(state.panes["%2"])
    }

    func testViewerIgnoresForeignSessionAndUnknownWindowFocusNotifications() throws {
        let layout = try TmuxLayoutParser.parse("80x24,0,0,1")
        var state = TmuxViewerState()
        state.apply(.sessionChanged(id: "$0", name: "work"))
        state.apply(.layoutChanged(windowID: "@1", layout: layout, visibleLayout: layout, flags: "*"))
        state.apply(.activeWindowChanged(sessionID: "$1", windowID: "@9"))
        state.apply(.activePaneChanged(windowID: "@9", paneID: "%9"))
        XCTAssertNil(state.activeWindowID)
        XCTAssertNil(state.windows["@9"])
        XCTAssertNil(state.panes["%9"])
    }

    func testCommandEncoderProducesControlCommandsAndAdvancedLayoutCommands() {
        XCTAssertEqual(
            TmuxCommandEncoder.listWindows(sessionID: "$0"),
            Data("list-windows -O index -t '$0' -F \"#{window_id}|#{window_layout}|#{window_visible_layout}|#{window_flags}|#{window_active}|#{window_name}\"\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.listPanes(sessionID: "$0"),
            Data("list-panes -s -t '$0:' -F \"#{window_id}|#{pane_id}|#{pane_active}|#{pane_title}\"\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.sendKeys(paneID: "%2", data: Data([0x00, 0x20, 0xff])),
            Data("send-keys -t '%2' -H 00 20 ff\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.splitPane(targetPaneID: "%2", direction: .horizontal, before: true),
            Data("split-window -b -h -t '%2'\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.resizePane("%2", columns: 80, rows: 24),
            Data("resize-pane -t '%2' -x 80 -y 24\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.resizeClient(windowID: "@1", columns: 100, rows: 30),
            Data("refresh-client -C '@1:100x30'\n".utf8)
        )
        XCTAssertEqual(TmuxCommandEncoder.rotateWindow("@1", direction: .previous), Data("rotate-window -U -t '@1'\n".utf8))
        XCTAssertEqual(TmuxCommandEncoder.swapPane("%2", direction: .next), Data("swap-pane -D -t '%2'\n".utf8))
        XCTAssertEqual(TmuxCommandEncoder.toggleZoom("%2"), Data("resize-pane -Z -t '%2'\n".utf8))
        XCTAssertEqual(
            TmuxCommandEncoder.selectLayout(.evenVertical, targetPaneID: "%2"),
            Data("select-layout -t '%2' even-vertical\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.capturePane("%2"),
            Data("capture-pane -p -e -q -J -N -S -10000 -t '%2'\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.captureAlternateScreen("%2"),
            Data("capture-pane -p -e -q -J -N -a -S -10000 -t '%2'\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.capturePendingOutput("%2"),
            Data("capture-pane -p -P -C -t '%2'\n".utf8)
        )
        let paneStateCommand = String(decoding: TmuxCommandEncoder.listPaneState("%2"), as: UTF8.self)
        XCTAssertTrue(paneStateCommand.contains("pane_id=#{pane_id}\tpane_width=#{pane_width}"))
        XCTAssertTrue(paneStateCommand.contains("\talternate_on=#{alternate_on}"))
        XCTAssertTrue(paneStateCommand.contains(" -f '#{==:#{pane_id},%2}' -F "))
        XCTAssertTrue(paneStateCommand.contains("\textended_keys_format=#{extended-keys-format}"))
        XCTAssertTrue(paneStateCommand.contains("\tsession_attached=#{session_attached}"))
        XCTAssertEqual(
            TmuxCommandEncoder.suspendPaneOutput("%2"),
            Data("refresh-client -A '%2:off'\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.resumePaneOutput("%2"),
            Data("refresh-client -A '%2:on'\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.attachedClientCount("%2"),
            Data("display-message -p -t '%2' '#{session_attached}'\n".utf8)
        )
        XCTAssertEqual(
            TmuxCommandEncoder.newWindow(sessionID: "$0"),
            Data("new-window -t '$0:'\n".utf8)
        )
        XCTAssertEqual(TmuxCommandEncoder.detachClient(), Data("detach-client\n".utf8))
    }

    @MainActor
    func testDriverSerializesResponsesAndReportsCommandPayloadOnError() {
        let recorder = WriteRecorder()
        var errors: [String] = []
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        driver.onError = { errors.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        XCTAssertTrue(recorder.commands.first?.hasPrefix("list-windows -O index -t '$0'") == true)
        completeInitialSnapshot(driver)
        XCTAssertTrue(recorder.commands.contains { $0.hasPrefix("list-panes -s -t '$0:'") })

        driver.selectPane("%0")
        driver.killPane("%missing")
        XCTAssertEqual(recorder.commands.filter { $0.hasPrefix("select-pane") }.count, 1)
        XCTAssertFalse(recorder.commands.contains { $0.hasPrefix("kill-pane") })

        driver.consume("%begin 20 20 1\n%end 20 20 1\n")
        XCTAssertTrue(recorder.commands.contains { $0.hasPrefix("kill-pane") })
        driver.consume("%begin 21 21 1\ncan't find pane: %missing\n%error 21 21 1\n")
        XCTAssertEqual(errors.last, "can't find pane: %missing")
        XCTAssertEqual(driver.state.lastError, "can't find pane: %missing")
    }

    @MainActor
    func testInitialCaptureSupersedesEarlierLiveOutputThenPreservesLaterOutput() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        driver.consume("%output %0 before-snapshot\\012\n")
        completeInitialSnapshot(driver, capturedText: "captured-screen")
        XCTAssertTrue(recorder.commands.contains { $0.hasPrefix("capture-pane -p -e -q -J -N -S -10000") })
        XCTAssertEqual(driver.state.panes["%0"]?.snapshot?.primaryScreen, Data("captured-screen".utf8))

        driver.consume("%output %0 after-snapshot\\012\n")
        XCTAssertEqual(driver.state.panes["%0"]?.output.suffix(15), Data("after-snapshot\n".utf8))
    }

    @MainActor
    func testPaneOutputCallbackPreservesSplitUTF8Bytes() {
        let recorder = WriteRecorder()
        var callbackBytes = Data()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        driver.onPaneOutput = { _, data in callbackBytes.append(data) }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)

        driver.consume("%output %0 \\303\n")
        driver.consume("%output %0 \\251\n")
        XCTAssertEqual(callbackBytes, Data([0xc3, 0xa9]))
        XCTAssertEqual(String(data: callbackBytes, encoding: .utf8), "é")
        XCTAssertEqual(driver.state.panes["%0"]?.output.suffix(callbackBytes.count), callbackBytes)
    }

    @MainActor
    func testFailedInitialCaptureFlushesBufferedLiveOutputAndCompletesGeneration() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        driver.consume("%output %0 buffered\\012\n")
        completeWindowAndPaneLists(driver)
        completeTextResponse(driver, timestamp: 4, text: "1")
        completeEmptyResponse(driver, timestamp: 5) // output off
        driver.consume("%begin 6 6 1\ncapture failed\n%error 6 6 1\n")
        completeRemainingPaneSnapshot(driver, timestamp: 7, paneID: "%0")

        // A required-stage failure retries the entire snapshot rather than
        // installing the successful fragments from the failed attempt.
        completePaneSnapshot(driver, timestamp: 11, paneID: "%0", capturedText: "buffered")
        completeEmptyResponse(driver, timestamp: 18) // state subscriptions
        XCTAssertEqual(driver.state.panes["%0"]?.snapshot?.primaryScreen, Data("buffered".utf8))
        XCTAssertFalse(driver.state.panes["%0"]?.output.isEmpty ?? true)

        driver.consume("%output %0 live\\012\n")
        XCTAssertEqual(driver.state.panes["%0"]?.output.suffix(5), Data("live\n".utf8))
    }

    @MainActor
    func testMalformedInitialPaneDiscoveryRetriesOnceThenSafelyDetaches() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        driver.consume("%output %0 buffered\\012\n")
        completeWindowList(driver, timestamp: 2)
        driver.consume("%begin 3 3 1\nmalformed pane snapshot\n%end 3 3 1\n")
        completeWindowList(driver, timestamp: 4)
        driver.consume("%begin 5 5 1\nmalformed again\n%end 5 5 1\n")

        XCTAssertEqual(recorder.commands.filter { $0.hasPrefix("list-windows") }.count, 2)
        XCTAssertEqual(recorder.commands.last, "detach-client\n")
        driver.consume("%begin 6 6 1\n%end 6 6 1\n%exit detached\n\u{1b}\\")
        XCTAssertFalse(driver.state.isAttached)
    }

    @MainActor
    func testWindowDiscoveryFailureRetriesOnceThenSafelyDetaches() {
        let recorder = WriteRecorder()
        var exitReason: String?
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        driver.onExitWithReason = { exitReason = $0 }
        enter(driver, sessionID: "$0", name: "work")
        driver.consume("%begin 2 2 1\nwindow list failed\n%error 2 2 1\n")
        driver.consume("%begin 3 3 1\nwindow list failed again\n%error 3 3 1\n")

        XCTAssertEqual(recorder.commands.filter { $0.hasPrefix("list-windows") }.count, 2)
        XCTAssertEqual(recorder.commands.last, "detach-client\n")
        XCTAssertTrue(driver.state.isAttached)
        driver.consume("%begin 4 4 1\n%end 4 4 1\n%exit detached\n\u{1b}\\")
        XCTAssertFalse(driver.state.isAttached)
        XCTAssertEqual(exitReason, "tmux window discovery failed")
    }

    @MainActor
    func testWindowSnapshotAllowsPipeInWindowName() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeWindowAndPaneLists(driver, windowName: "left|right")
        driver.consume("%begin 4 4 1\n%end 4 4 1\n")
        XCTAssertEqual(driver.state.windows["@0"]?.name, "left|right")
    }

    @MainActor
    func testCapturedMultilineScreenUsesCRLFWithoutTrailingLineBreak() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeWindowAndPaneLists(driver)
        completeTextResponse(driver, timestamp: 4, text: "1")
        completeEmptyResponse(driver, timestamp: 5)
        driver.consume("%begin 6 6 1\nalpha\nbeta\n%end 6 6 1\n")
        completeRemainingPaneSnapshot(driver, timestamp: 7, paneID: "%0")
        XCTAssertEqual(driver.state.panes["%0"]?.snapshot?.primaryScreen, Data("alpha\r\nbeta".utf8))
    }

    @MainActor
    func testResponsePayloadLimitFailsRequestAndContinuesQueue() {
        let recorder = WriteRecorder()
        var errors: [String] = []
        let driver = TmuxControlModeDriver(responseByteLimit: 1_024) { recorder.commands.append($0) }
        driver.onError = { errors.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)
        driver.selectPane("%0")
        driver.killPane("%0")
        driver.consume("%begin 20 20 1\n\(String(repeating: "x", count: 1_024))\n%end 20 20 1\n")
        XCTAssertTrue(errors.contains("tmux response exceeded the bounded payload limit"))
        XCTAssertTrue(recorder.commands.contains { $0.hasPrefix("kill-pane") })
    }

    @MainActor
    func testMismatchedCaptureBlockTimesOutFlushesOutputAndExits() async {
        let recorder = WriteRecorder()
        var exitReason: String?
        let detachSent = expectation(description: "timeout requests a safe detach")
        let driver = TmuxControlModeDriver(requestTimeout: 0.02) { command in
            recorder.commands.append(command)
            if command == "detach-client\n" { detachSent.fulfill() }
        }
        driver.onExitWithReason = { exitReason = $0 }
        enter(driver, sessionID: "$0", name: "work")
        completeWindowAndPaneLists(driver)
        driver.consume("%output %0 buffered\\012\n")
        driver.consume("%begin 4 4 1\n%end 99 99 1\n")

        await fulfillment(of: [detachSent], timeout: 1)
        XCTAssertTrue(driver.state.isAttached)
        driver.consume("%begin 10 10 1\n%end 10 10 1\n%exit detached\n\u{1b}\\")
        XCTAssertTrue(exitReason?.contains("timed out") == true)
        XCTAssertFalse(driver.state.isAttached)
        XCTAssertEqual(driver.state.panes["%0"]?.output, Data("buffered\n".utf8))
    }

    @MainActor
    func testReconnectResetsTopologyHistoryQueueAndRequestsFreshSnapshot() {
        let recorder = WriteRecorder()
        var exitReasons: [String?] = []
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        driver.onExitWithReason = { exitReasons.append($0) }
        enter(driver, sessionID: "$0", name: "first")
        completeInitialSnapshot(driver, capturedText: "old")
        XCTAssertEqual(driver.state.panes["%0"]?.snapshot?.primaryScreen, Data("old".utf8))

        driver.consume("%exit detached\n\u{1b}\\")
        XCTAssertEqual(exitReasons, ["detached"])
        enter(driver, sessionID: "$1", name: "second", timestamp: 10)
        XCTAssertTrue(driver.state.windows.isEmpty)
        XCTAssertTrue(driver.state.panes.isEmpty)
        XCTAssertEqual(driver.state.sessionID, "$1")
        XCTAssertEqual(recorder.commands.filter { $0.hasPrefix("list-windows") }.count, 2)

        completeInitialSnapshot(driver, timestamp: 20, windowID: "@1", paneID: "%1", capturedText: "new")
        XCTAssertNil(driver.state.panes["%0"])
        XCTAssertEqual(driver.state.panes["%1"]?.snapshot?.primaryScreen, Data("new".utf8))
    }

    @MainActor
    func testSessionChangeDrainsOldSnapshotResponseAndResumesOldPaneBeforeDiscovery() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "first")
        completeWindowAndPaneLists(driver)
        completeTextResponse(driver, timestamp: 4, text: "1")
        completeEmptyResponse(driver, timestamp: 5)
        XCTAssertTrue(recorder.commands.last?.hasPrefix("capture-pane -p -e -q -J -N -S") == true)

        let newDiscoveryCount = recorder.commands.filter { $0.hasPrefix("list-windows -O index -t '$1'") }.count
        driver.consume("%session-changed $1 second\n")

        XCTAssertEqual(driver.state.sessionID, "$1")
        XCTAssertTrue(driver.state.windows.isEmpty)
        XCTAssertEqual(
            recorder.commands.filter { $0.hasPrefix("list-windows -O index -t '$1'") }.count,
            newDiscoveryCount,
            "new-session discovery must wait until the old response block is drained"
        )

        driver.consume("%begin 6 6 1\nold-session-screen\n%end 6 6 1\n")
        XCTAssertEqual(recorder.commands.last, "refresh-client -A '%0:on'\n")
        XCTAssertNil(driver.state.panes["%0"])
        XCTAssertEqual(
            recorder.commands.filter { $0.hasPrefix("list-windows -O index -t '$1'") }.count,
            newDiscoveryCount
        )

        completeEmptyResponse(driver, timestamp: 7)
        XCTAssertTrue(recorder.commands.last?.hasPrefix("list-windows -O index -t '$1'") == true)

        let resumeIndex = recorder.commands.firstIndex(of: "refresh-client -A '%0:on'\n")
        let discoveryIndex = recorder.commands.firstIndex { $0.hasPrefix("list-windows -O index -t '$1'") }
        XCTAssertNotNil(resumeIndex)
        XCTAssertNotNil(discoveryIndex)
        if let resumeIndex, let discoveryIndex { XCTAssertLessThan(resumeIndex, discoveryIndex) }

        completeInitialSnapshot(
            driver,
            timestamp: 8,
            windowID: "@1",
            paneID: "%1",
            capturedText: "new-session-screen"
        )
        XCTAssertNil(driver.state.panes["%0"])
        XCTAssertEqual(
            driver.state.panes["%1"]?.snapshot?.primaryScreen,
            Data("new-session-screen".utf8)
        )
    }

    @MainActor
    func testSessionChangeRecoversPaneWhenOldSuspendResponseArrivesLate() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "first")
        completeWindowAndPaneLists(driver)
        completeTextResponse(driver, timestamp: 4, text: "1")
        XCTAssertEqual(recorder.commands.last, "refresh-client -A '%0:off'\n")

        driver.consume("%session-changed $1 second\n")
        XCTAssertFalse(recorder.commands.contains { $0.hasPrefix("list-windows -O index -t '$1'") })

        completeEmptyResponse(driver, timestamp: 5)
        XCTAssertEqual(recorder.commands.last, "refresh-client -A '%0:on'\n")
        XCTAssertFalse(recorder.commands.contains { $0.hasPrefix("list-windows -O index -t '$1'") })

        completeEmptyResponse(driver, timestamp: 6)
        XCTAssertTrue(recorder.commands.last?.hasPrefix("list-windows -O index -t '$1'") == true)
    }

    @MainActor
    func testSessionChangeDrainsOldMutationBeforeStartingNewDiscovery() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "first")
        completeInitialSnapshot(driver, capturedText: "old")

        driver.selectPane("%0")
        XCTAssertEqual(recorder.commands.last, "select-pane -t '%0'\n")
        driver.consume("%session-changed $1 second\n")
        XCTAssertFalse(recorder.commands.contains { $0.hasPrefix("list-windows -O index -t '$1'") })

        driver.consume("%begin 20 20 1\n@stale|not-a-layout\n%end 20 20 1\n")
        XCTAssertTrue(recorder.commands.last?.hasPrefix("list-windows -O index -t '$1'") == true)
        XCTAssertNil(driver.state.lastError)
    }

    @MainActor
    func testMutationsAreIgnoredAfterControlModeExit() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)
        driver.consume("%exit detached\n\u{1b}\\")
        let commandCount = recorder.commands.count
        driver.selectPane("%0")
        driver.newWindow()
        driver.detachClient()
        XCTAssertEqual(recorder.commands.count, commandCount)
    }

    @MainActor
    func testPaneSnapshotPlacesPendingEscapeBeforeBufferedLiveDelta() throws {
        let recorder = WriteRecorder()
        var delivered: [Data] = []
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        driver.onPaneOutput = { _, data in delivered.append(data) }
        enter(driver, sessionID: "$0", name: "work")
        completeWindowAndPaneLists(driver)

        driver.consume("%output %0 before-checkpoint\\012\n")
        completeTextResponse(driver, timestamp: 4, text: "1")
        completeEmptyResponse(driver, timestamp: 5)
        driver.consume("%begin 6 6 1\nbase\n%end 6 6 1\n")
        driver.consume("%begin 7 7 1\n%end 7 7 1\n")
        let stateResponse = paneStateResponse(paneID: "%0")
        driver.consume("%begin 8 8 1\n\(stateResponse)\n%end 8 8 1\n")
        driver.consume("%output %0 title\\007\n")
        driver.consume("%begin 9 9 1\n\\033]0;\n%end 9 9 1\n")
        completeEmptyResponse(driver, timestamp: 10)

        let pane = try XCTUnwrap(driver.state.panes["%0"])
        XCTAssertEqual(pane.snapshot?.primaryScreen, Data("base".utf8))
        XCTAssertNil(pane.output.range(of: Data("before-checkpoint".utf8)))
        XCTAssertEqual(pane.output.suffix(10), Data("\u{1b}]0;title\u{7}".utf8))
        XCTAssertTrue(delivered.isEmpty, "snapshot and buffered deltas are replayed atomically from state")

        driver.consume("%output %0 after\\012\n")
        XCTAssertEqual(delivered, [Data("after\n".utf8)])
    }

    @MainActor
    func testPaneAddedAfterAttachReceivesPreflightAndSixPartSnapshot() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)

        let layout = "80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
        driver.consume("%layout-change @0 \(layout) \(layout) *\n")
        XCTAssertEqual(
            recorder.commands.last,
            "display-message -p -t '%1' '#{session_attached}'\n"
        )

        completeTextResponse(driver, timestamp: 20, text: "1")
        XCTAssertEqual(recorder.commands.last, "refresh-client -A '%1:off'\n")
        completeEmptyResponse(driver, timestamp: 21)
        driver.consume("%begin 22 22 1\nlate-pane\n%end 22 22 1\n")
        completeRemainingPaneSnapshot(driver, timestamp: 23, paneID: "%1")

        XCTAssertEqual(driver.state.panes["%1"]?.snapshot?.primaryScreen, Data("late-pane".utf8))
        let paneCommands = recorder.commands
            .filter { $0.contains("%1") }
            .map { $0.trimmingCharacters(in: .newlines) }
        XCTAssertEqual(paneCommands.count, 7)
        XCTAssertEqual(paneCommands[0], "display-message -p -t '%1' '#{session_attached}'")
        XCTAssertEqual(paneCommands[1], "refresh-client -A '%1:off'")
        XCTAssertTrue(paneCommands[3].contains(" -a "))
        XCTAssertTrue(paneCommands[4].hasPrefix("list-panes -t '%1'"))
        XCTAssertTrue(paneCommands[5].hasPrefix("capture-pane -p -P -C"))
        XCTAssertEqual(paneCommands[6], "refresh-client -A '%1:on'")
    }

    @MainActor
    func testMultiClientPreflightNeverSuspendsPaneOutput() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeWindowAndPaneLists(driver)

        completeTextResponse(driver, timestamp: 4, text: "2")
        XCTAssertTrue(recorder.commands.last?.hasPrefix("capture-pane -p -e -q -J -N -S") == true)
        XCTAssertFalse(recorder.commands.contains { $0.contains("%0:off") })

        driver.consume("%begin 5 5 1\nshared-screen\n%end 5 5 1\n")
        completeRemainingPaneSnapshot(
            driver,
            timestamp: 6,
            paneID: "%0",
            attachedClientCount: 2,
            suspended: false
        )

        XCTAssertEqual(
            driver.state.panes["%0"]?.snapshot?.primaryScreen,
            Data("shared-screen".utf8)
        )
        XCTAssertFalse(recorder.commands.contains { $0.contains("%0:off") || $0.contains("%0:on") })
    }

    @MainActor
    func testSuspensionLeaseResumesPaneBeforeSafeDetach() async {
        let recorder = WriteRecorder()
        let resumed = expectation(description: "expired lease resumes pane output")
        let detached = expectation(description: "expired lease safely detaches")
        var exitReason: String?
        let driver = TmuxControlModeDriver(
            requestTimeout: 1,
            snapshotSuspensionTimeout: 0.02
        ) { command in
            recorder.commands.append(command)
            if command == "refresh-client -A '%0:on'\n" { resumed.fulfill() }
            if command == "detach-client\n" { detached.fulfill() }
        }
        driver.onExitWithReason = { exitReason = $0 }
        enter(driver, sessionID: "$0", name: "work")
        completeWindowAndPaneLists(driver)
        completeTextResponse(driver, timestamp: 4, text: "1")
        completeEmptyResponse(driver, timestamp: 5)

        await fulfillment(of: [resumed, detached], timeout: 1)
        let resumeIndex = try? XCTUnwrap(
            recorder.commands.firstIndex(of: "refresh-client -A '%0:on'\n")
        )
        let detachIndex = try? XCTUnwrap(recorder.commands.firstIndex(of: "detach-client\n"))
        XCTAssertNotNil(resumeIndex)
        XCTAssertNotNil(detachIndex)
        if let resumeIndex, let detachIndex { XCTAssertLessThan(resumeIndex, detachIndex) }

        driver.consume("%exit detached\n\u{1b}\\")
        XCTAssertEqual(exitReason, "tmux pane output suspension lease expired: %0")
    }

    @MainActor
    func testConsistencyRetryRunsFreshPreflightBeforeConsideringAnotherOff() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeWindowAndPaneLists(driver)

        completeTextResponse(driver, timestamp: 4, text: "1")
        completeEmptyResponse(driver, timestamp: 5)
        driver.consume("%begin 6 6 1\nfirst-screen\n%end 6 6 1\n")
        driver.consume("%output %0 raced\\012\n")
        completeRemainingPaneSnapshot(driver, timestamp: 7, paneID: "%0")

        XCTAssertEqual(
            recorder.commands.last,
            "display-message -p -t '%0' '#{session_attached}'\n"
        )
        completeTextResponse(driver, timestamp: 11, text: "2")
        XCTAssertTrue(recorder.commands.last?.hasPrefix("capture-pane -p -e -q -J -N -S") == true)
        XCTAssertEqual(recorder.commands.filter { $0.contains("%0:off") }.count, 1)

        driver.consume("%begin 12 12 1\nsecond-screen\n%end 12 12 1\n")
        completeRemainingPaneSnapshot(
            driver,
            timestamp: 13,
            paneID: "%0",
            attachedClientCount: 2,
            suspended: false
        )
        XCTAssertEqual(
            driver.state.panes["%0"]?.snapshot?.primaryScreen,
            Data("second-screen".utf8)
        )
    }

    @MainActor
    func testRequiredSnapshotStageExhaustionNeverInstallsPartialSnapshot() {
        let recorder = WriteRecorder()
        var errors: [String] = []
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        driver.onError = { errors.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeWindowAndPaneLists(driver)

        completeFailedCurrentSnapshotAttempt(driver, timestamp: 4, paneID: "%0")
        completeFailedCurrentSnapshotAttempt(driver, timestamp: 11, paneID: "%0")
        completeFailedCurrentSnapshotAttempt(driver, timestamp: 18, paneID: "%0")

        XCTAssertNil(driver.state.panes["%0"]?.snapshot)
        XCTAssertEqual(recorder.commands.last, "detach-client\n")
        XCTAssertTrue(errors.contains("tmux pane snapshot failed after bounded retries: %0"))
    }

    func testParserPreservesSubscriptionValueAndIgnoresFutureMetadataFields() {
        var parser = TmuxControlParser()
        let events = parser.consume(Data(
            "\u{1b}P1000p%subscription-changed kurotty-pane-title $0 @1 2 %3 future metadata : hello : 세계\n".utf8
        ))
        XCTAssertEqual(events, [
            .entered,
            .subscriptionChanged(
                name: "kurotty-pane-title",
                sessionID: "$0",
                windowID: "@1",
                windowIndex: 2,
                paneID: "%3",
                value: "hello : 세계"
            ),
        ])
    }

    @MainActor
    func testDriverBatchesTenThousandInputsAndKeepsLatestOfTenThousandResizes() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)

        driver.selectPane("%0")
        for _ in 0..<10_000 { driver.sendKeys(to: "%0", text: "x") }
        driver.killPane("%other")
        for index in 0..<10_000 {
            driver.resizePane("%0", columns: index + 1, rows: (index % 50) + 1)
        }

        completeEmptyResponse(driver, timestamp: 20)
        let inputCommand = recorder.commands.last ?? ""
        XCTAssertTrue(inputCommand.hasPrefix("send-keys -t '%0' -H "))
        let inputByteCount = inputCommand.components(separatedBy: " -H ").last?
            .split(whereSeparator: \.isWhitespace).count
        XCTAssertEqual(inputByteCount, 10_000)
        XCTAssertLessThanOrEqual(inputByteCount ?? .max, 16_384)

        completeEmptyResponse(driver, timestamp: 21)
        XCTAssertEqual(recorder.commands.last, "kill-pane -t '%other'\n")
        completeEmptyResponse(driver, timestamp: 22)
        XCTAssertEqual(recorder.commands.last, "resize-pane -t '%0' -x 10000 -y 50\n")
    }

    @MainActor
    func testDriverEncodesLargeInputOnlyAtDequeueInSixteenKiBChunks() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)

        driver.selectPane("%0")
        driver.sendKeys(to: "%0", text: String(repeating: "z", count: 40_000))
        completeEmptyResponse(driver, timestamp: 20)

        var timestamp: UInt64 = 21
        var byteCounts: [Int] = []
        for _ in 0..<3 {
            let command = recorder.commands.last ?? ""
            XCTAssertTrue(command.hasPrefix("send-keys -t '%0' -H "))
            byteCounts.append(command.components(separatedBy: " -H ").last?
                .split(whereSeparator: \.isWhitespace).count ?? 0)
            completeEmptyResponse(driver, timestamp: timestamp)
            timestamp += 1
        }
        XCTAssertEqual(byteCounts.reduce(0, +), 40_000)
        XCTAssertEqual(byteCounts, [16_384, 16_384, 7_232])
    }

    @MainActor
    func testMutationOverflowSurfacesErrorAndImmediatelyRequestsSafeDetach() {
        let recorder = WriteRecorder()
        var errors: [String] = []
        let limits = TmuxMutationQueue.Limits(
            maximumInputByteCount: 4,
            maximumPayloadByteCount: 32,
            maximumStructuralCount: 4,
            maximumResizeKeyCount: 4,
            inputChunkByteCount: 4
        )
        let driver = TmuxControlModeDriver(mutationQueueLimits: limits) {
            recorder.commands.append($0)
        }
        driver.onError = { errors.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)

        driver.sendKeys(to: "%0", text: "12345")

        XCTAssertEqual(recorder.commands.last, "detach-client\n")
        XCTAssertEqual(errors.last, "tmux input backlog exceeded 4 bytes (attempted 5)")
        XCTAssertEqual(driver.state.lastError, errors.last)
    }

    @MainActor
    func testDetachIsIdempotentDropsQueuedInputAndResumesAnOffPaneFirst() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeWindowAndPaneLists(driver)
        completeTextResponse(driver, timestamp: 4, text: "1")
        XCTAssertEqual(recorder.commands.last, "refresh-client -A '%0:off'\n")

        driver.sendKeys(to: "%0", text: "discard me")
        driver.detachClient()
        driver.detachClient()
        completeEmptyResponse(driver, timestamp: 5)
        XCTAssertEqual(recorder.commands.last, "refresh-client -A '%0:on'\n")
        completeEmptyResponse(driver, timestamp: 6)
        XCTAssertEqual(recorder.commands.last, "detach-client\n")
        XCTAssertEqual(recorder.commands.filter { $0 == "detach-client\n" }.count, 1)
        XCTAssertFalse(recorder.commands.contains { $0.hasPrefix("send-keys") })
    }

    @MainActor
    func testTransportExitFinalizesMatchingDriverExactlyOnce() {
        let recorder = WriteRecorder()
        var reasons: [String?] = []
        var exitCount = 0
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        driver.onExitWithReason = { reasons.append($0) }
        driver.onExit = { exitCount += 1 }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)

        driver.transportDidExit(status: 9)
        driver.transportDidExit(status: 9)
        driver.consume("%exit late\n\u{1b}\\")

        XCTAssertEqual(exitCount, 1)
        XCTAssertEqual(reasons, ["tmux transport exited with status 9"])
        XCTAssertFalse(driver.state.isAttached)
    }

    @MainActor
    func testFatalRecoveryWritesBlankBeforeGracePeriodSynthesizesExit() async {
        let blankWritten = expectation(description: "tmux wait-exit released")
        let exited = expectation(description: "local tmux UI restored")
        var commands: [String] = []
        let limits = TmuxMutationQueue.Limits(
            maximumInputByteCount: 0,
            maximumPayloadByteCount: 8,
            maximumStructuralCount: 2,
            maximumResizeKeyCount: 2,
            inputChunkByteCount: 1
        )
        let driver = TmuxControlModeDriver(
            fatalAbortDelay: 0.01,
            fatalWaitExitDelay: 0.01,
            mutationQueueLimits: limits
        ) { command in
            commands.append(command)
            if command == "\n" { blankWritten.fulfill() }
        }
        driver.onExit = { exited.fulfill() }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)

        driver.sendKeys(to: "%0", text: "x")
        await fulfillment(of: [blankWritten, exited], timeout: 1, enforceOrder: true)

        let detachIndex = commands.firstIndex(of: "detach-client\n")
        let blankIndex = commands.firstIndex(of: "\n")
        XCTAssertNotNil(detachIndex)
        XCTAssertNotNil(blankIndex)
        if let detachIndex, let blankIndex { XCTAssertLessThan(detachIndex, blankIndex) }
        XCTAssertFalse(driver.state.isAttached)
    }

    @MainActor
    func testParserLocalAbortWaitsForFatalFallbackBeforeRestoringLocalUI() async {
        let blankWritten = expectation(description: "tmux wait-exit released")
        let exited = expectation(description: "local tmux UI restored")
        var commands: [String] = []
        var exitCount = 0
        let driver = TmuxControlModeDriver(
            fatalAbortDelay: 0.01,
            fatalWaitExitDelay: 0.01
        ) { command in
            commands.append(command)
            if command == "\n" { blankWritten.fulfill() }
        }
        driver.onExit = {
            exitCount += 1
            exited.fulfill()
        }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)

        driver.consume("unexpected plain bytes\n")

        XCTAssertEqual(exitCount, 0)
        XCTAssertTrue(driver.state.isAttached)
        XCTAssertEqual(commands.last, "detach-client\n")
        await fulfillment(of: [blankWritten, exited], timeout: 1, enforceOrder: true)

        let detachIndex = commands.firstIndex(of: "detach-client\n")
        let blankIndex = commands.firstIndex(of: "\n")
        XCTAssertNotNil(detachIndex)
        XCTAssertNotNil(blankIndex)
        if let detachIndex, let blankIndex { XCTAssertLessThan(detachIndex, blankIndex) }
        XCTAssertEqual(exitCount, 1)
        XCTAssertFalse(driver.state.isAttached)
    }

    @MainActor
    func testNormalExitMarkerCancelsFatalFallbacks() async {
        let limits = TmuxMutationQueue.Limits(
            maximumInputByteCount: 0,
            maximumPayloadByteCount: 8,
            maximumStructuralCount: 2,
            maximumResizeKeyCount: 2,
            inputChunkByteCount: 1
        )
        var commands: [String] = []
        var exitCount = 0
        let driver = TmuxControlModeDriver(
            fatalAbortDelay: 0.01,
            fatalWaitExitDelay: 0.02,
            mutationQueueLimits: limits
        ) { commands.append($0) }
        driver.onExit = { exitCount += 1 }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)

        driver.sendKeys(to: "%0", text: "x")
        driver.consume("%exit detached\n\u{1b}\\")
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(exitCount, 1)
        XCTAssertFalse(commands.contains("\n"))
    }

    @MainActor
    func testPaneTitleInitialSnapshotAndSubscriptionAreSessionScoped() {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver { recorder.commands.append($0) }
        enter(driver, sessionID: "$0", name: "work")
        completeWindowList(driver, timestamp: 2)
        driver.consume("%begin 3 3 1\n@0|%0|1|build | logs\n%end 3 3 1\n")
        completePaneSnapshot(driver, timestamp: 4, paneID: "%0")
        completeEmptyResponse(driver, timestamp: 11)
        XCTAssertEqual(driver.state.panes["%0"]?.title, "build | logs")

        driver.consume("%subscription-changed kurotty-pane-title $1 @0 0 %0 : foreign\n")
        driver.consume("%subscription-changed kurotty-pane-title $0 @0 0 %missing : unknown\n")
        XCTAssertEqual(driver.state.panes["%0"]?.title, "build | logs")
        XCTAssertNil(driver.state.panes["%missing"])

        driver.consume("%subscription-changed kurotty-pane-title $0 @0 0 %0 future : editor : 세계\n")
        XCTAssertEqual(driver.state.panes["%0"]?.title, "editor : 세계")
    }

    @MainActor
    func testWindowOrderSubscriptionAbsorbsQueuedBurstAndRunsOneDirtyFollowup() async {
        let recorder = WriteRecorder()
        let driver = TmuxControlModeDriver(windowOrderDebounce: 0.01) {
            recorder.commands.append($0)
        }
        enter(driver, sessionID: "$0", name: "work")
        completeInitialSnapshot(driver)
        driver.selectPane("%0")

        for _ in 0..<10 {
            driver.consume("%subscription-changed kurotty-window-index $0 @0 0 %0 : 0\n")
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        for _ in 0..<10 {
            driver.consume("%subscription-changed kurotty-window-index $0 @0 0 %0 : 0\n")
        }
        completeEmptyResponse(driver, timestamp: 20)
        XCTAssertEqual(recorder.commands.filter { $0.hasPrefix("list-windows -O index -t '$0' -F \"#{window_id}\"") }.count, 1)

        for _ in 0..<10 {
            driver.consume("%subscription-changed kurotty-window-index $0 @0 0 %0 : 0\n")
        }
        completeTextResponse(driver, timestamp: 21, text: "@0")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(recorder.commands.filter { $0.hasPrefix("list-windows -O index -t '$0' -F \"#{window_id}\"") }.count, 2)
        completeTextResponse(driver, timestamp: 22, text: "@0")
        XCTAssertEqual(driver.state.windowOrder, ["@0"])
    }

    @MainActor
    private func enter(
        _ driver: TmuxControlModeDriver,
        sessionID: String,
        name: String,
        timestamp: UInt64 = 1
    ) {
        driver.consume(
            "\u{1b}P1000p%begin \(timestamp) \(timestamp) 0\n"
                + "%end \(timestamp) \(timestamp) 0\n"
                + "%session-changed \(sessionID) \(name)\n"
        )
    }

    @MainActor
    private func completeWindowAndPaneLists(
        _ driver: TmuxControlModeDriver,
        timestamp: UInt64 = 2,
        windowID: String = "@0",
        paneID: String = "%0",
        windowName: String = "shell"
    ) {
        completeWindowList(
            driver,
            timestamp: timestamp,
            windowID: windowID,
            paneID: paneID,
            windowName: windowName
        )
        driver.consume(
            "%begin \(timestamp + 1) \(timestamp + 1) 1\n"
                + "\(windowID)|\(paneID)|1\n"
                + "%end \(timestamp + 1) \(timestamp + 1) 1\n"
        )
    }

    @MainActor
    private func completeWindowList(
        _ driver: TmuxControlModeDriver,
        timestamp: UInt64,
        windowID: String = "@0",
        paneID: String = "%0",
        windowName: String = "shell"
    ) {
        let numericPaneID = paneID.dropFirst()
        let layout = "80x24,0,0,\(numericPaneID)"
        driver.consume(
            "%begin \(timestamp) \(timestamp) 1\n"
                + "\(windowID)|\(layout)|\(layout)|*|1|\(windowName)\n"
                + "%end \(timestamp) \(timestamp) 1\n"
        )
    }

    @MainActor
    private func completeInitialSnapshot(
        _ driver: TmuxControlModeDriver,
        timestamp: UInt64 = 2,
        windowID: String = "@0",
        paneID: String = "%0",
        capturedText: String = ""
    ) {
        completeWindowAndPaneLists(
            driver,
            timestamp: timestamp,
            windowID: windowID,
            paneID: paneID
        )
        completePaneSnapshot(
            driver,
            timestamp: timestamp + 2,
            paneID: paneID,
            capturedText: capturedText
        )
        completeEmptyResponse(driver, timestamp: timestamp + 9) // state subscriptions
    }

    @MainActor
    private func completePaneSnapshot(
        _ driver: TmuxControlModeDriver,
        timestamp: UInt64,
        paneID: String,
        capturedText: String = "",
        alternateText: String = "",
        pendingText: String = "",
        attachedClientCount: Int = 1
    ) {
        completeTextResponse(
            driver,
            timestamp: timestamp,
            text: String(attachedClientCount)
        )
        var currentTimestamp = timestamp + 1
        if attachedClientCount == 1 {
            completeEmptyResponse(driver, timestamp: currentTimestamp)
            currentTimestamp += 1
        }
        driver.consume(
            "%begin \(currentTimestamp) \(currentTimestamp) 1\n"
                + (capturedText.isEmpty ? "" : "\(capturedText)\n")
                + "%end \(currentTimestamp) \(currentTimestamp) 1\n"
        )
        completeRemainingPaneSnapshot(
            driver,
            timestamp: currentTimestamp + 1,
            paneID: paneID,
            alternateText: alternateText,
            pendingText: pendingText,
            attachedClientCount: attachedClientCount,
            suspended: attachedClientCount == 1
        )
    }

    @MainActor
    private func completeRemainingPaneSnapshot(
        _ driver: TmuxControlModeDriver,
        timestamp: UInt64,
        paneID: String,
        alternateText: String = "",
        pendingText: String = "",
        attachedClientCount: Int = 1,
        suspended: Bool = true
    ) {
        driver.consume(
            "%begin \(timestamp) \(timestamp) 1\n"
                + (alternateText.isEmpty ? "" : "\(alternateText)\n")
                + "%end \(timestamp) \(timestamp) 1\n"
        )
        let state = paneStateResponse(paneID: paneID, attachedClientCount: attachedClientCount)
        driver.consume(
            "%begin \(timestamp + 1) \(timestamp + 1) 1\n"
                + "\(state)\n"
                + "%end \(timestamp + 1) \(timestamp + 1) 1\n"
        )
        driver.consume(
            "%begin \(timestamp + 2) \(timestamp + 2) 1\n"
                + (pendingText.isEmpty ? "" : "\(pendingText)\n")
                + "%end \(timestamp + 2) \(timestamp + 2) 1\n"
        )
        if suspended {
            completeEmptyResponse(driver, timestamp: timestamp + 3)
        }
    }

    @MainActor
    private func completeEmptyResponse(_ driver: TmuxControlModeDriver, timestamp: UInt64) {
        driver.consume("%begin \(timestamp) \(timestamp) 1\n%end \(timestamp) \(timestamp) 1\n")
    }

    @MainActor
    private func completeTextResponse(
        _ driver: TmuxControlModeDriver,
        timestamp: UInt64,
        text: String
    ) {
        driver.consume(
            "%begin \(timestamp) \(timestamp) 1\n\(text)\n%end \(timestamp) \(timestamp) 1\n"
        )
    }

    @MainActor
    private func completeFailedCurrentSnapshotAttempt(
        _ driver: TmuxControlModeDriver,
        timestamp: UInt64,
        paneID: String
    ) {
        completeTextResponse(driver, timestamp: timestamp, text: "1")
        completeEmptyResponse(driver, timestamp: timestamp + 1)
        driver.consume(
            "%begin \(timestamp + 2) \(timestamp + 2) 1\n"
                + "capture failed\n"
                + "%error \(timestamp + 2) \(timestamp + 2) 1\n"
        )
        completeRemainingPaneSnapshot(
            driver,
            timestamp: timestamp + 3,
            paneID: paneID
        )
    }

    private func paneStateResponse(
        paneID: String,
        alternateOn: Bool = false,
        cursorX: Int = 0,
        cursorY: Int = 0,
        attachedClientCount: Int = 1
    ) -> String {
        [
            "pane_id=\(paneID)", "pane_width=80", "pane_height=24",
            "alternate_on=\(alternateOn ? 1 : 0)", "alternate_saved_x=0", "alternate_saved_y=0",
            "cursor_x=\(cursorX)", "cursor_y=\(cursorY)",
            "scroll_region_upper=0", "scroll_region_lower=23", "pane_tabs=8,16,24",
            "cursor_flag=1", "insert_flag=0", "origin_flag=0", "keypad_cursor_flag=0", "keypad_flag=0",
            "wrap_flag=1", "mouse_standard_flag=0", "mouse_button_flag=0", "mouse_any_flag=0",
            "mouse_utf8_flag=0", "mouse_sgr_flag=0", "bracket_paste_flag=0", "pane_key_mode=VT10x",
            "extended_keys_format=xterm", "session_attached=\(attachedClientCount)",
        ].joined(separator: "\t")
    }
}
