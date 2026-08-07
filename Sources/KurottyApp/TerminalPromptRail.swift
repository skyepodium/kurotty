import AppKit

/// One completed command, anchored to the scrollback row its prompt was drawn
/// on.
///
/// The row is *absolute*: `firstRetainedRowIndex + visibleRowIndex`, the index
/// space `BoundedScrollbackRows` already maintains and which survives trimming.
/// A content-row index would slide out from under the marker every time the
/// scrollback drops its oldest rows, which is exactly the class of bug that
/// makes a navigator send you somewhere else after a long build.
///
/// The payload is a `TerminalCommandHistoryEntry` rather than a second copy of
/// the same four fields, so the popover formats through
/// `TerminalCommandHistoryRowBuilder` like every other command row in the app.
struct TerminalPromptRailMarker: Equatable {
    let spanID: TerminalCommandSpan.ID
    let absoluteRowIndex: Int
    let entry: TerminalCommandHistoryEntry

    var didFail: Bool {
        guard let exitCode = entry.exitCode else { return false }
        return exitCode != 0
    }
}

/// The rail's own bounded record of markers.
///
/// Deliberately not `TerminalShellIntegration.recentCommandSpans`: that list is
/// capped at 100 spans and carries no row, so a rail built on it could never
/// describe more scrollback than the last hundred commands. Deliberately not
/// the persisted history store either, which spans sessions and panes and has a
/// privacy contract that says nothing about screen positions.
struct TerminalPromptRailStore: Equatable {
    /// Ceiling on retained markers. The *effective* cap is usually lower:
    /// `reconcile` drops every marker whose row has fallen out of the
    /// scrollback, because a marker that cannot be scrolled to is not a marker.
    /// This number only bounds the pathological case of a very large scrollback
    /// limit paired with very short commands.
    static let defaultCapacityCOUNT = 5_000

    private(set) var markers: [TerminalPromptRailMarker] = []
    /// Highest `nextRowIndex` seen. The absolute row space restarts at zero on
    /// ED 3 (`ESC [ 3 J`, which replaces the whole scrollback store), so a
    /// counter that moves *backwards* means every stored row now aliases a
    /// different line and the only correct answer is to forget all of them.
    private var lastObservedNextRowIndex = 0
    private let capacityCOUNT: Int

    init(capacityCOUNT: Int = TerminalPromptRailStore.defaultCapacityCOUNT) {
        self.capacityCOUNT = max(0, capacityCOUNT)
    }

    var isEmpty: Bool {
        markers.isEmpty
    }

    mutating func append(_ marker: TerminalPromptRailMarker) {
        guard capacityCOUNT > 0 else {
            markers.removeAll()
            return
        }
        markers.append(marker)
        let overflow = markers.count - capacityCOUNT
        if overflow > 0 {
            markers.removeFirst(overflow)
        }
    }

    mutating func removeAll() {
        markers.removeAll()
        lastObservedNextRowIndex = 0
    }

    /// Brings the store back in line with the scrollback after output, trimming,
    /// or a clear.
    ///
    /// - Parameters:
    ///   - firstRetainedRowIndex: absolute index of the oldest row still held.
    ///   - nextRowIndex: absolute index the next appended scrollback row takes.
    mutating func reconcile(firstRetainedRowIndex: Int, nextRowIndex: Int) {
        if nextRowIndex < lastObservedNextRowIndex {
            removeAll()
        }
        lastObservedNextRowIndex = max(lastObservedNextRowIndex, nextRowIndex)
        markers.removeAll { $0.absoluteRowIndex < firstRetainedRowIndex }
    }
}

/// How hard the rail had to compress to fit, which is what decides the visual
/// encoding. Reported rather than re-derived by the view so the density
/// behaviour can be asserted directly.
enum TerminalPromptRailDensityMode: Equatable {
    /// Every mark stands for exactly one command.
    case discrete
    /// Some marks stand for several commands, but few enough that a click on
    /// one still means something specific. Clusters draw at the full track
    /// width and singletons inset, so the two stay distinguishable at 3pt.
    case clustered
    /// Marks stand for so many commands that counting them by eye is hopeless.
    /// Successful clusters fall back to a density wash while failures stay at
    /// full strength, so the rail keeps answering "where did things break"
    /// after it has stopped being able to answer "how many ran here".
    case heat
}

/// One drawn mark. Stands for one command or for many.
struct TerminalPromptRailCluster: Equatable {
    /// Index from the top of the track; slot 0 holds the oldest rows.
    let slotIndex: Int
    /// Laid-out mark rectangle in the rail view's coordinate space.
    let frame: NSRect
    /// The full-width band this slot owns. Hit-testing uses this rather than
    /// `frame`, because nobody can click a 3pt mark.
    let hitFrame: NSRect
    let markerCount: Int
    let failedCount: Int
    /// The oldest command in the slot, and where a click scrolls to: landing on
    /// the top of a cluster shows the whole cluster, landing on the bottom of
    /// it hides everything the cluster contained.
    let anchorAbsoluteRowIndex: Int
    let spanIDs: [TerminalCommandSpan.ID]
    /// This slot's share of the busiest slot's population, `0...1`.
    let densityRATIO: CGFloat

    var hasFailure: Bool {
        failedCount > 0
    }

    var isSingleton: Bool {
        markerCount == 1
    }
}

/// Rail geometry and clustering.
///
/// Pure arithmetic over `NSRect`, exactly like `TerminalScrollIndicatorMetrics`
/// next door, so marker placement and every density regime are exercised
/// without a window.
struct TerminalPromptRailLayout: Equatable {
    /// The strip the rail owns, flush to the trailing edge.
    let trackFrame: NSRect
    /// Oldest first, which on this track is also top to bottom.
    let clusters: [TerminalPromptRailCluster]
    let mode: TerminalPromptRailDensityMode
    /// Height of one slot band. Never below
    /// `terminalPromptRailSlotHeightPX`, which is what guarantees a gap between
    /// neighbouring marks no matter how many commands the session ran.
    let slotHeightPX: CGFloat

    /// - Parameters:
    ///   - markers: any order; the layout sorts by row.
    ///   - bounds: the rail view's bounds.
    ///   - contentRowCount: scrollback rows plus live screen rows, the same
    ///     index space `TerminalSearchNavigation.scrollbackOffsetToReveal`
    ///     takes.
    ///   - firstRetainedRowIndex: absolute index of the oldest retained row,
    ///     used to turn absolute rows back into content rows.
    ///
    /// Returns `nil` when there is nothing to draw. That is the signal to take
    /// the rail off screen rather than leave an empty strip sitting on top of a
    /// column of terminal output.
    static func layout(
        markers: [TerminalPromptRailMarker],
        in bounds: NSRect,
        contentRowCount: Int,
        firstRetainedRowIndex: Int
    ) -> TerminalPromptRailLayout? {
        guard bounds.height > 0, bounds.width > 0, contentRowCount > 0, !markers.isEmpty else {
            return nil
        }

        let trackFrame = NSRect(
            x: max(0, bounds.width - DesignTokens.Component.terminalPromptRailWidthPX),
            y: 0,
            width: min(bounds.width, DesignTokens.Component.terminalPromptRailWidthPX),
            height: bounds.height
        )

        // Slots tile the track exactly. Taking the count from the minimum pitch
        // and dividing the height back out means the remainder never strands
        // the newest marker a few points above the bottom edge, where it would
        // disagree with the viewport it is supposed to be describing.
        let minimumSlotHeight = DesignTokens.Component.terminalPromptRailSlotHeightPX
        let slotCount = max(1, Int(trackFrame.height / minimumSlotHeight))
        let slotHeight = trackFrame.height / CGFloat(slotCount)

        let bucketedMarkers = bucketMarkersBySlot(
            markers: markers,
            contentRowCount: contentRowCount,
            firstRetainedRowIndex: firstRetainedRowIndex,
            slotCount: slotCount
        )
        guard !bucketedMarkers.isEmpty else {
            return nil
        }

        let maximumFanout = bucketedMarkers.values.map(\.count).max() ?? 1
        let markHeight = min(slotHeight, DesignTokens.Component.terminalPromptRailMarkerHeightPX)
        // A singleton is inset so a lone command reads narrower than a stack of
        // them. The quarter-width cap keeps the inset from eating the mark on a
        // rail that a future token change makes thinner.
        let singletonInset = min(
            DesignTokens.Component.terminalPromptRailSingletonInsetPX,
            trackFrame.width / 4
        )

        let clusters: [TerminalPromptRailCluster] = bucketedMarkers.keys.sorted().compactMap { slotIndex in
            guard let slotMarkers = bucketedMarkers[slotIndex], let anchor = slotMarkers.first else {
                return nil
            }
            // The terminal surface is not flipped, so slot 0 sits at the top of
            // the track and the newest rows land at y = 0, matching the scroll
            // thumb's own convention.
            let hitFrame = NSRect(
                x: trackFrame.minX,
                y: trackFrame.maxY - CGFloat(slotIndex + 1) * slotHeight,
                width: trackFrame.width,
                height: slotHeight
            )
            // Narrowing a singleton only says anything when there is a wider
            // cluster beside it to be narrower *than*. In discrete mode every
            // slot holds one command, so the inset communicated nothing and
            // merely shrank a 6pt rail's mark to 3pt -- which is why a handful
            // of commands read as almost nothing on screen.
            let inset = (maximumFanout > 1 && slotMarkers.count == 1) ? singletonInset : 0
            let frame = NSRect(
                x: trackFrame.minX + inset,
                y: hitFrame.minY + (slotHeight - markHeight) / 2,
                width: max(1, trackFrame.width - inset * 2),
                height: markHeight
            )
            return TerminalPromptRailCluster(
                slotIndex: slotIndex,
                frame: frame,
                hitFrame: hitFrame,
                markerCount: slotMarkers.count,
                failedCount: slotMarkers.filter(\.didFail).count,
                anchorAbsoluteRowIndex: anchor.absoluteRowIndex,
                spanIDs: slotMarkers.map(\.spanID),
                densityRATIO: CGFloat(slotMarkers.count) / CGFloat(maximumFanout)
            )
        }

        return TerminalPromptRailLayout(
            trackFrame: trackFrame,
            clusters: clusters,
            mode: densityMode(maximumFanout: maximumFanout),
            slotHeightPX: slotHeight
        )
    }

    /// Total inked height. The rail's whole promise is that it never degrades
    /// into a solid stripe, so that promise is measured rather than inferred
    /// from a marker count.
    var inkedHeightPX: CGFloat {
        clusters.reduce(0) { $0 + $1.frame.height }
    }

    /// The cluster a click at `y` means.
    ///
    /// Nearest-within-tolerance rather than strict containment: the mark is 3pt
    /// tall inside a 6pt-wide strip, so demanding a hit on the mark itself
    /// would make the rail feel broken. The tolerance is bounded by one slot,
    /// which cannot reach past a neighbouring slot's own claim, and it is what
    /// lets a click at the very top or bottom edge of the track still resolve
    /// to the extreme marker.
    func cluster(atY y: CGFloat) -> TerminalPromptRailCluster? {
        let tolerance = slotHeightPX * DesignTokens.Component.terminalPromptRailHitToleranceSLOTS
        guard let nearest = nearestClusters(toY: y, limit: 1).first,
              abs(nearest.hitFrame.midY - y) <= tolerance
        else {
            return nil
        }
        return nearest
    }

    /// Clusters around `y`, nearest first, for the hover popover.
    func nearestClusters(toY y: CGFloat, limit: Int) -> [TerminalPromptRailCluster] {
        guard limit > 0 else { return [] }
        return clusters
            .sorted { abs($0.hitFrame.midY - y) < abs($1.hitFrame.midY - y) }
            .prefix(limit)
            .map { $0 }
    }

    private static func densityMode(maximumFanout: Int) -> TerminalPromptRailDensityMode {
        if maximumFanout <= 1 {
            return .discrete
        }
        if maximumFanout <= DesignTokens.Component.terminalPromptRailClusterFanoutLIMIT {
            return .clustered
        }
        return .heat
    }

    private static func bucketMarkersBySlot(
        markers: [TerminalPromptRailMarker],
        contentRowCount: Int,
        firstRetainedRowIndex: Int,
        slotCount: Int
    ) -> [Int: [TerminalPromptRailMarker]] {
        var bucketedMarkers: [Int: [TerminalPromptRailMarker]] = [:]
        for marker in markers.sorted(by: { $0.absoluteRowIndex < $1.absoluteRowIndex }) {
            let contentRow = marker.absoluteRowIndex - firstRetainedRowIndex
            // A negative row means the command scrolled out of the retained
            // scrollback. Skipping it here rather than drawing it at row zero
            // is the difference between a missing marker and a lying one.
            guard contentRow >= 0 else { continue }
            let clampedRow = min(contentRow, contentRowCount - 1)
            // Rows run oldest-first and slot 0 is the top of the track, so the
            // two orders already agree and there is no inversion here.
            let normalizedFromTop = (CGFloat(clampedRow) + 0.5) / CGFloat(contentRowCount)
            let slotIndex = min(slotCount - 1, max(0, Int(normalizedFromTop * CGFloat(slotCount))))
            bucketedMarkers[slotIndex, default: []].append(marker)
        }
        return bucketedMarkers
    }
}

/// Prompt-to-prompt keyboard navigation.
///
/// Split from the layout because "which command is above me" is a question
/// about rows, not pixels: it has to answer the same way whether the rail is
/// drawn or switched off in Settings.
enum TerminalPromptRailNavigation {
    enum Direction: Equatable {
        case previous
        case next
    }

    /// The content row to reveal, or `nil` when there is no prompt that way.
    ///
    /// `currentTopContentRow` is the row at the top of the viewport, which is
    /// what the user reads as "where I am". Both directions compare strictly,
    /// so repeated presses walk the list instead of sticking on the prompt that
    /// is already at the top.
    static func targetContentRow(
        markers: [TerminalPromptRailMarker],
        firstRetainedRowIndex: Int,
        contentRowCount: Int,
        currentTopContentRow: Int,
        direction: Direction
    ) -> Int? {
        guard contentRowCount > 0 else { return nil }
        let rows = markers
            .map { $0.absoluteRowIndex - firstRetainedRowIndex }
            .filter { $0 >= 0 && $0 < contentRowCount }
            .sorted()

        switch direction {
        case .previous:
            return rows.last { $0 < currentTopContentRow }
        case .next:
            return rows.first { $0 > currentTopContentRow }
        }
    }
}
