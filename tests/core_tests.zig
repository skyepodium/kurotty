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

test "parser keeps incomplete CSI until final byte arrives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const first = try parser.feed("ab\x1b[31");
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("ab", first[0].printable.bytes);

    const second = try parser.feed(";1m!");
    try std.testing.expectEqual(@as(usize, 2), second.len);
    try std.testing.expectEqual(@as(u8, 'm'), second[0].csi.final);
    try std.testing.expectEqual(@as(u16, 31), second[0].csi.params[0]);
    try std.testing.expectEqual(@as(u16, 1), second[0].csi.params[1]);
    try std.testing.expectEqualStrings("!", second[1].printable.bytes);
}

test "parser parses private modes, 256 color, RGB SGR, and OSC strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const events = try parser.feed("\x1b[?25l\x1b[38;5;196;48;2;1;2;3mred\x1b]0;kurotty\x07");

    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expect(events[0].csi.private);
    try std.testing.expectEqual(@as(u8, 'l'), events[0].csi.final);
    try std.testing.expectEqual(@as(u16, 25), events[0].csi.params[0]);
    try std.testing.expectEqual(@as(u8, 'm'), events[1].csi.final);
    try std.testing.expectEqualSlices(u16, &.{ 38, 5, 196, 48, 2, 1, 2, 3 }, events[1].csi.params);
    try std.testing.expectEqualStrings("red", events[2].printable.bytes);
    try std.testing.expectEqualStrings("0;kurotty", events[3].osc.bytes);
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

test "grid applies absolute cursor, line erase, insert, delete, and alternate screen" {
    var grid = try core.Grid.init(std.testing.allocator, 5, 3);
    defer grid.deinit();

    try grid.write("abcde");
    grid.setCursor(0, 2);
    grid.insertCharacters(2);
    try std.testing.expectEqualStrings("ab  c", grid.rowText(0));

    grid.deleteCharacters(1);
    try std.testing.expectEqualStrings("ab c ", grid.rowText(0));

    grid.eraseLine(.right);
    try std.testing.expectEqualStrings("ab   ", grid.rowText(0));

    try grid.enterAlternateScreen();
    try grid.write("alt");
    try std.testing.expectEqualStrings("alt  ", grid.rowText(0));

    grid.leaveAlternateScreen();
    try std.testing.expectEqualStrings("ab   ", grid.rowText(0));
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

test "renderer damage controls draw call scheduling" {
    var renderer = core.RendererOrchestrator.init(std.testing.allocator);
    defer renderer.deinit();

    try std.testing.expectEqual(@as(u32, 0), renderer.beginFrame(100).draw_calls);
    try renderer.markDamage(.{ .row = 1, .col = 2, .rows = 3, .cols = 4 });
    const dirty = renderer.beginFrame(100);
    try std.testing.expectEqual(@as(u32, 1), dirty.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), dirty.dirty_rects);

    renderer.endFrame();
    const clean = renderer.beginFrame(100);
    try std.testing.expectEqual(@as(u32, 0), clean.draw_calls);
    try std.testing.expectEqual(@as(u32, 0), clean.dirty_rects);
}
