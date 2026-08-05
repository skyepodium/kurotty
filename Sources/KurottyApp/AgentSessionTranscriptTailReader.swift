import Foundation

/// One JSONL record plus where it started in the file.
struct AgentTranscriptLine: Equatable, Sendable {
    var text: String
    var byteOffset: Int
}

/// Reads the newest records of a JSONL transcript by walking backwards in
/// fixed-size chunks.
///
/// The file is never read whole: the reader starts at the last complete line
/// end, walks back one chunk at a time splitting on `\n`, and stops as soon as
/// it has `limit` records. Partial and oversized records are dropped rather
/// than surfaced, so a truncated write in progress cannot corrupt the view.
///
/// Every entry point is synchronous and must be called off the main actor.
enum AgentSessionTranscriptTailReader {
    struct Result: Equatable, Sendable {
        /// Records in chronological order.
        var lines: [AgentTranscriptLine]
        /// Byte offset of the end of the last complete record read.
        var consumedTo: Int
        /// True when older records exist before `lines`.
        var hasMore: Bool
        var oversizedRecordCount: Int

        static let empty = Result(lines: [], consumedTo: 0, hasMore: false, oversizedRecordCount: 0)
    }

    static func readTail(
        fileURL: URL,
        limit: Int = AppConstants.AgentTranscript.initialTailRecordCount,
        chunkBytes: Int = AppConstants.AgentTranscript.tailChunkBytes,
        maximumRecordBytes: Int = AppConstants.AgentTranscript.maximumRecordBytes
    ) -> Result {
        guard limit > 0,
              let handle = try? FileHandle(forReadingFrom: fileURL),
              let size = try? handle.seekToEnd(),
              size > 0
        else {
            return .empty
        }
        defer { try? handle.close() }

        let end = Int(size)
        let chunkBytes = max(1, chunkBytes)
        // A trailing partial record (a write still in flight) is excluded by
        // starting at the last newline.
        guard let consumedTo = lastCompleteLineEnd(handle: handle, end: end, chunkBytes: chunkBytes),
              consumedTo > 0
        else {
            return .empty
        }

        var newestFirst: [AgentTranscriptLine] = []
        var oversizedRecordCount = 0
        var pendingParts: [Data] = []
        var pendingBytes = 0
        var isPendingOversized = false
        // `consumedTo` points just past the final newline, which is not part of
        // any record.
        var cursor = consumedTo - 1
        var segmentEnd = cursor

        func retain(_ part: Data) {
            guard !isPendingOversized else {
                return
            }
            pendingBytes += part.count
            guard pendingBytes <= maximumRecordBytes else {
                pendingParts.removeAll()
                isPendingOversized = true
                oversizedRecordCount += 1
                return
            }
            pendingParts.append(part)
        }

        func flush(startOffset: Int) {
            defer {
                pendingParts.removeAll()
                pendingBytes = 0
                isPendingOversized = false
            }
            guard !isPendingOversized else {
                return
            }
            var joined = Data()
            for part in pendingParts.reversed() {
                joined.append(part)
            }
            if joined.last == UInt8(ascii: "\r") {
                joined.removeLast()
            }
            guard !joined.isEmpty else {
                return
            }
            newestFirst.append(AgentTranscriptLine(
                text: String(decoding: joined, as: UTF8.self),
                byteOffset: startOffset
            ))
        }

        while cursor > 0, newestFirst.count <= limit {
            let start = max(0, cursor - chunkBytes)
            guard (try? handle.seek(toOffset: UInt64(start))) != nil,
                  let buffer = try? handle.read(upToCount: cursor - start),
                  !buffer.isEmpty
            else {
                break
            }
            let bytes = [UInt8](buffer)
            var localEnd = segmentEnd - start
            var index = bytes.count - 1
            while index >= 0, newestFirst.count <= limit {
                if bytes[index] == UInt8(ascii: "\n") {
                    retain(Data(bytes[(index + 1)..<max(index + 1, localEnd)]))
                    flush(startOffset: start + index + 1)
                    localEnd = index
                }
                index -= 1
            }
            if localEnd > 0 {
                retain(Data(bytes[0..<localEnd]))
            }
            cursor = start
            segmentEnd = start
        }
        if cursor == 0, newestFirst.count <= limit {
            flush(startOffset: 0)
        }

        let hasMore = newestFirst.count > limit
        let selected = Array(newestFirst.prefix(limit)).reversed()
        return Result(
            lines: Array(selected),
            consumedTo: consumedTo,
            hasMore: hasMore,
            oversizedRecordCount: oversizedRecordCount
        )
    }

    /// Offset just past the last `\n`, or `end` when the file already ends with
    /// one. Returns `nil` when the file has no newline at all.
    static func lastCompleteLineEnd(handle: FileHandle, end: Int, chunkBytes: Int) -> Int? {
        guard end > 0,
              (try? handle.seek(toOffset: UInt64(end - 1))) != nil,
              let lastByte = try? handle.read(upToCount: 1),
              let byte = lastByte.first
        else {
            return nil
        }
        if byte == UInt8(ascii: "\n") {
            return end
        }
        var cursor = end
        while cursor > 0 {
            let start = max(0, cursor - chunkBytes)
            guard (try? handle.seek(toOffset: UInt64(start))) != nil,
                  let buffer = try? handle.read(upToCount: cursor - start)
            else {
                return nil
            }
            if let offset = [UInt8](buffer).lastIndex(of: UInt8(ascii: "\n")) {
                return start + offset + 1
            }
            cursor = start
        }
        return nil
    }
}

/// Forward tail-follow: reads only what was appended since the previous call.
///
/// State is the same triple Orca keeps — current offset, buffered bytes of the
/// record straddling a read boundary, and whether that record is being dropped
/// for exceeding the record cap. A file that shrank was replaced or rotated, so
/// the state resets and the caller re-reads the tail.
struct AgentSessionTranscriptIncrementalReader: Sendable {
    private(set) var offset: Int
    private var pendingParts: [Data] = []
    private var pendingStart: Int
    private var pendingBytes = 0
    private var isDroppingOversizedRecord = false
    private(set) var oversizedRecordCount = 0
    private let maximumRecordBytes: Int

    init(
        offset: Int = 0,
        maximumRecordBytes: Int = AppConstants.AgentTranscript.maximumRecordBytes
    ) {
        self.offset = offset
        pendingStart = offset
        self.maximumRecordBytes = maximumRecordBytes
    }

    mutating func reset(offset: Int = 0) {
        self.offset = offset
        pendingParts.removeAll()
        pendingStart = offset
        pendingBytes = 0
        isDroppingOversizedRecord = false
    }

    /// Detects replacement or truncation. Callers re-run a tail read when this
    /// returns true.
    mutating func resetIfFileShrank(fileSizeBytes: Int) -> Bool {
        guard fileSizeBytes < offset else {
            return false
        }
        reset()
        return true
    }

    /// Complete records appended since the last call. Never called on the main
    /// actor.
    mutating func readAppendedLines(fileURL: URL) -> [AgentTranscriptLine] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL),
              let size = try? handle.seekToEnd()
        else {
            return []
        }
        defer { try? handle.close() }

        let end = Int(size)
        guard end > offset,
              (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let appended = try? handle.read(upToCount: end - offset),
              !appended.isEmpty
        else {
            return []
        }

        var lines: [AgentTranscriptLine] = []
        let bytes = [UInt8](appended)
        var segmentStart = 0
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\n") else {
                index += 1
                continue
            }
            retain(Data(bytes[segmentStart..<index]))
            if let line = flush() {
                lines.append(line)
            }
            segmentStart = index + 1
            pendingStart = offset + segmentStart
            index += 1
        }
        if segmentStart < bytes.count {
            retain(Data(bytes[segmentStart...]))
        }
        offset += bytes.count
        return lines
    }

    private mutating func retain(_ part: Data) {
        guard !isDroppingOversizedRecord else {
            return
        }
        pendingBytes += part.count
        guard pendingBytes <= maximumRecordBytes else {
            pendingParts.removeAll()
            isDroppingOversizedRecord = true
            oversizedRecordCount += 1
            return
        }
        pendingParts.append(part)
    }

    private mutating func flush() -> AgentTranscriptLine? {
        defer {
            pendingParts.removeAll()
            pendingBytes = 0
            isDroppingOversizedRecord = false
        }
        guard !isDroppingOversizedRecord else {
            return nil
        }
        var joined = Data()
        for part in pendingParts {
            joined.append(part)
        }
        if joined.last == UInt8(ascii: "\r") {
            joined.removeLast()
        }
        guard !joined.isEmpty else {
            return nil
        }
        return AgentTranscriptLine(
            text: String(decoding: joined, as: UTF8.self),
            byteOffset: pendingStart
        )
    }
}
