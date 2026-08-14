import AppKit
import KurottyCore

final class TerminalPaneView: NSView {
    private let chromeView = PaneChromeView()
    /// Leading-edge accent rail marking the active pane, plus a bottom hairline
    /// separating the header from the terminal surface.
    private let activeIndicatorView = NSView()
    private let chromeBottomEdgeView = NSView()
    private let statusDotView = NSView()
    private let agentActivityIndicatorView = AgentActivityIndicatorView(frame: .zero)
    private let titleField = NSTextField(labelWithString: "~ (-zsh)")
    private let closeButton = ChromeIconButton(
        symbolName: IconSymbol.close,
        accessibilityLabel: AppLocalization.string(.closePane),
        size: .small,
        target: nil,
        action: nil
    )
    private let terminalSurfaceView: TerminalSurfaceView
    /// Retained so pane-level chrome (the window status bar) can ask the
    /// session for optional capabilities such as its shell pid. The surface
    /// owns the session's I/O; this reference is read-only.
    private let session: any TerminalSession
    private let searchBarView = TerminalSearchBarView()
    private let childExitBannerView = TerminalChildExitBannerView()
    private let commandProgressBarView = TerminalCommandProgressBarView()
    private var chromeHeightConstraint: NSLayoutConstraint?
    private var agentActivityWidthConstraint: NSLayoutConstraint?
    private var agentActivityTitleGapConstraint: NSLayoutConstraint?
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var isChromeActive = false
    private var isChromeHovered = false
    private var isTmuxDisplayTitleManaged = false
    /// Stable identity for the agent activity channel and for the
    /// `KUROTTY_PANE_ID` value injected into this pane's PTY. Generated here so
    /// the pane, its PTY, and the registry always agree.
    let agentPaneIdentifier: String

    var closeRequested: ((TerminalPaneView) -> Void)?
    var focusChanged: ((TerminalPaneView) -> Void)?
    var detachDragRequested: ((TerminalPaneView, NSEvent) -> Void)?
    /// Close of a pane whose child process has already ended, from the exit
    /// banner or from `terminal.closeOnChildExit`. Separate from
    /// `closeRequested` because a dead pane that is its tab's last one has to
    /// take the tab with it, while the header close button stops at the pane.
    var childExitCloseRequested: ((TerminalPaneView) -> Void)?
    /// Replace this pane with a freshly launched one.
    var restartRequested: ((TerminalPaneView) -> Void)?

    /// Whether the exit banner is on screen. Read by tests, which have no other
    /// way to observe an overlay that owns no model state of its own.
    var isChildExitBannerVisibleForTesting: Bool {
        !childExitBannerView.isHidden
    }

    var terminalSurface: TerminalSurfaceView {
        terminalSurfaceView
    }

    var automaticallyFocusesWhenAttached: Bool {
        get { terminalSurfaceView.automaticallyFocusesWhenAttached }
        set { terminalSurfaceView.automaticallyFocusesWhenAttached = newValue }
    }

    var displayTitle: String {
        titleField.stringValue
    }

    var isSearchVisibleForTesting: Bool {
        !searchBarView.isHidden
    }

    /// The pane's command progress bar. Exposed so a test can drive the same
    /// lifecycle the surface forwards without standing up a PTY.
    var commandProgressBarForTesting: TerminalCommandProgressBarView {
        commandProgressBarView
    }

    /// The pane's two top-edge overlays as laid out. Exposed so a test can
    /// assert their real frames against each other instead of re-deriving the
    /// constraints that produced them.
    var topOverlayFramesForTesting: (progressBar: NSRect, searchBar: NSRect, terminal: NSRect) {
        (commandProgressBarView.frame, searchBarView.frame, terminalSurfaceView.frame)
    }

    func setTmuxDisplayTitle(_ title: String) {
        isTmuxDisplayTitleManaged = true
        if !title.isEmpty {
            titleField.stringValue = title
        }
    }

    var ownsFirstResponder: Bool {
        guard let firstResponder = window?.firstResponder else {
            return false
        }
        guard let firstResponderView = firstResponder as? NSView else {
            return firstResponder === terminalSurfaceView
        }
        return firstResponderView === self
            || firstResponderView === terminalSurfaceView
            || firstResponderView.isDescendant(of: self)
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, session: TerminalSessionFactory.makeDefaultSession())
    }

    init(frame frameRect: NSRect, session: any TerminalSession) {
        // Generated locally because the surface starts the shell inside its own
        // init, before `super.init()` lets us read `self.agentPaneIdentifier`.
        let paneIdentifier = UUID().uuidString
        agentPaneIdentifier = paneIdentifier
        self.session = session
        terminalSurfaceView = TerminalSurfaceView(
            frame: .zero,
            session: session,
            paneIdentifier: paneIdentifier
        )
        super.init(frame: frameRect)
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.backgroundColor = ChromeGroundGradient.descendantFill.cgColor
        applyCardShape()
        configureLayout()
        observeTerminalTitle()
        observeTerminalFocus()
        observeAgentActivity()
        observeSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        let paneIdentifier = agentPaneIdentifier
        // Registry is main-actor isolated; deinit may run off it, so hop.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AgentActivityRegistry.shared.removePane(paneIdentifier)
            }
        }
    }

    /// Rounds the pane into the card the window ground shows around.
    ///
    /// The mask goes on the pane rather than on the surface so the header, the
    /// terminal, and every overlay pinned to the pane's edges are cut by one
    /// shape; masking them individually would leave the progress bar drawing
    /// square corners over a rounded card.
    ///
    /// Clipping is safe here only because the terminal grid already stops
    /// `Space.terminal*PX` short of the pane edge, which is at or above
    /// `TerminalPaneCard.minimumGridInsetPX`. The arc therefore cuts through the
    /// surface's background band and never through a cell.
    private func applyCardShape() {
        layer?.cornerRadius = DesignTokens.TerminalPaneCard.cornerRadiusPX
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    private func configureLayout() {
        chromeView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.onHoverChanged = { [weak self] isHovered in
            self?.isChromeHovered = isHovered
            self?.updateChromeAppearance()
        }
        chromeView.onSelect = { [weak self] in
            self?.focusTerminal()
        }
        chromeView.onDragRequested = { [weak self] event in
            guard let self else {
                return
            }
            self.beginDraggingPane(self, with: event)
        }
        addSubview(chromeView)

        activeIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        activeIndicatorView.wantsLayer = true
        activeIndicatorView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        activeIndicatorView.layer?.backgroundColor = chromeTheme.activeIndicator.cgColor
        chromeView.addSubview(activeIndicatorView)

        chromeBottomEdgeView.translatesAutoresizingMaskIntoConstraints = false
        chromeBottomEdgeView.wantsLayer = true
        chromeBottomEdgeView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        chromeBottomEdgeView.layer?.backgroundColor = chromeTheme.hairline.cgColor
        chromeView.addSubview(chromeBottomEdgeView)

        statusDotView.translatesAutoresizingMaskIntoConstraints = false
        statusDotView.wantsLayer = true
        statusDotView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        statusDotView.layer?.cornerRadius = DesignTokens.Component.terminalPaneChromeDotSizePX / 2
        chromeView.addSubview(statusDotView)

        agentActivityIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(agentActivityIndicatorView)

        DesignTokens.Typography.paneHeader.apply(to: titleField, color: chromeTheme.textSecondary)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(titleField)

        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed(_:))
        closeButton.toolTip = TerminalCommandTooltip.text(for: .closeCurrentPane)
        closeButton.applyChromeTheme(chromeTheme)
        chromeView.addSubview(closeButton)

        terminalSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalSurfaceView)
        addSubview(searchBarView)
        addSubview(childExitBannerView)
        // Added last so the bar composites over the terminal surface, the same
        // way the search bar and the exit banner do.
        addSubview(commandProgressBarView)

        terminalSurfaceView.onChildExit = { [weak self] exit in
            self?.handleChildExit(exit)
        }
        terminalSurfaceView.onCommandProgress = { [weak self] event in
            self?.commandProgressBarView.handle(event)
        }
        childExitBannerView.onRestart = { [weak self] in
            guard let self else { return }
            self.restartRequested?(self)
        }
        childExitBannerView.onClose = { [weak self] in
            guard let self else { return }
            self.childExitCloseRequested?(self)
        }

        searchBarView.onQueryChanged = { [weak self] query in
            self?.terminalSurfaceView.updateSearchQuery(query)
        }
        searchBarView.onOptionsChanged = { [weak self] options in
            self?.terminalSurfaceView.updateSearchOptions(options)
        }
        searchBarView.onNextMatch = { [weak self] in
            self?.terminalSurfaceView.selectNextSearchMatch()
        }
        searchBarView.onPreviousMatch = { [weak self] in
            self?.terminalSurfaceView.selectPreviousSearchMatch()
        }
        searchBarView.onClose = { [weak self] in
            self?.closeSearch()
        }
        terminalSurfaceView.onSearchSummaryChange = { [weak searchBarView] summary in
            searchBarView?.update(summary: summary)
        }
        terminalSurfaceView.closeSearchRequested = { [weak self] in
            self?.closeSearch()
        }

        let chromeHeightConstraint = chromeView.heightAnchor.constraint(equalToConstant: 0)
        self.chromeHeightConstraint = chromeHeightConstraint
        // Both collapse to 0 while no agent status is present, so the header
        // keeps its existing geometry until an agent actually reports.
        let agentActivityWidthConstraint = agentActivityIndicatorView.widthAnchor.constraint(equalToConstant: 0)
        self.agentActivityWidthConstraint = agentActivityWidthConstraint
        let agentActivityTitleGapConstraint = titleField.leadingAnchor.constraint(
            equalTo: agentActivityIndicatorView.trailingAnchor,
            constant: 0
        )
        self.agentActivityTitleGapConstraint = agentActivityTitleGapConstraint
        NSLayoutConstraint.activate([
            chromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeView.topAnchor.constraint(equalTo: topAnchor),
            chromeHeightConstraint,

            activeIndicatorView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor),
            activeIndicatorView.topAnchor.constraint(equalTo: chromeView.topAnchor),
            activeIndicatorView.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor),
            activeIndicatorView.widthAnchor.constraint(
                equalToConstant: DesignTokens.Component.terminalPaneChromeActiveRailWidthPX
            ),

            chromeBottomEdgeView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor),
            chromeBottomEdgeView.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor),
            chromeBottomEdgeView.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor),
            chromeBottomEdgeView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.hairlinePX
            ),

            statusDotView.leadingAnchor.constraint(
                equalTo: chromeView.leadingAnchor,
                constant: DesignTokens.Component.terminalPaneChromeDotInsetXPX
            ),
            statusDotView.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),
            statusDotView.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalPaneChromeDotSizePX),
            statusDotView.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalPaneChromeDotSizePX),

            agentActivityIndicatorView.leadingAnchor.constraint(
                equalTo: statusDotView.trailingAnchor,
                constant: DesignTokens.Space.x3PX
            ),
            agentActivityIndicatorView.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),
            agentActivityIndicatorView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.agentActivityIndicatorSizePX
            ),
            agentActivityWidthConstraint,
            agentActivityTitleGapConstraint,

            titleField.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor,
                constant: -DesignTokens.Space.x2PX
            ),
            titleField.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),

            closeButton.trailingAnchor.constraint(
                equalTo: chromeView.trailingAnchor,
                constant: -DesignTokens.Space.x3PX
            ),
            closeButton.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalPaneChromeCloseWidthPX),
            closeButton.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalPaneChromeCloseWidthPX),

            terminalSurfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalSurfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalSurfaceView.topAnchor.constraint(equalTo: chromeView.bottomAnchor),
            terminalSurfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),

            searchBarView.trailingAnchor.constraint(
                equalTo: terminalSurfaceView.trailingAnchor,
                constant: -DesignTokens.Component.terminalSearchInsetPX
            ),
            searchBarView.topAnchor.constraint(
                equalTo: terminalSurfaceView.topAnchor,
                constant: DesignTokens.Component.terminalSearchInsetPX
            ),
        ])
        searchBarView.leadingAnchor.constraint(
            greaterThanOrEqualTo: terminalSurfaceView.leadingAnchor,
            constant: DesignTokens.Component.terminalSearchInsetPX
        ).isActive = true
        NSLayoutConstraint.activate([
            // The pane's top edge as the user sees it: below the header when a
            // split shows one, at the very top of the pane when it does not.
            commandProgressBarView.leadingAnchor.constraint(equalTo: terminalSurfaceView.leadingAnchor),
            commandProgressBarView.trailingAnchor.constraint(equalTo: terminalSurfaceView.trailingAnchor),
            commandProgressBarView.topAnchor.constraint(equalTo: terminalSurfaceView.topAnchor),
            commandProgressBarView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.commandProgressBarHeightPX
            ),
        ])
        NSLayoutConstraint.activate([
            childExitBannerView.leadingAnchor.constraint(
                equalTo: terminalSurfaceView.leadingAnchor,
                constant: DesignTokens.Component.childExitBannerInsetPX
            ),
            childExitBannerView.topAnchor.constraint(
                equalTo: terminalSurfaceView.topAnchor,
                constant: DesignTokens.Component.childExitBannerInsetPX
            ),
            childExitBannerView.trailingAnchor.constraint(
                lessThanOrEqualTo: terminalSurfaceView.trailingAnchor,
                constant: -DesignTokens.Component.childExitBannerInsetPX
            ),
        ])
        setChromeVisible(false)
        updateChromeAppearance()
        updateAgentActivityIndicator()
        applyCommandProgressSetting((try? AppSettingsStore.shared.load()) ?? .default)
    }

    override func viewDidMoveToWindow() {
        if automaticallyFocusesWhenAttached {
            window?.makeFirstResponder(terminalSurfaceView)
        }
    }

    func focusTerminal() {
        window?.makeFirstResponder(terminalSurfaceView)
    }

    func showSearch() {
        if searchBarView.isHidden {
            terminalSurfaceView.beginSearchPresentation()
            searchBarView.present(query: "")
        } else {
            searchBarView.present()
        }
    }

    func closeSearch(restoringTerminalFocus: Bool = true) {
        guard !searchBarView.isHidden else { return }
        searchBarView.dismiss()
        terminalSurfaceView.endSearchPresentation()
        if restoringTerminalFocus {
            focusTerminal()
        }
    }

    func sendText(_ text: String) {
        terminalSurfaceView.sendText(text)
    }

    func jumpToPrompt(_ direction: TerminalPromptRailNavigation.Direction) {
        terminalSurfaceView.jumpToPrompt(direction)
    }

    func commandSpanPaletteCommands() -> [TerminalCommandSpanCommand] {
        terminalSurfaceView.commandSpanPaletteCommands()
    }

    func executeCommandSpanPaletteCommand(_ command: TerminalCommandSpanCommand) -> Bool {
        terminalSurfaceView.executeCommandSpanPaletteCommand(command)
    }

    func layoutOnlyDescriptor(id: String) -> WorkspaceSnapshotCoordinator.PaneDescriptor {
        WorkspaceSnapshotCoordinator.PaneDescriptor(
            id: id
        )
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = ChromeGroundGradient.descendantFill.cgColor
        searchBarView.applyChromeTheme(theme)
        childExitBannerView.applyChromeTheme(theme)
        agentActivityIndicatorView.applyChromeTheme(theme)
        commandProgressBarView.applyChromeTheme(theme)
        updateChromeAppearance()
    }

    /// The pane's child process is gone: decide between closing the pane and
    /// keeping it behind the exit banner.
    ///
    /// The banner goes up first in every case. When the policy says close, the
    /// owner may still refuse — a tab's last pane cannot be removed on its own
    /// — and the already-visible banner is what the user is left with instead
    /// of a frozen, unexplained pane.
    ///
    /// The setting is read here rather than mirrored, matching
    /// `confirmCloseRunningProcess`: both are one-shot decisions taken at the
    /// moment of a close, so the current value always applies with no restart.
    private func handleChildExit(_ exit: TerminalChildExit) {
        // A pane already detached from its container has nothing left to
        // explain and no owner to ask. tmux teardown reaches here that way: it
        // removes the pane and then reaps its session, and the exit callback
        // lands one main-queue hop later.
        guard superview != nil else { return }
        childExitBannerView.present(exit: exit)
        let settings = (try? AppSettingsStore.shared.load()) ?? .default
        let action = TerminalChildExitPolicy.action(
            mode: settings.terminal.closeOnChildExit,
            status: exit.status
        )
        guard action == .closePane else { return }
        childExitCloseRequested?(self)
    }

    /// Releases the pane's PTY resources. Called when the pane is discarded
    /// while its view tree is torn down separately, such as a restart swap.
    func stopSession() {
        session.stop()
    }

    func beginDraggingPane(_ pane: TerminalPaneView, with event: NSEvent) {
        detachDragRequested?(pane, event)
    }

    func setChromeVisible(_ isVisible: Bool) {
        chromeHeightConstraint?.constant = isVisible ? DesignTokens.Component.terminalPaneChromeHeightPX : 0
        chromeView.isHidden = !isVisible
    }

    func setChromeActive(_ isActive: Bool) {
        isChromeActive = isActive
        updateChromeAppearance()
    }

    @objc private func closeButtonPressed(_ sender: NSButton) {
        closeRequested?(self)
    }

    private func updateChromeAppearance() {
        // The header is the top of the card, not a strip of window chrome, so
        // it takes the surface one step above the ground. On `surfaceChrome` it
        // was the same color as the ground the card floats on, which made the
        // card's rounded top corners invisible and left the header reading as
        // background with the terminal starting below it. Hover stays the
        // achromatic wash and never a second surface color.
        chromeView.layer?.backgroundColor = chromeTheme.paneHeaderBackground.cgColor
        chromeView.layer?.borderWidth = 0
        chromeHoverOverlayColor = isChromeHovered ? chromeTheme.hoverFill : .clear
        activeIndicatorView.isHidden = !isChromeActive
        activeIndicatorView.layer?.backgroundColor = chromeTheme.accent.cgColor
        chromeBottomEdgeView.layer?.backgroundColor = chromeTheme.hairline.cgColor
        statusDotView.layer?.backgroundColor = (isChromeActive
            ? chromeTheme.success
            : chromeTheme.inactiveStatusDot).cgColor
        DesignTokens.Typography.paneHeader.apply(
            to: titleField,
            color: isChromeActive || isChromeHovered ? chromeTheme.textSecondary : chromeTheme.textTertiary
        )
        closeButton.applyChromeTheme(chromeTheme)
        // The rest tint tracks the header's own active/hover state, so a quiet
        // pane's close glyph stays quiet; everything else comes from the theme.
        closeButton.normalTintColor = isChromeActive || isChromeHovered
            ? chromeTheme.textSecondary
            : chromeTheme.textTertiary
    }

    /// Hover wash for the header, painted by `PaneChromeView` behind its
    /// children so the rail, dot, and title stay at full contrast.
    private var chromeHoverOverlayColor: NSColor {
        get { chromeView.hoverOverlayColor }
        set { chromeView.hoverOverlayColor = newValue }
    }

    private func observeTerminalTitle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalTitleDidChange(_:)),
            name: TerminalSurfaceView.titleDidChangeNotification,
            object: terminalSurfaceView
        )
    }

    private func observeTerminalFocus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalFocusDidChange(_:)),
            name: TerminalSurfaceView.focusDidChangeNotification,
            object: terminalSurfaceView
        )
    }

    /// The progress bar is the one piece of pane chrome with its own setting, so
    /// the pane — not the window — has to hear the change: a bar the user is
    /// looking at right now must go away the moment they turn it off.
    private func observeSettings() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        applyCommandProgressSetting(settings)
    }

    private func applyCommandProgressSetting(_ settings: AppSettings) {
        commandProgressBarView.setEnabled(settings.terminal.commandProgressIndicatorEnabled)
    }

    private func observeAgentActivity() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentActivityDidChange(_:)),
            name: AgentActivityRegistry.didChangeNotification,
            object: nil
        )
    }

    @objc private func agentActivityDidChange(_ notification: Notification) {
        let changedPaneIdentifier = notification.userInfo?[
            AgentActivityRegistry.paneIdentifierNotificationKey
        ] as? String
        guard changedPaneIdentifier == nil || changedPaneIdentifier == agentPaneIdentifier else {
            return
        }
        updateAgentActivityIndicator()
    }

    /// Snapshot of this pane for the window status bar.
    ///
    /// `shellProcessIdentifier` is `nil` for sessions that do not own a real
    /// child process (tmux placeholders, test doubles) and for PTY sessions
    /// until `TerminalShellProcessIdentifying` is adopted by the session type.
    var statusBarDescriptor: TerminalStatusBarPaneDescriptor {
        // The title is read into a local first so this live-chrome descriptor
        // can never be confused with the layout-only workspace snapshot, which
        // must not persist runtime titles.
        let paneTitle = displayTitle
        return TerminalStatusBarPaneDescriptor(
            paneIdentifier: agentPaneIdentifier,
            title: paneTitle,
            shellProcessIdentifier: shellProcessIdentifier,
            workingDirectoryPath: terminalSurfaceView.workingDirectoryPath,
            isWorkingDirectoryRemote: terminalSurfaceView.workingDirectoryLocation.isRemote
        )
    }

    /// The pane's shell child pid, when the session publishes one.
    var shellProcessIdentifier: pid_t? {
        guard let identifying = session as? any TerminalShellProcessIdentifying else {
            return nil
        }
        let processIdentifier = identifying.shellProcessIdentifier
        return processIdentifier > 1 ? processIdentifier : nil
    }

    /// Resolved agent status for this pane, or `nil` when nothing should show.
    var agentActivityStatus: AgentActivityStatus? {
        AgentActivityRegistry.shared.status(for: agentPaneIdentifier)
    }

    private func updateAgentActivityIndicator() {
        let status = agentActivityStatus
        agentActivityIndicatorView.update(status: status)
        agentActivityWidthConstraint?.constant = status == nil
            ? 0
            : DesignTokens.Component.agentActivityIndicatorSizePX
        agentActivityTitleGapConstraint?.constant = status == nil ? 0 : DesignTokens.Space.x2PX
    }

    @objc private func terminalFocusDidChange(_ notification: Notification) {
        focusChanged?(self)
    }

    @objc private func terminalTitleDidChange(_ notification: Notification) {
        guard !isTmuxDisplayTitleManaged else { return }
        guard let title = notification.userInfo?[TerminalSurfaceView.titleNotificationKey] as? String else {
            return
        }
        titleField.stringValue = title
    }
}

private final class PaneChromeView: NSView {
    private enum Drag {
        static let thresholdPX: CGFloat = 4
    }

    var onHoverChanged: ((Bool) -> Void)?
    var onSelect: (() -> Void)?
    var onDragRequested: ((NSEvent) -> Void)?
    /// Achromatic hover wash. A separate layer rather than a second background
    /// color so hover and "this pane is active" stay independent cues.
    var hoverOverlayColor: NSColor = .clear {
        didSet { hoverOverlayLayer.backgroundColor = hoverOverlayColor.cgColor }
    }

    private let hoverOverlayLayer = CALayer()
    private var mouseDownLocationInWindow = NSPoint.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hoverOverlayLayer.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        hoverOverlayLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(hoverOverlayLayer)
    }

    override func layout() {
        super.layout()
        hoverOverlayLayer.frame = bounds
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocationInWindow = event.locationInWindow
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        let dragDeltaX = abs(event.locationInWindow.x - mouseDownLocationInWindow.x)
        let dragDeltaY = abs(event.locationInWindow.y - mouseDownLocationInWindow.y)
        guard max(dragDeltaX, dragDeltaY) >= Drag.thresholdPX else {
            return
        }
        onDragRequested?(event)
    }
}
