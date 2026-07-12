import Foundation

@MainActor
final class TmuxControlModeDriver {
    private enum RequestKind: Equatable {
        case listWindows
        case listWindowOrder
        case listPanes
        case registerSubscriptions
        case snapshotPreflight(String)
        case snapshotSuspend(String)
        case snapshotCurrentScreen(String)
        case snapshotAlternateScreen(String)
        case snapshotState(String)
        case snapshotPendingOutput(String)
        case snapshotResume(String)
        case recoveryResume(String)
        case mutation

        var snapshotPaneID: String? {
            switch self {
            case let .snapshotPreflight(paneID), let .snapshotSuspend(paneID),
                 let .snapshotCurrentScreen(paneID),
                 let .snapshotAlternateScreen(paneID), let .snapshotState(paneID),
                 let .snapshotPendingOutput(paneID), let .snapshotResume(paneID):
                paneID
            case .listWindows, .listWindowOrder, .listPanes, .registerSubscriptions,
                 .recoveryResume, .mutation:
                nil
            }
        }
    }

    private struct PaneSnapshotAssembly {
        var currentScreen = Data()
        var alternateScreen = Data()
        var terminalState: TmuxPaneTerminalState?
        var pendingOutput = Data()
        var outputBufferedBeforeCurrentCapture = Data()
        var currentCaptureBegan = false
        var stateCaptured = false
        var outputObservedBeforeState = false
        var consistencyRetryCount = 0
        var requestedSuspension = false
        var suspendSucceeded = false
        var resumeRetryCount = 0
        var requiredStageFailed = false
    }

    private struct QueuedRequest {
        let kind: RequestKind
        let command: Data

        var commandDescription: String {
            String(decoding: command, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
    }

    private struct ResponseBlockID: Equatable {
        let timestamp: UInt64
        let number: UInt64
        let flags: UInt64
    }

    private struct ActiveRequest {
        let request: QueuedRequest
        var blockID: ResponseBlockID?
        var responseLines: [String] = []
        var responseByteCount = 0
        var responseFailure: String?
    }

    var onStateChange: ((TmuxViewerState) -> Void)?
    var onPaneOutput: ((String, Data) -> Void)?
    var onError: ((String) -> Void)?
    var onExit: (() -> Void)?
    var onExitWithReason: ((String?) -> Void)?

    private var parser = TmuxControlParser()
    private var viewer = TmuxViewerState()
    private var pendingRequests: [QueuedRequest] = []
    private var mutationQueue: TmuxMutationQueue
    private var activeRequest: ActiveRequest?
    private var activeRequestGeneration: UInt64?
    private var discardActiveResponseForSessionTransition = false
    private var nextRequestGeneration: UInt64 = 0
    private var requestTimeoutTask: Task<Void, Never>?
    private var fatalAbortTask: Task<Void, Never>?
    private var fatalWaitExitTask: Task<Void, Never>?
    private var windowOrderDebounceTask: Task<Void, Never>?
    private var fatalRecoveryReason: String?
    private var hasFinishedExit = false
    private var didObserveExternalExit = false
    private var subscriptionsRegistered = false
    private var subscriptionRegistrationRetryCount = 0
    private var windowOrderRefreshDirty = false
    private var consecutiveSnapshotRequestCount = 0
    private var hasCompletedInitialCapture = false
    private var initialSnapshotRetryCount = 0
    private var readyPaneIDs = Set<String>()
    private var snapshotPaneIDs = Set<String>()
    private var snapshotAssemblies: [String: PaneSnapshotAssembly] = [:]
    private var bufferedLiveOutput: [String: TmuxBoundedOutputHistory] = [:]
    private var suspendedPaneIDs = Set<String>()
    private var suspensionLeaseTasks: [String: Task<Void, Never>] = [:]
    private let maximumSnapshotConsistencyRetries = 2
    private let responseByteLimit: Int
    private let responseLineLimit: Int
    private let requestTimeoutNanoseconds: UInt64
    private let suspensionLeaseNanoseconds: UInt64
    private let fatalAbortDelayNanoseconds: UInt64
    private let fatalWaitExitDelayNanoseconds: UInt64
    private let windowOrderDebounceNanoseconds: UInt64
    private let write: (String) -> Void

    init(
        responseByteLimit: Int = 4 * 1024 * 1024,
        responseLineLimit: Int = 16_384,
        requestTimeout: TimeInterval = 5,
        snapshotSuspensionTimeout: TimeInterval = 2,
        fatalAbortDelay: TimeInterval = 0.25,
        fatalWaitExitDelay: TimeInterval = 1,
        windowOrderDebounce: TimeInterval = 0.12,
        mutationQueueLimits: TmuxMutationQueue.Limits = .default,
        write: @escaping (String) -> Void
    ) {
        mutationQueue = .init(limits: mutationQueueLimits)
        self.responseByteLimit = max(0, responseByteLimit)
        self.responseLineLimit = max(1, responseLineLimit)
        let timeoutSeconds = max(0.001, requestTimeout)
        requestTimeoutNanoseconds = UInt64(min(timeoutSeconds * 1_000_000_000, Double(UInt64.max)))
        let suspensionSeconds = max(0.001, snapshotSuspensionTimeout)
        suspensionLeaseNanoseconds = UInt64(
            min(suspensionSeconds * 1_000_000_000, Double(UInt64.max))
        )
        fatalAbortDelayNanoseconds = Self.nanoseconds(fatalAbortDelay)
        fatalWaitExitDelayNanoseconds = Self.nanoseconds(fatalWaitExitDelay)
        windowOrderDebounceNanoseconds = Self.nanoseconds(windowOrderDebounce)
        self.write = write
    }

    var isActive: Bool { parser.isInControlMode }
    var state: TmuxViewerState { viewer }

    @discardableResult
    func consume(_ text: String) -> String {
        let events = parser.consume(Data(text.utf8))
        let passthrough = parser.takePassthroughData()
        for event in events { handle(event) }
        return String(decoding: passthrough, as: UTF8.self)
    }

    func sendKeys(to paneID: String, text: String) {
        enqueueMutation { try $0.enqueueInput(paneID: paneID, data: Data(text.utf8)) }
    }

    func selectPane(_ paneID: String) {
        enqueueStructuralMutation(TmuxCommandEncoder.selectPane(paneID))
    }

    func selectWindow(_ windowID: String) {
        enqueueStructuralMutation(TmuxCommandEncoder.selectWindow(windowID))
    }

    func splitPane(
        _ paneID: String,
        direction: TmuxSplitDirection,
        before: Bool = false,
        synchronizedClientSize: (windowID: String, columns: Int, rows: Int)? = nil
    ) {
        if let synchronizedClientSize {
            enqueueStructuralMutation(TmuxCommandEncoder.resizeClient(
                windowID: synchronizedClientSize.windowID,
                columns: synchronizedClientSize.columns,
                rows: synchronizedClientSize.rows
            ))
        }
        enqueueStructuralMutation(TmuxCommandEncoder.splitPane(
            targetPaneID: paneID,
            direction: direction,
            before: before
        ))
    }

    func killPane(_ paneID: String) {
        enqueueStructuralMutation(TmuxCommandEncoder.killPane(paneID))
    }

    func killWindow(_ windowID: String) {
        enqueueStructuralMutation(TmuxCommandEncoder.killWindow(windowID))
    }

    func resizePane(_ paneID: String, columns: Int, rows: Int) {
        enqueueMutation { try $0.enqueuePaneResize(paneID: paneID, columns: columns, rows: rows) }
    }

    func resizeClient(windowID: String? = nil, columns: Int, rows: Int) {
        enqueueMutation {
            try $0.enqueueClientResize(windowID: windowID, columns: columns, rows: rows)
        }
    }

    func rotateWindow(_ windowID: String, direction: TmuxRotationDirection) {
        enqueueStructuralMutation(TmuxCommandEncoder.rotateWindow(windowID, direction: direction))
    }

    func swapPane(_ paneID: String, direction: TmuxPaneSwapDirection) {
        enqueueStructuralMutation(TmuxCommandEncoder.swapPane(paneID, direction: direction))
    }

    func toggleZoom(_ paneID: String) {
        enqueueStructuralMutation(TmuxCommandEncoder.toggleZoom(paneID))
    }

    func selectLayout(_ selection: TmuxLayoutSelection, targetPaneID: String) {
        enqueueStructuralMutation(TmuxCommandEncoder.selectLayout(selection, targetPaneID: targetPaneID))
    }

    func newWindow() {
        enqueueStructuralMutation(TmuxCommandEncoder.newWindow(sessionID: viewer.sessionID))
    }

    func detachClient() {
        guard acceptsMutations else { return }
        if let kind = activeRequest?.request.kind,
           case .snapshotSuspend = kind {
            conservativelyTrackPotentialSuspension(kind)
        }
        pendingRequests.removeAll(keepingCapacity: true)
        for paneID in suspendedPaneIDs.sorted() {
            enqueueRecoveryResume(for: paneID)
        }
        mutationQueue.enqueueDetach()
        sendNextRequestIfNeeded()
    }

    func transportDidExit(status: Int32) {
        guard viewer.isAttached || parser.isInControlMode || fatalRecoveryReason != nil else { return }
        didObserveExternalExit = true
        cancelFatalRecoveryTasks()
        let reason = fatalRecoveryReason ?? "tmux transport exited with status \(status)"
        finishExit(reason: reason, observedExternalExit: true)
    }

    func refresh() {
        guard let sessionID = viewer.sessionID else { return }
        enqueueSnapshot(.listWindows, command: TmuxCommandEncoder.listWindows(sessionID: sessionID))
    }

    private func handle(_ event: TmuxControlEvent) {
        switch event {
        case .entered:
            let interruptedRequestKind = activeRequest?.request.kind
            cancelRequestTimeout()
            cancelFatalRecoveryTasks()
            cancelWindowOrderRefresh()
            fatalRecoveryReason = nil
            hasFinishedExit = false
            didObserveExternalExit = false
            subscriptionsRegistered = false
            subscriptionRegistrationRetryCount = 0
            mutationQueue.reset()
            consecutiveSnapshotRequestCount = 0
            pendingRequests.removeAll(keepingCapacity: true)
            activeRequest = nil
            discardActiveResponseForSessionTransition = false
            if let interruptedRequestKind {
                conservativelyTrackPotentialSuspension(interruptedRequestKind)
            }
            if !suspendedPaneIDs.isEmpty {
                viewer.apply(event)
                beginFatalDetachRecovery(
                    reason: "tmux control mode re-entered while pane output was suspended"
                )
                return
            }
            resetInitialCaptureState()
            viewer.apply(event)
        case let .sessionChanged(id, _):
            let previousSessionID = viewer.sessionID
            if previousSessionID != nil, previousSessionID != id {
                mutationQueue.reset()
                cancelWindowOrderRefresh()
                subscriptionsRegistered = false
                subscriptionRegistrationRetryCount = 0
                pendingRequests.removeAll(keepingCapacity: true)
                discardActiveResponseForSessionTransition = activeRequest != nil
                resetInitialCaptureState(preservingSuspendedPanes: true)
                viewer.apply(event)
                enqueueSessionTransitionRecovery(to: id)
                onStateChange?(viewer)
                return
            }
            viewer.apply(event)
            onStateChange?(viewer)
            if previousSessionID != id || viewer.windowOrder.isEmpty { refresh() }
        case .sessionRenamed:
            viewer.apply(event)
            onStateChange?(viewer)
        case .sessionsChanged:
            viewer.apply(event)
            refresh()
        case .clientSessionChanged:
            viewer.apply(event)
        case let .output(paneID, data):
            // Pane topology is authoritative. Dropping output for an unknown or
            // closed ID prevents a late notification from recreating an orphan;
            // a pane discovered later receives its contents through capture-pane.
            guard viewer.panes[paneID] != nil else {
                readyPaneIDs.remove(paneID)
                bufferedLiveOutput[paneID] = nil
                return
            }
            if var assembly = snapshotAssemblies[paneID],
               assembly.currentCaptureBegan,
               !assembly.stateCaptured {
                assembly.outputObservedBeforeState = true
                snapshotAssemblies[paneID] = assembly
            }
            if !readyPaneIDs.contains(paneID) {
                if bufferedLiveOutput[paneID] == nil {
                    bufferedLiveOutput[paneID] = .init(byteLimit: TmuxPaneState.defaultOutputHistoryByteLimit)
                }
                bufferedLiveOutput[paneID]?.append(data)
            } else {
                applyPaneOutput(paneID: paneID, data: data)
            }
        case let .blockBegan(timestamp, number, flags):
            beginResponseBlock(.init(timestamp: timestamp, number: number, flags: flags))
        case let .responseLine(line):
            appendResponseLine(line)
        case let .blockEnded(timestamp, number, flags):
            finishResponseBlock(
                .init(timestamp: timestamp, number: number, flags: flags),
                succeeded: true
            )
        case let .blockFailed(timestamp, number, flags):
            finishResponseBlock(
                .init(timestamp: timestamp, number: number, flags: flags),
                succeeded: false
            )
        case .windowAdded, .windowClosed:
            viewer.apply(event)
            synchronizeTrackedPanesWithTopology()
            scheduleSnapshotsForNewPanes()
            refresh()
            onStateChange?(viewer)
        case .windowRenamed, .windowOrderChanged, .layoutChanged,
             .activeWindowChanged, .activePaneChanged, .paneFocused, .paneFocusChanged:
            viewer.apply(event)
            synchronizeTrackedPanesWithTopology()
            scheduleSnapshotsForNewPanes()
            onStateChange?(viewer)
        case let .subscriptionChanged(name, sessionID, _, _, paneID, value):
            handleSubscriptionChanged(
                name: name,
                sessionID: sessionID,
                paneID: paneID,
                value: value
            )
        case .paneTitleChanged:
            viewer.apply(event)
            onStateChange?(viewer)
        case let .configurationError(message):
            viewer.apply(event)
            reportError(message)
            onStateChange?(viewer)
        case let .exited(reason):
            didObserveExternalExit = true
            finishExit(reason: fatalRecoveryReason ?? reason, observedExternalExit: true)
        case let .locallyAborted(reason):
            let message = "tmux control parser stopped locally: \(reason)"
            if fatalRecoveryReason == nil {
                reportError(message)
                onStateChange?(viewer)
            }
            beginFatalDetachRecovery(reason: message)
        case .notification:
            viewer.apply(event)
        case let .malformed(line):
            viewer.apply(event)
            let message = "Malformed tmux control message: \(line)"
            reportError(message)
            onStateChange?(viewer)
            beginFatalDetachRecovery(reason: message)
        }
    }

    private func beginResponseBlock(_ blockID: ResponseBlockID) {
        guard var activeRequest else { return }
        guard activeRequest.blockID == nil else {
            failActiveRequest("tmux began a second response block before ending the first")
            return
        }
        activeRequest.blockID = blockID
        activeRequest.responseLines.removeAll(keepingCapacity: true)
        self.activeRequest = activeRequest
        if case let .snapshotCurrentScreen(paneID) = activeRequest.request.kind {
            // The current-screen capture is the checkpoint cutover. Output
            // received before this command begins is represented by the screen
            // dump and must not be replayed a second time.
            var assembly = snapshotAssemblies[paneID] ?? .init()
            assembly.outputBufferedBeforeCurrentCapture = bufferedLiveOutput[paneID]?.data ?? Data()
            assembly.currentCaptureBegan = true
            assembly.stateCaptured = false
            assembly.outputObservedBeforeState = false
            bufferedLiveOutput[paneID]?.removeAll()
            snapshotAssemblies[paneID] = assembly
        }
    }

    private func appendResponseLine(_ line: String) {
        guard var activeRequest, activeRequest.blockID != nil else { return }
        guard activeRequest.responseFailure == nil else { return }
        let lineByteCount = line.utf8.count + 1
        let exceedsByteLimit = lineByteCount > responseByteLimit - min(responseByteLimit, activeRequest.responseByteCount)
        if exceedsByteLimit || activeRequest.responseLines.count >= responseLineLimit {
            activeRequest.responseLines.removeAll(keepingCapacity: false)
            activeRequest.responseByteCount = 0
            activeRequest.responseFailure = "tmux response exceeded the bounded payload limit"
        } else {
            activeRequest.responseLines.append(line)
            activeRequest.responseByteCount += lineByteCount
        }
        self.activeRequest = activeRequest
    }

    private func finishResponseBlock(_ blockID: ResponseBlockID, succeeded: Bool) {
        guard let activeRequest else { return }
        guard let expectedBlockID = activeRequest.blockID else {
            failActiveRequest("tmux ended a response block before %begin")
            return
        }
        guard expectedBlockID == blockID else {
            failActiveRequest(
                "tmux response block mismatch: expected command \(expectedBlockID.number), got \(blockID.number)"
            )
            return
        }
        completeActiveRequest(succeeded: succeeded)
    }

    private var acceptsMutations: Bool {
        parser.isInControlMode && viewer.isAttached && fatalRecoveryReason == nil && !hasFinishedExit
    }

    private func enqueueStructuralMutation(_ command: Data) {
        enqueueMutation { try $0.enqueueStructural(command: command) }
    }

    private func enqueueMutation(
        _ operation: (inout TmuxMutationQueue) throws -> Void
    ) {
        guard acceptsMutations else { return }
        do {
            try operation(&mutationQueue)
        } catch TmuxMutationQueue.EnqueueError.detaching {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "tmux mutation backlog could not be queued"
            reportError(message)
            onStateChange?(viewer)
            beginFatalDetachRecovery(reason: message)
            return
        }
        sendNextRequestIfNeeded()
    }

    private func enqueueSessionTransitionRecovery(to sessionID: String) {
        for paneID in suspendedPaneIDs.sorted() {
            enqueueRecoveryResume(for: paneID)
        }
        pendingRequests.append(.init(
            kind: .listWindows,
            command: TmuxCommandEncoder.listWindows(sessionID: sessionID)
        ))
        sendNextRequestIfNeeded()
    }

    private func enqueueRecoveryResume(for paneID: String, atFront: Bool = false) {
        let kind = RequestKind.recoveryResume(paneID)
        guard activeRequest?.request.kind != kind,
              !pendingRequests.contains(where: { $0.kind == kind })
        else { return }
        let request = QueuedRequest(
            kind: kind,
            command: TmuxCommandEncoder.resumePaneOutput(paneID)
        )
        if atFront {
            pendingRequests.insert(request, at: 0)
        } else {
            pendingRequests.append(request)
        }
    }

    private func potentialSuspendedPaneID(for kind: RequestKind) -> String? {
        switch kind {
        case let .snapshotSuspend(paneID), let .recoveryResume(paneID):
            paneID
        default:
            nil
        }
    }

    private func conservativelyTrackPotentialSuspension(_ kind: RequestKind) {
        guard let paneID = potentialSuspendedPaneID(for: kind) else { return }
        suspendedPaneIDs.insert(paneID)
        scheduleSuspensionLease(for: paneID)
    }

    private func conservativelyRecoverDiscardedRequest(_ kind: RequestKind) {
        guard let paneID = potentialSuspendedPaneID(for: kind) else { return }
        conservativelyTrackPotentialSuspension(kind)
        enqueueRecoveryResume(for: paneID, atFront: true)
    }

    private func enqueueSnapshot(_ kind: RequestKind, command: Data, atFront: Bool = false) {
        guard kind == .listWindows || kind == .listPanes else { return }
        let isAlreadyQueued = activeRequest?.request.kind == kind || pendingRequests.contains { $0.kind == kind }
        guard !isAlreadyQueued else { return }
        enqueue(.init(kind: kind, command: command), atFront: atFront)
    }

    private func enqueue(_ request: QueuedRequest, atFront: Bool = false) {
        guard acceptsMutations else { return }
        if atFront {
            pendingRequests.insert(request, at: 0)
        } else {
            pendingRequests.append(request)
        }
        sendNextRequestIfNeeded()
    }

    private func sendNextRequestIfNeeded() {
        guard fatalRecoveryReason == nil, activeRequest == nil, let request = popNextRequest() else {
            return
        }
        activeRequest = .init(request: request)
        nextRequestGeneration &+= 1
        activeRequestGeneration = nextRequestGeneration
        scheduleRequestTimeout(generation: nextRequestGeneration)
        write(String(decoding: request.command, as: UTF8.self))
    }

    private func popNextRequest() -> QueuedRequest? {
        if let recoveryIndex = pendingRequests.firstIndex(where: {
            if case .recoveryResume = $0.kind { return true }
            return false
        }) {
            consecutiveSnapshotRequestCount += 1
            return pendingRequests.remove(at: recoveryIndex)
        }

        if !suspendedPaneIDs.isEmpty, !pendingRequests.isEmpty {
            consecutiveSnapshotRequestCount += 1
            return pendingRequests.removeFirst()
        }

        if mutationQueue.isDetaching,
           let mutation = mutationQueue.popFirst() {
            pendingRequests.removeAll(keepingCapacity: true)
            cancelWindowOrderRefresh()
            consecutiveSnapshotRequestCount = 0
            return queuedRequest(for: mutation)
        }

        if !pendingRequests.isEmpty,
           mutationQueue.isEmpty || consecutiveSnapshotRequestCount < 8 {
            consecutiveSnapshotRequestCount += 1
            return pendingRequests.removeFirst()
        }

        if let mutation = mutationQueue.popFirst() {
            consecutiveSnapshotRequestCount = 0
            return queuedRequest(for: mutation)
        }

        guard !pendingRequests.isEmpty else { return nil }
        consecutiveSnapshotRequestCount += 1
        return pendingRequests.removeFirst()
    }

    private func queuedRequest(for mutation: TmuxMutationQueue.Mutation) -> QueuedRequest {
        let command: Data
        switch mutation {
        case let .sendKeys(paneID, data):
            command = TmuxCommandEncoder.sendKeys(paneID: paneID, data: data)
        case let .structural(structuralCommand):
            command = structuralCommand
        case let .resizePane(paneID, columns, rows):
            command = TmuxCommandEncoder.resizePane(paneID, columns: columns, rows: rows)
        case let .resizeClient(windowID, columns, rows):
            command = TmuxCommandEncoder.resizeClient(
                windowID: windowID,
                columns: columns,
                rows: rows
            )
        case .detachClient:
            command = TmuxCommandEncoder.detachClient()
        }
        return .init(kind: .mutation, command: command)
    }

    private func scheduleRequestTimeout(generation: UInt64) {
        requestTimeoutTask?.cancel()
        let delay = requestTimeoutNanoseconds
        requestTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            self?.requestTimedOut(generation: generation)
        }
    }

    private func cancelRequestTimeout() {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        activeRequestGeneration = nil
    }

    private func requestTimedOut(generation: UInt64) {
        guard activeRequestGeneration == generation, let timedOut = activeRequest else { return }
        let message = "tmux command timed out: \(timedOut.request.commandDescription)"
        cancelRequestTimeout()
        activeRequest = nil
        if discardActiveResponseForSessionTransition {
            discardActiveResponseForSessionTransition = false
            conservativelyTrackPotentialSuspension(timedOut.request.kind)
        }
        pendingRequests.removeAll(keepingCapacity: true)
        handleFailedRequest(timedOut, message: message, recoverInitialSnapshot: false)
        flushBufferedLiveOutput()
        onStateChange?(viewer)
        beginFatalDetachRecovery(reason: message)
    }

    private func beginFatalDetachRecovery(reason: String) {
        guard fatalRecoveryReason == nil, !hasFinishedExit else { return }
        cancelRequestTimeout()
        cancelWindowOrderRefresh()
        activeRequest = nil
        pendingRequests.removeAll(keepingCapacity: true)
        mutationQueue.reset()
        discardActiveResponseForSessionTransition = false
        fatalRecoveryReason = reason
        parser.abandonOpenResponseBlock()
        resumeSuspendedPanesWithoutWaiting()
        write(String(decoding: TmuxCommandEncoder.detachClient(), as: UTF8.self))
        scheduleFatalRecoveryFallbacks(reason: reason)
    }

    private func scheduleFatalRecoveryFallbacks(reason: String) {
        cancelFatalRecoveryTasks()
        let (combinedAbortDelay, overflow) = fatalWaitExitDelayNanoseconds
            .addingReportingOverflow(fatalAbortDelayNanoseconds)
        let abortDelay = overflow ? UInt64.max : combinedAbortDelay
        fatalAbortTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: abortDelay)
            } catch {
                return
            }
            guard let self, !self.hasFinishedExit else { return }
            if self.fatalWaitExitTask != nil, !self.didObserveExternalExit {
                self.fatalWaitExitTask?.cancel()
                self.fatalWaitExitTask = nil
                self.write("\n")
            }
            self.finishExit(reason: reason, observedExternalExit: false)
        }

        let waitExitDelay = fatalWaitExitDelayNanoseconds
        fatalWaitExitTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: waitExitDelay)
            } catch {
                return
            }
            guard let self, !self.didObserveExternalExit else { return }
            self.write("\n")
            self.fatalWaitExitTask = nil
        }
    }

    private func finishExit(reason: String?, observedExternalExit: Bool) {
        if observedExternalExit { didObserveExternalExit = true }
        cancelFatalRecoveryTasks()
        guard !hasFinishedExit else { return }
        hasFinishedExit = true
        parser.abortControlMode()
        viewer.apply(.exited(reason: reason))
        cancelRequestTimeout()
        cancelWindowOrderRefresh()
        mutationQueue.reset()
        pendingRequests.removeAll(keepingCapacity: true)
        activeRequest = nil
        discardActiveResponseForSessionTransition = false
        flushBufferedLiveOutput()
        resetInitialCaptureState()
        subscriptionsRegistered = false
        onStateChange?(viewer)
        onExitWithReason?(reason)
        onExit?()
        if observedExternalExit {
            fatalRecoveryReason = nil
        }
    }

    private func cancelFatalRecoveryTasks() {
        fatalAbortTask?.cancel()
        fatalAbortTask = nil
        fatalWaitExitTask?.cancel()
        fatalWaitExitTask = nil
    }

    private func completeActiveRequest(succeeded: Bool) {
        guard let completed = activeRequest else { return }
        cancelRequestTimeout()
        activeRequest = nil

        if discardActiveResponseForSessionTransition {
            discardActiveResponseForSessionTransition = false
            conservativelyRecoverDiscardedRequest(completed.request.kind)
            sendNextRequestIfNeeded()
            return
        }

        if succeeded, completed.responseFailure == nil {
            switch completed.request.kind {
            case .listWindows:
                if applyWindowList(completed.responseLines), let sessionID = viewer.sessionID {
                    enqueueSnapshot(
                        .listPanes,
                        command: TmuxCommandEncoder.listPanes(sessionID: sessionID),
                        atFront: true
                    )
                } else {
                    recoverInitialSnapshotAfterFailure(failedKind: .listWindows)
                    onStateChange?(viewer)
                }
            case .listWindowOrder:
                applyWindowOrderRefresh(completed.responseLines)
            case .listPanes:
                if let paneIDs = applyPaneList(completed.responseLines) {
                    if hasCompletedInitialCapture {
                        viewer.pruneOrphanedPanes()
                        synchronizeTrackedPanesWithTopology()
                        schedulePaneSnapshots(paneIDs)
                    } else {
                        beginInitialCapture(paneIDs: paneIDs)
                    }
                    onStateChange?(viewer)
                } else {
                    recoverInitialSnapshotAfterFailure(failedKind: .listPanes)
                    onStateChange?(viewer)
                }
            case .registerSubscriptions:
                subscriptionsRegistered = true
                subscriptionRegistrationRetryCount = 0
            case .snapshotPreflight, .snapshotSuspend, .snapshotCurrentScreen, .snapshotAlternateScreen,
                 .snapshotState, .snapshotPendingOutput, .snapshotResume:
                applySnapshotResponse(
                    completed.responseLines,
                    for: completed.request.kind,
                    succeeded: true
                )
            case let .recoveryResume(paneID):
                suspendedPaneIDs.remove(paneID)
                cancelSuspensionLease(for: paneID)
            case .mutation:
                break
            }
        } else {
            let message = completed.responseFailure ?? (completed.responseLines.isEmpty
                ? "tmux command failed: \(completed.request.commandDescription)"
                : completed.responseLines.joined(separator: "\n"))
            handleFailedRequest(completed, message: message, recoverInitialSnapshot: true)
            onStateChange?(viewer)
        }
        if completed.request.kind == .listWindowOrder || completed.request.kind == .listWindows {
            completeWindowOrderRefreshCycle()
        }
        sendNextRequestIfNeeded()
    }

    private func failActiveRequest(_ message: String) {
        guard let failed = activeRequest else {
            reportError(message)
            return
        }
        cancelRequestTimeout()
        activeRequest = nil
        if discardActiveResponseForSessionTransition {
            discardActiveResponseForSessionTransition = false
            conservativelyRecoverDiscardedRequest(failed.request.kind)
            sendNextRequestIfNeeded()
            return
        }
        handleFailedRequest(failed, message: message, recoverInitialSnapshot: true)
        onStateChange?(viewer)
        if failed.request.kind == .listWindowOrder || failed.request.kind == .listWindows {
            completeWindowOrderRefreshCycle()
        }
        sendNextRequestIfNeeded()
    }

    private func handleFailedRequest(
        _ failed: ActiveRequest,
        message: String,
        recoverInitialSnapshot: Bool
    ) {
        reportError(message)
        switch failed.request.kind {
        case .snapshotPreflight, .snapshotSuspend, .snapshotCurrentScreen, .snapshotAlternateScreen,
             .snapshotState, .snapshotPendingOutput, .snapshotResume:
            applySnapshotResponse([], for: failed.request.kind, succeeded: false)
        case .listWindows, .listPanes:
            guard !hasCompletedInitialCapture else { break }
            if recoverInitialSnapshot {
                recoverInitialSnapshotAfterFailure(failedKind: failed.request.kind)
            } else {
                finishInitialCapture()
            }
        case .listWindowOrder:
            enqueueFullRefreshForOrderMismatch()
        case .registerSubscriptions:
            guard subscriptionRegistrationRetryCount < 1 else {
                beginFatalDetachRecovery(reason: "tmux state subscription registration failed")
                return
            }
            subscriptionRegistrationRetryCount += 1
            enqueue(.init(
                kind: .registerSubscriptions,
                command: TmuxCommandEncoder.registerStateSubscriptions()
            ), atFront: true)
        case let .recoveryResume(paneID):
            let recoveryMessage = "tmux pane output could not be resumed during session transition: \(paneID)"
            beginFatalDetachRecovery(reason: recoveryMessage)
        case .mutation:
            break
        }
    }

    private func handleSubscriptionChanged(
        name: String,
        sessionID: String,
        paneID: String,
        value: String
    ) {
        guard subscriptionsRegistered, sessionID == viewer.sessionID else { return }
        switch name {
        case "kurotty-window-index":
            scheduleWindowOrderRefresh()
        case "kurotty-pane-title":
            guard viewer.panes[paneID] != nil else { return }
            viewer.apply(.paneTitleChanged(
                sessionID: sessionID,
                paneID: paneID,
                title: value
            ))
            onStateChange?(viewer)
        default:
            break
        }
    }

    private func scheduleWindowOrderRefresh() {
        guard subscriptionsRegistered, viewer.sessionID != nil, !hasFinishedExit else { return }
        if hasActiveWindowRefresh {
            windowOrderRefreshDirty = true
            return
        }
        if hasPendingWindowRefresh { return }
        guard windowOrderDebounceTask == nil else { return }
        let delay = windowOrderDebounceNanoseconds
        windowOrderDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.windowOrderDebounceTask = nil
            self.beginWindowOrderRefresh()
        }
    }

    private var hasActiveWindowRefresh: Bool {
        switch activeRequest?.request.kind {
        case .listWindows, .listWindowOrder:
            return true
        default:
            return false
        }
    }

    private var hasPendingWindowRefresh: Bool {
        pendingRequests.contains {
            $0.kind == .listWindows || $0.kind == .listWindowOrder
        }
    }

    private func beginWindowOrderRefresh() {
        guard let sessionID = viewer.sessionID, subscriptionsRegistered, !hasFinishedExit else {
            return
        }
        if hasActiveWindowRefresh {
            windowOrderRefreshDirty = true
            return
        }
        if hasPendingWindowRefresh { return }
        enqueue(.init(
            kind: .listWindowOrder,
            command: TmuxCommandEncoder.listWindowOrder(sessionID: sessionID)
        ))
    }

    private func applyWindowOrderRefresh(_ lines: [String]) {
        let ids = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            enqueueFullRefreshForOrderMismatch()
            return
        }
        guard Set(ids) == Set(viewer.windows.keys) else {
            enqueueFullRefreshForOrderMismatch()
            return
        }
        viewer.apply(.windowOrderChanged(ids: ids))
        onStateChange?(viewer)
    }

    private func enqueueFullRefreshForOrderMismatch() {
        guard let sessionID = viewer.sessionID else { return }
        enqueueSnapshot(
            .listWindows,
            command: TmuxCommandEncoder.listWindows(sessionID: sessionID),
            atFront: true
        )
    }

    private func completeWindowOrderRefreshCycle() {
        guard windowOrderRefreshDirty else { return }
        windowOrderRefreshDirty = false
        scheduleWindowOrderRefresh()
    }

    private func cancelWindowOrderRefresh() {
        windowOrderDebounceTask?.cancel()
        windowOrderDebounceTask = nil
        windowOrderRefreshDirty = false
    }

    @discardableResult
    private func applyWindowList(_ lines: [String]) -> Bool {
        var parsed: [(id: String, name: String, layout: TmuxLayoutNode, visibleLayout: TmuxLayoutNode, flags: String, isActive: Bool)] = []
        for line in lines {
            let fields = line.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6,
                  let layout = try? TmuxLayoutParser.parse(fields[1]),
                  let visibleLayout = try? TmuxLayoutParser.parse(fields[2])
            else {
                reportError("Malformed tmux window snapshot: \(line)")
                return false
            }
            parsed.append((fields[0], fields[5], layout, visibleLayout, fields[3], fields[4] == "1"))
        }

        let observedWindowIDs = parsed.map(\.id)
        for window in parsed {
            viewer.apply(.windowAdded(id: window.id))
            viewer.apply(.windowRenamed(id: window.id, name: window.name))
            viewer.apply(.layoutChanged(
                windowID: window.id,
                layout: window.layout,
                visibleLayout: window.visibleLayout,
                flags: window.flags
            ))
            if window.isActive, let sessionID = viewer.sessionID {
                viewer.apply(.activeWindowChanged(sessionID: sessionID, windowID: window.id))
            }
        }
        for windowID in viewer.windowOrder where !observedWindowIDs.contains(windowID) {
            viewer.apply(.windowClosed(id: windowID))
        }
        viewer.apply(.windowOrderChanged(ids: observedWindowIDs))
        return true
    }

    @discardableResult
    private func applyPaneList(_ lines: [String]) -> [String]? {
        var paneIDs: [String] = []
        for line in lines {
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else {
                reportError("Malformed tmux pane snapshot: \(line)")
                return nil
            }
            paneIDs.append(fields[1])
            if fields.count == 4, let sessionID = viewer.sessionID {
                viewer.apply(.paneTitleChanged(
                    sessionID: sessionID,
                    paneID: fields[1],
                    title: fields[3]
                ))
            }
            if fields[2] == "1" {
                viewer.apply(.activePaneChanged(windowID: fields[0], paneID: fields[1]))
            }
        }
        return paneIDs
    }

    private func beginInitialCapture(paneIDs: [String]) {
        let orderedPaneIDs = paneIDs.reduce(into: [String]()) { result, paneID in
            if !result.contains(paneID) { result.append(paneID) }
        }
        readyPaneIDs.removeAll(keepingCapacity: true)
        guard !orderedPaneIDs.isEmpty else {
            finishInitialCapture()
            return
        }
        schedulePaneSnapshots(orderedPaneIDs, atFront: true)
    }

    private func scheduleSnapshotsForNewPanes() {
        guard viewer.sessionID != nil else { return }
        schedulePaneSnapshots(viewer.panes.keys.sorted())
    }

    private func schedulePaneSnapshots<S: Sequence>(_ paneIDs: S, atFront: Bool = false)
    where S.Element == String {
        var requests: [QueuedRequest] = []
        for paneID in paneIDs where !readyPaneIDs.contains(paneID) && !snapshotPaneIDs.contains(paneID) {
            snapshotPaneIDs.insert(paneID)
            snapshotAssemblies[paneID] = .init()
            requests.append(.init(
                kind: .snapshotPreflight(paneID),
                command: TmuxCommandEncoder.attachedClientCount(paneID)
            ))
        }
        guard !requests.isEmpty else { return }
        if atFront {
            pendingRequests.insert(contentsOf: requests, at: 0)
        } else {
            pendingRequests.append(contentsOf: requests)
        }
        sendNextRequestIfNeeded()
    }

    private func paneSnapshotRequests(_ paneID: String, suspendOutput: Bool) -> [QueuedRequest] {
        var requests: [QueuedRequest] = []
        if suspendOutput {
            requests.append(.init(
                kind: .snapshotSuspend(paneID),
                command: TmuxCommandEncoder.suspendPaneOutput(paneID)
            ))
        }
        requests.append(contentsOf: [
            .init(
                kind: .snapshotCurrentScreen(paneID),
                command: TmuxCommandEncoder.captureCurrentScreen(paneID)
            ),
            .init(
                kind: .snapshotAlternateScreen(paneID),
                command: TmuxCommandEncoder.captureAlternateScreen(paneID)
            ),
            .init(
                kind: .snapshotState(paneID),
                command: TmuxCommandEncoder.listPaneState(paneID)
            ),
            .init(
                kind: .snapshotPendingOutput(paneID),
                command: TmuxCommandEncoder.capturePendingOutput(paneID)
            ),
        ])
        if suspendOutput {
            requests.append(.init(
                kind: .snapshotResume(paneID),
                command: TmuxCommandEncoder.resumePaneOutput(paneID)
            ))
        }
        return requests
    }

    private func recoverInitialSnapshotAfterFailure(failedKind: RequestKind) {
        guard !hasCompletedInitialCapture else { return }
        guard initialSnapshotRetryCount < 1, let sessionID = viewer.sessionID else {
            let scope = failedKind == .listPanes ? "pane" : "window"
            beginFatalDetachRecovery(reason: "tmux \(scope) discovery failed")
            return
        }
        initialSnapshotRetryCount += 1
        enqueueSnapshot(
            .listWindows,
            command: TmuxCommandEncoder.listWindows(sessionID: sessionID),
            atFront: true
        )
    }

    private func applySnapshotResponse(
        _ responseLines: [String],
        for kind: RequestKind,
        succeeded: Bool
    ) {
        guard let paneID = kind.snapshotPaneID else { return }
        if case .snapshotSuspend = kind, succeeded {
            suspendedPaneIDs.insert(paneID)
            scheduleSuspensionLease(for: paneID)
        }
        guard snapshotPaneIDs.contains(paneID) else {
            abandonSnapshot(for: paneID)
            return
        }
        guard viewer.panes[paneID] != nil else {
            abandonSnapshot(for: paneID)
            return
        }
        var assembly = snapshotAssemblies[paneID] ?? .init()
        switch kind {
        case .snapshotPreflight:
            let attachedClientCount = succeeded
                ? responseLines.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                : nil
            if succeeded, attachedClientCount == nil {
                reportError("Malformed tmux attached-client count for \(paneID)")
            }
            // Unknown and multi-client states deliberately stay live. Only an
            // authoritative sole-client result permits `off`.
            assembly.requestedSuspension = attachedClientCount == 1
            snapshotAssemblies[paneID] = assembly
            pendingRequests.insert(
                contentsOf: paneSnapshotRequests(
                    paneID,
                    suspendOutput: assembly.requestedSuspension
                ),
                at: 0
            )
            return
        case .snapshotSuspend:
            assembly.suspendSucceeded = succeeded
        case .snapshotCurrentScreen:
            if succeeded {
                assembly.currentScreen = screenData(responseLines)
                assembly.outputBufferedBeforeCurrentCapture = Data()
            } else {
                assembly.requiredStageFailed = true
                var restored = TmuxBoundedOutputHistory(byteLimit: TmuxPaneState.defaultOutputHistoryByteLimit)
                restored.append(assembly.outputBufferedBeforeCurrentCapture)
                if let afterCutover = bufferedLiveOutput[paneID] { restored.append(afterCutover.data) }
                bufferedLiveOutput[paneID] = restored
                assembly.outputBufferedBeforeCurrentCapture = Data()
            }
        case .snapshotAlternateScreen:
            if succeeded {
                assembly.alternateScreen = screenData(responseLines)
            } else {
                assembly.requiredStageFailed = true
            }
        case .snapshotState:
            assembly.stateCaptured = true
            if succeeded {
                let response = responseLines.joined(separator: "\n")
                assembly.terminalState = TmuxPaneTerminalState.parse(response, expectedPaneID: paneID)
                if assembly.terminalState == nil {
                    assembly.requiredStageFailed = true
                    reportError("Malformed tmux pane state snapshot for \(paneID)")
                }
            } else {
                assembly.requiredStageFailed = true
            }
        case .snapshotPendingOutput:
            if succeeded {
                assembly.pendingOutput = TmuxPendingOutputDecoder.decode(
                    Data(responseLines.joined(separator: "\n").utf8)
                )
            } else {
                assembly.requiredStageFailed = true
            }
        case .snapshotResume:
            if succeeded {
                suspendedPaneIDs.remove(paneID)
                cancelSuspensionLease(for: paneID)
            } else if assembly.suspendSucceeded,
                      assembly.resumeRetryCount < 2 {
                assembly.resumeRetryCount += 1
                snapshotAssemblies[paneID] = assembly
                pendingRequests.insert(
                    .init(
                        kind: .snapshotResume(paneID),
                        command: TmuxCommandEncoder.resumePaneOutput(paneID)
                    ),
                    at: 0
                )
                return
            } else if assembly.suspendSucceeded {
                let message = "tmux pane output could not be resumed after snapshot: \(paneID)"
                reportError(message)
                beginFatalDetachRecovery(reason: message)
                return
            }
        case .listWindows, .listWindowOrder, .listPanes, .registerSubscriptions,
             .recoveryResume, .mutation:
            return
        }
        snapshotAssemblies[paneID] = assembly
        let completesSnapshot: Bool
        switch kind {
        case .snapshotResume:
            completesSnapshot = true
        case .snapshotPendingOutput:
            completesSnapshot = !assembly.requestedSuspension
        default:
            completesSnapshot = false
        }
        if completesSnapshot {
            finishPaneSnapshot(paneID)
        }
    }

    private func finishPaneSnapshot(_ paneID: String) {
        guard let assembly = snapshotAssemblies[paneID],
              let pane = viewer.panes[paneID]
        else {
            abandonSnapshot(for: paneID)
            return
        }
        if assembly.requiredStageFailed {
            guard assembly.consistencyRetryCount < maximumSnapshotConsistencyRetries else {
                failPaneSnapshot(
                    paneID,
                    message: "tmux pane snapshot failed after bounded retries: \(paneID)"
                )
                return
            }
            retryPaneSnapshot(
                paneID,
                retryCount: assembly.consistencyRetryCount + 1,
                suspendOutput: assembly.requestedSuspension && assembly.suspendSucceeded
            )
            return
        }

        // `off` freezes a pane only when this is the sole attached client. If
        // another tmux client can still drive the pane, take a second snapshot
        // with notifications enabled and use the normal output cutover check.
        if assembly.requestedSuspension,
           (!assembly.suspendSucceeded || assembly.terminalState?.attachedClientCount != 1) {
            guard assembly.consistencyRetryCount < maximumSnapshotConsistencyRetries else {
                failPaneSnapshot(
                    paneID,
                    message: "tmux pane snapshot could not establish a stable checkpoint: \(paneID)"
                )
                return
            }
            retryPaneSnapshot(
                paneID,
                retryCount: assembly.consistencyRetryCount + 1,
                suspendOutput: false
            )
            return
        }

        if assembly.outputObservedBeforeState,
           assembly.consistencyRetryCount < maximumSnapshotConsistencyRetries {
            retryPaneSnapshot(
                paneID,
                retryCount: assembly.consistencyRetryCount + 1,
                suspendOutput: assembly.requestedSuspension
            )
            return
        }
        if assembly.outputObservedBeforeState {
            failPaneSnapshot(
                paneID,
                message: "tmux pane snapshot remained active during bounded consistency retries: \(paneID)"
            )
            return
        }
        guard let state = assembly.terminalState else {
            failPaneSnapshot(paneID, message: "tmux pane snapshot had no terminal state: \(paneID)")
            return
        }
        let snapshot = TmuxPaneSnapshot(
            currentScreen: assembly.currentScreen,
            alternateScreen: assembly.alternateScreen,
            terminalState: state,
            pendingOutput: assembly.pendingOutput,
            byteLimit: pane.outputHistoryByteLimit
        )
        viewer.installSnapshot(snapshot, for: paneID)
        if let buffered = bufferedLiveOutput.removeValue(forKey: paneID) {
            viewer.apply(.output(paneID: paneID, data: buffered.data))
        }
        snapshotAssemblies[paneID] = nil
        snapshotPaneIDs.remove(paneID)
        readyPaneIDs.insert(paneID)

        if !hasCompletedInitialCapture, snapshotPaneIDs.isEmpty {
            finishInitialCapture()
        } else {
            onStateChange?(viewer)
        }
    }

    private func abandonSnapshot(for paneID: String) {
        let mustResume = suspendedPaneIDs.contains(paneID)
        snapshotAssemblies[paneID] = nil
        snapshotPaneIDs.remove(paneID)
        bufferedLiveOutput[paneID] = nil
        pendingRequests.removeAll { $0.kind.snapshotPaneID == paneID }
        if mustResume, parser.isInControlMode, viewer.isAttached {
            enqueueRecoveryResume(for: paneID, atFront: true)
            sendNextRequestIfNeeded()
        } else if mustResume {
            suspendedPaneIDs.remove(paneID)
            cancelSuspensionLease(for: paneID)
        }
        if !hasCompletedInitialCapture, snapshotPaneIDs.isEmpty {
            finishInitialCapture()
        }
    }

    private func retryPaneSnapshot(_ paneID: String, retryCount: Int, suspendOutput: Bool) {
        var nextAssembly = PaneSnapshotAssembly()
        nextAssembly.consistencyRetryCount = retryCount
        snapshotAssemblies[paneID] = nextAssembly
        if suspendOutput {
            pendingRequests.insert(
                .init(
                    kind: .snapshotPreflight(paneID),
                    command: TmuxCommandEncoder.attachedClientCount(paneID)
                ),
                at: 0
            )
        } else {
            pendingRequests.insert(
                contentsOf: paneSnapshotRequests(paneID, suspendOutput: false),
                at: 0
            )
        }
    }

    private func failPaneSnapshot(_ paneID: String, message: String) {
        reportError(message)
        beginFatalDetachRecovery(reason: message)
    }

    private func discardOrphanedSnapshotWork() {
        let livePaneIDs = Set(viewer.panes.keys)
        for paneID in Array(snapshotPaneIDs) where !livePaneIDs.contains(paneID) {
            if activeRequest?.request.kind.snapshotPaneID != paneID {
                abandonSnapshot(for: paneID)
            }
        }
    }

    private func synchronizeTrackedPanesWithTopology() {
        let livePaneIDs = Set(viewer.panes.keys)
        readyPaneIDs.formIntersection(livePaneIDs)
        bufferedLiveOutput = bufferedLiveOutput.filter { livePaneIDs.contains($0.key) }
        discardOrphanedSnapshotWork()
    }

    private func screenData(_ responseLines: [String]) -> Data {
        Data(responseLines.joined(separator: "\r\n").utf8)
    }

    private func finishInitialCapture() {
        let incompletePaneIDs = Set(viewer.panes.keys).subtracting(readyPaneIDs)
        guard incompletePaneIDs.isEmpty else {
            beginFatalDetachRecovery(
                reason: "tmux initial snapshot was incomplete: \(incompletePaneIDs.sorted().joined(separator: ", "))"
            )
            return
        }
        hasCompletedInitialCapture = true
        initialSnapshotRetryCount = 0
        viewer.pruneOrphanedPanes()
        synchronizeTrackedPanesWithTopology()
        onStateChange?(viewer)
        if !subscriptionsRegistered,
           !pendingRequests.contains(where: { $0.kind == .registerSubscriptions }) {
            enqueue(.init(
                kind: .registerSubscriptions,
                command: TmuxCommandEncoder.registerStateSubscriptions()
            ))
        }
    }

    private func flushBufferedLiveOutput() {
        for (paneID, output) in bufferedLiveOutput where viewer.panes[paneID] != nil {
            applyPaneOutput(paneID: paneID, data: output.data)
        }
        bufferedLiveOutput.removeAll(keepingCapacity: true)
    }

    private func resumeSuspendedPanesWithoutWaiting() {
        cancelAllSuspensionLeases()
        for paneID in suspendedPaneIDs.sorted() {
            write(String(decoding: TmuxCommandEncoder.resumePaneOutput(paneID), as: UTF8.self))
        }
        suspendedPaneIDs.removeAll(keepingCapacity: true)
    }

    private func applyPaneOutput(paneID: String, data: Data) {
        viewer.apply(.output(paneID: paneID, data: data))
        onPaneOutput?(paneID, data)
    }

    private func resetInitialCaptureState(preservingSuspendedPanes: Bool = false) {
        if !preservingSuspendedPanes {
            cancelAllSuspensionLeases()
        }
        hasCompletedInitialCapture = false
        initialSnapshotRetryCount = 0
        readyPaneIDs.removeAll(keepingCapacity: true)
        snapshotPaneIDs.removeAll(keepingCapacity: true)
        snapshotAssemblies.removeAll(keepingCapacity: true)
        bufferedLiveOutput.removeAll(keepingCapacity: true)
        if !preservingSuspendedPanes {
            suspendedPaneIDs.removeAll(keepingCapacity: true)
        }
    }

    private func scheduleSuspensionLease(for paneID: String) {
        cancelSuspensionLease(for: paneID)
        let delay = suspensionLeaseNanoseconds
        suspensionLeaseTasks[paneID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            self?.suspensionLeaseExpired(for: paneID)
        }
    }

    private func suspensionLeaseExpired(for paneID: String) {
        suspensionLeaseTasks[paneID] = nil
        guard suspendedPaneIDs.contains(paneID), fatalRecoveryReason == nil else { return }
        let message = "tmux pane output suspension lease expired: \(paneID)"
        reportError(message)
        beginFatalDetachRecovery(reason: message)
    }

    private func cancelSuspensionLease(for paneID: String) {
        suspensionLeaseTasks.removeValue(forKey: paneID)?.cancel()
    }

    private func cancelAllSuspensionLeases() {
        for task in suspensionLeaseTasks.values { task.cancel() }
        suspensionLeaseTasks.removeAll(keepingCapacity: true)
    }

    private func reportError(_ message: String) {
        viewer.recordError(message)
        onError?(message)
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        let seconds = max(0.001, interval)
        return UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
    }

}
