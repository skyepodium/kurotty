import Darwin
import AppKit

/// Decides whether closing a tab or window needs a confirmation because a
/// pane's shell still runs a child process (an editor, ssh, a build).
///
/// The decision layer is pure: process listing and name resolution are
/// injected so tests can drive it without spawning processes. Production call
/// sites use `runningProcessNames(shellProcessIdentifiers:)`, which walks each
/// shell's direct children through the same `libproc` reader the status bar's
/// resource sampler already uses. An idle shell has no children, so it never
/// prompts; a tmux placeholder or test double has no shell pid at all and is
/// skipped before any process call.
enum TerminalCloseConfirmation {
    /// Cap on names shown in the confirmation dialog. The decision counts every
    /// process; the dialog does not need to list a whole build tree.
    static let maximumDisplayedProcessNameCount = 4

    /// Answers the confirmation instead of raising a modal.
    ///
    /// `NSAlert.runModal()` blocks until someone clicks. Under XCTest nobody
    /// can, so a close that hit a live child wedged the whole run: three test
    /// processes were observed stuck at 0% CPU for over half an hour, which
    /// reads as "the suite is slow" rather than "the suite is hung".
    ///
    /// A test that wants to exercise the guard sets this explicitly; leaving it
    /// unset resolves to "allow the close", because a test calling a close
    /// wants the close. `XCTestCase` is absent from the shipped app, so the
    /// fallback below cannot change what a user sees.
    @MainActor static var presenterOverride: (([String]) -> Bool)?

    @MainActor static var isRunningUnderTest: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// The answer to use without presenting, or `nil` to present for real.
    @MainActor static func resolvedWithoutPresenting(processNames: [String]) -> Bool? {
        if let presenterOverride { return presenterOverride(processNames) }
        return isRunningUnderTest ? true : nil
    }

    struct Decision: Equatable {
        /// Distinct running child process names, first-seen order.
        var processNames: [String]

        var needsConfirmation: Bool { !processNames.isEmpty }

        static let noConfirmation = Decision(processNames: [])
    }

    static func decision(
        isEnabled: Bool,
        shellProcessIdentifiers: [pid_t],
        childProcessLister: (pid_t) -> [pid_t],
        processNameResolver: (pid_t) -> String?
    ) -> Decision {
        guard isEnabled else { return .noConfirmation }

        var names: [String] = []
        var seenNames = Set<String>()
        for shellProcessIdentifier in shellProcessIdentifiers where shellProcessIdentifier > 0 {
            for child in childProcessLister(shellProcessIdentifier) {
                // A child whose name cannot be read is still a running process;
                // hiding it would skip the confirmation exactly when the
                // process is unusual enough to resist inspection.
                let name = processNameResolver(child) ?? fallbackProcessName
                guard seenNames.insert(name).inserted else { continue }
                names.append(name)
            }
        }
        return Decision(processNames: names)
    }

    /// Production entry: reads live process state for the given shell pids.
    static func runningProcessNames(shellProcessIdentifiers: [pid_t]) -> [String] {
        decision(
            isEnabled: true,
            shellProcessIdentifiers: shellProcessIdentifiers,
            childProcessLister: TerminalProcessTreeReader.childProcessIdentifiers(of:),
            processNameResolver: processName(processIdentifier:)
        ).processNames
    }

    /// Invocation name first (`argv[0]` basename, e.g. `codex` rather than
    /// `codex-aarch64-apple-darwin`), kernel executable name as fallback —
    /// the same precedence `ShellSession.foregroundProcessName()` uses.
    static func processName(processIdentifier: pid_t) -> String? {
        if let invokedName = TerminalProcessArguments.commandName(pid: processIdentifier) {
            return invokedName
        }
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let byteCount = proc_name(processIdentifier, &nameBuffer, UInt32(nameBuffer.count))
        guard byteCount > 0 else { return nil }
        let name = String(cString: nameBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Shown when a child process exists but its name cannot be read. This is a
    /// last-resort placeholder, not user-facing copy ownership: the dialog
    /// localizes around the list, and one opaque entry still communicates
    /// "something is running".
    static let fallbackProcessName = "?"

    /// The dialog's process list: capped and joined for a one-line message.
    static func displayedProcessList(_ names: [String]) -> String {
        names.prefix(maximumDisplayedProcessNameCount).joined(separator: ", ")
    }
}
