import Foundation

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

private enum CoreLibraryPath {
    static let appBundleExtension = "app"
    static let dylibName = "libkurotty_core"
    static let dylibExtension = "dylib"
    static let dylibFilename = "\(dylibName).\(dylibExtension)"
    static let zigOutDevelopmentPath = "zig-out/lib/\(dylibFilename)"
    static let swiftPMDebugDevelopmentPath = ".build/debug/\(dylibFilename)"
}

final class CoreBridge: @unchecked Sendable {
    private let symbols = CoreSymbols.load()
    private var handle: TerminalHandle?
    private var fallbackBuffer = ""
    private var columns: UInt32
    private var rows: UInt32

    init(cols: UInt32, rows: UInt32) {
        columns = max(1, cols)
        self.rows = max(1, rows)
        handle = symbols?.create(cols, rows)
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
        } else {
            fallbackBuffer.append(text)
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
            let cellAt: CellAtFn = symbol(dylib, "kurotty_terminal_cell_at")
        else {
            dlclose(dylib)
            return nil
        }

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
            cellAt: cellAt
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
