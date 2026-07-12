import Foundation

final class TmuxPaneSession: TerminalSession, @unchecked Sendable {
    private static let maximumUTF8ScalarBytes = 4

    var onOutput: ((String) -> Void)? {
        get {
            pendingOutputLock.lock()
            defer { pendingOutputLock.unlock() }
            return outputHandler
        }
        set {
            pendingOutputLock.lock()
            outputHandler = newValue
            let shouldSchedule = newValue != nil && !pendingOutput.isEmpty && !isOutputDrainScheduled
            if shouldSchedule { isOutputDrainScheduled = true }
            pendingOutputLock.unlock()
            if shouldSchedule { scheduleOutputDrain() }
        }
    }
    var onRawOutput: ((Data) -> Void)?
    var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let writeHandler: (String) -> Void
    private let resizeHandler: (Int, Int) -> Void
    private let stopHandler: () -> Void
    private let pendingOutputLock = NSLock()
    private var outputHandler: ((String) -> Void)?
    private var pendingOutput: TmuxBoundedOutputHistory
    private var isOutputDrainScheduled = false

    init(
        writeHandler: @escaping (String) -> Void,
        resizeHandler: @escaping (Int, Int) -> Void,
        stopHandler: @escaping () -> Void,
        pendingOutputByteLimit: Int = TmuxPaneState.defaultOutputHistoryByteLimit
    ) {
        self.writeHandler = writeHandler
        self.resizeHandler = resizeHandler
        self.stopHandler = stopHandler
        pendingOutput = TmuxBoundedOutputHistory(byteLimit: pendingOutputByteLimit)
    }

    func start(workingDirectory: String) {}

    func write(_ text: String) {
        writeHandler(text)
    }

    func foregroundProcessName() -> String? {
        "tmux"
    }

    func canReceiveTerminalResponseWithoutEcho() -> Bool {
        true
    }

    func resize(columns: Int, rows: Int) {
        resizeHandler(columns, rows)
    }

    func stop() {
        stopHandler()
    }

    func receive(_ text: String) {
        receive(Data(text.utf8))
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingOutputLock.lock()
        pendingOutput.append(data)
        let shouldSchedule = outputHandler != nil && !isOutputDrainScheduled
        if shouldSchedule { isOutputDrainScheduled = true }
        pendingOutputLock.unlock()
        if shouldSchedule { scheduleOutputDrain() }
    }

    private func scheduleOutputDrain() {
        DispatchQueue.main.async { [weak self] in
            self?.drainPendingOutput()
        }
    }

    private func drainPendingOutput() {
        pendingOutputLock.lock()
        guard let outputHandler else {
            isOutputDrainScheduled = false
            pendingOutputLock.unlock()
            return
        }
        guard let decoded = takeDecodedPendingOutput() else {
            isOutputDrainScheduled = false
            pendingOutputLock.unlock()
            return
        }
        isOutputDrainScheduled = false
        pendingOutputLock.unlock()

        onRawOutput?(decoded.data)
        outputHandler(decoded.text)
    }

    private func takeDecodedPendingOutput() -> (data: Data, text: String)? {
        let data = pendingOutput.data
        guard !data.isEmpty else {
            pendingOutput.removeAll()
            return nil
        }
        if let text = String(data: data, encoding: .utf8) {
            pendingOutput.removeAll()
            return (data, text)
        }

        let retainedSuffixLimit = min(Self.maximumUTF8ScalarBytes, data.count)
        if data.count > 1 {
            for suffixByteCount in 1...retainedSuffixLimit {
                let prefixByteCount = data.count - suffixByteCount
                guard prefixByteCount > 0 else { continue }
                let prefix = Data(data.prefix(prefixByteCount))
                if let text = String(data: prefix, encoding: .utf8) {
                    let suffix = Data(data.suffix(suffixByteCount))
                    pendingOutput.removeAll()
                    pendingOutput.append(suffix)
                    return (prefix, text)
                }
            }
        }

        guard data.count > Self.maximumUTF8ScalarBytes else { return nil }
        let prefixByteCount = data.count - Self.maximumUTF8ScalarBytes
        let prefix = Data(data.prefix(prefixByteCount))
        let suffix = Data(data.suffix(Self.maximumUTF8ScalarBytes))
        pendingOutput.removeAll()
        pendingOutput.append(suffix)
        return (prefix, String(decoding: prefix, as: UTF8.self))
    }

    func finish(exitStatus: Int32 = 0) {
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(exitStatus)
        }
    }
}
