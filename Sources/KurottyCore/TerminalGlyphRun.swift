import Foundation
#if canImport(CoreText)
import CoreText
#endif

public struct TerminalGlyphRun: Codable, Equatable, Sendable {
    public let source: TerminalGlyphSourceCluster
    public let terminalCellWidth: Int
    public let fallbackFont: TerminalGlyphFallbackFont
    public let fallbackChain: [TerminalGlyphFallbackFont]
    public let glyphs: [TerminalGlyph]
    public let advance: TerminalGlyphAdvance
    public let bounds: TerminalGlyphBounds
    public let atlasKey: TerminalGlyphAtlasKey
    public let shaping: TerminalGlyphShapingDiagnostics
    public let atlas: TerminalGlyphAtlasMetadata
    public let clipping: TerminalGlyphClippingMetrics
    public let contract: TerminalGlyphBackendContract
    public let diagnosticFlags: Set<TerminalGlyphDiagnosticFlag>

    public init(
        source: TerminalGlyphSourceCluster,
        terminalCellWidth: Int,
        fallbackFont: TerminalGlyphFallbackFont,
        fallbackChain: [TerminalGlyphFallbackFont]? = nil,
        glyphs: [TerminalGlyph],
        advance: TerminalGlyphAdvance,
        bounds: TerminalGlyphBounds,
        atlasKey: TerminalGlyphAtlasKey,
        shaping: TerminalGlyphShapingDiagnostics = .unshapedDiagnostic,
        atlas: TerminalGlyphAtlasMetadata = .unassigned,
        clipping: TerminalGlyphClippingMetrics = .zero,
        contract: TerminalGlyphBackendContract? = nil,
        diagnosticFlags: Set<TerminalGlyphDiagnosticFlag>
    ) {
        self.source = source
        self.terminalCellWidth = terminalCellWidth
        self.fallbackFont = fallbackFont
        self.fallbackChain = fallbackChain ?? [fallbackFont]
        self.glyphs = glyphs
        self.advance = advance
        self.bounds = bounds
        self.atlasKey = atlasKey
        self.shaping = shaping
        self.atlas = atlas
        self.clipping = clipping
        self.contract = contract ?? TerminalGlyphBackendContract(
            shaping: shaping,
            fallbackFont: fallbackFont,
            fallbackChain: self.fallbackChain,
            atlas: atlas,
            clipping: clipping
        )
        self.diagnosticFlags = diagnosticFlags
    }

    enum CodingKeys: String, CodingKey {
        case source
        case terminalCellWidth
        case fallbackFont
        case fallbackChain
        case glyphs
        case advance
        case bounds
        case atlasKey
        case shaping
        case atlas
        case clipping
        case contract
        case diagnosticFlags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(TerminalGlyphSourceCluster.self, forKey: .source)
        terminalCellWidth = try container.decode(Int.self, forKey: .terminalCellWidth)
        fallbackFont = try container.decode(TerminalGlyphFallbackFont.self, forKey: .fallbackFont)
        fallbackChain = try container.decodeIfPresent([TerminalGlyphFallbackFont].self, forKey: .fallbackChain) ?? [fallbackFont]
        glyphs = try container.decode([TerminalGlyph].self, forKey: .glyphs)
        advance = try container.decode(TerminalGlyphAdvance.self, forKey: .advance)
        bounds = try container.decode(TerminalGlyphBounds.self, forKey: .bounds)
        atlasKey = try container.decode(TerminalGlyphAtlasKey.self, forKey: .atlasKey)
        shaping = try container.decodeIfPresent(TerminalGlyphShapingDiagnostics.self, forKey: .shaping) ?? .unshapedDiagnostic
        atlas = try container.decodeIfPresent(TerminalGlyphAtlasMetadata.self, forKey: .atlas) ?? .unassigned
        clipping = try container.decodeIfPresent(TerminalGlyphClippingMetrics.self, forKey: .clipping) ?? .zero
        contract = try container.decodeIfPresent(TerminalGlyphBackendContract.self, forKey: .contract) ?? TerminalGlyphBackendContract(
            shaping: shaping,
            fallbackFont: fallbackFont,
            fallbackChain: fallbackChain,
            atlas: atlas,
            clipping: clipping
        )
        diagnosticFlags = try container.decode(Set<TerminalGlyphDiagnosticFlag>.self, forKey: .diagnosticFlags)
    }

    public static func diagnosticModel(
        sourceText: String,
        sourceRange: TerminalGlyphSourceRange,
        fallbackFont: TerminalGlyphFallbackFont,
        fallbackChain: [TerminalGlyphFallbackFont]? = nil,
        glyphs: [TerminalGlyph],
        advance: TerminalGlyphAdvance,
        bounds: TerminalGlyphBounds,
        atlasKey: TerminalGlyphAtlasKey,
        shaping: TerminalGlyphShapingDiagnostics = .unshapedDiagnostic,
        atlas: TerminalGlyphAtlasMetadata = .unassigned,
        clipping: TerminalGlyphClippingMetrics? = nil,
        contract: TerminalGlyphBackendContract? = nil,
        diagnosticFlags explicitDiagnosticFlags: Set<TerminalGlyphDiagnosticFlag> = []
    ) -> TerminalGlyphRun {
        let source = TerminalGlyphSourceCluster(text: sourceText, range: sourceRange)
        let width = sourceText.terminalColumnWidth
        let clipping = clipping ?? .unclipped(inkBounds: bounds, cellBounds: bounds)
        let inferredDiagnosticFlags = TerminalGlyphDiagnosticFlag.flags(for: sourceText, terminalCellWidth: width)
            .union(TerminalGlyphDiagnosticFlag.flags(for: clipping))

        return TerminalGlyphRun(
            source: source,
            terminalCellWidth: width,
            fallbackFont: fallbackFont,
            fallbackChain: fallbackChain,
            glyphs: glyphs,
            advance: advance,
            bounds: bounds,
            atlasKey: atlasKey,
            shaping: shaping,
            atlas: atlas,
            clipping: clipping,
            contract: contract,
            diagnosticFlags: inferredDiagnosticFlags.union(explicitDiagnosticFlags)
        )
    }

#if canImport(CoreText)
    public static func coreTextModel(
        sourceText: String,
        sourceRange: TerminalGlyphSourceRange,
        fontName: String,
        pointSizePixels: Int,
        scale: Int,
        cellSizePixels: TerminalGlyphCellSize
    ) -> TerminalGlyphRun {
        let pointSize = max(1, CGFloat(pointSizePixels)) / max(1, CGFloat(scale))
        let baseFont = CTFontCreateWithName(fontName as CFString, pointSize, nil)
        let attributed = NSAttributedString(
            string: sourceText,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): baseFont]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(line) as NSArray

        var glyphs: [TerminalGlyph] = []
        var fallbackChain: [TerminalGlyphFallbackFont] = []
        struct CoreTextGlyphRecord {
            let glyphID: UInt32
            let stringIndex: Int
            let advance: CGSize
            let fallbackFont: TerminalGlyphFallbackFont
        }
        var glyphRecords: [CoreTextGlyphRecord] = []
        var typographicAscent: CGFloat = 0
        var typographicDescent: CGFloat = 0
        var typographicLeading: CGFloat = 0
        let typographicWidth = CTLineGetTypographicBounds(line, &typographicAscent, &typographicDescent, &typographicLeading)
        let imageBounds = CTLineGetImageBounds(line, nil)

        for runValue in runs {
            guard CFGetTypeID(runValue as CFTypeRef) == CTRunGetTypeID() else {
                continue
            }
            let run = unsafeDowncast(runValue as AnyObject, to: CTRun.self)
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else {
                continue
            }

            let runFont = TerminalGlyphRun.coreTextFont(from: run) ?? baseFont
            let fallbackFont = TerminalGlyphFallbackFont.coreTextFont(
                runFont,
                primaryFontName: fontName,
                requestedPresentation: TerminalGlyphPresentation(sourceText: sourceText)
            )
            if fallbackChain.last != fallbackFont {
                fallbackChain.append(fallbackFont)
            }

            var runGlyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &runGlyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)

            for index in 0..<glyphCount {
                let glyphID = UInt32(runGlyphs[index])
                glyphRecords.append(CoreTextGlyphRecord(
                    glyphID: glyphID,
                    stringIndex: max(0, stringIndices[index]),
                    advance: advances[index],
                    fallbackFont: fallbackFont
                ))
            }
        }

        glyphRecords.sort {
            if $0.stringIndex == $1.stringIndex {
                return $0.glyphID < $1.glyphID
            }
            return $0.stringIndex < $1.stringIndex
        }
        for index in glyphRecords.indices {
            let record = glyphRecords[index]
            let localLocation = min(record.stringIndex, sourceText.utf16.count)
            let nextLocation = glyphRecords[(index + 1)...]
                .map(\.stringIndex)
                .first(where: { $0 > localLocation })
                ?? sourceText.utf16.count
            let utf16Length = max(1, nextLocation - localLocation)
            glyphs.append(TerminalGlyph(
                glyphID: record.glyphID,
                sourceRange: TerminalGlyphSourceRange(
                    utf16Location: sourceRange.utf16Location + localLocation,
                    utf16Length: utf16Length
                ),
                advance: TerminalGlyphAdvance(
                    x: Double(record.advance.width * CGFloat(scale)),
                    y: Double(record.advance.height * CGFloat(scale))
                )
            ))
        }

        let terminalCellWidth = sourceText.terminalColumnWidth
        let fallbackFont = fallbackChain.last ?? TerminalGlyphFallbackFont.coreTextFont(
            baseFont,
            primaryFontName: fontName,
            requestedPresentation: TerminalGlyphPresentation(sourceText: sourceText)
        )
        if fallbackChain.isEmpty {
            fallbackChain = [fallbackFont]
        }
        let atlasFont = TerminalGlyphRun.atlasFontIdentity(for: fallbackChain)

        let bounds = TerminalGlyphBounds(
            x: Double(imageBounds.origin.x * CGFloat(scale)),
            y: Double(imageBounds.origin.y * CGFloat(scale)),
            width: Double(imageBounds.width * CGFloat(scale)),
            height: Double(imageBounds.height * CGFloat(scale))
        )
        let cellBounds = TerminalGlyphBounds(
            x: 0,
            y: -Double(typographicDescent * CGFloat(scale)),
            width: Double(max(1, terminalCellWidth) * cellSizePixels.width),
            height: Double(cellSizePixels.height)
        )
        let clipping = TerminalGlyphClippingMetrics.classified(inkBounds: bounds, cellBounds: cellBounds)
        let sourceFingerprint = TerminalGlyphAtlasKey.sourceFingerprint(for: sourceText)
        let atlasKey = TerminalGlyphAtlasKey.separated(
            fontIdentifier: atlasFont.identifier,
            presentation: atlasFont.requestedPresentation,
            sourceFingerprint: sourceFingerprint,
            glyphIDs: glyphRecords.map(\.glyphID),
            pointSizePixels: pointSizePixels,
            scale: scale
        )

        return TerminalGlyphRun.diagnosticModel(
            sourceText: sourceText,
            sourceRange: sourceRange,
            fallbackFont: fallbackFont,
            fallbackChain: fallbackChain,
            glyphs: glyphs,
            advance: TerminalGlyphAdvance(x: Double(typographicWidth * CGFloat(scale)), y: 0),
            bounds: bounds,
            atlasKey: atlasKey,
            shaping: TerminalGlyphShapingDiagnostics(
                engine: .platformShaper,
                status: glyphs.contains(where: { $0.glyphID == 0 }) ? .missingGlyph : (fallbackChain.count > 1 ? .fallbackResolved : .shaped)
            ),
            atlas: TerminalGlyphAtlasMetadata(ownership: .sharedFontAtlas),
            clipping: clipping,
            diagnosticFlags: glyphs.count == 1 && sourceText.count > 1 ? [.ligatureCluster] : []
        )
    }

    private static func atlasFontIdentity(for fallbackChain: [TerminalGlyphFallbackFont]) -> TerminalGlyphFallbackFont {
        guard let first = fallbackChain.first else {
            return TerminalGlyphFallbackFont.primary(
                name: "unknown",
                identifier: "unknown",
                requestedPresentation: .unspecified
            )
        }
        let identifiers = fallbackChain.map(\.identifier)
        guard Set(identifiers).count > 1 else {
            return first
        }
        let mixedIdentifier = "mixed(\(identifiers.joined(separator: "+")))"
        let presentation = fallbackChain.reduce(TerminalGlyphPresentation.unspecified) { current, font in
            current == .unspecified ? font.requestedPresentation : current
        }
        return TerminalGlyphFallbackFont.systemCascade(
            name: "Mixed CoreText runs",
            identifier: mixedIdentifier,
            requestedPresentation: presentation
        )
    }

    private static func coreTextFont(from run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let fontValue = attributes[kCTFontAttributeName as String],
              CFGetTypeID(fontValue as CFTypeRef) == CTFontGetTypeID() else {
            return nil
        }
        return unsafeDowncast(fontValue as AnyObject, to: CTFont.self)
    }
#endif
}

public struct TerminalGlyphSourceCluster: Codable, Equatable, Sendable {
    public let text: String
    public let range: TerminalGlyphSourceRange
    public let graphemeClusterCount: Int
    public let graphemeClusters: [TerminalGlyphSourceGraphemeCluster]
    public let unicodeScalarValues: [UInt32]

    public init(text: String, range: TerminalGlyphSourceRange) {
        self.text = text
        self.range = range
        self.graphemeClusterCount = text.count
        self.graphemeClusters = TerminalGlyphSourceGraphemeCluster.clusters(in: text, startingAt: range.utf16Location)
        self.unicodeScalarValues = text.unicodeScalars.map(\.value)
    }

    enum CodingKeys: String, CodingKey {
        case text
        case range
        case graphemeClusterCount
        case graphemeClusters
        case unicodeScalarValues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        range = try container.decode(TerminalGlyphSourceRange.self, forKey: .range)
        graphemeClusterCount = try container.decode(Int.self, forKey: .graphemeClusterCount)
        graphemeClusters = try container.decodeIfPresent(
            [TerminalGlyphSourceGraphemeCluster].self,
            forKey: .graphemeClusters
        ) ?? TerminalGlyphSourceGraphemeCluster.clusters(in: text, startingAt: range.utf16Location)
        unicodeScalarValues = try container.decode([UInt32].self, forKey: .unicodeScalarValues)
    }
}

public struct TerminalGlyphSourceGraphemeCluster: Codable, Equatable, Sendable {
    public let text: String
    public let range: TerminalGlyphSourceRange
    public let terminalCellWidth: Int
    public let unicodeScalarValues: [UInt32]

    public init(text: String, range: TerminalGlyphSourceRange, terminalCellWidth: Int, unicodeScalarValues: [UInt32]) {
        self.text = text
        self.range = range
        self.terminalCellWidth = terminalCellWidth
        self.unicodeScalarValues = unicodeScalarValues
    }

    fileprivate static func clusters(in text: String, startingAt utf16Location: Int) -> [TerminalGlyphSourceGraphemeCluster] {
        var location = utf16Location

        return text.map { character in
            let clusterText = String(character)
            let length = clusterText.utf16.count
            defer { location += length }

            return TerminalGlyphSourceGraphemeCluster(
                text: clusterText,
                range: TerminalGlyphSourceRange(utf16Location: location, utf16Length: length),
                terminalCellWidth: character.terminalColumnWidth,
                unicodeScalarValues: character.unicodeScalars.map(\.value)
            )
        }
    }
}

public struct TerminalGlyphSourceRange: Codable, Equatable, Hashable, Sendable {
    public let utf16Location: Int
    public let utf16Length: Int

    public init(utf16Location: Int, utf16Length: Int) {
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
    }
}

public struct TerminalGlyph: Codable, Equatable, Sendable {
    public let glyphID: UInt32
    public let sourceRange: TerminalGlyphSourceRange
    public let terminalCellWidth: Int?
    public let advance: TerminalGlyphAdvance?
    public let bounds: TerminalGlyphBounds?

    public init(
        glyphID: UInt32,
        sourceRange: TerminalGlyphSourceRange,
        terminalCellWidth: Int? = nil,
        advance: TerminalGlyphAdvance? = nil,
        bounds: TerminalGlyphBounds? = nil
    ) {
        self.glyphID = glyphID
        self.sourceRange = sourceRange
        self.terminalCellWidth = terminalCellWidth
        self.advance = advance
        self.bounds = bounds
    }
}

public struct TerminalGlyphFallbackFont: Codable, Equatable, Sendable {
    public let decision: Decision
    public let name: String
    public let identifier: String
    public let requestedPresentation: TerminalGlyphPresentation

    public init(
        decision: Decision,
        name: String,
        identifier: String,
        requestedPresentation: TerminalGlyphPresentation
    ) {
        self.decision = decision
        self.name = name
        self.identifier = identifier
        self.requestedPresentation = requestedPresentation
    }

    public static func primary(
        name: String,
        identifier: String,
        requestedPresentation: TerminalGlyphPresentation = .unspecified
    ) -> TerminalGlyphFallbackFont {
        TerminalGlyphFallbackFont(
            decision: .primary,
            name: name,
            identifier: identifier,
            requestedPresentation: requestedPresentation
        )
    }

    public static func configured(
        name: String,
        identifier: String,
        requestedPresentation: TerminalGlyphPresentation = .unspecified
    ) -> TerminalGlyphFallbackFont {
        TerminalGlyphFallbackFont(
            decision: .configuredFallback,
            name: name,
            identifier: identifier,
            requestedPresentation: requestedPresentation
        )
    }

    public static func systemCascade(
        name: String,
        identifier: String,
        requestedPresentation: TerminalGlyphPresentation = .unspecified
    ) -> TerminalGlyphFallbackFont {
        TerminalGlyphFallbackFont(
            decision: .systemCascade,
            name: name,
            identifier: identifier,
            requestedPresentation: requestedPresentation
        )
    }

    public enum Decision: String, Codable, Equatable, Sendable {
        case primary
        case configuredFallback
        case systemCascade
        case unresolved
    }
}

#if canImport(CoreText)
private extension TerminalGlyphFallbackFont {
    static func coreTextFont(
        _ font: CTFont,
        primaryFontName: String,
        requestedPresentation: TerminalGlyphPresentation
    ) -> TerminalGlyphFallbackFont {
        let displayName = (CTFontCopyDisplayName(font) as String?) ?? primaryFontName
        let postScriptName = (CTFontCopyPostScriptName(font) as String?) ?? displayName
        let identifier = stableIdentifier(for: postScriptName)
        let primaryIdentifier = stableIdentifier(for: primaryFontName)
        let decision: Decision = identifier == primaryIdentifier ? .primary : .systemCascade

        return TerminalGlyphFallbackFont(
            decision: decision,
            name: displayName,
            identifier: identifier,
            requestedPresentation: requestedPresentation
        )
    }

    static func stableIdentifier(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var scalars: [Character] = []
        var previousWasSeparator = false
        for character in folded {
            if character.isLetter || character.isNumber {
                scalars.append(character)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                scalars.append("-")
                previousWasSeparator = true
            }
        }
        return String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
#endif

public enum TerminalGlyphPresentation: String, Codable, Equatable, Sendable {
    case unspecified
    case text
    case emoji
    case cjk

    fileprivate init(sourceText: String) {
        if sourceText.unicodeScalars.contains(where: { (0x1f300...0x1faff).contains($0.value) }) {
            self = .emoji
        } else if sourceText.unicodeScalars.contains(where: { scalar in
            let value = scalar.value
            return (0x2e80...0xa4cf).contains(value) || (0xac00...0xd7a3).contains(value) || (0xf900...0xfaff).contains(value)
        }) {
            self = .cjk
        } else {
            self = .text
        }
    }
}

public struct TerminalGlyphAdvance: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct TerminalGlyphBounds: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TerminalGlyphShapingDiagnostics: Codable, Equatable, Sendable {
    public let engine: Engine
    public let status: Status

    public init(engine: Engine, status: Status) {
        self.engine = engine
        self.status = status
    }

    public static let unshapedDiagnostic = TerminalGlyphShapingDiagnostics(engine: .diagnostic, status: .unshaped)

    public enum Engine: String, Codable, Equatable, Sendable {
        case diagnostic
        case platformShaper
        case harfbuzz
        case unknown
    }

    public enum Status: String, Codable, Equatable, Sendable {
        case unshaped
        case shaped
        case substituted
        case fallbackResolved
        case missingGlyph
    }
}

public struct TerminalGlyphBackendContract: Codable, Equatable, Sendable {
    public let shapingReadiness: ShapingReadiness
    public let fallbackResolution: FallbackResolution
    public let atlasReadiness: AtlasReadiness
    public let atlasOwnership: TerminalGlyphAtlasMetadata.Ownership
    public let clippingRisk: ClippingRisk
    public let validationFlags: Set<ValidationFlag>

    public init(
        shapingReadiness: ShapingReadiness,
        fallbackResolution: FallbackResolution,
        atlasReadiness: AtlasReadiness,
        atlasOwnership: TerminalGlyphAtlasMetadata.Ownership,
        clippingRisk: ClippingRisk,
        validationFlags: Set<ValidationFlag>
    ) {
        self.shapingReadiness = shapingReadiness
        self.fallbackResolution = fallbackResolution
        self.atlasReadiness = atlasReadiness
        self.atlasOwnership = atlasOwnership
        self.clippingRisk = clippingRisk
        self.validationFlags = validationFlags
    }

    public init(
        shaping: TerminalGlyphShapingDiagnostics,
        fallbackFont: TerminalGlyphFallbackFont,
        fallbackChain: [TerminalGlyphFallbackFont],
        atlas: TerminalGlyphAtlasMetadata,
        clipping: TerminalGlyphClippingMetrics
    ) {
        let shapingReadiness = ShapingReadiness(shaping.status)
        let fallbackResolution = FallbackResolution(fallbackFont: fallbackFont, fallbackChain: fallbackChain)
        let atlasReadiness = AtlasReadiness(atlas: atlas)
        let clippingRisk = ClippingRisk(clipping: clipping)
        var validationFlags: Set<ValidationFlag> = []

        if shapingReadiness == .requiresShaping {
            validationFlags.insert(.requiresShaping)
        }
        if shapingReadiness == .blocked {
            validationFlags.insert(.missingGlyph)
        }
        if fallbackResolution == .unresolved {
            validationFlags.insert(.fallbackUnresolved)
        }
        if fallbackResolution == .fallbackChainResolved {
            validationFlags.insert(.fallbackChainUsed)
        }
        if atlasReadiness == .unassigned {
            validationFlags.insert(.atlasUnassigned)
        }
        if atlas.slot != nil {
            validationFlags.insert(.atlasSlotAssigned)
        }
        if clippingRisk != .none {
            validationFlags.insert(.clippingRisk)
        }

        self.init(
            shapingReadiness: shapingReadiness,
            fallbackResolution: fallbackResolution,
            atlasReadiness: atlasReadiness,
            atlasOwnership: atlas.ownership,
            clippingRisk: clippingRisk,
            validationFlags: validationFlags
        )
    }

    public enum ShapingReadiness: String, Codable, Equatable, Sendable {
        case requiresShaping
        case ready
        case blocked

        fileprivate init(_ status: TerminalGlyphShapingDiagnostics.Status) {
            switch status {
            case .unshaped:
                self = .requiresShaping
            case .shaped, .substituted, .fallbackResolved:
                self = .ready
            case .missingGlyph:
                self = .blocked
            }
        }
    }

    public enum FallbackResolution: String, Codable, Equatable, Sendable {
        case primaryResolved
        case fallbackChainResolved
        case unresolved

        fileprivate init(fallbackFont: TerminalGlyphFallbackFont, fallbackChain: [TerminalGlyphFallbackFont]) {
            if fallbackFont.decision == .unresolved || fallbackChain.contains(where: { $0.decision == .unresolved }) {
                self = .unresolved
            } else if fallbackFont.decision != .primary || fallbackChain.count > 1 {
                self = .fallbackChainResolved
            } else {
                self = .primaryResolved
            }
        }
    }

    public enum AtlasReadiness: String, Codable, Equatable, Sendable {
        case unassigned
        case reserved
        case resident

        fileprivate init(atlas: TerminalGlyphAtlasMetadata) {
            if atlas.ownership == .unassigned {
                self = .unassigned
            } else if atlas.slot == nil {
                self = .reserved
            } else {
                self = .resident
            }
        }
    }

    public enum ClippingRisk: String, Codable, Equatable, Sendable {
        case none
        case overhang
        case clipped

        fileprivate init(clipping: TerminalGlyphClippingMetrics) {
            if !clipping.clippedEdges.isEmpty {
                self = .clipped
            } else if !clipping.overhang.isZero {
                self = .overhang
            } else {
                self = .none
            }
        }
    }

    public enum ValidationFlag: String, Codable, Equatable, Hashable, Sendable {
        case requiresShaping
        case missingGlyph
        case fallbackUnresolved
        case fallbackChainUsed
        case atlasUnassigned
        case atlasSlotAssigned
        case clippingRisk
    }
}

public struct TerminalGlyphAtlasKey: Codable, Equatable, Hashable, Sendable {
    public let value: String
    public let fontIdentifier: String?
    public let presentation: TerminalGlyphPresentation?
    public let sourceFingerprint: String?
    public let glyphIDs: [UInt32]
    public let pointSizePixels: Int?
    public let scale: Int?

    public init(
        value: String,
        fontIdentifier: String? = nil,
        presentation: TerminalGlyphPresentation? = nil,
        sourceFingerprint: String? = nil,
        glyphIDs: [UInt32] = [],
        pointSizePixels: Int? = nil,
        scale: Int? = nil
    ) {
        self.value = value
        self.fontIdentifier = fontIdentifier
        self.presentation = presentation
        self.sourceFingerprint = sourceFingerprint
        self.glyphIDs = glyphIDs
        self.pointSizePixels = pointSizePixels
        self.scale = scale
    }

    enum CodingKeys: String, CodingKey {
        case value
        case fontIdentifier
        case presentation
        case sourceFingerprint
        case glyphIDs
        case pointSizePixels
        case scale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        fontIdentifier = try container.decodeIfPresent(String.self, forKey: .fontIdentifier)
        presentation = try container.decodeIfPresent(TerminalGlyphPresentation.self, forKey: .presentation)
        sourceFingerprint = try container.decodeIfPresent(String.self, forKey: .sourceFingerprint)
        glyphIDs = try container.decodeIfPresent([UInt32].self, forKey: .glyphIDs) ?? []
        pointSizePixels = try container.decodeIfPresent(Int.self, forKey: .pointSizePixels)
        scale = try container.decodeIfPresent(Int.self, forKey: .scale)
    }

    public static func separated(
        fontIdentifier: String,
        presentation: TerminalGlyphPresentation,
        sourceFingerprint: String,
        glyphIDs: [UInt32],
        pointSizePixels: Int,
        scale: Int
    ) -> TerminalGlyphAtlasKey {
        let glyphComponent = glyphIDs.map(String.init).joined(separator: ",")
        let value = [
            fontIdentifier,
            presentation.rawValue,
            sourceFingerprint,
            glyphComponent,
            "\(pointSizePixels)px",
            "\(scale)x",
        ].joined(separator: "/")

        return TerminalGlyphAtlasKey(
            value: value,
            fontIdentifier: fontIdentifier,
            presentation: presentation,
            sourceFingerprint: sourceFingerprint,
            glyphIDs: glyphIDs,
            pointSizePixels: pointSizePixels,
            scale: scale
        )
    }

    public static func sourceFingerprint(for text: String) -> String {
        text.unicodeScalars
            .map { String(format: "U+%04X", $0.value) }
            .joined(separator: "-")
    }
}

public struct TerminalGlyphCellSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct TerminalGlyphAtlasMetadata: Codable, Equatable, Sendable {
    public let ownership: Ownership
    public let slot: TerminalGlyphAtlasSlotMetadata?

    public init(ownership: Ownership, slot: TerminalGlyphAtlasSlotMetadata? = nil) {
        self.ownership = ownership
        self.slot = slot
    }

    public static let unassigned = TerminalGlyphAtlasMetadata(ownership: .unassigned)

    public enum Ownership: String, Codable, Equatable, Sendable {
        case unassigned
        case glyphCache
        case sharedFontAtlas
    }
}

public struct TerminalGlyphAtlasSlotMetadata: Codable, Equatable, Sendable {
    public let index: Int
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let generation: Int?

    public init(index: Int, x: Int, y: Int, width: Int, height: Int, generation: Int? = nil) {
        self.index = index
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.generation = generation
    }
}

public struct TerminalGlyphClippingMetrics: Codable, Equatable, Sendable {
    public let inkBounds: TerminalGlyphBounds
    public let cellBounds: TerminalGlyphBounds
    public let overhang: TerminalGlyphOverhang
    public let clippedEdges: Set<TerminalGlyphClippedEdge>

    public init(
        inkBounds: TerminalGlyphBounds,
        cellBounds: TerminalGlyphBounds,
        overhang: TerminalGlyphOverhang,
        clippedEdges: Set<TerminalGlyphClippedEdge>
    ) {
        self.inkBounds = inkBounds
        self.cellBounds = cellBounds
        self.overhang = overhang
        self.clippedEdges = clippedEdges
    }

    public static let zero = TerminalGlyphClippingMetrics(
        inkBounds: TerminalGlyphBounds(x: 0, y: 0, width: 0, height: 0),
        cellBounds: TerminalGlyphBounds(x: 0, y: 0, width: 0, height: 0),
        overhang: .zero,
        clippedEdges: []
    )

    public static func unclipped(
        inkBounds: TerminalGlyphBounds,
        cellBounds: TerminalGlyphBounds
    ) -> TerminalGlyphClippingMetrics {
        TerminalGlyphClippingMetrics(
            inkBounds: inkBounds,
            cellBounds: cellBounds,
            overhang: .zero,
            clippedEdges: []
        )
    }

    public static func classified(
        inkBounds: TerminalGlyphBounds,
        cellBounds: TerminalGlyphBounds
    ) -> TerminalGlyphClippingMetrics {
        let left = max(0, cellBounds.x - inkBounds.x)
        let top = max(0, cellBounds.y - inkBounds.y)
        let right = max(0, (inkBounds.x + inkBounds.width) - (cellBounds.x + cellBounds.width))
        let bottom = max(0, (inkBounds.y + inkBounds.height) - (cellBounds.y + cellBounds.height))
        let overhang = TerminalGlyphOverhang(left: left, right: right, top: top, bottom: bottom)
        var clippedEdges: Set<TerminalGlyphClippedEdge> = []
        if left > 0 { clippedEdges.insert(.left) }
        if right > 0 { clippedEdges.insert(.right) }
        if top > 0 { clippedEdges.insert(.top) }
        if bottom > 0 { clippedEdges.insert(.bottom) }

        return TerminalGlyphClippingMetrics(
            inkBounds: inkBounds,
            cellBounds: cellBounds,
            overhang: overhang,
            clippedEdges: clippedEdges
        )
    }
}

public struct TerminalGlyphOverhang: Codable, Equatable, Sendable {
    public let left: Double
    public let right: Double
    public let top: Double
    public let bottom: Double

    public init(left: Double, right: Double, top: Double, bottom: Double) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    public static let zero = TerminalGlyphOverhang(left: 0, right: 0, top: 0, bottom: 0)

    fileprivate var isZero: Bool {
        left == 0 && right == 0 && top == 0 && bottom == 0
    }
}

public enum TerminalGlyphClippedEdge: String, Codable, Equatable, Hashable, Sendable {
    case left
    case right
    case top
    case bottom
}

public enum TerminalGlyphDiagnosticFlag: String, Codable, Equatable, Hashable, Sendable {
    case containsCombiningMarks
    case containsZeroWidthJoiner
    case containsVariationSelector
    case wideCluster
    case zeroWidthCluster
    case ligatureCluster
    case fallbackFontSelected
    case missingGlyph
    case clippedInkBounds

    fileprivate static func flags(for text: String, terminalCellWidth: Int) -> Set<TerminalGlyphDiagnosticFlag> {
        var flags: Set<TerminalGlyphDiagnosticFlag> = []

        if text.unicodeScalars.contains(where: { CharacterSet.nonBaseCharacters.contains($0) }) {
            flags.insert(.containsCombiningMarks)
        }
        if text.unicodeScalars.contains(where: { $0.value == 0x200d }) {
            flags.insert(.containsZeroWidthJoiner)
        }
        if text.unicodeScalars.contains(where: { (0xfe00...0xfe0f).contains($0.value) }) {
            flags.insert(.containsVariationSelector)
        }
        if terminalCellWidth == 0 {
            flags.insert(.zeroWidthCluster)
        } else if terminalCellWidth > 1 {
            flags.insert(.wideCluster)
        }

        return flags
    }

    fileprivate static func flags(for clipping: TerminalGlyphClippingMetrics) -> Set<TerminalGlyphDiagnosticFlag> {
        clipping.clippedEdges.isEmpty && clipping.overhang.isZero ? [] : [.clippedInkBounds]
    }
}
