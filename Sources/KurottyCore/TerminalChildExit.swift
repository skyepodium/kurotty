import Foundation

/// How a pane's child process ended.
///
/// `waitpid(2)` packs two different outcomes into one status word: the child
/// called `exit(status)`, or a signal killed it. The POSIX shell convention
/// flattens both onto a single number by reporting `128 + signal` for the
/// second case, which makes a genuine `exit 137` indistinguishable from a
/// `SIGKILL`. A pane has to tell the user which one happened, so the two stay
/// separate cases here and are flattened only at the boundaries that speak
/// exit codes.
public enum TerminalChildExitStatus: Equatable, Sendable {
    case exited(code: Int32)
    case signalled(signal: Int32)

    /// Shell convention for reporting a signal death as one number.
    public static let signalExitCodeBase: Int32 = 128

    private static let signalMask: Int32 = 0x7f
    private static let exitCodeShift: Int32 = 8
    private static let exitCodeMask: Int32 = 0xff

    /// Decodes a raw `waitpid(2)` status word.
    public init(waitpidStatus: Int32) {
        let signal = waitpidStatus & Self.signalMask
        guard signal == 0 else {
            self = .signalled(signal: signal)
            return
        }
        self = .exited(code: (waitpidStatus >> Self.exitCodeShift) & Self.exitCodeMask)
    }

    /// The single number a shell would report for this outcome. Used by
    /// consumers that only speak exit codes, such as the tmux control-mode
    /// transport.
    public var shellExitCode: Int32 {
        switch self {
        case let .exited(code):
            return code
        case let .signalled(signal):
            return Self.signalExitCodeBase + signal
        }
    }

    /// A child that chose to leave with status 0. A nonzero status or any
    /// signal is an abnormal end that the pane must keep on screen.
    public var isCleanExit: Bool {
        self == .exited(code: 0)
    }
}

/// One child-process exit as the owning pane hears about it.
public struct TerminalChildExit: Equatable, Sendable {
    public let status: TerminalChildExitStatus
    /// Wall-clock seconds the child ran, when the session kept a start clock.
    /// `nil` for sessions that never spawn a child of their own, such as a tmux
    /// pane whose process lives inside the tmux server.
    public let runtimeSeconds: TimeInterval?

    public init(status: TerminalChildExitStatus, runtimeSeconds: TimeInterval? = nil) {
        self.status = status
        self.runtimeSeconds = runtimeSeconds
    }
}

/// Compact "how long it ran" text for the exit banner.
///
/// `%.1fs` is fine for a command that ran for seconds and unreadable for a
/// shell that ran for an afternoon, so the unit follows the magnitude.
public enum TerminalChildExitRuntimeText {
    private static let secondsPerMinute: TimeInterval = 60
    private static let secondsPerHour: TimeInterval = 3_600
    private static let subSecondFormat = "%.1fs"
    private static let secondsFormat = "%ds"
    private static let minutesFormat = "%dm %02ds"
    private static let hoursFormat = "%dh %02dm"

    public static func text(seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 1 {
            return String(format: subSecondFormat, clamped)
        }
        if clamped < secondsPerMinute {
            return String(format: secondsFormat, Int(clamped))
        }
        if clamped < secondsPerHour {
            let wholeMinutes = Int(clamped / secondsPerMinute)
            let remainingSeconds = Int(clamped) - wholeMinutes * Int(secondsPerMinute)
            return String(format: minutesFormat, wholeMinutes, remainingSeconds)
        }
        let wholeHours = Int(clamped / secondsPerHour)
        let remainingMinutes = Int((clamped - TimeInterval(wholeHours) * secondsPerHour) / secondsPerMinute)
        return String(format: hoursFormat, wholeHours, remainingMinutes)
    }
}

/// What a pane does with itself once its child process is gone.
///
/// Deliberately distinct from `terminal.confirmCloseRunningProcess`, which
/// guards a close the *user* asked for while a process is still running. This
/// setting only ever applies after the process has already ended, so the two
/// can never contend over the same close and neither has to consult the other.
public enum TerminalCloseOnChildExitMode: String, CaseIterable, Codable, Sendable {
    /// Always keep the pane and show the exit banner.
    case never
    /// Close on a status-0 exit; keep the pane with the banner otherwise.
    case onCleanExit
    /// Close whatever the child's outcome was.
    case always
}

/// Maps a child exit plus the user's `terminal.closeOnChildExit` choice onto
/// the one thing the pane should do next.
///
/// A pure type on purpose: the pane view that acts on it is a large AppKit
/// object, and this decision has to stay testable without a window.
public enum TerminalChildExitPolicy {
    public enum Action: Equatable, Sendable {
        /// Keep the pane on screen and present the exit banner.
        case presentBanner
        /// Remove the pane; the child already ended, so nothing is killed.
        case closePane
    }

    public static func action(
        mode: TerminalCloseOnChildExitMode,
        status: TerminalChildExitStatus
    ) -> Action {
        switch mode {
        case .never:
            return .presentBanner
        case .onCleanExit:
            return status.isCleanExit ? .closePane : .presentBanner
        case .always:
            return .closePane
        }
    }
}
