const std = @import("std");
const core = @import("kurotty_core");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) std.process.exit(2);
    }

    var scrollback = try core.Scrollback.init(gpa.allocator(), 1_000_000);
    defer scrollback.deinit();

    var i: usize = 0;
    while (i < 1_000_000) : (i += 1) {
        try scrollback.appendFmt("line-{d}", .{i});
    }

    if (scrollback.len() != 1_000_000) return error.BadScrollbackLength;
    if (!std.mem.eql(u8, scrollback.lineAt(0), "line-0")) return error.BadFirstLine;
    if (!std.mem.eql(u8, scrollback.lineAt(999_999), "line-999999")) return error.BadLastLine;
    if (scrollback.bytesUsed() >= 64 * 1024 * 1024) return error.ScrollbackMemoryBudgetExceeded;

    std.debug.print("scrollback_lines={d}\nscrollback_bytes={d}\n", .{ scrollback.len(), scrollback.bytesUsed() });
}
