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
    defer {
        ptr.parser.freeEvents(events);
        ptr.allocator.free(events);
    }

    var printable_bytes: usize = 0;
    for (events) |event| {
        switch (event) {
            .printable => |printable| {
                printable_bytes += ptr.grid.writeBounded(printable.bytes) catch 0;
            },
            .control => |control| switch (control) {
                '\n' => ptr.grid.write("\n") catch {},
                '\r' => ptr.grid.setCursor(ptr.grid.cursorRow(), 0),
                0x08 => ptr.grid.moveCursor(.{ .col_delta = -1 }),
                '\t' => ptr.grid.write("    ") catch {},
                else => {},
            },
            .csi => |csi| {
                applyCsi(ptr, csi);
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

export fn kurotty_terminal_resize(terminal: ?*Terminal, width: u32, height: u32) void {
    const ptr = terminal orelse return;
    ptr.grid.resize(width, height) catch {};
    ptr.renderer.markDamage(.{ .row = 0, .col = 0, .rows = height, .cols = width }) catch {};
}

export fn kurotty_terminal_cell_at(terminal: ?*Terminal, row: u32, col: u32) u8 {
    const ptr = terminal orelse return ' ';
    return ptr.grid.cellAt(row, col);
}

fn applyCsi(ptr: *Terminal, csi: core.CsiEvent) void {
    const first = param(csi, 0, 1);
    switch (csi.final) {
        'A' => ptr.grid.moveCursor(.{ .row_delta = -@as(isize, @intCast(first)) }),
        'B' => ptr.grid.moveCursor(.{ .row_delta = @intCast(first) }),
        'C' => ptr.grid.moveCursor(.{ .col_delta = @intCast(first) }),
        'D' => ptr.grid.moveCursor(.{ .col_delta = -@as(isize, @intCast(first)) }),
        'G' => ptr.grid.setCursor(ptr.grid.cursorRow(), if (first == 0) 0 else first - 1),
        'H', 'f' => {
            const row = param(csi, 0, 1);
            const col = param(csi, 1, 1);
            ptr.grid.setCursor(if (row == 0) 0 else row - 1, if (col == 0) 0 else col - 1);
        },
        'J' => ptr.grid.eraseDisplay(switch (param(csi, 0, 0)) {
            1 => .above,
            2, 3 => .all,
            else => .below,
        }),
        'K' => ptr.grid.eraseLine(switch (param(csi, 0, 0)) {
            1 => .left,
            2 => .all,
            else => .right,
        }),
        'P' => ptr.grid.deleteCharacters(first),
        '@' => ptr.grid.insertCharacters(first),
        'L' => ptr.grid.insertLines(first),
        'M' => ptr.grid.deleteLines(first),
        'h' => if (csi.private) {
            for (csi.params) |value| if (value == 47 or value == 1047 or value == 1049) ptr.grid.enterAlternateScreen() catch {};
        },
        'l' => if (csi.private) {
            for (csi.params) |value| if (value == 47 or value == 1047 or value == 1049) ptr.grid.leaveAlternateScreen();
        },
        else => {},
    }
}

fn param(csi: core.CsiEvent, index: usize, default: usize) usize {
    if (index >= csi.params.len or csi.params[index] == 0) return default;
    return csi.params[index];
}
