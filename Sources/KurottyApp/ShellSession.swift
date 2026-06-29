import Darwin
import Foundation

@_silgen_name("forkpty")
private func systemForkpty(
    _ master: UnsafeMutablePointer<Int32>,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termp: UnsafePointer<termios>?,
    _ winp: UnsafePointer<winsize>?
) -> pid_t

final class ShellSession: @unchecked Sendable {
    var onOutput: ((String) -> Void)?
    var onRawOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var master: Int32 = -1
    private var childPid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?
    private let readQueue = DispatchQueue(label: "dev.kurotty.shell-session.read", qos: .userInteractive)
    private var inputDrainGeneration: UInt64 = 0
    private var isStarted = false
    private var isStopping = false
    private var pendingOutput = Data()

    func start(workingDirectory requestedWorkingDirectory: String) {
        guard !isStarted else { return }
        let workingDirectory = ShellSettings.normalizedWorkingDirectory(requestedWorkingDirectory)

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
            runChildShell(workingDirectory: workingDirectory)
            _exit(127)
        }

        master = fd
        childPid = pid
        setNonBlocking(fd)
        observeMaster(fd)
        observeChildExit(pid)
    }

    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(master, base.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == -1 && errno == EINTR {
                    continue
                }
                if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    usleep(1_000)
                    continue
                }
                break
            }
        }
        scheduleOutputDrain()
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
        var size = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(master, TIOCSWINSZ, &size)
        if childPid > 0 {
            kill(childPid, SIGWINCH)
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
        for delay in [4, 8, 16, 32, 64, 120] {
            readQueue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                guard let self, self.inputDrainGeneration == generation else { return }
                self.drainOutput(fd)
            }
        }
    }

    private func drainOutput(_ fd: Int32) {
        var didRead = false
        while true {
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
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

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private func takeDecodedOutput() -> String? {
        if let text = String(data: pendingOutput, encoding: .utf8) {
            pendingOutput.removeAll(keepingCapacity: true)
            return text
        }

        let count = pendingOutput.count
        guard count > 4 else { return nil }
        for validCount in stride(from: count - 1, through: max(0, count - 4), by: -1) {
            let prefix = pendingOutput.prefix(validCount)
            if let text = String(data: prefix, encoding: .utf8) {
                pendingOutput.removeFirst(validCount)
                return text
            }
        }
        let text = String(decoding: pendingOutput.prefix(count - 4), as: UTF8.self)
        pendingOutput.removeFirst(count - 4)
        return text
    }

    private static func normalizedExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal != 0 {
            return 128 + signal
        }
        return (status >> 8) & 0xff
    }
}

private func runChildShell(workingDirectory: String) {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
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
    unsetenv("NO_COLOR")
    unsetenv("ZDOTDIR")
    setenv("PWD", actualWorkingDirectory, 1)
    setenv("HOME", homeDirectory, 1)
    setenv("HISTFILE", "\(homeDirectory)/.zsh_history", 1)
    setenv("POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD", "true", 1)
    setenv("ZSH_DISABLE_COMPFIX", "true", 1)

    shell.withCString { shellPath in
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let arg0 = strdup("-\(shellName)")
        let interactive = strdup("-i")
        var argv: [UnsafeMutablePointer<CChar>?] = [arg0, interactive, nil]
        execv(shellPath, &argv)
    }
}
