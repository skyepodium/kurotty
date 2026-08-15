import Foundation
import KurottyCore

/// Memoizes URL and file-path link detection per visible logical line.
///
/// `TerminalLinkRange.findAll` joins a logical line into a string and runs two
/// regular expressions over it. Doing that for every visible line on every
/// renderer frame made link detection the single largest per-keystroke cost on
/// the main thread, so the surface caches each line's result and only re-runs
/// detection for lines whose inputs changed.
///
/// Lifecycle contract:
/// - Entries are keyed by everything the detection result depends on: the
///   line's printable text, its wrap structure, explicit OSC 8 link metadata,
///   and the working directory used for file-path resolution.
/// - Capacity is bounded to the lines referenced by the two most recent frames.
///   `beginFrame()` retires the older generation, so a line that scrolls out of
///   view stops occupying memory after two frames.
/// - File-exists probe answers arrive asynchronously and change file-link
///   resolution for unchanged text; the owner must call `removeAll()` when a
///   probe result lands.
@MainActor
final class TerminalVisibleLinkCache {
    struct Key: Hashable {
        /// Printable (non-continuation) characters of the logical line.
        private let lineText: String
        /// Cell count per screen row, so the same text split across different
        /// wrap boundaries cannot reuse another line's cell-range mapping.
        private let rowLengths: [Int]
        /// Explicit OSC 8 hyperlink metadata in character order.
        private let explicitLinks: [ExplicitLink]
        /// File-path candidates resolve relative to the working directory.
        private let workingDirectory: String?

        struct ExplicitLink: Hashable {
            let characterOffset: Int
            let urlString: String
        }

        init(rows: [[TerminalScreenCell]], workingDirectory: String?) {
            var text = ""
            text.reserveCapacity(rows.reduce(0) { $0 + $1.count })
            var links: [ExplicitLink] = []
            var lengths: [Int] = []
            lengths.reserveCapacity(rows.count)
            var characterOffset = 0
            for row in rows {
                lengths.append(row.count)
                for cell in row where !cell.isContinuation {
                    text.append(cell.character)
                    if let urlString = cell.linkURL {
                        links.append(ExplicitLink(
                            characterOffset: characterOffset,
                            urlString: urlString
                        ))
                    }
                    characterOffset += 1
                }
            }
            lineText = text
            rowLengths = lengths
            explicitLinks = links
            self.workingDirectory = workingDirectory
        }
    }

    private var previousFrameLines: [Key: [TerminalLinkRange]] = [:]
    private var currentFrameLines: [Key: [TerminalLinkRange]] = [:]

    /// Rotates the generations. Entries the previous frame used stay reusable
    /// for exactly one more frame; anything older is released.
    func beginFrame() {
        previousFrameLines = currentFrameLines
        currentFrameLines.removeAll(keepingCapacity: true)
    }

    /// Returns the cached ranges for `key`, running `detectLinks` only when
    /// neither the current nor the previous frame computed this line.
    /// Ranges are stored relative to the logical line's first row.
    func ranges(for key: Key, detectLinks: () -> [TerminalLinkRange]) -> [TerminalLinkRange] {
        if let cached = currentFrameLines[key] ?? previousFrameLines[key] {
            currentFrameLines[key] = cached
            return cached
        }
        let detected = detectLinks()
        currentFrameLines[key] = detected
        return detected
    }

    /// Drops every entry. Called when an asynchronous input to detection (a
    /// file-exists probe answer) changes without the line text changing.
    func removeAll() {
        previousFrameLines.removeAll(keepingCapacity: true)
        currentFrameLines.removeAll(keepingCapacity: true)
    }

    /// Bounded-capacity evidence for tests and diagnostics.
    var retainedLineCount: Int {
        var keys = Set(currentFrameLines.keys)
        keys.formUnion(previousFrameLines.keys)
        return keys.count
    }
}
