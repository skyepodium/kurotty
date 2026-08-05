import AppKit

/// What the status bar needs from the window that hosts it.
///
/// The bar never reaches into the window controller's view tree: every input is
/// pulled through this protocol, so the bar can be driven by a test double.
@MainActor
protocol TerminalStatusBarDataSource: AnyObject {
    /// Every pane in the window, in tab/split order.
    func statusBarPaneDescriptors() -> [TerminalStatusBarPaneDescriptor]
    /// The focused pane, whose agent status the left segment shows.
    func statusBarActivePaneIdentifier() -> String?
    /// Visibility and occlusion inputs for the sampling gate.
    func statusBarSamplingContext() -> TerminalStatusBarSamplingContext
    /// Inserts text at the pane's prompt without a trailing newline. The bar
    /// never executes a command.
    func statusBarInsertText(_ text: String, paneIdentifier: String)
    /// Opens Preferences so the user can turn on the agent status hooks.
    func statusBarOpenPreferences()
}

/// Bottom status bar for a terminal window.
///
/// Layout: a fixed-height strip with a hairline top edge, one leading-aligned
/// agent segment and one trailing-aligned resource segment, both hover-
/// highlighted click targets.
///
/// Redraw contract: nothing here updates on keystrokes. The agent segment
/// updates only on `AgentActivityRegistry.didChangeNotification`, the resource
/// segment only when a sampled value actually changed, and both compare their
/// rendered model before touching a label. Values use monospaced digits with
/// reserved widths so a changing number cannot reflow the bar.
///
/// Mounting: see `attach(to:)`. The returned height constraint is the collapse
/// control; the bar collapses itself to zero height while the window has no
/// panes.
@MainActor
final class TerminalStatusBarView: NSView {
    private let topBorderView = NSView()
    private let agentSegmentView = TerminalStatusBarAgentSegmentView(frame: .zero)
    private let worktreeSegmentView = TerminalStatusBarWorktreeSegmentView(frame: .zero)
    private let resourceSegmentView = TerminalStatusBarResourceSegmentView(frame: .zero)
    private let sampler: TerminalResourceUsageSampler
    private let registry: AgentActivityRegistry
    private let sessionIndexStore: AgentSessionIndexStore
    private let worktreeService: any TerminalGitWorktreeProviding
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var heightConstraint: NSLayoutConstraint?
    private var visibility = TerminalStatusBarVisibility.full
    private var lastAppliedWidthPX: CGFloat = 0
    private var activePopover: NSPopover?
    private var worktreeSnapshot: TerminalGitWorktreeSnapshot?
    /// Working directory the current snapshot describes. Directory changes
    /// arrive through the same notification as title changes, which fires once
    /// per prompt, so an unchanged directory must not spawn another `git`.
    private var worktreeDirectoryPath: String?

    /// The worktree state the segment currently renders, applied from the
    /// service's async result.
    private(set) var currentWorktreeSummary = TerminalStatusBarWorktreeSummary.absent

    weak var dataSource: (any TerminalStatusBarDataSource)?
    /// Resolved from `AgentStatusHookCoordinator.shared` by default; injectable
    /// so tests can drive the hooks-disabled branch.
    var areStatusHooksInstalledProvider: @MainActor () -> Bool = {
        AgentStatusHookCoordinator.shared.isEnabled
    }

    init(
        frame frameRect: NSRect = .zero,
        sampler: TerminalResourceUsageSampler = TerminalResourceUsageSampler(),
        registry: AgentActivityRegistry = .shared,
        sessionIndexStore: AgentSessionIndexStore = .shared,
        worktreeService: any TerminalGitWorktreeProviding = TerminalGitWorktreeService()
    ) {
        self.sampler = sampler
        self.registry = registry
        self.sessionIndexStore = sessionIndexStore
        self.worktreeService = worktreeService
        super.init(frame: frameRect)
        configureLayout()
        configureSampler()
        observeAgentActivity()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Mounting

    /// Pins the bar to the bottom edge of `containerView` and returns its
    /// height constraint.
    ///
    /// The caller must then pin whatever sits above it (the split container) to
    /// `topAnchor`, exactly as the tab bar owns the top strip. The height
    /// constraint starts at zero and is driven by `refreshPanes()`.
    @discardableResult
    func attach(to containerView: NSView) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(self)
        let heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            heightConstraint,
        ])
        refreshPanes()
        return heightConstraint
    }

    /// Mirror of `terminal.statusBarEnabled`, live-applied.
    private(set) var isEnabled = true

    /// Applies the `terminal.statusBarEnabled` setting. Disabling collapses the
    /// strip to zero height and invalidates the sampling timer, so a turned-off
    /// bar costs no timer wakeup and no `libproc` call at all.
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else {
            return
        }
        isEnabled = enabled
        guard enabled else {
            stopSampling()
            refreshPanes()
            return
        }
        refreshPanes()
        startSampling()
    }

    /// Starts the sampling timer. Call from `windowDidBecomeMain`/`showWindow`.
    func startSampling() {
        guard isEnabled else {
            return
        }
        sampler.start()
    }

    /// Stops the sampling timer. Call from window close.
    func stopSampling() {
        sampler.stop()
    }

    /// Re-reads panes: collapses or expands the bar, resets CPU delta state,
    /// and refreshes both segments. Call whenever a pane or tab is added,
    /// removed, or selected.
    func refreshPanes() {
        let descriptors = dataSource?.statusBarPaneDescriptors() ?? []
        let isCollapsed = !isEnabled || descriptors.isEmpty
        heightConstraint?.constant = isCollapsed ? 0 : DesignTokens.Component.StatusBar.heightPX
        isHidden = isCollapsed
        sampler.resetDeltaState()
        refreshAgentSegment()
        guard !isCollapsed else {
            worktreeService.cancelPendingRequests()
            return
        }
        refreshWorktreeSegment()
        sampler.sampleNow()
    }

    /// Re-evaluates the sampling gate. Call from `windowDidChangeOcclusionState`
    /// and from miniaturize/deminiaturize.
    func windowVisibilityDidChange() {
        sampler.sampleNow()
    }

    /// Recomputes the agent segment from the registry. Called automatically on
    /// registry changes; exposed for the window controller's focus changes.
    func refreshAgentSegment() {
        let summary = TerminalStatusBarAgentComposer.summary(
            statuses: activeStatuses(),
            areStatusHooksInstalled: areStatusHooksInstalledProvider(),
            hasEverReported: hasEverReported()
        )
        agentSegmentView.update(summary: summary, visibility: visibility)
    }

    /// Recomputes the worktree segment for the active pane's working directory.
    ///
    /// The lookup is skipped entirely while the directory is unchanged, so the
    /// per-prompt directory notification cannot turn into a `git` process per
    /// command.
    func refreshWorktreeSegment(forcesReload: Bool = false) {
        let descriptor = activePaneDescriptor
        // An SSH pane reports a path that belongs to another machine; running
        // git against it locally would describe the wrong repository.
        let directoryPath = (descriptor?.isWorkingDirectoryRemote ?? true)
            ? ""
            : (descriptor?.workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        guard !directoryPath.isEmpty else {
            worktreeService.cancelPendingRequests()
            applyWorktreeSnapshot(nil, directoryPath: nil)
            return
        }
        guard forcesReload || directoryPath != worktreeDirectoryPath else {
            return
        }
        worktreeDirectoryPath = directoryPath
        worktreeService.requestSnapshot(workingDirectoryPath: directoryPath) { [weak self] snapshot in
            self?.applyWorktreeSnapshot(snapshot, directoryPath: directoryPath)
        }
    }

    private func applyWorktreeSnapshot(_ snapshot: TerminalGitWorktreeSnapshot?, directoryPath: String?) {
        worktreeSnapshot = snapshot
        worktreeDirectoryPath = directoryPath
        currentWorktreeSummary = TerminalStatusBarWorktreeComposer.summary(snapshot: snapshot)
        worktreeSegmentView.update(summary: currentWorktreeSummary, visibility: visibility)
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = theme.topChromeBackground.cgColor
        topBorderView.layer?.backgroundColor = theme.borderHairline.cgColor
        agentSegmentView.applyChromeTheme(theme)
        worktreeSegmentView.applyChromeTheme(theme)
        resourceSegmentView.applyChromeTheme(theme)
    }

    // MARK: - Layout

    private func configureLayout() {
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor

        topBorderView.wantsLayer = true
        topBorderView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        topBorderView.layer?.backgroundColor = chromeTheme.borderHairline.cgColor
        topBorderView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorderView)

        agentSegmentView.translatesAutoresizingMaskIntoConstraints = false
        worktreeSegmentView.translatesAutoresizingMaskIntoConstraints = false
        resourceSegmentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(agentSegmentView)
        addSubview(worktreeSegmentView)
        addSubview(resourceSegmentView)

        agentSegmentView.onClick = { [weak self] in
            self?.agentSegmentClicked()
        }
        worktreeSegmentView.onClick = { [weak self] in
            self?.worktreeSegmentClicked()
        }
        resourceSegmentView.onClick = { [weak self] in
            self?.resourceSegmentClicked()
        }

        NSLayoutConstraint.activate([
            topBorderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorderView.topAnchor.constraint(equalTo: topAnchor),
            topBorderView.heightAnchor.constraint(equalToConstant: DesignTokens.Component.hairlinePX),

            agentSegmentView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DesignTokens.Component.StatusBar.horizontalInsetPX
                    - DesignTokens.Component.StatusBar.segmentPaddingXPX
            ),
            agentSegmentView.centerYAnchor.constraint(equalTo: centerYAnchor),

            // The worktree segment joins the leading group: pane context reads
            // left to right as agent, then where that agent is working.
            worktreeSegmentView.leadingAnchor.constraint(
                equalTo: agentSegmentView.trailingAnchor,
                constant: DesignTokens.Component.StatusBar.segmentGroupGapPX
            ),
            worktreeSegmentView.centerYAnchor.constraint(equalTo: centerYAnchor),

            resourceSegmentView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(DesignTokens.Component.StatusBar.horizontalInsetPX
                    - DesignTokens.Component.StatusBar.segmentPaddingXPX)
            ),
            resourceSegmentView.centerYAnchor.constraint(equalTo: centerYAnchor),
            resourceSegmentView.leadingAnchor.constraint(
                greaterThanOrEqualTo: worktreeSegmentView.trailingAnchor,
                constant: DesignTokens.Component.StatusBar.segmentGroupGapPX
            ),
        ])
    }

    override func layout() {
        super.layout()
        applyVisibilityIfNeeded()
    }

    private func applyVisibilityIfNeeded() {
        let widthPX = bounds.width
        guard widthPX != lastAppliedWidthPX else {
            return
        }
        lastAppliedWidthPX = widthPX
        let nextVisibility = TerminalStatusBarLayoutPolicy.visibility(barWidthPX: widthPX)
        guard nextVisibility != visibility else {
            return
        }
        visibility = nextVisibility
        agentSegmentView.update(summary: agentSegmentView.currentSummary, visibility: visibility)
        worktreeSegmentView.update(summary: worktreeSegmentView.currentSummary, visibility: visibility)
        resourceSegmentView.update(usage: sampler.latestUsage, visibility: visibility)
    }

    // MARK: - Sampling

    private func configureSampler() {
        sampler.paneDescriptorsProvider = { [weak self] in
            self?.dataSource?.statusBarPaneDescriptors() ?? []
        }
        sampler.samplingContextProvider = { [weak self] in
            self?.dataSource?.statusBarSamplingContext() ?? TerminalStatusBarSamplingContext(
                isWindowVisible: false,
                isWindowOccluded: true,
                paneCount: 0
            )
        }
        sampler.onUsageChanged = { [weak self] usage in
            guard let self else {
                return
            }
            self.resourceSegmentView.update(usage: usage, visibility: self.visibility)
        }
    }

    // MARK: - Agent state

    private func observeAgentActivity() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentActivityDidChange(_:)),
            name: AgentActivityRegistry.didChangeNotification,
            object: nil
        )
    }

    @objc private func agentActivityDidChange(_ notification: Notification) {
        refreshAgentSegment()
    }

    /// Statuses for every pane in this window; the composer picks the
    /// highest-priority one and reports the count.
    private func activeStatuses() -> [AgentActivityStatus] {
        let descriptors = dataSource?.statusBarPaneDescriptors() ?? []
        return descriptors.compactMap { registry.status(for: $0.paneIdentifier) }
    }

    private func hasEverReported() -> Bool {
        let descriptors = dataSource?.statusBarPaneDescriptors() ?? []
        return descriptors.contains { !registry.history(for: $0.paneIdentifier).isEmpty }
    }

    private var activePaneDescriptor: TerminalStatusBarPaneDescriptor? {
        let descriptors = dataSource?.statusBarPaneDescriptors() ?? []
        guard let activeIdentifier = dataSource?.statusBarActivePaneIdentifier() else {
            return descriptors.first
        }
        return descriptors.first { $0.paneIdentifier == activeIdentifier } ?? descriptors.first
    }

    // MARK: - Click handling

    private func agentSegmentClicked() {
        switch agentSegmentView.currentSummary.action {
        case .offerToEnableStatusHooks:
            presentEnableStatusHooksAlert()
        case .showStatusHistory:
            presentAgentHistoryPopover()
        }
    }

    private func presentEnableStatusHooksAlert() {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.statusBarEnableStatusHooksTitle)
        alert.informativeText = AppLocalization.string(.statusBarEnableStatusHooksMessage)
        alert.addButton(withTitle: AppLocalization.string(.statusBarOpenPreferences))
        alert.addButton(withTitle: AppLocalization.string(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        dataSource?.statusBarOpenPreferences()
    }

    private func presentAgentHistoryPopover() {
        guard let descriptor = activePaneDescriptor else {
            return
        }
        let history = registry.history(for: descriptor.paneIdentifier)
        let resumeRecord = Self.resumableSession(
            forWorkingDirectory: descriptor.workingDirectoryPath,
            records: sessionIndexStore.records
        )
        let contentView = TerminalStatusBarAgentHistoryView(
            history: history,
            resumeRecord: resumeRecord,
            theme: chromeTheme
        )
        contentView.onResume = { [weak self] record in
            self?.insertResumeCommand(record, paneIdentifier: descriptor.paneIdentifier)
        }
        present(contentView: contentView, relativeTo: agentSegmentView)
    }

    /// Newest indexed session whose recorded working directory matches the
    /// pane's. Pure so the lookup rule is testable without the store.
    static func resumableSession(
        forWorkingDirectory workingDirectoryPath: String,
        records: [AgentSessionRecord]
    ) -> AgentSessionRecord? {
        let normalizedPath = workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            return nil
        }
        return records
            .filter { $0.cwd.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedPath }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func insertResumeCommand(_ record: AgentSessionRecord, paneIdentifier: String) {
        activePopover?.close()
        // Inserted only; there is no execute path, so no trailing newline.
        dataSource?.statusBarInsertText(
            AgentSessionResumeCommand.command(for: record),
            paneIdentifier: paneIdentifier
        )
    }

    private func worktreeSegmentClicked() {
        let rows = GitWorktreeRowBuilder.rows(
            snapshot: worktreeSnapshot ?? .empty,
            records: sessionIndexStore.records
        )
        let contentView = TerminalStatusBarWorktreeListView(rows: rows, theme: chromeTheme)
        contentView.onChangeDirectory = { [weak self] worktree in
            self?.insertChangeDirectoryCommand(worktree)
        }
        present(contentView: contentView, relativeTo: worktreeSegmentView)
    }

    private func insertChangeDirectoryCommand(_ worktree: GitWorktree) {
        guard let paneIdentifier = activePaneDescriptor?.paneIdentifier else {
            return
        }
        activePopover?.close()
        // Inserted only; there is no execute path, so no trailing newline.
        dataSource?.statusBarInsertText(
            GitWorktreeChangeDirectoryCommand.command(for: worktree),
            paneIdentifier: paneIdentifier
        )
    }

    private func resourceSegmentClicked() {
        let usage = sampler.latestUsage
        let contentView = TerminalStatusBarProcessUsageView(usage: usage, theme: chromeTheme)
        contentView.onQuitProcess = { [weak self] paneUsage in
            self?.confirmQuitProcess(paneUsage)
        }
        present(contentView: contentView, relativeTo: resourceSegmentView)
    }

    private func confirmQuitProcess(_ paneUsage: TerminalPaneResourceUsage) {
        guard let processIdentifier = paneUsage.processIdentifier else {
            return
        }
        let ownedProcessIdentifiers = Set(
            (dataSource?.statusBarPaneDescriptors() ?? []).compactMap(\.shellProcessIdentifier)
        )
        // Ask the policy before showing anything: a reserved or unowned pid
        // must never even reach a confirmation dialog.
        let precheck = TerminalProcessKillPolicy.decision(
            processIdentifier: processIdentifier,
            ownedProcessIdentifiers: ownedProcessIdentifiers,
            isConfirmed: false
        )
        guard precheck == .requiresConfirmation else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = AppLocalization.string(.statusBarQuitProcessTitle)
        alert.informativeText = AppLocalization.string(.statusBarQuitProcessMessage)
        alert.addButton(withTitle: AppLocalization.string(.statusBarQuitProcessConfirm))
        alert.addButton(withTitle: AppLocalization.string(.cancel))
        let isConfirmed = alert.runModal() == .alertFirstButtonReturn
        let decision = TerminalProcessKillPolicy.decision(
            processIdentifier: processIdentifier,
            ownedProcessIdentifiers: ownedProcessIdentifiers,
            isConfirmed: isConfirmed
        )
        guard decision == .terminate else {
            return
        }
        activePopover?.close()
        TerminalResourceUsageSampler.terminate(processIdentifier: processIdentifier)
    }

    private func present(contentView: NSView, relativeTo segmentView: NSView) {
        activePopover?.close()
        let popover = NSPopover()
        let controller = NSViewController()
        controller.view = contentView
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = chromeTheme.windowAppearance
        popover.show(relativeTo: segmentView.bounds, of: segmentView, preferredEdge: .maxY)
        activePopover = popover
    }
}
