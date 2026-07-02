import XCTest
@testable import KurottyCore

final class TerminalGlyphRunTests: XCTestCase {
    func testCombiningClusterPreservesSourceRangeAndZeroWidthMarkMetadata() throws {
        let run = TerminalGlyphRun.diagnosticModel(
            sourceText: "e\u{301}",
            sourceRange: TerminalGlyphSourceRange(utf16Location: 4, utf16Length: 2),
            fallbackFont: .primary(name: "Menlo", identifier: "menlo-regular"),
            glyphs: [
                TerminalGlyph(glyphID: 121, sourceRange: TerminalGlyphSourceRange(utf16Location: 4, utf16Length: 2)),
            ],
            advance: TerminalGlyphAdvance(x: 9, y: 0),
            bounds: TerminalGlyphBounds(x: 0, y: -2, width: 9, height: 14),
            atlasKey: TerminalGlyphAtlasKey(value: "Menlo/e-acute/15/1x")
        )

        XCTAssertEqual(run.source.text, "e\u{301}")
        XCTAssertEqual(run.source.range, TerminalGlyphSourceRange(utf16Location: 4, utf16Length: 2))
        XCTAssertEqual(run.source.graphemeClusters.map(\.text), ["e\u{301}"])
        XCTAssertEqual(run.source.graphemeClusters.first?.range, TerminalGlyphSourceRange(utf16Location: 4, utf16Length: 2))
        XCTAssertEqual(run.source.graphemeClusters.first?.terminalCellWidth, 1)
        XCTAssertEqual(run.terminalCellWidth, 1)
        XCTAssertTrue(run.diagnosticFlags.contains(.containsCombiningMarks))
        XCTAssertFalse(run.diagnosticFlags.contains(.wideCluster))

        let decoded = try JSONDecoder().decode(TerminalGlyphRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(decoded, run)
    }

    func testKoreanSyllableAndWideEmojiExposeTerminalCellWidth() {
        let korean = TerminalGlyphRun.diagnosticModel(
            sourceText: "한",
            sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 1),
            fallbackFont: .primary(name: "Menlo", identifier: "menlo-regular"),
            glyphs: [
                TerminalGlyph(
                    glyphID: 4001,
                    sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 1),
                    terminalCellWidth: 2,
                    advance: TerminalGlyphAdvance(x: 18, y: 0),
                    bounds: TerminalGlyphBounds(x: 0, y: -3, width: 17, height: 16)
                ),
            ],
            advance: TerminalGlyphAdvance(x: 18, y: 0),
            bounds: TerminalGlyphBounds(x: 0, y: -3, width: 17, height: 16),
            atlasKey: TerminalGlyphAtlasKey(value: "Menlo/hangul/15/1x")
        )
        let emoji = TerminalGlyphRun.diagnosticModel(
            sourceText: "🧑‍💻",
            sourceRange: TerminalGlyphSourceRange(utf16Location: 1, utf16Length: 5),
            fallbackFont: .systemCascade(name: "Apple Color Emoji", identifier: "apple-color-emoji", requestedPresentation: .emoji),
            glyphs: [TerminalGlyph(glyphID: 90210, sourceRange: TerminalGlyphSourceRange(utf16Location: 1, utf16Length: 5))],
            advance: TerminalGlyphAdvance(x: 18, y: 0),
            bounds: TerminalGlyphBounds(x: -1, y: -2, width: 20, height: 20),
            atlasKey: TerminalGlyphAtlasKey(value: "AppleColorEmoji/person-technologist/15/2c")
        )

        XCTAssertEqual(korean.terminalCellWidth, 2)
        XCTAssertEqual(korean.source.graphemeClusters.first?.terminalCellWidth, 2)
        XCTAssertEqual(korean.glyphs.first?.terminalCellWidth, 2)
        XCTAssertEqual(korean.glyphs.first?.advance, TerminalGlyphAdvance(x: 18, y: 0))
        XCTAssertEqual(korean.glyphs.first?.bounds, TerminalGlyphBounds(x: 0, y: -3, width: 17, height: 16))
        XCTAssertTrue(korean.diagnosticFlags.contains(.wideCluster))
        XCTAssertEqual(emoji.terminalCellWidth, 2)
        XCTAssertEqual(emoji.source.graphemeClusters, [
            TerminalGlyphSourceGraphemeCluster(
                text: "🧑‍💻",
                range: TerminalGlyphSourceRange(utf16Location: 1, utf16Length: 5),
                terminalCellWidth: 2,
                unicodeScalarValues: [0x1f9d1, 0x200d, 0x1f4bb]
            ),
        ])
        XCTAssertTrue(emoji.diagnosticFlags.contains(.wideCluster))
        XCTAssertTrue(emoji.diagnosticFlags.contains(.containsZeroWidthJoiner))
        XCTAssertEqual(emoji.fallbackFont.requestedPresentation, .emoji)
    }

    func testFallbackFontDecisionCarriesConfiguredAndCascadeMetadata() {
        let configured = TerminalGlyphFallbackFont.configured(
            name: "Symbols Nerd Font Mono",
            identifier: "symbols-nerd-font-mono",
            requestedPresentation: .text
        )
        let cascade = TerminalGlyphFallbackFont.systemCascade(
            name: "Apple Color Emoji",
            identifier: "apple-color-emoji",
            requestedPresentation: .emoji
        )

        XCTAssertEqual(configured.decision, .configuredFallback)
        XCTAssertEqual(configured.name, "Symbols Nerd Font Mono")
        XCTAssertEqual(configured.requestedPresentation, .text)
        XCTAssertEqual(cascade.decision, .systemCascade)
        XCTAssertEqual(cascade.requestedPresentation, .emoji)
    }

    func testLigatureClusterCanMapMultipleSourceCharactersToOneGlyph() {
        let sourceRange = TerminalGlyphSourceRange(utf16Location: 10, utf16Length: 2)
        let run = TerminalGlyphRun.diagnosticModel(
            sourceText: "fi",
            sourceRange: sourceRange,
            fallbackFont: .primary(name: "Fira Code", identifier: "fira-code-regular"),
            glyphs: [
                TerminalGlyph(glyphID: 64257, sourceRange: sourceRange),
            ],
            advance: TerminalGlyphAdvance(x: 18, y: 0),
            bounds: TerminalGlyphBounds(x: 0, y: -2, width: 17, height: 13),
            atlasKey: TerminalGlyphAtlasKey(value: "FiraCode/fi-ligature/15/2c"),
            diagnosticFlags: [.ligatureCluster]
        )

        XCTAssertEqual(run.source.graphemeClusterCount, 2)
        XCTAssertEqual(run.glyphs.count, 1)
        XCTAssertEqual(run.terminalCellWidth, 2)
        XCTAssertTrue(run.diagnosticFlags.contains(.ligatureCluster))
    }

    func testAtlasKeyCanSeparateFontPresentationSourceGlyphAndScaleIdentity() {
        let cjkKey = TerminalGlyphAtlasKey.separated(
            fontIdentifier: "menlo-regular",
            presentation: .cjk,
            sourceFingerprint: "U+D55C",
            glyphIDs: [4001],
            pointSizePixels: 18,
            scale: 2
        )
        let emojiKey = TerminalGlyphAtlasKey.separated(
            fontIdentifier: "apple-color-emoji",
            presentation: .emoji,
            sourceFingerprint: "U+1F9D1-U+200D-U+1F4BB",
            glyphIDs: [90210],
            pointSizePixels: 18,
            scale: 2
        )

        XCTAssertNotEqual(cjkKey, emojiKey)
        XCTAssertEqual(cjkKey.fontIdentifier, "menlo-regular")
        XCTAssertEqual(cjkKey.presentation, .cjk)
        XCTAssertEqual(cjkKey.sourceFingerprint, "U+D55C")
        XCTAssertEqual(cjkKey.glyphIDs, [4001])
        XCTAssertEqual(cjkKey.pointSizePixels, 18)
        XCTAssertEqual(cjkKey.scale, 2)
        XCTAssertTrue(cjkKey.value.contains("menlo-regular/cjk/U+D55C/4001/18px/2x"))
    }
}
