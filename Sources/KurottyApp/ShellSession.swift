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
    private let readQueue = DispatchQueue(label: "dev.kurotty.shell-session.read", qos: .userInteractive)
    private var inputDrainGeneration: UInt64 = 0
    private var isStarted = false
    private var pendingOutput = Data()
    private var startupDirectoryPath: String?

    func start() {
        guard !isStarted else { return }
        isStarted = true

        var fd: Int32 = -1
        var size = winsize(
            ws_row: UInt16(AppConstants.Terminal.defaultRows),
            ws_col: UInt16(AppConstants.Terminal.defaultColumns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let startupEnvironment = makeStartupEnvironment()
        let pid = withUnsafePointer(to: &size) { sizePointer in
            systemForkpty(&fd, nil, nil, sizePointer)
        }

        if pid < 0 {
            removeStartupDirectory()
            onOutput?("failed to start PTY: \(String(cString: strerror(errno)))\n")
            return
        }

        if pid == 0 {
            runChildShell(startupEnvironment: startupEnvironment)
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
        removeStartupDirectory()
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
                pendingOutput.append(Data(buffer[0..<count]))
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

    private func makeStartupEnvironment() -> ShellStartupEnvironment {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let startupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(ShellStartupConstants.runtimeDirectoryPrefix + UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: startupDirectory,
                withIntermediateDirectories: true,
                attributes: ShellStartupConstants.runtimeDirectoryAttributes
            )
            let zshrcPath = startupDirectory.appendingPathComponent(ShellStartupConstants.zshrcFileName)
            try ShellStartupConstants.zshrcContents.write(to: zshrcPath, atomically: true, encoding: .utf8)
            startupDirectoryPath = startupDirectory.path
            return ShellStartupEnvironment(homeDirectory: homeDirectory, zshDotDirectory: startupDirectory.path)
        } catch {
            return ShellStartupEnvironment(homeDirectory: homeDirectory, zshDotDirectory: nil)
        }
    }

    private func removeStartupDirectory() {
        guard let startupDirectoryPath else { return }
        try? FileManager.default.removeItem(atPath: startupDirectoryPath)
        self.startupDirectoryPath = nil
    }
}

private func runChildShell(startupEnvironment: ShellStartupEnvironment) {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    setenv("TERM", AppConstants.Shell.term, 1)
    setenv("COLORTERM", AppConstants.Shell.colorTerm, 1)
    setenv("PWD", startupEnvironment.homeDirectory, 1)
    setenv("HOME", startupEnvironment.homeDirectory, 1)
    setenv("PS1", AppConstants.Shell.prompt, 1)
    setenv("PROMPT", AppConstants.Shell.prompt, 1)
    setenv("RPROMPT", "", 1)
    setenv("RPS1", "", 1)
    setenv("POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD", "true", 1)
    setenv("ZSH_DISABLE_COMPFIX", "true", 1)
    if let zshDotDirectory = startupEnvironment.zshDotDirectory {
        setenv("ZDOTDIR", zshDotDirectory, 1)
    }
    chdir(startupEnvironment.homeDirectory)

    shell.withCString { shellPath in
        let arg0 = strdup(shellPath)
        var argv: [UnsafeMutablePointer<CChar>?] = [arg0, nil]
        execv(shellPath, &argv)
    }
}

private struct ShellStartupEnvironment {
    let homeDirectory: String
    let zshDotDirectory: String?
}

private enum ShellStartupConstants {
    static let runtimeDirectoryPrefix = "kurotty-zdotdir-"
    static let zshrcFileName = ".zshrc"
    static let runtimeDirectoryPermissions = 0o700
    static var runtimeDirectoryAttributes: [FileAttributeKey: Any] {
        [
            .posixPermissions: runtimeDirectoryPermissions,
        ]
    }
    static let zshrcContents = """
    unsetopt BEEP
    setopt AUTO_CD
    setopt AUTO_LIST
    setopt AUTO_MENU
    setopt COMPLETE_IN_WORD
    setopt PROMPT_SUBST
    unsetopt NOMATCH

    export PROMPT='\(AppConstants.Shell.prompt)'
    export PS1="$PROMPT"
    export RPROMPT=''
    export RPS1=''
    export POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true
    export ZSH_DISABLE_COMPFIX=true

    # ZDOTDIR points at Kurotty's runtime directory, so zsh would otherwise skip
    # the user's normal oh-my-zsh/plugins/theme setup in ~/.zshrc.
    [[ -r "$HOME/.zshrc" ]] && source "$HOME/.zshrc"

    alias ll >/dev/null 2>&1 || alias ll='ls -la'
    alias la >/dev/null 2>&1 || alias la='ls -A'
    alias l >/dev/null 2>&1 || alias l='ls -CF'

    if ! whence -w compdef >/dev/null 2>&1; then
        autoload -Uz compinit
        compinit -d "$ZDOTDIR/.zcompdump"
    fi
    """
}
