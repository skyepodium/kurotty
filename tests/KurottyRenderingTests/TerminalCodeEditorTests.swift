import Foundation
import XCTest
@testable import KurottyApp

final class TerminalCodeEditorTests: XCTestCase {
    // MARK: - Helpers

    private func tokens(_ text: String, _ language: CodeSyntaxLanguage) -> [CodeSyntaxToken] {
        TerminalCodeSyntaxHighlighter.highlight(text: text, language: language)
    }

    private func token(
        ofKind kind: CodeSyntaxTokenKind,
        covering substring: String,
        in text: String,
        language: CodeSyntaxLanguage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CodeSyntaxToken? {
        guard let swiftRange = text.range(of: substring) else {
            XCTFail("Fixture does not contain \(substring)", file: file, line: line)
            return nil
        }
        let expected = NSRange(swiftRange, in: text)
        return tokens(text, language).first { $0.kind == kind && $0.range == expected }
    }

    private func assertToken(
        _ kind: CodeSyntaxTokenKind,
        covers substring: String,
        in text: String,
        language: CodeSyntaxLanguage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotNil(
            token(ofKind: kind, covering: substring, in: text, language: language, file: file, line: line),
            "Expected \(kind) token covering \(substring) in \(language)",
            file: file,
            line: line
        )
    }

    // MARK: - Language mapping

    @MainActor
    func testImageFileLoadsIntoReadOnlyPreview() throws {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-image-preview-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let editor = TerminalCodeEditorView()
        editor.load(url: url)

        XCTAssertTrue(editor.isShowingImageForTesting)
        XCTAssertFalse(editor.isModified)
    }

    func testLanguageIsDerivedFromFileExtension() {
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "swift"), .swift)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "zig"), .zig)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "h"), .c)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "TSX"), .javascript)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "py"), .python)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "zsh"), .shell)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "json"), .json)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "yml"), .yaml)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "md"), .markdown)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "toml"), .toml)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "rs"), .rust)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "go"), .go)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: "bin"), .plain)
        XCTAssertEqual(CodeSyntaxLanguage(fileExtension: ""), .plain)
    }

    // MARK: - Swift

    func testSwiftKeywordsStringsAndComments() {
        let source = """
        // load the value
        func loadValue() -> Int {
            let label = "count \\"quoted\\""
            /* block
               comment */
            return 42
        }
        """
        assertToken(.comment, covers: "// load the value", in: source, language: .swift)
        assertToken(.keyword, covers: "func", in: source, language: .swift)
        assertToken(.keyword, covers: "let", in: source, language: .swift)
        assertToken(.keyword, covers: "return", in: source, language: .swift)
        assertToken(.string, covers: "\"count \\\"quoted\\\"\"", in: source, language: .swift)
        assertToken(.comment, covers: "/* block\n       comment */", in: source, language: .swift)
        assertToken(.number, covers: "42", in: source, language: .swift)
        assertToken(.typeName, covers: "Int", in: source, language: .swift)
    }

    func testSwiftEscapedQuoteDoesNotTerminateString() {
        let source = "let s = \"a\\\"b\"\nlet t = 1"
        let stringTokens = tokens(source, .swift).filter { $0.kind == .string }
        XCTAssertEqual(stringTokens.count, 1)
        let covered = (source as NSString).substring(with: stringTokens[0].range)
        XCTAssertEqual(covered, "\"a\\\"b\"")
    }

    // MARK: - Other languages

    func testZigKeywordsAndLineComment() {
        let source = "// zig\npub fn main() void {\n    const answer = 7;\n}"
        assertToken(.comment, covers: "// zig", in: source, language: .zig)
        assertToken(.keyword, covers: "pub", in: source, language: .zig)
        assertToken(.keyword, covers: "const", in: source, language: .zig)
        assertToken(.number, covers: "7", in: source, language: .zig)
    }

    func testCBlockCommentAndCharLiteral() {
        let source = "/* header */\nstatic int add(int a) { return a + 'x'; }"
        assertToken(.comment, covers: "/* header */", in: source, language: .c)
        assertToken(.keyword, covers: "static", in: source, language: .c)
        assertToken(.keyword, covers: "return", in: source, language: .c)
        assertToken(.string, covers: "'x'", in: source, language: .c)
    }

    func testJavaScriptTemplateLiteralSpansLines() {
        let source = "const msg = `line one\nline two`;\nlet done = true;"
        assertToken(.string, covers: "`line one\nline two`", in: source, language: .javascript)
        assertToken(.keyword, covers: "const", in: source, language: .javascript)
        assertToken(.keyword, covers: "true", in: source, language: .javascript)
    }

    func testPythonTripleQuotedStringAndHashComment() {
        let source = "# note\ndef go():\n    doc = \"\"\"multi\nline\"\"\"\n    return None"
        assertToken(.comment, covers: "# note", in: source, language: .python)
        assertToken(.keyword, covers: "def", in: source, language: .python)
        assertToken(.string, covers: "\"\"\"multi\nline\"\"\"", in: source, language: .python)
        assertToken(.keyword, covers: "None", in: source, language: .python)
    }

    func testShellCommentKeywordAndString() {
        let source = "#!/bin/sh\nif [ -f x ]; then\n  echo \"hi\"\nfi"
        assertToken(.keyword, covers: "if", in: source, language: .shell)
        assertToken(.keyword, covers: "fi", in: source, language: .shell)
        assertToken(.string, covers: "\"hi\"", in: source, language: .shell)
        XCTAssertTrue(tokens(source, .shell).contains { $0.kind == .comment })
    }

    func testJSONLiteralsStringsAndNumbers() {
        let source = "{\"name\": \"kurotty\", \"ok\": true, \"count\": 12}"
        assertToken(.string, covers: "\"name\"", in: source, language: .json)
        assertToken(.keyword, covers: "true", in: source, language: .json)
        assertToken(.number, covers: "12", in: source, language: .json)
    }

    func testYAMLCommentAndLiterals() {
        let source = "# config\nenabled: true\ncount: 3\nname: \"box\""
        assertToken(.comment, covers: "# config", in: source, language: .yaml)
        assertToken(.keyword, covers: "true", in: source, language: .yaml)
        assertToken(.number, covers: "3", in: source, language: .yaml)
        assertToken(.string, covers: "\"box\"", in: source, language: .yaml)
    }

    func testMarkdownHighlightsHeadersAndCodeFencesOnly() {
        let source = "# Title\nplain prose here\n```\ncode body\n```\nmore prose"
        let result = tokens(source, .markdown)
        assertToken(.keyword, covers: "# Title", in: source, language: .markdown)
        assertToken(.string, covers: "code body", in: source, language: .markdown)
        XCTAssertEqual(result.filter { $0.kind == .comment }.count, 2, "both fence lines marked")
        let proseRange = NSRange((source.range(of: "plain prose here"))!, in: source)
        XCTAssertFalse(result.contains { NSIntersectionRange($0.range, proseRange).length > 0 })
    }

    func testTOMLCommentStringAndBoolean() {
        let source = "# section\ntitle = \"demo\"\nactive = false"
        assertToken(.comment, covers: "# section", in: source, language: .toml)
        assertToken(.string, covers: "\"demo\"", in: source, language: .toml)
        assertToken(.keyword, covers: "false", in: source, language: .toml)
    }

    func testRustKeywordsAndComment() {
        let source = "// entry\nfn main() { let mut x = 5; }"
        assertToken(.comment, covers: "// entry", in: source, language: .rust)
        assertToken(.keyword, covers: "fn", in: source, language: .rust)
        assertToken(.keyword, covers: "mut", in: source, language: .rust)
        assertToken(.number, covers: "5", in: source, language: .rust)
    }

    func testGoRawStringAndKeywords() {
        let source = "package main\nfunc run() { s := `raw`\n_ = s }"
        assertToken(.keyword, covers: "package", in: source, language: .go)
        assertToken(.keyword, covers: "func", in: source, language: .go)
        assertToken(.string, covers: "`raw`", in: source, language: .go)
    }

    // MARK: - Fallback and cap

    func testPlainLanguageProducesNoTokens() {
        XCTAssertTrue(tokens("func let \"string\" // comment", .plain).isEmpty)
    }

    func testUnknownExtensionFallsBackToNoHighlighting() {
        let language = CodeSyntaxLanguage(fileExtension: "dat")
        XCTAssertTrue(tokens("if true then 1", language).isEmpty)
    }

    func testHighlightingSkipsFilesAboveSizeCap() {
        let overCapCharacterCount = TerminalCodeSyntaxHighlighter.highlightSizeCapBytes / 2 + 1
        let big = String(repeating: "a", count: overCapCharacterCount)
        XCTAssertTrue(tokens(big, .swift).isEmpty)
    }

    func testIdentifierContainingKeywordIsNotAKeyword() {
        let source = "let functions = 1"
        let keywordTokens = tokens(source, .swift).filter { $0.kind == .keyword }
        XCTAssertEqual(keywordTokens.count, 1)
        XCTAssertEqual((source as NSString).substring(with: keywordTokens[0].range), "let")
    }

    // MARK: - Binary detection and load classification

    func testTextDataClassifiesAsText() {
        let data = Data("hello world\n".utf8)
        XCTAssertEqual(TerminalCodeEditorDocumentPolicy.classify(data: data), .text("hello world\n"))
    }

    func testNulByteInPrefixClassifiesAsBinary() {
        var data = Data("abc".utf8)
        data.append(0)
        data.append(Data("def".utf8))
        XCTAssertTrue(TerminalCodeEditorDocumentPolicy.isBinary(data: data))
        XCTAssertEqual(TerminalCodeEditorDocumentPolicy.classify(data: data), .binary)
    }

    func testNulByteBeyondProbePrefixIsNotDetected() {
        var data = Data(repeating: UInt8(ascii: "a"), count: TerminalCodeEditorDocumentPolicy.binaryProbePrefixBytes)
        data.append(0)
        XCTAssertFalse(TerminalCodeEditorDocumentPolicy.isBinary(data: data))
    }

    func testOversizedDataClassifiesAsTooLarge() {
        let data = Data(count: TerminalCodeEditorDocumentPolicy.fileSizeCapBytes + 1)
        XCTAssertEqual(TerminalCodeEditorDocumentPolicy.classify(data: data), .tooLarge)
    }

    func testInvalidUTF8FallsBackToLossyText() {
        let data = Data([0x61, 0xFF, 0x62])
        guard case .text(let text) = TerminalCodeEditorDocumentPolicy.classify(data: data) else {
            return XCTFail("Expected lossy text classification")
        }
        XCTAssertTrue(text.hasPrefix("a"))
        XCTAssertTrue(text.hasSuffix("b"))
        XCTAssertTrue(text.contains("\u{FFFD}"))
    }

    // MARK: - Dirty tracker

    func testDirtyTrackerReportsTransitionsOnly() {
        var tracker = TerminalCodeEditorDirtyTracker()
        XCTAssertFalse(tracker.isDirty)
        XCTAssertFalse(tracker.noteLoaded(), "already clean; no transition")
        XCTAssertTrue(tracker.noteTextChanged())
        XCTAssertTrue(tracker.isDirty)
        XCTAssertFalse(tracker.noteTextChanged(), "already dirty; no transition")
        XCTAssertTrue(tracker.noteSaved())
        XCTAssertFalse(tracker.isDirty)
        XCTAssertFalse(tracker.noteSaved(), "already clean; no transition")
        XCTAssertTrue(tracker.noteTextChanged())
        XCTAssertTrue(tracker.noteLoaded(), "reload clears dirty state")
    }

    // MARK: - Placeholder copy

    // Placeholder copy migrated from the retired TerminalCodeEditorCopy table
    // into AppLocalization editor* keys.
    func testPlaceholderCopyExistsForAllLanguages() {
        for language in AppLanguage.allCases {
            XCTAssertFalse(AppLocalization.string(.editorBinaryFile, language: language).isEmpty)
            XCTAssertFalse(AppLocalization.string(.editorFileTooLarge, language: language).isEmpty)
            XCTAssertFalse(AppLocalization.string(.editorLoadFailed, language: language).isEmpty)
        }
    }

    func testPlaceholderCopyEnglishValues() {
        XCTAssertEqual(AppLocalization.string(.editorBinaryFile, language: .english), "Binary file")
        XCTAssertEqual(AppLocalization.string(.editorFileTooLarge, language: .english), "File too large")
    }
}
