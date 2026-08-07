import AppKit
import KurottyCore
import XCTest

@testable import KurottyApp

/// The prompt navigator rail, exercised through its own API.
///
/// The behaviours worth pinning are: a command span maps to a scrollback row
/// and back, marks land where the rows are, the rail stays readable at every
/// density it claims to support, exit status is encoded in the colour, a click
/// resolves to the row the marker named, and the rail never shares pixels with
/// the scrollback indicator it sits beside.
@MainActor
final class TerminalPromptRailTests: XCTestCase {
    private let trackHeightPX: CGFloat = 600
    private let hostWidthPX: CGFloat = 400

    private func makeEntry(
        commandText: String = "swift build",
        exitCode: Int? = 0,
        finishedAt: Date = Date()
    ) -> TerminalCommandHistoryEntry {
        TerminalCommandHistoryEntry(
            commandText: commandText,
            cwd: "/tmp",
            exitCode: exitCode,
            finishedAt: finishedAt
        )
    }

    private func makeMarker(
        spanID: Int,
        absoluteRowIndex: Int,
        exitCode: Int? = 0,
        commandText: String = "swift build",
        finishedAt: Date = Date()
    ) -> TerminalPromptRailMarker {
        TerminalPromptRailMarker(
            spanID: spanID,
            absoluteRowIndex: absoluteRowIndex,
            entry: makeEntry(commandText: commandText, exitCode: exitCode, finishedAt: finishedAt)
        )
    }

    /// `commandCount` commands spread evenly over `contentRowCount` rows, which
    /// is what a long session looks like: commands arrive at a roughly steady
    /// rate and each one leaves output behind it.
    private func makeEvenlySpacedMarkers(
        commandCount: Int,
        contentRowCount: Int,
        failingEvery: Int? = nil
    ) -> [TerminalPromptRailMarker] {
        (0..<commandCount).map { index in
            let row = Int((Double(index) / Double(commandCount)) * Double(contentRowCount))
            let didFail = failingEvery.map { index % $0 == 0 } ?? false
            return makeMarker(spanID: index + 1, absoluteRowIndex: row, exitCode: didFail ? 1 : 0)
        }
    }

    private func makeLayout(
        markers: [TerminalPromptRailMarker],
        contentRowCount: Int,
        firstRetainedRowIndex: Int = 0,
        heightPX: CGFloat? = nil
    ) -> TerminalPromptRailLayout {
        let bounds = NSRect(x: 0, y: 0, width: hostWidthPX, height: heightPX ?? trackHeightPX)
        guard let layout = TerminalPromptRailLayout.layout(
            markers: markers,
            in: bounds,
            contentRowCount: contentRowCount,
            firstRetainedRowIndex: firstRetainedRowIndex
        ) else {
            XCTFail("expected a layout for \(markers.count) markers")
            fatalError("unreachable")
        }
        return layout
    }

    // MARK: - Span to row

    /// The crux: a `TerminalCommandSpan` carries boundary sequence numbers, not
    /// rows, so the rail anchors on the absolute scrollback index instead. That
    /// index survives trimming, which a content-row index does not.
    func testAnAbsoluteRowSurvivesTrimmingWhileAContentRowWouldNot() {
        let marker = makeMarker(spanID: 1, absoluteRowIndex: 1_200)

        // Before trimming: 1,200 absolute is content row 1,200.
        let untrimmed = makeLayout(markers: [marker], contentRowCount: 2_000, firstRetainedRowIndex: 0)
        // After 500 rows fell off the front, the same command is content row 700.
        let trimmed = makeLayout(markers: [marker], contentRowCount: 1_500, firstRetainedRowIndex: 500)

        XCTAssertEqual(untrimmed.clusters.count, 1)
        XCTAssertEqual(trimmed.clusters.count, 1)
        // Same absolute row, same fraction of the document, so the same slot:
        // 1200/2000 and 700/1500 are different fractions, so the mark moves —
        // which is correct, because the document in front of it got shorter.
        XCTAssertEqual(untrimmed.clusters[0].anchorAbsoluteRowIndex, 1_200)
        XCTAssertEqual(trimmed.clusters[0].anchorAbsoluteRowIndex, 1_200)
        XCTAssertLessThan(trimmed.clusters[0].slotIndex, untrimmed.clusters[0].slotIndex)
    }

    func testAMarkerTrimmedOutOfTheScrollbackIsDroppedRatherThanPinnedToRowZero() {
        let markers = [
            makeMarker(spanID: 1, absoluteRowIndex: 10),
            makeMarker(spanID: 2, absoluteRowIndex: 900),
        ]
        let layout = makeLayout(markers: markers, contentRowCount: 1_000, firstRetainedRowIndex: 500)

        XCTAssertEqual(layout.clusters.flatMap(\.spanIDs), [2])
    }

    func testStoreDropsMarkersBelowTheFirstRetainedRow() {
        var store = TerminalPromptRailStore()
        store.append(makeMarker(spanID: 1, absoluteRowIndex: 10))
        store.append(makeMarker(spanID: 2, absoluteRowIndex: 900))

        store.reconcile(firstRetainedRowIndex: 500, nextRowIndex: 1_000)

        XCTAssertEqual(store.markers.map(\.spanID), [2])
    }

    /// ED 3 replaces the whole scrollback store, which restarts the absolute
    /// row counter at zero. Every stored row then aliases a different line, so
    /// the only correct answer is to forget them.
    func testStoreForgetsEverythingWhenTheAbsoluteRowSpaceRestarts() {
        var store = TerminalPromptRailStore()
        store.append(makeMarker(spanID: 1, absoluteRowIndex: 900))
        store.reconcile(firstRetainedRowIndex: 0, nextRowIndex: 1_000)
        XCTAssertEqual(store.markers.count, 1)

        store.reconcile(firstRetainedRowIndex: 0, nextRowIndex: 0)

        XCTAssertTrue(store.isEmpty)
    }

    func testStoreEvictsOldestMarkersAtCapacity() {
        var store = TerminalPromptRailStore(capacityCOUNT: 3)
        for index in 1...5 {
            store.append(makeMarker(spanID: index, absoluteRowIndex: index * 10))
        }

        XCTAssertEqual(store.markers.map(\.spanID), [3, 4, 5])
    }

    // MARK: - Marker positions

    func testMarkerPositionsForAKnownSetOfSpans() {
        // Four commands at the quarter points of a 1,000-row document, on a
        // 600pt track with a 5pt minimum pitch: 120 slots of exactly 5pt.
        let markers = [
            makeMarker(spanID: 1, absoluteRowIndex: 0),
            makeMarker(spanID: 2, absoluteRowIndex: 250),
            makeMarker(spanID: 3, absoluteRowIndex: 500),
            makeMarker(spanID: 4, absoluteRowIndex: 999),
        ]
        let layout = makeLayout(markers: markers, contentRowCount: 1_000)

        XCTAssertEqual(layout.slotHeightPX, 5, accuracy: 0.0001)
        XCTAssertEqual(layout.clusters.map(\.slotIndex), [0, 30, 60, 119])
        // Oldest at the top, newest at the bottom: the surface is not flipped,
        // so this is the same axis the scroll thumb already uses.
        XCTAssertEqual(layout.clusters[0].hitFrame.maxY, trackHeightPX, accuracy: 0.0001)
        XCTAssertEqual(layout.clusters[3].hitFrame.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.clusters[1].hitFrame.midY, trackHeightPX - 152.5, accuracy: 0.0001)
        for cluster in layout.clusters {
            XCTAssertEqual(cluster.frame.height, DesignTokens.Component.terminalPromptRailMarkerHeightPX)
            XCTAssertEqual(cluster.frame.midY, cluster.hitFrame.midY, accuracy: 0.0001)
        }
    }

    func testTheTrackHugsTheTrailingEdge() {
        let layout = makeLayout(
            markers: [makeMarker(spanID: 1, absoluteRowIndex: 5)],
            contentRowCount: 100
        )

        XCTAssertEqual(layout.trackFrame.maxX, hostWidthPX)
        XCTAssertEqual(layout.trackFrame.width, DesignTokens.Component.terminalPromptRailWidthPX)
        XCTAssertEqual(layout.trackFrame.height, trackHeightPX)
    }

    func testNoLayoutWithoutMarkersOrContent() {
        let bounds = NSRect(x: 0, y: 0, width: hostWidthPX, height: trackHeightPX)
        XCTAssertNil(TerminalPromptRailLayout.layout(
            markers: [],
            in: bounds,
            contentRowCount: 100,
            firstRetainedRowIndex: 0
        ))
        XCTAssertNil(TerminalPromptRailLayout.layout(
            markers: [makeMarker(spanID: 1, absoluteRowIndex: 0)],
            in: bounds,
            contentRowCount: 0,
            firstRetainedRowIndex: 0
        ))
    }

    // MARK: - Density

    /// 50 commands: one mark each, every mark its own command, no clustering.
    func testFiftyCommandsDrawFiftyDiscreteMarks() {
        let markers = makeEvenlySpacedMarkers(commandCount: 50, contentRowCount: 5_000)
        let layout = makeLayout(markers: markers, contentRowCount: 5_000)

        XCTAssertEqual(layout.mode, .discrete)
        XCTAssertEqual(layout.clusters.count, 50)
        XCTAssertEqual(layout.clusters.reduce(0) { $0 + $1.markerCount }, 50)
        XCTAssertTrue(layout.clusters.allSatisfy(\.isSingleton))
    }

    /// 500 commands over a 120-slot rail: marks cluster, and a cluster is drawn
    /// wider than a singleton so the two remain distinguishable at 3pt.
    func testFiveHundredCommandsClusterAndStayCountable() {
        let markers = makeEvenlySpacedMarkers(commandCount: 500, contentRowCount: 10_000)
        let layout = makeLayout(markers: markers, contentRowCount: 10_000)

        XCTAssertEqual(layout.mode, .clustered)
        XCTAssertLessThanOrEqual(layout.clusters.count, 120)
        XCTAssertEqual(layout.clusters.reduce(0) { $0 + $1.markerCount }, 500)
        let clustered = layout.clusters.filter { !$0.isSingleton }
        XCTAssertFalse(clustered.isEmpty)
        XCTAssertTrue(
            clustered.allSatisfy { $0.frame.width == layout.trackFrame.width },
            "a cluster fills the track width"
        )
        let maximumFanout = layout.clusters.map(\.markerCount).max() ?? 0
        XCTAssertLessThanOrEqual(maximumFanout, DesignTokens.Component.terminalPromptRailClusterFanoutLIMIT)
    }

    /// 5,000 commands: counting marks is hopeless, so the rail drops to a
    /// density wash. The mark count is still bounded by the track.
    func testFiveThousandCommandsFallBackToADensityHeat() {
        let markers = makeEvenlySpacedMarkers(commandCount: 5_000, contentRowCount: 20_000)
        let layout = makeLayout(markers: markers, contentRowCount: 20_000)

        XCTAssertEqual(layout.mode, .heat)
        XCTAssertLessThanOrEqual(layout.clusters.count, 120)
        XCTAssertEqual(layout.clusters.reduce(0) { $0 + $1.markerCount }, 5_000)
        XCTAssertGreaterThan(layout.clusters.map(\.markerCount).max() ?? 0, DesignTokens.Component.terminalPromptRailClusterFanoutLIMIT)
        XCTAssertTrue(layout.clusters.allSatisfy { $0.densityRATIO > 0 && $0.densityRATIO <= 1 })
    }

    /// The failure mode this feature is judged on: a rail that becomes a solid
    /// stripe has stopped saying anything. At every density the marks together
    /// ink at most 3/5 of the track and never touch.
    func testTheRailNeverBecomesASolidStripeAtAnyDensity() {
        let densities = [
            (commandCount: 50, contentRowCount: 5_000),
            (commandCount: 500, contentRowCount: 10_000),
            (commandCount: 5_000, contentRowCount: 20_000),
        ]
        for density in densities {
            let markers = makeEvenlySpacedMarkers(
                commandCount: density.commandCount,
                contentRowCount: density.contentRowCount
            )
            let layout = makeLayout(markers: markers, contentRowCount: density.contentRowCount)
            let inkedRatio = layout.inkedHeightPX / trackHeightPX
            let markHeight = DesignTokens.Component.terminalPromptRailMarkerHeightPX
            let slotHeight = DesignTokens.Component.terminalPromptRailSlotHeightPX

            XCTAssertLessThanOrEqual(
                inkedRatio,
                markHeight / slotHeight,
                "\(density.commandCount) commands inked \(inkedRatio) of the track"
            )
            let sorted = layout.clusters.sorted { $0.frame.minY < $1.frame.minY }
            for (lower, upper) in zip(sorted, sorted.dropFirst()) {
                XCTAssertGreaterThanOrEqual(
                    upper.frame.minY - lower.frame.maxY,
                    slotHeight - markHeight,
                    "\(density.commandCount) commands left no gap between marks"
                )
            }
        }
    }

    // MARK: - Exit status encoding

    func testASlotWithAnyFailureReportsIt() {
        let markers = [
            makeMarker(spanID: 1, absoluteRowIndex: 0, exitCode: 0),
            makeMarker(spanID: 2, absoluteRowIndex: 1, exitCode: 127),
            makeMarker(spanID: 3, absoluteRowIndex: 2, exitCode: 0),
        ]
        let layout = makeLayout(markers: markers, contentRowCount: 1_000)

        XCTAssertEqual(layout.clusters.count, 1)
        XCTAssertEqual(layout.clusters[0].markerCount, 3)
        XCTAssertEqual(layout.clusters[0].failedCount, 1)
        XCTAssertTrue(layout.clusters[0].hasFailure)
    }

    func testAMissingExitCodeIsNotAFailure() {
        XCTAssertFalse(makeMarker(spanID: 1, absoluteRowIndex: 0, exitCode: nil).didFail)
        XCTAssertFalse(makeMarker(spanID: 2, absoluteRowIndex: 0, exitCode: 0).didFail)
        XCTAssertTrue(makeMarker(spanID: 3, absoluteRowIndex: 0, exitCode: 1).didFail)
    }

    func testStatusColorsComeFromTheThemeRampInBothThemes() {
        for theme in [DesignTokens.ChromeTheme.dark, .light] {
            let railView = TerminalPromptRailView(frame: NSRect(x: 0, y: 0, width: 6, height: trackHeightPX))
            railView.chromeTheme = theme
            let layout = makeLayout(
                markers: [
                    makeMarker(spanID: 1, absoluteRowIndex: 0, exitCode: 0),
                    makeMarker(spanID: 2, absoluteRowIndex: 900, exitCode: 1),
                ],
                contentRowCount: 1_000
            )
            railView.apply(layout)

            let successCluster = layout.clusters.first { !$0.hasFailure }
            let failureCluster = layout.clusters.first(where: \.hasFailure)
            XCTAssertNotNil(successCluster)
            XCTAssertNotNil(failureCluster)
            XCTAssertEqual(railView.markColorForTesting(failureCluster!), theme.error)
            XCTAssertEqual(
                railView.markColorForTesting(successCluster!),
                theme.success.withAlphaComponent(DesignTokens.Color.promptRailSuccessAlphaRATIO)
            )
        }
    }

    /// A failure must not fade out with density: the whole point of the heat
    /// regime is that the red stays findable in a column of green.
    func testAFailureStaysOpaqueEvenInTheHeatRegime() {
        var markers = makeEvenlySpacedMarkers(commandCount: 5_000, contentRowCount: 20_000)
        markers.append(makeMarker(spanID: 90_001, absoluteRowIndex: 19_999, exitCode: 2))
        let layout = makeLayout(markers: markers, contentRowCount: 20_000)
        XCTAssertEqual(layout.mode, .heat)

        let railView = TerminalPromptRailView(frame: NSRect(x: 0, y: 0, width: 6, height: trackHeightPX))
        railView.chromeTheme = .dark
        railView.apply(layout)

        let failureCluster = layout.clusters.first(where: \.hasFailure)
        XCTAssertNotNil(failureCluster)
        XCTAssertEqual(railView.markColorForTesting(failureCluster!), DesignTokens.ChromeTheme.dark.error)
    }

    func testTheHeatWashScalesWithDensityAndStaysVisible() {
        let markers = makeEvenlySpacedMarkers(commandCount: 5_000, contentRowCount: 20_000)
        let layout = makeLayout(markers: markers, contentRowCount: 20_000)
        let railView = TerminalPromptRailView(frame: NSRect(x: 0, y: 0, width: 6, height: trackHeightPX))
        railView.chromeTheme = .dark
        railView.apply(layout)

        for cluster in layout.clusters where !cluster.hasFailure {
            let alpha = railView.markColorForTesting(cluster).alphaComponent
            XCTAssertGreaterThanOrEqual(alpha, DesignTokens.Color.promptRailHeatMinAlphaRATIO - 0.0001)
            XCTAssertLessThanOrEqual(alpha, DesignTokens.Color.promptRailHeatMaxAlphaRATIO + 0.0001)
        }
        let busiest = layout.clusters.max { $0.densityRATIO < $1.densityRATIO }
        let quietest = layout.clusters.min { $0.densityRATIO < $1.densityRATIO }
        XCTAssertNotNil(busiest)
        XCTAssertNotNil(quietest)
        XCTAssertGreaterThanOrEqual(
            railView.markColorForTesting(busiest!).alphaComponent,
            railView.markColorForTesting(quietest!).alphaComponent
        )
    }

    // MARK: - Hit-testing

    func testAClickOnAMarkResolvesToItsCluster() {
        let layout = makeLayout(
            markers: [
                makeMarker(spanID: 1, absoluteRowIndex: 0),
                makeMarker(spanID: 2, absoluteRowIndex: 500),
                makeMarker(spanID: 3, absoluteRowIndex: 999),
            ],
            contentRowCount: 1_000
        )

        for cluster in layout.clusters {
            XCTAssertEqual(layout.cluster(atY: cluster.hitFrame.midY)?.slotIndex, cluster.slotIndex)
        }
    }

    /// The rail's edges: the top pixel belongs to the oldest marker and the
    /// bottom pixel to the newest, with no dead band at either end.
    func testHitTestingAtTheRailEdges() {
        let layout = makeLayout(
            markers: [
                makeMarker(spanID: 1, absoluteRowIndex: 0),
                makeMarker(spanID: 2, absoluteRowIndex: 999),
            ],
            contentRowCount: 1_000
        )

        XCTAssertEqual(layout.cluster(atY: trackHeightPX)?.spanIDs, [1])
        XCTAssertEqual(layout.cluster(atY: trackHeightPX - 0.5)?.spanIDs, [1])
        XCTAssertEqual(layout.cluster(atY: 0)?.spanIDs, [2])
        XCTAssertEqual(layout.cluster(atY: 0.5)?.spanIDs, [2])
    }

    func testAClickFarFromEveryMarkResolvesToNothing() {
        let layout = makeLayout(
            markers: [makeMarker(spanID: 1, absoluteRowIndex: 0)],
            contentRowCount: 1_000
        )

        // Slot 0 is the top 5pt; the tolerance reaches 1.5 slots past its
        // centre, so the middle of the track is well outside it.
        XCTAssertNil(layout.cluster(atY: trackHeightPX / 2))
    }

    func testAClickMapsToTheOldestRowInItsCluster() {
        let layout = makeLayout(
            markers: [
                makeMarker(spanID: 1, absoluteRowIndex: 300),
                makeMarker(spanID: 2, absoluteRowIndex: 302),
                makeMarker(spanID: 3, absoluteRowIndex: 304),
            ],
            contentRowCount: 1_000
        )

        XCTAssertEqual(layout.clusters.count, 1)
        XCTAssertEqual(layout.cluster(atY: layout.clusters[0].hitFrame.midY)?.anchorAbsoluteRowIndex, 300)
    }

    func testClickingTheRailViewReportsTheAnchorRow() {
        let railView = TerminalPromptRailView(frame: NSRect(x: 0, y: 0, width: 6, height: trackHeightPX))
        let layout = makeLayout(
            markers: [
                makeMarker(spanID: 1, absoluteRowIndex: 0),
                makeMarker(spanID: 2, absoluteRowIndex: 750),
            ],
            contentRowCount: 1_000
        )
        railView.apply(layout)
        var reportedRows: [Int] = []
        railView.onSelectAbsoluteRow = { reportedRows.append($0) }

        let target = layout.clusters.first { $0.spanIDs == [2] }
        XCTAssertNotNil(target)
        railView.selectForTesting(atY: target!.hitFrame.midY)

        XCTAssertEqual(reportedRows, [750])
    }

    // MARK: - Click scrolls to the expected row

    /// A click names an absolute row; the surface turns it into a scrollback
    /// offset through the same converter search already uses.
    func testAnAnchorRowResolvesToTheScrollbackOffsetThatRevealsIt() {
        // 1,000 content rows, 24 visible: the bottom of the document starts at
        // row 976, and revealing row 300 means scrolling up 676 rows.
        let offset = TerminalSearchNavigation.scrollbackOffsetToReveal(
            row: 300,
            contentRowCount: 1_000,
            visibleRowCount: 24,
            currentOffset: 0
        )

        XCTAssertEqual(offset, 676)
    }

    func testAnAnchorRowAlreadyOnScreenDoesNotMoveTheViewport() {
        let offset = TerminalSearchNavigation.scrollbackOffsetToReveal(
            row: 980,
            contentRowCount: 1_000,
            visibleRowCount: 24,
            currentOffset: 0
        )

        XCTAssertEqual(offset, 0)
    }

    // MARK: - Keyboard navigation

    func testPreviousAndNextPromptWalkTheMarkerRows() {
        let markers = [
            makeMarker(spanID: 1, absoluteRowIndex: 100),
            makeMarker(spanID: 2, absoluteRowIndex: 400),
            makeMarker(spanID: 3, absoluteRowIndex: 700),
        ]

        func target(from row: Int, _ direction: TerminalPromptRailNavigation.Direction) -> Int? {
            TerminalPromptRailNavigation.targetContentRow(
                markers: markers,
                firstRetainedRowIndex: 0,
                contentRowCount: 1_000,
                currentTopContentRow: row,
                direction: direction
            )
        }

        XCTAssertEqual(target(from: 500, .previous), 400)
        XCTAssertEqual(target(from: 400, .previous), 100)
        XCTAssertEqual(target(from: 100, .previous), nil)
        XCTAssertEqual(target(from: 500, .next), 700)
        XCTAssertEqual(target(from: 700, .next), nil)
    }

    func testNavigationIgnoresMarkersThatHaveBeenTrimmedAway() {
        let markers = [
            makeMarker(spanID: 1, absoluteRowIndex: 100),
            makeMarker(spanID: 2, absoluteRowIndex: 700),
        ]

        let target = TerminalPromptRailNavigation.targetContentRow(
            markers: markers,
            firstRetainedRowIndex: 400,
            contentRowCount: 600,
            currentTopContentRow: 500,
            direction: .previous
        )

        // Row 100 is gone; row 700 becomes content row 300, which is above the
        // viewport, so it is the answer.
        XCTAssertEqual(target, 300)
    }

    // MARK: - Hover popover

    func testThePopoverListsCommandsNewestFirstWithTheHistoryFormatting() {
        let now = Date()
        let markers = [
            makeMarker(
                spanID: 1,
                absoluteRowIndex: 10,
                exitCode: 0,
                commandText: "git status",
                finishedAt: now.addingTimeInterval(-7_200)
            ),
            makeMarker(
                spanID: 2,
                absoluteRowIndex: 20,
                exitCode: 1,
                commandText: "swift test",
                finishedAt: now.addingTimeInterval(-180)
            ),
        ]

        let content = TerminalPromptRailPopoverContent.rows(
            forSpanIDs: [1, 2],
            markers: markers,
            now: now,
            limit: 6
        )

        XCTAssertEqual(content.overflowCOUNT, 0)
        XCTAssertEqual(content.rows.map(\.spanID), [2, 1])
        XCTAssertEqual(content.rows[0].commandText, "swift test")
        // Exactly what the history sidebar renders for the same entry.
        XCTAssertEqual(
            content.rows[0].detail,
            TerminalCommandHistoryRowBuilder.trailingDetailLabel(for: markers[1].entry, now: now)
        )
        XCTAssertEqual(content.rows[0].detail, "3m · 1")
        XCTAssertTrue(content.rows[0].didFail)
        XCTAssertEqual(content.rows[1].detail, "2h")
        XCTAssertFalse(content.rows[1].didFail)
    }

    func testThePopoverReportsWhatItTruncated() {
        let markers = (1...10).map { makeMarker(spanID: $0, absoluteRowIndex: $0) }

        let content = TerminalPromptRailPopoverContent.rows(
            forSpanIDs: markers.map(\.spanID),
            markers: markers,
            now: Date(),
            limit: 4
        )

        XCTAssertEqual(content.rows.count, 4)
        XCTAssertEqual(content.overflowCOUNT, 6)
    }

    /// Laid-out frames, not constraints: the row has to actually place the
    /// command text and the trailing detail without overlapping them.
    func testPopoverRowsLayOutWithoutOverlapping() {
        let popover = TerminalPromptRailPopoverView(frame: .zero)
        let now = Date()
        let markers = [
            makeMarker(spanID: 1, absoluteRowIndex: 10, exitCode: 1, commandText: "swift build --very-long-target-name", finishedAt: now.addingTimeInterval(-300)),
            makeMarker(spanID: 2, absoluteRowIndex: 20, exitCode: 0, commandText: "ls", finishedAt: now),
        ]
        let content = TerminalPromptRailPopoverContent.rows(
            forSpanIDs: [1, 2],
            markers: markers,
            now: now,
            limit: 6
        )

        popover.present(rows: content.rows, overflowCOUNT: 0)
        popover.layoutSubtreeIfNeeded()

        XCTAssertFalse(popover.isHidden)
        XCTAssertEqual(popover.displayedRows.map(\.spanID), [2, 1])
        XCTAssertEqual(popover.frame.width, DesignTokens.Component.terminalPromptRailPopoverWidthPX)
        let rowViews = popover.subviews
            .flatMap(\.subviews)
            .compactMap { $0 as? TerminalPromptRailPopoverRowView }
            .filter { !$0.isHidden }
        XCTAssertEqual(rowViews.count, 2)
        for rowView in rowViews {
            let commandFrame = rowView.commandLabelForTesting.frame
            let detailFrame = rowView.detailLabelForTesting.frame
            XCTAssertGreaterThan(rowView.frame.height, 0)
            XCTAssertGreaterThan(detailFrame.width, 0)
            XCTAssertLessThanOrEqual(
                commandFrame.maxX,
                detailFrame.minX,
                "the command text overlapped its trailing detail"
            )
        }
    }

    func testAnEmptyHoverDismissesThePopover() {
        let popover = TerminalPromptRailPopoverView(frame: .zero)
        popover.present(
            rows: [TerminalPromptRailPopoverRow(spanID: 1, commandText: "ls", detail: "now", didFail: false)],
            overflowCOUNT: 0
        )
        XCTAssertFalse(popover.isHidden)

        popover.dismiss()

        XCTAssertTrue(popover.isHidden)
        XCTAssertTrue(popover.displayedRows.isEmpty)
    }

    // MARK: - Coexistence with the scrollback indicator

    /// The bug that was already removed once: two controls sharing one strip.
    /// The rail takes the trailing edge, the indicator's track slides inboard
    /// by exactly the rail's width, and the two frames do not intersect.
    func testTheRailAndTheScrollThumbNeverShareAPixel() {
        let bounds = NSRect(x: 0, y: 0, width: hostWidthPX, height: trackHeightPX)
        let railLayout = makeLayout(
            markers: [makeMarker(spanID: 1, absoluteRowIndex: 500)],
            contentRowCount: 1_000
        )
        let indicatorMetrics = TerminalScrollIndicatorMetrics.metrics(
            in: bounds,
            visibleRows: 24,
            maxScrollbackOffset: 976,
            scrollbackOffset: 400,
            trailingInsetPX: DesignTokens.Component.terminalPromptRailWidthPX
        )

        XCTAssertNotNil(indicatorMetrics)
        XCTAssertFalse(railLayout.trackFrame.intersects(indicatorMetrics!.trackFrame))
        XCTAssertEqual(indicatorMetrics!.trackFrame.maxX, railLayout.trackFrame.minX)
        XCTAssertFalse(railLayout.trackFrame.intersects(indicatorMetrics!.thumbFrame))
    }

    func testWithoutARailTheIndicatorKeepsItsOriginalTrack() {
        let bounds = NSRect(x: 0, y: 0, width: hostWidthPX, height: trackHeightPX)
        let metrics = TerminalScrollIndicatorMetrics.metrics(
            in: bounds,
            visibleRows: 24,
            maxScrollbackOffset: 976,
            scrollbackOffset: 0
        )

        XCTAssertEqual(metrics?.trackFrame.maxX, hostWidthPX)
    }

    func testCoordinatorReservesNoWidthUntilItHasSomethingToDraw() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: hostWidthPX, height: trackHeightPX))
        let coordinator = TerminalPromptRailCoordinator(chromeTheme: .dark, isEnabled: true)
        coordinator.install(in: host)

        coordinator.update(bounds: host.bounds, contentRowCount: 1_000, firstRetainedRowIndex: 0, nextRowIndex: 900)
        XCTAssertEqual(coordinator.trailingInsetPX, 0)

        coordinator.record(makeMarker(spanID: 1, absoluteRowIndex: 500))
        coordinator.update(bounds: host.bounds, contentRowCount: 1_000, firstRetainedRowIndex: 0, nextRowIndex: 900)
        XCTAssertEqual(coordinator.trailingInsetPX, DesignTokens.Component.terminalPromptRailWidthPX)
    }

    func testCoordinatorPlacesTheRailFlushToTheTrailingEdge() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: hostWidthPX, height: trackHeightPX))
        let coordinator = TerminalPromptRailCoordinator(chromeTheme: .dark, isEnabled: true)
        coordinator.install(in: host)
        coordinator.record(makeMarker(spanID: 1, absoluteRowIndex: 500))

        coordinator.update(bounds: host.bounds, contentRowCount: 1_000, firstRetainedRowIndex: 0, nextRowIndex: 900)

        let railView = coordinator.railViewForTesting
        XCTAssertFalse(railView.isHidden)
        XCTAssertEqual(railView.frame.maxX, hostWidthPX)
        XCTAssertEqual(railView.frame.width, DesignTokens.Component.terminalPromptRailWidthPX)
        XCTAssertEqual(railView.frame.height, trackHeightPX)
        // Marks come back in the rail's own coordinates, not the host's.
        XCTAssertEqual(railView.layoutModel?.trackFrame.minX, 0)
        XCTAssertTrue(railView.layoutModel?.clusters.allSatisfy { $0.frame.minX >= 0 } == true)
    }

    func testADisabledCoordinatorDrawsNothingAndForgetsItsMarkers() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: hostWidthPX, height: trackHeightPX))
        let coordinator = TerminalPromptRailCoordinator(chromeTheme: .dark, isEnabled: true)
        coordinator.install(in: host)
        coordinator.record(makeMarker(spanID: 1, absoluteRowIndex: 500))
        coordinator.update(bounds: host.bounds, contentRowCount: 1_000, firstRetainedRowIndex: 0, nextRowIndex: 900)
        XCTAssertFalse(coordinator.railViewForTesting.isHidden)

        coordinator.setEnabled(false)
        coordinator.record(makeMarker(spanID: 2, absoluteRowIndex: 600))
        coordinator.update(bounds: host.bounds, contentRowCount: 1_000, firstRetainedRowIndex: 0, nextRowIndex: 900)

        XCTAssertTrue(coordinator.railViewForTesting.isHidden)
        XCTAssertEqual(coordinator.trailingInsetPX, 0)
        XCTAssertTrue(coordinator.markers.isEmpty)
    }

    /// Following live output calls `update` once per scrolled row. A layout
    /// walks every marker, so a growth that cannot move any mark by a whole
    /// slot has to be skipped rather than re-walked.
    func testFollowingOutputDoesNotRelayoutForEverySingleRow() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: hostWidthPX, height: trackHeightPX))
        let coordinator = TerminalPromptRailCoordinator(chromeTheme: .dark, isEnabled: true)
        coordinator.install(in: host)
        for marker in makeEvenlySpacedMarkers(commandCount: 200, contentRowCount: 12_000) {
            coordinator.record(marker)
        }
        coordinator.update(bounds: host.bounds, contentRowCount: 12_000, firstRetainedRowIndex: 0, nextRowIndex: 12_000)
        let baseline = coordinator.railViewForTesting.layoutModel

        // 12,000 rows over 120 slots is 100 rows per slot, so ten more rows
        // cannot move a mark off its slot.
        coordinator.update(bounds: host.bounds, contentRowCount: 12_010, firstRetainedRowIndex: 0, nextRowIndex: 12_010)
        XCTAssertEqual(coordinator.railViewForTesting.layoutModel, baseline)

        // Two slots' worth does, and the rail follows.
        coordinator.update(bounds: host.bounds, contentRowCount: 12_200, firstRetainedRowIndex: 0, nextRowIndex: 12_200)
        XCTAssertNotEqual(coordinator.railViewForTesting.layoutModel, baseline)
    }

    func testANewMarkerAlwaysForcesARelayout() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: hostWidthPX, height: trackHeightPX))
        let coordinator = TerminalPromptRailCoordinator(chromeTheme: .dark, isEnabled: true)
        coordinator.install(in: host)
        coordinator.record(makeMarker(spanID: 1, absoluteRowIndex: 100))
        coordinator.update(bounds: host.bounds, contentRowCount: 12_000, firstRetainedRowIndex: 0, nextRowIndex: 12_000)
        let baseline = coordinator.railViewForTesting.layoutModel

        coordinator.record(makeMarker(spanID: 2, absoluteRowIndex: 11_900))
        coordinator.update(bounds: host.bounds, contentRowCount: 12_000, firstRetainedRowIndex: 0, nextRowIndex: 12_000)

        XCTAssertNotEqual(coordinator.railViewForTesting.layoutModel, baseline)
        XCTAssertEqual(coordinator.railViewForTesting.layoutModel?.clusters.count, 2)
    }

    /// Same rule as the scrollback indicator beside it: the pointing hand means
    /// "web link" on macOS, so neither strip uses it.
    func testTheRailUsesTheArrowCursor() {
        XCTAssertEqual(TerminalPromptRailView(frame: .zero).railCursor, NSCursor.arrow)
    }

    // MARK: - Commands

    func testPreviousAndNextPromptAreRegisteredWithTheIterm2MarkShortcuts() {
        let registry = TerminalCommandRegistry.default

        let previous = registry.windowCommands.first { $0.id == .jumpToPreviousPrompt }
        let next = registry.windowCommands.first { $0.id == .jumpToNextPrompt }
        XCTAssertEqual(previous?.action, .jumpToPrompt(.previous))
        XCTAssertEqual(next?.action, .jumpToPrompt(.next))
        XCTAssertEqual(previous?.category, .navigation)
        XCTAssertEqual(previous?.shortcut?.keyCode, 126)
        XCTAssertEqual(next?.shortcut?.keyCode, 125)
        XCTAssertEqual(previous?.shortcut?.modifiers, [.command, .shift])
        XCTAssertEqual(next?.shortcut?.modifiers, [.command, .shift])
    }

    /// ⌘⇧↑ must reach the prompt jump and ⌘↑ must still reach pane focus: the
    /// two share a key code and are separated only by shift being required
    /// rather than tolerated.
    func testTheJumpShortcutDoesNotShadowPaneFocusOnTheSameKeyCode() {
        let registry = TerminalCommandRegistry.default

        XCTAssertEqual(registry.windowCommand(matching: makeKeyEvent(keyCode: 126, modifiers: [.command, .shift]))?.id, .jumpToPreviousPrompt)
        XCTAssertEqual(registry.windowCommand(matching: makeKeyEvent(keyCode: 125, modifiers: [.command, .shift]))?.id, .jumpToNextPrompt)
        XCTAssertEqual(registry.windowCommand(matching: makeKeyEvent(keyCode: 126, modifiers: .command))?.id, .focusPaneUp)
        XCTAssertEqual(registry.windowCommand(matching: makeKeyEvent(keyCode: 125, modifiers: .command))?.id, .focusPaneDown)
    }

    private func makeKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    // MARK: - Settings

    func testTheRailDefaultsOn() {
        // Re-pointed at schema 22, which added
        // `terminal.promptNavigatorRailEnabled`.
        XCTAssertEqual(SettingsDefaults.schemaVersion, 22)
        XCTAssertTrue(SettingsDefaults.promptNavigatorRailEnabled)
        XCTAssertTrue(AppSettings.default.terminal.promptNavigatorRailEnabled)
    }

    func testTheKeyIsLiveApplied() {
        XCTAssertEqual(
            AppSettingsValidation.lifecycle(for: .terminalPromptNavigatorRailEnabled),
            .liveApplied
        )
    }

    func testSettingsWrittenBeforeSchemaTwentyTwoNormalizeToTheCurrentDefault() {
        var settings = AppSettings.default
        settings.schemaVersion = 21
        settings.terminal.promptNavigatorRailEnabled = false

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertEqual(normalized.schemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertEqual(
            normalized.terminal.promptNavigatorRailEnabled,
            SettingsDefaults.promptNavigatorRailEnabled
        )
    }

    func testCurrentSchemaPreservesAnExplicitRailChoice() {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion
        settings.terminal.promptNavigatorRailEnabled = false

        XCTAssertFalse(AppSettingsNormalizer.normalized(settings).terminal.promptNavigatorRailEnabled)
    }

    func testTheChoiceSurvivesAnEncodeDecodeRoundTrip() throws {
        for choice in [true, false] {
            var settings = AppSettings.default
            settings.terminal.promptNavigatorRailEnabled = choice

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

            XCTAssertEqual(decoded.terminal.promptNavigatorRailEnabled, choice)
        }
    }

    func testDecodingASettingsFileWithoutTheRailKeyUsesTheDefault() throws {
        var settings = AppSettings.default
        settings.schemaVersion = 21
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        )
        var terminal = try XCTUnwrap(object["terminal"] as? [String: Any])
        terminal.removeValue(forKey: "promptNavigatorRailEnabled")
        object["terminal"] = terminal

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(
            decoded.terminal.promptNavigatorRailEnabled,
            SettingsDefaults.promptNavigatorRailEnabled
        )
    }
}

// MARK: - Visibility

/// The rail shipped with a lone command drawn as a 3x3pt mark at 70% alpha on a
/// 6pt track -- a full stop, effectively invisible, and that is exactly the case
/// where the rail is the only thing on screen to look at.
@MainActor
final class TerminalPromptRailVisibilityTests: XCTestCase {
    private func entry(_ exitCode: Int?) -> TerminalCommandHistoryEntry {
        TerminalCommandHistoryEntry(
            commandText: "swift build",
            cwd: "/tmp",
            cwdHost: nil,
            exitCode: exitCode,
            startedAt: nil,
            finishedAt: Date(),
            duration: nil
        )
    }

    private func rail(commandCount: Int, height: CGFloat) -> TerminalPromptRailLayout? {
        let rowsPerCommand = 3
        let markers = (0..<commandCount).map { index in
            TerminalPromptRailMarker(
                spanID: index,
                absoluteRowIndex: index * rowsPerCommand,
                entry: entry(0)
            )
        }
        return TerminalPromptRailLayout.layout(
            markers: markers,
            in: NSRect(x: 0, y: 0, width: 40, height: height),
            contentRowCount: max(1, commandCount * rowsPerCommand),
            firstRetainedRowIndex: 0
        )
    }

    /// Narrowing a singleton only says something when a wider cluster sits
    /// beside it to be narrower *than*. With none, the inset communicated
    /// nothing and halved a 6pt mark.
    func testALoneCommandUsesTheFullTrackWidth() throws {
        let layout = try XCTUnwrap(rail(commandCount: 3, height: 600))
        XCTAssertFalse(layout.clusters.isEmpty)
        for cluster in layout.clusters {
            XCTAssertEqual(
                cluster.frame.width,
                DesignTokens.Component.terminalPromptRailWidthPX,
                accuracy: 0.01,
                "a singleton with no cluster to contrast against drew \(cluster.frame.width)pt wide"
            )
        }
    }

    /// The inset still has to work where it means something. A uniform density
    /// gives every slot the same count, so this deliberately mixes them: a burst
    /// of commands landing in one slot, and lone commands spread far apart.
    func testTheInsetStillDistinguishesSingletonsOnceClustersExist() throws {
        var markers: [TerminalPromptRailMarker] = []
        // A burst: eight commands sharing a handful of rows, so they bucket together.
        for index in 0..<8 {
            markers.append(TerminalPromptRailMarker(spanID: index, absoluteRowIndex: index, entry: entry(0)))
        }
        // Then lone commands, spaced far enough apart to each own a slot.
        for index in 0..<6 {
            markers.append(TerminalPromptRailMarker(
                spanID: 100 + index,
                absoluteRowIndex: 200 + index * 120,
                entry: entry(0)
            ))
        }
        let layout = try XCTUnwrap(TerminalPromptRailLayout.layout(
            markers: markers,
            in: NSRect(x: 0, y: 0, width: 40, height: 400),
            contentRowCount: 1_000,
            firstRetainedRowIndex: 0
        ))
        let clustered = layout.clusters.filter { $0.markerCount > 1 }
        let singletons = layout.clusters.filter { $0.markerCount == 1 }
        XCTAssertFalse(clustered.isEmpty, "the burst did not bucket into a cluster")
        XCTAssertFalse(singletons.isEmpty, "the spaced commands did not stay singletons")
        for singleton in singletons {
            for cluster in clustered {
                XCTAssertLessThan(
                    singleton.frame.width,
                    cluster.frame.width,
                    "a singleton must read narrower than a stack beside it"
                )
            }
        }
    }

    /// A sliver, or a mark translucent enough to sink into the ground, fails the
    /// one job the rail has.
    func testMarksAreThickEnoughAndOpaqueEnoughToFind() throws {
        let layout = try XCTUnwrap(rail(commandCount: 3, height: 600))
        for cluster in layout.clusters {
            XCTAssertGreaterThanOrEqual(cluster.frame.height, 4, "mark height")
        }
        XCTAssertGreaterThanOrEqual(
            DesignTokens.Color.promptRailSuccessAlphaRATIO,
            0.85,
            "a successful command is the common case and must not be faint"
        )
        XCTAssertGreaterThanOrEqual(
            DesignTokens.Color.promptRailHeatMinAlphaRATIO,
            0.35,
            "the quietest heat step still has to be visible"
        )
    }
}
