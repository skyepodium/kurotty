import AppKit
import XCTest
@testable import KurottyApp

/// Window stand-in for the status bar's data source. Records the text the bar
/// asks to insert so the resume path can be asserted without a PTY.
@MainActor
final class StubStatusBarDataSource: TerminalStatusBarDataSource {
    var descriptors: [TerminalStatusBarPaneDescriptor]
    var activePaneIdentifier: String?
    var samplingContext: TerminalStatusBarSamplingContext
    private(set) var insertedText: [(text: String, paneIdentifier: String)] = []
    private(set) var didOpenPreferences = false

    init(
        descriptors: [TerminalStatusBarPaneDescriptor],
        activePaneIdentifier: String? = nil,
        samplingContext: TerminalStatusBarSamplingContext = TerminalStatusBarSamplingContext(
            isWindowVisible: false,
            isWindowOccluded: true,
            paneCount: 0
        )
    ) {
        self.descriptors = descriptors
        self.activePaneIdentifier = activePaneIdentifier
        self.samplingContext = samplingContext
    }

    func statusBarPaneDescriptors() -> [TerminalStatusBarPaneDescriptor] {
        descriptors
    }

    func statusBarActivePaneIdentifier() -> String? {
        activePaneIdentifier
    }

    func statusBarSamplingContext() -> TerminalStatusBarSamplingContext {
        samplingContext
    }

    func statusBarInsertText(_ text: String, paneIdentifier: String) {
        insertedText.append((text, paneIdentifier))
    }

    func statusBarOpenPreferences() {
        didOpenPreferences = true
    }
}

/// Bottom status bar: the pure layers only.
///
/// Byte/percent formatting, the CPU delta between counter samples, aggregation
/// across panes, the destructive kill guard, the occlusion sampling gate, the
/// responsive-truncation breakpoints, and the agent-label composition are all
/// deterministic functions, so nothing here touches libproc, a timer, or a
/// window.
final class TerminalStatusBarTests: XCTestCase {
    /// The bar holds its data source weakly; these keep the stubs alive.
    @MainActor private var retainedDataSources: [StubStatusBarDataSource] = []

    private enum Fixture {
        static let kilobyteBYTES: UInt64 = 1024
        static let megabyteBYTES: UInt64 = 1024 * 1024
        static let gigabyteBYTES: UInt64 = 1024 * 1024 * 1024
        static let paneA = "pane-A"
        static let paneB = "pane-B"
        static let paneATitle = "~ (-zsh)"
        static let paneBTitle = "~/src (claude)"
        static let paneAProcess: pid_t = 4242
        static let paneBProcess: pid_t = 4243
        static let processorCOUNT = 8
        static let workingDirectory = "/Users/example/project"
        static let otherWorkingDirectory = "/Users/example/other"
    }

    // MARK: - Memory formatting

    func testMemoryTextUsesWholeMegabytesBelowOneGigabyte() {
        let bytes = 412 * Fixture.megabyteBYTES

        XCTAssertEqual(TerminalResourceUsageFormatter.memoryText(bytes: bytes), "412 MB")
    }

    func testMemoryTextUsesOneDecimalGigabyteAboveTheBoundary() {
        let bytes = UInt64(Double(Fixture.gigabyteBYTES) * 1.23)

        XCTAssertEqual(TerminalResourceUsageFormatter.memoryText(bytes: bytes), "1.2 GB")
    }

    func testMemoryTextUsesKilobytesBelowOneMegabyte() {
        let bytes = 768 * Fixture.kilobyteBYTES

        XCTAssertEqual(TerminalResourceUsageFormatter.memoryText(bytes: bytes), "768 KB")
    }

    func testMemoryTextRoundsMegabytesToTheNearestWholeUnit() {
        let bytes = UInt64(Double(Fixture.megabyteBYTES) * 411.6)

        XCTAssertEqual(TerminalResourceUsageFormatter.memoryText(bytes: bytes), "412 MB")
    }

    func testMemoryTextReportsZeroBytesWithoutCrashing() {
        XCTAssertEqual(TerminalResourceUsageFormatter.memoryText(bytes: 0), "0 KB")
    }

    // MARK: - CPU formatting

    func testCPUTextRoundsToWholePercent() {
        XCTAssertEqual(TerminalResourceUsageFormatter.cpuText(percent: 3.4), "3%")
        XCTAssertEqual(TerminalResourceUsageFormatter.cpuText(percent: 3.6), "4%")
    }

    func testCPUTextClampsOutOfRangeValues() {
        XCTAssertEqual(TerminalResourceUsageFormatter.cpuText(percent: -12), "0%")
        XCTAssertEqual(TerminalResourceUsageFormatter.cpuText(percent: 4_000), "100%")
    }

    func testCPUTextRendersUnavailableValueWhenNoDeltaExists() {
        XCTAssertEqual(TerminalResourceUsageFormatter.cpuText(percent: nil), "—")
    }

    func testSummaryTextMatchesTheCompactCopyShape() {
        let text = TerminalResourceUsageFormatter.summaryText(
            bytes: 412 * Fixture.megabyteBYTES,
            cpuPercent: 3
        )

        XCTAssertEqual(text, "RAM 412 MB · CPU 3%")
    }

    // MARK: - Severity thresholds

    func testSeverityCrossesWarningAndErrorThresholds() {
        XCTAssertEqual(TerminalResourceUsageFormatter.severity(cpuPercent: 79.9), .normal)
        XCTAssertEqual(TerminalResourceUsageFormatter.severity(cpuPercent: 80), .warning)
        XCTAssertEqual(TerminalResourceUsageFormatter.severity(cpuPercent: 91.9), .warning)
        XCTAssertEqual(TerminalResourceUsageFormatter.severity(cpuPercent: 92), .error)
    }

    func testMemorySeverityIsRelativeToPhysicalMemory() {
        let totalBytes = 16 * Fixture.gigabyteBYTES

        XCTAssertEqual(
            TerminalResourceUsageFormatter.severity(residentBytes: Fixture.gigabyteBYTES, totalPhysicalBytes: totalBytes),
            .normal
        )
        XCTAssertEqual(
            TerminalResourceUsageFormatter.severity(
                residentBytes: 15 * Fixture.gigabyteBYTES,
                totalPhysicalBytes: totalBytes
            ),
            .error
        )
    }

    func testMemorySeverityIsNormalWhenPhysicalMemoryIsUnknown() {
        XCTAssertEqual(
            TerminalResourceUsageFormatter.severity(residentBytes: Fixture.gigabyteBYTES, totalPhysicalBytes: 0),
            .normal
        )
    }

    // MARK: - CPU delta across samples

    func testFirstSampleHasNoCPUPercent() {
        let current = TerminalProcessCounterSample(
            residentBytes: Fixture.megabyteBYTES,
            cpuTimeSeconds: 12,
            uptimeSeconds: 100
        )

        XCTAssertNil(TerminalProcessCPUUsage.percent(
            previous: nil,
            current: current,
            processorCount: Fixture.processorCOUNT
        ))
    }

    func testCPUPercentIsNormalizedAgainstEveryCore() {
        let previous = TerminalProcessCounterSample(residentBytes: 0, cpuTimeSeconds: 10, uptimeSeconds: 100)
        // 8 CPU-seconds over 2 wall seconds on 8 cores is half the machine.
        let current = TerminalProcessCounterSample(residentBytes: 0, cpuTimeSeconds: 18, uptimeSeconds: 102)

        let percent = TerminalProcessCPUUsage.percent(
            previous: previous,
            current: current,
            processorCount: Fixture.processorCOUNT
        )

        XCTAssertEqual(try XCTUnwrap(percent), 50, accuracy: 0.001)
    }

    func testCPUPercentIsNilWhenTheCounterMovesBackwards() {
        // pid reuse after an exit, or a counter wraparound: the delta is
        // meaningless and must not be rendered as a spike or as 0%.
        let previous = TerminalProcessCounterSample(residentBytes: 0, cpuTimeSeconds: 900, uptimeSeconds: 100)
        let current = TerminalProcessCounterSample(residentBytes: 0, cpuTimeSeconds: 3, uptimeSeconds: 102)

        XCTAssertNil(TerminalProcessCPUUsage.percent(
            previous: previous,
            current: current,
            processorCount: Fixture.processorCOUNT
        ))
    }

    func testCPUPercentIsNilWhenNoTimeElapsed() {
        let previous = TerminalProcessCounterSample(residentBytes: 0, cpuTimeSeconds: 10, uptimeSeconds: 100)
        let current = TerminalProcessCounterSample(residentBytes: 0, cpuTimeSeconds: 11, uptimeSeconds: 100)

        XCTAssertNil(TerminalProcessCPUUsage.percent(
            previous: previous,
            current: current,
            processorCount: Fixture.processorCOUNT
        ))
    }

    func testCPUPercentIsClampedToOneHundred() {
        let previous = TerminalProcessCounterSample(residentBytes: 0, cpuTimeSeconds: 0, uptimeSeconds: 100)
        let current = TerminalProcessCounterSample(residentBytes: 0, cpuTimeSeconds: 400, uptimeSeconds: 101)

        XCTAssertEqual(
            try XCTUnwrap(TerminalProcessCPUUsage.percent(
                previous: previous,
                current: current,
                processorCount: Fixture.processorCOUNT
            )),
            100,
            accuracy: 0.001
        )
    }

    func testCPUPercentIsNilWithoutAProcessorCount() {
        let previous = TerminalProcessCounterSample(residentBytes: 0, cpuTimeSeconds: 10, uptimeSeconds: 100)
        let current = TerminalProcessCounterSample(residentBytes: 0, cpuTimeSeconds: 11, uptimeSeconds: 102)

        XCTAssertNil(TerminalProcessCPUUsage.percent(previous: previous, current: current, processorCount: 0))
    }

    // MARK: - Aggregation

    func testAggregationSumsPanesAndSortsByMemoryDescending() {
        let panes = [
            makePaneUsage(identifier: Fixture.paneA, residentBytes: 100 * Fixture.megabyteBYTES, cpuPercent: 4),
            makePaneUsage(identifier: Fixture.paneB, residentBytes: 300 * Fixture.megabyteBYTES, cpuPercent: 11),
        ]

        let usage = TerminalResourceUsageAggregator.aggregate(panes)

        XCTAssertEqual(usage.residentBytes, 400 * Fixture.megabyteBYTES)
        XCTAssertEqual(try XCTUnwrap(usage.cpuPercent), 15, accuracy: 0.001)
        XCTAssertEqual(usage.panes.map(\.paneIdentifier), [Fixture.paneB, Fixture.paneA])
    }

    func testAggregationKeepsCPUUnavailableUntilAnyPaneHasADelta() {
        let panes = [
            makePaneUsage(identifier: Fixture.paneA, residentBytes: Fixture.megabyteBYTES, cpuPercent: nil),
            makePaneUsage(identifier: Fixture.paneB, residentBytes: Fixture.megabyteBYTES, cpuPercent: nil),
        ]

        let usage = TerminalResourceUsageAggregator.aggregate(panes)

        XCTAssertNil(usage.cpuPercent)
        XCTAssertEqual(usage.residentBytes, 2 * Fixture.megabyteBYTES)
    }

    func testAggregationIgnoresPanesWithoutADeltaWhenSumming() {
        let panes = [
            makePaneUsage(identifier: Fixture.paneA, residentBytes: Fixture.megabyteBYTES, cpuPercent: nil),
            makePaneUsage(identifier: Fixture.paneB, residentBytes: Fixture.megabyteBYTES, cpuPercent: 7),
        ]

        XCTAssertEqual(
            try XCTUnwrap(TerminalResourceUsageAggregator.aggregate(panes).cpuPercent),
            7,
            accuracy: 0.001
        )
    }

    func testAggregationOfNoPanesIsEmpty() {
        XCTAssertEqual(TerminalResourceUsageAggregator.aggregate([]), .empty)
        XCTAssertTrue(TerminalWindowResourceUsage.empty.isEmpty)
    }

    // MARK: - Kill policy

    func testKillPolicyRefusesReservedProcessIdentifiers() {
        let owned: Set<pid_t> = [0, 1, Fixture.paneAProcess]

        XCTAssertEqual(
            TerminalProcessKillPolicy.decision(processIdentifier: 0, ownedProcessIdentifiers: owned, isConfirmed: true),
            .refusedReservedProcess
        )
        XCTAssertEqual(
            TerminalProcessKillPolicy.decision(processIdentifier: 1, ownedProcessIdentifiers: owned, isConfirmed: true),
            .refusedReservedProcess
        )
        XCTAssertEqual(
            TerminalProcessKillPolicy.decision(processIdentifier: -1, ownedProcessIdentifiers: owned, isConfirmed: true),
            .refusedReservedProcess
        )
    }

    func testKillPolicyRefusesProcessesTheAppDoesNotOwn() {
        XCTAssertEqual(
            TerminalProcessKillPolicy.decision(
                processIdentifier: Fixture.paneBProcess,
                ownedProcessIdentifiers: [Fixture.paneAProcess],
                isConfirmed: true
            ),
            .refusedUnownedProcess
        )
    }

    func testKillPolicyRequiresConfirmationBeforeTerminating() {
        XCTAssertEqual(
            TerminalProcessKillPolicy.decision(
                processIdentifier: Fixture.paneAProcess,
                ownedProcessIdentifiers: [Fixture.paneAProcess],
                isConfirmed: false
            ),
            .requiresConfirmation
        )
        XCTAssertEqual(
            TerminalProcessKillPolicy.decision(
                processIdentifier: Fixture.paneAProcess,
                ownedProcessIdentifiers: [Fixture.paneAProcess],
                isConfirmed: true
            ),
            .terminate
        )
    }

    // MARK: - Sampling gate

    func testSamplingIsSkippedWhileTheWindowIsOccluded() {
        let context = TerminalStatusBarSamplingContext(
            isWindowVisible: true,
            isWindowOccluded: true,
            paneCount: 2
        )

        XCTAssertFalse(TerminalStatusBarSamplingPolicy.shouldSample(context))
    }

    func testSamplingIsSkippedWhileTheWindowIsHiddenOrHasNoPanes() {
        XCTAssertFalse(TerminalStatusBarSamplingPolicy.shouldSample(
            TerminalStatusBarSamplingContext(isWindowVisible: false, isWindowOccluded: false, paneCount: 2)
        ))
        XCTAssertFalse(TerminalStatusBarSamplingPolicy.shouldSample(
            TerminalStatusBarSamplingContext(isWindowVisible: true, isWindowOccluded: false, paneCount: 0)
        ))
        XCTAssertFalse(TerminalStatusBarSamplingPolicy.shouldSample(
            TerminalStatusBarSamplingContext(
                isWindowVisible: true,
                isWindowOccluded: false,
                paneCount: 2,
                isStatusBarVisible: false
            )
        ))
    }

    func testSamplingRunsForAVisiblePanedWindow() {
        XCTAssertTrue(TerminalStatusBarSamplingPolicy.shouldSample(
            TerminalStatusBarSamplingContext(isWindowVisible: true, isWindowOccluded: false, paneCount: 1)
        ))
    }

    // MARK: - Responsive truncation

    func testWideBarShowsEverything() {
        XCTAssertEqual(TerminalStatusBarLayoutPolicy.visibility(barWidthPX: 1_200), .full)
        XCTAssertEqual(TerminalStatusBarLayoutPolicy.visibility(barWidthPX: 560), .full)
    }

    func testAgentDetailIsTheFirstThingDropped() {
        let visibility = TerminalStatusBarLayoutPolicy.visibility(barWidthPX: 559)

        XCTAssertFalse(visibility.showsAgentDetail)
        XCTAssertTrue(visibility.showsAgentLabel)
        XCTAssertTrue(visibility.showsCPUMetric)
    }

    func testCPUMetricIsDroppedNext() {
        let visibility = TerminalStatusBarLayoutPolicy.visibility(barWidthPX: 439)

        XCTAssertFalse(visibility.showsCPUMetric)
        XCTAssertTrue(visibility.showsAgentLabel)
        XCTAssertTrue(visibility.showsMemoryValue)
    }

    func testAgentLabelIsDroppedNext() {
        let visibility = TerminalStatusBarLayoutPolicy.visibility(barWidthPX: 339)

        XCTAssertFalse(visibility.showsAgentLabel)
        XCTAssertFalse(visibility.showsAgentDetail)
        XCTAssertTrue(visibility.showsMemoryValue)
    }

    func testRightSegmentBecomesIconOnlyAtTheNarrowestBreakpoint() {
        let visibility = TerminalStatusBarLayoutPolicy.visibility(barWidthPX: 239)

        XCTAssertFalse(visibility.showsMemoryValue)
        XCTAssertFalse(visibility.showsCPUMetric)
        XCTAssertFalse(visibility.showsAgentLabel)
        XCTAssertFalse(visibility.showsAgentDetail)
    }

    // MARK: - Agent label composition

    func testWorkingStatusComposesNameStateAndDetail() {
        let summary = TerminalStatusBarAgentComposer.summary(
            statuses: [AgentActivityStatus(state: .working, agentName: "claude", detail: "running tests")],
            areStatusHooksInstalled: true,
            hasEverReported: true,
            language: .english
        )

        XCTAssertEqual(summary.label, "claude · Working")
        XCTAssertEqual(summary.detail, "running tests")
        XCTAssertTrue(summary.showsSpinner)
        XCTAssertEqual(summary.dot, .filled(.working))
        XCTAssertEqual(summary.action, .showStatusHistory)
    }

    func testWaitingBlockedAndDoneStatesMapToTheirOwnDotAndLabel() {
        let waiting = TerminalStatusBarAgentComposer.summary(
            statuses: [AgentActivityStatus(state: .waitingForInput, agentName: "claude")],
            areStatusHooksInstalled: true,
            hasEverReported: true,
            language: .english
        )
        let blocked = TerminalStatusBarAgentComposer.summary(
            statuses: [AgentActivityStatus(state: .blocked, agentName: "claude", detail: "needs approval")],
            areStatusHooksInstalled: true,
            hasEverReported: true,
            language: .english
        )
        let done = TerminalStatusBarAgentComposer.summary(
            statuses: [AgentActivityStatus(state: .done, agentName: "claude")],
            areStatusHooksInstalled: true,
            hasEverReported: true,
            language: .english
        )

        XCTAssertEqual(waiting.label, "claude · Needs input")
        XCTAssertEqual(waiting.dot, .filled(.waiting))
        XCTAssertFalse(waiting.showsSpinner)
        XCTAssertEqual(blocked.label, "claude · Blocked")
        XCTAssertEqual(blocked.dot, .filled(.error))
        XCTAssertEqual(blocked.detail, "needs approval")
        XCTAssertEqual(done.label, "claude · Idle")
        XCTAssertEqual(done.dot, .filled(.idle))
    }

    func testStatusWithoutAnAgentNameUsesTheStateLabelAlone() {
        let summary = TerminalStatusBarAgentComposer.summary(
            statuses: [AgentActivityStatus(state: .working)],
            areStatusHooksInstalled: true,
            hasEverReported: true,
            language: .english
        )

        XCTAssertEqual(summary.label, "Working")
    }

    func testMultipleAgentsShowTheHighestPriorityStateAndACount() {
        let summary = TerminalStatusBarAgentComposer.summary(
            statuses: [
                AgentActivityStatus(state: .working, agentName: "claude"),
                AgentActivityStatus(state: .done, agentName: "codex"),
                AgentActivityStatus(state: .waitingForInput, agentName: "codex"),
            ],
            areStatusHooksInstalled: true,
            hasEverReported: true,
            language: .english
        )

        XCTAssertEqual(summary.label, "codex · Needs input")
        XCTAssertEqual(summary.agentCount, 3)
    }

    func testBlockedOutranksEveryOtherState() {
        let summary = TerminalStatusBarAgentComposer.summary(
            statuses: [
                AgentActivityStatus(state: .waitingForInput, agentName: "codex"),
                AgentActivityStatus(state: .blocked, agentName: "claude"),
                AgentActivityStatus(state: .working, agentName: "claude"),
            ],
            areStatusHooksInstalled: true,
            hasEverReported: true,
            language: .english
        )

        XCTAssertEqual(summary.dot, .filled(.error))
        XCTAssertEqual(summary.label, "claude · Blocked")
    }

    func testNoAgentUsesAHollowRingOnceHooksAreInstalled() {
        let summary = TerminalStatusBarAgentComposer.summary(
            statuses: [],
            areStatusHooksInstalled: true,
            hasEverReported: false,
            language: .english
        )

        XCTAssertEqual(summary.label, "No agent")
        XCTAssertEqual(summary.dot, .hollowRing)
        XCTAssertFalse(summary.isCallToAction)
        XCTAssertEqual(summary.action, .showStatusHistory)
    }

    func testNoAgentUsesAHollowRingAfterAnAgentHasReportedBefore() {
        let summary = TerminalStatusBarAgentComposer.summary(
            statuses: [],
            areStatusHooksInstalled: false,
            hasEverReported: true,
            language: .english
        )

        XCTAssertEqual(summary.dot, .hollowRing)
        XCTAssertEqual(summary.label, "No agent")
    }

    func testHooksDisabledAndNeverConnectedOffersToEnableTheHooks() {
        let summary = TerminalStatusBarAgentComposer.summary(
            statuses: [],
            areStatusHooksInstalled: false,
            hasEverReported: false,
            language: .english
        )

        XCTAssertEqual(summary.label, "Connect an agent")
        XCTAssertEqual(summary.dot, .none)
        XCTAssertTrue(summary.isCallToAction)
        XCTAssertEqual(summary.action, .offerToEnableStatusHooks)
        XCTAssertFalse(summary.tooltip.isEmpty)
    }

    func testAgentStateLabelsAreLocalized() {
        XCTAssertEqual(TerminalStatusBarStrings.stateLabel(for: .working, language: .korean), "작업 중")
        XCTAssertEqual(TerminalStatusBarStrings.stateLabel(for: .waitingForInput, language: .japanese), "入力待ち")
        XCTAssertEqual(TerminalStatusBarStrings.stateLabel(for: .done, language: .english), "Idle")
    }

    // MARK: - Resume lookup

    @MainActor
    func testResumableSessionPicksTheNewestRecordForThePaneDirectory() {
        let older = makeSessionRecord(
            sessionID: "older",
            cwd: Fixture.workingDirectory,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = makeSessionRecord(
            sessionID: "newer",
            cwd: Fixture.workingDirectory,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let elsewhere = makeSessionRecord(
            sessionID: "elsewhere",
            cwd: Fixture.otherWorkingDirectory,
            updatedAt: Date(timeIntervalSince1970: 3_000)
        )

        let record = TerminalStatusBarView.resumableSession(
            forWorkingDirectory: Fixture.workingDirectory,
            records: [older, elsewhere, newer]
        )

        XCTAssertEqual(record?.sessionID, "newer")
    }

    @MainActor
    func testResumableSessionIsNilWithoutAMatchingDirectory() {
        let record = makeSessionRecord(
            sessionID: "elsewhere",
            cwd: Fixture.otherWorkingDirectory,
            updatedAt: Date()
        )

        XCTAssertNil(TerminalStatusBarView.resumableSession(
            forWorkingDirectory: Fixture.workingDirectory,
            records: [record]
        ))
        XCTAssertNil(TerminalStatusBarView.resumableSession(
            forWorkingDirectory: "",
            records: [record]
        ))
    }

    @MainActor
    func testResumeCommandIsInsertedWithoutATrailingNewline() {
        let record = makeSessionRecord(
            sessionID: "abc123",
            cwd: Fixture.workingDirectory,
            updatedAt: Date()
        )

        let command = AgentSessionResumeCommand.command(for: record)

        XCTAssertFalse(command.hasSuffix("\n"))
        XCTAssertTrue(command.contains("--resume abc123"))
    }

    // MARK: - Pane descriptors

    func testPaneDescriptorCarriesPaneIdentityAndProcess() {
        let descriptor = TerminalStatusBarPaneDescriptor(
            paneIdentifier: Fixture.paneA,
            title: Fixture.paneATitle,
            shellProcessIdentifier: Fixture.paneAProcess,
            workingDirectoryPath: Fixture.workingDirectory
        )

        XCTAssertEqual(descriptor.paneIdentifier, Fixture.paneA)
        XCTAssertEqual(descriptor.shellProcessIdentifier, Fixture.paneAProcess)
        XCTAssertEqual(descriptor.workingDirectoryPath, Fixture.workingDirectory)
    }

    // MARK: - Process tree reader

    /// Behavioral evidence that the libproc path actually reads a live tree:
    /// a real child process with a real grandchild is sampled, and a second
    /// sample produces a usable CPU delta.
    func testProcessTreeReaderSamplesARealChildProcessTree() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A grandchild proves the walk descends past the direct child.
        process.arguments = ["-c", "sleep 30 & sleep 30"]
        try process.run()
        defer {
            process.terminate()
        }
        // The shell needs a moment to fork its own child.
        Thread.sleep(forTimeInterval: 0.3)

        let children = TerminalProcessTreeReader.childProcessIdentifiers(of: getpid())
        XCTAssertTrue(children.contains(process.processIdentifier))

        let first = try XCTUnwrap(TerminalProcessTreeReader.sample(
            rootProcessIdentifier: process.processIdentifier,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime
        ))
        XCTAssertGreaterThan(first.residentBytes, 0)

        Thread.sleep(forTimeInterval: 0.1)
        let second = try XCTUnwrap(TerminalProcessTreeReader.sample(
            rootProcessIdentifier: process.processIdentifier,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime
        ))
        let percent = try XCTUnwrap(TerminalProcessCPUUsage.percent(
            previous: first,
            current: second,
            processorCount: ProcessInfo.processInfo.activeProcessorCount
        ))
        XCTAssertGreaterThanOrEqual(percent, 0)
        XCTAssertLessThanOrEqual(percent, 100)
    }

    func testProcessTreeReaderRefusesReservedProcessIdentifiers() {
        XCTAssertNil(TerminalProcessTreeReader.sample(rootProcessIdentifier: 0, uptimeSeconds: 1))
        XCTAssertNil(TerminalProcessTreeReader.sample(rootProcessIdentifier: 1, uptimeSeconds: 1))
    }

    // MARK: - View layout and mounting

    @MainActor
    func testAttachedBarCollapsesToZeroHeightWithoutPanes() {
        let dataSource = StubStatusBarDataSource(descriptors: [])
        let statusBarView = makeStatusBarView(dataSource: dataSource)
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))

        let heightConstraint = statusBarView.attach(to: containerView)
        containerView.layoutSubtreeIfNeeded()

        XCTAssertEqual(heightConstraint.constant, 0)
        XCTAssertTrue(statusBarView.isHidden)
    }

    @MainActor
    func testAttachedBarPinsToTheBottomEdgeAtTheFixedHeight() {
        let dataSource = StubStatusBarDataSource(descriptors: [makeDescriptor()])
        let statusBarView = makeStatusBarView(dataSource: dataSource)
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))

        let heightConstraint = statusBarView.attach(to: containerView)
        containerView.layoutSubtreeIfNeeded()

        XCTAssertEqual(heightConstraint.constant, TerminalStatusBarTokens.heightPX)
        XCTAssertFalse(statusBarView.isHidden)
        XCTAssertEqual(statusBarView.frame.height, TerminalStatusBarTokens.heightPX)
        XCTAssertEqual(statusBarView.frame.width, containerView.frame.width)
        XCTAssertEqual(statusBarView.frame.minY, 0)
    }

    @MainActor
    func testBarKeepsBothSegmentsOnOppositeEdges() throws {
        let dataSource = StubStatusBarDataSource(descriptors: [makeDescriptor()])
        let statusBarView = makeStatusBarView(dataSource: dataSource)
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        statusBarView.attach(to: containerView)
        containerView.layoutSubtreeIfNeeded()

        let segments = statusBarView.subviews.compactMap { $0 as? TerminalStatusBarSegmentView }

        XCTAssertEqual(segments.count, 2)
        let leading = try XCTUnwrap(segments.min { $0.frame.minX < $1.frame.minX })
        let trailing = try XCTUnwrap(segments.max { $0.frame.maxX < $1.frame.maxX })
        XCTAssertEqual(
            leading.frame.minX,
            TerminalStatusBarTokens.horizontalInsetPX - TerminalStatusBarTokens.segmentPaddingXPX
        )
        XCTAssertEqual(
            trailing.frame.maxX,
            statusBarView.frame.width
                - (TerminalStatusBarTokens.horizontalInsetPX - TerminalStatusBarTokens.segmentPaddingXPX)
        )
    }

    @MainActor
    func testBarThemesItselfInLightAndDark() {
        let statusBarView = makeStatusBarView(dataSource: StubStatusBarDataSource(descriptors: []))

        statusBarView.applyChromeTheme(.dark)
        let darkBackground = statusBarView.layer?.backgroundColor
        statusBarView.applyChromeTheme(.light)
        let lightBackground = statusBarView.layer?.backgroundColor

        XCTAssertEqual(darkBackground, DesignTokens.ChromeTheme.dark.topChromeBackground.cgColor)
        XCTAssertEqual(lightBackground, DesignTokens.ChromeTheme.light.topChromeBackground.cgColor)
        XCTAssertNotEqual(darkBackground, lightBackground)
    }

    @MainActor
    func testDisabledBarCollapsesAndStopsSamplingEntirely() {
        let dataSource = StubStatusBarDataSource(descriptors: [makeDescriptor()])
        let statusBarView = makeStatusBarView(dataSource: dataSource)
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let heightConstraint = statusBarView.attach(to: containerView)
        statusBarView.startSampling()

        statusBarView.setEnabled(false)
        containerView.layoutSubtreeIfNeeded()

        XCTAssertFalse(statusBarView.isEnabled)
        XCTAssertEqual(heightConstraint.constant, 0)
        XCTAssertTrue(statusBarView.isHidden)
        // Disabled means no timer at all, not a timer whose ticks are skipped.
        XCTAssertFalse(
            TerminalStatusBarSamplingPolicy.shouldSample(
                TerminalStatusBarSamplingContext(
                    isWindowVisible: true,
                    isWindowOccluded: false,
                    paneCount: 1,
                    isStatusBarVisible: false
                )
            )
        )
    }

    @MainActor
    func testReEnablingTheBarRestoresItsHeight() {
        let dataSource = StubStatusBarDataSource(descriptors: [makeDescriptor()])
        let statusBarView = makeStatusBarView(dataSource: dataSource)
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let heightConstraint = statusBarView.attach(to: containerView)

        statusBarView.setEnabled(false)
        statusBarView.setEnabled(true)
        containerView.layoutSubtreeIfNeeded()

        XCTAssertEqual(heightConstraint.constant, TerminalStatusBarTokens.heightPX)
        XCTAssertFalse(statusBarView.isHidden)
        statusBarView.stopSampling()
    }

    // MARK: - Window mounting

    @MainActor
    func testWindowMountsTheBarAtTheBottomWithTheSplitStoppingAboveIt() throws {
        let controller = makeWindowController()
        let rootView = try XCTUnwrap(controller.window?.contentView)
        rootView.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.statusBarView.isDescendant(of: rootView))
        XCTAssertEqual(controller.statusBarView.frame.minY, rootView.bounds.minY)
        XCTAssertEqual(controller.statusBarView.frame.width, rootView.bounds.width)
        // The bar owns the bottom strip: the split view stops at its top edge
        // instead of running under it, so terminal content is never clipped.
        XCTAssertEqual(
            controller.commandHistorySplitView.frame.minY,
            controller.statusBarView.frame.maxY
        )
    }

    @MainActor
    func testWindowIsTheBarsDataSourceAndReportsItsPanes() throws {
        let controller = makeWindowController()
        let descriptors = controller.statusBarPaneDescriptors()

        XCTAssertTrue(controller.statusBarView.dataSource === controller)
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(
            controller.statusBarActivePaneIdentifier(),
            descriptors.first?.paneIdentifier
        )
    }

    @MainActor
    func testSplittingAPaneGrowsTheReportedPaneSet() {
        let controller = makeWindowController()
        XCTAssertEqual(controller.statusBarPaneDescriptors().count, 1)

        controller.splitVertically()

        XCTAssertEqual(controller.statusBarPaneDescriptors().count, 2)
    }

    @MainActor
    func testSamplingContextFollowsWindowVisibility() {
        let controller = makeWindowController()

        let hiddenContext = controller.statusBarSamplingContext()

        XCTAssertFalse(hiddenContext.isWindowVisible)
        XCTAssertTrue(hiddenContext.isStatusBarVisible)
        XCTAssertEqual(hiddenContext.paneCount, 1)
        XCTAssertFalse(TerminalStatusBarSamplingPolicy.shouldSample(hiddenContext))
    }

    /// The bar never executes a command: the resume row inserts text on the
    /// prompt and the user presses Return themselves.
    @MainActor
    func testWindowInsertTextRoutesThroughTheInsertOnlyPath() throws {
        let statusBarSource = try statusBarWindowSource()
        XCTAssertTrue(statusBarSource.contains("func statusBarInsertText(_ text: String, paneIdentifier: String) {"))
        XCTAssertTrue(statusBarSource.contains("sendTextToActivePane(text)"))
        XCTAssertFalse(statusBarSource.contains("sendTextToActivePane(text + \"\\n\")"))
    }

    @MainActor
    func testWindowStartsAndStopsSamplingWithTheWindowLifecycle() throws {
        let statusBarSource = try statusBarWindowSource()
        XCTAssertTrue(statusBarSource.contains("override func showWindow(_ sender: Any?)"))
        XCTAssertTrue(statusBarSource.contains("func windowDidBecomeMain(_ notification: Notification)"))
        XCTAssertTrue(statusBarSource.contains("func windowWillClose(_ notification: Notification)"))
        XCTAssertTrue(statusBarSource.contains("func windowDidChangeOcclusionState(_ notification: Notification)"))
        XCTAssertTrue(statusBarSource.contains("func windowDidMiniaturize(_ notification: Notification)"))
        XCTAssertTrue(statusBarSource.contains("func windowDidDeminiaturize(_ notification: Notification)"))
        XCTAssertTrue(statusBarSource.contains("statusBarView.startSampling()"))
        XCTAssertTrue(statusBarSource.contains("statusBarView.stopSampling()"))
        XCTAssertTrue(statusBarSource.contains("statusBarView.windowVisibilityDidChange()"))
    }

    private func statusBarWindowSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KurottyApp/TerminalWindowStatusBar.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @MainActor
    private func makeWindowController() -> TerminalWindowController {
        let session = TmuxPaneSession(
            writeHandler: { _ in },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let controller = TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: session),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        addTeardownBlock { @MainActor in
            controller.statusBarView.stopSampling()
        }
        return controller
    }

    // MARK: - Fixtures

    @MainActor
    private func makeStatusBarView(dataSource: StubStatusBarDataSource) -> TerminalStatusBarView {
        let statusBarView = TerminalStatusBarView(
            registry: AgentActivityRegistry(),
            sessionIndexStore: AgentSessionIndexStore(
                isIndexingEnabled: false,
                observesSettingsChanges: false
            )
        )
        statusBarView.areStatusHooksInstalledProvider = { false }
        statusBarView.dataSource = dataSource
        // The bar holds its data source weakly, so the test owns the stub.
        retainedDataSources.append(dataSource)
        return statusBarView
    }

    private func makeDescriptor() -> TerminalStatusBarPaneDescriptor {
        TerminalStatusBarPaneDescriptor(
            paneIdentifier: Fixture.paneA,
            title: Fixture.paneATitle,
            shellProcessIdentifier: Fixture.paneAProcess,
            workingDirectoryPath: Fixture.workingDirectory
        )
    }

    private func makePaneUsage(
        identifier: String,
        residentBytes: UInt64,
        cpuPercent: Double?
    ) -> TerminalPaneResourceUsage {
        TerminalPaneResourceUsage(
            paneIdentifier: identifier,
            title: identifier == Fixture.paneA ? Fixture.paneATitle : Fixture.paneBTitle,
            processIdentifier: identifier == Fixture.paneA ? Fixture.paneAProcess : Fixture.paneBProcess,
            residentBytes: residentBytes,
            cpuPercent: cpuPercent
        )
    }

    private func makeSessionRecord(
        sessionID: String,
        cwd: String,
        updatedAt: Date
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            agent: .claudeCode,
            sessionID: sessionID,
            title: "session",
            cwd: cwd,
            updatedAt: updatedAt,
            createdAt: updatedAt,
            messageCount: 1,
            filePath: "/tmp/\(sessionID).jsonl"
        )
    }
}
