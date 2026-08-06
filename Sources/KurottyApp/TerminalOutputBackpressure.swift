import Foundation

/// Decides when the PTY reader must stop draining the kernel buffer.
///
/// A terminal gets flow control from the OS for free: once the PTY buffer
/// fills, a child that outruns its reader blocks in `write(2)`. A reader that
/// always drains to `EAGAIN` defeats that, so `yes` or `cat` of a large file
/// stops being kernel backpressure and becomes unbounded in-process buffering.
/// Suspending the read source hands the flow control back to the kernel.
///
/// The whole decision lives here, free of Dispatch and file descriptors, so the
/// hysteresis is testable without a PTY. Callers own the suspend/resume calls
/// because those must stay balanced, which is a lifetime concern rather than a
/// policy one.
struct TerminalOutputBackpressurePolicy: Equatable, Sendable {
    enum ReaderState: Equatable, Sendable {
        case reading
        case suspended
    }

    enum Action: Equatable, Sendable {
        case none
        case suspendReader
        case resumeReader
    }

    static let `default` = TerminalOutputBackpressurePolicy(
        highWaterMarkBytes: AppConstants.Shell.outputHighWaterMarkBytes,
        lowWaterMarkBytes: AppConstants.Shell.outputLowWaterMarkBytes,
        maximumBytesPerDrain: AppConstants.Shell.outputMaximumBytesPerDrain
    )

    let highWaterMarkBytes: Int
    let lowWaterMarkBytes: Int
    /// Ceiling on one drain pass. Without it a single event-handler invocation
    /// can read past the high-water mark before anyone re-evaluates the policy,
    /// which is how an uncapped drain loop outruns the renderer in the first
    /// place.
    let maximumBytesPerDrain: Int

    /// `lowWaterMarkBytes` is clamped strictly below `highWaterMarkBytes`:
    /// equal marks would suspend and resume at the same byte count, which is
    /// exactly the thrash this type exists to avoid.
    init(highWaterMarkBytes: Int, lowWaterMarkBytes: Int, maximumBytesPerDrain: Int) {
        let high = max(1, highWaterMarkBytes)
        self.highWaterMarkBytes = high
        self.lowWaterMarkBytes = min(max(0, lowWaterMarkBytes), high - 1)
        self.maximumBytesPerDrain = max(1, maximumBytesPerDrain)
    }

    func action(
        pendingBytes: Int,
        state: ReaderState
    ) -> Action {
        switch state {
        case .reading:
            return pendingBytes >= highWaterMarkBytes ? .suspendReader : .none
        case .suspended:
            return pendingBytes <= lowWaterMarkBytes ? .resumeReader : .none
        }
    }

    func nextState(pendingBytes: Int, state: ReaderState) -> ReaderState {
        switch action(pendingBytes: pendingBytes, state: state) {
        case .none:
            return state
        case .suspendReader:
            return .suspended
        case .resumeReader:
            return .reading
        }
    }

    /// Whether the drain loop may pull one more chunk out of the kernel buffer.
    ///
    /// `pendingBytes` must already include `bytesReadThisDrain`, so the loop
    /// stops at the same high-water mark the suspend decision uses instead of
    /// overshooting it by a whole drain.
    func allowsAdditionalRead(pendingBytes: Int, bytesReadThisDrain: Int) -> Bool {
        bytesReadThisDrain < maximumBytesPerDrain && pendingBytes < highWaterMarkBytes
    }
}

/// Observable counters for the PTY reader's flow control.
///
/// `droppedByteCount` must stay at zero while suspension works: dropping bytes
/// mid-escape-sequence corrupts screen state, so a non-zero count is a bug
/// report, not a tuning knob. It is surfaced rather than swallowed for exactly
/// that reason.
struct TerminalOutputBackpressureDiagnostics: Equatable, CustomStringConvertible, Sendable {
    var isReaderSuspended = false
    var pendingByteCount = 0
    var peakPendingByteCount = 0
    var suspendCount = 0
    var resumeCount = 0
    var droppedByteCount = 0

    var description: String {
        [
            "readerSuspended=\(isReaderSuspended)",
            "pendingBytes=\(pendingByteCount)",
            "peakPendingBytes=\(peakPendingByteCount)",
            "suspends=\(suspendCount)",
            "resumes=\(resumeCount)",
            "droppedBytes=\(droppedByteCount)",
        ].joined(separator: " ")
    }
}
