import Foundation

/// Anything that can absorb restored scrollback bytes for display.
///
/// The contract is narrow on purpose. A replay is **display only**: bytes go
/// into the screen model and nothing goes back out to the shell. `isReplayingScrollback`
/// is the flag the interpreter/surface consults to suppress terminal capability
/// replies (DA/DSR/cursor-position answers) while restored output is parsed, so
/// a freshly launched shell can never receive an answer to a query that was
/// asked in a previous process.
///
/// The seam exists so the restore path is testable without an interpreter; the
/// real conformances are declared below.
@MainActor
protocol TerminalScrollbackReplayTarget: AnyObject {
    /// True only while restored bytes are being parsed.
    var isReplayingScrollback: Bool { get set }
    /// Feeds restored bytes into the screen model.
    func consumeReplayedScrollback(_ text: String)
}

/// The interpreter already owns `isReplayingScrollback` as the single choke
/// point that drops DA1/DA2/CPR/XTWINOPS/DECRPM replies and OSC query answers.
/// Conformance lives here rather than in the interpreter so the replay contract
/// stays in one file.
extension TerminalOutputInterpreter: TerminalScrollbackReplayTarget {
    func consumeReplayedScrollback(_ text: String) {
        interpret(text)
    }
}

// `TerminalSurfaceView` mirrors the same flag but keeps its interpreter
// private and exposes no public byte-ingest entry point, so a pane-level
// conformance needs one line in that file:
//
//     func consumeReplayedScrollback(_ text: String) { interpreter.interpret(text) }
//
// Until then the restore path replays through the interpreter directly.

/// Closure-shaped adapter for hosts that are not reference types or that want
/// to route replay through their own entry point.
@MainActor
final class TerminalScrollbackReplayClosureTarget: TerminalScrollbackReplayTarget {
    var isReplayingScrollback = false
    private let consume: (String) -> Void

    init(consume: @escaping (String) -> Void) {
        self.consume = consume
    }

    func consumeReplayedScrollback(_ text: String) {
        consume(text)
    }
}

/// Outcome of one pane's replay, surfaced for diagnostics and tests.
struct TerminalScrollbackReplayReport: Equatable {
    var byteCount: Int
    var didMarkReplayFlag: Bool
    var isFlagClearedAfterReplay: Bool

    static let skipped = TerminalScrollbackReplayReport(
        byteCount: 0,
        didMarkReplayFlag: false,
        isFlagClearedAfterReplay: true
    )
}

/// Feeds a stored snapshot into a pane with the replay flag raised.
///
/// The flag is raised before the first byte is parsed and lowered on every
/// exit path, including a throwing or empty payload, so a partially replayed
/// pane can never be left in a state where the shell stops receiving real
/// capability replies.
@MainActor
enum TerminalScrollbackReplayer {
    @discardableResult
    static func replay(
        payload: Data,
        into target: TerminalScrollbackReplayTarget
    ) -> TerminalScrollbackReplayReport {
        guard !payload.isEmpty else {
            return .skipped
        }
        let text = String(decoding: payload, as: UTF8.self)
        guard !text.isEmpty else {
            return .skipped
        }

        target.isReplayingScrollback = true
        defer { target.isReplayingScrollback = false }
        target.consumeReplayedScrollback(text)
        return TerminalScrollbackReplayReport(
            byteCount: payload.count,
            didMarkReplayFlag: true,
            isFlagClearedAfterReplay: false
        )
    }

    /// Convenience used by the restore path: reads the pane's snapshot and
    /// replays it, reporting `.skipped` when nothing is stored.
    @discardableResult
    static func replay(
        ref: String,
        from store: TerminalScrollbackSnapshotStore,
        into target: TerminalScrollbackReplayTarget
    ) -> TerminalScrollbackReplayReport {
        guard let payload = store.readReplayPayload(ref: ref) else {
            return .skipped
        }
        var report = replay(payload: payload, into: target)
        report.isFlagClearedAfterReplay = target.isReplayingScrollback == false
        return report
    }
}

/// Settings contract for scrollback restore.
///
/// Kurotty's settings schema lives in `AppSettings`/`SettingsDefaults`, owned by
/// another agent this wave, so the key and its default are declared here and
/// listed in the handoff report for migration. The lifecycle contract is
/// **launch-only**: the value is read once while restoring a workspace.
enum TerminalScrollbackRestoreSetting {
    static let keyPath = "terminal.restoreScrollbackOnLaunch"
    static let defaultValue = true

    /// Replaying scrollback *bytes* is display-only and therefore safe by
    /// default. Replaying *commands* stays a separate opt-in governed by
    /// `TerminalCommandReplayPolicy`; the two must never be collapsed into one
    /// switch.
    static func shouldRestoreScrollback(isEnabled: Bool = defaultValue) -> Bool {
        isEnabled
    }
}
