const std = @import("std");
const core = @import("kurotty_core");

extern fn kurotty_terminal_create(width: u32, height: u32) ?*anyopaque;
extern fn kurotty_terminal_destroy(terminal: ?*anyopaque) void;
extern fn kurotty_terminal_feed(terminal: ?*anyopaque, bytes: [*]const u8, len: usize) usize;
extern fn kurotty_terminal_cursor_row(terminal: ?*anyopaque) u32;
extern fn kurotty_terminal_cursor_col(terminal: ?*anyopaque) u32;
extern fn kurotty_terminal_copy_row(terminal: ?*anyopaque, row: u32, buffer: ?[*]u8, buffer_len: usize) usize;
extern fn kurotty_terminal_copy_row_cells(terminal: ?*anyopaque, row: u32, buffer: ?[*]core.AbiCell, max_cells: usize) usize;

fn feedText(terminal: ?*anyopaque, text: []const u8) usize {
    return kurotty_terminal_feed(terminal, text.ptr, text.len);
}

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

test "parser clamps overflowing CSI parameters instead of silently defaulting" {
    // This used to assert `error.Overflow`, to stop an oversized parameter from
    // silently becoming 0. Clamping keeps that guarantee — 0 is still wrong and
    // still not what we produce — without failing the whole feed, which dropped
    // every event in the chunk and, in production, aborted the process.
    // Deliberately not an arena: an arena's `free` is a no-op, which is what hid
    // the invalid free on this path for so long.
    var parser = core.Parser.init(std.testing.allocator);
    defer parser.deinit();

    const events = try parser.feed("\x1b[999999999999m");
    defer parser.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualSlices(u16, &.{std.math.maxInt(u16)}, events[0].csi.params);
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

test "screen mutation recorder captures parser intent without mutating grid" {
    var parser = core.Parser.init(std.testing.allocator);
    defer parser.deinit();

    const events = try parser.feed("hi\x1b[2J!");
    defer parser.freeEvents(events);

    var recorder = core.ScreenMutationRecorder.init(std.testing.allocator, .{ .width = 4, .height = 2 });
    defer recorder.deinit();

    var grid = try core.Grid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();

    try recorder.recordEvents(events);

    try std.testing.expectEqual(@as(usize, 3), recorder.items().len);
    try std.testing.expectEqualStrings("hi", recorder.items()[0].printable.bytes);
    try std.testing.expectEqual(@as(usize, 0), recorder.items()[0].printable.row);
    try std.testing.expectEqual(@as(usize, 0), recorder.items()[0].printable.col);
    try std.testing.expectEqual(@as(usize, 2), recorder.items()[0].printable.cell_count);
    try std.testing.expectEqual(@as(usize, 2), recorder.items()[0].printable.raw_cell_count);
    try std.testing.expectEqual(@as(u8, 'J'), recorder.items()[1].csi.final);
    try std.testing.expectEqualSlices(u16, &.{2}, recorder.items()[1].csi.params);
    try std.testing.expectEqualStrings("!", recorder.items()[2].printable.bytes);
    var row_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("    ", grid.rowText(0, &row_buffer));
    try std.testing.expectEqual(@as(usize, 0), grid.cursorRow());
    try std.testing.expectEqual(@as(usize, 0), grid.cursorCol());
}

test "screen mutation recorder bounds printable cells for wide-ish row writes" {
    var parser = core.Parser.init(std.testing.allocator);
    defer parser.deinit();

    const events = try parser.feed("AＢC");
    defer parser.freeEvents(events);

    var recorder = core.ScreenMutationRecorder.init(std.testing.allocator, .{ .width = 3, .height = 1 });
    defer recorder.deinit();

    try recorder.recordEvents(events);

    try std.testing.expectEqual(@as(usize, 1), recorder.items().len);
    try std.testing.expectEqualStrings("AＢ", recorder.items()[0].printable.bytes);
    try std.testing.expectEqual(@as(usize, 3), recorder.items()[0].printable.cell_count);
    try std.testing.expectEqual(@as(usize, 4), recorder.items()[0].printable.raw_cell_count);
    try std.testing.expectEqual(@as(usize, 3), recorder.cursorCol());
    try std.testing.expect(recorder.items()[0].printable.cell_count <= recorder.widthCells());
}

test "screen mutation recorder does not split wide printable across final cell" {
    var parser = core.Parser.init(std.testing.allocator);
    defer parser.deinit();

    const events = try parser.feed("A界");
    defer parser.freeEvents(events);

    var recorder = core.ScreenMutationRecorder.init(std.testing.allocator, .{ .width = 2, .height = 1 });
    defer recorder.deinit();

    try recorder.recordEvents(events);

    try std.testing.expectEqual(@as(usize, 1), recorder.items().len);
    try std.testing.expectEqualStrings("A", recorder.items()[0].printable.bytes);
    try std.testing.expectEqual(@as(usize, 1), recorder.items()[0].printable.cell_count);
    try std.testing.expectEqual(@as(usize, 3), recorder.items()[0].printable.raw_cell_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.cursorCol());
}

test "grid applies printable text, cursor movement, and erase in display" {
    var grid = try core.Grid.init(std.testing.allocator, 4, 3);
    defer grid.deinit();

    try grid.write("abcd");
    try grid.write("ef");
    grid.moveCursor(.{ .row_delta = -1, .col_delta = 0 });
    try grid.write("XY");
    grid.eraseDisplay(.below);

    var row_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("abXY", grid.rowText(0, &row_buffer));
    try std.testing.expectEqualStrings("    ", grid.rowText(1, &row_buffer));
    try std.testing.expectEqual(@as(usize, 0), grid.cursorRow());
    try std.testing.expectEqual(@as(usize, 4), grid.cursorCol());
}

test "grid applies absolute cursor, line erase, insert, delete, and alternate screen" {
    var grid = try core.Grid.init(std.testing.allocator, 5, 3);
    defer grid.deinit();

    var row_buffer: [32]u8 = undefined;
    try grid.write("abcde");
    grid.setCursor(0, 2);
    grid.insertCharacters(2);
    try std.testing.expectEqualStrings("ab  c", grid.rowText(0, &row_buffer));

    grid.deleteCharacters(1);
    try std.testing.expectEqualStrings("ab c ", grid.rowText(0, &row_buffer));

    grid.eraseLine(.right);
    try std.testing.expectEqualStrings("ab   ", grid.rowText(0, &row_buffer));

    try grid.enterAlternateScreen();
    try grid.write("alt");
    try std.testing.expectEqualStrings("alt  ", grid.rowText(0, &row_buffer));

    grid.leaveAlternateScreen();
    try std.testing.expectEqualStrings("ab   ", grid.rowText(0, &row_buffer));
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

    var row_buffer: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), grid.width);
    try std.testing.expectEqual(@as(usize, 3), grid.height);
    try std.testing.expectEqualStrings("abc  ", grid.rowText(0, &row_buffer));
    try std.testing.expectEqualStrings("def  ", grid.rowText(1, &row_buffer));
    try std.testing.expectEqualStrings("     ", grid.rowText(2, &row_buffer));
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

test "pty dimensions accept valid terminal cell sizes" {
    const dims = try core.PtyDimensions.init(120, 40);

    try std.testing.expectEqual(@as(u16, 120), dims.cols);
    try std.testing.expectEqual(@as(u16, 40), dims.rows);
}

test "pty dimensions reject zero and winsize overflow" {
    try std.testing.expectError(error.InvalidDimensions, core.PtyDimensions.init(0, 24));
    try std.testing.expectError(error.InvalidDimensions, core.PtyDimensions.init(80, 0));
    try std.testing.expectError(error.DimensionOverflow, core.PtyDimensions.init(65_536, 24));
    try std.testing.expectError(error.DimensionOverflow, core.PtyDimensions.init(80, 65_536));
}

test "pty size diagnostic reports renderer mismatch deltas" {
    const pty = try core.PtyDimensions.init(100, 30);
    const renderer = try core.PtyDimensions.init(96, 32);

    const diagnostic = core.PtySizeDiagnostic.compare(pty, renderer);

    try std.testing.expectEqual(core.PtySizeStatus.mismatch, diagnostic.status);
    try std.testing.expect(!diagnostic.matches());
    try std.testing.expectEqual(@as(i32, -4), diagnostic.cols_delta);
    try std.testing.expectEqual(@as(i32, 2), diagnostic.rows_delta);
}

test "pty resize request construction validates requested dimensions" {
    const request = try core.PtyResizeRequest.init(132, 43, .renderer, 7);

    try std.testing.expectEqual(@as(u64, 7), request.sequence);
    try std.testing.expectEqual(core.PtyResizeSource.renderer, request.source);
    try std.testing.expectEqual(@as(u16, 132), request.dimensions.cols);
    try std.testing.expectEqual(@as(u16, 43), request.dimensions.rows);
    try std.testing.expectError(error.InvalidDimensions, core.PtyResizeRequest.init(0, 43, .renderer, 8));
}

test "grid gives Korean wide char a head cell plus continuation cell" {
    var grid = try core.Grid.init(std.testing.allocator, 6, 2);
    defer grid.deinit();

    try grid.write("한A");

    const head = grid.cellInfoAt(0, 0);
    try std.testing.expectEqual(@as(u21, 0xd55c), head.codepoint);
    try std.testing.expectEqual(core.CellWidth.wide, head.width);
    try std.testing.expectEqual(core.CellWidth.continuation, grid.cellInfoAt(0, 1).width);
    try std.testing.expectEqual(@as(u21, 'A'), grid.cellInfoAt(0, 2).codepoint);
    try std.testing.expectEqual(@as(usize, 3), grid.cursorCol());

    var row_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("한A   ", grid.rowText(0, &row_buffer));
}

test "grid wraps a wide char that does not fit in the last column" {
    var grid = try core.Grid.init(std.testing.allocator, 3, 2);
    defer grid.deinit();

    try grid.write("ab界");

    try std.testing.expectEqual(@as(u21, 'a'), grid.cellInfoAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellInfoAt(0, 2).codepoint);
    try std.testing.expectEqual(core.CellWidth.wide, grid.cellInfoAt(1, 0).width);
    try std.testing.expectEqual(core.CellWidth.continuation, grid.cellInfoAt(1, 1).width);
    try std.testing.expectEqual(@as(usize, 1), grid.cursorRow());
    try std.testing.expectEqual(@as(usize, 2), grid.cursorCol());
}

test "grid overwriting half of a wide char clears its partner cell" {
    var grid = try core.Grid.init(std.testing.allocator, 6, 1);
    defer grid.deinit();

    try grid.write("한");
    grid.setCursor(0, 1);
    try grid.write("x");

    try std.testing.expectEqual(@as(u21, ' '), grid.cellInfoAt(0, 0).codepoint);
    try std.testing.expectEqual(core.CellWidth.single, grid.cellInfoAt(0, 0).width);
    try std.testing.expectEqual(@as(u21, 'x'), grid.cellInfoAt(0, 1).codepoint);
}

test "grid attaches combining mark to previous cell without advancing cursor" {
    var grid = try core.Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();

    try grid.write("a\u{0301}b");

    try std.testing.expectEqual(@as(u21, 'a'), grid.cellInfoAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 0x0301), grid.cellInfoAt(0, 0).combining);
    try std.testing.expectEqual(@as(u21, 'b'), grid.cellInfoAt(0, 1).codepoint);
    try std.testing.expectEqual(@as(usize, 2), grid.cursorCol());

    var row_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a\u{0301}b  ", grid.rowText(0, &row_buffer));
}

test "grid decodes UTF-8 sequences split across write calls" {
    var grid = try core.Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();

    const bytes = "한";
    try grid.write(bytes[0..1]);
    try grid.write(bytes[1..]);

    try std.testing.expectEqual(@as(u21, 0xd55c), grid.cellInfoAt(0, 0).codepoint);
    try std.testing.expectEqual(core.CellWidth.wide, grid.cellInfoAt(0, 0).width);
    try std.testing.expectEqual(@as(usize, 2), grid.cursorCol());
}

test "grid tab moves cursor to next multiple-of-8 stop without erasing" {
    var grid = try core.Grid.init(std.testing.allocator, 20, 1);
    defer grid.deinit();

    try grid.write("abc");
    grid.setCursor(0, 1);
    grid.tab();
    try std.testing.expectEqual(@as(usize, 8), grid.cursorCol());
    try std.testing.expectEqual(@as(u21, 'c'), grid.cellInfoAt(0, 2).codepoint);

    grid.tab();
    try std.testing.expectEqual(@as(usize, 16), grid.cursorCol());
    grid.tab();
    try std.testing.expectEqual(@as(usize, 19), grid.cursorCol());
}

test "grid restores saved cursor when leaving the alternate screen" {
    var grid = try core.Grid.init(std.testing.allocator, 10, 4);
    defer grid.deinit();

    grid.setCursor(2, 5);
    try grid.enterAlternateScreen();
    try std.testing.expectEqual(@as(usize, 0), grid.cursorRow());
    try std.testing.expectEqual(@as(usize, 0), grid.cursorCol());

    grid.setCursor(3, 9);
    grid.leaveAlternateScreen();
    try std.testing.expectEqual(@as(usize, 2), grid.cursorRow());
    try std.testing.expectEqual(@as(usize, 5), grid.cursorCol());
}

test "ABI tab control moves the cursor non-destructively" {
    const terminal = kurotty_terminal_create(20, 2) orelse return error.TerminalCreateFailed;
    defer kurotty_terminal_destroy(terminal);

    _ = feedText(terminal, "ab\rx\ty");
    try std.testing.expectEqual(@as(u32, 9), kurotty_terminal_cursor_col(terminal));

    var buffer: [20]u8 = undefined;
    _ = kurotty_terminal_copy_row(terminal, 0, &buffer, buffer.len);
    try std.testing.expectEqualStrings("xb      y", buffer[0..9]);
}

test "ABI SGR colors and attributes round-trip through copy_row_cells" {
    const terminal = kurotty_terminal_create(8, 2) orelse return error.TerminalCreateFailed;
    defer kurotty_terminal_destroy(terminal);

    _ = feedText(terminal, "\x1b[1;4;31;48;5;200mA\x1b[38;2;10;20;30mB\x1b[0mC");

    var cells: [8]core.AbiCell = undefined;
    try std.testing.expectEqual(@as(usize, 8), kurotty_terminal_copy_row_cells(terminal, 0, &cells, cells.len));

    try std.testing.expectEqual(@as(u32, 'A'), cells[0].codepoint);
    try std.testing.expectEqual(core.Color.indexed(1), cells[0].fg);
    try std.testing.expectEqual(core.Color.indexed(200), cells[0].bg);
    const attrs_a: core.Attributes = @bitCast(cells[0].attrs);
    try std.testing.expect(attrs_a.bold);
    try std.testing.expect(attrs_a.underline);
    try std.testing.expect(!attrs_a.inverse);
    try std.testing.expectEqual(@as(u8, 1), cells[0].width);

    try std.testing.expectEqual(@as(u32, 'B'), cells[1].codepoint);
    try std.testing.expectEqual(core.Color.rgb(10, 20, 30), cells[1].fg);
    try std.testing.expectEqual(core.Color.indexed(200), cells[1].bg);

    try std.testing.expectEqual(@as(u32, 'C'), cells[2].codepoint);
    try std.testing.expectEqual(core.Color.default, cells[2].fg);
    try std.testing.expectEqual(core.Color.default, cells[2].bg);
    try std.testing.expectEqual(@as(u16, 0), cells[2].attrs);
}

test "ABI copy_row_cells reports wide head and continuation widths" {
    const terminal = kurotty_terminal_create(6, 1) orelse return error.TerminalCreateFailed;
    defer kurotty_terminal_destroy(terminal);

    _ = feedText(terminal, "한A");

    var cells: [6]core.AbiCell = undefined;
    try std.testing.expectEqual(@as(usize, 6), kurotty_terminal_copy_row_cells(terminal, 0, &cells, cells.len));
    try std.testing.expectEqual(@as(u32, 0xd55c), cells[0].codepoint);
    try std.testing.expectEqual(@as(u8, 2), cells[0].width);
    try std.testing.expectEqual(@as(u8, 0), cells[1].width);
    try std.testing.expectEqual(@as(u32, 'A'), cells[2].codepoint);

    var bytes: [6]u8 = undefined;
    _ = kurotty_terminal_copy_row(terminal, 0, &bytes, bytes.len);
    try std.testing.expectEqualStrings("  A   ", &bytes);
}

test "ABI CSI parameter defaults are explicit per opcode" {
    const terminal = kurotty_terminal_create(10, 4) orelse return error.TerminalCreateFailed;
    defer kurotty_terminal_destroy(terminal);

    _ = feedText(terminal, "\x1b[2;5H");
    try std.testing.expectEqual(@as(u32, 1), kurotty_terminal_cursor_row(terminal));
    try std.testing.expectEqual(@as(u32, 4), kurotty_terminal_cursor_col(terminal));

    _ = feedText(terminal, "\x1b[H");
    try std.testing.expectEqual(@as(u32, 0), kurotty_terminal_cursor_row(terminal));
    try std.testing.expectEqual(@as(u32, 0), kurotty_terminal_cursor_col(terminal));

    _ = feedText(terminal, "\x1b[0B\x1b[0C");
    try std.testing.expectEqual(@as(u32, 1), kurotty_terminal_cursor_row(terminal));
    try std.testing.expectEqual(@as(u32, 1), kurotty_terminal_cursor_col(terminal));

    _ = feedText(terminal, "ab\x1b[3G");
    try std.testing.expectEqual(@as(u32, 2), kurotty_terminal_cursor_col(terminal));

    _ = feedText(terminal, "\x1b[K");
    var bytes: [10]u8 = undefined;
    _ = kurotty_terminal_copy_row(terminal, 1, &bytes, bytes.len);
    try std.testing.expectEqualStrings(" a        ", &bytes);
}

test "ABI alternate screen restores cursor position on leave" {
    const terminal = kurotty_terminal_create(10, 4) orelse return error.TerminalCreateFailed;
    defer kurotty_terminal_destroy(terminal);

    _ = feedText(terminal, "\x1b[3;7H\x1b[?1049h");
    try std.testing.expectEqual(@as(u32, 0), kurotty_terminal_cursor_row(terminal));
    try std.testing.expectEqual(@as(u32, 0), kurotty_terminal_cursor_col(terminal));

    _ = feedText(terminal, "alt\x1b[?1049l");
    try std.testing.expectEqual(@as(u32, 2), kurotty_terminal_cursor_row(terminal));
    try std.testing.expectEqual(@as(u32, 6), kurotty_terminal_cursor_col(terminal));
}

test "renderer clips damage rects to grid bounds and caps the pending list" {
    var renderer = core.RendererOrchestrator.init(std.testing.allocator);
    defer renderer.deinit();
    renderer.setGridBounds(24, 80);

    try renderer.markDamage(.{ .row = 30, .col = 0, .rows = 1, .cols = 4 });
    try renderer.markDamage(.{ .row = 0, .col = 0, .rows = 0, .cols = 4 });
    try std.testing.expectEqual(@as(u32, 0), renderer.beginFrame(1).dirty_rects);

    try renderer.markDamage(.{ .row = 20, .col = 70, .rows = 100, .cols = 100 });
    try std.testing.expectEqual(@as(u32, 1), renderer.beginFrame(1).dirty_rects);
    renderer.endFrame();

    const cap: u32 = @intCast(core.RendererOrchestrator.max_damage_rects);
    var index: u32 = 0;
    while (index < cap) : (index += 1) {
        try renderer.markDamage(.{ .row = index % 24, .col = index % 80, .rows = 1, .cols = 1 });
    }
    try std.testing.expectEqual(cap, renderer.beginFrame(1).dirty_rects);

    try renderer.markDamage(.{ .row = 5, .col = 5, .rows = 1, .cols = 1 });
    try std.testing.expectEqual(@as(u32, 1), renderer.beginFrame(1).dirty_rects);
}

test "ABI ignores private CSI m sequences for text style" {
    const terminal = kurotty_terminal_create(8, 1) orelse return error.TerminalCreateFailed;
    defer kurotty_terminal_destroy(terminal);

    _ = feedText(terminal, "\x1b[>4;2mA");

    var cells: [8]core.AbiCell = undefined;
    try std.testing.expectEqual(@as(usize, 8), kurotty_terminal_copy_row_cells(terminal, 0, &cells, cells.len));
    try std.testing.expectEqual(@as(u32, 'A'), cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 0), cells[0].attrs);
    try std.testing.expectEqual(core.Color.default, cells[0].fg);
    try std.testing.expectEqual(core.Color.default, cells[0].bg);
}

test "parser clamps an oversized CSI parameter instead of aborting" {
    // `\x1b[99999m` overflowed the u16 parameter parse. The overflow was
    // propagated out of `feed`, whose errdefer then freed a borrowed slice as
    // if it owned the allocation — an invalid free, reachable from any byte a
    // child process writes.
    var parser = core.Parser.init(std.testing.allocator);
    defer parser.deinit();

    const events = try parser.feed("hello\x1b[99999m world");
    defer parser.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("hello", events[0].printable.bytes);
    try std.testing.expectEqual(@as(u8, 'm'), events[1].csi.final);
    try std.testing.expectEqual(std.math.maxInt(u16), events[1].csi.params[0]);
    try std.testing.expectEqualStrings(" world", events[2].printable.bytes);
}

test "parser survives an oversized parameter mid-stream and keeps parsing" {
    var parser = core.Parser.init(std.testing.allocator);
    defer parser.deinit();

    const first = try parser.feed("\x1b[70000;5H");
    defer parser.freeEvents(first);
    try std.testing.expectEqual(std.math.maxInt(u16), first[0].csi.params[0]);
    try std.testing.expectEqual(@as(u16, 5), first[0].csi.params[1]);

    const second = try parser.feed("ok");
    defer parser.freeEvents(second);
    try std.testing.expectEqualStrings("ok", second[0].printable.bytes);
}

// The DCS/SOS/PM/APC payload has no buffer to overflow — it is dropped byte by
// byte — so what an unbounded string control costs is the stream: every byte
// after a missing `ESC \` is consumed forever and no later sequence parses.
// Deliberately not an arena: an arena's `free` is a no-op, which is what hid
// the invalid free on this parser for so long.
test "parser abandons an unterminated string control instead of swallowing the stream" {
    var parser = core.Parser.init(std.testing.allocator);
    defer parser.deinit();

    const payload_chunk = "x" ** 4096;
    const opening = try parser.feed("\x1bP");
    defer parser.freeEvents(opening);
    try std.testing.expectEqual(@as(usize, 0), opening.len);

    var consumed: usize = 0;
    while (consumed < core.Parser.max_string_control_bytes) : (consumed += payload_chunk.len) {
        const events = try parser.feed(payload_chunk);
        defer parser.freeEvents(events);
        try std.testing.expectEqual(@as(usize, 0), events.len);
    }
    try std.testing.expectEqual(core.Parser.max_string_control_bytes, consumed);

    // The byte that crosses the bound belongs to the payload and is dropped
    // with it; `ok` is the first byte the abandoned sequence no longer owns.
    const resynchronized = try parser.feed("xok");
    defer parser.freeEvents(resynchronized);
    try std.testing.expectEqual(@as(usize, 1), resynchronized.len);
    try std.testing.expectEqualStrings("ok", resynchronized[0].printable.bytes);
}

// The other half of the bound. A payload that stays inside it is still
// consumed whole, terminator and all — a bound that abandons real sequences
// would be the worse bug.
test "parser consumes a string control up to the bound and resynchronizes at its terminator" {
    var parser = core.Parser.init(std.testing.allocator);
    defer parser.deinit();

    const payload_chunk = "x" ** 4096;
    const opening = try parser.feed("\x1b_G");
    defer parser.freeEvents(opening);

    var consumed: usize = "G".len;
    while (consumed + payload_chunk.len <= core.Parser.max_string_control_bytes) : (consumed += payload_chunk.len) {
        const events = try parser.feed(payload_chunk);
        defer parser.freeEvents(events);
        try std.testing.expectEqual(@as(usize, 0), events.len);
    }

    const terminated = try parser.feed("\x1b\\ok");
    defer parser.freeEvents(terminated);
    try std.testing.expectEqual(@as(usize, 1), terminated.len);
    try std.testing.expectEqualStrings("ok", terminated[0].printable.bytes);
}
