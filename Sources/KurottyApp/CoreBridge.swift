import Foundation

typealias TerminalHandle = OpaquePointer

private typealias CreateFn = @convention(c) (UInt32, UInt32) -> TerminalHandle?
private typealias DestroyFn = @convention(c) (TerminalHandle?) -> Void
private typealias FeedFn = @convention(c) (TerminalHandle?, UnsafePointer<UInt8>, Int) -> Int
private typealias TimestampFn = @convention(c) (TerminalHandle?, UInt64) -> Void
private typealias LastLatencyFn = @convention(c) (TerminalHandle?) -> UInt64
private typealias MarkDamageFn = @convention(c) (TerminalHandle?, UInt32, UInt32, UInt32, UInt32) -> Void
private typealias BeginFrameFn = @convention(c) (TerminalHandle?, UInt32) -> UInt32
private typealias EndFrameFn = @convention(c) (TerminalHandle?) -> Void

final class CoreBridge: @unchecked Sendable {
    private let symbols = CoreSymbols.load()
    private var handle: TerminalHandle?
    private var fallbackBuffer = ""

    init(cols: UInt32, rows: UInt32) {
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
            symbols.markDamage(handle, 0, 0, 40, 120)
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
}

private struct CoreSymbols {
    let dylib: UnsafeMutableRawPointer
    let create: CreateFn
    let destroy: DestroyFn
    let feed: FeedFn
    let recordKey: TimestampFn
    let recordPresent: TimestampFn
    let lastLatency: LastLatencyFn
    let markDamage: MarkDamageFn
    let beginFrame: BeginFrameFn
    let endFrame: EndFrameFn

    static func load() -> CoreSymbols? {
        let names = ["./zig-out/lib/libkurotty_core.dylib", "./zig-out/lib/libkurotty_core.a"]
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
            let markDamage: MarkDamageFn = symbol(dylib, "kurotty_terminal_mark_damage"),
            let beginFrame: BeginFrameFn = symbol(dylib, "kurotty_terminal_begin_frame"),
            let endFrame: EndFrameFn = symbol(dylib, "kurotty_terminal_end_frame")
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
            markDamage: markDamage,
            beginFrame: beginFrame,
            endFrame: endFrame
        )
    }

    private static func symbol<T>(_ dylib: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let raw = dlsym(dylib, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }
}

private func monotonicMicros() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1_000
}
