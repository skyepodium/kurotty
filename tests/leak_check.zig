const std = @import("std");
const core = @import("kurotty_core");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    try exerciseCore(allocator);

    const status = gpa.deinit();
    if (status == .leak) {
        std.debug.print("kurotty leak check failed\n", .{});
        std.process.exit(1);
    }
}

fn exerciseCore(allocator: std.mem.Allocator) !void {
    var parser = core.Parser.init(allocator);
    defer parser.deinit();

    const events = try parser.feed("hello\x1b[38;5;45mworld\x1b[0m\x1b]0;kurotty\x07");
    defer parser.freeEvents(events);

    var grid = try core.Grid.init(allocator, 120, 40);
    defer grid.deinit();
    try grid.write("hello world");
    grid.setCursor(0, 0);
    grid.eraseLine(.right);

    var scrollback = try core.Scrollback.init(allocator, 2048);
    defer scrollback.deinit();
    var index: usize = 0;
    while (index < 4096) : (index += 1) {
        try scrollback.appendFmt("line-{d}", .{index});
    }

    var renderer = core.RendererOrchestrator.init(allocator);
    defer renderer.deinit();
    try renderer.markDamage(.{ .row = 0, .col = 0, .rows = 1, .cols = 80 });
    _ = renderer.beginFrame(120);
    renderer.endFrame();
}
