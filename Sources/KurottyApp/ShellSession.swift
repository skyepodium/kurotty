#if os(macOS)
import Darwin
import Foundation
import KurottyCore

@_silgen_name("forkpty")
private func systemForkpty(
    _ master: UnsafeMutablePointer<Int32>,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termp: UnsafePointer<termios>?,
    _ winp: UnsafePointer<winsize>?
) -> pid_t

enum TerminalResizeSignalTarget: Equatable {
    case processGroup(pid_t)
    case process(pid_t)

    static func resolve(foregroundProcessGroup: pid_t, childProcess: pid_t) -> TerminalResizeSignalTarget? {
        if foregroundProcessGroup > 0 {
            return .processGroup(foregroundProcessGroup)
        }
        if childProcess > 0 {
            return .process(childProcess)
        }
        return nil
    }
}

final class DarwinPTYTerminalSession: TerminalSession, TerminalShellLaunchConfigurable, TerminalShellProcessIdentifying, TerminalSessionInputBackpressureReporting, @unchecked Sendable {
    var onOutput: ((String) -> Void)?
    var onRawOutput: ((Data) -> Void)?
    var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
    var onExit: ((TerminalChildExit) -> Void)?

    private var master: Int32 = -1
    private var childPid: pid_t = -1
    /// Set when the child is forked and read once when it is reaped, so the
    /// exit banner can say how long the session ran.
    private var childStartDate: Date?
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?
    private let readQueue = DispatchQueue(label: "dev.kurotty.shell-session.read", qos: .userInteractive)
    private var inputDrainGeneration: UInt64 = 0
    private var isStarted = false
    private var isStopping = false
    private var isInputDrainScheduled = false
    private var pendingInput = Data()
    private var pendingInputStartIndex = 0
    /// Bytes accepted from callers but not yet handed to the PTY. Published
    /// under `queuedInputLock` so the main actor can pace large pastes without
    /// reaching into `readQueue` state.
    private var publishedQueuedInputByteCount = 0
    private let queuedInputLock = NSLock()
    /// Undecoded PTY bytes. Touched only on `readQueue`.
    private var pendingOutput = TerminalPendingOutputBuffer(
        byteLimit: AppConstants.Shell.pendingOutputByteLimit
    )
    private var readBuffer = [UInt8](repeating: 0, count: AppConstants.Shell.ptyReadBufferSizeBytes)
    private var ptyReadTraceSequence: UInt64 = 0

    /// Flow control for the read source.
    ///
    /// `outputBackpressureLock` guards every field below plus `readSource`
    /// itself, because the suspend/resume calls have to stay balanced: the
    /// decision is made on `readQueue` (a drain just delivered bytes) or on the
    /// main queue (the surface just consumed them), and computing the action on
    /// one queue while applying it on another is how the balance is lost.
    /// Dispatch traps on an over-resume and never runs the cancel handler of a
    /// source that is still suspended.
    private let outputBackpressureLock = NSLock()
    private let outputBackpressurePolicy = TerminalOutputBackpressurePolicy.default
    private var outputReaderState = TerminalOutputBackpressurePolicy.ReaderState.reading
    /// Bytes handed to the main queue that the surface has not consumed yet.
    /// This is the real backlog: `pendingOutput` empties on every drain, while
    /// undelivered main-queue work is what grows without bound when the child
    /// outruns the renderer.
    private var undeliveredOutputByteCount = 0
    private var outputBackpressureCounters = TerminalOutputBackpressureDiagnostics()

    /// Agent-status hook variables for this pane's PTY, resolved by the owner
    /// from `AgentStatusHookCoordinator.shared.shellEnvironment(paneIdentifier:)`.
    ///
    /// Must be assigned before `start(workingDirectory:)`. Empty by default, so
    /// a session whose owner never sets it spawns exactly as before.
    var agentStatusHookEnvironment: [String: String] = [:]

    /// Next-session mirror of `shell.perProjectHistoryEnabled`, assigned by the
    /// owner before `start(workingDirectory:)`. An inherited `HISTFILE` still
    /// wins either way.
    var perProjectHistoryEnabled: Bool = SettingsDefaults.perProjectHistoryEnabled

    /// The pane's direct shell child, published for the window status bar.
    ///
    /// `childPid` stays at `-1` before `start(workingDirectory:)` and is reset
    /// to `-1` on exit/stop, so the sampler's `> 1` guard already covers both
    /// "not started" and "already exited" without a second liveness check here.
    var shellProcessIdentifier: pid_t { childPid }

    func start(workingDirectory requestedWorkingDirectory: String) {
        guard !isStarted else { return }
        let workingDirectory = ShellSettings.normalizedWorkingDirectory(requestedWorkingDirectory)
        let shellPath = TerminalShellIntegrationBootstrap.loginShellPath()
        let launchConfiguration = TerminalShellIntegrationBootstrap.bundledConfiguration(shellPath: shellPath)
        let notificationBridgeEnvironment = KurottyNotificationBridgeEnvironment.shellEnvironment()
        // Derived at the launch boundary: the `.git` walk needs the filesystem
        // and must not run inside the forked child. Directory creation is left
        // to the child, which is off the main actor by construction.
        let inheritedHistoryFile = launchConfiguration.environment[
            TerminalShellHistoryEnvironment.environmentKey
        ] ?? ProcessInfo.processInfo.environment[TerminalShellHistoryEnvironment.environmentKey]
        let perProjectHistoryFilePath = TerminalShellHistoryEnvironment.resolvedHistoryFilePath(
            workingDirectory: workingDirectory,
            shellPath: shellPath,
            inheritedHistoryFile: inheritedHistoryFile,
            applicationSupportDirectory:
                TerminalShellHistoryEnvironment.defaultApplicationSupportDirectory(),
            isEnabled: perProjectHistoryEnabled
        )
        let mayExportGlobalHistoryFallback = TerminalShellHistoryEnvironment
            .shouldUseGlobalFallback(inheritedHistoryFile: inheritedHistoryFile)

        var fd: Int32 = -1
        var size = winsize(
            ws_row: UInt16(AppConstants.Terminal.defaultRows),
            ws_col: UInt16(AppConstants.Terminal.defaultColumns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let pid = withUnsafePointer(to: &size) { sizePointer in
            systemForkpty(&fd, nil, nil, sizePointer)
        }

        if pid < 0 {
            onOutput?("failed to start PTY: \(String(cString: strerror(errno)))\n")
            return
        }

        isStarted = true
        if pid == 0 {
            runChildShell(
                shellPath: shellPath,
                launchConfiguration: launchConfiguration,
                notificationBridgeEnvironment: notificationBridgeEnvironment,
                workingDirectory: workingDirectory,
                perProjectHistoryFilePath: perProjectHistoryFilePath,
                mayExportGlobalHistoryFallback: mayExportGlobalHistoryFallback,
                agentStatusHookEnvironment: agentStatusHookEnvironment
            )
            _exit(AppConstants.Shell.childExecFailureStatusCode)
        }

        master = fd
        childPid = pid
        childStartDate = Date()
        setNonBlocking(fd)
        observeMaster(fd)
        observeChildExit(pid)
    }

    /// Test seam: drives the reader from an already-open descriptor.
    ///
    /// The backpressure path is otherwise only reachable behind `forkpty`, and
    /// asserting on flow control should not require spawning a login shell.
    func attachOutputReaderForTesting(fileDescriptor: Int32) {
        guard !isStarted else { return }
        isStarted = true
        master = fileDescriptor
        setNonBlocking(fileDescriptor)
        observeMaster(fileDescriptor)
    }

    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        readQueue.async { [weak self] in
            self?.enqueueInput(data)
        }
    }

    /// Bytes still queued for the PTY. Read from any thread; the paste writer
    /// uses it to stay behind the write path.
    var queuedInputByteCount: Int {
        queuedInputLock.lock()
        defer { queuedInputLock.unlock() }
        return publishedQueuedInputByteCount
    }

    func foregroundProcessName() -> String? {
        guard master >= 0, childPid > 0 else { return nil }
        let foregroundProcessGroup = tcgetpgrp(master)
        guard foregroundProcessGroup > 0, foregroundProcessGroup != childPid else { return nil }

        if let invokedName = TerminalProcessArguments.commandName(pid: foregroundProcessGroup) {
            return invokedName
        }

        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let byteCount = proc_name(foregroundProcessGroup, &nameBuffer, UInt32(nameBuffer.count))
        guard byteCount > 0 else { return nil }
        let name = String(
            decoding: nameBuffer.prefix(Int(byteCount)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func canReceiveTerminalResponseWithoutEcho() -> Bool {
        guard master >= 0 else { return false }
        var attributes = termios()
        guard tcgetattr(master, &attributes) == 0 else {
            return false
        }
        return TerminalLineDiscipline.canReceiveTerminalResponseWithoutEcho(localFlags: attributes.c_lflag)
    }

    func resize(columns: Int, rows: Int) {
        guard master >= 0 else { return }
        let trace = TerminalResizeTrace(
            requestedColumns: columns,
            requestedRows: rows,
            cellSize: nil,
            viewSize: nil,
            ioctlResult: 0,
            ioctlErrno: nil,
            didSendSIGWINCH: false
        )
        var size = winsize(
            ws_row: UInt16(trace.clampedRows),
            ws_col: UInt16(trace.clampedColumns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let ioctlResult = ioctl(master, TIOCSWINSZ, &size)
        let ioctlErrno = ioctlResult == -1 ? errno : nil
        let signalTarget = TerminalResizeSignalTarget.resolve(
            foregroundProcessGroup: tcgetpgrp(master),
            childProcess: childPid
        )
        let didSendSIGWINCH: Bool
        switch signalTarget {
        case let .processGroup(processGroup):
            didSendSIGWINCH = killpg(processGroup, SIGWINCH) == 0
        case let .process(process):
            didSendSIGWINCH = kill(process, SIGWINCH) == 0
        case nil:
            didSendSIGWINCH = false
        }
        if DebugOptions.ptyLog {
            let completedTrace = TerminalResizeTrace(
                requestedColumns: columns,
                requestedRows: rows,
                cellSize: nil,
                viewSize: nil,
                ioctlResult: Int32(ioctlResult),
                ioctlErrno: ioctlErrno,
                didSendSIGWINCH: didSendSIGWINCH
            )
            NSLog("Kurotty PTY resize: %@", completedTrace.description)
        }
    }

    func stop() {
        isStopping = true
        outputBackpressureLock.lock()
        // A suspended source never runs its cancel handler, so the file
        // descriptor would leak and the source would trap on deallocation.
        // Balance the suspension before cancelling.
        if outputReaderState == .suspended {
            readSource?.resume()
            outputReaderState = .reading
        }
        let source = readSource
        readSource = nil
        outputBackpressureLock.unlock()

        if let source {
            source.cancel()
        } else if master >= 0 {
            close(master)
        }
        waitSource?.cancel()
        waitSource = nil
        if childPid > 0 {
            kill(childPid, SIGTERM)
            var status: Int32 = 0
            _ = waitpid(childPid, &status, WNOHANG)
            childPid = -1
        }
        master = -1
    }

    private func enqueueInput(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingInput.append(data)
        publishQueuedInputByteCount()
        drainInput()
    }

    private func drainInput() {
        isInputDrainScheduled = false
        guard master >= 0 else {
            pendingInput.removeAll(keepingCapacity: true)
            pendingInputStartIndex = 0
            publishQueuedInputByteCount()
            return
        }
        defer { publishQueuedInputByteCount() }

        var didWrite = false
        while pendingInputReadableCount > 0 {
            let previousInputCount = pendingInputReadableCount
            let didMakeProgress = writeInputChunk(master)
            didWrite = didWrite || pendingInputReadableCount < previousInputCount
            guard didMakeProgress else {
                if didWrite {
                    scheduleOutputDrain()
                }
                scheduleInputDrain()
                return
            }
        }

        if didWrite {
            scheduleOutputDrain()
        }
    }

    private func writeInputChunk(_ fd: Int32) -> Bool {
        let written = pendingInput.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(
                fd,
                baseAddress.advanced(by: pendingInputStartIndex),
                pendingInputReadableCount
            )
        }

        if written > 0 {
            consumePendingInput(written)
            return true
        }
        if written == -1 && errno == EINTR {
            return true
        }
        if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            return false
        }

        pendingInput.removeAll(keepingCapacity: true)
        pendingInputStartIndex = 0
        return true
    }

    private var pendingInputReadableCount: Int {
        pendingInput.count - pendingInputStartIndex
    }

    private func publishQueuedInputByteCount() {
        let count = max(0, pendingInputReadableCount)
        queuedInputLock.lock()
        publishedQueuedInputByteCount = count
        queuedInputLock.unlock()
    }

    private func consumePendingInput(_ count: Int) {
        pendingInputStartIndex += count
        compactPendingInputIfNeeded()
    }

    private func compactPendingInputIfNeeded() {
        guard pendingInputStartIndex > 0 else { return }
        guard pendingInputStartIndex >= pendingInput.count / 2 || pendingInputStartIndex == pendingInput.count else { return }
        pendingInput = Data(pendingInput[pendingInputStartIndex...])
        pendingInputStartIndex = 0
    }

    private func scheduleInputDrain() {
        guard !isInputDrainScheduled else { return }
        isInputDrainScheduled = true
        readQueue.asyncAfter(deadline: .now() + .microseconds(Int(AppConstants.Shell.ptyWriteRetryDelayMicros))) { [weak self] in
            self?.drainInput()
        }
    }

    private func observeMaster(_ fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in
            self?.drainOutput(fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        // Resumed under the lock so that `readSource` is only ever touched with
        // it held: every state transition then happens atomically with the
        // Dispatch call it describes, which is what keeps the pair balanced.
        outputBackpressureLock.lock()
        readSource = source
        outputReaderState = .reading
        source.resume()
        outputBackpressureLock.unlock()
    }

    private func observeChildExit(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        source.setEventHandler { [weak self] in
            self?.handleChildExit(pid)
        }
        waitSource = source
        source.resume()
    }

    private func handleChildExit(_ pid: pid_t) {
        var status: Int32 = 0
        let waitedPid = waitpid(pid, &status, WNOHANG)
        guard waitedPid == pid else { return }

        childPid = -1
        waitSource?.cancel()
        waitSource = nil
        let exitStatus = TerminalChildExit(
            status: TerminalChildExitStatus(waitpidStatus: status),
            runtimeSeconds: childStartDate.map { -$0.timeIntervalSinceNow }
        )
        guard !isStopping else { return }

        // The process source and PTY read source share readQueue, but either may
        // be delivered first. Drain once after waitpid so output already buffered
        // by the kernel is enqueued on the main queue before the exit callback.
        if master >= 0 {
            drainOutput(master, mode: .final)
        }
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(exitStatus)
        }
    }

    private func scheduleOutputDrain() {
        let fd = master
        guard fd >= 0 else { return }
        inputDrainGeneration &+= 1
        let generation = inputDrainGeneration
        readQueue.async { [weak self] in
            self?.drainOutput(fd)
        }
        for delay in AppConstants.Shell.inputDrainRetryDelaysMS {
            readQueue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                guard let self, self.inputDrainGeneration == generation else { return }
                self.drainOutput(fd)
            }
        }
    }

    /// Whether a drain pass answers to flow control.
    private enum OutputDrainMode {
        /// Normal reads: stop at the high-water mark and let the child block in
        /// `write(2)` until the surface catches up.
        case backpressured
        /// The post-`waitpid` read. The child is gone, so what is left is
        /// bounded by the kernel buffer and must not be lost to a byte cap or
        /// to a suspension that nothing will lift.
        case final
    }

    private func drainOutput(_ fd: Int32, mode: OutputDrainMode = .backpressured) {
        if mode == .backpressured, isOutputReaderSuspended {
            // `scheduleOutputDrain` and its retries reach this path directly,
            // bypassing the read source. Honour the suspension here or the
            // source's suspend/resume would only throttle idle sessions.
            return
        }

        var didRead = false
        var bytesReadThisDrain = 0
        let undeliveredByteCountAtStart = currentUndeliveredOutputByteCount()
        while true {
            if mode == .backpressured,
               !outputBackpressurePolicy.allowsAdditionalRead(
                   pendingBytes: undeliveredByteCountAtStart + bytesReadThisDrain,
                   bytesReadThisDrain: bytesReadThisDrain
               ) {
                // Leave the rest in the kernel buffer. The read source is
                // level-triggered, so it fires again once the reader resumes.
                break
            }
            let count = readBuffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(fd, baseAddress, rawBuffer.count)
            }
            if count > 0 {
                let chunk = Data(readBuffer[0..<count])
                emitRuntimePtyRead(byteCount: chunk.count)
                onRawOutput?(chunk)
                pendingOutput.append(chunk)
                bytesReadThisDrain += count
                didRead = true
                continue
            }
            if count == -1 && errno == EINTR {
                continue
            }
            break
        }

        guard didRead else { return }
        let text = takeDecodedOutput()
        publishDroppedOutputByteCount(pendingOutput.droppedByteCount)
        guard let text, !text.isEmpty else { return }

        // Account in UTF-8 bytes, the unit the child produced and the surface
        // will re-encode, so the mark is comparable to the read buffer size.
        let deliveredByteCount = text.utf8.count
        applyOutputBackpressure(pendingByteCountDelta: deliveredByteCount)
        DispatchQueue.main.async { [weak self] in
            self?.onOutput?(text)
            // Acknowledged only once the surface has taken the text, so the
            // measured backlog is main-queue saturation rather than how fast
            // the reader can call `async`.
            self?.applyOutputBackpressure(pendingByteCountDelta: -deliveredByteCount)
        }
    }

    /// Snapshot of the reader's flow-control state. Safe from any thread.
    var outputBackpressureDiagnostics: TerminalOutputBackpressureDiagnostics {
        outputBackpressureLock.lock()
        defer { outputBackpressureLock.unlock() }
        var diagnostics = outputBackpressureCounters
        diagnostics.isReaderSuspended = outputReaderState == .suspended
        diagnostics.pendingByteCount = undeliveredOutputByteCount
        return diagnostics
    }

    private var isOutputReaderSuspended: Bool {
        outputBackpressureLock.lock()
        defer { outputBackpressureLock.unlock() }
        return outputReaderState == .suspended
    }

    private func currentUndeliveredOutputByteCount() -> Int {
        outputBackpressureLock.lock()
        defer { outputBackpressureLock.unlock() }
        return undeliveredOutputByteCount
    }

    /// Updates the backlog and suspends or resumes the read source to match.
    ///
    /// The mutation and the Dispatch call are made together under the lock so
    /// that concurrent deliveries and acknowledgements cannot interleave into
    /// an unbalanced suspend/resume pair.
    private func applyOutputBackpressure(pendingByteCountDelta: Int) {
        outputBackpressureLock.lock()
        defer { outputBackpressureLock.unlock() }

        undeliveredOutputByteCount = max(0, undeliveredOutputByteCount + pendingByteCountDelta)
        outputBackpressureCounters.peakPendingByteCount = max(
            outputBackpressureCounters.peakPendingByteCount,
            undeliveredOutputByteCount
        )

        guard let readSource else { return }
        let action = outputBackpressurePolicy.action(
            pendingBytes: undeliveredOutputByteCount,
            state: outputReaderState
        )
        switch action {
        case .none:
            return
        case .suspendReader:
            readSource.suspend()
            outputReaderState = .suspended
            outputBackpressureCounters.suspendCount += 1
        case .resumeReader:
            readSource.resume()
            outputReaderState = .reading
            outputBackpressureCounters.resumeCount += 1
        }
        if DebugOptions.ptyLog {
            NSLog("Kurotty PTY backpressure: action=%@ %@", "\(action)", outputBackpressureCounters.description)
        }
    }

    private func publishDroppedOutputByteCount(_ count: Int) {
        outputBackpressureLock.lock()
        let didChange = outputBackpressureCounters.droppedByteCount != count
        outputBackpressureCounters.droppedByteCount = count
        outputBackpressureLock.unlock()
        guard didChange else { return }
        // Dropping PTY bytes corrupts escape-sequence state, so it is reported
        // unconditionally rather than behind a debug flag.
        NSLog("Kurotty PTY backpressure dropped output: droppedBytes=%d", count)
    }

    private func emitRuntimePtyRead(byteCount: Int) {
        guard byteCount > 0 else { return }
        let traceID = TerminalEventTraceID("pty-read-\(ptyReadTraceSequence)")
        ptyReadTraceSequence &+= 1
        let event = TerminalEventLedger.RecordedEvent.ptyRead(traceID: traceID, byteCount: byteCount)
        onRuntimeEvent?(event)
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private func takeDecodedOutput() -> String? {
        pendingOutput.takeDecodedText()
    }
}

/// Creates the parent directories of `path` with raw `mkdir(2)` calls.
///
/// This runs in the forked child before `execv`, which keeps the filesystem work
/// off the main actor without an extra dispatch hop. Failures are ignored: a
/// missing history directory only degrades history persistence, and the child
/// must still exec the shell.
private func createDirectoryTree(forFileAtPath path: String) {
    let directory = (path as NSString).deletingLastPathComponent
    guard !directory.isEmpty, directory != "/" else { return }
    var partial = ""
    for component in directory.split(separator: "/") {
        partial += "/" + component
        _ = partial.withCString {
            mkdir($0, TerminalShellHistoryEnvironment.directoryPermissions)
        }
    }
}

private func runChildShell(
    shellPath: String,
    launchConfiguration: TerminalShellLaunchConfiguration,
    notificationBridgeEnvironment: [String: String],
    workingDirectory: String,
    perProjectHistoryFilePath: String?,
    mayExportGlobalHistoryFallback: Bool,
    agentStatusHookEnvironment: [String: String]
) {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    let actualWorkingDirectory: String
    if chdir(workingDirectory) == 0 {
        actualWorkingDirectory = workingDirectory
    } else {
        _ = chdir(homeDirectory)
        actualWorkingDirectory = homeDirectory
    }

    setenv("TERM", AppConstants.Shell.term, 1)
    setenv("COLORTERM", AppConstants.Shell.colorTerm, 1)
    setenv("TERM_PROGRAM", AppConstants.Shell.termProgram, 1)
    setenv("TERM_PROGRAM_VERSION", AppConstants.Bundle.currentVersion, 1)
    unsetenv("NO_COLOR")
    setenv("PWD", actualWorkingDirectory, 1)
    setenv("HOME", homeDirectory, 1)
    // Per-project history. Never overwrite a HISTFILE the user configured: the
    // caller already resolved that, so a nil path plus a disallowed fallback
    // means "leave HISTFILE untouched".
    // The literal name matches the other setenv calls in this function; it is
    // the same key as TerminalShellHistoryEnvironment.environmentKey.
    if let perProjectHistoryFilePath {
        createDirectoryTree(forFileAtPath: perProjectHistoryFilePath)
        setenv("HISTFILE", perProjectHistoryFilePath, 1)
    } else if mayExportGlobalHistoryFallback {
        setenv(
            "HISTFILE",
            "\(homeDirectory)/\(TerminalShellHistoryEnvironment.globalFallbackHistoryFileName)",
            1
        )
    }
    setenv("POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD", "true", 1)
    setenv("ZSH_DISABLE_COMPFIX", "true", 1)

    for key in launchConfiguration.environmentKeysToUnset {
        unsetenv(key)
    }
    for (key, value) in launchConfiguration.environment {
        setenv(key, value, 1)
    }
    for (key, value) in notificationBridgeEnvironment {
        setenv(key, value, 1)
    }
    for (key, value) in agentStatusHookEnvironment {
        setenv(key, value, 1)
    }

    shellPath.withCString { executablePath in
        var argv = ([launchConfiguration.argumentZero] + launchConfiguration.arguments)
            .map { strdup($0) as UnsafeMutablePointer<CChar>? }
        argv.append(nil)
        execv(executablePath, &argv)
    }
}

#endif
