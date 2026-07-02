import Foundation

public struct TerminalGlyphRun: Codable, Equatable, Sendable {
    public let source: TerminalGlyphSourceCluster
    public let terminalCellWidth: Int
    public let fallbackFont: TerminalGlyphFallbackFont
    public let glyphs: [TerminalGlyph]
    public let advance: TerminalGlyphAdvance
    public let bounds: TerminalGlyphBounds
    public let atlasKey: TerminalGlyphAtlasKey
    public let diagnosticFlags: Set<TerminalGlyphDiagnosticFlag>

    public init(
        source: TerminalGlyphSourceCluster,
        terminalCellWidth: Int,
        fallbackFont: TerminalGlyphFallbackFont,
        glyphs: [TerminalGlyph],
        advance: TerminalGlyphAdvance,
        bounds: TerminalGlyphBounds,
        atlasKey: TerminalGlyphAtlasKey,
        diagnosticFlags: Set<TerminalGlyphDiagnosticFlag>
    ) {
        self.source = source
        self.terminalCellWidth = terminalCellWidth
        self.fallbackFont = fallbackFont
        self.glyphs = glyphs
        self.advance = advance
        self.bounds = bounds
        self.atlasKey = atlasKey
        self.diagnosticFlags = diagnosticFlags
    }

    public static func diagnosticModel(
        sourceText: String,
        sourceRange: TerminalGlyphSourceRange,
        fallbackFont: TerminalGlyphFallbackFont,
        glyphs: [TerminalGlyph],
        advance: TerminalGlyphAdvance,
        bounds: TerminalGlyphBounds,
        atlasKey: TerminalGlyphAtlasKey,
        diagnosticFlags explicitDiagnosticFlags: Set<TerminalGlyphDiagnosticFlag> = []
    ) -> TerminalGlyphRun {
        let source = TerminalGlyphSourceCluster(text: sourceText, range: sourceRange)
        let width = sourceText.terminalColumnWidth
        let inferredDiagnosticFlags = TerminalGlyphDiagnosticFlag.flags(for: sourceText, terminalCellWidth: width)

        return TerminalGlyphRun(
            source: source,
            terminalCellWidth: width,
            fallbackFont: fallbackFont,
            glyphs: glyphs,
            advance: advance,
            bounds: bounds,
            atlasKey: atlasKey,
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
}
