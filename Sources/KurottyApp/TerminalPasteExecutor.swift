import Foundation

/// Optional capability for sessions that can report how much input is still
/// queued for the PTY. A paste writer uses it to stay behind the write path
/// instead of enqueuing a whole clipboard at once.
protocol TerminalSessionInputBackpressureReporting: AnyObject {
    var queuedInputByteCount: Int { get }
}

/// The write side a paste needs, kept narrow so tests can drive it without a
/// real PTY.
@MainActor
protocol TerminalPasteWriting: AnyObject {
    func writePasteChunk(_ text: String)
    /// Bytes still queued for the PTY, or `nil` when the session cannot report
    /// it. `nil` disables pacing but never blocks the paste.
    var queuedPasteByteCount: Int? { get }
}

struct TerminalPasteExecutionResult: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case pasted
        case rejected
        case cancelled
    }

    let status: Status
    let chunksWritten: Int
    let bytesWritten: Int
    /// Counts and modes only; never pasted content.
    let redactedDiagnostic: String
}

/// Writes a planned paste to the PTY in chunks, pausing whenever the session's
/// pending-input queue is above the plan's high-water mark.
@MainActor
enum TerminalPasteExecutor {
    /// One pacing step. Short enough that a paste stays interactive, long
    /// enough that the PTY drain queue makes progress between polls.
    static let backpressurePollNanoseconds: UInt64 = 2_000_000
    /// Bounds how long a single chunk may wait for the PTY before the writer
    /// proceeds anyway, so a stalled reader can never wedge the paste forever.
    static let backpressureMaxPollCount = 500

    static func execute(
        plan: TerminalPastePlan,
        text: String,
        limits: TerminalPasteLimits = .default,
        writer: any TerminalPasteWriting,
        isCancelled: () -> Bool = { false }
    ) async -> TerminalPasteExecutionResult {
        guard plan.isExecutable else {
            return TerminalPasteExecutionResult(
                status: .rejected,
                chunksWritten: 0,
                bytesWritten: 0,
                redactedDiagnostic: plan.redactedDiagnostic
            )
        }

        let chunks = TerminalPastePlanner.chunks(for: plan, text: text)
        var chunksWritten = 0
        var bytesWritten = 0
        for chunk in chunks {
            if isCancelled() {
                return TerminalPasteExecutionResult(
                    status: .cancelled,
                    chunksWritten: chunksWritten,
                    bytesWritten: bytesWritten,
                    redactedDiagnostic: plan.redactedDiagnostic
                )
            }
            await waitForWriteCapacity(writer: writer, limits: limits)
            writer.writePasteChunk(chunk)
            chunksWritten += 1
            bytesWritten += chunk.utf8.count
        }
        return TerminalPasteExecutionResult(
            status: .pasted,
            chunksWritten: chunksWritten,
            bytesWritten: bytesWritten,
            redactedDiagnostic: plan.redactedDiagnostic
        )
    }

    private static func waitForWriteCapacity(
        writer: any TerminalPasteWriting,
        limits: TerminalPasteLimits
    ) async {
        var pollCount = 0
        while let queued = writer.queuedPasteByteCount,
              queued > limits.backpressureHighWaterMarkBytes,
              pollCount < backpressureMaxPollCount {
            pollCount += 1
            try? await Task.sleep(nanoseconds: backpressurePollNanoseconds)
        }
    }
}
