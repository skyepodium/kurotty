import CryptoKit
import Foundation

/// On-disk format and byte budgets for per-pane scrollback snapshots.
///
/// A snapshot is a content-addressed file holding the trailing bytes of a
/// pane's scrollback rendered back into terminal output. Two budgets are kept
/// deliberately separate:
///
/// - the **store** budget bounds what is written to disk for one pane, so a
///   long-lived pane cannot grow an unbounded file;
/// - the **replay** budget bounds what is read back and fed to the screen model
///   at launch, so restoring a window never stalls on megabytes of text.
///
/// Both clipping paths take the *trailing* portion and never split a UTF-8
/// scalar: a clip that lands inside a multi-byte sequence walks forward past
/// the `10xxxxxx` continuation bytes first, matching the reference behavior in
/// Orca's `terminal-scrollback-snapshots.ts`.
enum TerminalScrollbackSnapshotFormat {
    /// Directory under `Application Support/Kurotty` that holds snapshot files.
    static let directoryName = AppConstants.TerminalScrollbackSnapshots.directoryName
    /// V2 drops styled trailing blanks so prompt backgrounds cannot expand
    /// into large color blocks when scrollback is replayed on launch.
    static let refPrefix = "v2"
    static let fileExtension = "bin"
    /// Hex characters retained from the SHA-256 digest.
    static let refHashCharacterCount = 32
    /// Byte written between serialized rows. Terminal output uses CRLF so a
    /// replayed row starts at column zero regardless of newline mode.
    static let rowSeparator = "\r\n"

    enum Budget {
        /// Largest snapshot written for one pane.
        static let storeBytesPerPane = AppConstants.TerminalScrollbackSnapshots.storeBytesPerPane
        /// Largest snapshot replayed into one pane at restore.
        static let replayBytesPerPane = AppConstants.TerminalScrollbackSnapshots.replayBytesPerPane
        /// Largest total size of the snapshot directory. Pruning drops the
        /// least recently modified files until the directory fits.
        static let totalStoreBytes = AppConstants.TerminalScrollbackSnapshots.totalStoreBytes
    }

    /// Content address for one pane: `sha256(tabID \0 paneID)`, truncated to
    /// `refHashCharacterCount` hex characters. Stable across launches so a
    /// restored layout finds the same file, and collision-free in practice for
    /// the few hundred panes a workspace can hold.
    static func ref(tabID: String, paneID: String) -> String {
        var input = Data(tabID.utf8)
        input.append(0)
        input.append(contentsOf: Array(paneID.utf8))
        let digest = SHA256.hash(data: input)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(refPrefix)-\(hex.prefix(refHashCharacterCount))"
    }

    /// True only for a well-formed `v2-<32 hex>` reference. Every filesystem
    /// path is derived through this guard so a hostile or corrupted snapshot
    /// value can never escape the snapshot directory.
    static func isValidRef(_ ref: String) -> Bool {
        let expectedPrefix = "\(refPrefix)-"
        guard ref.count == expectedPrefix.count + refHashCharacterCount,
              ref.hasPrefix(expectedPrefix)
        else {
            return false
        }
        return ref.dropFirst(expectedPrefix.count).allSatisfy { character in
            character.isHexDigit && !character.isUppercase
        }
    }

    static func fileName(forRef ref: String) -> String? {
        guard isValidRef(ref) else {
            return nil
        }
        return "\(ref).\(fileExtension)"
    }

    /// Trailing `maximumBytes` of `data`, advanced forward so the result never
    /// begins inside a multi-byte UTF-8 scalar.
    static func trailingUTF8Bytes(_ data: Data, maximumBytes: Int) -> Data {
        guard maximumBytes > 0 else {
            return Data()
        }
        guard data.count > maximumBytes else {
            return data
        }
        let start = data.count - maximumBytes
        return clippedToScalarBoundary(data.suffix(from: data.startIndex + start))
    }

    /// Drops leading UTF-8 continuation bytes (`10xxxxxx`) so decoding starts on
    /// a scalar boundary.
    static func clippedToScalarBoundary<Bytes: DataProtocol>(_ bytes: Bytes) -> Data {
        var data = Data(bytes)
        var start = data.startIndex
        while start < data.endIndex, isContinuationByte(data[start]) {
            start = data.index(after: start)
        }
        data = Data(data[start...])
        return data
    }

    static func isContinuationByte(_ byte: UInt8) -> Bool {
        byte & 0xc0 == 0x80
    }

    /// Payload actually fed to the screen model: the trailing replay budget,
    /// clipped to a UTF-8 boundary and then advanced to the first row boundary
    /// so replay can never begin in the middle of an SGR sequence emitted by
    /// the serializer.
    static func replayPayload(from stored: Data, maximumBytes: Int = Budget.replayBytesPerPane) -> Data {
        let trailing = trailingUTF8Bytes(stored, maximumBytes: maximumBytes)
        guard trailing.count < stored.count else {
            return trailing
        }
        guard let newline = trailing.firstIndex(of: UInt8(ascii: "\n")) else {
            return Data()
        }
        return Data(trailing[trailing.index(after: newline)...])
    }
}
