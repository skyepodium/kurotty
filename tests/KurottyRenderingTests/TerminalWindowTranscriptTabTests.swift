import AppKit
import XCTest
@testable import KurottyApp

/// Center-tab hosting for the read-only agent transcript viewer: identity and
/// title formatting, tab reuse per session, and the guarantee that terminal-only
/// controller actions fall through a transcript tab as no-ops.
final class AgentSessionTranscriptTabTitleFormatterTests: XCTestCase {
    private func makeRecord(
        agent: AgentSessionKind = .claudeCode,
        sessionID: String = "session-1",
        title: String = "Fix the parser",
        filePath: String = "/tmp/transcript.jsonl"
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            agent: agent,
            sessionID: sessionID,
            title: title,
            cwd: "/tmp",
            updatedAt: Date(),
            createdAt: Date(),
            messageCount: 1,
            filePath: filePath
        )
    }

    func testLabelCombinesSessionTitleAndAgentName() {
        let label = AgentSessionTranscriptTabTitleFormatter.label(for: makeRecord())

        XCTAssertEqual(
            label,
            "Fix the parser" + AgentSessionTranscriptTabTitleFormatter.titleSeparator
                + AgentSessionKind.claudeCode.displayName
        )
    }

    func testLabelFallsBackToTheAgentNameWhenTheSessionHasNoTitle() {
        XCTAssertEqual(
            AgentSessionTranscriptTabTitleFormatter.label(for: makeRecord(title: "   ")),
            AgentSessionKind.claudeCode.displayName
        )
    }

    func testSessionKeySeparatesAgentsSharingAnIdentifier() {
        XCTAssertNotEqual(
            AgentSessionTranscriptTabTitleFormatter.sessionKey(for: makeRecord(agent: .claudeCode)),
            AgentSessionTranscriptTabTitleFormatter.sessionKey(for: makeRecord(agent: .codex))
        )
    }
}

@MainActor
final class TerminalWindowTranscriptTabTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-transcript-tab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
        try super.tearDownWithError()
    }

    private func makeWindowController() -> TerminalWindowController {
        let session = TmuxPaneSession(
            writeHandler: { _ in },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        return TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: session),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
    }

    private func makeRecord(sessionID: String, title: String = "Session") throws -> AgentSessionRecord {
        let fileURL = directoryURL.appendingPathComponent("\(sessionID).jsonl")
        try "{}\n".write(to: fileURL, atomically: true, encoding: .utf8)
        return AgentSessionRecord(
            agent: .claudeCode,
            sessionID: sessionID,
            title: title,
            cwd: directoryURL.path,
            updatedAt: Date(),
            createdAt: Date(),
            messageCount: 1,
            filePath: fileURL.path
        )
    }

    func testOpeningATranscriptAddsATabTitledWithTheSession() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        let record = try makeRecord(sessionID: "alpha", title: "Alpha run")

        let item = try XCTUnwrap(controller.openTranscriptTab(for: record))

        XCTAssertEqual(controller.tabView.numberOfTabViewItems, 2)
        XCTAssertTrue(controller.tabView.selectedTabViewItem === item)
        XCTAssertEqual(item.label, AgentSessionTranscriptTabTitleFormatter.label(for: record))
        XCTAssertNotNil(controller.transcriptView(in: item))
    }

    func testOpeningTheSameSessionTwiceReusesItsTab() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        let record = try makeRecord(sessionID: "alpha")
        let other = try makeRecord(sessionID: "beta")

        let first = try XCTUnwrap(controller.openTranscriptTab(for: record))
        _ = controller.openTranscriptTab(for: other)
        let reopened = try XCTUnwrap(controller.openTranscriptTab(for: record))

        XCTAssertTrue(first === reopened, "a second open of the same session must reuse its tab")
        XCTAssertEqual(controller.tabView.numberOfTabViewItems, 3, "terminal tab plus one tab per session")
        XCTAssertEqual(
            controller.openTranscriptSessionKeys,
            [
                AgentSessionTranscriptTabTitleFormatter.sessionKey(for: record),
                AgentSessionTranscriptTabTitleFormatter.sessionKey(for: other),
            ]
        )
    }

    func testARecordWithoutATranscriptPathOpensNoTab() {
        let controller = makeWindowController()
        defer { controller.close() }
        let record = AgentSessionRecord(
            agent: .claudeCode,
            sessionID: "no-file",
            title: "No file",
            cwd: "/tmp",
            updatedAt: Date(),
            createdAt: Date(),
            messageCount: 0,
            filePath: ""
        )

        XCTAssertNil(controller.openTranscriptTab(for: record))
        XCTAssertEqual(controller.tabView.numberOfTabViewItems, 1)
    }

    /// A transcript tab hosts no `SplitTerminalView`, so every controller path
    /// that needs a terminal must fall through it exactly like an editor tab.
    func testTerminalOnlyActionsAreNoOpsWhileATranscriptTabIsSelected() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        let item = try XCTUnwrap(controller.openTranscriptTab(for: try makeRecord(sessionID: "alpha")))

        XCTAssertTrue(controller.tabView.selectedTabViewItem === item)
        XCTAssertNil(controller.currentSplitView())

        controller.splitVertically()
        controller.splitHorizontally()
        controller.findTerminalOutput()
        controller.sendTextToActivePane("echo should-not-reach-a-pane")

        XCTAssertEqual(
            controller.tabView.numberOfTabViewItems,
            2,
            "splitting on a transcript tab must not create panes or tabs"
        )
        XCTAssertEqual(controller.selectedLayoutSlotCount, 0)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder.isEmpty)
        XCTAssertTrue(controller.commandSpanPaletteCommands().isEmpty)
    }

    func testTheSidebarOpensTranscriptsThroughTheWindowControllerTab() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        controller.setCommandHistoryPanelVisible(true, section: .agentSessions)
        let record = try makeRecord(sessionID: "alpha")

        let handler = try XCTUnwrap(
            controller.agentSessionPanel.onOpenTranscript,
            "the window controller must own transcript presentation, not the panel"
        )
        handler(record)

        XCTAssertEqual(
            controller.openTranscriptSessionKeys,
            [AgentSessionTranscriptTabTitleFormatter.sessionKey(for: record)]
        )
    }
}
