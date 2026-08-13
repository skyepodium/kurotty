import AppKit
import XCTest

@testable import KurottyApp

/// Covers the text a file drop inserts at the shell cursor. The quoting rules
/// are the reason this type exists: an unquoted space silently turns one
/// argument into two, and a mis-escaped apostrophe leaves the shell waiting for
/// a quote that never closes.
final class TerminalFileDropFormatterTests: XCTestCase {
    // MARK: - Quoting

    func testPlainPathIsNotQuoted() {
        XCTAssertEqual(TerminalFileDropFormatter.quoted("/Users/a/dev/main.swift"), "/Users/a/dev/main.swift")
    }

    func testPathWithSpaceIsQuoted() {
        XCTAssertEqual(
            TerminalFileDropFormatter.quoted("/Users/a/My Project/main.swift"),
            "'/Users/a/My Project/main.swift'"
        )
    }

    func testApostropheIsClosedEscapedAndReopened() {
        // The one sequence single quoting cannot express directly.
        XCTAssertEqual(
            TerminalFileDropFormatter.quoted("/Users/a/it's here.txt"),
            "'/Users/a/it'\\''s here.txt'"
        )
    }

    func testShellMetacharactersAreQuoted() {
        for path in ["/tmp/a$b", "/tmp/a`b`", "/tmp/a*b", "/tmp/a;b", "/tmp/a\nb", "/tmp/a(b)"] {
            XCTAssertTrue(
                TerminalFileDropFormatter.quoted(path).hasPrefix("'"),
                "expected \(path) to be quoted"
            )
        }
    }

    func testLeadingTildeIsQuotedSoTheShellDoesNotExpandIt() {
        XCTAssertEqual(TerminalFileDropFormatter.quoted("~weird"), "'~weird'")
    }

    func testNonASCIIPathIsQuoted() {
        XCTAssertEqual(TerminalFileDropFormatter.quoted("/tmp/한글.txt"), "'/tmp/한글.txt'")
    }

    func testEmptyPathIsQuotedRatherThanVanishing() {
        XCTAssertEqual(TerminalFileDropFormatter.quoted(""), "''")
    }

    // MARK: - Path styles

    func testAbsoluteStyleUsesTheFullPath() {
        let url = URL(fileURLWithPath: "/Users/a/dev/main.swift")
        XCTAssertEqual(
            TerminalFileDropFormatter.path(for: url, style: .absolute, workingDirectory: "/Users/a"),
            "/Users/a/dev/main.swift"
        )
    }

    func testNameStyleUsesTheLastComponent() {
        let url = URL(fileURLWithPath: "/Users/a/dev/main.swift")
        XCTAssertEqual(
            TerminalFileDropFormatter.path(for: url, style: .name, workingDirectory: "/Users/a"),
            "main.swift"
        )
    }

    func testRelativeStyleStripsTheWorkingDirectory() {
        let url = URL(fileURLWithPath: "/Users/a/dev/main.swift")
        XCTAssertEqual(
            TerminalFileDropFormatter.path(for: url, style: .relative, workingDirectory: "/Users/a"),
            "dev/main.swift"
        )
    }

    func testRelativeStyleToleratesATrailingSlashOnTheWorkingDirectory() {
        let url = URL(fileURLWithPath: "/Users/a/dev/main.swift")
        XCTAssertEqual(
            TerminalFileDropFormatter.path(for: url, style: .relative, workingDirectory: "/Users/a/"),
            "dev/main.swift"
        )
    }

    func testRelativeStyleFallsBackToAbsoluteOutsideTheWorkingDirectory() {
        // Climbing out through `..` is longer than the absolute path and reads
        // worse, so the absolute path wins.
        let url = URL(fileURLWithPath: "/etc/hosts")
        XCTAssertEqual(
            TerminalFileDropFormatter.path(for: url, style: .relative, workingDirectory: "/Users/a"),
            "/etc/hosts"
        )
    }

    func testRelativeStyleFallsBackToAbsoluteWithoutAWorkingDirectory() {
        let url = URL(fileURLWithPath: "/Users/a/dev/main.swift")
        XCTAssertEqual(
            TerminalFileDropFormatter.path(for: url, style: .relative, workingDirectory: nil),
            "/Users/a/dev/main.swift"
        )
    }

    func testSiblingDirectoryWithASharedPrefixIsNotTreatedAsInside() {
        let url = URL(fileURLWithPath: "/Users/andrew/notes.txt")
        XCTAssertEqual(
            TerminalFileDropFormatter.path(for: url, style: .relative, workingDirectory: "/Users/a"),
            "/Users/andrew/notes.txt"
        )
    }

    // MARK: - Assembled text

    func testSingleFileEndsWithOneTrailingSpace() {
        let text = TerminalFileDropFormatter.text(
            for: [URL(fileURLWithPath: "/tmp/a.txt")],
            style: .absolute,
            workingDirectory: nil
        )
        XCTAssertEqual(text, "/tmp/a.txt ")
    }

    func testMultipleFilesAreSpaceSeparatedInPasteboardOrder() {
        let text = TerminalFileDropFormatter.text(
            for: [
                URL(fileURLWithPath: "/tmp/a.txt"),
                URL(fileURLWithPath: "/tmp/two words.txt"),
            ],
            style: .absolute,
            workingDirectory: nil
        )
        XCTAssertEqual(text, "/tmp/a.txt '/tmp/two words.txt' ")
    }

    func testEmptyDropInsertsNothing() {
        XCTAssertNil(TerminalFileDropFormatter.text(for: [], style: .absolute, workingDirectory: nil))
    }

    func testDecomposedHangulPathIsPassedThroughUnchanged() {
        // macOS hands out NFD. Precomposing here would hand the shell a path
        // that is not the one on disk; rendering it correctly is the terminal's
        // problem, not the formatter's.
        let decomposed = "/tmp/\u{1112}\u{1161}\u{11AB}.txt"
        let text = TerminalFileDropFormatter.text(
            for: [URL(fileURLWithPath: decomposed)],
            style: .absolute,
            workingDirectory: nil
        )
        // Swift's `==` compares canonical equivalence, so an NFD string and its
        // NFC form test equal. The scalars are what reaches the PTY, so this
        // asserts on those.
        XCTAssertEqual(
            Array(text?.unicodeScalars ?? "".unicodeScalars),
            Array("'\(decomposed)' ".unicodeScalars)
        )
    }

    // MARK: - Modifiers

    func testNoModifiersInsertsTheAbsolutePath() {
        XCTAssertEqual(TerminalFileDropModifiers.style(for: []), .absolute)
    }

    func testOptionInsertsTheFileNameAlone() {
        XCTAssertEqual(TerminalFileDropModifiers.style(for: [.option]), .name)
    }

    func testShiftInsertsARelativePath() {
        XCTAssertEqual(TerminalFileDropModifiers.style(for: [.shift]), .relative)
    }

    func testOptionWinsOverShift() {
        XCTAssertEqual(TerminalFileDropModifiers.style(for: [.option, .shift]), .name)
    }

    func testCommandAndControlAreIgnored() {
        XCTAssertEqual(TerminalFileDropModifiers.style(for: [.command, .control]), .absolute)
    }
}
