import Foundation

struct TmuxMutationQueue: Sendable {
    struct Limits: Equatable, Sendable {
        static let `default` = Limits(
            maximumInputByteCount: 4 * 1024 * 1024,
            maximumPayloadByteCount: 8 * 1024 * 1024,
            maximumStructuralCount: 1_024,
            maximumResizeKeyCount: 512,
            inputChunkByteCount: 16 * 1024,
            normalPopsBeforeResize: 8
        )

        let maximumInputByteCount: Int
        let maximumPayloadByteCount: Int
        let maximumStructuralCount: Int
        let maximumResizeKeyCount: Int
        let inputChunkByteCount: Int
        let normalPopsBeforeResize: Int

        init(
            maximumInputByteCount: Int,
            maximumPayloadByteCount: Int,
            maximumStructuralCount: Int,
            maximumResizeKeyCount: Int,
            inputChunkByteCount: Int,
            normalPopsBeforeResize: Int = 8
        ) {
            self.maximumInputByteCount = max(0, maximumInputByteCount)
            self.maximumPayloadByteCount = max(0, maximumPayloadByteCount)
            self.maximumStructuralCount = max(0, maximumStructuralCount)
            self.maximumResizeKeyCount = max(0, maximumResizeKeyCount)
            self.inputChunkByteCount = max(1, inputChunkByteCount)
            self.normalPopsBeforeResize = max(1, normalPopsBeforeResize)
        }
    }

    enum Mutation: Equatable, Sendable {
        case sendKeys(paneID: String, data: Data)
        case structural(command: Data)
        case resizePane(paneID: String, columns: Int, rows: Int)
        case resizeClient(windowID: String?, columns: Int, rows: Int)
        case detachClient
    }

    enum EnqueueError: Error, Equatable, LocalizedError, Sendable {
        case detaching
        case inputByteLimitExceeded(limit: Int, attempted: Int)
        case payloadByteLimitExceeded(limit: Int, attempted: Int)
        case structuralCountLimitExceeded(limit: Int, attempted: Int)
        case resizeKeyLimitExceeded(limit: Int, attempted: Int)

        var errorDescription: String? {
            switch self {
            case .detaching:
                "tmux mutation queue is detaching"
            case let .inputByteLimitExceeded(limit, attempted):
                "tmux input backlog exceeded \(limit) bytes (attempted \(attempted))"
            case let .payloadByteLimitExceeded(limit, attempted):
                "tmux mutation backlog exceeded \(limit) bytes (attempted \(attempted))"
            case let .structuralCountLimitExceeded(limit, attempted):
                "tmux structural backlog exceeded \(limit) requests (attempted \(attempted))"
            case let .resizeKeyLimitExceeded(limit, attempted):
                "tmux resize backlog exceeded \(limit) targets (attempted \(attempted))"
            }
        }
    }

    struct Metrics: Equatable, Sendable {
        let pendingInputByteCount: Int
        let pendingPayloadByteCount: Int
        let pendingStructuralCount: Int
        let pendingResizeKeyCount: Int
        let pendingNormalEntryCount: Int
        let normalStorageSlotCount: Int
        let resizeStorageSlotCount: Int
        let isDetaching: Bool
    }

    private struct InputBuffer: Sendable {
        let paneID: String
        private var data: Data
        private var startOffset = 0

        init(paneID: String, data: Data) {
            self.paneID = paneID
            self.data = data
        }

        var readableByteCount: Int { data.count - startOffset }

        mutating func append(_ additionalData: Data) {
            compactBeforeAppendingIfNeeded()
            data.append(additionalData)
        }

        mutating func takePrefix(maximumByteCount: Int) -> Data {
            let byteCount = min(readableByteCount, maximumByteCount)
            guard byteCount > 0 else { return Data() }
            let lowerBound = data.index(data.startIndex, offsetBy: startOffset)
            let upperBound = data.index(lowerBound, offsetBy: byteCount)
            let prefix = Data(data[lowerBound..<upperBound])
            startOffset += byteCount
            compactConsumedBytesIfNeeded()
            return prefix
        }

        private mutating func compactBeforeAppendingIfNeeded() {
            guard startOffset > 0 else { return }
            guard startOffset >= data.count / 2 || startOffset >= 64 * 1024 else { return }
            data = Data(data.dropFirst(startOffset))
            startOffset = 0
        }

        private mutating func compactConsumedBytesIfNeeded() {
            guard startOffset > 0 else { return }
            if startOffset == data.count {
                data.removeAll(keepingCapacity: true)
                startOffset = 0
            } else if startOffset >= data.count / 2, startOffset >= 64 * 1024 {
                data = Data(data.dropFirst(startOffset))
                startOffset = 0
            }
        }
    }

    private enum NormalEntry: Sendable {
        case input(InputBuffer)
        case structural(Data)
    }

    private enum ResizeKey: Hashable, Sendable {
        case pane(String)
        case client(String?)

        var payloadByteCount: Int {
            let identifierByteCount: Int
            switch self {
            case let .pane(paneID):
                identifierByteCount = paneID.utf8.count
            case let .client(windowID):
                identifierByteCount = windowID?.utf8.count ?? 0
            }
            return identifierByteCount + (2 * MemoryLayout<Int>.size)
        }
    }

    private enum ResizeValue: Sendable {
        case pane(paneID: String, columns: Int, rows: Int)
        case client(windowID: String?, columns: Int, rows: Int)

        var mutation: Mutation {
            switch self {
            case let .pane(paneID, columns, rows):
                .resizePane(paneID: paneID, columns: columns, rows: rows)
            case let .client(windowID, columns, rows):
                .resizeClient(windowID: windowID, columns: columns, rows: rows)
            }
        }
    }

    private static let compactionMinimumHeadIndex = 256

    let limits: Limits

    private var normalStorage: [NormalEntry?] = []
    private var normalHeadIndex = 0
    private var pendingNormalEntryCount = 0
    private var resizeStorage: [ResizeKey?] = []
    private var resizeHeadIndex = 0
    private var pendingResizes: [ResizeKey: ResizeValue] = [:]
    private var pendingInputByteCount = 0
    private var pendingPayloadByteCount = 0
    private var pendingStructuralCount = 0
    private var consecutiveNormalPopCount = 0
    private var pendingDetach = false
    private(set) var isDetaching = false

    init(limits: Limits = .default) {
        self.limits = limits
    }

    var metrics: Metrics {
        Metrics(
            pendingInputByteCount: pendingInputByteCount,
            pendingPayloadByteCount: pendingPayloadByteCount,
            pendingStructuralCount: pendingStructuralCount,
            pendingResizeKeyCount: pendingResizes.count,
            pendingNormalEntryCount: pendingNormalEntryCount,
            normalStorageSlotCount: normalStorage.count,
            resizeStorageSlotCount: resizeStorage.count,
            isDetaching: isDetaching
        )
    }

    var isEmpty: Bool {
        !pendingDetach && pendingNormalEntryCount == 0 && pendingResizes.isEmpty
    }

    mutating func enqueueInput(paneID: String, data: Data) throws {
        guard !isDetaching else { throw EnqueueError.detaching }
        guard !data.isEmpty else { return }

        let attemptedInputByteCount = Self.boundedSum(pendingInputByteCount, data.count)
        guard attemptedInputByteCount <= limits.maximumInputByteCount else {
            throw EnqueueError.inputByteLimitExceeded(
                limit: limits.maximumInputByteCount,
                attempted: attemptedInputByteCount
            )
        }
        let attemptedPayloadByteCount = Self.boundedSum(pendingPayloadByteCount, data.count)
        guard attemptedPayloadByteCount <= limits.maximumPayloadByteCount else {
            throw EnqueueError.payloadByteLimitExceeded(
                limit: limits.maximumPayloadByteCount,
                attempted: attemptedPayloadByteCount
            )
        }

        if let tailIndex = normalTailIndex,
           case var .input(buffer) = normalStorage[tailIndex],
           buffer.paneID == paneID {
            buffer.append(data)
            normalStorage[tailIndex] = .input(buffer)
        } else {
            normalStorage.append(.input(.init(paneID: paneID, data: data)))
            pendingNormalEntryCount += 1
        }
        pendingInputByteCount = attemptedInputByteCount
        pendingPayloadByteCount = attemptedPayloadByteCount
    }

    mutating func enqueueStructural(command: Data) throws {
        guard !isDetaching else { throw EnqueueError.detaching }
        let attemptedStructuralCount = Self.boundedSum(pendingStructuralCount, 1)
        guard attemptedStructuralCount <= limits.maximumStructuralCount else {
            throw EnqueueError.structuralCountLimitExceeded(
                limit: limits.maximumStructuralCount,
                attempted: attemptedStructuralCount
            )
        }
        let attemptedPayloadByteCount = Self.boundedSum(pendingPayloadByteCount, command.count)
        guard attemptedPayloadByteCount <= limits.maximumPayloadByteCount else {
            throw EnqueueError.payloadByteLimitExceeded(
                limit: limits.maximumPayloadByteCount,
                attempted: attemptedPayloadByteCount
            )
        }

        normalStorage.append(.structural(command))
        pendingNormalEntryCount += 1
        pendingStructuralCount = attemptedStructuralCount
        pendingPayloadByteCount = attemptedPayloadByteCount
    }

    mutating func enqueuePaneResize(paneID: String, columns: Int, rows: Int) throws {
        try enqueueResize(
            key: .pane(paneID),
            value: .pane(paneID: paneID, columns: max(1, columns), rows: max(1, rows))
        )
    }

    mutating func enqueueClientResize(windowID: String?, columns: Int, rows: Int) throws {
        try enqueueResize(
            key: .client(windowID),
            value: .client(windowID: windowID, columns: max(1, columns), rows: max(1, rows))
        )
    }

    mutating func enqueueDetach() {
        guard !isDetaching else { return }
        discardPendingMutations()
        isDetaching = true
        pendingDetach = true
    }

    mutating func popFirst() -> Mutation? {
        if pendingDetach {
            pendingDetach = false
            return .detachClient
        }

        if pendingNormalEntryCount > 0 {
            if !pendingResizes.isEmpty,
               consecutiveNormalPopCount >= limits.normalPopsBeforeResize,
               let resize = popFirstResize() {
                consecutiveNormalPopCount = 0
                return resize
            }
            guard let mutation = popFirstNormal() else { return popFirst() }
            consecutiveNormalPopCount = pendingResizes.isEmpty ? 0 : consecutiveNormalPopCount + 1
            return mutation
        }

        consecutiveNormalPopCount = 0
        return popFirstResize()
    }

    mutating func reset() {
        discardPendingMutations()
        pendingDetach = false
        isDetaching = false
    }

    private var normalTailIndex: Int? {
        guard pendingNormalEntryCount > 0,
              let index = normalStorage.indices.last,
              index >= normalHeadIndex,
              normalStorage[index] != nil
        else { return nil }
        return index
    }

    private mutating func enqueueResize(key: ResizeKey, value: ResizeValue) throws {
        guard !isDetaching else { throw EnqueueError.detaching }
        if pendingResizes[key] != nil {
            pendingResizes[key] = value
            return
        }

        let attemptedResizeKeyCount = Self.boundedSum(pendingResizes.count, 1)
        guard attemptedResizeKeyCount <= limits.maximumResizeKeyCount else {
            throw EnqueueError.resizeKeyLimitExceeded(
                limit: limits.maximumResizeKeyCount,
                attempted: attemptedResizeKeyCount
            )
        }
        let attemptedPayloadByteCount = Self.boundedSum(pendingPayloadByteCount, key.payloadByteCount)
        guard attemptedPayloadByteCount <= limits.maximumPayloadByteCount else {
            throw EnqueueError.payloadByteLimitExceeded(
                limit: limits.maximumPayloadByteCount,
                attempted: attemptedPayloadByteCount
            )
        }

        pendingResizes[key] = value
        resizeStorage.append(key)
        pendingPayloadByteCount = attemptedPayloadByteCount
    }

    private mutating func popFirstNormal() -> Mutation? {
        while normalHeadIndex < normalStorage.count {
            guard let entry = normalStorage[normalHeadIndex] else {
                normalHeadIndex += 1
                continue
            }
            switch entry {
            case var .input(buffer):
                let data = buffer.takePrefix(maximumByteCount: limits.inputChunkByteCount)
                pendingInputByteCount -= data.count
                pendingPayloadByteCount -= data.count
                if buffer.readableByteCount == 0 {
                    normalStorage[normalHeadIndex] = nil
                    normalHeadIndex += 1
                    pendingNormalEntryCount -= 1
                    compactNormalStorageIfNeeded()
                } else {
                    normalStorage[normalHeadIndex] = .input(buffer)
                }
                return .sendKeys(paneID: buffer.paneID, data: data)
            case let .structural(command):
                normalStorage[normalHeadIndex] = nil
                normalHeadIndex += 1
                pendingNormalEntryCount -= 1
                pendingStructuralCount -= 1
                pendingPayloadByteCount -= command.count
                compactNormalStorageIfNeeded()
                return .structural(command: command)
            }
        }
        return nil
    }

    private mutating func popFirstResize() -> Mutation? {
        while resizeHeadIndex < resizeStorage.count {
            guard let key = resizeStorage[resizeHeadIndex] else {
                resizeHeadIndex += 1
                continue
            }
            resizeStorage[resizeHeadIndex] = nil
            resizeHeadIndex += 1
            guard let value = pendingResizes.removeValue(forKey: key) else { continue }
            pendingPayloadByteCount -= key.payloadByteCount
            compactResizeStorageIfNeeded()
            return value.mutation
        }
        return nil
    }

    private mutating func compactNormalStorageIfNeeded() {
        guard normalHeadIndex > 0 else { return }
        if pendingNormalEntryCount == 0 {
            normalStorage.removeAll(keepingCapacity: true)
            normalHeadIndex = 0
        } else if normalHeadIndex >= Self.compactionMinimumHeadIndex,
                  normalHeadIndex >= normalStorage.count / 2 {
            normalStorage = Array(normalStorage[normalHeadIndex...])
            normalHeadIndex = 0
        }
    }

    private mutating func compactResizeStorageIfNeeded() {
        guard resizeHeadIndex > 0 else { return }
        if pendingResizes.isEmpty {
            resizeStorage.removeAll(keepingCapacity: true)
            resizeHeadIndex = 0
        } else if resizeHeadIndex >= Self.compactionMinimumHeadIndex,
                  resizeHeadIndex >= resizeStorage.count / 2 {
            resizeStorage = Array(resizeStorage[resizeHeadIndex...])
            resizeHeadIndex = 0
        }
    }

    private mutating func discardPendingMutations() {
        normalStorage.removeAll(keepingCapacity: true)
        normalHeadIndex = 0
        pendingNormalEntryCount = 0
        resizeStorage.removeAll(keepingCapacity: true)
        resizeHeadIndex = 0
        pendingResizes.removeAll(keepingCapacity: true)
        pendingInputByteCount = 0
        pendingPayloadByteCount = 0
        pendingStructuralCount = 0
        consecutiveNormalPopCount = 0
    }

    private static func boundedSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
