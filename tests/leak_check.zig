const std = @import("std");
const core = @import("kurotty_core");

extern fn kurotty_terminal_create(width: u32, height: u32) ?*anyopaque;
extern fn kurotty_terminal_destroy(terminal: ?*anyopaque) void;
extern fn kurotty_terminal_feed(terminal: ?*anyopaque, bytes: [*]const u8, len: usize) usize;
extern fn kurotty_terminal_record_key(terminal: ?*anyopaque, timestamp_micros: u64) void;
extern fn kurotty_terminal_record_present(terminal: ?*anyopaque, timestamp_micros: u64) void;
extern fn kurotty_terminal_last_latency(terminal: ?*anyopaque) u64;
extern fn kurotty_terminal_cursor_row(terminal: ?*anyopaque) u32;
extern fn kurotty_terminal_cursor_col(terminal: ?*anyopaque) u32;
extern fn kurotty_terminal_mark_damage(terminal: ?*anyopaque, row: u32, col: u32, rows: u32, cols: u32) void;
extern fn kurotty_terminal_begin_frame(terminal: ?*anyopaque, visible_cells: u32) u32;
extern fn kurotty_terminal_end_frame(terminal: ?*anyopaque) void;
extern fn kurotty_terminal_resize(terminal: ?*anyopaque, width: u32, height: u32) void;
extern fn kurotty_terminal_cell_at(terminal: ?*anyopaque, row: u32, col: u32) u8;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    try exerciseAbiLifecycle();
    try exerciseParserIncompleteSequences(allocator);
    try exerciseCoreAllocatorPaths(allocator);

    const status = gpa.deinit();
    if (status == .leak) {
        std.debug.print("kurotty leak check failed\n", .{});
        std.process.exit(1);
    }
}

fn exerciseAbiLifecycle() !void {
    const terminal = kurotty_terminal_create(8, 3) orelse return error.TerminalCreateFailed;
    defer kurotty_terminal_destroy(terminal);

    try expectEqual(@as(usize, 5), kurotty_terminal_feed(terminal, "hello".ptr, "hello".len));
    try expectEqual(@as(usize, 0), kurotty_terminal_feed(terminal, "\x1b[2".ptr, "\x1b[2".len));
    try expectEqual(@as(usize, 5), kurotty_terminal_feed(terminal, "Jworld".ptr, "Jworld".len));
    try expectEqual(@as(u8, 'w'), kurotty_terminal_cell_at(terminal, 0, 5));

    kurotty_terminal_resize(terminal, 16, 4);
    try expectEqual(@as(usize, 3), kurotty_terminal_feed(terminal, "\x1b[2;4Hxyz".ptr, "\x1b[2;4Hxyz".len));
    try expectEqual(@as(u32, 1), kurotty_terminal_cursor_row(terminal));
    try expectEqual(@as(u32, 6), kurotty_terminal_cursor_col(terminal));
    try expectEqual(@as(u8, 'x'), kurotty_terminal_cell_at(terminal, 1, 3));

    kurotty_terminal_record_key(terminal, 10);
    kurotty_terminal_record_present(terminal, 42);
    try expectEqual(@as(u64, 32), kurotty_terminal_last_latency(terminal));

    kurotty_terminal_mark_damage(terminal, 0, 0, 4, 16);
    try expectEqual(@as(u32, 1), kurotty_terminal_begin_frame(terminal, 64));
    kurotty_terminal_end_frame(terminal);
    try expectEqual(@as(u32, 0), kurotty_terminal_begin_frame(terminal, 64));
    kurotty_terminal_end_frame(terminal);
}

fn exerciseParserIncompleteSequences(allocator: std.mem.Allocator) !void {
    var parser = core.Parser.init(allocator);
    defer parser.deinit();

    var events = try parser.feed("hello\x1b[38;5;45");
    try expectEqual(@as(usize, 1), events.len);
    parser.freeEvents(events);

    events = try parser.feed("mworld\x1b]0;kur");
    try expectEqual(@as(usize, 2), events.len);
    parser.freeEvents(events);

    events = try parser.feed("otty");
    try expectEqual(@as(usize, 0), events.len);
    parser.freeEvents(events);

    events = try parser.feed("\x1b\\\x1b]1;tab-title\x07\x1b[?1049");
    try expectEqual(@as(usize, 2), events.len);
    parser.freeEvents(events);

    events = try parser.feed("h\x1b[?1049l");
    try expectEqual(@as(usize, 2), events.len);
    parser.freeEvents(events);

    events = try parser.feed("\x1bP1$rq\x1b\\\x1b^pm");
    try expectEqual(@as(usize, 0), events.len);
    parser.freeEvents(events);

    events = try parser.feed("-ignored\x07\x1b_apc");
    try expectEqual(@as(usize, 0), events.len);
    parser.freeEvents(events);

    events = try parser.feed("-ignored\x1b\\\x1b]0;title\x1bX");
    try expectEqual(@as(usize, 0), events.len);
    parser.freeEvents(events);

    events = try parser.feed("-suffix\x07");
    try expectEqual(@as(usize, 1), events.len);
    parser.freeEvents(events);
}

fn exerciseCoreAllocatorPaths(allocator: std.mem.Allocator) !void {
    var grid = try core.Grid.init(allocator, 120, 40);
    defer grid.deinit();
    try grid.write("hello world");
    grid.setCursor(0, 0);
    grid.eraseLine(.right);

    var scrollback = try core.Scrollback.init(allocator, 4096);
    defer scrollback.deinit();
    var index: usize = 0;
    while (index < 65_536) : (index += 1) {
        try scrollback.appendFmt("scrollback-line-{d:0>5}-payload-for-retention-churn", .{index});
    }
    try expectEqual(@as(usize, 4096), scrollback.len());
    try expectEqualStrings("scrollback-line-61440-payload-for-retention-churn", scrollback.lineAt(0));

    var renderer = core.RendererOrchestrator.init(allocator);
    defer renderer.deinit();
    var frame: u32 = 0;
    while (frame < 2048) : (frame += 1) {
        try renderer.markDamage(.{ .row = frame % 40, .col = frame % 120, .rows = 1, .cols = 8 });
        if (frame % 4 == 3) {
            const dirty = renderer.beginFrame(120 * 40);
            try expectEqual(@as(u32, 1), dirty.draw_calls);
            renderer.endFrame();
            const clean = renderer.beginFrame(120 * 40);
            try expectEqual(@as(u32, 0), clean.draw_calls);
        }
    }
}

fn expectEqual(expected: anytype, actual: @TypeOf(expected)) !void {
    if (actual != expected) {
        std.debug.print("expected {}, got {}\n", .{ expected, actual });
        return error.UnexpectedValue;
    }
}

fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print("expected \"{s}\", got \"{s}\"\n", .{ expected, actual });
        return error.UnexpectedValue;
    }
}
