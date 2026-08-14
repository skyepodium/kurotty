import Foundation

/// Runs the command that produces a picker's choices.
///
/// Separate from the terminal's own shell on purpose. The listing is not
/// something the user asked to see — it is how the picker fills itself — so it
/// must not appear in the scrollback, must not disturb the prompt, and must not
/// inherit whatever half-typed line is sitting there. It runs in its own
/// process and its output goes to the picker.
///
/// The *chosen* command is the opposite: that one goes to the real shell, in
/// the real session, so what the person ends up in is an ordinary terminal.
final class QuickCommandPickRunner {
    private enum Limit {
        /// How long a listing may take before the picker gives up.
        ///
        /// A cluster on the other side of a VPN is slow, and a cluster that is
        /// unreachable never answers at all. Fifteen seconds is long enough for
        /// the first and short enough that the second does not look like a
        /// hang.
        static let deadlineSECONDS: TimeInterval = 15
        /// Largest listing the picker will read.
        ///
        /// `kubectl get pods -A -o json` on a large cluster is tens of
        /// megabytes of JSON describing thousands of pods nobody is going to
        /// scroll through. Past this the answer is a narrower command, not more
        /// memory.
        static let outputBYTES = 8 * 1024 * 1024
    }

    enum Failure: Error, Equatable {
        /// The command exited non-zero. Its standard error is carried, because
        /// `error: You must be logged in to the server` is the whole answer and
        /// hiding it would leave an empty picker with no explanation.
        case failed(status: Int32, message: String)
        case timedOut
        case tooMuchOutput
    }

    private let shellURL: URL

    init(shellURL: URL = URL(fileURLWithPath: "/bin/sh")) {
        self.shellURL = shellURL
    }

    /// Runs a listing command and returns its standard output.
    ///
    /// - Parameter workingDirectory: the pane's directory, so a command that
    ///   depends on where you are — a kubeconfig in a repo, a compose file —
    ///   behaves the way it would if you had typed it.
    func run(
        _ command: String,
        workingDirectory: URL,
        completion: @escaping @Sendable (Result<Data, Failure>) -> Void
    ) {
        let process = Process()
        process.executableURL = shellURL
        // `-l` is deliberately absent. A login shell would source the user's
        // profile, which for most people prints things, changes directories, or
        // takes a second — none of which a listing command should inherit.
        process.arguments = ["-c", command]
        process.currentDirectoryURL = workingDirectory

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        // Boxed because the termination handler is a `@Sendable` closure and a
        // work item is not: the box is what crosses, and only the one thread
        // that fires first ever touches it.
        let deadline = UncheckedBox(DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else {
                return
            }
            process.terminate()
        })
        DispatchQueue.global().asyncAfter(
            deadline: .now() + Limit.deadlineSECONDS,
            execute: deadline.value
        )

        process.terminationHandler = { finished in
            deadline.value.cancel()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

            DispatchQueue.main.async {
                guard data.count <= Limit.outputBYTES else {
                    return completion(.failure(.tooMuchOutput))
                }
                // A terminated process reports a signal rather than a status,
                // and the only signal this sends is the deadline's.
                guard finished.terminationReason != .uncaughtSignal else {
                    return completion(.failure(.timedOut))
                }
                guard finished.terminationStatus == 0 else {
                    return completion(.failure(.failed(
                        status: finished.terminationStatus,
                        message: message.trimmingCharacters(in: .whitespacesAndNewlines)
                    )))
                }
                completion(.success(data))
            }
        }

        do {
            try process.run()
        } catch {
            deadline.value.cancel()
            DispatchQueue.main.async {
                completion(.failure(.failed(status: -1, message: error.localizedDescription)))
            }
        }
    }
}

/// Carries a value that is not `Sendable` across a boundary the compiler cannot
/// check, where the surrounding code guarantees only one thread touches it.
///
/// Used for exactly one thing here: a `DispatchWorkItem` that either fires or is
/// cancelled, never both, and never from two places at once.
private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
