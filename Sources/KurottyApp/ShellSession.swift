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

    private var master: Int32 = -1
    private var childPid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true

        var fd: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let pid = withUnsafePointer(to: &size) { sizePointer in
            systemForkpty(&fd, nil, nil, sizePointer)
        }

        if pid < 0 {
            onOutput?("failed to start PTY: \(String(cString: strerror(errno)))\n")
            return
        }

        if pid == 0 {
            runChildShell()
            _exit(127)
        }

        master = fd
        childPid = pid
        setNonBlocking(fd)
        observeMaster(fd)
    }

    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            _ = Darwin.write(master, base, rawBuffer.count)
        }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if childPid > 0 {
            kill(childPid, SIGTERM)
            childPid = -1
        }
        if master >= 0 {
            close(master)
            master = -1
        }
    }

    private func observeMaster(_ fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return }
            let data = Data(buffer[0..<count])
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.onOutput?(text)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        readSource = source
        source.resume()
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }
}

private func runChildShell() {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    setenv("TERM", "xterm-256color", 1)
    setenv("COLORTERM", "truecolor", 1)
    setenv("PWD", "/Users/skyepodium/dev/kurotty", 1)
    setenv("PS1", "%n %~ ", 1)
    setenv("PROMPT", "%n %~ ", 1)
    setenv("RPROMPT", "", 1)
    setenv("RPS1", "", 1)
    setenv("POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD", "true", 1)
    chdir("/Users/skyepodium/dev/kurotty")

    shell.withCString { shellPath in
        let arg0 = strdup(shellPath)
        let arg1 = strdup("-f")
        var argv: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, nil]
        execv(shellPath, &argv)
    }
}
