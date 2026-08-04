import Foundation

/// A `path:line:col` style file reference extracted from one logical terminal
/// line. Offsets are character offsets into the logical-line text so the caller
/// can map them back onto screen cells.
struct TerminalFilePathCandidate: Equatable {
    /// Path text without the `:line:col` (or `(line,col)`) suffix.
    let pathText: String
    let line: Int?
    let column: Int?
    /// Inclusive character offset of `pathText` in the logical line.
    let startIndex: Int
    /// Exclusive character offset just past the retained suffix.
    let endIndex: Int

    var characterLength: Int { endIndex - startIndex }
}

/// A candidate after resolution against a working directory, paired with the
/// cached on-disk existence answer (`nil` means "not probed yet").
struct TerminalFilePathResolution: Equatable {
    let candidate: TerminalFilePathCandidate
    let absolutePath: String
    let exists: Bool?
}

/// Pure extraction and ranking of file-path links found in terminal output.
///
/// Ported from Orca's `terminal-links.ts` / `terminal-file-link-hit-testing.ts`
/// pair, trimmed to the local-filesystem cases Kurotty can act on. Everything
/// here is deterministic and filesystem-free; existence answers are supplied by
/// the caller so hit-testing never stats on the main actor.
enum TerminalFilePathLinkDetector {
    /// Extensions that make a bare, separator-free token (`main.swift`) worth
    /// treating as a path candidate. Tokens such as `v1.2` or `10.30` must not
    /// become links, so the bare-filename pass is allow-listed rather than
    /// matching any dotted word.
    static let bareFilenameExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "rs", "go",
        "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs",
        "zig", "sh", "bash", "zsh", "fish", "pl", "php", "lua", "sql", "r",
        "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "html",
        "htm", "css", "scss", "less", "md", "markdown", "txt", "log", "csv",
        "lock", "gradle", "cmake", "make", "mk", "proto", "graphql", "vue",
        "svelte", "dart", "ex", "exs", "erl", "hs", "scala", "clj", "plist",
        "entitlements", "xcconfig", "podspec", "gemspec", "env"
    ]

    /// Minimum retained path length; a stray `/` or `./` must not become a link.
    static let minimumPathTextLengthCharacters = AppConstants.TerminalLinks.minimumPathTextLengthCharacters

    /// Alternation order matters: the separator pass is tried first so
    /// `src/main.swift` is claimed whole instead of only its bare filename.
    private static let separatorPathPattern =
        #"(?:~[/\\]|[/\\]|\.{1,2}[/\\]|[A-Za-z0-9._+-]+[/\\])[A-Za-z0-9._~/\\%+@()\[\]-]*"#
    private static let bareFilenamePattern = #"[A-Za-z0-9._+-]+\.[A-Za-z0-9_]+"#
    private static let lineColumnSuffixPattern = #"(?::\d+)?(?::\d+)?"#

    private static let candidateRegex = try! NSRegularExpression(
        pattern: "(?:\(separatorPathPattern)|\(bareFilenamePattern))\(lineColumnSuffixPattern)"
    )

    /// A scheme prefix such as `https://` immediately before a match means the
    /// separator pass latched onto the authority part of a URL.
    private static let uriSchemePrefixRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9+.-]*:(?://)?$"#
    )

    private static let parenthesisedLineColumnRegex = try! NSRegularExpression(
        pattern: #"\((\d+)(?:,(\d+))?\)$"#
    )

    private static let trailingProsePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "'", "\"", "`", "*", "<", ">"
    ]

    // MARK: - Extraction

    /// Extracts every file-path candidate in `text`, left to right.
    static func candidates(in text: String) -> [TerminalFilePathCandidate] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let matches = candidateRegex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else { return [] }

        let characterOffsets = characterOffsetsByUTF16Offset(text)
        var results: [TerminalFilePathCandidate] = []
        for match in matches {
            let matchedText = nsText.substring(with: match.range)
            guard !isInsideURIScheme(nsText: nsText, matchStart: match.range.location, matchedText: matchedText)
            else { continue }
            guard match.range.location < characterOffsets.count else { continue }
            guard let candidate = makeCandidate(
                matchedText: matchedText,
                startIndex: characterOffsets[match.range.location]
            ) else { continue }
            results.append(candidate)
        }
        return results
    }

    /// `NSRegularExpression` reports UTF-16 offsets while screen cells are
    /// indexed by character. Build the mapping once per logical line so long
    /// lines with many matches stay linear.
    private static func characterOffsetsByUTF16Offset(_ text: String) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(text.utf16.count + 1)
        for (characterIndex, character) in text.enumerated() {
            for _ in 0..<character.utf16.count {
                offsets.append(characterIndex)
            }
        }
        offsets.append(text.count)
        return offsets
    }

    private static func isInsideURIScheme(nsText: NSString, matchStart: Int, matchedText: String) -> Bool {
        if matchedText.contains("://") { return true }
        let prefix = nsText.substring(to: matchStart)
        let prefixRange = NSRange(location: 0, length: (prefix as NSString).length)
        return uriSchemePrefixRegex.firstMatch(in: prefix, range: prefixRange) != nil
    }

    private static func makeCandidate(
        matchedText: String,
        startIndex: Int
    ) -> TerminalFilePathCandidate? {
        var text = matchedText
        var line: Int?
        var column: Int?

        (text, line, column) = splitColonLineColumnSuffix(text)
        if line == nil {
            (text, line, column) = splitParenthesisedLineColumnSuffix(text)
        }
        // Everything after the path portion is the retained line/column suffix;
        // trimming only shortens the path portion, so the two add up.
        let suffixLengthCharacters = matchedText.count - text.count
        text = strippingUnbalancedTrailingClosers(text)
        text = strippingTrailingProsePunctuation(text)

        guard isUsablePathText(text) else { return nil }

        let retainedLength = text.count + suffixLengthCharacters
        return TerminalFilePathCandidate(
            pathText: text,
            line: line,
            column: column,
            startIndex: startIndex,
            endIndex: startIndex + retainedLength
        )
    }

    private static func splitColonLineColumnSuffix(
        _ text: String
    ) -> (String, Int?, Int?) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (text, nil, nil) }

        // Windows drive letters (`C:/x`) are part of the path, not a line.
        var numericTail: [Int] = []
        var index = parts.count - 1
        while index > 0, numericTail.count < 2, let value = Int(parts[index]), !parts[index].isEmpty {
            numericTail.insert(value, at: 0)
            index -= 1
        }
        guard !numericTail.isEmpty else { return (text, nil, nil) }
        let pathText = parts[0...index].joined(separator: ":")
        guard !pathText.isEmpty else { return (text, nil, nil) }
        return (pathText, numericTail.first, numericTail.count > 1 ? numericTail[1] : nil)
    }

    private static func splitParenthesisedLineColumnSuffix(
        _ text: String
    ) -> (String, Int?, Int?) {
        let nsText = text as NSString
        guard let match = parenthesisedLineColumnRegex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ) else { return (text, nil, nil) }
        let pathText = nsText.substring(to: match.range.location)
        guard !pathText.isEmpty else { return (text, nil, nil) }
        let line = Int(nsText.substring(with: match.range(at: 1)))
        var column: Int?
        if match.range(at: 2).location != NSNotFound {
            column = Int(nsText.substring(with: match.range(at: 2)))
        }
        return (pathText, line, column)
    }

    /// `(src/a.ts)` must drop the closing paren while `app/(shop)/page.tsx`
    /// keeps its balanced ones.
    private static func strippingUnbalancedTrailingClosers(_ text: String) -> String {
        var result = text
        while let last = result.last, last == ")" || last == "]" || last == "}" {
            let opener: Character = last == ")" ? "(" : (last == "]" ? "[" : "{")
            let openCount = result.filter { $0 == opener }.count
            let closeCount = result.filter { $0 == last }.count
            guard closeCount > openCount else { break }
            result.removeLast()
        }
        return result
    }

    private static func strippingTrailingProsePunctuation(_ text: String) -> String {
        var result = text
        while let last = result.last, trailingProsePunctuation.contains(last) {
            result.removeLast()
        }
        return result
    }

    private static func isUsablePathText(_ text: String) -> Bool {
        guard text.count >= minimumPathTextLengthCharacters else { return false }
        // A trailing separator names a directory; editor tabs open files.
        guard let last = text.last, last != "/", last != "\\" else { return false }
        guard text.contains(where: { $0 != "/" && $0 != "\\" && $0 != "." }) else { return false }
        if text.contains("/") || text.contains("\\") { return true }
        // Bare token: only allow-listed extensions become candidates.
        guard let dotIndex = text.lastIndex(of: "."), dotIndex != text.startIndex else { return false }
        let ext = String(text[text.index(after: dotIndex)...]).lowercased()
        return bareFilenameExtensions.contains(ext)
    }

    // MARK: - Resolution

    /// Absolute paths to probe for `candidate`, in priority order: `~` expansion,
    /// already-absolute, then the pane working directory followed by `$HOME`.
    static func resolutionPaths(
        for candidate: TerminalFilePathCandidate,
        workingDirectory: String?,
        homeDirectory: String
    ) -> [String] {
        let normalized = candidate.pathText.contains("\\") && !candidate.pathText.contains("/")
            ? candidate.pathText.replacingOccurrences(of: "\\", with: "/")
            : candidate.pathText

        if normalized.hasPrefix("~/") {
            return [standardized(homeDirectory + "/" + String(normalized.dropFirst(2)))]
        }
        if normalized.hasPrefix("/") {
            return [standardized(normalized)]
        }

        var bases: [String] = []
        if let workingDirectory, !workingDirectory.isEmpty {
            bases.append(workingDirectory)
        }
        if !bases.contains(homeDirectory) {
            bases.append(homeDirectory)
        }
        return bases.map { standardized($0 + "/" + normalized) }
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    // MARK: - Ranking

    /// Orca's ranking: a path known to exist wins, longest match first; then a
    /// not-yet-probed path; a path known to be missing never wins.
    static func bestMatch(among resolutions: [TerminalFilePathResolution]) -> TerminalFilePathResolution? {
        let existing = resolutions
            .filter { $0.exists == true }
            .sorted { $0.candidate.pathText.count > $1.candidate.pathText.count }
        if let best = existing.first { return best }
        return resolutions.first { $0.exists == nil }
    }

    /// Non-overlapping set of confirmed links for decoration rendering: longest
    /// confirmed candidate wins each region of the logical line.
    static func acceptedNonOverlapping(
        _ resolutions: [TerminalFilePathResolution]
    ) -> [TerminalFilePathResolution] {
        let ordered = resolutions
            .filter { $0.exists == true }
            .sorted {
                if $0.candidate.characterLength != $1.candidate.characterLength {
                    return $0.candidate.characterLength > $1.candidate.characterLength
                }
                return $0.candidate.startIndex < $1.candidate.startIndex
            }
        var accepted: [TerminalFilePathResolution] = []
        for resolution in ordered {
            let overlaps = accepted.contains { existing in
                resolution.candidate.startIndex < existing.candidate.endIndex
                    && existing.candidate.startIndex < resolution.candidate.endIndex
            }
            if !overlaps { accepted.append(resolution) }
        }
        return accepted.sorted { $0.candidate.startIndex < $1.candidate.startIndex }
    }
}
