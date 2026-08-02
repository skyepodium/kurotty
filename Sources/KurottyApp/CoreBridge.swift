import Foundation
import KurottyCore

typealias TerminalHandle = OpaquePointer

private typealias CreateFn = @convention(c) (UInt32, UInt32) -> TerminalHandle?
private typealias DestroyFn = @convention(c) (TerminalHandle?) -> Void
private typealias FeedFn = @convention(c) (TerminalHandle?, UnsafePointer<UInt8>, Int) -> Int
private typealias TimestampFn = @convention(c) (TerminalHandle?, UInt64) -> Void
private typealias LastLatencyFn = @convention(c) (TerminalHandle?) -> UInt64
private typealias LastErrorFn = @convention(c) (TerminalHandle?) -> UInt32
private typealias MarkDamageFn = @convention(c) (TerminalHandle?, UInt32, UInt32, UInt32, UInt32) -> Void
private typealias BeginFrameFn = @convention(c) (TerminalHandle?, UInt32) -> UInt32
private typealias EndFrameFn = @convention(c) (TerminalHandle?) -> Void
private typealias ResizeFn = @convention(c) (TerminalHandle?, UInt32, UInt32) -> Void
private typealias CellAtFn = @convention(c) (TerminalHandle?, UInt32, UInt32) -> UInt8
private typealias CopyRowFn = @convention(c) (TerminalHandle?, UInt32, UnsafeMutablePointer<UInt8>?, Int) -> Int
private typealias CopyRowCellsFn = @convention(c) (TerminalHandle?, UInt32, UnsafeMutableRawPointer?, Int) -> Int

/// Mirrors the 16-byte `kurotty_cell` record documented in docs/abi.md.
struct CoreCell {
    struct Attributes: OptionSet {
        let rawValue: UInt16

        static let bold = Attributes(rawValue: 1 << 0)
        static let dim = Attributes(rawValue: 1 << 1)
        static let italic = Attributes(rawValue: 1 << 2)
        static let underline = Attributes(rawValue: 1 << 3)
        static let strikethrough = Attributes(rawValue: 1 << 4)
        static let inverse = Attributes(rawValue: 1 << 5)
    }

    enum Width: UInt8 {
        case continuation = 0
        case single = 1
        case wide = 2
    }

    let codepoint: UInt32
    let foreground: UInt32
    let background: UInt32
    let attributes: Attributes
    let width: Width
}

/// Raw C-layout twin of CoreCell used only for the ABI copy.
private struct RawCoreCell {
    var codepoint: UInt32 = 0
    var fg: UInt32 = 0
    var bg: UInt32 = 0
    var attrs: UInt16 = 0
    var width: UInt8 = 0
    var pad: UInt8 = 0
}

private enum CoreLibraryPath {
    static let appBundleExtension = "app"
    static let dylibName = "libkurotty_core"
    static let dylibExtension = "dylib"
    static let dylibFilename = "\(dylibName).\(dylibExtension)"
    static let zigOutDevelopmentPath = "zig-out/lib/\(dylibFilename)"
    static let swiftPMDebugDevelopmentPath = ".build/debug/\(dylibFilename)"
}

final class CoreBridge: TerminalCore,
    TerminalCoreCompatibilityDiagnosing,
    TerminalCoreMutationSourceDiagnosing,
    TerminalCoreRuntimeBoundaryDiagnosing,
    @unchecked Sendable {
    private let symbols: CoreSymbols?
    private var handle: TerminalHandle?
    private var columns: UInt32
    private var rows: UInt32

    init(cols: UInt32, rows: UInt32) {
        self.symbols = CoreSymbols.load()
        columns = max(1, cols)
        self.rows = max(1, rows)
        handle = symbols?.create(cols, rows)
    }

    init(cols: UInt32, rows: UInt32, loadSymbols: Bool) {
        self.symbols = loadSymbols ? CoreSymbols.load() : nil
        columns = max(1, cols)
        self.rows = max(1, rows)
        handle = symbols?.create(cols, rows)
    }

    var compatibilityDiagnostic: TerminalCoreCompatibilityDiagnostic {
        let bridgeSource: TerminalCoreStateSource = handle == nil ? .swiftScaffold : .zigCore
        return TerminalCoreCompatibilityDiagnostic(
            bridge: bridgeSource,
            pty: .swiftScaffold,
            parser: .swiftScaffold,
            screen: .swiftScaffold,
            render: .swiftScaffold
        )
    }

    var mutationSourceDiagnostic: TerminalCoreMutationSourceDiagnostic {
        return TerminalCoreMutationSourceDiagnostic(
            sessionMutationOwner: .swiftScaffold,
            frameMutationOwner: .swiftScaffold,
            zigBridgeActive: handle != nil,
            reason: handle == nil ? "zig-core-unavailable" : "swift-runtime-mutation-with-zig-feed-active"
        )
    }

    var runtimeBoundaryDiagnostic: TerminalCoreRuntimeBoundaryDiagnostic {
        let isZigFeedBridgeActive = handle != nil
        return TerminalCoreRuntimeBoundaryDiagnostic(
            feedBridgeParticipant: isZigFeedBridgeActive ? .zigCore : .swiftScaffold,
            parserMutationOwner: .swiftScaffold,
            screenMutationOwner: .swiftScaffold,
            renderMutationOwner: .swiftScaffold,
            mutationHandoffReady: false,
            dualWriteRisk: isZigFeedBridgeActive ? .feedBridgeOnly : .none,
            reason: isZigFeedBridgeActive ? "zig-feed-bridge-active-swift-mutation-owner" : "zig-core-unavailable"
        )
    }

    deinit {
        symbols?.destroy(handle)
    }

    func feed(_ text: String) {
        if let symbols {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBufferPointer { buffer in
                symbols.feed(handle, buffer.baseAddress!, buffer.count)
            }
            symbols.markDamage(handle, 0, 0, rows, columns)
        }
    }

    func recordKeyEvent() {
        symbols?.recordKey(handle, monotonicMicros())
    }

    func recordFramePresented() {
        symbols?.recordPresent(handle, monotonicMicros())
    }

    func beginFrame(visibleCells: UInt32) -> UInt32 {
        symbols?.beginFrame(handle, visibleCells) ?? 1
    }

    func endFrame() {
        symbols?.endFrame(handle)
    }

    func lastLatencyMicros() -> UInt64 {
        symbols?.lastLatency(handle) ?? 0
    }

    func resize(cols: UInt32, rows: UInt32) {
        columns = max(1, cols)
        self.rows = max(1, rows)
        symbols?.resize(handle, columns, self.rows)
    }

    func cell(row: UInt32, col: UInt32) -> UInt8 {
        symbols?.cellAt(handle, row, col) ?? 32
    }

    func copyRow(_ row: UInt32, into buffer: inout [UInt8]) -> Int {
        guard let symbols, !buffer.isEmpty else { return 0 }
        return buffer.withUnsafeMutableBufferPointer { rawBuffer in
            symbols.copyRow(handle, row, rawBuffer.baseAddress, rawBuffer.count)
        }
    }

    /// True when the loaded core dylib exports the styled cell row copy.
    var supportsStyledRows: Bool {
        symbols?.copyRowCells != nil
    }

    /// Reads one grid row as styled cells via `kurotty_terminal_copy_row_cells`.
    /// Returns an empty array when the core or the symbol is unavailable.
    func copyStyledRow(_ row: UInt32, maxCells: Int) -> [CoreCell] {
        guard let symbols, let copyRowCells = symbols.copyRowCells, maxCells > 0 else { return [] }
        var raw = [RawCoreCell](repeating: RawCoreCell(), count: maxCells)
        let copied = raw.withUnsafeMutableBytes { rawBuffer in
            copyRowCells(handle, row, rawBuffer.baseAddress, maxCells)
        }
        guard copied > 0 else { return [] }
        return raw.prefix(copied).map { cell in
            CoreCell(
                codepoint: cell.codepoint,
                foreground: cell.fg,
                background: cell.bg,
                attributes: CoreCell.Attributes(rawValue: cell.attrs),
                width: CoreCell.Width(rawValue: cell.width) ?? .single
            )
        }
    }
}

private struct CoreSymbols {
    let dylib: UnsafeMutableRawPointer
    let create: CreateFn
    let destroy: DestroyFn
    let feed: FeedFn
    let recordKey: TimestampFn
    let recordPresent: TimestampFn
    let lastLatency: LastLatencyFn
    let lastError: LastErrorFn
    let markDamage: MarkDamageFn
    let beginFrame: BeginFrameFn
    let endFrame: EndFrameFn
    let resize: ResizeFn
    let cellAt: CellAtFn
    let copyRow: CopyRowFn
    /// Optional: absent in older core dylibs; loading must not fail without it.
    let copyRowCells: CopyRowCellsFn?

    static func load() -> CoreSymbols? {
        let names = dylibCandidates()
        guard let dylib = names.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else {
            return nil
        }

        guard
            let create: CreateFn = symbol(dylib, "kurotty_terminal_create"),
            let destroy: DestroyFn = symbol(dylib, "kurotty_terminal_destroy"),
            let feed: FeedFn = symbol(dylib, "kurotty_terminal_feed"),
            let recordKey: TimestampFn = symbol(dylib, "kurotty_terminal_record_key"),
            let recordPresent: TimestampFn = symbol(dylib, "kurotty_terminal_record_present"),
            let lastLatency: LastLatencyFn = symbol(dylib, "kurotty_terminal_last_latency"),
            let lastError: LastErrorFn = symbol(dylib, "kurotty_terminal_last_error"),
            let markDamage: MarkDamageFn = symbol(dylib, "kurotty_terminal_mark_damage"),
            let beginFrame: BeginFrameFn = symbol(dylib, "kurotty_terminal_begin_frame"),
            let endFrame: EndFrameFn = symbol(dylib, "kurotty_terminal_end_frame"),
            let resize: ResizeFn = symbol(dylib, "kurotty_terminal_resize"),
            let cellAt: CellAtFn = symbol(dylib, "kurotty_terminal_cell_at"),
            let copyRow: CopyRowFn = symbol(dylib, "kurotty_terminal_copy_row")
        else {
            dlclose(dylib)
            return nil
        }

        let copyRowCells: CopyRowCellsFn? = symbol(dylib, "kurotty_terminal_copy_row_cells")

        return CoreSymbols(
            dylib: dylib,
            create: create,
            destroy: destroy,
            feed: feed,
            recordKey: recordKey,
            recordPresent: recordPresent,
            lastLatency: lastLatency,
            lastError: lastError,
            markDamage: markDamage,
            beginFrame: beginFrame,
            endFrame: endFrame,
            resize: resize,
            cellAt: cellAt,
            copyRow: copyRow,
            copyRowCells: copyRowCells
        )
    }

    private static func dylibCandidates() -> [String] {
        if Bundle.main.bundleURL.pathExtension == CoreLibraryPath.appBundleExtension {
            return appBundleDylibCandidates()
        }
        return developmentDylibCandidates()
    }

    private static func appBundleDylibCandidates() -> [String] {
        let urls = [
            Bundle.main.url(forResource: CoreLibraryPath.dylibName, withExtension: CoreLibraryPath.dylibExtension),
            Bundle.main.resourceURL?.appendingPathComponent(CoreLibraryPath.dylibFilename),
            Bundle.main.privateFrameworksURL?.appendingPathComponent(CoreLibraryPath.dylibFilename),
            Bundle.main.sharedFrameworksURL?.appendingPathComponent(CoreLibraryPath.dylibFilename),
        ].compactMap { $0 }
        return uniquePaths(from: urls)
    }

    private static func developmentDylibCandidates() -> [String] {
        let root = repositoryRootURL()
        return [
            root.appendingPathComponent(CoreLibraryPath.zigOutDevelopmentPath).path,
            root.appendingPathComponent(CoreLibraryPath.swiftPMDebugDevelopmentPath).path,
        ]
    }

    private static func repositoryRootURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static func uniquePaths(from urls: [URL]) -> [String] {
        var seen = Set<String>()
        return urls.map(\.path).filter { seen.insert($0).inserted }
    }

    private static func symbol<T>(_ dylib: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let raw = dlsym(dylib, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }
}

private func monotonicMicros() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1_000
}
