import Foundation

/// Turns files dropped onto a pane into the text that gets inserted at the
/// shell's cursor.
///
/// The formatter is deliberately Foundation-only and free of view state so the
/// quoting rules — the part that is easy to get subtly wrong and impossible to
/// eyeball — can be tested directly.
enum TerminalFileDropFormatter {
    /// Which spelling of a dropped file's location is inserted.
    ///
    /// The modifier is read at drop time rather than at drag start: a drag can
    /// begin in another application, where Kurotty never saw the key press.
    enum PathStyle: Equatable, Sendable {
        /// The full filesystem path. The default, and the only style that is
        /// correct regardless of where the shell's cursor currently is.
        case absolute
        /// The last path component only, for `mv old new`-shaped commands where
        /// the directory is already typed.
        case name
        /// Relative to the pane's working directory when the file lives under
        /// it, and the absolute path otherwise. A relative path that had to
        /// climb out through `..` is longer than the absolute one and reads
        /// worse, so this style never produces one.
        case relative
    }

    /// Characters that survive an unquoted shell word untouched.
    ///
    /// Everything else — spaces, quotes, globs, `~`, `$`, and every non-ASCII
    /// scalar — takes the quoted path. Non-ASCII is safe unquoted in a UTF-8
    /// shell, but quoting it costs two characters and removes a whole class of
    /// locale-dependent surprises.
    private static let unquotedSafeASCII = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/+@:,=")

    /// Builds the text for a drop.
    ///
    /// - Parameters:
    ///   - urls: The dropped files, in the order the pasteboard reported them.
    ///   - style: How each path is spelled.
    ///   - workingDirectory: The pane's OSC 7 directory, used only by
    ///     `.relative`. Pass `nil` when the pane's directory is unknown or
    ///     belongs to a remote host, and `.relative` falls back to `.absolute`.
    /// - Returns: The text to insert, or `nil` when there is nothing to insert.
    ///
    /// The result ends in a single space so the next argument can be typed
    /// immediately, which is what every other terminal on this platform does.
    static func text(
        for urls: [URL],
        style: PathStyle,
        workingDirectory: String?
    ) -> String? {
        let words = urls.compactMap { url -> String? in
            let path = self.path(for: url, style: style, workingDirectory: workingDirectory)
            return path.isEmpty ? nil : quoted(path)
        }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ") + " "
    }

    /// The path spelling for one dropped file.
    ///
    /// The Unicode form is passed through exactly as the filesystem reported
    /// it. macOS hands out decomposed Hangul, which today renders as scattered
    /// jamo — but precomposing here would send the shell a path that is not the
    /// one on disk. Fixing the rendering is the terminal's job; changing the
    /// bytes would be a correctness bug wearing a cosmetic fix's clothes.
    static func path(
        for url: URL,
        style: PathStyle,
        workingDirectory: String?
    ) -> String {
        let absolute = url.path
        switch style {
        case .absolute:
            return absolute
        case .name:
            return url.lastPathComponent
        case .relative:
            guard let relative = relativePath(from: workingDirectory, to: absolute) else {
                return absolute
            }
            return relative
        }
    }

    /// A path relative to `workingDirectory`, or `nil` when the file is not
    /// underneath it.
    private static func relativePath(from workingDirectory: String?, to absolute: String) -> String? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        let base = workingDirectory.hasSuffix("/") ? String(workingDirectory.dropLast()) : workingDirectory
        guard !base.isEmpty, absolute != base else { return nil }
        let prefix = base + "/"
        guard absolute.hasPrefix(prefix) else { return nil }
        let relative = String(absolute.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    /// POSIX single-quote quoting.
    ///
    /// Single quotes are the only shell quoting that suspends every expansion,
    /// so one rule covers spaces, globs, `$`, backticks, newlines, and a leading
    /// `~`. A literal `'` cannot appear inside them, so it is closed, escaped,
    /// and reopened — `it's` becomes `'it'\''s'`.
    static func quoted(_ path: String) -> String {
        guard needsQuoting(path) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func needsQuoting(_ path: String) -> Bool {
        guard !path.isEmpty else { return true }
        return path.unicodeScalars.contains { !unquotedSafeASCII.contains(Character($0)) }
    }
}
