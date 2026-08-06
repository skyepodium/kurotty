import Foundation

/// A progress report a program sent over OSC `9;4`.
///
/// The sequence is the ConEmu/Windows Terminal convention,
/// `ESC ] 9 ; 4 ; <state> ; <percent> ST`, and it is the only way a producer
/// can tell a terminal how far along it actually is. Kurotty already refused to
/// turn these into desktop alerts (`TerminalNotificationPayload` rejects a
/// numeric first parameter); this type is what finally reads them.
struct TerminalCommandProgressReport: Equatable {
    /// Wire values of the `<state>` parameter. Anything outside this set is not
    /// a progress report, so the sequence falls through to the OSC 9 handling
    /// that was already there.
    enum State: Int, Equatable {
        case cleared = 0
        case set = 1
        case error = 2
        case indeterminate = 3
        case paused = 4
    }

    let state: State
    /// The reported percentage, clamped to 0...100. `nil` when the sequence
    /// carried no percentage at all, or carried one this parser could not read:
    /// a producer that sends `4;1;` or `4;1;abc` has said "I am working", not
    /// "I am zero percent done", and the two must not render the same.
    let percent: Int?
}

extension TerminalCommandProgressReport {
    /// The OSC 9 subcommand that marks a progress report rather than a message.
    private static let subcommand = "4"
    private static let minimumPercent = 0
    /// Percent is a 0...100 wire value; the presentation works in 0...1, so
    /// this is both the clamp ceiling and the scale divisor.
    static let maximumPercent = 100

    /// Parses the payload that follows `9;` in an OSC 9 sequence.
    ///
    /// `nil` means "not a progress report", which is deliberately different
    /// from a report with no percentage: only the former may be re-read as a
    /// notification body.
    static func parse(oscPayload: String) -> TerminalCommandProgressReport? {
        let parameters = oscPayload.split(separator: ";", omittingEmptySubsequences: false)
        guard parameters.count >= 2, parameters[0] == subcommand else {
            return nil
        }
        guard let rawState = Int(parameters[1]), let state = State(rawValue: rawState) else {
            return nil
        }
        guard parameters.count >= 3 else {
            return TerminalCommandProgressReport(state: state, percent: nil)
        }
        return TerminalCommandProgressReport(
            state: state,
            percent: clampedPercent(String(parameters[2]))
        )
    }

    /// Producers do overshoot: a script that computes `done * 100 / total`
    /// reports 103 when its total was an estimate. Clamping keeps a bar that
    /// stays inside its track instead of dropping the number entirely.
    private static func clampedPercent(_ text: String) -> Int? {
        guard let value = Int(text) else {
            return nil
        }
        return min(maximumPercent, max(minimumPercent, value))
    }
}

/// What the pane's progress bar draws at one instant.
struct TerminalCommandProgressPresentation: Equatable {
    enum Fill: Equatable {
        /// Nothing said how far along the command is, so the bar has only
        /// "something is running" to show.
        case indeterminate
        /// A real fraction of the pane's width, 0...1.
        case fraction(Double)
    }

    enum Tone: Equatable {
        case running
        case failed
        case paused
    }

    /// Whether the bar is allowed to animate.
    ///
    /// The sweep makes two separate claims: "a command is running", which OSC
    /// 133 makes certain, and "progress is being made right now", which nothing
    /// backs up. This is where the second claim is withdrawn on its own — a
    /// paused command, or a sweep that has run past its ceiling. The view
    /// withholds motion for reduced motion independently; `.sweeping` is
    /// permission, not an instruction.
    enum Motion: Equatable {
        case sweeping
        case still
    }

    let fill: Fill
    let tone: Tone
    let motion: Motion
}

/// Command lifecycle as the pane's progress bar needs it, forwarded by the
/// surface so the bar never has to reach into terminal state itself.
enum TerminalCommandProgressEvent: Equatable {
    case commandStarted
    case reported(TerminalCommandProgressReport)
    case commandEnded(exitCode: Int?)
    /// A program switched the pane to the alternate screen (DEC 47/1047/1049).
    case alternateScreenEntered
    /// A keystroke the user typed reached the PTY. Only user-initiated input
    /// counts; synthesized protocol traffic does not reach this event.
    case userDidInteract
}

/// Decides whether a pane shows a progress bar, and what it shows.
///
/// Pure value type on purpose: this is the whole visibility contract, and it
/// has to be assertable without a window, a PTY, or a clock. Every decision is
/// driven by OSC 133 command boundaries, OSC 9;4 reports, and two signals that
/// say the user is *using* a program rather than waiting on one — never by
/// output volume or a quiet timer, which are exactly the guesses that make
/// other terminals show a busy bar for a command that already returned.
///
/// ## Why a running command is not always a command you are waiting on
///
/// OSC 133 gives Kurotty an exact `C` when a command launches, but an
/// interactive program never returns control to the shell, so its `D` does not
/// arrive until the user quits — an hour later. Between those two marks the
/// shell is telling the truth ("a command is running") while the bar would be
/// telling a lie ("you are waiting on it"). Two signals separate the cases, and
/// both are facts Kurotty already holds rather than inferences about content:
///
/// - the program took the alternate screen, which only a full-screen
///   application does;
/// - the user typed into it, which nobody does to a batch job they are waiting
///   on.
///
/// Neither is universal — a program can be interactive without doing either —
/// so `sweepCeilingSeconds` is the backstop. It withdraws the *motion* and not
/// the bar, because "the command ended" is precisely what a timer may never
/// claim here.
struct TerminalCommandProgressPolicy: Equatable {
    /// Mirror of `terminal.commandProgressIndicatorEnabled`. Held here rather
    /// than in the view so "off" is part of the tested contract instead of a
    /// hidden early return in AppKit code.
    var isEnabled: Bool
    /// How long a command has to run before its bar appears. A bar that flashes
    /// on every `ls` is worse than no bar.
    let appearanceDelaySeconds: TimeInterval
    /// How long a failed command's bar stays up after the command ended.
    let failureLingerSeconds: TimeInterval
    /// How long an indeterminate bar may sweep before it goes static.
    let sweepCeilingSeconds: TimeInterval

    private enum Phase: Equatable {
        case idle
        /// `isInteractive` latches for the rest of the command span. A program
        /// the user has started driving does not stop being one because it went
        /// quiet, and re-raising a bar the user already saw dismissed is worse
        /// than leaving it down.
        case running(since: Date, isInteractive: Bool)
        /// A command that already failed, whose bar the user could see while it
        /// ran. Held briefly so the failure registers instead of the bar simply
        /// vanishing at the moment the shell prompt returns.
        case failureLinger(until: Date)
    }

    private var phase: Phase = .idle
    private var report: TerminalCommandProgressReport?

    init(
        isEnabled: Bool,
        appearanceDelaySeconds: TimeInterval,
        failureLingerSeconds: TimeInterval,
        sweepCeilingSeconds: TimeInterval
    ) {
        self.isEnabled = isEnabled
        self.appearanceDelaySeconds = appearanceDelaySeconds
        self.failureLingerSeconds = failureLingerSeconds
        self.sweepCeilingSeconds = sweepCeilingSeconds
    }

    mutating func commandDidStart(at date: Date) {
        phase = .running(since: date, isInteractive: false)
        // A new command's progress is its own; the last one's number must never
        // be inherited by the next prompt.
        report = nil
    }

    /// A program switched the pane to the alternate screen.
    ///
    /// Only a full-screen application does this, and a full-screen application
    /// owns the pane's whole viewport — including the row the bar sits on. It
    /// is drawing its own status; a second one on top of it is noise.
    mutating func alternateScreenDidActivate() {
        markInteractive()
    }

    /// The user typed into the running command.
    ///
    /// Keystrokes during a command mean the command is reading them, which a
    /// batch job the user is waiting on does not do. This does catch typeahead
    /// — someone queueing their next command during a long build — and the bar
    /// goes down when it should not have. That is the cheaper failure: a bar
    /// that leaves early costs a status the user can recover by looking at the
    /// output, while a bar that sweeps for an hour costs the indicator its
    /// meaning for every other command.
    mutating func userDidInteract() {
        markInteractive()
    }

    private mutating func markInteractive() {
        guard case .running(let since, false) = phase else {
            return
        }
        phase = .running(since: since, isInteractive: true)
    }

    /// Records an OSC 9;4 report.
    ///
    /// Reports that arrive outside a command span are dropped. Kurotty knows
    /// exactly when a command runs, and a bar started by a stray sequence has
    /// nothing that is guaranteed to take it down again.
    mutating func didReceive(_ report: TerminalCommandProgressReport) {
        guard case .running = phase else {
            return
        }
        // State 0 is the producer withdrawing its number, not reporting zero:
        // the bar falls back to the elapsed-time rule rather than to an empty
        // determinate track.
        self.report = report.state == .cleared ? nil : report
    }

    mutating func commandDidEnd(exitCode: Int?, at date: Date) {
        let wasVisible = presentation(at: date) != nil
        report = nil
        // An unknown status is not a failure: OSC 133 `D` with no code says
        // nothing about the outcome, so it must not paint one.
        guard let exitCode, exitCode != 0, wasVisible else {
            phase = .idle
            return
        }
        phase = .failureLinger(until: date.addingTimeInterval(failureLingerSeconds))
    }

    func presentation(at now: Date) -> TerminalCommandProgressPresentation? {
        guard isEnabled else {
            return nil
        }
        switch phase {
        case .idle:
            return nil
        case .failureLinger(let until):
            guard now < until else {
                return nil
            }
            return TerminalCommandProgressPresentation(fill: .fraction(1), tone: .failed, motion: .still)
        case .running(let since, let isInteractive):
            guard let candidate = candidatePresentation(since: since, now: now) else {
                return nil
            }
            // A determinate percentage is information the pane does not
            // otherwise carry, so nothing below touches it: not the
            // interactivity signals, not the ceiling. Everything else is only
            // ever the claim "something is working", which is exactly what the
            // user can see for themselves once they are inside the program.
            guard case .indeterminate = candidate.fill else {
                return candidate
            }
            guard !isInteractive else {
                return nil
            }
            guard candidate.motion == .sweeping,
                  now.timeIntervalSince(since) >= sweepCeilingSeconds
            else {
                return candidate
            }
            // Static, not gone. Kurotty has had no `D`, so it does not know the
            // command ended, and a bar that vanished on a timer would be
            // claiming exactly that.
            return TerminalCommandProgressPresentation(
                fill: candidate.fill,
                tone: candidate.tone,
                motion: .still
            )
        }
    }

    /// When `presentation(at:)` would next return something different without
    /// any further input. `nil` means nothing is pending, so the caller has no
    /// reason to wake up at all — this is what keeps the bar off a repeating
    /// timer.
    func nextPresentationChange(after now: Date) -> Date? {
        guard isEnabled else {
            return nil
        }
        switch phase {
        case .idle:
            return nil
        case .failureLinger(let until):
            return now < until ? until : nil
        case .running(let since, let isInteractive):
            guard !isInteractive else {
                return nil
            }
            // Two one-shot transitions, at most: the bar becoming due, and its
            // sweep reaching the ceiling. A determinate report has neither — it
            // changes only when the producer sends the next one.
            let sweeps = report.map { Self.candidatePresentation(for: $0).motion == .sweeping } ?? true
            let pending = [
                report == nil ? since.addingTimeInterval(appearanceDelaySeconds) : nil,
                sweeps ? since.addingTimeInterval(sweepCeilingSeconds) : nil,
            ]
            return pending.compactMap { $0 }.filter { now < $0 }.min()
        }
    }

    /// What the producer, or the elapsed time, asks the bar to draw — before the
    /// interactivity and ceiling rules get a say.
    private func candidatePresentation(
        since: Date,
        now: Date
    ) -> TerminalCommandProgressPresentation? {
        if let report {
            // An explicit report is the producer declaring a long operation,
            // so it skips the delay: the number is already meaningful.
            return Self.candidatePresentation(for: report)
        }
        guard now.timeIntervalSince(since) >= appearanceDelaySeconds else {
            return nil
        }
        return TerminalCommandProgressPresentation(
            fill: .indeterminate,
            tone: .running,
            motion: .sweeping
        )
    }

    private static func candidatePresentation(
        for report: TerminalCommandProgressReport
    ) -> TerminalCommandProgressPresentation {
        let fill: TerminalCommandProgressPresentation.Fill = report.percent
            .map { .fraction(Double($0) / Double(TerminalCommandProgressReport.maximumPercent)) }
            ?? .indeterminate
        // A determinate bar has a number to show and nothing to animate, so
        // only the indeterminate fill is ever granted motion.
        let motion: TerminalCommandProgressPresentation.Motion = fill == .indeterminate
            ? .sweeping
            : .still
        switch report.state {
        case .cleared, .set:
            return TerminalCommandProgressPresentation(fill: fill, tone: .running, motion: motion)
        case .error:
            return TerminalCommandProgressPresentation(fill: fill, tone: .failed, motion: motion)
        case .indeterminate:
            // The producer said "working, no number"; a percentage sent
            // alongside state 3 would contradict the state itself.
            return TerminalCommandProgressPresentation(
                fill: .indeterminate,
                tone: .running,
                motion: .sweeping
            )
        case .paused:
            // A paused command is not moving, so its bar must not either: the
            // sweep is the claim "work is happening", and pausing withdraws
            // exactly that claim.
            return TerminalCommandProgressPresentation(fill: fill, tone: .paused, motion: .still)
        }
    }
}
