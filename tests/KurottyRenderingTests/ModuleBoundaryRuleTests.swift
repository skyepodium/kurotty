import AppKit
import XCTest
@testable import KurottyCore
@testable import KurottyApp

/// Deliberately-kept source-text assertions, and the behavioural tests that
/// stand next to them.
///
/// Everything in the `RuleTests` class below reads a source file as text, which
/// is normally the wrong shape for a test. It is kept here because these are
/// *construction rules*, not behaviour: statements about what a file may
/// contain, which have no runtime witness on the platform the suite runs on.
///
/// - "`KurottyCore` imports no AppKit" cannot be observed at runtime. The module
///   would still build and pass every behavioural test with `import AppKit` at
///   the top; the rule exists so the module stays portable, and portability is
///   only proved by a build that does not happen here.
/// - The `#elseif os(Linux)` and `#elseif os(Windows)` adapter branches are not
///   compiled on macOS, so no test can reach them.
/// - `src/core.zig`'s public surface is Zig; the Swift suite has no handle on it
///   at all.
///
/// Anything with a runtime witness lives in `ModuleBoundaryBehaviourTests`
/// instead. If a rule below becomes reachable — for example by adding a Linux
/// CI job that builds `KurottyCore` — delete it from here.
final class ModuleBoundaryRuleTests: XCTestCase {
    func testKurottyCoreStaysFreeOfAppKitAndPlatformAdapters() throws {
        for (filename, source) in try kurottyCoreSourceFiles() {
            XCTAssertFalse(source.contains("import AppKit"), "\(filename) must stay AppKit-free")
            XCTAssertFalse(source.contains("import Darwin"), "\(filename) must stay Darwin-free")
            XCTAssertFalse(source.contains("import Metal"), "\(filename) must stay Metal-free")
            XCTAssertFalse(source.contains("ShellSession"), "\(filename) must not reference app shell adapters")
            XCTAssertFalse(source.contains("DarwinPTYTerminalSession"), "\(filename) must not reference Darwin shell adapters")
            XCTAssertFalse(source.contains("CoreBridge"), "\(filename) must not reference the dynamic ABI loader")
            XCTAssertFalse(source.contains("TerminalAppKitRenderer"), "\(filename) must not reference AppKit renderer adapters")
        }
    }

    /// The screen model and the style layer carry no CoreGraphics geometry: a
    /// `CGFloat` in the model is how a renderer's units leak into the data.
    func testTerminalModelAndStyleCarryNoCoreGraphicsGeometry() throws {
        let modelSource = try moduleBoundarySource("Sources/KurottyCore/TerminalCore.swift")
        let styleSource = try moduleBoundarySource("Sources/KurottyCore/TerminalTextStyle.swift")
        let colorUtilitiesSource = try moduleBoundarySource("Sources/KurottyCore/TerminalColorUtilities.swift")

        for name in ["import AppKit", "import CoreGraphics", "CGSize", "CGPoint", "CGRect", "CGFloat"] {
            XCTAssertFalse(modelSource.contains(name), "TerminalCore must not mention \(name)")
        }
        XCTAssertFalse(styleSource.contains("import AppKit"))
        XCTAssertFalse(colorUtilitiesSource.contains("import AppKit"))
        // The palette lives in the portable module; the style layer must read it
        // from there rather than from the app's design tokens.
        XCTAssertFalse(styleSource.contains("DesignTokens.Color.ansi"))
    }

    /// `TerminalFrame` is the contract between the surface and any renderer. It
    /// must stay a plain value type — no AppKit, no Metal, and no Foundation, so
    /// a renderer on another platform can consume it unchanged.
    func testRenderFrameContractStaysPlatformFree() throws {
        let frameSource = try moduleBoundarySource("Sources/KurottyCore/TerminalRenderFrame.swift")
        let metalSource = try moduleBoundarySource("Sources/KurottyApp/TerminalMetalView.swift")

        XCTAssertFalse(metalSource.contains("struct TerminalFrame"), "the frame contract must not be redeclared in the renderer")
        for name in ["import AppKit", "import Metal", "import MetalKit", "import Foundation", "NSRange", "CGRect", "CGSize", "CGFloat"] {
            XCTAssertFalse(frameSource.contains(name), "TerminalRenderFrame must not mention \(name)")
        }
    }

    /// The frame-renderer protocol is the portable half of the renderer seam and
    /// must not name an AppKit type; the AppKit half is a separate protocol.
    func testFrameRendererProtocolStaysAppKitFree() throws {
        let frameRendererSource = try moduleBoundarySource("Sources/KurottyCore/TerminalFrameRenderer.swift")

        XCTAssertFalse(frameRendererSource.contains("import AppKit"))
        XCTAssertFalse(frameRendererSource.contains("NSView"))
        XCTAssertFalse(frameRendererSource.contains("NSFont"))
    }

    /// The surface builds its renderer through the factory. Naming
    /// `TerminalMetalView` directly would put Metal back in the surface's
    /// dependency graph, which is the seam the factory exists to hold open.
    func testTerminalSurfaceReachesItsRendererOnlyThroughTheFactory() throws {
        let surfaceSource = try moduleBoundarySource("Sources/KurottyApp/TerminalSurfaceView.swift")

        XCTAssertTrue(surfaceSource.contains("TerminalRendererFactory.makeDefaultRenderer("))
        XCTAssertFalse(surfaceSource.contains("TerminalMetalView("))
        XCTAssertFalse(surfaceSource.contains("metalView."))
    }

    /// The protocols must not know their own factories, or the dependency runs
    /// backwards and nothing can substitute an implementation.
    func testCoreAndSessionProtocolsDoNotNameTheirFactories() throws {
        let coreSource = try moduleBoundarySource("Sources/KurottyCore/TerminalCore.swift")
        let sessionSource = try moduleBoundarySource("Sources/KurottyApp/TerminalSession.swift")

        for name in ["CoreBridge", "TerminalCoreFactory", "makeDefaultCore"] {
            XCTAssertFalse(coreSource.contains(name), "TerminalCore must not mention \(name)")
        }
        for name in ["DarwinPTYTerminalSession", "UnsupportedTerminalSession", "TerminalSessionFactory", "makeDefaultSession"] {
            XCTAssertFalse(sessionSource.contains(name), "TerminalSession must not mention \(name)")
        }
    }

    /// The platform choice lives in one adapter, behind `#if os(...)`. The two
    /// non-macOS branches never compile here, so their spelling is all a test on
    /// this platform can check — and a typo in them is a build break for whoever
    /// ports the app.
    func testPlatformChoiceStaysInTheAdapterBehindCompilationGuards() throws {
        let factorySource = try moduleBoundarySource("Sources/KurottyApp/TerminalSessionFactory.swift")
        let adapterSource = try moduleBoundarySource("Sources/KurottyApp/TerminalSessionAdapter.swift")
        let shellSource = try moduleBoundarySource("Sources/KurottyApp/ShellSession.swift")
        let unsupportedSource = try moduleBoundarySource("Sources/KurottyApp/UnsupportedTerminalSession.swift")

        XCTAssertFalse(factorySource.contains("#if os(macOS)"), "the factory must not branch on the platform itself")
        XCTAssertTrue(adapterSource.contains("#if os(macOS)"))
        XCTAssertTrue(adapterSource.contains("#elseif os(Linux)"))
        XCTAssertTrue(adapterSource.contains("#elseif os(Windows)"))
        XCTAssertTrue(adapterSource.contains("UnsupportedTerminalSessionAdapter.makeSession(platformName: TerminalSessionPlatformNames.linux)"))
        XCTAssertTrue(adapterSource.contains("UnsupportedTerminalSessionAdapter.makeSession(platformName: TerminalSessionPlatformNames.windows)"))
        // The Darwin PTY implementation is compiled out wholesale off macOS.
        XCTAssertTrue(shellSource.hasPrefix("#if os(macOS)\n"))
        XCTAssertFalse(unsupportedSource.contains("import Darwin"))
        XCTAssertFalse(unsupportedSource.contains("import AppKit"))
    }

    /// The Zig core's public module exposes only the PTY boundary value types.
    /// Widening it re-exports allocator-owning types across the ABI, and the
    /// Swift suite cannot import Zig to find out.
    func testZigCoreExposesOnlyPtyBoundaryValueTypes() throws {
        let coreSource = try moduleBoundarySource("src/core.zig")

        XCTAssertTrue(coreSource.contains("pub const PtyDimensions = @import(\"pty.zig\").PtyDimensions"))
        XCTAssertTrue(coreSource.contains("pub const PtyResizeRequest = @import(\"pty.zig\").PtyResizeRequest"))
        XCTAssertTrue(coreSource.contains("pub const PtySizeDiagnostic = @import(\"pty.zig\").PtySizeDiagnostic"))
        XCTAssertFalse(coreSource.contains("pub const Pty ="))
        XCTAssertFalse(coreSource.contains("pub const PtyConfig"))
    }
}

/// The half of the seam that does have a runtime witness.
@MainActor
final class ModuleBoundaryBehaviourTests: XCTestCase {
    /// The factory hands back something that satisfies both halves of the
    /// renderer seam and yields a real view to install.
    func testRendererFactoryProducesAnInstallableAppKitRenderer() {
        let renderer = TerminalRendererFactory.makeDefaultRenderer(
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            backgroundColor: SIMD4<Float>(0, 0, 0, 1),
            cursorColor: SIMD4<Float>(1, 1, 1, 1)
        )

        // The compiler proves the conformance; what a test can add is that the
        // renderer yields a view the surface can actually install, and that it
        // accepts a frame without a device or a window.
        XCTAssertTrue(renderer.rendererView.isKind(of: NSView.self))
        XCTAssertNil(renderer.rendererView.superview)
    }

    /// The session factory resolves to the Darwin PTY implementation here, and
    /// it satisfies the protocol the surface actually holds.
    func testSessionFactoryResolvesToThePlatformSession() {
        let session = TerminalSessionFactory.makeDefaultSession()

        #if os(macOS)
        XCTAssertTrue(session is DarwinPTYTerminalSession)
        #endif
    }

    /// The unsupported adapter is a real session, not a stub that traps: every
    /// call has to be survivable, because it is what runs on a platform the app
    /// has no PTY for.
    func testUnsupportedAdapterReturnsASurvivableSession() {
        let session = UnsupportedTerminalSessionAdapter.makeSession(
            platformName: TerminalSessionPlatformNames.linux
        )

        session.start(workingDirectory: "/tmp")
        session.write("echo hi\n")
        session.resize(columns: 80, rows: 24)
        session.stop()

        XCTAssertNil(session.foregroundProcessName())
    }

    /// The portable core types compose without any AppKit help — the positive
    /// side of the rules above.
    func testPortableCoreTypesComposeWithoutAppKit() {
        let style = TerminalTextStyle(
            foreground: TerminalPalette.ansiColor(2, bright: false),
            background: .zero,
            bold: true
        )
        let frame = TerminalFrame(
            cells: [
                TerminalCell(
                    character: "K",
                    column: 0,
                    row: 0,
                    foreground: style.effectiveForeground,
                    background: style.effectiveBackground
                ),
            ],
            backgrounds: [TerminalBackground(column: 0, row: 0, color: style.effectiveBackground)],
            decorations: [
                TerminalDecoration(
                    column: 0,
                    row: 0,
                    width: 1,
                    kind: .blockElement(x: 0, y: 0, width: 1, height: 0.5),
                    color: style.effectiveForeground
                ),
            ],
            defaultForeground: style.foreground,
            defaultBackground: style.background,
            dirtyRows: [0],
            dirtyRects: [TerminalFrameRect(x: 0, y: 0, width: 10, height: 20)],
            isFullDamage: false,
            cursorColumn: 0,
            cursorRow: 0,
            cursorBlinkOn: true,
            markedTextColumn: 0,
            markedText: "",
            markedTextSelectedRange: .none,
            columns: 1,
            visibleRows: 1,
            cellSize: TerminalFrameSize(width: 10, height: 20),
            padding: .zero
        )

        XCTAssertEqual(frame.decorations.count, 1)
        XCTAssertEqual(frame.dirtyRects.first?.height, 20)
        XCTAssertNotEqual(style.effectiveForeground, style.effectiveBackground)
    }
}

private func moduleBoundarySource(_ relativePath: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    url.deleteLastPathComponent()
    url.deleteLastPathComponent()
    return try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
}

private func kurottyCoreSourceFiles() throws -> [(filename: String, source: String)] {
    var root = URL(fileURLWithPath: #filePath)
    root.deleteLastPathComponent()
    root.deleteLastPathComponent()
    root.deleteLastPathComponent()
    let directory = root.appendingPathComponent("Sources/KurottyCore")
    let urls = try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
}
