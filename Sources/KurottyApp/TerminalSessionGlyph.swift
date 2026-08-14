import Foundation

/// The emoji a session wears in its tab.
///
/// Dia's bookmark folders carry no custom iconography — they carry whatever
/// emoji the person picked, and that is what makes the window feel like
/// somebody's rather than a vendor's. In a terminal the same move does work as
/// well as decoration: a tab on a production host should not look like a tab on
/// this Mac, and a hostname in eight-point grey is not a difference anyone
/// notices at the moment it matters.
///
/// So the glyph is derived rather than assigned. Nothing to configure, nothing
/// to forget to configure, and the one case that must never be missed — a root
/// shell on a machine that is not yours — is the one case that does not depend
/// on a hash at all.
///
/// Pure: a location in, a character out. No AppKit, no session, no chrome.
enum TerminalSessionGlyph {
    /// Shown for a root shell, wherever it is running.
    ///
    /// Root on a remote host outranks everything else this can say. It is the
    /// only glyph that is not derived from the name, because a warning that
    /// varies by host is not a warning.
    static let root: Character = "🚨"

    /// Shown for a shell on this Mac.
    ///
    /// Deliberately nothing. A local shell is the ordinary case, and marking
    /// the ordinary case teaches the eye to ignore the mark — which is exactly
    /// what must not happen to the two above.
    static let local: Character? = nil

    /// One glyph per remote host, stable for the life of the host's name.
    ///
    /// Chosen from a small set rather than generated, because the point is that
    /// two windows on the same host look alike and two windows on different
    /// hosts do not. Anything recognisably *meaningful* is left out: a glyph
    /// that reads as a warning would compete with `root`, and one that reads as
    /// a status would say something the terminal does not know.
    private static let remote: [Character] = [
        "🛰", "🪐", "🧭", "🛸", "🗿", "🏔", "🌋", "🏝",
        "🎏", "🪁", "🧊", "🪵", "🪸", "🍄", "🌵", "🪨",
    ]

    /// The glyph for a working directory, or nil when the session is local and
    /// unremarkable.
    static func glyph(for location: TerminalWorkingDirectoryLocation) -> Character? {
        guard let host = location.remoteHost else {
            return local
        }
        guard !isRoot(host) else {
            return root
        }

        return remote[index(for: machineName(of: host))]
    }

    /// Whether `user@host` names a root shell.
    private static func isRoot(_ host: String) -> Bool {
        guard let separator = host.firstIndex(of: "@") else {
            return false
        }
        return host[host.startIndex..<separator] == "root"
    }

    /// The machine half of `user@host`, so the same box looks the same however
    /// you logged into it.
    private static func machineName(of host: String) -> Substring {
        guard let separator = host.firstIndex(of: "@") else {
            return host[...]
        }
        return host[host.index(after: separator)...]
    }

    /// A stable index into the set.
    ///
    /// Written out rather than taken from `hashValue`, which is seeded per
    /// process: the same host would wear a different glyph in every window and
    /// a different one again after a restart, which is the opposite of the
    /// point. FNV-1a over the name's bytes gives the same answer everywhere,
    /// forever.
    private static func index(for name: Substring) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01B3
        }
        return Int(hash % UInt64(remote.count))
    }
}
