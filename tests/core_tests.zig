const std = @import("std");
const core = @import("kurotty_core");

test "parser emits printable runs and CSI SGR events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const events = try parser.feed("hi\x1b[31;1m!\x1b[0m");

    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expectEqualStrings("hi", events[0].printable.bytes);
    try std.testing.expectEqual(@as(u16, 31), events[1].csi.params[0]);
    try std.testing.expectEqual(@as(u16, 1), events[1].csi.params[1]);
    try std.testing.expectEqualStrings("!", events[2].printable.bytes);
    try std.testing.expectEqual(@as(u16, 0), events[3].csi.params[0]);
}

test "grid applies printable text, cursor movement, and erase in display" {
    var grid = try core.Grid.init(std.testing.allocator, 4, 3);
    defer grid.deinit();

    try grid.write("abcd");
    try grid.write("ef");
    grid.moveCursor(.{ .row_delta = -1, .col_delta = 0 });
    try grid.write("XY");
    grid.eraseDisplay(.below);

    try std.testing.expectEqualStrings("abXY", grid.rowText(0));
    try std.testing.expectEqualStrings("    ", grid.rowText(1));
    try std.testing.expectEqual(@as(usize, 0), grid.cursorRow());
    try std.testing.expectEqual(@as(usize, 4), grid.cursorCol());
}

test "scrollback keeps line addresses with bounded lookup" {
    const line_count = 10_000;
    var scrollback = try core.Scrollback.init(std.testing.allocator, line_count);
    defer scrollback.deinit();

    var i: usize = 0;
    while (i < line_count) : (i += 1) {
        try scrollback.appendFmt("line-{d}", .{i});
    }

    try std.testing.expectEqual(@as(usize, line_count), scrollback.len());
    try std.testing.expectEqualStrings("line-0", scrollback.lineAt(0));
    try std.testing.expectEqualStrings("line-9999", scrollback.lineAt(line_count - 1));
    try std.testing.expect(scrollback.bytesUsed() < 1024 * 1024);
}

test "metrics records input to present latency samples" {
    var metrics = core.Metrics.init();
    metrics.recordKeyEvent(100);
    metrics.recordFramePresented(141);

    try std.testing.expectEqual(@as(u64, 41), metrics.lastInputToPresentMicros());
    try std.testing.expect(metrics.maxInputToPresentMicros() >= 41);
}
