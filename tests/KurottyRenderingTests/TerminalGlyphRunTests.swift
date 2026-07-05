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
        XCTAssertEqual(decoded.source.range, run.source.range)
        XCTAssertEqual(decoded.source.graphemeClusterCount, run.source.graphemeClusterCount)
        XCTAssertEqual(decoded.source.graphemeClusters.first?.range, run.source.graphemeClusters.first?.range)
        XCTAssertEqual(decoded.source.graphemeClusters.first?.terminalCellWidth, 1)
        XCTAssertEqual(decoded.source.text, "")
        XCTAssertEqual(decoded.source.graphemeClusters.map(\.text), [""])
        XCTAssertEqual(decoded.glyphs, run.glyphs)
        XCTAssertEqual(decoded.diagnosticFlags, run.diagnosticFlags)
    }

    func testKoreanSyllableAndWideEmojiExposeTerminalCellWidth() {
        let korean = TerminalGlyphRun.diagnosticModel(
            sourceText: "한",
            sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 1),
            fallbackFont: .primary(name: "Menlo", identifier: "menlo-regular"),
            fallbackChain: [
                .primary(name: "Menlo", identifier: "menlo-regular", requestedPresentation: .cjk),
                .systemCascade(name: "Apple SD Gothic Neo", identifier: "apple-sd-gothic-neo", requestedPresentation: .cjk),
            ],
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
            atlasKey: TerminalGlyphAtlasKey(value: "Menlo/hangul/15/1x"),
            shaping: TerminalGlyphShapingDiagnostics(engine: .diagnostic, status: .shaped),
            atlas: TerminalGlyphAtlasMetadata(
                ownership: .glyphCache,
                slot: TerminalGlyphAtlasSlotMetadata(index: 12, x: 72, y: 24, width: 18, height: 18, generation: 3)
            ),
            clipping: TerminalGlyphClippingMetrics(
                inkBounds: TerminalGlyphBounds(x: 0, y: -3, width: 17, height: 16),
                cellBounds: TerminalGlyphBounds(x: 0, y: -4, width: 18, height: 18),
                overhang: TerminalGlyphOverhang(left: 0, right: 0, top: 0, bottom: 0),
                clippedEdges: []
            )
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
        XCTAssertEqual(korean.shaping.engine, .diagnostic)
        XCTAssertEqual(korean.shaping.status, .shaped)
        XCTAssertEqual(korean.fallbackChain.map(\.identifier), ["menlo-regular", "apple-sd-gothic-neo"])
        XCTAssertEqual(korean.atlas.ownership, .glyphCache)
        XCTAssertEqual(korean.atlas.slot?.index, 12)
        XCTAssertEqual(korean.clipping.overhang, TerminalGlyphOverhang(left: 0, right: 0, top: 0, bottom: 0))
        XCTAssertEqual(korean.clipping.clippedEdges, [])
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
            shaping: TerminalGlyphShapingDiagnostics(engine: .diagnostic, status: .substituted),
            clipping: TerminalGlyphClippingMetrics(
                inkBounds: TerminalGlyphBounds(x: -1, y: -2, width: 20, height: 13),
                cellBounds: TerminalGlyphBounds(x: 0, y: -2, width: 18, height: 14),
                overhang: TerminalGlyphOverhang(left: 1, right: 1, top: 0, bottom: 0),
                clippedEdges: [.left, .right]
            ),
            diagnosticFlags: [.ligatureCluster]
        )

        XCTAssertEqual(run.source.graphemeClusterCount, 2)
        XCTAssertEqual(run.glyphs.count, 1)
        XCTAssertEqual(run.terminalCellWidth, 2)
        XCTAssertEqual(run.shaping.status, .substituted)
        XCTAssertEqual(run.clipping.clippedEdges, [.left, .right])
        XCTAssertTrue(run.diagnosticFlags.contains(.clippedInkBounds))
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

    func testDiagnosticContractDefaultsDoNotLeakRendererOwnership() throws {
        let run = TerminalGlyphRun.diagnosticModel(
            sourceText: "a",
            sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 1),
            fallbackFont: .primary(name: "Menlo", identifier: "menlo-regular"),
            glyphs: [TerminalGlyph(glyphID: 65, sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 1))],
            advance: TerminalGlyphAdvance(x: 9, y: 0),
            bounds: TerminalGlyphBounds(x: 0, y: -2, width: 8, height: 12),
            atlasKey: TerminalGlyphAtlasKey(value: "Menlo/a/15/1x")
        )

        XCTAssertEqual(run.shaping, .unshapedDiagnostic)
        XCTAssertEqual(run.fallbackChain, [run.fallbackFont])
        XCTAssertEqual(run.atlas.ownership, .unassigned)
        XCTAssertNil(run.atlas.slot)
        XCTAssertEqual(run.clipping.overhang, .zero)
        XCTAssertEqual(run.clipping.clippedEdges, [])

        let json = String(data: try JSONEncoder().encode(run), encoding: .utf8) ?? ""
        XCTAssertFalse(json.localizedCaseInsensitiveContains("renderer"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("metal"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("appkit"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("coretext"))

        let decoded = try JSONDecoder().decode(TerminalGlyphRun.self, from: Data("""
        {
          "source": {
            "text": "a",
            "range": { "utf16Location": 0, "utf16Length": 1 },
            "graphemeClusterCount": 1,
            "unicodeScalarValues": [97]
          },
          "terminalCellWidth": 1,
          "fallbackFont": {
            "decision": "primary",
            "name": "Menlo",
            "identifier": "menlo-regular",
            "requestedPresentation": "unspecified"
          },
          "glyphs": [],
          "advance": { "x": 9, "y": 0 },
          "bounds": { "x": 0, "y": -2, "width": 8, "height": 12 },
          "atlasKey": { "value": "Menlo/a/15/1x" },
          "diagnosticFlags": []
        }
        """.utf8))

        XCTAssertEqual(decoded.shaping, .unshapedDiagnostic)
        XCTAssertEqual(decoded.fallbackChain, [decoded.fallbackFont])
        XCTAssertEqual(decoded.atlas.ownership, .unassigned)
        XCTAssertEqual(decoded.clipping.overhang, .zero)
    }

    func testSerializedGlyphDiagnosticsDoNotExposeRawSourceText() throws {
        let run = TerminalGlyphRun.productionModel(
            sourceText: "secret-token",
            sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 12),
            fallbackFont: .primary(name: "Menlo", identifier: "menlo-regular"),
            glyphs: [
                TerminalGlyph(glyphID: 99, sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 12)),
            ],
            advance: TerminalGlyphAdvance(x: 90, y: 0),
            bounds: TerminalGlyphBounds(x: 0, y: -2, width: 90, height: 14),
            atlasSlot: TerminalGlyphAtlasSlotMetadata(index: 2, x: 16, y: 16, width: 22, height: 18),
            pointSizePixels: 18,
            scale: 2
        )

        let json = String(data: try JSONEncoder().encode(run), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("secret-token"))
        XCTAssertFalse(json.contains("\"text\""))
        XCTAssertFalse(json.contains("[115,101,99,114,101,116,45,116,111,107,101,110]"))
        XCTAssertFalse(json.contains("\"unicodeScalarValues\""))
        XCTAssertFalse(json.contains("U+0073-U+0065-U+0063-U+0072-U+0065-U+0074-U+002D-U+0074-U+006F-U+006B-U+0065-U+006E"))
        XCTAssertFalse(json.contains("\"sourceFingerprint\""))
        XCTAssertFalse(json.contains("missing-glyph/secret-token"))
        XCTAssertTrue(json.contains("source-redacted"))
        XCTAssertTrue(json.contains("\"unicodeScalarCount\""))
        XCTAssertTrue(json.contains("\"graphemeClusterCount\""))
    }

    func testBackendContractSummarizesShapingFallbackAtlasAndClippingReadiness() throws {
        let run = TerminalGlyphRun.diagnosticModel(
            sourceText: "한",
            sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 1),
            fallbackFont: .primary(name: "Menlo", identifier: "menlo-regular", requestedPresentation: .cjk),
            fallbackChain: [
                .primary(name: "Menlo", identifier: "menlo-regular", requestedPresentation: .cjk),
                .systemCascade(name: "Apple SD Gothic Neo", identifier: "apple-sd-gothic-neo", requestedPresentation: .cjk),
            ],
            glyphs: [
                TerminalGlyph(glyphID: 4001, sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 1)),
            ],
            advance: TerminalGlyphAdvance(x: 18, y: 0),
            bounds: TerminalGlyphBounds(x: -1, y: -3, width: 20, height: 16),
            atlasKey: TerminalGlyphAtlasKey.separated(
                fontIdentifier: "apple-sd-gothic-neo",
                presentation: .cjk,
                sourceFingerprint: "U+D55C",
                glyphIDs: [4001],
                pointSizePixels: 18,
                scale: 2
            ),
            shaping: TerminalGlyphShapingDiagnostics(engine: .platformShaper, status: .fallbackResolved),
            atlas: TerminalGlyphAtlasMetadata(
                ownership: .sharedFontAtlas,
                slot: TerminalGlyphAtlasSlotMetadata(index: 7, x: 64, y: 32, width: 22, height: 18)
            ),
            clipping: TerminalGlyphClippingMetrics(
                inkBounds: TerminalGlyphBounds(x: -1, y: -3, width: 20, height: 16),
                cellBounds: TerminalGlyphBounds(x: 0, y: -3, width: 18, height: 16),
                overhang: TerminalGlyphOverhang(left: 1, right: 1, top: 0, bottom: 0),
                clippedEdges: [.left, .right]
            )
        )

        XCTAssertEqual(run.contract.shapingReadiness, .ready)
        XCTAssertEqual(run.contract.fallbackResolution, .fallbackChainResolved)
        XCTAssertEqual(run.contract.atlasReadiness, .resident)
        XCTAssertEqual(run.contract.atlasOwnership, .sharedFontAtlas)
        XCTAssertEqual(run.contract.clippingRisk, .clipped)
        XCTAssertEqual(run.contract.validationFlags, [.fallbackChainUsed, .atlasSlotAssigned, .clippingRisk])

        let decoded = try JSONDecoder().decode(TerminalGlyphRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(decoded.contract, run.contract)
    }

    func testProductionModelRequiresResidentAtlasAndPlatformShapingContract() {
        let run = TerminalGlyphRun.productionModel(
            sourceText: "한",
            sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 1),
            fallbackFont: .systemCascade(name: "Apple SD Gothic Neo", identifier: "apple-sd-gothic-neo", requestedPresentation: .cjk),
            fallbackChain: [
                .primary(name: "Menlo", identifier: "menlo-regular", requestedPresentation: .cjk),
                .systemCascade(name: "Apple SD Gothic Neo", identifier: "apple-sd-gothic-neo", requestedPresentation: .cjk),
            ],
            glyphs: [
                TerminalGlyph(
                    glyphID: 4_001,
                    sourceRange: TerminalGlyphSourceRange(utf16Location: 0, utf16Length: 1),
                    terminalCellWidth: 2,
                    advance: TerminalGlyphAdvance(x: 18, y: 0),
                    bounds: TerminalGlyphBounds(x: 0, y: -3, width: 17, height: 16)
                ),
            ],
            advance: TerminalGlyphAdvance(x: 18, y: 0),
            bounds: TerminalGlyphBounds(x: 0, y: -3, width: 17, height: 16),
            atlasSlot: TerminalGlyphAtlasSlotMetadata(index: 12, x: 72, y: 24, width: 18, height: 18, generation: 3),
            pointSizePixels: 18,
            scale: 2,
            clipping: TerminalGlyphClippingMetrics(
                inkBounds: TerminalGlyphBounds(x: 0, y: -3, width: 17, height: 16),
                cellBounds: TerminalGlyphBounds(x: 0, y: -4, width: 18, height: 18),
                overhang: .zero,
                clippedEdges: []
            )
        )

        XCTAssertTrue(run.contract.isProductionReady)
        XCTAssertEqual(run.shaping.engine, .platformShaper)
        XCTAssertEqual(run.shaping.status, .fallbackResolved)
        XCTAssertEqual(run.contract.shapingReadiness, .ready)
        XCTAssertEqual(run.contract.fallbackResolution, .fallbackChainResolved)
        XCTAssertEqual(run.contract.atlasReadiness, .resident)
        XCTAssertEqual(run.contract.atlasOwnership, .glyphCache)
        XCTAssertEqual(run.contract.clippingRisk, .none)
        XCTAssertEqual(run.atlas.slot?.index, 12)
        XCTAssertEqual(run.atlasKey.fontIdentifier, "apple-sd-gothic-neo")
        XCTAssertEqual(run.atlasKey.presentation, .cjk)
        XCTAssertEqual(run.atlasKey.glyphIDs, [4_001])
        XCTAssertEqual(run.atlasKey.pointSizePixels, 18)
        XCTAssertEqual(run.atlasKey.scale, 2)
        XCTAssertTrue(run.diagnosticFlags.contains(.wideCluster))
        XCTAssertTrue(run.diagnosticFlags.contains(.fallbackFontSelected))
    }

    func testBackendContractDefaultsForLegacyPayloads() throws {
        let decoded = try JSONDecoder().decode(TerminalGlyphRun.self, from: Data("""
        {
          "source": {
            "text": "?",
            "range": { "utf16Location": 3, "utf16Length": 1 },
            "graphemeClusterCount": 1,
            "unicodeScalarValues": [63]
          },
          "terminalCellWidth": 1,
          "fallbackFont": {
            "decision": "unresolved",
            "name": "",
            "identifier": "",
            "requestedPresentation": "unspecified"
          },
          "glyphs": [],
          "advance": { "x": 9, "y": 0 },
          "bounds": { "x": 0, "y": -2, "width": 8, "height": 12 },
          "atlasKey": { "value": "legacy/missing" },
          "shaping": { "engine": "diagnostic", "status": "missingGlyph" },
          "diagnosticFlags": ["missingGlyph"]
        }
        """.utf8))

        XCTAssertEqual(decoded.contract.shapingReadiness, .blocked)
        XCTAssertEqual(decoded.contract.fallbackResolution, .unresolved)
        XCTAssertEqual(decoded.contract.atlasReadiness, .unassigned)
        XCTAssertEqual(decoded.contract.atlasOwnership, .unassigned)
        XCTAssertEqual(decoded.contract.clippingRisk, .none)
        XCTAssertEqual(decoded.contract.validationFlags, [.missingGlyph, .fallbackUnresolved, .atlasUnassigned])
    }
}
