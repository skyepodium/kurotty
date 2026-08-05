import AppKit
import KurottyCore
import XCTest
@testable import KurottyApp

/// The editor used a hardcoded point size and was permanently soft-wrapped.
/// Both are settings now, and both have to reach tabs that are already open,
/// not just the next one.
@MainActor
final class CodeEditorSettingsTests: XCTestCase {
    private func makeEditor() -> TerminalCodeEditorView {
        let editor = TerminalCodeEditorView()
        editor.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        editor.layoutSubtreeIfNeeded()
        return editor
    }

    private func textView(in editor: TerminalCodeEditorView) throws -> NSTextView {
        let scrollView = try XCTUnwrap(
            editor.subviews.compactMap { $0 as? NSScrollView }.first
        )
        return try XCTUnwrap(scrollView.documentView as? NSTextView)
    }

    func testTheEditorCarriesTheNativeFindBar() throws {
        // Cmd+F, Cmd+G, and the Find menu items come from AppKit rather than a
        // bespoke bar, so this is the whole contract for find-in-file.
        let editor = makeEditor()
        let textView = try textView(in: editor)
        XCTAssertTrue(textView.usesFindBar)
        XCTAssertTrue(textView.isIncrementalSearchingEnabled)
    }

    func testDefaultsKeepTheEditorUnwrappedAtThirteenPoint() {
        XCTAssertEqual(SettingsDefaults.codeEditorFontSizePT, 13)
        XCTAssertFalse(SettingsDefaults.codeEditorWrapsLines)
        XCTAssertLessThan(
            SettingsDefaults.minimumCodeEditorFontSizePT,
            SettingsDefaults.maximumCodeEditorFontSizePT
        )
    }

    func testTheEditorSizeIsSeparateFromTheTerminalSize() {
        // One number cannot serve both: the terminal is sized for a cell grid
        // and the editor for prose-length lines.
        let settings = AppSettings.default
        XCTAssertNotNil(settings.terminal.codeEditorFontSize)
        var changed = settings
        changed.terminal.codeEditorFontSize = 18
        XCTAssertEqual(changed.terminal.fontSize, settings.terminal.fontSize)
    }

    func testSettingsWithoutTheEditorKeysStillDecode() throws {
        // Files written by an older schema must not fail to decode; they take
        // the current defaults instead. Built by stripping the keys off a real
        // encode so the rest of the document stays valid as the schema grows.
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var terminal = try XCTUnwrap(object["terminal"] as? [String: Any])
        terminal.removeValue(forKey: "codeEditorFontSize")
        terminal.removeValue(forKey: "codeEditorWrapsLines")
        object["terminal"] = terminal
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let settings = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertEqual(settings.terminal.codeEditorFontSize, SettingsDefaults.codeEditorFontSizePT)
        XCTAssertEqual(settings.terminal.codeEditorWrapsLines, SettingsDefaults.codeEditorWrapsLines)
    }

    func testTheEditorSettingsSurviveARoundTrip() throws {
        var settings = AppSettings.default
        settings.terminal.codeEditorFontSize = 17
        settings.terminal.codeEditorWrapsLines = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.terminal.codeEditorFontSize, 17)
        XCTAssertTrue(decoded.terminal.codeEditorWrapsLines)
    }

    func testWrappingOffLetsLinesRunAndScrollHorizontally() throws {
        let editor = makeEditor()
        let textView = try textView(in: editor)
        let scrollView = try XCTUnwrap(editor.subviews.compactMap { $0 as? NSScrollView }.first)
        // The default is unwrapped, which is what `load` applies.
        editor.applyEditorSettings()
        XCTAssertTrue(textView.isHorizontallyResizable)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
        // A container left tracking the view width silently keeps folding even
        // with horizontal resizing on, so this is the assertion that matters.
        XCTAssertFalse(textView.textContainer?.widthTracksTextView ?? true)
    }
}
