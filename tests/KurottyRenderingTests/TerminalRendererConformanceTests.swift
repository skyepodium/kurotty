import XCTest
import KurottyCore
@testable import KurottyApp

/// Runs the probe table against the live HTML renderer.
@MainActor
enum TerminalConformanceEngine {
    struct Result {
        let name: String
        /// `nil` when the input reached the document.
        let dropped: String?
    }

    /// Feeds every probe's frames to a renderer and reports which inputs made
    /// no difference to what came out.
    ///
    /// `transform` exists so the engine can be pointed at a deliberately
    /// blinded view of the same document. A conformance check nobody has seen
    /// fail proves nothing, and a check that can only be seen failing by
    /// breaking the product for a moment cannot be kept.
    static func run(
        _ probes: [TerminalConformanceProbe],
        transform: (String) -> String = { $0 }
    ) throws -> [Result] {
        // One document serves every `distinguishable` probe: those frames all
        // report full damage, so each one replaces the screen outright and
        // nothing carries over from the frame before it. The damage probes are
        // about what carries over, so each of those gets a document of its own.
        let shared = try TerminalHTMLConformanceLens()
        try shared.load()

        return try probes.map { probe in
            switch probe.trial {
            case let .distinguishable(frames):
                let documents = try frames.map { transform(try shared.observe($0)) }
                return Result(name: probe.name, dropped: firstCollision(in: documents))
            case let .sequences(sequences):
                for sequence in sequences {
                    let lens = try TerminalHTMLConformanceLens()
                    try lens.load()
                    let document = transform(try lens.observe(sequence.frames))
                    guard document.contains(sequence.marker) != sequence.isExpected else {
                        continue
                    }
                    return Result(name: probe.name, dropped: sequence.because)
                }
                return Result(name: probe.name, dropped: nil)
            }
        }
    }

    private static func firstCollision(in documents: [String]) -> String? {
        for (index, document) in documents.enumerated() {
            for (other, candidate) in documents.enumerated() where other > index {
                guard document == candidate else {
                    continue
                }
                return "frames \(index) and \(other) differ in this input alone "
                    + "and produced byte-identical documents, so the renderer never read it"
            }
        }
        return nil
    }
}

/// Holds the HTML renderer to the same `TerminalFrame` the Metal renderer draws.
///
/// Not a pixel diff. Two rasterizers antialias differently — an earlier naive
/// comparison of two *correct* screens reported 8% of pixels different — so
/// pixels can only answer "are these bitmaps equal", which is not the question.
/// The question is whether an input the frame carries changed anything at all,
/// and that has an exact answer that needs no screen, no GPU and no tolerance.
@MainActor
final class TerminalRendererConformanceTests: XCTestCase {
    // MARK: - Census: the check has to survive the frame growing

    func testEveryFrameInputIsNamedInTheContract() {
        let declared = Set(TerminalFrameMember.declaredByTheType(in: TerminalConformanceFrame().frame()))
        let named = Set(TerminalFrameMember.allCases.map(\.rawValue))

        XCTAssertEqual(
            declared.subtracting(named),
            [],
            "TerminalFrame carries inputs the conformance contract does not name. "
                + "Add them to TerminalFrameMember and give each one a probe, or the next renderer "
                + "can drop them the way block elements and marked text were dropped."
        )
        XCTAssertEqual(
            named.subtracting(declared),
            [],
            "the conformance contract names inputs TerminalFrame no longer has"
        )
    }

    func testEveryFrameInputHasAProbe() {
        let covered = Set(TerminalRendererConformance.probes.flatMap(\.members))
        let uncovered = Set(TerminalFrameMember.allCases).subtracting(covered)

        XCTAssertEqual(
            uncovered.map(\.rawValue).sorted(),
            [],
            "these frame inputs are never probed, so no renderer can be caught ignoring them"
        )
    }

    func testEveryDecorationKindHasAProbe() {
        let covered = Set(TerminalRendererConformance.probes.compactMap(\.decorationKind))
        let uncovered = Set(TerminalDecorationKindCase.allCases).subtracting(covered)

        XCTAssertEqual(
            uncovered.map(\.rawValue).sorted(),
            [],
            "a decoration kind with no probe is a kind a projector can silently skip; "
                + "that is exactly what `case .boxDrawing, .blockElement: continue` did"
        )
    }

    func testEveryCursorShapeHasAProbe() {
        let covered = Set(TerminalRendererConformance.probes.compactMap(\.cursorShape))
        let uncovered = Set(TerminalCursorShapeCase.allCases).subtracting(covered)

        XCTAssertEqual(uncovered.map(\.rawValue).sorted(), [])
    }

    func testTheGapListOnlyNamesProbesThatExist() {
        let names = Set(TerminalRendererConformance.probes.map(\.name))
        let unknown = Set(TerminalRendererConformance.knownGaps.keys).subtracting(names)

        XCTAssertEqual(
            unknown.sorted(),
            [],
            "the known-gap list names probes that do not exist, so those entries suppress nothing"
        )
    }

    // MARK: - The reference renderer's side of the contract

    /// `makeAtlasBufferSignature` is the one place the Metal renderer decides
    /// whether a frame changed anything it draws, so it enumerates the frame in
    /// full. That makes it the reference answer to "which inputs does a
    /// renderer have to observe", and this keeps it honest: if Metal ever stops
    /// reading an input, the contract stops being able to claim the input is
    /// drawn at all, and that is worth failing over rather than discovering
    /// through the HTML renderer being held to a standard nothing meets.
    func testTheMetalRendererObservesEveryFrameInput() throws {
        let source = try repositorySource("Sources/KurottyApp/TerminalMetalView.swift")
        let body = try functionBody(named: "makeAtlasBufferSignature", in: source)

        for member in TerminalFrameMember.allCases {
            XCTAssertTrue(
                body.contains("frame.\(member.rawValue)"),
                "the Metal renderer's frame signature no longer reads frame.\(member.rawValue)"
            )
        }
    }

    func testTheMetalRendererObservesEveryDecorationKind() throws {
        let source = try repositorySource("Sources/KurottyApp/TerminalMetalView.swift")
        let body = try functionBody(named: "combineDecorationKind", in: source)

        for kind in TerminalDecorationKindCase.allCases {
            XCTAssertTrue(
                body.contains(".\(kind.rawValue)"),
                "the Metal renderer's decoration hashing no longer distinguishes .\(kind.rawValue)"
            )
        }
        XCTAssertFalse(
            body.contains("default:"),
            "that switch is exhaustive on purpose: a `default` would let a new decoration kind "
                + "compile into silence instead of failing the build"
        )
    }

    // MARK: - The check itself

    func testTheHTMLRendererObservesEveryFrameInput() throws {
        let results = try TerminalConformanceEngine.run(TerminalRendererConformance.probes)
        let gaps = TerminalRendererConformance.knownGaps

        var unreported: [String] = []
        var closed: [String] = []
        for result in results {
            switch (result.dropped, gaps[result.name]) {
            case let (.some(reason), nil):
                unreported.append("\(result.name): \(reason)")
            case (nil, .some):
                closed.append(result.name)
            default:
                continue
            }
        }

        report(results)

        XCTAssertEqual(
            unreported.sorted(),
            [],
            "the HTML renderer ignores frame inputs the Metal renderer draws. "
                + "Either draw them or record them in TerminalRendererConformance.knownGaps with a reason."
        )
        XCTAssertEqual(
            closed.sorted(),
            [],
            "these inputs now reach the HTML document. Delete their entries from "
                + "TerminalRendererConformance.knownGaps so the list cannot rot into a suppression file."
        )
    }

    /// Proves the check can fail.
    ///
    /// The engine is pointed at the same live renderer through a lens that
    /// deletes every colour from the document, which is what a projector that
    /// forgot to emit colours would produce. The inputs that survive only as a
    /// colour must then be reported dropped — and the inputs that survive as
    /// structure must not, or the engine is simply failing everything and
    /// proving nothing.
    func testTheCheckDetectsAnInputThatStopsReachingTheDocument() throws {
        let probes = TerminalRendererConformance.probes.filter { probe in
            guard case .distinguishable = probe.trial else {
                return false
            }
            return true
        }

        let sighted = try TerminalConformanceEngine.run(probes)
        let blinded = try TerminalConformanceEngine.run(probes, transform: Self.withoutColours)

        let before = Set(sighted.filter { $0.dropped != nil }.map(\.name))
        let after = Set(blinded.filter { $0.dropped != nil }.map(\.name))

        XCTAssertEqual(
            after.subtracting(before).sorted(),
            ["defaultBackground", "defaultForeground"],
            "a renderer that stopped emitting colours must be caught by exactly the probes whose "
                + "input is only ever visible as a colour"
        )
        XCTAssertFalse(
            after.contains("cells"),
            "the blinded lens must stay narrow; a check that fails on everything localises nothing"
        )
    }

    /// The renderer protocol carries a frame-derived value of its own, and the
    /// HTML renderer stubs it out. Same class of bug, one layer up, so it is
    /// checked against both renderers rather than assumed.
    func testBothRenderersReportTheDamageTheFrameCarries() throws {
        let dirtyRects = [TerminalConformanceFrame.rowRect(0), TerminalConformanceFrame.rowRect(1)]
        let frame = TerminalConformanceFrame().changing {
            $0.isFullDamage = false
            $0.dirtyRows = [0, 1]
            $0.dirtyRects = dirtyRects
        }.frame()

        let metal = TerminalMetalView(
            font: .monospacedSystemFont(ofSize: Fixture.fontSizePT, weight: .regular),
            backgroundColor: TerminalConformanceFrame.Baseline.background,
            cursorColor: TerminalConformanceFrame.Baseline.foreground
        )
        metal.frame = Fixture.surfaceBounds
        metal.update(frame: frame)

        XCTAssertEqual(
            metal.damageDiagnostics.dirtyRectCount,
            dirtyRects.count,
            "the reference renderer reports the damage it was given"
        )

        let html = try TerminalHTMLConformanceLens()
        try html.load()
        try html.observe(TerminalConformanceFrame().changing {
            $0.isFullDamage = false
            $0.dirtyRows = [0, 1]
            $0.dirtyRects = dirtyRects
        })

        XCTAssertEqual(
            html.renderer.damageDiagnostics.dirtyRectCount,
            0,
            "known gap: the HTML renderer never fills in damageDiagnostics, so the surface's "
                + "damage report reads empty on that backend. Update this expectation when it does."
        )
    }

    /// The other seam the two renderers share.
    ///
    /// The frame carries a `Character`; it does not carry the face that has a
    /// glyph for it, and the first bug on this branch lived in that gap. Both
    /// frames said "draw this powerline separator", both renderers drew
    /// something, and the differential above would have called that agreement —
    /// while Metal walked the named fallback list and the page asked CoreText,
    /// which answers `.LastResort` for the private use area and gave the
    /// empty-box font. So the fallback list is checked where it is decided
    /// rather than where it shows, and checked against the machine's real
    /// fonts: a family this Mac does not have cannot be expected in a stylesheet.
    func testBothRenderersReachForTheSameFallbackFaces() throws {
        let expected = TerminalGlyphFallbackFonts.installed(
            from: TerminalGlyphFallbackFonts.general + TerminalGlyphFallbackFonts.cjk,
            size: Fixture.fontSizePT
        )
        XCTAssertFalse(
            expected.isEmpty,
            "no fallback face resolves on this machine, so this check would prove nothing"
        )

        let lens = try TerminalHTMLConformanceLens(fontSizePT: Fixture.fontSizePT)
        try lens.load()
        let document = try lens.observe(TerminalConformanceFrame())

        for family in expected {
            XCTAssertTrue(
                document.contains(family),
                "the page never names \(family), so a glyph only that face carries renders as a "
                    + "missing-glyph box while the atlas draws it"
            )
        }

        let source = try repositorySource("Sources/KurottyApp/TerminalMetalView.swift")
        XCTAssertTrue(
            source.contains("TerminalGlyphFallbackFonts.general")
                && source.contains("TerminalGlyphFallbackFonts.cjk"),
            "the atlas no longer walks the shared fallback list, so the two renderers are back to "
                + "resolving glyphs from different sets of faces"
        )
    }

    // MARK: - Helpers

    private enum Fixture {
        static let fontSizePT = 12.0
        static let surfaceBounds = NSRect(x: 0, y: 0, width: 400, height: 200)
        static let repositoryDepthFromTestFileCOUNT = 3
    }

    private static func withoutColours(_ document: String) -> String {
        document.replacingOccurrences(
            of: "rgba\\([^)]*\\)",
            with: "",
            options: .regularExpression
        )
    }

    private func report(_ results: [TerminalConformanceEngine.Result]) {
        let dropped = results.filter { $0.dropped != nil }.map(\.name).sorted()
        let observed = results.filter { $0.dropped == nil }.map(\.name).sorted()
        print("""

        renderer conformance: \(observed.count) of \(results.count) frame inputs reach the HTML document
          observed: \(observed.joined(separator: ", "))
          dropped:  \(dropped.isEmpty ? "none" : dropped.joined(separator: ", "))

        """)
    }

    private func repositorySource(_ path: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<Fixture.repositoryDepthFromTestFileCOUNT {
            root = root.deletingLastPathComponent()
        }
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The body of a Swift function, taken as the text between its declaration
    /// and the first closing brace at the indentation the declaration sits at.
    private func functionBody(named name: String, in source: String) throws -> String {
        guard let declaration = source.range(of: "func \(name)") else {
            throw ConformanceSourceError.functionMissing(name)
        }
        let remainder = source[declaration.upperBound...]
        guard let close = remainder.range(of: "\n    }") else {
            throw ConformanceSourceError.functionUnterminated(name)
        }
        return String(remainder[..<close.lowerBound])
    }

    private enum ConformanceSourceError: Error, CustomStringConvertible {
        case functionMissing(String)
        case functionUnterminated(String)

        var description: String {
            switch self {
            case let .functionMissing(name):
                return "\(name) is gone; the conformance contract no longer has a reference renderer to compare against"
            case let .functionUnterminated(name):
                return "\(name) could not be read from source"
            }
        }
    }
}
