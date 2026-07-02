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

test "parser keeps incomplete OSC until BEL or string terminator arrives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const first = try parser.feed("prefix\x1b]0;kur");
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("prefix", first[0].printable.bytes);

    const second = try parser.feed("otty");
    try std.testing.expectEqual(@as(usize, 0), second.len);

    const third = try parser.feed("\x1b\\suffix\x1b]1;tab\x07");
    try std.testing.expectEqual(@as(usize, 3), third.len);
    try std.testing.expectEqualStrings("0;kurotty", third[0].osc.bytes);
    try std.testing.expectEqualStrings("suffix", third[1].printable.bytes);
    try std.testing.expectEqualStrings("1;tab", third[2].osc.bytes);
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

test "parser handles SGR reset variants and colon color parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const events = try parser.feed("\x1b[m\x1b[0;39;49;22;23;24;25;27;28;29m\x1b[38:2::1:2:3m");

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualSlices(u16, &.{0}, events[0].csi.params);
    try std.testing.expectEqualSlices(u16, &.{ 0, 39, 49, 22, 23, 24, 25, 27, 28, 29 }, events[1].csi.params);
    try std.testing.expectEqualSlices(u16, &.{ 38, 2, 0, 1, 2, 3 }, events[2].csi.params);
}

test "parser rejects overflowing CSI parameters instead of silently defaulting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    try std.testing.expectError(error.Overflow, parser.feed("\x1b[999999999999m"));
}

test "parser preserves private cursor and report CSI sequences across fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const first = try parser.feed("\x1b[?2004");
    try std.testing.expectEqual(@as(usize, 0), first.len);

    const second = try parser.feed("h\x1b[>0");
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expect(second[0].csi.private);
    try std.testing.expectEqual(@as(u8, 'h'), second[0].csi.final);
    try std.testing.expectEqualSlices(u16, &.{2004}, second[0].csi.params);

    const third = try parser.feed("c\x1b[6n\x1b[?6n");
    try std.testing.expectEqual(@as(usize, 3), third.len);
    try std.testing.expect(third[0].csi.private);
    try std.testing.expectEqual(@as(u8, 'c'), third[0].csi.final);
    try std.testing.expectEqualSlices(u16, &.{0}, third[0].csi.params);
    try std.testing.expect(!third[1].csi.private);
    try std.testing.expectEqual(@as(u8, 'n'), third[1].csi.final);
    try std.testing.expectEqualSlices(u16, &.{6}, third[1].csi.params);
    try std.testing.expect(third[2].csi.private);
    try std.testing.expectEqual(@as(u8, 'n'), third[2].csi.final);
    try std.testing.expectEqualSlices(u16, &.{6}, third[2].csi.params);
}

test "parser suppresses charset designators used by tmux terminfo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const events = try parser.feed("A\x1b(BB\x1b)0C\x1b%GD");

    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expectEqualStrings("A", events[0].printable.bytes);
    try std.testing.expectEqualStrings("B", events[1].printable.bytes);
    try std.testing.expectEqualStrings("C", events[2].printable.bytes);
    try std.testing.expectEqualStrings("D", events[3].printable.bytes);
}

test "parser preserves exact CSI prefix for device attribute queries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const events = try parser.feed("\x1b[c\x1b[>0c\x1b[?1;2c");

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(@as(u8, 'c'), events[0].csi.final);
    try std.testing.expectEqual(@as(?u8, null), events[0].csi.prefix);
    try std.testing.expectEqual(@as(?u8, '>'), events[1].csi.prefix);
    try std.testing.expectEqual(@as(?u8, '?'), events[2].csi.prefix);
}

test "parser suppresses fragmented charset designators without printable leakage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const first = try parser.feed("A\x1b(");
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("A", first[0].printable.bytes);

    const second = try parser.feed("BC\x1b)");
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqualStrings("C", second[0].printable.bytes);

    const third = try parser.feed("0D");
    try std.testing.expectEqual(@as(usize, 1), third.len);
    try std.testing.expectEqualStrings("D", third[0].printable.bytes);
}

test "parser suppresses fragmented DEC private two byte escapes without printable leakage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const first = try parser.feed("A\x1b#");
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("A", first[0].printable.bytes);

    const second = try parser.feed("8B");
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqualStrings("B", second[0].printable.bytes);
}

test "parser preserves fragmented device attribute prefixes without printable leakage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    try std.testing.expectEqual(@as(usize, 0), (try parser.feed("\x1b[")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parser.feed(">0")).len);

    const first = try parser.feed("cX\x1b[?1;2");
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqual(@as(u8, 'c'), first[0].csi.final);
    try std.testing.expectEqual(@as(?u8, '>'), first[0].csi.prefix);
    try std.testing.expectEqualStrings("X", first[1].printable.bytes);

    const second = try parser.feed("c");
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(@as(u8, 'c'), second[0].csi.final);
    try std.testing.expectEqual(@as(?u8, '?'), second[0].csi.prefix);
}

test "parser suppresses fragmented DCS PM and APC payloads until terminators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const first = try parser.feed("a\x1bP1$r");
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("a", first[0].printable.bytes);

    const second = try parser.feed("q\x1b\\b\x1b^pm");
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqualStrings("b", second[0].printable.bytes);

    const third = try parser.feed("-ignored\x07c\x1b_apc");
    try std.testing.expectEqual(@as(usize, 1), third.len);
    try std.testing.expectEqualStrings("c", third[0].printable.bytes);

    const fourth = try parser.feed("-ignored\x1b\\d");
    try std.testing.expectEqual(@as(usize, 1), fourth.len);
    try std.testing.expectEqualStrings("d", fourth[0].printable.bytes);
}

test "parser keeps OSC open when ESC is not a string terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const first = try parser.feed("\x1b]0;title\x1bX");
    try std.testing.expectEqual(@as(usize, 0), first.len);

    const second = try parser.feed("-suffix\x07done");
    try std.testing.expectEqual(@as(usize, 2), second.len);
    try std.testing.expectEqualStrings("0;title\x1bX-suffix", second[0].osc.bytes);
    try std.testing.expectEqualStrings("done", second[1].printable.bytes);
}

test "parser bounds oversized CSI buffers and resynchronizes at the final byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const oversized_digits = "1" ** (core.Parser.max_csi_sequence_bytes + 1);
    const first = try parser.feed("\x1b[" ++ oversized_digits);
    try std.testing.expectEqual(@as(usize, 0), first.len);
    try std.testing.expectEqual(@as(usize, 0), parser.control.items.len);

    const second = try parser.feed("mok");
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqualStrings("ok", second[0].printable.bytes);
}

test "parser bounds oversized OSC buffers and resynchronizes at string terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = core.Parser.init(arena.allocator());
    defer parser.deinit();

    const oversized_title = "x" ** (core.Parser.max_string_sequence_bytes + 1);
    const first = try parser.feed("\x1b]0;" ++ oversized_title);
    try std.testing.expectEqual(@as(usize, 0), first.len);
    try std.testing.expectEqual(@as(usize, 0), parser.string.items.len);

    const second = try parser.feed("\x1b\\ok");
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqualStrings("ok", second[0].printable.bytes);
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

test "grid rejects zero dimensions before allocation and cursor math" {
    try std.testing.expectError(error.InvalidDimensions, core.Grid.init(std.testing.allocator, 0, 3));
    try std.testing.expectError(error.InvalidDimensions, core.Grid.init(std.testing.allocator, 3, 0));
}

test "grid restores alternate screen deterministically after resize" {
    var grid = try core.Grid.init(std.testing.allocator, 3, 2);
    defer grid.deinit();

    try grid.write("abcdef");
    try grid.enterAlternateScreen();
    try grid.write("xyz");
    try grid.resize(5, 3);

    grid.leaveAlternateScreen();

    try std.testing.expectEqual(@as(usize, 5), grid.width);
    try std.testing.expectEqual(@as(usize, 3), grid.height);
    try std.testing.expectEqualStrings("abc  ", grid.rowText(0));
    try std.testing.expectEqualStrings("def  ", grid.rowText(1));
    try std.testing.expectEqualStrings("     ", grid.rowText(2));
}

test "grid reports current dimensions after init and resize" {
    var grid = try core.Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();

    try std.testing.expectEqual(@as(usize, 4), grid.widthCells());
    try std.testing.expectEqual(@as(usize, 2), grid.heightRows());

    try grid.resize(0, 5);

    try std.testing.expectEqual(@as(usize, 1), grid.widthCells());
    try std.testing.expectEqual(@as(usize, 5), grid.heightRows());
}

test "grid copies rows into caller buffers without exposing owned storage" {
    var grid = try core.Grid.init(std.testing.allocator, 5, 2);
    defer grid.deinit();

    try grid.write("abcde");
    try grid.write("xy");

    var full_buffer: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), grid.copyRow(0, &full_buffer));
    try std.testing.expectEqualStrings("abcde", &full_buffer);

    var short_buffer: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), grid.copyRow(1, &short_buffer));
    try std.testing.expectEqualStrings("xy ", &short_buffer);

    var unchanged: [2]u8 = .{ 1, 2 };
    try std.testing.expectEqual(@as(usize, 0), grid.copyRow(2, &unchanged));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &unchanged);
    try std.testing.expectEqual(@as(usize, 0), grid.copyRow(0, unchanged[0..0]));
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

test "scrollback churns past capacity and releases evicted lines" {
    const capacity = 128;
    const appended = 4096;
    var scrollback = try core.Scrollback.init(std.testing.allocator, capacity);
    defer scrollback.deinit();

    var i: usize = 0;
    while (i < appended) : (i += 1) {
        try scrollback.appendFmt("line-{d:0>4}-payload", .{i});
    }

    try std.testing.expectEqual(@as(usize, capacity), scrollback.len());
    try std.testing.expectEqualStrings("line-3968-payload", scrollback.lineAt(0));
    try std.testing.expectEqualStrings("line-4095-payload", scrollback.lineAt(capacity - 1));
    try std.testing.expect(scrollback.bytesUsed() < 32 * 1024);
}

test "scrollback rejects zero capacity instead of growing unbounded" {
    try std.testing.expectError(error.InvalidCapacity, core.Scrollback.init(std.testing.allocator, 0));
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

test "renderer damage lifecycle reuses retained storage across frames" {
    var renderer = core.RendererOrchestrator.init(std.testing.allocator);
    defer renderer.deinit();

    var frame: u32 = 0;
    while (frame < 128) : (frame += 1) {
        var rect: u32 = 0;
        while (rect < 16) : (rect += 1) {
            try renderer.markDamage(.{ .row = frame, .col = rect, .rows = 1, .cols = 2 });
        }

        const dirty = renderer.beginFrame(240);
        try std.testing.expectEqual(@as(u32, 16), dirty.dirty_rects);
        try std.testing.expectEqual(@as(u32, 1), dirty.draw_calls);

        renderer.endFrame();
        const clean = renderer.beginFrame(240);
        try std.testing.expectEqual(@as(u32, 0), clean.dirty_rects);
        try std.testing.expectEqual(@as(u32, 0), clean.draw_calls);
    }
}
