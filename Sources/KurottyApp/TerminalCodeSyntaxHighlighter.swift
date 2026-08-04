import Foundation

/// Token classification produced by the syntax highlighter. Kinds are
/// color-agnostic; the editor view maps each kind onto theme colors.
enum CodeSyntaxTokenKind: Equatable {
    case keyword
    case string
    case comment
    case number
    case typeName
}

/// One highlighted span. `range` is expressed in UTF-16 code units so it can be
/// applied directly to `NSTextStorage` / `NSAttributedString` APIs.
struct CodeSyntaxToken: Equatable {
    let range: NSRange
    let kind: CodeSyntaxTokenKind
}

/// Language token derived from a file extension. `plain` disables highlighting.
enum CodeSyntaxLanguage: Equatable {
    case swift
    case zig
    case c
    case javascript
    case python
    case shell
    case json
    case yaml
    case markdown
    case toml
    case rust
    case go
    case plain

    init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "swift": self = .swift
        case "zig": self = .zig
        case "c", "h", "m", "cpp", "cc", "hpp", "metal": self = .c
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": self = .javascript
        case "py": self = .python
        case "sh", "zsh", "bash": self = .shell
        case "json": self = .json
        case "yaml", "yml": self = .yaml
        case "md", "markdown": self = .markdown
        case "toml": self = .toml
        case "rs": self = .rust
        case "go": self = .go
        default: self = .plain
        }
    }
}

/// Declarative description of a language's lexical surface. The generic
/// scanner in `TerminalCodeSyntaxHighlighter` interprets one spec per language,
/// so adding a language means adding a table entry, not a new scanner.
private struct CodeSyntaxLanguageSpec {
    let keywords: Set<String>
    let lineCommentPrefixes: [String]
    let blockComment: (open: String, close: String)?
    /// String delimiters tried in declaration order; longer delimiters
    /// (triple quotes) must precede their single-character prefixes.
    let stringDelimiters: [String]
    let supportsBackslashEscape: Bool
    /// Highlight capitalized identifiers as `typeName`.
    let highlightsCapitalizedTypeNames: Bool
}

/// Pure syntax highlighter: `(text, language) -> [CodeSyntaxToken]`.
///
/// Incremental strategy (v1, documented choice): the highlighter runs a single
/// whole-document scan on load and again after edits (the editor re-runs it on
/// the whole document, debounced per text change). The scan is a single O(n)
/// pass over UTF-16 code units with no regex backtracking, which stays in the
/// low-millisecond range for ~1 MB files. Above
/// `highlightSizeCapBytes` the highlighter returns no tokens so oversized
/// files degrade to plain text instead of stalling the main thread. A future
/// v2 can key block-comment/string carry-over state per line for true
/// incremental re-highlighting.
enum TerminalCodeSyntaxHighlighter {
    /// UTF-16 size cap above which highlighting is skipped entirely.
    static let highlightSizeCapBytes = 2 * 1024 * 1024

    static func highlight(text: String, language: CodeSyntaxLanguage) -> [CodeSyntaxToken] {
        guard language != .plain else { return [] }
        let units = Array(text.utf16)
        guard units.count * 2 <= highlightSizeCapBytes else { return [] }
        if language == .markdown {
            return highlightMarkdown(units: units)
        }
        guard let spec = specs[language] else { return [] }
        return scan(units: units, spec: spec)
    }

    // MARK: - Generic scanner

    private static func scan(units: [UInt16], spec: CodeSyntaxLanguageSpec) -> [CodeSyntaxToken] {
        var tokens: [CodeSyntaxToken] = []
        var index = 0
        let count = units.count

        while index < count {
            let unit = units[index]

            if let blockComment = spec.blockComment, matches(units, at: index, text: blockComment.open) {
                index = consumeBlockComment(units, from: index, spec: blockComment, into: &tokens)
                continue
            }
            if let prefix = spec.lineCommentPrefixes.first(where: { matches(units, at: index, text: $0) }) {
                index = consumeLineComment(units, from: index, prefixLength: prefix.utf16.count, into: &tokens)
                continue
            }
            if let delimiter = spec.stringDelimiters.first(where: { matches(units, at: index, text: $0) }) {
                index = consumeString(
                    units,
                    from: index,
                    delimiter: delimiter,
                    allowsEscape: spec.supportsBackslashEscape,
                    into: &tokens
                )
                continue
            }
            if isDigit(unit), !isIdentifierUnit(index > 0 ? units[index - 1] : ASCII.space) {
                index = consumeNumber(units, from: index, into: &tokens)
                continue
            }
            if isIdentifierStart(unit) {
                index = consumeIdentifier(units, from: index, spec: spec, into: &tokens)
                continue
            }
            index += 1
        }
        return tokens
    }

    private static func consumeBlockComment(
        _ units: [UInt16],
        from start: Int,
        spec: (open: String, close: String),
        into tokens: inout [CodeSyntaxToken]
    ) -> Int {
        let openLength = spec.open.utf16.count
        let closeUnits = Array(spec.close.utf16)
        var index = start + openLength
        var depth = 1
        while index < units.count {
            if matches(units, at: index, text: spec.open) {
                // Swift/Zig-style nested block comments; harmless for C.
                depth += 1
                index += openLength
                continue
            }
            if matchesUnits(units, at: index, pattern: closeUnits) {
                depth -= 1
                index += closeUnits.count
                if depth == 0 { break }
                continue
            }
            index += 1
        }
        tokens.append(CodeSyntaxToken(range: NSRange(location: start, length: index - start), kind: .comment))
        return index
    }

    private static func consumeLineComment(
        _ units: [UInt16],
        from start: Int,
        prefixLength: Int,
        into tokens: inout [CodeSyntaxToken]
    ) -> Int {
        var index = start + prefixLength
        while index < units.count, units[index] != ASCII.newline {
            index += 1
        }
        tokens.append(CodeSyntaxToken(range: NSRange(location: start, length: index - start), kind: .comment))
        return index
    }

    private static func consumeString(
        _ units: [UInt16],
        from start: Int,
        delimiter: String,
        allowsEscape: Bool,
        into tokens: inout [CodeSyntaxToken]
    ) -> Int {
        let delimiterUnits = Array(delimiter.utf16)
        let isMultiline = delimiterUnits.count > 1 || delimiterUnits.first == ASCII.backtick
        var index = start + delimiterUnits.count
        while index < units.count {
            let unit = units[index]
            if allowsEscape, unit == ASCII.backslash, index + 1 < units.count {
                index += 2
                continue
            }
            if matchesUnits(units, at: index, pattern: delimiterUnits) {
                index += delimiterUnits.count
                break
            }
            if !isMultiline, unit == ASCII.newline {
                break
            }
            index += 1
        }
        tokens.append(CodeSyntaxToken(range: NSRange(location: start, length: index - start), kind: .string))
        return index
    }

    private static func consumeNumber(
        _ units: [UInt16],
        from start: Int,
        into tokens: inout [CodeSyntaxToken]
    ) -> Int {
        var index = start
        while index < units.count, isNumberBodyUnit(units[index]) {
            index += 1
        }
        tokens.append(CodeSyntaxToken(range: NSRange(location: start, length: index - start), kind: .number))
        return index
    }

    private static func consumeIdentifier(
        _ units: [UInt16],
        from start: Int,
        spec: CodeSyntaxLanguageSpec,
        into tokens: inout [CodeSyntaxToken]
    ) -> Int {
        var index = start
        while index < units.count, isIdentifierUnit(units[index]) {
            index += 1
        }
        let range = NSRange(location: start, length: index - start)
        let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
        if spec.keywords.contains(word) {
            tokens.append(CodeSyntaxToken(range: range, kind: .keyword))
        } else if spec.highlightsCapitalizedTypeNames, isUppercaseASCII(units[start]) {
            tokens.append(CodeSyntaxToken(range: range, kind: .typeName))
        }
        return index
    }

    // MARK: - Markdown (headers and code fences only)

    private static func highlightMarkdown(units: [UInt16]) -> [CodeSyntaxToken] {
        var tokens: [CodeSyntaxToken] = []
        var lineStart = 0
        var insideFence = false
        let fence = Array("```".utf16)
        var index = 0
        while index <= units.count {
            let atEnd = index == units.count
            if atEnd || units[index] == ASCII.newline {
                let lineRange = NSRange(location: lineStart, length: index - lineStart)
                let isFenceLine = matchesUnits(units, at: lineStart, pattern: fence)
                if isFenceLine {
                    tokens.append(CodeSyntaxToken(range: lineRange, kind: .comment))
                    insideFence.toggle()
                } else if insideFence {
                    if lineRange.length > 0 {
                        tokens.append(CodeSyntaxToken(range: lineRange, kind: .string))
                    }
                } else if lineRange.length > 0, units[lineStart] == ASCII.hash {
                    tokens.append(CodeSyntaxToken(range: lineRange, kind: .keyword))
                }
                lineStart = index + 1
            }
            if atEnd { break }
            index += 1
        }
        return tokens
    }

    // MARK: - Character classification (UTF-16 code units)

    private enum ASCII {
        static let newline: UInt16 = 0x0A
        static let space: UInt16 = 0x20
        static let hash: UInt16 = 0x23
        static let backslash: UInt16 = 0x5C
        static let backtick: UInt16 = 0x60
        static let underscore: UInt16 = 0x5F
        static let dot: UInt16 = 0x2E
        static let zero: UInt16 = 0x30
        static let nine: UInt16 = 0x39
        static let upperA: UInt16 = 0x41
        static let upperZ: UInt16 = 0x5A
        static let lowerA: UInt16 = 0x61
        static let lowerZ: UInt16 = 0x7A
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= ASCII.zero && unit <= ASCII.nine
    }

    private static func isUppercaseASCII(_ unit: UInt16) -> Bool {
        unit >= ASCII.upperA && unit <= ASCII.upperZ
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        isUppercaseASCII(unit) || (unit >= ASCII.lowerA && unit <= ASCII.lowerZ)
    }

    private static func isIdentifierStart(_ unit: UInt16) -> Bool {
        isLetter(unit) || unit == ASCII.underscore
    }

    private static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }

    private static func isNumberBodyUnit(_ unit: UInt16) -> Bool {
        isDigit(unit) || isLetter(unit) || unit == ASCII.dot || unit == ASCII.underscore
    }

    private static func matches(_ units: [UInt16], at index: Int, text: String) -> Bool {
        matchesUnits(units, at: index, pattern: Array(text.utf16))
    }

    private static func matchesUnits(_ units: [UInt16], at index: Int, pattern: [UInt16]) -> Bool {
        guard index + pattern.count <= units.count else { return false }
        for offset in 0..<pattern.count where units[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    // MARK: - Language specs

    private static let specs: [CodeSyntaxLanguage: CodeSyntaxLanguageSpec] = [
        .swift: CodeSyntaxLanguageSpec(
            keywords: [
                "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
                "import", "init", "inout", "internal", "let", "open", "operator", "private",
                "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript",
                "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do",
                "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw",
                "switch", "where", "while", "as", "any", "false", "is", "nil", "self", "Self",
                "super", "throws", "true", "try", "async", "await", "actor", "some", "lazy",
                "weak", "unowned", "mutating", "nonisolated", "override", "required", "final",
            ],
            lineCommentPrefixes: ["//"],
            blockComment: (open: "/*", close: "*/"),
            stringDelimiters: ["\"\"\"", "\""],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: true
        ),
        .zig: CodeSyntaxLanguageSpec(
            keywords: [
                "const", "var", "fn", "pub", "return", "try", "catch", "defer", "errdefer",
                "if", "else", "while", "for", "switch", "break", "continue", "struct", "enum",
                "union", "error", "test", "comptime", "inline", "export", "extern", "packed",
                "align", "allowzero", "and", "or", "orelse", "null", "undefined", "true", "false",
                "unreachable", "usingnamespace", "async", "await", "suspend", "resume", "threadlocal",
                "volatile", "anytype", "anyframe", "noalias", "nosuspend", "opaque",
            ],
            lineCommentPrefixes: ["//"],
            blockComment: nil,
            stringDelimiters: ["\"", "'"],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: true
        ),
        .c: CodeSyntaxLanguageSpec(
            keywords: [
                "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
                "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
                "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
                "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool",
                "true", "false", "NULL", "include", "define", "ifdef", "ifndef", "endif", "pragma",
            ],
            lineCommentPrefixes: ["//"],
            blockComment: (open: "/*", close: "*/"),
            stringDelimiters: ["\"", "'"],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: false
        ),
        .javascript: CodeSyntaxLanguageSpec(
            keywords: [
                "break", "case", "catch", "class", "const", "continue", "debugger", "default",
                "delete", "do", "else", "export", "extends", "finally", "for", "function", "if",
                "import", "in", "instanceof", "let", "new", "of", "return", "static", "super",
                "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with",
                "yield", "async", "await", "true", "false", "null", "undefined", "interface",
                "type", "enum", "implements", "namespace", "readonly", "as", "declare", "from",
            ],
            lineCommentPrefixes: ["//"],
            blockComment: (open: "/*", close: "*/"),
            stringDelimiters: ["\"", "'", "`"],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: true
        ),
        .python: CodeSyntaxLanguageSpec(
            keywords: [
                "False", "None", "True", "and", "as", "assert", "async", "await", "break",
                "class", "continue", "def", "del", "elif", "else", "except", "finally", "for",
                "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or",
                "pass", "raise", "return", "try", "while", "with", "yield", "match", "case", "self",
            ],
            lineCommentPrefixes: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"\"\"", "'''", "\"", "'"],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: false
        ),
        .shell: CodeSyntaxLanguageSpec(
            keywords: [
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
                "case", "esac", "function", "in", "select", "time", "return", "break", "continue",
                "local", "export", "readonly", "declare", "typeset", "unset", "shift", "exit",
                "source", "alias", "set", "trap", "eval", "exec", "echo", "printf", "read", "cd",
            ],
            lineCommentPrefixes: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"", "'"],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: false
        ),
        .json: CodeSyntaxLanguageSpec(
            keywords: ["true", "false", "null"],
            lineCommentPrefixes: [],
            blockComment: nil,
            stringDelimiters: ["\""],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: false
        ),
        .yaml: CodeSyntaxLanguageSpec(
            keywords: ["true", "false", "null", "yes", "no", "on", "off"],
            lineCommentPrefixes: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"", "'"],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: false
        ),
        .toml: CodeSyntaxLanguageSpec(
            keywords: ["true", "false"],
            lineCommentPrefixes: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"\"\"", "'''", "\"", "'"],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: false
        ),
        .rust: CodeSyntaxLanguageSpec(
            keywords: [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
                "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
                "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
            ],
            lineCommentPrefixes: ["//"],
            blockComment: (open: "/*", close: "*/"),
            stringDelimiters: ["\""],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: true
        ),
        .go: CodeSyntaxLanguageSpec(
            keywords: [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                "package", "range", "return", "select", "struct", "switch", "type", "var",
                "true", "false", "nil", "iota", "make", "new", "len", "cap", "append", "error",
            ],
            lineCommentPrefixes: ["//"],
            blockComment: (open: "/*", close: "*/"),
            stringDelimiters: ["\"", "`", "'"],
            supportsBackslashEscape: true,
            highlightsCapitalizedTypeNames: true
        ),
    ]
}
