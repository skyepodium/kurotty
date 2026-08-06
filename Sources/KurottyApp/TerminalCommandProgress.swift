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
        /// Nothing said how far along the command is, so the bar sweeps.
        case indeterminate
        /// A real fraction of the pane's width, 0...1.
        case fraction(Double)
    }

    enum Tone: Equatable {
        case running
        case failed
        case paused
    }

    let fill: Fill
    let tone: Tone
}

/// Command lifecycle as the pane's progress bar needs it, forwarded by the
/// surface so the bar never has to reach into terminal state itself.
enum TerminalCommandProgressEvent: Equatable {
    case commandStarted
    case reported(TerminalCommandProgressReport)
    case commandEnded(exitCode: Int?)
}

/// Decides whether a pane shows a progress bar, and what it shows.
///
/// Pure value type on purpose: this is the whole visibility contract, and it
/// has to be assertable without a window, a PTY, or a clock. Every decision is
/// driven by OSC 133 command boundaries and OSC 9;4 reports — never by output
/// volume or a quiet timer, which are exactly the guesses that make other
/// terminals show a busy bar for a command that already returned.
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

    private enum Phase: Equatable {
        case idle
        case running(since: Date)
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
        failureLingerSeconds: TimeInterval
    ) {
        self.isEnabled = isEnabled
        self.appearanceDelaySeconds = appearanceDelaySeconds
        self.failureLingerSeconds = failureLingerSeconds
    }

    mutating func commandDidStart(at date: Date) {
        phase = .running(since: date)
        // A new command's progress is its own; the last one's number must never
        // be inherited by the next prompt.
        report = nil
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
            return TerminalCommandProgressPresentation(fill: .fraction(1), tone: .failed)
        case .running(let since):
            if let report {
                // An explicit report is the producer declaring a long operation,
                // so it skips the delay: the number is already meaningful.
                return Self.presentation(for: report)
            }
            guard now.timeIntervalSince(since) >= appearanceDelaySeconds else {
                return nil
            }
            return TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running)
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
        case .running(let since):
            guard report == nil else {
                return nil
            }
            let appearsAt = since.addingTimeInterval(appearanceDelaySeconds)
            return now < appearsAt ? appearsAt : nil
        }
    }

    private static func presentation(
        for report: TerminalCommandProgressReport
    ) -> TerminalCommandProgressPresentation {
        let fill: TerminalCommandProgressPresentation.Fill = report.percent
            .map { .fraction(Double($0) / Double(TerminalCommandProgressReport.maximumPercent)) }
            ?? .indeterminate
        switch report.state {
        case .cleared, .set:
            return TerminalCommandProgressPresentation(fill: fill, tone: .running)
        case .error:
            return TerminalCommandProgressPresentation(fill: fill, tone: .failed)
        case .indeterminate:
            // The producer said "working, no number"; a percentage sent
            // alongside state 3 would contradict the state itself.
            return TerminalCommandProgressPresentation(fill: .indeterminate, tone: .running)
        case .paused:
            return TerminalCommandProgressPresentation(fill: fill, tone: .paused)
        }
    }
}
