const std = @import("std");
const core = @import("kurotty_core");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = core.Parser.init(allocator);
    defer parser.deinit();
    const events = try parser.feed("hello\x1b[31mred\x1b[0m\n");
    defer parser.freeEvents(events);

    var grid = try core.Grid.init(allocator, 120, 40);
    defer grid.deinit();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) try grid.write("0123456789\n");

    var scrollback = try core.Scrollback.init(allocator, 1_000_000);
    defer scrollback.deinit();
    i = 0;
    while (i < 100_000) : (i += 1) try scrollback.appendFmt("bench-{d}", .{i});

    var renderer = core.RendererOrchestrator.init(allocator);
    defer renderer.deinit();
    try renderer.markDamage(.{ .row = 0, .col = 0, .rows = 40, .cols = 120 });
    const stats = renderer.beginFrame(120 * 40);
    renderer.endFrame();

    var metrics = core.Metrics.init();
    metrics.recordKeyEvent(100);
    metrics.recordFramePresented(160);

    std.debug.print(
        "parser_events={d}\ngrid_writes={d}\nscrollback_lines={d}\nscrollback_bytes={d}\nrenderer_draw_calls={d}\ninput_latency_us={d}\n",
        .{ events.len, 10_000, scrollback.len(), scrollback.bytesUsed(), stats.draw_calls, metrics.lastInputToPresentMicros() },
    );
}
