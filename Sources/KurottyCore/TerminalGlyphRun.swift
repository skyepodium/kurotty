import Foundation

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

public enum TerminalGlyphPresentation: String, Codable, Equatable, Sendable {
    case unspecified
    case text
    case emoji
    case cjk
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
