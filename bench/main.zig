const std = @import("std");
const core = @import("kurotty_core");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = core.Parser.init(allocator);
    defer parser.deinit();
    _ = try parser.feed("hello\x1b[31mred\x1b[0m\n");

    var grid = try core.Grid.init(allocator, 120, 40);
    defer grid.deinit();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) try grid.write("0123456789\n");

    var scrollback = try core.Scrollback.init(allocator, 1_000_000);
    defer scrollback.deinit();
    i = 0;
    while (i < 100_000) : (i += 1) try scrollback.appendFmt("bench-{d}", .{i});

    std.debug.print(
        "parser_bytes={d}\ngrid_writes={d}\nscrollback_lines={d}\nscrollback_bytes={d}\n",
        .{ 20, 10_000, scrollback.len(), scrollback.bytesUsed() },
    );
}
