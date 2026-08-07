import AppKit

/// Owns the prompt navigator rail and its hover popover for one terminal
/// surface.
///
/// Shaped like `TerminalScrollIndicatorCoordinator` next door — install, lay
/// out, follow the chrome theme through `AppSettingsStore.didChangeNotification`
/// — because the two are neighbours on the same edge and a reader who has
/// understood one should not have to learn a second pattern for the other.
@MainActor
final class TerminalPromptRailCoordinator: NSObject {
    /// Fires with the absolute scrollback row a click or a keyboard jump asked
    /// for. The surface owns the actual scroll; the rail only names a row.
    var onSelectAbsoluteRow: ((Int) -> Void)?

    private let railView = TerminalPromptRailView(frame: .zero)
    private let popoverView = TerminalPromptRailPopoverView(frame: .zero)
    private let observesSettingsChanges: Bool
    private var chromeTheme: DesignTokens.ChromeTheme
    private var store: TerminalPromptRailStore
    private(set) var isEnabled: Bool
    private var lastBounds: NSRect = .zero
    private var lastLaidOutState: LaidOutState?

    /// What the last layout was computed from.
    ///
    /// Following live output calls `update` once per scrolled row, and a layout
    /// walks every marker. Re-running that for a single new row would put an
    /// O(markers) pass in the hot path of every build log, so a growth in
    /// content that cannot move any mark by a whole slot is skipped.
    private struct LaidOutState {
        let bounds: NSRect
        let contentRowCount: Int
        let firstRetainedRowIndex: Int
        let markerCount: Int
        let slotCount: Int

        func isStale(
            bounds: NSRect,
            contentRowCount: Int,
            firstRetainedRowIndex: Int,
            markerCount: Int
        ) -> Bool {
            guard bounds == self.bounds,
                  firstRetainedRowIndex == self.firstRetainedRowIndex,
                  markerCount == self.markerCount
            else {
                return true
            }
            let rowsPerSlot = max(1, self.contentRowCount / max(1, slotCount))
            return abs(contentRowCount - self.contentRowCount) >= rowsPerSlot
        }
    }

    /// - Parameters:
    ///   - chromeTheme: pass a theme to pin the rail to it; the app passes
    ///     nothing and the coordinator tracks the terminal background setting
    ///     the same way `ChromeTheme.theme(for:)` does.
    ///   - isEnabled: pass a value to pin the rail on or off; the app passes
    ///     nothing and the coordinator reads `terminal.promptNavigatorRailEnabled`.
    init(
        chromeTheme: DesignTokens.ChromeTheme? = nil,
        isEnabled: Bool? = nil,
        capacityCOUNT: Int = TerminalPromptRailStore.defaultCapacityCOUNT
    ) {
        observesSettingsChanges = chromeTheme == nil && isEnabled == nil
        let settings = Self.resolvedSettings()
        self.chromeTheme = chromeTheme ?? DesignTokens.ChromeTheme.theme(for: settings)
        self.isEnabled = isEnabled ?? settings.terminal.promptNavigatorRailEnabled
        store = TerminalPromptRailStore(capacityCOUNT: capacityCOUNT)
        super.init()
        configureViews()
        guard observesSettingsChanges else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func install(in view: NSView) {
        view.addSubview(railView)
        view.addSubview(popoverView)
    }

    /// Width the rail reserves along the trailing edge, which the scroll
    /// indicator is pushed inboard by. Zero while the rail has nothing to draw,
    /// so a session without shell integration keeps the full-width strip the
    /// indicator has always had.
    var trailingInsetPX: CGFloat {
        railView.isHidden ? 0 : DesignTokens.Component.terminalPromptRailWidthPX
    }

    var markers: [TerminalPromptRailMarker] {
        store.markers
    }

    func record(_ marker: TerminalPromptRailMarker) {
        guard isEnabled else { return }
        store.append(marker)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        // Markers are dropped rather than parked: they are anchored to a
        // scrollback that keeps moving while the rail is off, and rows that
        // scroll away in the meantime would come back wrong.
        if !enabled {
            store.removeAll()
            popoverView.dismiss()
        }
        railView.apply(nil)
    }

    func setChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        railView.chromeTheme = theme
        popoverView.chromeTheme = theme
    }

    /// Re-anchors the store against the current scrollback and lays the rail
    /// out.
    func update(
        bounds: NSRect,
        contentRowCount: Int,
        firstRetainedRowIndex: Int,
        nextRowIndex: Int
    ) {
        lastBounds = bounds
        store.reconcile(firstRetainedRowIndex: firstRetainedRowIndex, nextRowIndex: nextRowIndex)
        guard isEnabled else {
            railView.apply(nil)
            popoverView.dismiss()
            lastLaidOutState = nil
            return
        }

        let isStale = lastLaidOutState?.isStale(
            bounds: bounds,
            contentRowCount: contentRowCount,
            firstRetainedRowIndex: firstRetainedRowIndex,
            markerCount: store.markers.count
        ) ?? true
        guard isStale else { return }

        let railBounds = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let layout = TerminalPromptRailLayout.layout(
            markers: store.markers,
            in: railBounds,
            contentRowCount: contentRowCount,
            firstRetainedRowIndex: firstRetainedRowIndex
        )
        guard let layout else {
            railView.apply(nil)
            popoverView.dismiss()
            lastLaidOutState = nil
            return
        }

        lastLaidOutState = LaidOutState(
            bounds: bounds,
            contentRowCount: contentRowCount,
            firstRetainedRowIndex: firstRetainedRowIndex,
            markerCount: store.markers.count,
            slotCount: max(1, Int(layout.trackFrame.height / layout.slotHeightPX))
        )
        railView.frame = layout.trackFrame
        // The layout was computed against the host's full width, so the marks
        // come back in host coordinates; move them into the rail's own.
        railView.apply(
            TerminalPromptRailLayout(
                trackFrame: NSRect(origin: .zero, size: layout.trackFrame.size),
                clusters: layout.clusters.map { cluster in
                    TerminalPromptRailCluster(
                        slotIndex: cluster.slotIndex,
                        frame: cluster.frame.offsetBy(dx: -layout.trackFrame.minX, dy: 0),
                        hitFrame: cluster.hitFrame.offsetBy(dx: -layout.trackFrame.minX, dy: 0),
                        markerCount: cluster.markerCount,
                        failedCount: cluster.failedCount,
                        anchorAbsoluteRowIndex: cluster.anchorAbsoluteRowIndex,
                        spanIDs: cluster.spanIDs,
                        densityRATIO: cluster.densityRATIO
                    )
                },
                mode: layout.mode,
                slotHeightPX: layout.slotHeightPX
            )
        )
    }

    // MARK: - Test seams

    var railViewForTesting: TerminalPromptRailView { railView }
    var popoverViewForTesting: TerminalPromptRailPopoverView { popoverView }

    // MARK: - Wiring

    private func configureViews() {
        railView.chromeTheme = chromeTheme
        railView.isHidden = true
        popoverView.chromeTheme = chromeTheme
        railView.onSelectAbsoluteRow = { [weak self] absoluteRow in
            self?.onSelectAbsoluteRow?(absoluteRow)
        }
        railView.onHoverSpanIDs = { [weak self] spanIDs, y in
            self?.presentPopover(forSpanIDs: spanIDs, atRailY: y)
        }
    }

    private func presentPopover(forSpanIDs spanIDs: [TerminalCommandSpan.ID], atRailY y: CGFloat) {
        guard !spanIDs.isEmpty else {
            popoverView.dismiss()
            return
        }
        let content = TerminalPromptRailPopoverContent.rows(
            forSpanIDs: spanIDs,
            markers: store.markers,
            now: Date(),
            limit: DesignTokens.Component.terminalPromptRailPopoverEntryLIMIT
        )
        popoverView.present(rows: content.rows, overflowCOUNT: content.overflowCOUNT)
        positionPopover(atRailY: y)
    }

    /// Anchors the popover beside the pointer and inside the surface.
    ///
    /// It sits inboard of the rail rather than over it, so the marks the list
    /// describes stay visible while the list is up.
    private func positionPopover(atRailY y: CGFloat) {
        let size = popoverView.frame.size
        let gap = DesignTokens.Component.terminalPromptRailPopoverGapPX
        let maximumX = max(0, railView.frame.minX - gap - size.width)
        let centeredY = railView.frame.minY + y - size.height / 2
        let maximumY = max(0, lastBounds.height - size.height)
        popoverView.setFrameOrigin(
            NSPoint(x: maximumX, y: min(maximumY, max(0, centeredY)))
        )
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        setChromeTheme(DesignTokens.ChromeTheme.theme(for: settings))
        setEnabled(settings.terminal.promptNavigatorRailEnabled)
    }

    private static func resolvedSettings() -> AppSettings {
        (try? AppSettingsStore.shared.load()) ?? .default
    }
}
