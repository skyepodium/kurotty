#if os(macOS)
import Darwin
import Foundation

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

final class DarwinPTYTerminalSession: TerminalSession, @unchecked Sendable {
    var onOutput: ((String) -> Void)?
    var onRawOutput: ((Data) -> Void)?
    var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var master: Int32 = -1
    private var childPid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?
    private let readQueue = DispatchQueue(label: "dev.kurotty.shell-session.read", qos: .userInteractive)
    private var inputDrainGeneration: UInt64 = 0
    private var isStarted = false
    private var isStopping = false
    private var isInputDrainScheduled = false
    private var pendingInput = Data()
    private var pendingInputStartIndex = 0
    private var pendingOutput = Data()
    private var pendingOutputStartIndex = 0
    private var readBuffer = [UInt8](repeating: 0, count: AppConstants.Shell.ptyReadBufferSizeBytes)
    private var ptyReadTraceSequence: UInt64 = 0

    func start(workingDirectory requestedWorkingDirectory: String) {
        guard !isStarted else { return }
        let workingDirectory = ShellSettings.normalizedWorkingDirectory(requestedWorkingDirectory)
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let launchConfiguration = TerminalShellIntegrationBootstrap.bundledConfiguration(shellPath: shellPath)
        let notificationBridgeEnvironment = KurottyNotificationBridgeEnvironment.shellEnvironment()

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
                workingDirectory: workingDirectory
            )
            _exit(AppConstants.Shell.childExecFailureStatusCode)
        }

        master = fd
        childPid = pid
        setNonBlocking(fd)
        observeMaster(fd)
        observeChildExit(pid)
    }

    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        readQueue.async { [weak self] in
            self?.enqueueInput(data)
        }
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
        if let readSource {
            readSource.cancel()
            self.readSource = nil
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
        drainInput()
    }

    private func drainInput() {
        isInputDrainScheduled = false
        guard master >= 0 else {
            pendingInput.removeAll(keepingCapacity: true)
            pendingInputStartIndex = 0
            return
        }

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
        readSource = source
        source.resume()
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
        let exitStatus = Self.normalizedExitStatus(status)
        guard !isStopping else { return }

        // The process source and PTY read source share readQueue, but either may
        // be delivered first. Drain once after waitpid so output already buffered
        // by the kernel is enqueued on the main queue before the exit callback.
        if master >= 0 {
            drainOutput(master)
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

    private func drainOutput(_ fd: Int32) {
        var didRead = false
        while true {
            let count = readBuffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(fd, baseAddress, rawBuffer.count)
            }
            if count > 0 {
                let chunk = Data(readBuffer[0..<count])
                emitRuntimePtyRead(byteCount: chunk.count)
                onRawOutput?(chunk)
                pendingOutput.append(chunk)
                didRead = true
                continue
            }
            if count == -1 && errno == EINTR {
                continue
            }
            break
        }

        guard didRead, let text = takeDecodedOutput(), !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onOutput?(text)
        }
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
        let pendingBytes = pendingOutput[pendingOutputStartIndex...]
        if let text = String(data: Data(pendingBytes), encoding: .utf8) {
            consumePendingOutput(pendingBytes.count)
            return text
        }

        let count = pendingBytes.count
        guard count > AppConstants.Shell.maximumUTF8ScalarBytes else { return nil }
        for validCount in stride(
            from: count - 1,
            through: max(0, count - AppConstants.Shell.maximumUTF8ScalarBytes),
            by: -1
        ) {
            let prefix = pendingBytes.prefix(validCount)
            if let text = String(data: prefix, encoding: .utf8) {
                consumePendingOutput(validCount)
                return text
            }
        }
        let decodableCount = count - AppConstants.Shell.maximumUTF8ScalarBytes
        let text = String(decoding: pendingBytes.prefix(decodableCount), as: UTF8.self)
        consumePendingOutput(decodableCount)
        return text
    }

    private func consumePendingOutput(_ count: Int) {
        pendingOutputStartIndex += count
        compactPendingOutputIfNeeded()
    }

    private func compactPendingOutputIfNeeded() {
        guard pendingOutputStartIndex > 0 else { return }
        guard pendingOutputStartIndex >= pendingOutput.count / 2 || pendingOutputStartIndex == pendingOutput.count else { return }
        pendingOutput = Data(pendingOutput[pendingOutputStartIndex...])
        pendingOutputStartIndex = 0
    }

    private static func normalizedExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal != 0 {
            return AppConstants.Shell.signalExitStatusBase + signal
        }
        return (status >> 8) & 0xff
    }
}

private func runChildShell(
    shellPath: String,
    launchConfiguration: TerminalShellLaunchConfiguration,
    notificationBridgeEnvironment: [String: String],
    workingDirectory: String
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
    setenv("HISTFILE", "\(homeDirectory)/.zsh_history", 1)
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

    shellPath.withCString { executablePath in
        var argv = ([launchConfiguration.argumentZero] + launchConfiguration.arguments)
            .map { strdup($0) as UnsafeMutablePointer<CChar>? }
        argv.append(nil)
        execv(executablePath, &argv)
    }
}

#endif
