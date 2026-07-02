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
    public let unicodeScalarValues: [UInt32]

    public init(text: String, range: TerminalGlyphSourceRange) {
        self.text = text
        self.range = range
        self.graphemeClusterCount = text.count
        self.unicodeScalarValues = text.unicodeScalars.map(\.value)
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
    public let advance: TerminalGlyphAdvance?
    public let bounds: TerminalGlyphBounds?

    public init(
        glyphID: UInt32,
        sourceRange: TerminalGlyphSourceRange,
        advance: TerminalGlyphAdvance? = nil,
        bounds: TerminalGlyphBounds? = nil
    ) {
        self.glyphID = glyphID
        self.sourceRange = sourceRange
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

    public init(value: String) {
        self.value = value
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
