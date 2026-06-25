const std = @import("std");
const core = @import("kurotty_core");

const Terminal = struct {
    allocator: std.mem.Allocator,
    parser: core.Parser,
    grid: core.Grid,
    metrics: core.Metrics,
    renderer: core.RendererOrchestrator,

    fn create(allocator: std.mem.Allocator, width: usize, height: usize) !*Terminal {
        const terminal = try allocator.create(Terminal);
        errdefer allocator.destroy(terminal);

        terminal.* = .{
            .allocator = allocator,
            .parser = core.Parser.init(allocator),
            .grid = try core.Grid.init(allocator, width, height),
            .metrics = core.Metrics.init(),
            .renderer = core.RendererOrchestrator.init(allocator),
        };
        return terminal;
    }

    fn destroy(self: *Terminal) void {
        self.renderer.deinit();
        self.parser.deinit();
        self.grid.deinit();
        self.allocator.destroy(self);
    }
};

var gpa = std.heap.DebugAllocator(.{}){};

export fn kurotty_terminal_create(width: u32, height: u32) ?*Terminal {
    return Terminal.create(gpa.allocator(), width, height) catch null;
}

export fn kurotty_terminal_destroy(terminal: ?*Terminal) void {
    if (terminal) |ptr| ptr.destroy();
}

export fn kurotty_terminal_feed(terminal: ?*Terminal, bytes: [*]const u8, len: usize) usize {
    const ptr = terminal orelse return 0;
    const input = bytes[0..len];
    const events = ptr.parser.feed(input) catch return 0;
    defer ptr.allocator.free(events);

    var printable_bytes: usize = 0;
    for (events) |event| {
        switch (event) {
            .printable => |printable| {
                printable_bytes += ptr.grid.writeBounded(printable.bytes) catch 0;
            },
            .csi => |csi| {
                if (csi.final == 'J') ptr.grid.eraseDisplay(.below);
            },
        }
    }
    return printable_bytes;
}

export fn kurotty_terminal_record_key(terminal: ?*Terminal, timestamp_micros: u64) void {
    const ptr = terminal orelse return;
    ptr.metrics.recordKeyEvent(timestamp_micros);
}

export fn kurotty_terminal_record_present(terminal: ?*Terminal, timestamp_micros: u64) void {
    const ptr = terminal orelse return;
    ptr.metrics.recordFramePresented(timestamp_micros);
}

export fn kurotty_terminal_last_latency(terminal: ?*Terminal) u64 {
    const ptr = terminal orelse return 0;
    return ptr.metrics.lastInputToPresentMicros();
}

export fn kurotty_terminal_cursor_row(terminal: ?*Terminal) u32 {
    const ptr = terminal orelse return 0;
    return @intCast(ptr.grid.cursorRow());
}

export fn kurotty_terminal_cursor_col(terminal: ?*Terminal) u32 {
    const ptr = terminal orelse return 0;
    return @intCast(ptr.grid.cursorCol());
}

export fn kurotty_terminal_mark_damage(terminal: ?*Terminal, row: u32, col: u32, rows: u32, cols: u32) void {
    const ptr = terminal orelse return;
    ptr.renderer.markDamage(.{ .row = row, .col = col, .rows = rows, .cols = cols }) catch {};
}

export fn kurotty_terminal_begin_frame(terminal: ?*Terminal, visible_cells: u32) u32 {
    const ptr = terminal orelse return 0;
    const stats = ptr.renderer.beginFrame(visible_cells);
    return stats.draw_calls;
}

export fn kurotty_terminal_end_frame(terminal: ?*Terminal) void {
    const ptr = terminal orelse return;
    ptr.renderer.endFrame();
}
