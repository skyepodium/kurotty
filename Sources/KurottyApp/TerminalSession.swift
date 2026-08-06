import Foundation
import KurottyCore

protocol TerminalSession: AnyObject {
    var onOutput: ((String) -> Void)? { get set }
    var onRawOutput: ((Data) -> Void)? { get set }
    var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)? { get set }
    /// Delivered on the main queue once the session's child process is gone.
    /// Carries the `waitpid(2)` outcome rather than a flattened exit code, so
    /// the pane can tell "the shell exited 137" from "a signal killed it".
    var onExit: ((TerminalChildExit) -> Void)? { get set }

    func start(workingDirectory requestedWorkingDirectory: String)
    func write(_ text: String)
    func foregroundProcessName() -> String?
    func canReceiveTerminalResponseWithoutEcho() -> Bool
    func resize(columns: Int, rows: Int)
    func stop()
}

/// Optional capability for sessions that spawn a real child process. The owner
/// resolves every value that needs the main actor (settings, hook coordinator)
/// and hands it over before `start(workingDirectory:)`, so the session itself
/// never reaches back into main-actor state from the launch path.
///
/// Deliberately separate from `TerminalSession` so tmux, tests, and any future
/// non-PTY session stay conformant without carrying PTY launch state.
protocol TerminalShellLaunchConfigurable: AnyObject {
    /// `KUROTTY_PANE_ID` / hook port / hook token. Empty unless
    /// `terminal.agentStatusHooksEnabled` is on and the listener is bound.
    var agentStatusHookEnvironment: [String: String] { get set }
    /// Mirror of `shell.perProjectHistoryEnabled` (next-session).
    var perProjectHistoryEnabled: Bool { get set }
}
