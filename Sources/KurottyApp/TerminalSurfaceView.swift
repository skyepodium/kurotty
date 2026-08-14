import AppKit
import KurottyCore

@MainActor
final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient, TerminalPasteWriting {
    static let titleDidChangeNotification = Notification.Name("dev.kurotty.terminalSurface.titleDidChange")
    static let focusDidChangeNotification = Notification.Name("dev.kurotty.terminalSurface.focusDidChange")
    static let tmuxControlModeDidActivateNotification = Notification.Name("dev.kurotty.terminalSurface.tmuxControlModeDidActivate")
    static let tmuxControlModeDriverNotificationKey = "driver"
    static let titleNotificationKey = "title"
    private static let runtimeEventLedgerCapacity = 4_096

    private let core: any TerminalCore = TerminalCoreFactory.makeDefaultCore(
        cols: UInt32(AppConstants.Terminal.defaultColumns),
        rows: UInt32(AppConstants.Terminal.defaultRows)
    )
    private let shell: any TerminalSession
    private let notifier = TerminalNotifier.shared
    private let renderer: any TerminalAppKitRenderer
    private let securityPolicy = TerminalSecurityPolicy.default
    /// Holds an OSC 52 confirmation until this pane is the one the user is
    /// looking at. Owned by the surface and cleared on teardown, so nothing it
    /// holds can outlive the session that produced it.
    private var clipboardConfirmationQueue = TerminalClipboardConfirmationQueue()
    private lazy var scrollIndicatorCoordinator = TerminalScrollIndicatorCoordinator { [weak self] normalizedOffset in
        self?.setScrollbackOffset(fromNormalizedOffset: normalizedOffset)
    }
    private lazy var promptRailCoordinator = TerminalPromptRailCoordinator()
    /// Absolute scrollback row of the prompt OSC 133 last reported, held from
    /// the `A` boundary until the matching `D`. The span itself cannot carry it:
    /// `TerminalShellIntegration` is a pure value type with no view of the
    /// screen, and the row is only knowable at the instant the sequence is
    /// parsed, before any further output moves the cursor.
    private var pendingPromptAbsoluteRowIndex: Int?
    /// Internal rather than private so sibling seams that must drive the parser
    /// directly — scrollback replay, which raises `isReplayingScrollback`
    /// around the feed — can reach it without a second parser entry point.
    let interpreter: TerminalOutputInterpreter
    private var viewportBackground: SIMD4<Float>?
    private var scrollWheelAccumulator = TerminalScrollWheelAccumulator()
    private var cursorBlinkOn = true
    private var cursorBlinkTimer: Timer?
    private var selectionAnchor: TerminalCellPosition?
    private var selectionFocus: TerminalCellPosition?
    private var selectionGestureState = TerminalSelectionGestureState()
    private var searchQuery = ""
    /// Survives close and reopen of the bar, because the toggles in the bar do.
    private var searchOptions = TerminalSearchOptions.default
    private var searchResults = TerminalSearchResults.empty
    private var currentSearchMatchIndex: Int?
    private var searchGeneration: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var isSearchPresentationActive = false
    private var terminalTrackingArea: NSTrackingArea?
    private var hoveredLinkRange: TerminalLinkRange?
    /// Bounded existence answers for `path:line:col` link candidates. Hit-testing
    /// runs on every mouse move, so it only ever reads this cache; misses are
    /// stat'd by `filePathExistsProbe` off the main actor.
    private let filePathExistsCache = TerminalPathExistsCache()
    private let filePathExistsProbe = TerminalPathExistsProbe()
    private var markedText = NSMutableAttributedString()
    private var inputSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var markedTextAnchor: TerminalCellPosition?
    private var pendingMarkedTextAnchor: TerminalCellPosition?
    private var committedMarkedTextPrefix = ""
    private var committedMarkedTextPrefixAnchor: TerminalCellPosition?
    private var markedTextInputSourceID: String?
    private var inputSourceChangeCommitToSuppress: String?
    private var textInputEventDepth = 0
    private var needsDeferredTextInputFrame = false
    private var isTextInputRendererFrameScheduled = false
    private var keyTextAccumulator: [String]?
    private var keyboardSelectionInputStart: TerminalCellPosition?
    private var font: NSFont
    /// The last settings this surface applied. Held so a font-zoom change can
    /// re-run the appearance path without a second settings load per pane.
    private var appliedSettings: AppSettings
    private var pendingOutputText = ""
    private var isOutputFlushScheduled = false
    private var submittedCommandRecorder = TerminalSubmittedCommandRecorder()
    private var lastSubmittedCommandText: String?
    private var debugFrameIndex: UInt64 = 0
    private var runtimeEventLedger = TerminalEventLedger(capacity: TerminalSurfaceView.runtimeEventLedgerCapacity)
    private var pendingRuntimeOutputEvents: [TerminalEventLedger.RecordedEvent] = []
    private var outputFlushTraceSequence: UInt64 = 0
    private var activeOutputRuntimeEventBatch: TerminalRuntimeEventBatch?
    private var outputInterceptor: ((String) -> String)?
    /// Stable identity shared by this surface, its PTY (`KUROTTY_PANE_ID`), and
    /// the agent activity registry.
    let agentPaneIdentifier: String
    /// Strips OSC 9999 agent-status sequences out of the PTY stream before any
    /// of it can reach the screen model.
    private let agentStatusChannel: AgentStatusOutputChannel
    /// Live mirror of `terminal.hideMouseCursorWhileTyping`; read on every
    /// `keyDown`, so it must never touch the filesystem.
    private var hideMouseCursorWhileTypingEnabled: Bool
    /// Live mirror of `terminal.confirmMultilinePaste`; read on every paste, so
    /// it must never touch the filesystem.
    private var confirmMultilinePasteEnabled: Bool
    /// Live mirrors of `terminal.notifyOnCommandFinish` and
    /// `terminal.minimumCommandDurationSeconds`; read on every OSC 133;D, so
    /// they must never touch the filesystem.
    private var commandFinishNotificationMode: TerminalCommandFinishNotificationMode
    private var minimumCommandDurationSeconds: Double
    /// Live mirror of `terminal.notifyOnAgentWaiting`, read on every reported
    /// agent state and on every focus change.
    private var notifyOnAgentWaitingEnabled: Bool
    /// This pane's waiting-banner state machine. One per surface, so the
    /// per-pane debounce and the outstanding-banner bookkeeping are simply its
    /// own fields.
    private var agentWaitingNotificationPolicy = AgentWaitingNotificationPolicy()
    private let pasteLimits = TerminalPasteLimits.default
    /// Tracks the drop border so repeated `draggingUpdated` callbacks — AppKit
    /// sends one per mouse move — do not re-set the same layer properties.
    private var isFileDropHighlighted = false
    var automaticallyFocusesWhenAttached = true
    /// Raised once when this surface's child process is gone. The owning pane
    /// decides what to show and whether to close; the surface only reports.
    var onChildExit: ((TerminalChildExit) -> Void)?
    /// Command lifecycle for the pane's progress bar: an OSC 133 boundary
    /// opening or closing a command span, or an OSC 9;4 report inside one. The
    /// surface only reports; the pane owns the bar and every visibility rule.
    var onCommandProgress: ((TerminalCommandProgressEvent) -> Void)?
    var onSearchSummaryChange: ((TerminalSearchSummary) -> Void)?
    var closeSearchRequested: (() -> Void)?
    private lazy var tmuxControlModeDriver = TmuxControlModeDriver { [weak self] command in
        self?.writeSession(command)
    }
    private var windowScreenObserver: NSObjectProtocol?
    private var currentBackingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    private let padding = NSEdgeInsets(
        top: DesignTokens.Space.terminalTopPX,
        left: DesignTokens.Space.terminalLeftPX,
        bottom: DesignTokens.Space.terminalBottomPX,
        right: DesignTokens.Space.terminalRightPX
    )

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, session: TerminalSessionFactory.makeDefaultSession())
    }

    /// `paneIdentifier` is supplied by the owning `TerminalPaneView` so the
    /// pane, its PTY environment, and the activity registry agree on one id.
    /// The default keeps every other call site (and every test double) working
    /// with a private identity of its own.
    init(
        frame frameRect: NSRect,
        session: any TerminalSession,
        paneIdentifier: String = UUID().uuidString
    ) {
        shell = session
        agentPaneIdentifier = paneIdentifier
        agentStatusChannel = AgentStatusOutputChannel(paneIdentifier: paneIdentifier)
        let settings = (try? AppSettingsStore.shared.load()) ?? .default
        appliedSettings = settings
        hideMouseCursorWhileTypingEnabled = settings.terminal.hideMouseCursorWhileTyping
        confirmMultilinePasteEnabled = settings.terminal.confirmMultilinePaste
        commandFinishNotificationMode = settings.terminal.commandFinishNotificationMode
        minimumCommandDurationSeconds = settings.terminal.minimumCommandDurationSeconds
        notifyOnAgentWaitingEnabled = settings.terminal.notifyOnAgentWaiting
        let configuredFont = Self.terminalFont(for: settings)
        font = configuredFont
        let terminalDefaultStyle = TerminalTextStyle(
            foreground: settings.terminal.colors.foregroundColor,
            background: settings.terminal.colors.backgroundColor
        )
        interpreter = TerminalOutputInterpreter(
            defaultStyle: terminalDefaultStyle,
            ansiColors: Self.ansiColors(from: settings),
            maxScrollbackRows: max(1, settings.terminal.scrollbackLines)
        )
        renderer = TerminalRendererFactory.makeDefaultRenderer(
            font: configuredFont,
            backgroundColor: terminalDefaultStyle.background,
            cursorColor: settings.terminal.colors.cursorColor
        )
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = terminalDefaultStyle.background.cgColor
        // Only file URLs. Kurotty's own pane drags carry a private pasteboard
        // type that is deliberately not registered here, so a pane dragged over
        // a surface still resolves to the window's pane drop target.
        registerForDraggedTypes([.fileURL])
        let rendererView = renderer.rendererView
        rendererView.translatesAutoresizingMaskIntoConstraints = false
        renderer.onPresented = { [weak self] in
            self?.rendererFramePresented()
        }
        connectImageStoreToRenderer()
        addSubview(rendererView)
        NSLayoutConstraint.activate([
            rendererView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rendererView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rendererView.topAnchor.constraint(equalTo: topAnchor),
            rendererView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The rail installs first so the indicator's thumb draws above it; they
        // never overlap, but z-order decides which one wins if a future token
        // change makes them touch.
        promptRailCoordinator.install(in: self)
        promptRailCoordinator.onSelectAbsoluteRow = { [weak self] absoluteRow in
            self?.scrollToAbsoluteRow(absoluteRow)
        }
        scrollIndicatorCoordinator.install(in: self)
        interpreter.titleReportsEnabled = settings.terminal.titleReportsEnabled
        interpreter.host = TerminalOutputInterpreterHost(
            sendTerminalResponse: { [weak self] text in self?.sendTerminalResponse(text) },
            respondToOscQuery: { [weak self] code in self?.respondToOscQuery(code) },
            dispatchTerminalIntegrationOsc: { [weak self] command in
                self?.dispatchTerminalIntegrationOsc(command) ?? .ignored
            },
            publishTitle: { [weak self] in self?.publishTitle() },
            handleTerminalIntegrationEvent: { [weak self] event in self?.handleTerminalIntegrationEvent(event) },
            handleDesktopNotificationEvent: { [weak self] event in self?.handleDesktopNotificationEvent(event) },
            handleClipboardWriteEvent: { [weak self] event in self?.handleClipboardWriteEvent(event) },
            ringTerminalBell: { [weak self] in self?.ringTerminalBell() },
            updateScrollIndicator: { [weak self] in self?.updateScrollIndicator() },
            maxScrollbackOffset: { [weak self] visibleRows in
                self?.maxScrollbackOffset(visibleRows: visibleRows) ?? 0
            },
            reportTerminalFocusIfNeeded: { [weak self] in self?.reportTerminalFocusIfNeeded() },
            terminalCapabilityMetrics: { [weak self] in self?.terminalCapabilityMetrics() },
            terminalColorSchemeMode: { [weak self] in
                self?.terminalColorSchemeMode ?? TerminalColorSchemeMode(isLightBackground: false)
            }
        )
        installOutputInterceptor { [weak self] text in
            guard let self else { return text }
            let wasActive = tmuxControlModeDriver.isActive
            let visibleText = tmuxControlModeDriver.consume(text)
            if !wasActive, tmuxControlModeDriver.isActive {
                NotificationCenter.default.post(
                    name: Self.tmuxControlModeDidActivateNotification,
                    object: self,
                    userInfo: [Self.tmuxControlModeDriverNotificationKey: tmuxControlModeDriver]
                )
            }
            return visibleText
        }
        shell.onOutput = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                // OSC 9999 is an out-of-band status channel: it is recorded and
                // stripped here so the sequence can never reach the screen model.
                let visibleText = self.agentStatusChannel.filter(self.outputInterceptor?(text) ?? text)
                self.enqueueOutput(visibleText)
            }
        }
        shell.onExit = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                // The tmux transport only speaks exit codes, so the signal case
                // is flattened here and nowhere else; `onChildExit` keeps the
                // full outcome for the pane that owns the exit banner.
                self.tmuxControlModeDriver.transportDidExit(status: status.status.shellExitCode)
                // The program that asked for the clipboard is gone; answering
                // it now would write on behalf of a finished session.
                self.clipboardConfirmationQueue.cancelPending()
                self.onChildExit?(status)
            }
        }
        shell.onRuntimeEvent = { [weak self] event in
            Task { @MainActor in
                self?.recordRuntimeEvent(event)
            }
        }
        if DebugOptions.ptyLog {
            shell.onRawOutput = { data in
                let metadata = TerminalRawPtyLogMetadata(data: data)
                NSLog("%@: %@", AppConstants.Diagnostics.ptyRawLogPrefix, metadata.description)
            }
        }
        renderer.diagnosticRenderingLogEnabled = DebugOptions.layout || DebugOptions.renderRects || DebugOptions.dirtyRects || DebugOptions.backgroundRuns || DebugOptions.cursorCell || DebugOptions.scrollRegion
        // Keep the scaffold available as an explicit diagnostic escape hatch for
        // resize, IME, scrollback, or tmux status-line dirty-rect regressions.
        renderer.diagnosticFullRedrawEnabled = DebugOptions.fullModelRedraw || AppConstants.Rendering.forceFullModelRedrawUntilDamageIsVerified
        renderer.diagnosticCellBoundaryOverlayEnabled = DebugOptions.renderRects
        renderer.diagnosticBaselineOverlayEnabled = DebugOptions.renderRects
        renderer.diagnosticGlyphQuadOverlayEnabled = DebugOptions.renderRects
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: AppSettingsStore.shared
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontZoomDidChange(_:)),
            name: TerminalFontZoomCoordinator.didChangeNotification,
            object: TerminalFontZoomCoordinator.shared
        )
        observeTerminalFocusChanges()
        observeAgentActivityForNotifications()
        observeInputSourceChanges()
        // Resolved here, on the main actor, and handed to the session before the
        // child is spawned. The hook environment is empty unless
        // `terminal.agentStatusHooksEnabled` is on and the listener is bound.
        if let launchConfigurableShell = shell as? TerminalShellLaunchConfigurable {
            launchConfigurableShell.agentStatusHookEnvironment =
                AgentStatusHookCoordinator.shared.shellEnvironment(paneIdentifier: paneIdentifier)
            launchConfigurableShell.perProjectHistoryEnabled = settings.shell.perProjectHistoryEnabled
        }
        shell.start(workingDirectory: settings.shell.workingDirectory)
    }

    private func recordRuntimeEvent(_ event: TerminalEventLedger.RecordedEvent) {
        runtimeEventLedger.record(event)
        if event.payload.kind == .ptyRead {
            pendingRuntimeOutputEvents.append(event)
        }
    }

    func installOutputInterceptor(_ interceptor: @escaping (String) -> String) {
        outputInterceptor = interceptor
    }

    func writeSession(_ text: String) {
        shell.write(text)
    }

    var currentTerminalSize: TerminalSize {
        terminalMetrics().size
    }

    private var terminalKeyEncoderState: TerminalKeyEncoder.State {
        .init(
            applicationCursorKeys: applicationCursorKeysEnabled,
            applicationKeypad: applicationKeypadEnabled,
            modifyOtherKeysMode: modifyOtherKeysMode,
            extendedKeyFormat: extendedKeyFormat
        )
    }

    struct TmuxRestoreStateForTesting: Equatable {
        let cursorRow: Int
        let cursorColumn: Int
        let cursorVisible: Bool
        let isUsingAlternateScreen: Bool
        let insertModeEnabled: Bool
        let originModeEnabled: Bool
        let wraparoundModeEnabled: Bool
        let applicationCursorKeysEnabled: Bool
        let applicationKeypadEnabled: Bool
        let modifyOtherKeysMode: Int
        let extendedKeyFormat: TerminalExtendedKeyFormat
        let bracketedPasteEnabled: Bool
        let mouseTrackingMode: TerminalMouseTrackingMode
        let mouseUsesUTF8: Bool
        let mouseUsesSGR: Bool
        let tabStops: Set<Int>
        let visibleLines: [String]
    }

    struct SearchStateForTesting: Equatable {
        let summary: TerminalSearchSummary
        let currentMatch: TerminalSearchMatch?
        let scrollbackOffset: Int
        let visibleRows: Range<Int>
    }

    func consumeTmuxRestoreOutputForTesting(_ data: Data) {
        appendOutput(String(decoding: data, as: UTF8.self))
    }

    func resizeGridForTesting(columns: Int, rows: Int) {
        cursorRow = screen.resize(rows: rows, columns: columns, anchorRow: cursorRow)
        cursorColumn = min(cursorColumn, max(0, columns - 1))
        lastSentSize = TerminalSize(columns: columns, rows: rows)
        resetScrollRegion()
    }

    var tmuxRestoreStateForTesting: TmuxRestoreStateForTesting {
        .init(
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            cursorVisible: cursorVisible,
            isUsingAlternateScreen: isUsingAlternateScreen,
            insertModeEnabled: insertModeEnabled,
            originModeEnabled: originModeEnabled,
            wraparoundModeEnabled: wraparoundModeEnabled,
            applicationCursorKeysEnabled: applicationCursorKeysEnabled,
            applicationKeypadEnabled: applicationKeypadEnabled,
            modifyOtherKeysMode: modifyOtherKeysMode,
            extendedKeyFormat: extendedKeyFormat,
            bracketedPasteEnabled: bracketedPasteEnabled,
            mouseTrackingMode: mouseReportingState.trackingMode,
            mouseUsesUTF8: mouseReportingState.usesUTF8ExtendedCoordinates,
            mouseUsesSGR: mouseReportingState.usesSGRExtendedCoordinates,
            tabStops: tabStops,
            visibleLines: screen.cells.map { String($0.map(\.character)) }
        )
    }

    var searchStateForTesting: SearchStateForTesting {
        SearchStateForTesting(
            summary: TerminalSearchSummary(
                currentIndex: currentSearchMatchIndex,
                totalMatches: searchResults.matches.count,
                isTruncated: searchResults.isTruncated
            ),
            currentMatch: currentSearchMatch,
            scrollbackOffset: scrollbackOffset,
            visibleRows: visibleContentRowRange()
        )
    }

    func setSelectionForTesting(anchor: TerminalCellPosition?, focus: TerminalCellPosition?) {
        selectionAnchor = anchor
        selectionFocus = focus
    }

    var selectionForTesting: (anchor: TerminalCellPosition?, focus: TerminalCellPosition?) {
        (selectionAnchor, selectionFocus)
    }

    var contentRowCountForTesting: Int {
        contentRowCount
    }

    /// The double-click gesture, without an `NSEvent`.
    ///
    /// `mouseDown` resolves the click to a content-absolute position and then
    /// calls this; a test can supply the position directly and still exercise
    /// the row lookup, which is where the gesture used to go wrong.
    func selectWordForTesting(at position: TerminalCellPosition) {
        selectWord(at: position)
    }

    func terminalSequenceForTesting(_ selector: Selector) -> String? {
        TerminalKeyEncoder.sequence(for: selector, state: terminalKeyEncoderState)
    }

    func terminalSequenceForTesting(_ event: NSEvent) -> String? {
        TerminalKeyEncoder.sequence(for: event, state: terminalKeyEncoderState)
    }

    func beginSearchPresentation() {
        isSearchPresentationActive = true
        updateSearchQuery("")
    }

    func endSearchPresentation() {
        isSearchPresentationActive = false
        searchTask?.cancel()
        searchGeneration &+= 1
        searchQuery = ""
        searchResults = .empty
        currentSearchMatchIndex = nil
        publishSearchSummary()
        markFullDamage()
        updateRendererFrame()
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        restartSearch()
    }

    func updateSearchOptions(_ options: TerminalSearchOptions) {
        guard options != searchOptions else { return }
        searchOptions = options
        restartSearch()
    }

    private func restartSearch() {
        searchResults = .empty
        currentSearchMatchIndex = nil
        publishSearchSummary()
        markFullDamage()
        updateRendererFrame()
        scheduleSearch(
            query: searchQuery,
            preserving: nil,
            delayNanoseconds: AppConstants.Terminal.searchInputDebounceNanoseconds
        )
    }

    func selectNextSearchMatch() {
        moveSearchSelection(by: 1)
    }

    func selectPreviousSearchMatch() {
        moveSearchSelection(by: -1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isOpaque: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let terminalTrackingArea {
            removeTrackingArea(terminalTrackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        terminalTrackingArea = nextTrackingArea
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            startCursorBlinking()
            NotificationCenter.default.post(name: Self.focusDidChangeNotification, object: self)
            handleTerminalFocusStateChange()
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            stopCursorBlinking(showCursor: true)
            NotificationCenter.default.post(name: Self.focusDidChangeNotification, object: self)
            handleTerminalFocusStateChange()
        }
        return didResignFirstResponder
    }

    override func viewDidMoveToWindow() {
        if automaticallyFocusesWhenAttached {
            window?.makeFirstResponder(self)
        }
        currentBackingScale = effectiveBackingScale
        observeWindowScreenChanges()
        syncSizeWithView()
        updateCursorBlinkStateForFocus()
        reportTerminalFocusIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopCursorBlinking(showCursor: true)
            // The pane is being torn down. A held confirmation has no window to
            // open on and no session to answer for.
            clipboardConfirmationQueue.cancelPending()
        }
        removeWindowScreenObserver()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        handleDisplayConfigurationChanged()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportTerminalMouseEvent(.press(.left), with: event) {
            pressedMouseButton = .left
            return
        }
        let position = cellPosition(for: event)
        // A plain left-click belongs to selection: URLs in output have to be
        // clickable-into and drag-selectable like any other text. Requiring a
        // modifier before a link swallows the click is what Ghostty, iTerm2 and
        // kitty all do; ⌘ is the macOS-native one.
        if event.modifierFlags.contains(.command), let link = linkRange(at: position) {
            clearSelection()
            setHoveredLinkRange(link)
            if let fileTarget = link.fileTarget {
                openFileLinkInEditorTab(fileTarget)
            } else {
                activateLink(link)
            }
            return
        }
        if event.clickCount >= 2 {
            selectWord(at: position)
            return
        }
        selectionGestureState.beginCharacterSelection()
        selectionAnchor = position
        selectionFocus = nil
        markFullDamage()
        updateRendererFrame()
    }

    override func mouseMoved(with event: NSEvent) {
        if reportTerminalMouseEvent(.move, with: event) {
            return
        }
        if mouseReportingState.isEnabled, !event.modifierFlags.contains(.shift) {
            setHoveredLinkRange(nil)
            return
        }
        updateHoveredLinkRange(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredLinkRange(nil)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateHoveredLinkRange(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let pressedMouseButton {
            if reportTerminalMouseEvent(.drag(pressedMouseButton), with: event) {
                return
            }
            if mouseReportingState.isEnabled, !event.modifierFlags.contains(.shift) {
                return
            }
        }
        updateSelectionFocus(with: event, autoscroll: true)
    }

    override func mouseUp(with event: NSEvent) {
        if let pressedMouseButton {
            self.pressedMouseButton = nil
            if reportTerminalMouseEvent(.release(pressedMouseButton), with: event) {
                return
            }
        }
        updateSelectionFocus(with: event, autoscroll: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportTerminalMouseEvent(.press(.right), with: event) {
            pressedMouseButton = .right
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if reportTerminalMouseEvent(.drag(.right), with: event) {
            return
        }
        if mouseReportingState.isEnabled, !event.modifierFlags.contains(.shift) {
            return
        }
        super.rightMouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        pressedMouseButton = nil
        if reportTerminalMouseEvent(.release(.right), with: event) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportTerminalMouseEvent(.press(.middle), with: event) {
            pressedMouseButton = .middle
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if reportTerminalMouseEvent(.drag(.middle), with: event) {
            return
        }
        if mouseReportingState.isEnabled, !event.modifierFlags.contains(.shift) {
            return
        }
        super.otherMouseDragged(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        pressedMouseButton = nil
        if reportTerminalMouseEvent(.release(.middle), with: event) {
            return
        }
        super.otherMouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let rowDelta = scrollWheelAccumulator.rows(
            for: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            cellHeightPX: CGFloat(terminalMetrics().cellSize.height)
        )
        if reportTerminalMouseWheel(with: event, rowDelta: rowDelta) {
            return
        }
        if sendAlternateScrollKeysIfNeeded(with: event, rowDelta: rowDelta) {
            return
        }
        guard rowDelta != 0 else { return }

        let maxOffset = maxScrollbackOffset()
        let previousOffset = scrollbackOffset
        if rowDelta > 0 {
            scrollbackOffset = min(maxOffset, scrollbackOffset + rowDelta)
        } else {
            scrollbackOffset = max(0, scrollbackOffset + rowDelta)
        }
        if scrollbackOffset != previousOffset {
            markFullDamage()
        }
        updateScrollIndicator()
        updateRendererFrame()
    }

    override func keyDown(with event: NSEvent) {
        if isSearchPresentationActive, event.keyCode == 53 {
            closeSearchRequested?()
            return
        }
        core.recordKeyEvent()
        // keyboardSelectionDidChange can arrive after the first keystroke on the
        // new input source. If the source changed while a composition is alive,
        // commit the preedit now so this key cannot be written ahead of it.
        if hasMarkedText(), markedTextInputSourceID != inputContext?.selectedKeyboardInputSource {
            commitPendingCompositionForInputSourceChange()
        }
        if handleCommandKey(event) {
            return
        }
        hideMouseCursorWhileTypingIfNeeded(event)
        // Modified ordinary keys must be encoded before NSTextInputContext;
        // otherwise AppKit commits text and discards the protocol modifiers.
        if modifyOtherKeysMode > 0, handleTerminalControlKey(event) {
            return
        }
        if performTextInputTransaction({
            TerminalTextInputRouter.handleKeyDown(event, in: self, hasMarkedText: hasMarkedText())
        }) {
            return
        }
        if handleTerminalControlKey(event) {
            return
        }
        performTextInputTransaction {
            interpretKeyEvents([event])
        }
    }

    /// Ordinary typing hides the pointer until the next mouse move; AppKit
    /// restores it on its own, so there is no paired "show" call to leak.
    private func hideMouseCursorWhileTypingIfNeeded(_ event: NSEvent) {
        guard TerminalTypingCursorHiding.shouldHideCursor(
            characters: event.characters,
            modifierFlags: event.modifierFlags,
            isModalPresentationActive: isModalPresentationActive,
            isEnabled: hideMouseCursorWhileTypingEnabled
        ) else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private var isModalPresentationActive: Bool {
        NSApp.modalWindow != nil || window?.attachedSheet != nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        return handleCommandKey(event) || handleKeyEquivalentTerminalControl(event) || super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return makeTerminalContextMenu()
    }

    func rendererFramePresented() {
        core.recordFramePresented()
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        guard !text.isEmpty else { return }
        let plan = TerminalPastePlanner.plan(
            text: text,
            bracketedPasteEnabled: bracketedPasteEnabled,
            confirmMultilinePaste: confirmMultilinePasteEnabled,
            limits: pasteLimits
        )
        logPastePlan(plan)
        guard plan.isExecutable else {
            presentPasteRejection(plan)
            return
        }
        guard plan.requiresConfirmation else {
            executePaste(plan: plan, text: text)
            return
        }
        presentMultilinePasteConfirmation(plan) { [weak self] confirmed in
            guard let self, confirmed else { return }
            executePaste(plan: plan, text: text)
        }
    }

    private func executePaste(plan: TerminalPastePlan, text: String) {
        pendingMarkedTextAnchor = nil
        clearSelection()
        followLiveOutputForUserInput()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await TerminalPasteExecutor.execute(
                plan: plan,
                text: text,
                limits: pasteLimits,
                writer: self
            )
            logPasteResult(result)
        }
    }

    private func presentMultilinePasteConfirmation(
        _ plan: TerminalPastePlan,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = AppLocalization.format(.pasteLinesQuestion, plan.lineCount)
        // Deliberately omits the pasted text: a confirmation dialog is not a
        // place to mirror clipboard content back onto the screen.
        alert.informativeText = AppLocalization.string(.pasteLinesExplanation)
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: AppLocalization.string(.pasteConfirm))
        alert.addButton(withTitle: AppLocalization.string(.cancel))
        if let window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func presentPasteRejection(_ plan: TerminalPastePlan) {
        guard plan.rejectionReason == .payloadTooLarge else { return }
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.pasteTooLargeTitle)
        alert.informativeText = AppLocalization.format(
            .pasteTooLargeExplanation,
            plan.byteCount,
            pasteLimits.maxBytes
        )
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: AppLocalization.string(.ok))
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func logPastePlan(_ plan: TerminalPastePlan) {
        guard DebugOptions.vtParser else { return }
        NSLog("%@ plan: %@", AppConstants.Diagnostics.pasteLogPrefix, plan.redactedDiagnostic)
    }

    private func logPasteResult(_ result: TerminalPasteExecutionResult) {
        guard DebugOptions.vtParser else { return }
        NSLog(
            "%@ result: status=%@ chunks=%d bytes=%d %@",
            AppConstants.Diagnostics.pasteLogPrefix,
            result.status.rawValue,
            result.chunksWritten,
            result.bytesWritten,
            result.redactedDiagnostic
        )
    }

    // MARK: - File drops

    /// A file dropped onto a pane inserts its path at the shell's cursor rather
    /// than opening or moving anything: the terminal is a place to compose a
    /// command line, and the path is the part that is tedious to type.
    ///
    /// The text goes through the ordinary paste pipeline, so bracketed paste,
    /// the size limit, and the PTY backpressure pacing all apply — a drop of a
    /// thousand files is a paste, and is treated like one.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setFileDropHighlighted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setFileDropHighlighted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setFileDropHighlighted(false)
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        guard let text = TerminalFileDropFormatter.text(
            for: urls,
            style: TerminalFileDropModifiers.style(for: NSEvent.modifierFlags),
            workingDirectory: fileDropWorkingDirectory
        ) else { return false }
        window?.makeFirstResponder(self)
        insertDroppedFileText(text)
        return true
    }

    private func fileDropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppedFileURLs(from: sender).isEmpty else {
            setFileDropHighlighted(false)
            return []
        }
        setFileDropHighlighted(true)
        // Copy, not link or move: nothing on disk is touched, and `.copy` is the
        // operation Finder's own drag feedback promises for this gesture.
        return .copy
    }

    private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }

    /// The directory a relative drop resolves against, or `nil` when there is
    /// none to resolve against. A remote OSC 7 directory names a path on the
    /// other host, so a local file is never under it.
    private var fileDropWorkingDirectory: String? {
        guard workingDirectoryLocation.remoteHost == nil else { return nil }
        let path = workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func setFileDropHighlighted(_ isHighlighted: Bool) {
        guard isFileDropHighlighted != isHighlighted else { return }
        isFileDropHighlighted = isHighlighted
        // Border only. The layer's background is the terminal's own background
        // and the renderer draws into a subview above it, so tinting the fill
        // would either be invisible or fight the renderer for the same pixels.
        layer?.borderWidth = isHighlighted ? DesignTokens.Component.paneDropTargetBorderWidthPX : 0
        layer?.borderColor = isHighlighted ? DesignTokens.Color.paneDropTargetBorder.cgColor : nil
    }

    private func insertDroppedFileText(_ text: String) {
        let plan = TerminalPastePlanner.plan(
            text: text,
            bracketedPasteEnabled: bracketedPasteEnabled,
            confirmMultilinePaste: confirmMultilinePasteEnabled,
            limits: pasteLimits
        )
        logPastePlan(plan)
        guard plan.isExecutable else {
            presentPasteRejection(plan)
            return
        }
        // A file name may legally contain a newline, which makes a drop a
        // multi-line paste and earns the same confirmation an ordinary one gets.
        guard plan.requiresConfirmation else {
            executePaste(plan: plan, text: text)
            return
        }
        presentMultilinePasteConfirmation(plan) { [weak self] confirmed in
            guard let self, confirmed else { return }
            executePaste(plan: plan, text: text)
        }
    }

    @objc func copy(_ sender: Any?) {
        // Without a selection there is nothing to copy. Falling back to the
        // whole visible screen clobbers the pasteboard with unselected text.
        guard let text = selectedText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copySelectionFromContextMenu(_ sender: Any?) {
        guard let text = selectedText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func splitRightFromContextMenu(_ sender: Any?) {
        splitFromContextMenu(.right)
    }

    @objc private func splitLeftFromContextMenu(_ sender: Any?) {
        splitFromContextMenu(.left)
    }

    @objc private func splitDownFromContextMenu(_ sender: Any?) {
        splitFromContextMenu(.down)
    }

    @objc private func splitUpFromContextMenu(_ sender: Any?) {
        splitFromContextMenu(.up)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
    }

    override func selectAll(_ sender: Any?) {
        selectEntireBuffer()
    }

    /// Selects every content row: the full scrollback plus the visible screen.
    /// Selection positions are content-absolute (scrollback + screen), so the
    /// existing highlight rendering and copy path work unchanged.
    private func selectEntireBuffer() {
        let totalRows = contentRowCount
        guard totalRows > 0, screen.columns > 0 else { return }
        selectionGestureState.beginCharacterSelection()
        selectionAnchor = TerminalCellPosition(row: 0, column: 0)
        selectionFocus = TerminalCellPosition(row: totalRows - 1, column: screen.columns - 1)
        markFullDamage()
        updateRendererFrame()
    }

    func sendText(_ text: String) {
        send(text)
    }

    func commandSpanPaletteCommands() -> [TerminalCommandSpanCommand] {
        TerminalCommandSpanPaletteActions.executableCommands(for: latestCompletedCommandSpan())
    }

    func executeCommandSpanPaletteCommand(_ command: TerminalCommandSpanCommand) -> Bool {
        guard let span = latestCompletedCommandSpan() else {
            return false
        }

        switch command.action {
        case .copyReference:
            copyCommandSpanReference(span.locatorString)
            return true
        case .replay:
            guard let candidate = span.replayCandidate,
                  confirmCommandReplay(candidate)
            else {
                return false
            }
            sendText("\(candidate.commandText)\n")
            return true
        case .foldOutput:
            return false
        }
    }

    private func latestCompletedCommandSpan() -> TerminalCommandSpan? {
        shellIntegration.recentCommandSpans.last
    }

    private func copyCommandSpanReference(_ locatorString: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(locatorString, forType: .string)
    }

    private func confirmCommandReplay(_ candidate: TerminalCommandReplayCandidate) -> Bool {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.replayCommandQuestion)
        alert.informativeText = candidate.commandText
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: AppLocalization.string(.replay))
        alert.addButton(withTitle: AppLocalization.string(.cancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func makeTerminalContextMenu() -> NSMenu {
        let state = TerminalContextMenuState(
            hasSelection: normalizedSelectionRange() != nil,
            hasPasteboardText: !(NSPasteboard.general.string(forType: .string)?.isEmpty ?? true)
        )
        let workingDirectory = workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let layout = TerminalContextMenuBuilder.layout(
            for: state,
            quickCommands: QuickCommandStore.shared.commands(
                forWorkingDirectory: workingDirectory.isEmpty ? nil : workingDirectory
            ),
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            language: AppLocalization.language
        )
        let menu = NSMenu()
        for entry in layout.entries {
            guard let title = entry.title, let action = entry.action else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: selector(for: action), keyEquivalent: "")
            item.target = self
            item.isEnabled = entry.isEnabled
            if let iconSymbolName = entry.iconSymbolName {
                item.image = NSImage(systemSymbolName: iconSymbolName, accessibilityDescription: title)
                item.image?.isTemplate = true
            }
            menu.addItem(item)
        }
        // Quick commands are data-driven and identified by string id, so they
        // are a submenu rather than a case in the fixed action enum above.
        guard let quickCommandSubmenu = layout.quickCommandSubmenu else {
            return menu
        }
        menu.addItem(.separator())
        let submenuItem = NSMenuItem(title: quickCommandSubmenu.title, action: nil, keyEquivalent: "")
        submenuItem.submenu = QuickCommandContextMenuBuilder.makeMenu(
            for: quickCommandSubmenu,
            target: self,
            action: #selector(runQuickCommandFromContextMenu(_:))
        )
        menu.addItem(submenuItem)
        return menu
    }

    /// `representedObject` carries the quick command's id; the window
    /// controller resolves it and routes it through `QuickCommandInvoker`, the
    /// only path that may write a quick command to a pane.
    @objc private func runQuickCommandFromContextMenu(_ sender: NSMenuItem) {
        guard let quickCommandID = sender.representedObject as? String else {
            return
        }
        guard let controller = window?.windowController as? TerminalWindowController else {
            return
        }
        controller.invokeQuickCommand(withID: quickCommandID)
    }

    private func selector(for action: TerminalContextMenuAction) -> Selector {
        switch action {
        case .copySelection:
            return #selector(copySelectionFromContextMenu(_:))
        case .paste:
            return #selector(paste(_:))
        case .split(.right):
            return #selector(splitRightFromContextMenu(_:))
        case .split(.left):
            return #selector(splitLeftFromContextMenu(_:))
        case .split(.down):
            return #selector(splitDownFromContextMenu(_:))
        case .split(.up):
            return #selector(splitUpFromContextMenu(_:))
        }
    }

    private func splitFromContextMenu(_ direction: TerminalPaneSplitDirection) {
        guard let controller = window?.windowController as? TerminalWindowController else {
            return
        }
        controller.split(direction: direction)
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        if TerminalCommandDispatcher.dispatchWindowCommand(from: self, event: event) {
            return true
        }

        let flags = event.modifierFlags.terminalInputModifiers
        guard flags.contains(.command),
              flags.subtracting([.command, .shift]).isEmpty,
              let characters = TerminalTextInputRouter.latinKeyEquivalent(for: event)
        else {
            return false
        }

        switch characters {
        case "c" where flags == .command:
            copy(nil)
            return true
        case "v" where flags == .command:
            paste(nil)
            return true
        case "x" where flags == .command:
            cut(nil)
            return true
        case "a" where flags == .command:
            // latinKeyEquivalent falls back to the hardware keyCode (kVK_ANSI_A
            // = 0 maps to "a"), so Cmd+A matches even when a non-Latin input
            // source reports "ㅁ" in charactersIgnoringModifiers. Returning true
            // here also keeps Cmd+A out of the command-shortcut control-text
            // fallback that would otherwise write Ctrl-A to the shell.
            selectAll(nil)
            return true
        default:
            return false
        }
    }

    private func handleTerminalControlKey(_ event: NSEvent) -> Bool {
        if let controlText = TerminalKeyEncoder.sequence(for: event, state: terminalKeyEncoderState) {
            send(controlText)
            return true
        }
        if let commandControlText = TerminalTextInputRouter.commandShortcutControlText(for: event) {
            send(commandControlText)
            return true
        }

        return false
    }

    private func handleKeyEquivalentTerminalControl(_ event: NSEvent) -> Bool {
        if let commandControlText = TerminalTextInputRouter.commandShortcutControlText(for: event) {
            resetMarkedTextForInputSourceChange()
            send(commandControlText)
            return true
        }
        guard !hasMarkedText() else {
            return false
        }
        return handleTerminalControlKey(event)
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        apply(settings: settings)
    }

    /// The zoom resolves against the configured size, so re-applying the last
    /// settings is all it takes; `terminalFont(for:)` picks up the new size.
    @objc private func fontZoomDidChange(_ notification: Notification) {
        apply(settings: appliedSettings)
    }

    override func layout() {
        super.layout()
        markFullDamage()
        syncSizeWithView()
        layoutScrollIndicator()
        updateRendererFrame()
    }

    private func setScrollbackOffset(fromNormalizedOffset normalizedOffset: CGFloat) {
        let maxOffset = maxScrollbackOffset()
        guard maxOffset > 0 else { return }
        let nextOffset = min(maxOffset, max(0, Int(round(normalizedOffset * CGFloat(maxOffset)))))
        guard nextOffset != scrollbackOffset else { return }
        scrollbackOffset = nextOffset
        markFullDamage()
        updateScrollIndicator()
        updateRendererFrame()
    }

    private func observeWindowScreenChanges() {
        removeWindowScreenObserver()
        guard let window else { return }
        windowScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayConfigurationChanged()
            }
        }
    }

    private func removeWindowScreenObserver() {
        guard let windowScreenObserver else { return }
        NotificationCenter.default.removeObserver(windowScreenObserver)
        self.windowScreenObserver = nil
    }

    deinit {
        searchTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        // A pane that is torn down while its agent still waits would otherwise
        // leave a banner pointing at a tab that no longer exists. Unconditional
        // because a deinitializer may not read the policy's isolated state, and
        // withdrawing an identifier that was never posted is a no-op.
        let paneIdentifier = agentPaneIdentifier
        // The notifier is main-actor isolated; deinit may run off it, so hop.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                TerminalNotifier.shared.withdrawAgentWaitingNotification(paneIdentifier: paneIdentifier)
            }
        }
    }

    private func observeInputSourceChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputSourceDidChange(_:)),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
    }

    private func observeTerminalFocusChanges() {
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(terminalFocusContextDidChange(_:)),
                name: name,
                object: nil
            )
        }
    }

    @objc private func terminalFocusContextDidChange(_ notification: Notification) {
        if let changedWindow = notification.object as? NSWindow,
           changedWindow !== window {
            return
        }
        updateCursorBlinkStateForFocus()
        handleTerminalFocusStateChange()
    }

    /// Everything that has to happen when the user arrives at or leaves this
    /// pane: the program hears about it through DEC focus reporting, and a
    /// waiting banner the user has now answered comes down.
    private func handleTerminalFocusStateChange() {
        reportTerminalFocusIfNeeded()
        updateAgentWaitingNotification()
        presentDeferredClipboardConfirmationIfNeeded()
    }

    private func reportTerminalFocusIfNeeded() {
        guard let sequence = focusReportingState.sequenceIfNeeded(isFocused: isTerminalFocusedForUser) else {
            return
        }
        sendTerminalResponse(sequence)
    }

    @objc private func inputSourceDidChange(_ notification: Notification) {
        handleInputSourceChanged()
    }

    private func handleInputSourceChanged() {
        commitPendingCompositionForInputSourceChange()
    }

    /// An input-source switch (한/영) ends the current composition, but IMK does
    /// not reliably deliver the dying preedit's insertText before the next
    /// keystroke on the new source reaches the PTY. Left alone, the preedit
    /// either vanishes (flicker) or lands after later keystrokes ("dks안").
    /// Commit it to the PTY here, then swallow IMK's duplicate commit if one
    /// still arrives. discardMarkedText() must not run synchronously inside the
    /// global keyboardSelectionDidChange notification — it re-enters AppKit/IMK
    /// and can pin the main thread with split panes — so it is deferred.
    private func commitPendingCompositionForInputSourceChange() {
        guard hasMarkedText() || !committedMarkedTextPrefix.isEmpty else { return }
        let pendingComposition = committedMarkedTextPrefix + markedText.string
        let isActiveInputClient = window?.firstResponder === self
        resetMarkedTextForInputSourceChange()
        guard isActiveInputClient, !pendingComposition.isEmpty else { return }
        sendCommittedText(pendingComposition, source: "inputSourceChange")
        inputSourceChangeCommitToSuppress = pendingComposition
        DispatchQueue.main.async { [weak self] in
            self?.inputContext?.discardMarkedText()
            DispatchQueue.main.async { [weak self] in
                self?.inputSourceChangeCommitToSuppress = nil
            }
        }
    }

    private func resetMarkedTextForInputSourceChange() {
        guard hasMarkedText() || !committedMarkedTextPrefix.isEmpty else { return }
        markMarkedTextDirty()
        markedText = NSMutableAttributedString()
        inputSelectedRange = NSRange(location: NSNotFound, length: 0)
        markedTextAnchor = nil
        pendingMarkedTextAnchor = nil
        markedTextInputSourceID = nil
        clearCommittedMarkedTextPrefix()
        markDirty(row: cursorRow)
        updateRendererFrame()
    }

    private func handleDisplayConfigurationChanged() {
        // Moving between Retina and 1x displays can change effective cell metrics and
        // PTY dimensions. Force a full frame so Metal receives fresh cell geometry.
        currentBackingScale = effectiveBackingScale
        markFullDamage()
        syncSizeWithView()
        updateRendererFrame()
    }

    private func syncSizeWithView() {
        let metrics = terminalMetrics()
        guard metrics.size.columns > 0, metrics.size.rows > 0 else { return }
        if metrics.size != lastSentSize {
            cursorRow = screen.resize(rows: metrics.size.rows, columns: metrics.size.columns, anchorRow: cursorRow)
            cursorColumn = min(cursorColumn, metrics.size.columns - 1)
            resetScrollRegion()
            lastSentSize = metrics.size
            shell.resize(columns: metrics.size.columns, rows: metrics.size.rows)
            core.resize(cols: UInt32(metrics.size.columns), rows: UInt32(metrics.size.rows))
            markFullDamage()
            refreshSearchAfterContentChange()
        }
    }

    private func updateRendererFrame() {
        let metrics = terminalMetrics()
        let rowsToRender = visibleRowsForRendering(limit: metrics.size.rows)
        let nextViewportBackground = TerminalViewportBackgroundPolicy.background(
            in: rowsToRender,
            columns: metrics.size.columns,
            fallback: terminalDefaultStyle.background
        )
        let viewportBackgroundChanged = viewportBackground.map {
            !$0.sameColor(as: nextViewportBackground)
        } ?? true
        if viewportBackgroundChanged {
            viewportBackground = nextViewportBackground
            layer?.backgroundColor = nextViewportBackground.cgColor
            markFullDamage()
        }
        let damage = consumePendingDamage(metrics: metrics)
        var cells: [TerminalCell] = []
        var backgrounds: [TerminalBackground] = []
        var decorations: [TerminalDecoration] = []
        cells.reserveCapacity(metrics.size.rows * metrics.size.columns / AppConstants.Rendering.visibleCellReserveDivisor)
        let visibleStartRow = visibleRowStartIndex(limit: metrics.size.rows)
        let linkRanges = visibleLinkRanges(
            visibleStartRow: visibleStartRow,
            visibleRowCount: rowsToRender.count
        )
        let selectedCells = selectedCellSet()
        let currentSearchMatch = currentSearchMatch
        for row in 0..<rowsToRender.count {
            let sourceRow = rowsToRender[row]
            for column in 0..<min(sourceRow.count, metrics.size.columns) {
                let cell = sourceRow[column]
                let position = TerminalCellPosition(row: visibleStartRow + row, column: column)
                let isSelected = selectedCells.contains(position)
                let searchHighlight = searchResults.highlight(
                    at: position,
                    currentMatch: currentSearchMatch
                )
                let renderedForeground: SIMD4<Float>
                let renderedBackground: SIMD4<Float>
                if isSelected {
                    renderedForeground = TerminalSelectionStyle.foregroundColor
                    renderedBackground = TerminalSelectionStyle.backgroundColor
                } else if searchHighlight == .current {
                    renderedForeground = TerminalSearchStyle.foregroundColor
                    renderedBackground = TerminalSearchStyle.currentBackgroundColor
                } else if searchHighlight == .match {
                    renderedForeground = TerminalSearchStyle.foregroundColor
                    renderedBackground = TerminalSearchStyle.matchBackgroundColor
                } else {
                    renderedForeground = TerminalTextContrastPolicy.visibleForeground(
                        for: cell.style,
                        defaultStyle: terminalDefaultStyle
                    )
                    renderedBackground = cell.style.effectiveBackground
                }
                if isSelected || searchHighlight != nil || shouldRenderBackground(for: cell) {
                    backgrounds.append(TerminalBackground(
                        column: column,
                        row: row,
                        color: renderedBackground
                    ))
                }
                if cell.isContinuation {
                    continue
                }
                if cell.style.underline {
                    decorations.append(TerminalDecoration(
                        column: column,
                        row: row,
                        width: max(1, cell.character.terminalColumnWidth),
                        kind: .underline,
                        color: renderedForeground
                    ))
                }
                if cell.style.strikethrough {
                    decorations.append(TerminalDecoration(
                        column: column,
                        row: row,
                        width: max(1, cell.character.terminalColumnWidth),
                        kind: .strikethrough,
                        color: renderedForeground
                    ))
                }
                if linkRanges.contains(where: { $0.contains(row: row, column: column) }) {
                    decorations.append(TerminalDecoration(
                        column: column,
                        row: row,
                        width: max(1, cell.character.terminalColumnWidth),
                        kind: .underline,
                        color: renderedForeground
                    ))
                }
                if hoveredLinkRange?.contains(row: row, column: column) == true {
                    decorations.append(TerminalDecoration(
                        column: column,
                        row: row,
                        width: max(1, cell.character.terminalColumnWidth),
                        kind: .underline,
                        color: TerminalLinkRange.hoverColor
                    ))
                }
                if appendBoxDrawingDecoration(
                    for: cell.character,
                    column: column,
                    row: row,
                    color: renderedForeground,
                    to: &decorations
                ) {
                    continue
                }
                if appendBlockElementDecoration(
                    for: cell.character,
                    column: column,
                    row: row,
                    color: renderedForeground,
                    to: &decorations
                ) {
                    continue
                }
                if cell.character != " " {
                    // The screen model marks the trailing half of a wide glyph
                    // as a continuation, which is the Zig grid's answer carried
                    // up. Passing it on means no renderer has to work the width
                    // out from the codepoint.
                    let isWide = column + 1 < sourceRow.count
                        && sourceRow[column + 1].isContinuation

                    cells.append(TerminalCell(
                        character: cell.character,
                        column: column,
                        row: row,
                        foreground: renderedForeground,
                        background: renderedBackground,
                        columns: isWide ? TerminalCellColumns.wide : TerminalCellColumns.single
                    ))
                }
            }
        }
        let compositionText = textInputOverlayText()
        let markedTextPosition = renderedMarkedTextPosition(visibleStartRow: visibleStartRow, compositionText: compositionText)
        let displayCursorRow = markedTextPosition?.row ?? cursorRow
        let displayCursorColumn = markedTextPosition?.column ?? cursorColumn
        discardImagesScrolledOutOfTheBuffer()

        renderer.update(frame: TerminalFrame(
            cells: cells,
            backgrounds: backgrounds,
            decorations: decorations,
            images: imagePlacements.visible(
                from: absoluteContentRow(forRelative: visibleRowStartIndex(limit: metrics.size.rows)),
                rows: metrics.size.rows
            ),
            defaultForeground: terminalDefaultStyle.foreground,
            defaultBackground: nextViewportBackground,
            dirtyRows: damage.rows,
            dirtyRects: damage.rects,
            isFullDamage: damage.isFull,
            cursorColumn: min(displayCursorColumn + compositionText.terminalColumnWidth, metrics.size.columns - 1),
            cursorRow: cursorVisible && scrollbackOffset == 0 ? min(displayCursorRow, metrics.size.rows - 1) : -1,
            // Inactive apps, windows, and panes keep a steady cursor; only the
            // terminal that is focused for user input follows the blink phase.
            cursorBlinkOn: TerminalCursorPresentationPolicy.shouldRenderBlinkPhase(
                isFocusedForUser: isTerminalFocusedForUser,
                cursorStyleBlinks: cursorStyle.blinks,
                cursorBlinkOn: cursorBlinkOn,
                hasMarkedText: hasMarkedText()
            ),
            cursorStyle: cursorStyle,
            markedTextColumn: displayCursorColumn,
            markedText: compositionText,
            markedTextSelectedRange: markedTextSelectionRange(committedPrefix: committedMarkedTextPrefix),
            columns: metrics.size.columns,
            visibleRows: metrics.size.rows,
            cellSize: metrics.cellSize,
            padding: TerminalFramePoint(x: Double(padding.left), y: Double(padding.top))
        ))
        activeOutputRuntimeEventBatch?.recordRenderFrame(.init(
            frameIndex: Int(debugFrameIndex),
            dirtyRegionCount: damage.rects.count,
            fullRedraw: damage.isFull
        ))
        logScreenDumpIfNeeded(rows: rowsToRender, damage: damage, metrics: metrics)
        debugFrameIndex &+= 1
    }

    private func renderedMarkedTextPosition(visibleStartRow: Int, compositionText: String) -> TerminalCellPosition? {
        guard !compositionText.isEmpty else { return nil }
        let anchor = committedMarkedTextPrefixAnchor ?? markedTextAnchor ?? TerminalCellPosition(row: cursorRow, column: cursorColumn)
        let contentRow = scrollbackRows.count + anchor.row
        return TerminalCellPosition(row: contentRow - visibleStartRow, column: anchor.column)
    }

    private func shouldRenderBackground(for cell: TerminalScreenCell) -> Bool {
        guard !cell.style.effectiveBackground.sameColor(as: terminalDefaultStyle.background) else {
            return false
        }
        if cell.character == " ", cell.style == .default {
            return false
        }
        return true
    }

    private func appendBoxDrawingDecoration(
        for character: Character,
        column: Int,
        row: Int,
        color: SIMD4<Float>,
        to decorations: inout [TerminalDecoration]
    ) -> Bool {
        let left: Bool
        let right: Bool
        let up: Bool
        let down: Bool
        switch character {
        case "─":
            left = true; right = true; up = false; down = false
        case "│":
            left = false; right = false; up = true; down = true
        case "┌", "╭":
            left = false; right = true; up = false; down = true
        case "┐", "╮":
            left = true; right = false; up = false; down = true
        case "└", "╰":
            left = false; right = true; up = true; down = false
        case "┘", "╯":
            left = true; right = false; up = true; down = false
        case "├":
            left = false; right = true; up = true; down = true
        case "┤":
            left = true; right = false; up = true; down = true
        case "┬":
            left = true; right = true; up = false; down = true
        case "┴":
            left = true; right = true; up = true; down = false
        case "┼":
            left = true; right = true; up = true; down = true
        default:
            return false
        }
        decorations.append(TerminalDecoration(
            column: column,
            row: row,
            width: 1,
            kind: .boxDrawing(left: left, right: right, up: up, down: down),
            color: color
        ))
        return true
    }

    private func appendBlockElementDecoration(
        for character: Character,
        column: Int,
        row: Int,
        color: SIMD4<Float>,
        to decorations: inout [TerminalDecoration]
    ) -> Bool {
        guard let rects = TerminalBlockElementGeometry.rects(for: character) else {
            return false
        }
        for rect in rects {
            decorations.append(TerminalDecoration(
                column: column,
                row: row,
                width: 1,
                kind: .blockElement(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                color: color
            ))
        }
        return true
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = TerminalTextInputRouter.committedText(from: string)
        TerminalTextInputRouter.logInsertText(text, replacementRange: replacementRange)
        if let suppressed = inputSourceChangeCommitToSuppress {
            inputSourceChangeCommitToSuppress = nil
            if text == suppressed, !hasMarkedText() {
                // Already committed by commitPendingCompositionForInputSourceChange();
                // this is IMK's late duplicate for the dead composition.
                return
            }
        }
        appendCommittedMarkedTextPrefix(text)
        recordPendingMarkedTextAnchor(afterCommitting: text)
        clearMarkedText(renderFrame: false)
        guard !text.isEmpty else { return }
        if var committedText = keyTextAccumulator {
            committedText.append(text)
            keyTextAccumulator = committedText
        } else {
            sendCommittedText(text, source: "insertText")
        }
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) {
            resetMarkedTextForInputSourceChange()
        }
        if let sequence = TerminalKeyEncoder.sequence(for: selector, state: terminalKeyEncoderState) {
            flushAccumulatedCommittedText()
            clearCommittedMarkedTextPrefix()
            pendingMarkedTextAnchor = nil
            send(sequence)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        followLiveOutputForUserInput()
        markMarkedTextDirty()
        let attr = string as? NSAttributedString ?? NSAttributedString(string: string as? String ?? "")
        TerminalTextInputRouter.logMarkedText(attr.string, selectedRange: selectedRange, replacementRange: replacementRange)
        guard !attr.string.isEmpty else {
            clearMarkedText(renderFrame: true)
            return
        }
        if markedText.length == 0 {
            markedTextAnchor = pendingMarkedTextAnchor ?? TerminalCellPosition(row: cursorRow, column: cursorColumn)
            pendingMarkedTextAnchor = nil
        }
        markedTextInputSourceID = inputContext?.selectedKeyboardInputSource
        inputSourceChangeCommitToSuppress = nil
        markedText = NSMutableAttributedString(attributedString: attr)
        inputSelectedRange = selectedRange
        markMarkedTextDirty()
        requestTextInputRendererFrame()
    }

    func unmarkText() {
        TerminalTextInputRouter.logUnmarkText()
        clearMarkedText(renderFrame: true)
    }

    private func clearMarkedText(renderFrame: Bool) {
        markMarkedTextDirty()
        markedText = NSMutableAttributedString()
        inputSelectedRange = NSRange(location: NSNotFound, length: 0)
        markedTextAnchor = nil
        markDirty(row: cursorRow)
        if renderFrame {
            requestTextInputRendererFrame()
        }
    }

    private func appendCommittedMarkedTextPrefix(_ text: String) {
        guard !text.isEmpty, hasMarkedText() else { return }
        if committedMarkedTextPrefixAnchor == nil {
            committedMarkedTextPrefixAnchor = markedTextAnchor ?? TerminalCellPosition(row: cursorRow, column: cursorColumn)
        }
        committedMarkedTextPrefix.append(text)
        if let anchor = committedMarkedTextPrefixAnchor {
            markDirty(row: anchor.row)
        }
    }

    private func clearCommittedMarkedTextPrefix() {
        guard !committedMarkedTextPrefix.isEmpty || committedMarkedTextPrefixAnchor != nil else { return }
        if let anchor = committedMarkedTextPrefixAnchor {
            markDirty(row: anchor.row)
        }
        committedMarkedTextPrefix.removeAll(keepingCapacity: true)
        committedMarkedTextPrefixAnchor = nil
    }

    private func textInputOverlayText() -> String {
        guard !committedMarkedTextPrefix.isEmpty else {
            return markedText.string
        }
        return committedMarkedTextPrefix + markedText.string
    }

    private func recordPendingMarkedTextAnchor(afterCommitting text: String) {
        guard !text.isEmpty else {
            pendingMarkedTextAnchor = nil
            return
        }
        let anchor = markedTextAnchor ?? TerminalCellPosition(row: cursorRow, column: cursorColumn)
        pendingMarkedTextAnchor = advancedTerminalPosition(from: anchor, by: text)
    }

    private func advancedTerminalPosition(from position: TerminalCellPosition, by text: String) -> TerminalCellPosition {
        var row = position.row
        var column = position.column
        let columns = max(1, terminalMetrics().size.columns)
        for character in text {
            let width = character.terminalColumnWidth
            guard width > 0 else { continue }
            if width == 2 && column == columns - 1 {
                row += 1
                column = 0
            } else if column >= columns {
                row += 1
                column = 0
            }
            column += width
        }
        return TerminalCellPosition(row: row, column: min(column, columns - 1))
    }

    private func markMarkedTextDirty() {
        guard let anchor = markedTextAnchor else {
            markDirty(row: cursorRow)
            return
        }
        // IME composition is an overlay on top of terminal cells. When it changes
        // or commits, redraw the original row so transient composition pixels do
        // not become persistent cell backgrounds.
        markDirty(row: anchor.row)
        if anchor.row != cursorRow {
            markDirty(row: cursorRow)
        }
    }

    private func performTextInputTransaction<Result>(_ body: () -> Result) -> Result {
        textInputEventDepth += 1
        if textInputEventDepth == 1 {
            keyTextAccumulator = []
        }
        let result = body()
        textInputEventDepth -= 1
        if textInputEventDepth == 0 {
            let didSendCommittedText = flushAccumulatedCommittedText()
            keyTextAccumulator = nil
            if needsDeferredTextInputFrame {
                needsDeferredTextInputFrame = false
                if !didSendCommittedText || hasMarkedText() {
                    requestTextInputRendererFrame()
                }
            }
        }
        return result
    }

    @discardableResult
    private func flushAccumulatedCommittedText() -> Bool {
        guard let committedText = keyTextAccumulator else { return false }
        keyTextAccumulator = []
        var didSendCommittedText = false
        for text in committedText where !text.isEmpty {
            sendCommittedText(text, source: "keyTextAccumulator")
            didSendCommittedText = true
        }
        return didSendCommittedText
    }

    private func requestTextInputRendererFrame() {
        if textInputEventDepth > 0 {
            needsDeferredTextInputFrame = true
            return
        }
        guard !isTextInputRendererFrameScheduled else {
            return
        }
        isTextInputRendererFrameScheduled = true
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isTextInputRendererFrameScheduled = false
                self.updateRendererFrame()
            }
        }
    }

    private func sendCommittedText(_ text: String, source: String) {
        TerminalTextInputRouter.logPTYWrite(text, source: source)
        send(text)
    }

    private func markedTextSelectionRange(committedPrefix: String) -> TerminalTextSelectionRange {
        guard inputSelectedRange.location != NSNotFound else {
            return .none
        }
        return TerminalTextSelectionRange(
            location: committedPrefix.utf16.count + inputSelectedRange.location,
            length: inputSelectedRange.length
        )
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange {
        inputSelectedRange.location == NSNotFound ? NSRange(location: 0, length: 0) : inputSelectedRange
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int {
        let metrics = terminalMetrics()
        guard metrics.cellSize.width > 0, metrics.cellSize.height > 0 else { return 0 }
        let cellWidth = CGFloat(metrics.cellSize.width)
        let cellHeight = CGFloat(metrics.cellSize.height)
        let column = Int((point.x - padding.left) / cellWidth)
        let row = Int((bounds.height - padding.top - point.y) / cellHeight)
        let clampedColumn = min(max(0, column), max(0, metrics.size.columns - 1))
        let clampedRow = min(max(0, row), max(0, metrics.size.rows - 1))
        return clampedRow * metrics.size.columns + clampedColumn
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = selectedRange()
        let localRect = currentCursorCellRectInViewCoordinates()
        let windowRect = convert(localRect, to: nil)
        let screenRect = window?.convertToScreen(windowRect) ?? .zero
        logIMEFirstRect(range: range, actualRange: actualRange?.pointee, localRect: localRect, windowRect: windowRect, screenRect: screenRect)
        return screenRect
    }

    private func send(_ text: String, recordsUserActivity: Bool = true) {
        // Only user-initiated input dismisses the selection. Synthesized
        // protocol traffic (focus reports, DSR/DA responses) must not clear it.
        // The same flag tells the progress bar that a keystroke reached the
        // running command, which a batch job the user is waiting on never sees.
        if recordsUserActivity {
            clearSelection()
            followLiveOutputForUserInput()
            recordKeyboardSelectionInputStartIfNeeded(for: text)
            recordUserInput(text)
            onCommandProgress?(.userDidInteract)
        }
        shell.write(text)
    }

    /// Paste chunks go straight to the session. Selection clearing, viewport
    /// follow, and marked-text teardown already ran once in `executePaste`;
    /// repeating them per chunk would fight the user mid-paste.
    func writePasteChunk(_ text: String) {
        recordSubmittedInputText(text)
        shell.write(text)
    }

    var queuedPasteByteCount: Int? {
        (shell as? any TerminalSessionInputBackpressureReporting)?.queuedInputByteCount
    }

    private func followLiveOutputForUserInput() {
        guard scrollbackOffset != 0 else { return }
        scrollbackOffset = 0
        markFullDamage()
        updateScrollIndicator()
        updateRendererFrame()
    }

    private func sendTerminalResponse(_ text: String) {
        // Replayed scrollback must never produce a reply on the live shell's
        // stdin; see `TerminalOutputInterpreter.isReplayingScrollback`.
        guard !isReplayingScrollback else {
            return
        }
        guard shell.canReceiveTerminalResponseWithoutEcho() else {
            return
        }
        send(text, recordsUserActivity: false)
    }

    private func sendTerminalMouseSequence(_ text: String) {
        clearSelection()
        followLiveOutputForUserInput()
        shell.write(text)
    }

    private func recordUserInput(_ text: String) {
        guard recordSubmittedInputText(text) else {
            return
        }
        pendingMarkedTextAnchor = nil
        keyboardSelectionInputStart = nil
    }

    @discardableResult
    private func recordSubmittedInputText(_ text: String) -> Bool {
        let submitted = submittedCommandRecorder.consume(text)
        guard let body = submitted.last else {
            return false
        }
        lastSubmittedCommandText = body
        return true
    }

    private func recordKeyboardSelectionInputStartIfNeeded(for text: String) {
        guard keyboardSelectionInputStart == nil else { return }
        guard text.contains(where: { $0.isTerminalPrintableGrapheme }) else { return }
        keyboardSelectionInputStart = TerminalCellPosition(
            row: visibleRowStartIndex(limit: terminalMetrics().size.rows) + cursorRow,
            column: cursorColumn
        )
    }

    private var isTerminalFocusedForUser: Bool {
        TerminalCursorPresentationPolicy.isFocusedForUser(
            isApplicationActive: NSApp.isActive,
            isKeyWindow: window?.isKeyWindow == true,
            isFirstResponder: window?.firstResponder === self
        )
    }

    private var shouldDeliverUserNotification: Bool {
        !isTerminalFocusedForUser
    }

    private func enqueueOutput(_ text: String) {
        pendingOutputText.append(text)
        guard !isOutputFlushScheduled else { return }
        isOutputFlushScheduled = true
        // TUIs often clear and repaint the same status/input row across adjacent
        // PTY chunks. Coalescing one display tick avoids presenting the cleared
        // intermediate model as visible flicker or a cursor jump.
        // The closure already runs on the main queue after the coalescing tick;
        // a nested Task { @MainActor } would only add one more scheduling hop.
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.Component.ptyOutputCoalescingDelaySeconds) { [weak self] in
            guard let self else { return }
            self.flushPendingOutput()
        }
    }

    private func flushPendingOutput() {
        isOutputFlushScheduled = false
        let text = pendingOutputText
        pendingOutputText = ""
        guard !text.isEmpty else { return }
        appendOutput(text)
        if !pendingOutputText.isEmpty {
            enqueueOutput("")
        }
    }

    private func appendOutput(_ text: String) {
        beginOutputRuntimeEventBatch(byteCount: text.utf8.count)
        defer {
            commitOutputRuntimeEventBatch()
        }
        clearCommittedMarkedTextPrefix()
        let previousFirstRetainedRow = scrollbackRows.retainedRowSummary.firstRetainedRowIndex
        let previousCursorRow = cursorRow
        let previousScrollbackOffset = scrollbackOffset
        scrollbackRowsAppendedDuringOutput = 0
        let shouldFollowOutput = scrollbackOffset == 0
        if shouldFollowOutput {
            scrollbackOffset = 0
        }
        if previousScrollbackOffset != scrollbackOffset {
            markFullDamage()
        } else {
            markDirty(row: previousCursorRow)
        }
        let wasUsingAlternateScreen = isUsingAlternateScreen
        interpreter.interpret(text)
        if !wasUsingAlternateScreen, isUsingAlternateScreen {
            onCommandProgress?(.alternateScreenEntered)
        }
        pendingMarkedTextAnchor = nil
        markDirty(row: cursorRow)
        let appendedScrollbackCount = scrollbackRowsAppendedDuringOutput
        if !shouldFollowOutput, appendedScrollbackCount > 0 {
            scrollbackOffset = min(maxScrollbackOffset(), scrollbackOffset + appendedScrollbackCount)
            markFullDamage()
        }
        scrollbackRowsAppendedDuringOutput = 0
        updateScrollIndicator()
        let didDropScrollbackRows = scrollbackRows.retainedRowSummary.firstRetainedRowIndex
            != previousFirstRetainedRow
        refreshSearchAfterContentChange(preservingCurrentMatch: !didDropScrollbackRows)
        updateRendererFrame()
    }

    private func beginOutputRuntimeEventBatch(byteCount: Int) {
        let ptyByteCount = consumeRuntimeOutputBatchByteCount(fallbackByteCount: byteCount)
        let traceID = nextOutputFlushTraceID()
        activeOutputRuntimeEventBatch = TerminalRuntimeEventBatch(traceID: traceID)
        activeOutputRuntimeEventBatch?.recordPtyRead(byteCount: ptyByteCount)
        activeOutputRuntimeEventBatch?.recordParserEvent(.printable(byteCount: byteCount))
    }

    private func commitOutputRuntimeEventBatch() {
        guard let batch = activeOutputRuntimeEventBatch else { return }
        batch.commit(to: &runtimeEventLedger)
        activeOutputRuntimeEventBatch = nil
    }

    private func consumeRuntimeOutputBatchByteCount(fallbackByteCount: Int) -> Int {
        let byteCount = pendingRuntimeOutputEvents.reduce(0) { count, event in
            guard case let .ptyRead(byteCount) = event.payload else {
                return count
            }
            return count + byteCount
        }
        pendingRuntimeOutputEvents.removeAll(keepingCapacity: true)
        return byteCount > 0 ? byteCount : fallbackByteCount
    }

    private func nextOutputFlushTraceID() -> TerminalEventTraceID {
        let traceID = TerminalEventTraceID("output-flush-\(outputFlushTraceSequence)")
        outputFlushTraceSequence &+= 1
        return traceID
    }

    private func selectedText() -> String? {
        guard let range = normalizedSelectionRange() else { return nil }
        guard contentRowCount > 0 else { return nil }

        var selectedLines: [String] = []
        for rowIndex in range.start.row...range.end.row {
            guard let row = contentRow(at: rowIndex) else { continue }
            let startColumn = rowIndex == range.start.row ? range.start.column : 0
            let endColumn = rowIndex == range.end.row ? range.end.column : min(row.count - 1, screen.columns - 1)
            guard startColumn <= endColumn, startColumn < row.count else {
                selectedLines.append("")
                continue
            }
            let cells = row[startColumn...min(endColumn, row.count - 1)]
            selectedLines.append(TerminalSelectionText.line(from: cells.map {
                TerminalWordSelection.Cell(character: $0.character, isContinuation: $0.isContinuation)
            }))
        }
        return selectedLines.joined(separator: "\n")
    }

    private func selectedCellSet() -> Set<TerminalCellPosition> {
        guard let range = normalizedSelectionRange() else { return [] }
        let visibleRowLimit = terminalMetrics().size.rows
        let rows = visibleRowsForRendering(limit: visibleRowLimit)
        let visibleStartRow = visibleRowStartIndex(limit: visibleRowLimit)
        // The renderer only consumes visible cells, so clamp the walk to the
        // visible band. A whole-buffer selection (Select All) must not build a
        // position set across the entire scrollback on every frame.
        let firstRow = max(range.start.row, visibleStartRow)
        let lastRow = min(range.end.row, visibleStartRow + rows.count - 1)
        guard firstRow <= lastRow else { return [] }
        var cells = Set<TerminalCellPosition>()
        for row in firstRow...lastRow {
            let visibleIndex = row - visibleStartRow
            let sourceRow = rows.indices.contains(visibleIndex) ? rows[visibleIndex] : []
            let startColumn = row == range.start.row ? range.start.column : 0
            let baseEndColumn = row == range.end.row ? range.end.column : screen.columns - 1
            let selectionCells = sourceRow.map {
                TerminalWordSelection.Cell(character: $0.character, isContinuation: $0.isContinuation)
            }
            let endColumn = TerminalWordSelection.Bounds(startColumn: startColumn, endColumn: baseEndColumn)
                .highlightEndColumn(in: selectionCells)
            guard startColumn <= endColumn else { continue }
            for column in startColumn...endColumn {
                cells.insert(TerminalCellPosition(row: row, column: column))
            }
        }
        return cells
    }

    private func normalizedSelectionRange() -> TerminalSelectionRange? {
        guard let anchor = selectionAnchor, let focus = selectionFocus else { return nil }
        let normalized = TerminalSelectionRangeModel.normalized(
            anchor: TerminalSelectionPosition(row: anchor.row, column: anchor.column),
            focus: TerminalSelectionPosition(row: focus.row, column: focus.column)
        )
        guard let normalized else { return nil }
        return TerminalSelectionRange(
            start: TerminalCellPosition(row: normalized.start.row, column: normalized.start.column),
            end: TerminalCellPosition(row: normalized.end.row, column: normalized.end.column)
        )
    }

    private func updateCursorBlinkStateForFocus() {
        if isTerminalFocusedForUser {
            startCursorBlinking()
        } else {
            stopCursorBlinking(showCursor: true)
        }
    }

    private func startCursorBlinking() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkOn = true
        let timer = Timer(timeInterval: AppConstants.Terminal.cursorBlinkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.toggleCursorBlink()
            }
        }
        cursorBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        markFullDamage()
        updateRendererFrame()
    }

    private func stopCursorBlinking(showCursor: Bool) {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        cursorBlinkOn = showCursor
        markFullDamage()
        updateRendererFrame()
    }

    private func toggleCursorBlink() {
        guard isTerminalFocusedForUser else {
            stopCursorBlinking(showCursor: true)
            return
        }
        guard !hasMarkedText() else {
            cursorBlinkOn = true
            markFullDamage()
            updateRendererFrame()
            return
        }
        // A steady DECSCUSR style is drawn on every frame regardless of the
        // phase, so advancing it would cost a full-surface redraw per tick for
        // no visible change.
        guard cursorStyle.blinks else { return }
        cursorBlinkOn.toggle()
        markFullDamage()
        updateRendererFrame()
    }

    private func selectWord(at position: TerminalCellPosition) {
        // `position` is content-absolute — `cellPosition(for:)` adds
        // `visibleRowStartIndex` — so the row has to be fetched from the content
        // buffer, the same accessor `selectedText()` reads. Indexing the
        // viewport slice with it agreed only while the buffer was shorter than
        // the screen; the moment anything scrolled off, a double click either
        // read the wrong row or ran past the end of the slice and cleared the
        // selection outright.
        guard let row = contentRow(at: position.row) else {
            clearSelection()
            return
        }
        let cells = row.map { TerminalWordSelection.Cell(character: $0.character, isContinuation: $0.isContinuation) }
        guard let bounds = TerminalWordSelection.bounds(in: cells, clickedColumn: position.column) else {
            clearSelection()
            return
        }

        selectionAnchor = TerminalCellPosition(row: position.row, column: bounds.startColumn)
        selectionFocus = TerminalCellPosition(row: position.row, column: bounds.endColumn)
        selectionGestureState.selectWord()
        markFullDamage()
        updateRendererFrame()
    }

    private func updateSelectionFocus(with event: NSEvent, autoscroll: Bool) {
        guard let anchor = selectionAnchor else { return }
        if autoscroll {
            guard selectionGestureState.shouldUpdateFocusOnPointerDrag() else { return }
            autoscrollSelectionIfNeeded(with: event)
        } else if !selectionGestureState.shouldUpdateFocusOnPointerUp() {
            return
        }
        let focus = cellPosition(for: event)
        selectionFocus = focus == anchor ? nil : focus
        markFullDamage()
        updateRendererFrame()
    }

    private func autoscrollSelectionIfNeeded(with event: NSEvent) {
        guard !scrollbackRows.isEmpty else { return }
        let metrics = terminalMetrics()
        let location = convert(event.locationInWindow, from: nil)
        let threshold = max(CGFloat(metrics.cellSize.height), 18)
        let topEdge = bounds.height - padding.top
        let bottomEdge = padding.bottom

        let rowDelta: Int
        if location.y > topEdge - threshold {
            rowDelta = 1
        } else if location.y < bottomEdge + threshold {
            rowDelta = -1
        } else {
            return
        }

        let previousOffset = scrollbackOffset
        scrollbackOffset = max(0, min(scrollbackRows.count, scrollbackOffset + rowDelta))
        guard scrollbackOffset != previousOffset else { return }

        // Keep the anchor attached to the same visible text while scrollback moves
        // under an active drag; otherwise selection appears to slide away.
        if let anchor = selectionAnchor {
            let clampedRow = max(0, min(metrics.size.rows - 1, anchor.row + scrollbackOffset - previousOffset))
            selectionAnchor = TerminalCellPosition(row: clampedRow, column: anchor.column)
        }
        updateScrollIndicator()
    }

    private func cellPosition(for event: NSEvent) -> TerminalCellPosition {
        let visiblePosition = visibleCellPosition(for: event)
        let maxContentRow = max(0, contentRowCount - 1)
        let row = min(maxContentRow, visibleRowStartIndex(limit: terminalMetrics().size.rows) + visiblePosition.row)
        return TerminalCellPosition(row: row, column: visiblePosition.column)
    }

    private func visibleCellPosition(for event: NSEvent) -> TerminalCellPosition {
        let metrics = terminalMetrics()
        let location = convert(event.locationInWindow, from: nil)
        let cellWidth = CGFloat(metrics.cellSize.width)
        let cellHeight = CGFloat(metrics.cellSize.height)
        let rawColumn = Int(floor((location.x - padding.left) / cellWidth))
        let rawRow = Int(floor((bounds.height - location.y - padding.top) / cellHeight))
        let column = max(0, min(metrics.size.columns - 1, rawColumn))
        let visibleRow = max(0, min(metrics.size.rows - 1, rawRow))
        return TerminalCellPosition(row: visibleRow, column: column)
    }

    private func extendKeyboardSelection(rowDelta: Int, columnDelta: Int) {
        if scrollbackOffset != 0 {
            scrollbackOffset = 0
            updateScrollIndicator()
        }

        let metrics = terminalMetrics()
        let liveCursorPosition = TerminalCellPosition(
            row: visibleRowStartIndex(limit: metrics.size.rows) + cursorRow,
            column: cursorColumn
        )
        let inputStart = keyboardSelectionInputStart ?? liveCursorPosition
        let anchor = selectionAnchor ?? liveCursorPosition
        let focus = selectionFocus ?? liveCursorPosition
        let nextFocus = clampedSelectionPosition(
            row: focus.row + rowDelta,
            column: focus.column + columnDelta,
            metrics: metrics,
            inputStart: inputStart
        )

        selectionGestureState.beginCharacterSelection()
        selectionAnchor = anchor
        selectionFocus = nextFocus == anchor ? nil : nextFocus
        markFullDamage()
        updateRendererFrame()
    }

    private func clampedSelectionPosition(
        row: Int,
        column: Int,
        metrics: TerminalMetrics,
        inputStart: TerminalCellPosition
    ) -> TerminalCellPosition {
        let maxRow = max(0, contentRowCount - 1)
        let nextRow = max(inputStart.row, min(maxRow, row))
        let minimumColumn = nextRow == inputStart.row ? inputStart.column : 0
        let nextColumn = max(minimumColumn, min(metrics.size.columns - 1, column))
        return TerminalCellPosition(row: nextRow, column: nextColumn)
    }

    /// The hover underline is the affordance for the ⌘-click, so it only shows
    /// while ⌘ is down. `flagsChanged` drives this too, which is what makes the
    /// underline appear and disappear under a stationary pointer.
    private func updateHoveredLinkRange(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            setHoveredLinkRange(nil)
            return
        }
        setHoveredLinkRange(linkRange(at: cellPosition(for: event)))
    }

    private func reportTerminalMouseWheel(with event: NSEvent, rowDelta: Int) -> Bool {
        guard mouseReportingState.isEnabled,
              !event.modifierFlags.contains(.shift),
              event.scrollingDeltaY != 0 else {
            return false
        }
        guard rowDelta != 0 else { return true }

        let kind: TerminalMouseEventKind = rowDelta > 0 ? .wheelUp : .wheelDown
        let position = visibleCellPosition(for: event)
        guard let sequence = TerminalMouseEventEncoder.sequence(
            for: kind,
            column: position.column,
            row: position.row,
            modifiers: terminalMouseModifiers(for: event),
            reportingState: mouseReportingState
        ) else {
            return true
        }
        sendTerminalMouseSequence(String(repeating: sequence, count: abs(rowDelta)))
        return true
    }

    /// DEC private mode 1007. The alternate screen has no scrollback of its own,
    /// so a claimed wheel is swallowed even when it quantizes to zero rows:
    /// falling through would scroll the normal screen's history behind the pager.
    private func sendAlternateScrollKeysIfNeeded(with event: NSEvent, rowDelta: Int) -> Bool {
        let context = TerminalAlternateScroll.Context(
            isAlternateScreenActive: isUsingAlternateScreen,
            isAlternateScrollEnabled: mouseReportingState.alternateScrollEnabled,
            isMouseReportingEnabled: mouseReportingState.isEnabled,
            applicationCursorKeysEnabled: applicationCursorKeysEnabled,
            isShiftHeld: event.modifierFlags.contains(.shift)
        )
        guard TerminalAlternateScroll.claimsWheel(in: context) else { return false }
        if let sequence = TerminalAlternateScroll.keySequence(rowDelta: rowDelta, context: context) {
            send(sequence)
        }
        return true
    }

    private func reportTerminalMouseEvent(_ kind: TerminalMouseEventKind, with event: NSEvent) -> Bool {
        guard mouseReportingState.isEnabled, !event.modifierFlags.contains(.shift) else {
            return false
        }
        let position = visibleCellPosition(for: event)
        guard let sequence = TerminalMouseEventEncoder.sequence(
            for: kind,
            column: position.column,
            row: position.row,
            modifiers: terminalMouseModifiers(for: event),
            reportingState: mouseReportingState
        ) else {
            return false
        }
        sendTerminalMouseSequence(sequence)
        return true
    }

    private func terminalMouseModifiers(for event: NSEvent) -> TerminalMouseModifiers {
        var modifiers: TerminalMouseModifiers = []
        if event.modifierFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if event.modifierFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if event.modifierFlags.contains(.control) {
            modifiers.insert(.control)
        }
        return modifiers
    }

    private func setHoveredLinkRange(_ nextRange: TerminalLinkRange?) {
        guard hoveredLinkRange != nextRange else { return }
        if let oldRange = hoveredLinkRange {
            markDirty(row: oldRange.row)
        }
        hoveredLinkRange = nextRange
        if let nextRange {
            markDirty(row: nextRange.row)
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
        updateRendererFrame()
    }

    private func linkRange(at position: TerminalCellPosition) -> TerminalLinkRange? {
        let visibleStart = visibleRowStartIndex(limit: terminalMetrics().size.rows)
        let visibleRow = position.row - visibleStart
        let rowsToRender = visibleRowsForRendering(limit: terminalMetrics().size.rows)
        guard rowsToRender.indices.contains(visibleRow) else { return nil }
        return visibleLinkRanges(
            visibleStartRow: visibleStart,
            visibleRowCount: rowsToRender.count
        ).first { $0.contains(row: visibleRow, column: position.column) }
    }

    private func visibleLinkRanges(visibleStartRow: Int, visibleRowCount: Int) -> [TerminalLinkRange] {
        guard visibleRowCount > 0, contentRowCount > 0 else { return [] }

        var contextStartRow = min(max(0, visibleStartRow), contentRowCount - 1)
        while contextStartRow > 0,
              contentRow(at: contextStartRow - 1)?.last?.wrapsToNextRow == true {
            contextStartRow -= 1
        }

        var contextEndRow = min(contentRowCount, visibleStartRow + visibleRowCount)
        while contextEndRow < contentRowCount,
              contentRow(at: contextEndRow - 1)?.last?.wrapsToNextRow == true {
            contextEndRow += 1
        }

        let rows = (contextStartRow..<contextEndRow).compactMap(contentRow(at:))
        return TerminalLinkRange.findAll(
            in: rows,
            startingRow: contextStartRow - visibleStartRow,
            fileLinkContext: fileLinkContext()
        )
    }

    /// Main-actor-safe view of the path-exists cache. Misses schedule a probe
    /// and repaint once the answer lands, so no `stat` ever runs inline.
    private func fileLinkContext() -> TerminalFileLinkContext {
        TerminalFileLinkContext(
            workingDirectory: workingDirectoryPath,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            cachedExists: { [weak self] path in self?.filePathExistsCache.exists(path) },
            requestExistsProbe: { [weak self] path in
                guard let self else { return }
                self.filePathExistsProbe.probe(path: path) { [weak self] probedPath, exists in
                    guard let self else { return }
                    self.filePathExistsCache.record(path: probedPath, exists: exists)
                    guard exists else { return }
                    self.markFullDamage()
                    self.updateRendererFrame()
                }
            }
        )
    }

    /// Opens a `path:line:col` link in a center editor tab, scrolling to the
    /// reported line when the link carried one.
    private func openFileLinkInEditorTab(_ target: TerminalFileLinkTarget) {
        guard let controller = window?.windowController as? TerminalWindowController else { return }
        controller.openEditorTab(for: target.fileURL, line: target.line)
    }

    /// The ⌘-click is already the user's intent, so a link whose printed text
    /// *is* its target opens straight away under a trusted scheme. A link whose
    /// target the program chose independently of the text — an OSC 8 label — or
    /// one carrying a scheme, userinfo, or control characters the user cannot
    /// read off the screen goes through the sheet, which shows the real target.
    private func activateLink(_ link: TerminalLinkRange) {
        let decision = TerminalLinkActivation.decision(for: link, policy: securityPolicy)
        guard let url = decision.openURL else { return }
        switch decision.outcome {
        case .allow:
            NSWorkspace.shared.open(url)
        case .ask:
            presentOpenLinkDialog(for: decision)
        case .deny:
            break
        }
    }

    private func presentOpenLinkDialog(for decision: TerminalLinkActivation.Decision) {
        guard decision.requiresConfirmation, let url = decision.openURL else { return }
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.openLinkQuestion)
        alert.informativeText = openLinkDialogDetail(for: decision)
        alert.alertStyle = decision.tier.isTrusted ? .informational : .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: AppLocalization.string(url.isFileURL ? .open : .openInBrowser))
        alert.addButton(withTitle: AppLocalization.string(.cancel))

        if let window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                NSWorkspace.shared.open(url)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    /// The target always comes from `safeTarget`, never from the raw payload:
    /// the host is printed on its own line so a `user:pass@host` prefix cannot
    /// be read as the destination, and the userinfo itself is redacted.
    private func openLinkDialogDetail(for decision: TerminalLinkActivation.Decision) -> String {
        var lines = [decision.safeTarget.displayURLString]
        if let host = decision.safeTarget.host {
            lines.append(AppLocalization.format(.openLinkHost, host))
        }
        if case .untrusted(.displayTextMismatch) = decision.tier {
            lines.append(AppLocalization.format(.openLinkVisibleText, decision.displayText))
        }
        return lines.joined(separator: "\n")
    }

    private func clearSelection() {
        guard selectionAnchor != nil || selectionFocus != nil else { return }
        selectionGestureState.beginCharacterSelection()
        selectionAnchor = nil
        selectionFocus = nil
        markFullDamage()
    }

    private func visibleRowsForRendering(limit: Int) -> [[TerminalScreenCell]] {
        let totalRows = contentRowCount
        guard totalRows > 0 else { return [] }
        let visibleCount = max(1, limit)
        let start = visibleRowStartIndex(limit: limit)
        let end = min(totalRows, start + visibleCount)
        var rows: [[TerminalScreenCell]] = []
        rows.reserveCapacity(visibleCount)
        for rowIndex in start..<end {
            guard let row = contentRow(at: rowIndex) else { continue }
            rows.append(row)
        }
        if rows.count < visibleCount {
            rows.append(contentsOf: Array(repeating: TerminalScreen.blankRow(columns: screen.columns), count: visibleCount - rows.count))
        }
        return rows
    }

    private func visibleRowStartIndex(limit: Int) -> Int {
        let totalRows = contentRowCount
        guard totalRows > 0 else { return 0 }
        let visibleCount = max(1, limit)
        let bottomStart = max(0, totalRows - visibleCount)
        return max(0, bottomStart - scrollbackOffset)
    }

    private func maxScrollbackOffset(visibleRows: Int? = nil) -> Int {
        let visibleCount = max(1, visibleRows ?? terminalMetrics().size.rows)
        return max(0, contentRowCount - visibleCount)
    }

    private var contentRowCount: Int {
        scrollbackRows.count + screen.cells.count
    }

    /// Pictures the terminal has been sent, and the bytes behind them.
    ///
    /// Two objects rather than one because they have different lifetimes: a
    /// placement dies when its rows scroll out of the buffer, and the bytes die
    /// with it *or* earlier, if a program sends more images than the store's
    /// budget holds.
    private let imageStore = TerminalImageStore()
    /// Points a document renderer's image scheme at this session's store.
    ///
    /// Only the document renderer serves pictures from bytes; the atlas
    /// outlines where they are and needs nothing. So this is a capability the
    /// renderer either has or does not, rather than another method on the
    /// protocol every renderer would have to answer for.
    private func connectImageStoreToRenderer() {
        guard let htmlRenderer = renderer as? TerminalHTMLView else {
            return
        }
        htmlRenderer.imageSchemeHandler.provider = { [weak self] identifier in
            self?.imageStore.entry(TerminalImageStore.Identifier(value: identifier))
        }
    }
    private var imagePlacements = TerminalImagePlacements()

    /// Accepts a picture at the cursor and moves the cursor past it.
    ///
    /// The rows an image occupies are rows the cursor has to skip, or the next
    /// line of output is printed through the picture. Feeding newlines is how
    /// that is done — it is what the shell would have done itself, so scrolling,
    /// scrollback and the reported cursor position all stay the model's own
    /// business rather than becoming a second set of rules for images.
    private func handleInlineImage(_ payload: TerminalInlineImagePayload) {
        let metrics = terminalMetrics()
        guard let representation = NSImage(data: payload.data), representation.size.width > 0 else {
            return
        }
        guard let identifier = imageStore.store(data: payload.data, name: payload.name) else {
            return
        }

        let size = TerminalInlineImageLayout.size(
            for: payload,
            pixelSize: representation.size,
            in: TerminalInlineImageLayout.Bounds(
                columns: metrics.size.columns,
                rows: metrics.size.rows,
                cellWidthPX: metrics.cellSize.width,
                cellHeightPX: metrics.cellSize.height
            )
        )

        imagePlacements.insert(TerminalImagePlacements.Placement(
            identifier: identifier,
            contentRow: absoluteContentRow(forRelative: scrollbackRows.count + cursorRow),
            column: cursorColumn,
            columns: size.columns,
            rows: size.rows,
            name: payload.name
        ))

        interpreter.advanceRowsForInlineImage(size.rows)
    }

    /// A content row counted from the start of the session rather than from
    /// the oldest row still kept.
    ///
    /// `contentRow(at:)` indexes retained rows, so its zero moves every time
    /// bounded scrollback drops a row off the top. An image anchored to that
    /// would slide down the buffer as the session aged — visible as a picture
    /// drifting away from the command that produced it.
    private func absoluteContentRow(forRelative index: Int) -> Int {
        scrollbackRows.diagnostics.retainedRowSummary.firstRetainedRowIndex + index
    }

    /// Drops pictures whose rows have fallen off the top of the scrollback.
    ///
    /// Bounded scrollback means rows leave, and an image whose last row has
    /// left is unreachable — holding its bytes would be a leak that grows with
    /// the session's age rather than with what is on screen.
    private func discardImagesScrolledOutOfTheBuffer() {
        let oldest = scrollbackRows.diagnostics.retainedRowSummary.firstRetainedRowIndex
        for identifier in imagePlacements.discardBefore(contentRow: oldest) {
            imageStore.discard(identifier)
        }
    }

    private func contentRow(at index: Int) -> [TerminalScreenCell]? {
        guard index >= 0 else { return nil }
        if index < scrollbackRows.count {
            return scrollbackRows.row(at: index)
        }
        let screenIndex = index - scrollbackRows.count
        guard screen.cells.indices.contains(screenIndex) else { return nil }
        return screen.cells[screenIndex]
    }

    private var currentSearchMatch: TerminalSearchMatch? {
        guard let currentSearchMatchIndex,
              searchResults.matches.indices.contains(currentSearchMatchIndex)
        else {
            return nil
        }
        return searchResults.matches[currentSearchMatchIndex]
    }

    private func scheduleSearch(
        query: String,
        preserving preservedMatch: TerminalSearchMatch?,
        delayNanoseconds: UInt64
    ) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        guard isSearchPresentationActive, !query.isEmpty else { return }
        let options = searchOptions

        searchTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled,
                  let snapshot = self?.searchSnapshot()
            else {
                return
            }
            let matchingTask = Task.detached(priority: .userInitiated) {
                TerminalSearchMatcher.scan(query: query, options: options, in: snapshot)
            }
            let scanResult = await withTaskCancellationHandler(
                operation: { await matchingTask.value },
                onCancel: { matchingTask.cancel() }
            )
            guard !Task.isCancelled else { return }
            self?.applySearchMatches(
                scanResult,
                generation: generation,
                query: query,
                preserving: preservedMatch
            )
        }
    }

    private func refreshSearchAfterContentChange(preservingCurrentMatch: Bool = true) {
        guard isSearchPresentationActive, !searchQuery.isEmpty else { return }
        let preservedMatch = preservingCurrentMatch ? currentSearchMatch : nil
        searchResults = .empty
        currentSearchMatchIndex = nil
        publishSearchSummary()
        markFullDamage()
        scheduleSearch(
            query: searchQuery,
            preserving: preservedMatch,
            delayNanoseconds: AppConstants.Terminal.searchContentRefreshDebounceNanoseconds
        )
    }

    private func searchSnapshot() -> TerminalSearchSnapshot {
        TerminalSearchSnapshot(
            scrollbackRows: scrollbackRows,
            screenRows: screen.cells,
            preferredStartRow: visibleContentRowRange().lowerBound
        )
    }

    private func applySearchMatches(
        _ scanResult: TerminalSearchScanResult,
        generation: UInt64,
        query: String,
        preserving preservedMatch: TerminalSearchMatch?
    ) {
        guard isSearchPresentationActive,
              generation == searchGeneration,
              query == searchQuery
        else {
            return
        }

        searchResults = TerminalSearchResults(
            matches: scanResult.matches,
            isTruncated: scanResult.isTruncated
        )
        let matches = searchResults.matches
        if let preservedMatch,
           let preservedIndex = matches.firstIndex(of: preservedMatch) {
            currentSearchMatchIndex = preservedIndex
        } else {
            currentSearchMatchIndex = TerminalSearchNavigation.preferredInitialIndex(
                matches: matches,
                visibleRows: visibleContentRowRange()
            )
        }
        revealCurrentSearchMatch()
        publishSearchSummary()
        markFullDamage()
        updateRendererFrame()
    }

    private func moveSearchSelection(by delta: Int) {
        currentSearchMatchIndex = TerminalSearchNavigation.movedIndex(
            from: currentSearchMatchIndex,
            by: delta,
            matchCount: searchResults.matches.count
        )
        revealCurrentSearchMatch()
        publishSearchSummary()
        markFullDamage()
        updateRendererFrame()
    }

    private func revealCurrentSearchMatch() {
        guard let currentSearchMatch else { return }
        let metrics = terminalMetrics()
        let nextOffset = TerminalSearchNavigation.scrollbackOffsetToReveal(
            row: currentSearchMatch.row,
            contentRowCount: contentRowCount,
            visibleRowCount: metrics.size.rows,
            currentOffset: scrollbackOffset
        )
        guard nextOffset != scrollbackOffset else { return }
        scrollbackOffset = nextOffset
        updateScrollIndicator()
    }

    private func visibleContentRowRange() -> Range<Int> {
        let visibleRowCount = max(1, terminalMetrics().size.rows)
        let start = visibleRowStartIndex(limit: visibleRowCount)
        return start..<min(contentRowCount, start + visibleRowCount)
    }

    private func publishSearchSummary() {
        onSearchSummaryChange?(TerminalSearchSummary(
            currentIndex: currentSearchMatchIndex,
            totalMatches: searchResults.matches.count,
            isTruncated: searchResults.isTruncated
        ))
    }

    private func terminalMetrics() -> TerminalMetrics {
        let scale = currentBackingScale
        let rawLineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        let rawWidth = max(
            AppConstants.Terminal.minimumCellWidthPX,
            ("0" as NSString).size(withAttributes: [.font: font]).width
        )
        let lineHeight = snapMetricToPhysicalPixels(rawLineHeight, scale: scale)
        let width = snapMetricToPhysicalPixels(rawWidth, scale: scale)
        let columns = max(1, Int((bounds.width - padding.left - padding.right) / width))
        let rows = max(1, Int((bounds.height - padding.top - padding.bottom) / lineHeight))
        return TerminalMetrics(
            size: TerminalSize(columns: columns, rows: rows),
            cellSize: TerminalFrameSize(width: Double(width), height: Double(lineHeight))
        )
    }

    /// Capability replies read the renderer's own metrics path so `CSI 14t`,
    /// `CSI 16t`, and `CSI 18t` can never disagree with the grid the PTY and
    /// the renderer were sized with.
    private func terminalCapabilityMetrics() -> TerminalCapabilityMetrics? {
        let metrics = terminalMetrics()
        guard metrics.cellSize.width > 0, metrics.cellSize.height > 0 else { return nil }
        return TerminalCapabilityMetrics(
            columns: metrics.size.columns,
            rows: metrics.size.rows,
            cellWidthPX: metrics.cellSize.width,
            cellHeightPX: metrics.cellSize.height
        )
    }

    var terminalColorSchemeMode: TerminalColorSchemeMode {
        TerminalColorSchemeMode(isLightBackground: terminalDefaultStyle.isLightBackground)
    }

    /// Mirrors `TerminalOutputInterpreter.isReplayingScrollback`. The scrollback
    /// replay path sets this around a replay so no restored capability query
    /// can be answered into the live shell.
    var isReplayingScrollback: Bool {
        get { interpreter.isReplayingScrollback }
        set { interpreter.isReplayingScrollback = newValue }
    }

    /// Trailing rows to persist for this pane: the newest
    /// `maximumRows` of scrollback plus the live screen, copied out on the main
    /// actor so the snapshot writer never touches terminal state.
    ///
    /// Bounded here rather than after serialization: a million-row pane must not
    /// be rendered into a multi-megabyte string only to have the store budget
    /// throw almost all of it away.
    func persistableScrollbackRows(
        maximumRows: Int = AppConstants.TerminalScrollbackSnapshots.maximumCapturedRowCount
    ) -> [[TerminalScreenCell]] {
        guard maximumRows > 0 else {
            return []
        }
        let start = max(0, contentRowCount - maximumRows)
        return (start..<contentRowCount).compactMap { contentRow(at: $0) }
    }

    /// Default style the persisted rows were rendered against, so a replay can
    /// tell a styled cell from an unstyled one.
    var persistableDefaultStyle: TerminalTextStyle {
        terminalDefaultStyle
    }

    /// `TerminalScrollbackReplayTarget` ingest point. Display only: restored
    /// bytes go into the screen model through the private interpreter and
    /// nothing is ever written back to the PTY. The conformance itself is
    /// declared in `TerminalScrollbackReplay.swift`.
    func consumeReplayedScrollback(_ text: String) {
        interpreter.interpret(text)
    }

    var colorSchemeUpdateModeEnabled: Bool {
        get { interpreter.colorSchemeUpdateModeEnabled }
        set { interpreter.colorSchemeUpdateModeEnabled = newValue }
    }

    /// Pushes `CSI ? 997 ; Ps n` when the terminal's color scheme actually
    /// flips and a TUI is still subscribed via DEC mode 2031. Font, opacity,
    /// and scrollback changes also reach `apply(settings:)`, so only a real
    /// dark/light flip is reported.
    private func reportColorSchemeChangeIfNeeded(previousMode: TerminalColorSchemeMode) {
        let nextMode = terminalColorSchemeMode
        guard nextMode != previousMode else { return }
        guard colorSchemeUpdateModeEnabled else { return }
        sendTerminalResponse(TerminalCapabilityReplies.colorSchemeNotification(nextMode))
    }

    /// This pane's contribution to the one-shot diagnostics report. Every value
    /// here is a count, a mode, or a geometry; terminal content, command text,
    /// and full paths never leave the surface.
    func diagnosticsReportPane() -> TerminalDiagnosticsReportInput.Pane {
        let metrics = terminalMetrics()
        return TerminalDiagnosticsReportInput.Pane(
            paneIdentifier: agentPaneIdentifier,
            columns: metrics.size.columns,
            rows: metrics.size.rows,
            cellWidthPX: metrics.cellSize.width,
            cellHeightPX: metrics.cellSize.height,
            isUsingAlternateScreen: isUsingAlternateScreen,
            isBracketedPasteEnabled: bracketedPasteEnabled,
            isColorSchemeUpdateModeEnabled: colorSchemeUpdateModeEnabled,
            isReplayingScrollback: isReplayingScrollback,
            workingDirectoryName: TerminalDiagnosticsReportBuilder.workingDirectoryName(
                fromPath: currentWorkingDirectory
            ),
            isRemoteWorkingDirectory: workingDirectoryLocation.remoteHost != nil,
            eventLedger: runtimeEventLedger.diagnostics,
            latestTrace: latestRuntimeTraceSummary(),
            resizeSourceOfTruth: nil,
            scrollback: TerminalScrollbackDiagnosticsSummary(scrollbackRows.diagnostics),
            renderDamage: renderDamageSummary(),
            recentEvents: runtimeEventLedger.events
        )
    }

    private func latestRuntimeTraceSummary() -> TerminalTraceTimelineSummary? {
        guard let traceID = runtimeEventLedger.events.last?.traceID else { return nil }
        return runtimeEventLedger.timelineSummary(for: traceID)
    }

    private func renderDamageSummary() -> String {
        let damage = renderer.damageDiagnostics
        return [
            "decision=\(damage.redrawDecision)",
            "policy=\(damage.schedulingPolicy)",
            "dirtyRects=\(damage.dirtyRectCount)",
            "scissorRects=\(damage.scissorRectCount)",
            "scissorPlanReady=\(damage.scissorPlanIsReady)",
        ].joined(separator: " ")
    }

    private var effectiveBackingScale: CGFloat {
        window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func snapMetricToPhysicalPixels(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        ceil(value * scale) / scale
    }

    private func apply(settings: AppSettings) {
        appliedSettings = settings
        hideMouseCursorWhileTypingEnabled = settings.terminal.hideMouseCursorWhileTyping
        confirmMultilinePasteEnabled = settings.terminal.confirmMultilinePaste
        commandFinishNotificationMode = settings.terminal.commandFinishNotificationMode
        minimumCommandDurationSeconds = settings.terminal.minimumCommandDurationSeconds
        notifyOnAgentWaitingEnabled = settings.terminal.notifyOnAgentWaiting
        // Live, not next-session: the switch governs how the parser answers a
        // sequence, so turning it off must silence the next `CSI 21 t` in a pane
        // that is already running.
        interpreter.titleReportsEnabled = settings.terminal.titleReportsEnabled
        // Turning the setting off takes down a banner that is on screen at that
        // moment rather than leaving it parked until the agent moves on.
        updateAgentWaitingNotification()
        let nextFont = Self.terminalFont(for: settings)
        let previousDefaultStyle = terminalDefaultStyle
        let previousColorSchemeMode = terminalColorSchemeMode
        let previousAnsiColors = terminalAnsiColors
        let nextAnsiColors = Self.ansiColors(from: settings)
        font = nextFont
        terminalDefaultStyle = TerminalTextStyle(
            foreground: settings.terminal.colors.foregroundColor,
            background: settings.terminal.colors.backgroundColor
        )
        terminalAnsiColors = nextAnsiColors
        let colorMap = TerminalStyleColorMap(
            previousDefaultStyle: previousDefaultStyle,
            nextDefaultStyle: terminalDefaultStyle,
            previousAnsiColors: previousAnsiColors,
            nextAnsiColors: nextAnsiColors
        )
        maxScrollbackRows = max(1, settings.terminal.scrollbackLines)
        currentStyle = terminalDefaultStyle
        screen.remapColors(colorMap)
        scrollbackRows.remapColors(colorMap)
        screen.remapStyle(from: previousDefaultStyle, to: terminalDefaultStyle)
        scrollbackRows.remapStyle(from: previousDefaultStyle, to: terminalDefaultStyle)
        if trimScrollbackRowsToLimit() {
            markFullDamage()
        }
        updateScrollIndicator()
        viewportBackground = nil
        layer?.backgroundColor = terminalDefaultStyle.background.cgColor
        renderer.applyAppearance(
            font: nextFont,
            backgroundColor: terminalDefaultStyle.background,
            cursorColor: settings.terminal.colors.cursorColor
        )
        markFullDamage()
        syncSizeWithView()
        updateRendererFrame()
        reportColorSchemeChangeIfNeeded(previousMode: previousColorSchemeMode)
    }

    /// The configured face at the size the zoom layer resolves to. Every font
    /// the surface builds goes through here so ⌘+ / ⌘- / ⌘0 cannot be bypassed
    /// by a second construction site drifting out of sync.
    private static func terminalFont(for settings: AppSettings) -> NSFont {
        let sizePT = CGFloat(
            TerminalFontZoomCoordinator.shared.fontSizePT(configuredFontSizePT: settings.terminal.fontSize)
        )
        return NSFont(name: settings.terminal.fontName, size: sizePT)
            ?? NSFont.monospacedSystemFont(ofSize: sizePT, weight: .regular)
    }

    private static func ansiColors(from settings: AppSettings) -> [SIMD4<Float>] {
        let configuredAnsiColors = settings.terminal.colors.ansi.map {
            ColorHexParser.parse($0, fallback: DesignTokens.Color.terminalForeground)
        }
        return configuredAnsiColors.count >= TerminalColorSettings.requiredAnsiColorCount
            ? Array(configuredAnsiColors.prefix(TerminalColorSettings.requiredAnsiColorCount))
            : DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright
    }

    private func logScreenDumpIfNeeded(rows: [[TerminalScreenCell]], damage: TerminalFrameDamage, metrics: TerminalMetrics) {
        guard DebugOptions.screenDump || DebugOptions.layout else { return }
        NSLog(
            "Kurotty screen dump: frame=%llu rows=%d cols=%d cursor=(%d,%d) scrollRegion=%d-%d full=%@ dirtyRows=%@ cell=(%0.2f,%0.2f) scale=%0.2f",
            debugFrameIndex,
            metrics.size.rows,
            metrics.size.columns,
            cursorRow,
            cursorColumn,
            scrollRegionTop,
            scrollRegionBottom,
            damage.isFull ? "yes" : "no",
            damage.rows.map(String.init).joined(separator: ","),
            metrics.cellSize.width,
            metrics.cellSize.height,
            currentBackingScale
        )
        for rowIndex in 0..<min(rows.count, metrics.size.rows) {
            let row = Array(rows[rowIndex].prefix(metrics.size.columns))
            let cursorMarker = rowIndex == cursorRow ? " cursorCol=\(cursorColumn)" : ""
            NSLog(
                "Kurotty row[%03d]%@: occupiedCells=%d bgRuns=%@ fgRuns=%@",
                rowIndex,
                cursorMarker,
                TerminalScreenDiagnostics.occupiedCellCount(in: row),
                TerminalScreenDiagnostics.styleRuns(for: row.map(\.style), background: true),
                TerminalScreenDiagnostics.styleRuns(for: row.map(\.style), background: false)
            )
        }
    }

    private func currentCursorCellRectInViewCoordinates() -> NSRect {
        let metrics = terminalMetrics()
        let imeAnchorPosition = currentIMEAnchorPosition()
        return Self.cursorCellRectInViewCoordinates(
            boundsHeight: bounds.height,
            padding: padding,
            cursorRow: imeAnchorPosition.row,
            cursorColumn: imeAnchorPosition.column,
            cellSize: CGSize(
                width: CGFloat(metrics.cellSize.width),
                height: CGFloat(metrics.cellSize.height)
            ),
            columns: metrics.size.columns,
            rows: metrics.size.rows
        )
    }

    private func currentIMEAnchorPosition() -> TerminalCellPosition {
        markedTextAnchor ?? TerminalCellPosition(row: cursorRow, column: cursorColumn)
    }

    static func cursorCellRectInViewCoordinates(
        boundsHeight: CGFloat,
        padding: NSEdgeInsets,
        cursorRow: Int,
        cursorColumn: Int,
        cellSize: CGSize,
        columns: Int,
        rows: Int
    ) -> NSRect {
        let clampedRow = min(max(0, cursorRow), max(0, rows - 1))
        let clampedColumn = min(max(0, cursorColumn), max(0, columns - 1))
        return NSRect(
            x: padding.left + CGFloat(clampedColumn) * cellSize.width,
            // Terminal row 0 is visually at the top. NSView local coordinates are
            // bottom-origin here, so IME/AppKit must use the same y math as Metal
            // cursor placement instead of the top-origin terminal row formula.
            y: boundsHeight - padding.top - CGFloat(clampedRow + 1) * cellSize.height,
            width: max(1, cellSize.width),
            height: max(1, cellSize.height)
        )
    }

    private func logIMEFirstRect(
        range: NSRange,
        actualRange: NSRange?,
        localRect: NSRect,
        windowRect: NSRect,
        screenRect: NSRect
    ) {
        guard DebugOptions.imeRect || DebugOptions.inputClient || DebugOptions.cursorCoordinates else { return }
        NSLog(
            "Kurotty IME firstRect: cursor=(row:%d,col:%d) requested=%@ actual=%@ local=%@ window=%@ screen=%@ bounds=%@ scale=%0.2f flipped=%@ marked=%@ selected=%@",
            cursorRow,
            cursorColumn,
            NSStringFromRange(range),
            actualRange.map(NSStringFromRange) ?? "nil",
            NSStringFromRect(localRect),
            NSStringFromRect(windowRect),
            NSStringFromRect(screenRect),
            NSStringFromRect(bounds),
            effectiveBackingScale,
            isFlipped ? "yes" : "no",
            NSStringFromRange(markedRange()),
            NSStringFromRange(selectedRange())
        )
    }


    private func layoutScrollIndicator() {
        updateScrollIndicator()
    }

    private func updateScrollIndicator() {
        let visibleRows = max(1, terminalMetrics().size.rows)
        // The rail is laid out first because the indicator's track has to know
        // how much of the trailing edge the rail took.
        updatePromptRail()
        scrollIndicatorCoordinator.update(
            bounds: bounds,
            visibleRows: visibleRows,
            maxScrollbackOffset: maxScrollbackOffset(visibleRows: visibleRows),
            scrollbackOffset: scrollbackOffset,
            trailingInsetPX: promptRailCoordinator.trailingInsetPX
        )
    }

    private func updatePromptRail() {
        let retainedRowSummary = scrollbackRows.retainedRowSummary
        promptRailCoordinator.update(
            bounds: bounds,
            contentRowCount: contentRowCount,
            firstRetainedRowIndex: retainedRowSummary.firstRetainedRowIndex,
            nextRowIndex: retainedRowSummary.nextRowIndex
        )
    }

    /// Absolute scrollback row the cursor sits on right now.
    ///
    /// `nextRowIndex` is the index the next row appended to the scrollback will
    /// take, so it is also the absolute index of screen row 0. Reading it while
    /// an OSC is being executed is what makes the number correct: the parser is
    /// synchronous, so nothing has moved the cursor since the sequence arrived.
    private var cursorAbsoluteRowIndex: Int {
        scrollbackRows.retainedRowSummary.nextRowIndex + cursorRow
    }

    /// Scrolls the viewport so `absoluteRow` is visible, if it still exists.
    ///
    /// A row that has been trimmed out of the scrollback resolves to nothing
    /// and the viewport stays put, which is the honest answer: the command is
    /// gone, and scrolling to where it used to be would be a lie.
    private func scrollToAbsoluteRow(_ absoluteRow: Int) {
        let firstRetainedRowIndex = scrollbackRows.retainedRowSummary.firstRetainedRowIndex
        let contentRow = absoluteRow - firstRetainedRowIndex
        guard contentRow >= 0, contentRow < contentRowCount else { return }
        scrollToContentRow(contentRow)
    }

    private func scrollToContentRow(_ contentRow: Int) {
        let metrics = terminalMetrics()
        let nextOffset = TerminalSearchNavigation.scrollbackOffsetToReveal(
            row: contentRow,
            contentRowCount: contentRowCount,
            visibleRowCount: metrics.size.rows,
            currentOffset: scrollbackOffset
        )
        guard nextOffset != scrollbackOffset else { return }
        scrollbackOffset = nextOffset
        markFullDamage()
        updateScrollIndicator()
        updateRendererFrame()
    }

    /// Scrolls to the previous or next shell prompt.
    ///
    /// Reads the rail's markers rather than the rail's geometry, so it answers
    /// identically whether the rail is drawn, hidden behind an empty session,
    /// or switched off in Settings.
    func jumpToPrompt(_ direction: TerminalPromptRailNavigation.Direction) {
        let visibleRowCount = max(1, terminalMetrics().size.rows)
        let firstRetainedRowIndex = scrollbackRows.retainedRowSummary.firstRetainedRowIndex
        guard let targetRow = TerminalPromptRailNavigation.targetContentRow(
            markers: promptRailCoordinator.markers,
            firstRetainedRowIndex: firstRetainedRowIndex,
            contentRowCount: contentRowCount,
            currentTopContentRow: visibleRowStartIndex(limit: visibleRowCount),
            direction: direction
        ) else {
            return
        }
        scrollToContentRow(targetRow)
    }


    private func dispatchTerminalIntegrationOsc(_ command: String) -> TerminalOSCDispatcher.Event {
        var dispatcher = TerminalOSCDispatcher(
            osc52Policy: TerminalOSC52Policy(policy: securityPolicy),
            shellIntegration: shellIntegration
        )
        // The attached PTY runs a locally spawned shell session; remote origin
        // classification requires session-level transport awareness that this
        // surface does not have yet.
        let event = dispatcher.dispatch(command, origin: .local)
        shellIntegration = dispatcher.shellIntegration
        return event
    }

    private func handleClipboardWriteEvent(_ event: TerminalOSCDispatcher.Event) {
        guard case let .osc52(evaluation, base64Payload) = event else {
            return
        }
        guard evaluation.operation == .write else {
            return
        }
        switch evaluation.decision {
        case .deny:
            return
        case .allow:
            guard let text = TerminalOSC52Policy.decodedText(fromBase64Payload: base64Payload),
                  !text.isEmpty
            else {
                return
            }
            writeToPasteboard(text)
        case .ask:
            guard let request = TerminalClipboardConfirmationRequest(
                evaluation: evaluation,
                base64Payload: base64Payload
            ) else {
                return
            }
            // A pane the user is not looking at must not open a sheet on the
            // window they are working in; the request waits for focus instead.
            switch clipboardConfirmationQueue.submit(request, isFocused: isTerminalFocusedForUser) {
            case .present(let request):
                presentClipboardConfirmation(request)
            case .deferred:
                break
            }
        }
    }

    private func writeToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Presents a held OSC 52 confirmation, then drains whatever the coalescing
    /// rule kept while the sheet was up.
    private func presentClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.clipboardWriteQuestion)
        // Deliberately omits the payload: a confirmation dialog is not a place
        // to print what a program wants to put on the pasteboard.
        alert.informativeText = AppLocalization.format(.clipboardWriteExplanation, request.byteCount)
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: AppLocalization.string(.clipboardWriteConfirm))
        alert.addButton(withTitle: AppLocalization.string(.cancel))

        let apply: (Bool) -> Void = { [weak self] approved in
            guard let self else { return }
            if approved {
                writeToPasteboard(request.text)
            }
            if let next = clipboardConfirmationQueue.didFinishPresenting(
                isFocused: isTerminalFocusedForUser
            ) {
                presentClipboardConfirmation(next)
            }
        }

        if let window {
            alert.beginSheetModal(for: window) { response in
                apply(response == .alertFirstButtonReturn)
            }
        } else {
            apply(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func presentDeferredClipboardConfirmationIfNeeded() {
        guard let request = clipboardConfirmationQueue.focusDidChange(
            isFocused: isTerminalFocusedForUser
        ) else {
            return
        }
        presentClipboardConfirmation(request)
    }

    private func handleTerminalIntegrationEvent(_ event: TerminalOSCDispatcher.Event) {
        if case .commandProgress(let report) = event {
            onCommandProgress?(.reported(report))
            return
        }
        guard case .shellIntegration(let shellEvent) = event else {
            return
        }

        switch shellEvent {
        case .promptStart:
            // The prompt row, not the command row: a marker has to land on the
            // line the user reads as the start of the command, and OSC 133 `B`
            // arrives after the prompt has already been drawn.
            pendingPromptAbsoluteRowIndex = cursorAbsoluteRowIndex
        case .commandStart:
            shellIntegration.setActiveCommandText(lastSubmittedCommandText)
            onCommandProgress?(.commandStarted)
        case .commandEnd(let context):
            recordPromptRailMarker(for: context)
            TerminalCommandHistoryStore.shared.record(completion: context)
            onCommandProgress?(.commandEnded(exitCode: context.exitCode))
            notifyCommandFinishedIfNeeded(context)
        default:
            break
        }
    }

    /// Anchors a finished command onto the rail.
    ///
    /// Falls back to the cursor's row when no prompt boundary was seen, which
    /// happens when integration is installed mid-session and the first command
    /// to complete never had an `A`. A marker one line below the prompt is
    /// still a marker on the right command; no marker at all would silently
    /// drop it.
    private func recordPromptRailMarker(for context: TerminalCommandCompletionContext) {
        defer { pendingPromptAbsoluteRowIndex = nil }
        guard let commandText = context.commandText else { return }
        let finishedAt = Date()
        promptRailCoordinator.record(
            TerminalPromptRailMarker(
                spanID: context.span.id,
                absoluteRowIndex: pendingPromptAbsoluteRowIndex ?? cursorAbsoluteRowIndex,
                entry: TerminalCommandHistoryEntry(
                    commandText: commandText,
                    cwd: context.cwd,
                    cwdHost: context.cwdHost,
                    exitCode: context.exitCode,
                    startedAt: context.duration.map { finishedAt.addingTimeInterval(-$0) },
                    finishedAt: finishedAt,
                    duration: context.duration
                )
            )
        )
    }

    /// The waiting banner is driven from the registry rather than from the
    /// pane's own OSC 9999 channel, because the loopback hook reports into the
    /// same registry without passing through this surface's PTY at all.
    private func observeAgentActivityForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentActivityDidChangeForNotifications(_:)),
            name: AgentActivityRegistry.didChangeNotification,
            object: nil
        )
    }

    @objc private func agentActivityDidChangeForNotifications(_ notification: Notification) {
        let changedPaneIdentifier = notification.userInfo?[
            AgentActivityRegistry.paneIdentifierNotificationKey
        ] as? String
        guard changedPaneIdentifier == nil || changedPaneIdentifier == agentPaneIdentifier else {
            return
        }
        updateAgentWaitingNotification()
    }

    /// Thin glue: read the pane's resolved status, ask the policy, do what it
    /// says. Every rule about when a banner is owed lives in the policy.
    private func updateAgentWaitingNotification() {
        let status = AgentActivityRegistry.shared.status(for: agentPaneIdentifier)
        switch agentWaitingNotificationPolicy.decide(
            state: status?.state,
            isEnabled: notifyOnAgentWaitingEnabled,
            isFocused: isTerminalFocusedForUser,
            now: Date()
        ) {
        case .doNothing:
            return
        case .withdraw:
            notifier.withdrawAgentWaitingNotification(paneIdentifier: agentPaneIdentifier)
        case .notify(let state):
            notifier.notifyAgentWaiting(
                content: AgentWaitingNotificationContent.make(
                    state: state,
                    agentName: status?.agentName,
                    detail: status?.detail,
                    paneTitle: notificationSessionTitle()
                ),
                paneIdentifier: agentPaneIdentifier
            )
        }
    }

    private func notifyCommandFinishedIfNeeded(_ context: TerminalCommandCompletionContext) {
        lastSubmittedCommandText = nil
        guard TerminalCommandFinishNotificationPolicy.shouldNotify(
            mode: commandFinishNotificationMode,
            minimumDuration: minimumCommandDurationSeconds,
            actualDuration: context.duration,
            isFocused: isTerminalFocusedForUser
        ) else {
            return
        }
        notifier.notifyCommandFinished(content: TerminalCommandCompletionNotificationContent.make(from: context))
    }

    private func handleDesktopNotificationEvent(_ event: TerminalOSCDispatcher.Event) {
        // OSC 1337 carries both, so both arrive here. An image is not a
        // notification and takes the other path entirely.
        if case .inlineImage(let payload) = event {
            handleInlineImage(payload)
            return
        }
        guard case .desktopNotification(let content) = event else {
            return
        }
        guard shouldDeliverUserNotification else {
            return
        }
        notifier.notifyTerminalNotification(
            content: content.addingFallbackSubtitle(notificationSessionTitle())
        )
    }

    private func ringTerminalBell() {
        NSSound.beep()
        guard shouldDeliverUserNotification else {
            return
        }
        notifier.notifyBell()
    }

    private func respondToOscQuery(_ code: String) {
        switch code {
        case "10":
            sendTerminalResponse("\u{1b}]10;\(terminalOscColor(terminalDefaultStyle.foreground))\u{1b}\\")
        case "11":
            sendTerminalResponse("\u{1b}]11;\(terminalOscColor(terminalDefaultStyle.background))\u{1b}\\")
        default:
            break
        }
    }

    private func publishTitle() {
        NotificationCenter.default.post(
            name: Self.titleDidChangeNotification,
            object: self,
            userInfo: [Self.titleNotificationKey: displayTitle()]
        )
    }

    private func displayTitle() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let displayPath: String
        if currentWorkingDirectory == home {
            displayPath = "~"
        } else if currentWorkingDirectory.hasPrefix(home + "/") {
            displayPath = "~/" + currentWorkingDirectory.dropFirst(home.count + 1)
        } else {
            displayPath = currentWorkingDirectory
        }

        let trimmedTitle = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty || trimmedTitle == displayPath ? "-zsh" : trimmedTitle
        let named = title.contains(displayPath) && displayPath != "~"
            ? title
            : "\(displayPath) (\(title))"

        // A hostname in eight-point grey is not a difference anyone notices at
        // the moment it matters. A glyph is.
        guard let glyph = TerminalSessionGlyph.glyph(for: interpreter.currentWorkingDirectoryLocation) else {
            return named
        }
        return "\(glyph) \(named)"
    }

    private func notificationSessionTitle() -> String {
        let trimmedTitle = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? displayTitle() : trimmedTitle
    }

    private func terminalOscColor(_ color: SIMD4<Float>) -> String {
        func component(_ value: Float) -> String {
            let clamped = max(0, min(1, value))
            return String(format: "%04x", Int((clamped * 65_535).rounded()))
        }
        return "rgb:\(component(color.x))/\(component(color.y))/\(component(color.z))"
    }


    private func consumePendingDamage(metrics: TerminalMetrics) -> TerminalFrameDamage {
        let visibleRows = max(1, metrics.size.rows)
        let rows: [Int]
        let isFull = pendingFullDamage
        if isFull {
            rows = Array(0..<visibleRows)
        } else {
            rows = pendingDirtyRows
                .filter { $0 >= 0 && $0 < visibleRows }
                .sorted()
        }
        let rects = rows.map { row in
            let cellWidth = CGFloat(metrics.cellSize.width)
            let cellHeight = CGFloat(metrics.cellSize.height)
            return TerminalFrameRect(
                x: Double(padding.left),
                y: Double(bounds.height - padding.top - cellHeight * CGFloat(row + 1)),
                width: Double(cellWidth * CGFloat(metrics.size.columns)),
                height: Double(cellHeight)
            )
        }
        pendingDirtyRows.removeAll(keepingCapacity: true)
        pendingFullDamage = false
        return TerminalFrameDamage(rows: rows, rects: rects, isFull: isFull)
    }

}

// MARK: - Interpreter state and mutation forwarding
// TerminalOutputInterpreter owns the terminal-model state. These forwarders
// keep the surface view's rendering, selection, resize, IME, and testing
// paths reading and writing that state under the original names.
extension TerminalSurfaceView {
    private var terminalDefaultStyle: TerminalTextStyle {
        get { interpreter.terminalDefaultStyle }
        set { interpreter.terminalDefaultStyle = newValue }
    }

    private var terminalAnsiColors: [SIMD4<Float>] {
        get { interpreter.terminalAnsiColors }
        set { interpreter.terminalAnsiColors = newValue }
    }

    private var maxScrollbackRows: Int {
        get { interpreter.maxScrollbackRows }
        set { interpreter.maxScrollbackRows = newValue }
    }

    private var screen: TerminalScreen {
        get { interpreter.screen }
        set { interpreter.screen = newValue }
    }

    private var scrollbackRows: BoundedScrollbackRows {
        get { interpreter.scrollbackRows }
        set { interpreter.scrollbackRows = newValue }
    }

    private var scrollbackOffset: Int {
        get { interpreter.scrollbackOffset }
        set { interpreter.scrollbackOffset = newValue }
    }

    private var normalScreenSnapshot: TerminalScreen? {
        get { interpreter.normalScreenSnapshot }
        set { interpreter.normalScreenSnapshot = newValue }
    }

    private var cursorRow: Int {
        get { interpreter.cursorRow }
        set { interpreter.cursorRow = newValue }
    }

    private var cursorColumn: Int {
        get { interpreter.cursorColumn }
        set { interpreter.cursorColumn = newValue }
    }

    private var scrollRegionTop: Int {
        get { interpreter.scrollRegionTop }
        set { interpreter.scrollRegionTop = newValue }
    }

    private var scrollRegionBottom: Int {
        get { interpreter.scrollRegionBottom }
        set { interpreter.scrollRegionBottom = newValue }
    }

    private var cursorVisible: Bool {
        get { interpreter.cursorVisible }
        set { interpreter.cursorVisible = newValue }
    }

    private var cursorStyle: TerminalCursorStyle {
        get { interpreter.cursorStyle }
        set { interpreter.cursorStyle = newValue }
    }

    private var isUsingAlternateScreen: Bool {
        get { interpreter.isUsingAlternateScreen }
        set { interpreter.isUsingAlternateScreen = newValue }
    }

    private var insertModeEnabled: Bool {
        get { interpreter.insertModeEnabled }
        set { interpreter.insertModeEnabled = newValue }
    }

    private var originModeEnabled: Bool {
        get { interpreter.originModeEnabled }
        set { interpreter.originModeEnabled = newValue }
    }

    private var wraparoundModeEnabled: Bool {
        get { interpreter.wraparoundModeEnabled }
        set { interpreter.wraparoundModeEnabled = newValue }
    }

    private var applicationCursorKeysEnabled: Bool {
        get { interpreter.applicationCursorKeysEnabled }
        set { interpreter.applicationCursorKeysEnabled = newValue }
    }

    private var applicationKeypadEnabled: Bool {
        get { interpreter.applicationKeypadEnabled }
        set { interpreter.applicationKeypadEnabled = newValue }
    }

    private var modifyOtherKeysMode: Int {
        get { interpreter.modifyOtherKeysMode }
        set { interpreter.modifyOtherKeysMode = newValue }
    }

    private var extendedKeyFormat: TerminalExtendedKeyFormat {
        get { interpreter.extendedKeyFormat }
        set { interpreter.extendedKeyFormat = newValue }
    }

    private var tabStops: Set<Int> {
        get { interpreter.tabStops }
        set { interpreter.tabStops = newValue }
    }

    private var bracketedPasteEnabled: Bool {
        get { interpreter.bracketedPasteEnabled }
        set { interpreter.bracketedPasteEnabled = newValue }
    }

    private var mouseReportingState: TerminalMouseReportingState {
        get { interpreter.mouseReportingState }
        set { interpreter.mouseReportingState = newValue }
    }

    private var focusReportingState: TerminalFocusReportingState {
        get { interpreter.focusReportingState }
        set { interpreter.focusReportingState = newValue }
    }

    private var pressedMouseButton: TerminalMouseButton? {
        get { interpreter.pressedMouseButton }
        set { interpreter.pressedMouseButton = newValue }
    }

    private var currentStyle: TerminalTextStyle {
        get { interpreter.currentStyle }
        set { interpreter.currentStyle = newValue }
    }

    private var activeHyperlinkURL: String? {
        get { interpreter.activeHyperlinkURL }
        set { interpreter.activeHyperlinkURL = newValue }
    }

    private var terminalTitle: String {
        get { interpreter.terminalTitle }
        set { interpreter.terminalTitle = newValue }
    }

    private var currentWorkingDirectory: String {
        get { interpreter.currentWorkingDirectory }
        set { interpreter.currentWorkingDirectory = newValue }
    }

    /// Read-only view of the OSC 7 shell-integration working directory for
    /// window chrome such as the file-explorer panel. Defaults to the user's
    /// home directory until the shell reports a directory change.
    var workingDirectoryPath: String {
        interpreter.currentWorkingDirectory
    }

    /// The OSC 7 working directory together with its host, so panels that only
    /// work on local files (file explorer, git status) can tell an SSH session
    /// apart from a local one instead of listing a same-named local path.
    var workingDirectoryLocation: TerminalWorkingDirectoryLocation {
        interpreter.currentWorkingDirectoryLocation
    }

    private var shellIntegration: TerminalShellIntegration {
        get { interpreter.shellIntegration }
        set { interpreter.shellIntegration = newValue }
    }

    private var lastSentSize: TerminalSize {
        get { interpreter.lastSentSize }
        set { interpreter.lastSentSize = newValue }
    }

    private var pendingDirtyRows: Set<Int> {
        get { interpreter.pendingDirtyRows }
        set { interpreter.pendingDirtyRows = newValue }
    }

    private var pendingFullDamage: Bool {
        get { interpreter.pendingFullDamage }
        set { interpreter.pendingFullDamage = newValue }
    }

    private var scrollbackRowsAppendedDuringOutput: Int {
        get { interpreter.scrollbackRowsAppendedDuringOutput }
        set { interpreter.scrollbackRowsAppendedDuringOutput = newValue }
    }

    private func markDirty(row: Int) {
        interpreter.markDirty(row: row)
    }

    private func markDirty(rows: Range<Int>) {
        interpreter.markDirty(rows: rows)
    }

    private func markFullDamage() {
        interpreter.markFullDamage()
    }

    private func resetScrollRegion() {
        interpreter.resetScrollRegion()
    }

    @discardableResult
    private func trimScrollbackRowsToLimit() -> Bool {
        interpreter.trimScrollbackRowsToLimit()
    }
}
