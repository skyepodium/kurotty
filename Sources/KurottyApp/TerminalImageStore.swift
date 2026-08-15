import Foundation

/// The bytes of every image currently on a terminal's screen or in its
/// scrollback, held once.
///
/// **The frame must never carry the bytes.** `TerminalFrame` is a value that is
/// built, copied and handed across an isolation boundary on every frame; a
/// megabyte of PNG inside it would be a megabyte copied sixty times a second
/// for as long as the image stays on screen. Frames carry an id, and this is
/// what the id means.
///
/// Bounded, because a terminal is a place where `cat *.png` is one keystroke. A
/// program can put images on screen faster than a person can scroll them off,
/// so the store keeps a total and drops the oldest images once it is over —
/// which is the same thing scrollback does to rows, and for the same reason.
final class TerminalImageStore {
    /// Identifies one stored image for the length of its life in the store.
    struct Identifier: Hashable, CustomStringConvertible {
        let value: Int

        var description: String {
            String(value)
        }
    }

    struct Entry {
        let data: Data
        /// The file's own name, when the sender supplied one. This is what a
        /// screen reader reads out, so an image without one is announced as an
        /// image and nothing more.
        let name: String?
    }

    private enum Capacity {
        /// How many bytes of image the store will hold before dropping the
        /// oldest.
        ///
        /// Sized against what a screen can actually show rather than against
        /// what a machine can spare: a full window of images at Retina density
        /// is a few tens of megabytes, and anything past that is scrollback
        /// nobody is looking at.
        static let totalBYTES = 64 * 1024 * 1024
    }

    private var entries: [Identifier: Entry] = [:]
    /// Ids in the order they arrived, oldest first. Kept beside the dictionary
    /// because eviction is by age and a dictionary has no order.
    private var order: [Identifier] = []
    private var storedBytes = 0
    private var nextValue = 0

    private(set) var evictionCount = 0

    var count: Int {
        entries.count
    }

    /// Bytes currently held. Exposed so the bound can be asserted against real
    /// traffic rather than trusted.
    var byteCount: Int {
        storedBytes
    }

    /// Takes an image and returns the id the frame will carry.
    ///
    /// An image larger than the whole budget is refused rather than admitted
    /// and then immediately evicted, which would clear the store of everything
    /// else on the way past.
    func store(data: Data, name: String?) -> Identifier? {
        guard !data.isEmpty, data.count <= Capacity.totalBYTES else {
            return nil
        }

        let identifier = Identifier(value: nextValue)
        nextValue += 1
        entries[identifier] = Entry(data: data, name: name)
        order.append(identifier)
        storedBytes += data.count
        evictOldestWhileOverCapacity()

        return identifier
    }

    func entry(_ identifier: Identifier) -> Entry? {
        entries[identifier]
    }

    /// Drops an image the screen no longer shows.
    ///
    /// Called when an image scrolls out of the buffer. Eviction by capacity
    /// exists for the case where that never happens fast enough; this is the
    /// ordinary path.
    func discard(_ identifier: Identifier) {
        guard let entry = entries.removeValue(forKey: identifier) else {
            return
        }
        storedBytes -= entry.data.count
        order.removeAll { $0 == identifier }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        storedBytes = 0
    }

    private func evictOldestWhileOverCapacity() {
        while storedBytes > Capacity.totalBYTES, let oldest = order.first {
            order.removeFirst()
            if let entry = entries.removeValue(forKey: oldest) {
                storedBytes -= entry.data.count
                evictionCount += 1
            }
        }
    }
}
