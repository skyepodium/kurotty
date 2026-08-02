const std = @import("std");
const core = @import("kurotty_core");

const TerminalGpa = std.heap.DebugAllocator(.{ .thread_safe = true });

const Terminal = struct {
    gpa: *TerminalGpa,
    allocator: std.mem.Allocator,
    parser: core.Parser,
    grid: core.Grid,
    metrics: core.Metrics,
    renderer: core.RendererOrchestrator,
    last_error: AbiError = .none,

    fn create(width: usize, height: usize) !*Terminal {
        const gpa = try std.heap.page_allocator.create(TerminalGpa);
        errdefer std.heap.page_allocator.destroy(gpa);
        gpa.* = .init;
        const allocator = gpa.allocator();

        const terminal = try allocator.create(Terminal);
        errdefer allocator.destroy(terminal);

        terminal.* = .{
            .gpa = gpa,
            .allocator = allocator,
            .parser = core.Parser.init(allocator),
            .grid = try core.Grid.init(allocator, width, height),
            .metrics = core.Metrics.init(),
            .renderer = core.RendererOrchestrator.init(allocator),
        };
        terminal.renderer.setGridBounds(@intCast(height), @intCast(width));
        return terminal;
    }

    fn destroy(self: *Terminal) void {
        const gpa = self.gpa;
        self.renderer.deinit();
        self.parser.deinit();
        self.grid.deinit();
        self.allocator.destroy(self);
        _ = gpa.deinit();
        std.heap.page_allocator.destroy(gpa);
    }
};

const AbiError = enum(u32) {
    none = 0,
    parser = 1,
    grid = 2,
    renderer = 3,
};

export fn kurotty_terminal_create(width: u32, height: u32) ?*Terminal {
    return Terminal.create(width, height) catch null;
}

export fn kurotty_terminal_destroy(terminal: ?*Terminal) void {
    if (terminal) |ptr| ptr.destroy();
}

export fn kurotty_terminal_feed(terminal: ?*Terminal, bytes: [*]const u8, len: usize) usize {
    const ptr = terminal orelse return 0;
    ptr.last_error = .none;
    const input = bytes[0..len];
    const events = ptr.parser.feed(input) catch {
        ptr.last_error = .parser;
        return 0;
    };
    defer ptr.parser.freeEvents(events);

    var printable_bytes: usize = 0;
    for (events) |event| {
        switch (event) {
            .printable => |printable| {
                printable_bytes += ptr.grid.writeBounded(printable.bytes) catch {
                    ptr.last_error = .grid;
                    return printable_bytes;
                };
            },
            .control => |control| switch (control) {
                '\n' => ptr.grid.write("\n") catch {
                    ptr.last_error = .grid;
                    return printable_bytes;
                },
                '\r' => ptr.grid.setCursor(ptr.grid.cursorRow(), 0),
                0x08 => ptr.grid.moveCursor(.{ .col_delta = -1 }),
                '\t' => ptr.grid.tab(),
                else => {},
            },
            .csi => |csi| {
                applyCsi(ptr, csi);
            },
            .osc => {},
        }
    }
    return printable_bytes;
}

export fn kurotty_terminal_last_error(terminal: ?*Terminal) u32 {
    const ptr = terminal orelse return @intFromEnum(AbiError.none);
    return @intFromEnum(ptr.last_error);
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

export fn kurotty_terminal_width(terminal: ?*Terminal) u32 {
    const ptr = terminal orelse return 0;
    return @intCast(ptr.grid.widthCells());
}

export fn kurotty_terminal_height(terminal: ?*Terminal) u32 {
    const ptr = terminal orelse return 0;
    return @intCast(ptr.grid.heightRows());
}

export fn kurotty_terminal_mark_damage(terminal: ?*Terminal, row: u32, col: u32, rows: u32, cols: u32) void {
    const ptr = terminal orelse return;
    ptr.last_error = .none;
    ptr.renderer.markDamage(.{ .row = row, .col = col, .rows = rows, .cols = cols }) catch {
        ptr.last_error = .renderer;
    };
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
    ptr.last_error = .none;
    ptr.grid.resize(width, height) catch {
        ptr.last_error = .grid;
        return;
    };
    ptr.renderer.setGridBounds(@intCast(ptr.grid.heightRows()), @intCast(ptr.grid.widthCells()));
    ptr.renderer.markDamage(.{ .row = 0, .col = 0, .rows = height, .cols = width }) catch {
        ptr.last_error = .renderer;
    };
}

export fn kurotty_terminal_cell_at(terminal: ?*Terminal, row: u32, col: u32) u8 {
    const ptr = terminal orelse return ' ';
    return ptr.grid.cellAt(row, col);
}

export fn kurotty_terminal_copy_row(terminal: ?*Terminal, row: u32, buffer: ?[*]u8, buffer_len: usize) usize {
    const ptr = terminal orelse return 0;
    const output = buffer orelse return 0;
    return ptr.grid.copyRow(row, output[0..buffer_len]);
}

export fn kurotty_terminal_copy_row_cells(terminal: ?*Terminal, row: u32, buffer: ?[*]core.AbiCell, max_cells: usize) usize {
    const ptr = terminal orelse return 0;
    const output = buffer orelse return 0;
    return ptr.grid.copyRowCells(row, output[0..max_cells]);
}

fn applyCsi(ptr: *Terminal, csi: core.CsiEvent) void {
    switch (csi.final) {
        'A' => ptr.grid.moveCursor(.{ .row_delta = -@as(isize, @intCast(cursorParam(csi, 0))) }),
        'B' => ptr.grid.moveCursor(.{ .row_delta = @intCast(cursorParam(csi, 0)) }),
        'C' => ptr.grid.moveCursor(.{ .col_delta = @intCast(cursorParam(csi, 0)) }),
        'D' => ptr.grid.moveCursor(.{ .col_delta = -@as(isize, @intCast(cursorParam(csi, 0))) }),
        'G' => ptr.grid.setCursor(ptr.grid.cursorRow(), cursorParam(csi, 0) - 1),
        'H', 'f' => ptr.grid.setCursor(cursorParam(csi, 0) - 1, cursorParam(csi, 1) - 1),
        'J' => ptr.grid.eraseDisplay(switch (selectParam(csi, 0)) {
            1 => .above,
            2, 3 => .all,
            else => .below,
        }),
        'K' => ptr.grid.eraseLine(switch (selectParam(csi, 0)) {
            1 => .left,
            2 => .all,
            else => .right,
        }),
        'P' => ptr.grid.deleteCharacters(cursorParam(csi, 0)),
        '@' => ptr.grid.insertCharacters(cursorParam(csi, 0)),
        'L' => ptr.grid.insertLines(cursorParam(csi, 0)),
        'M' => ptr.grid.deleteLines(cursorParam(csi, 0)),
        // SGR is only the non-private CSI m family; private variants such as
        // CSI > 4;2 m (Kitty keyboard mode) must not mutate text style.
        'm' => if (!csi.private) applySgr(ptr, csi.params),
        'h' => if (csi.private) {
            for (csi.params) |value| if (value == 47 or value == 1047 or value == 1049) ptr.grid.enterAlternateScreen() catch {
                ptr.last_error = .grid;
                return;
            };
        },
        'l' => if (csi.private) {
            for (csi.params) |value| if (value == 47 or value == 1047 or value == 1049) ptr.grid.leaveAlternateScreen();
        },
        else => {},
    }
}

fn applySgr(ptr: *Terminal, params: []const u16) void {
    var style = ptr.grid.style();
    var index: usize = 0;
    while (index < params.len) : (index += 1) {
        switch (params[index]) {
            0 => style = .{},
            1 => style.attrs.bold = true,
            2 => style.attrs.dim = true,
            3 => style.attrs.italic = true,
            4 => style.attrs.underline = true,
            7 => style.attrs.inverse = true,
            9 => style.attrs.strikethrough = true,
            22 => {
                style.attrs.bold = false;
                style.attrs.dim = false;
            },
            23 => style.attrs.italic = false,
            24 => style.attrs.underline = false,
            27 => style.attrs.inverse = false,
            29 => style.attrs.strikethrough = false,
            30...37 => style.fg = core.Color.indexed(@intCast(params[index] - 30)),
            39 => style.fg = core.Color.default,
            40...47 => style.bg = core.Color.indexed(@intCast(params[index] - 40)),
            49 => style.bg = core.Color.default,
            90...97 => style.fg = core.Color.indexed(@intCast(params[index] - 90 + 8)),
            100...107 => style.bg = core.Color.indexed(@intCast(params[index] - 100 + 8)),
            38 => {
                const parsed = parseExtendedColor(params[index + 1 ..]) orelse break;
                style.fg = parsed.color;
                index += parsed.consumed;
            },
            48 => {
                const parsed = parseExtendedColor(params[index + 1 ..]) orelse break;
                style.bg = parsed.color;
                index += parsed.consumed;
            },
            else => {},
        }
    }
    ptr.grid.setStyle(style);
}

const ExtendedColor = struct {
    color: u32,
    consumed: usize,
};

fn parseExtendedColor(params: []const u16) ?ExtendedColor {
    if (params.len == 0) return null;
    switch (params[0]) {
        5 => {
            if (params.len < 2 or params[1] > 255) return null;
            return .{ .color = core.Color.indexed(@intCast(params[1])), .consumed = 2 };
        },
        2 => {
            if (params.len < 4 or params[1] > 255 or params[2] > 255 or params[3] > 255) return null;
            return .{
                .color = core.Color.rgb(@intCast(params[1]), @intCast(params[2]), @intCast(params[3])),
                .consumed = 4,
            };
        },
        else => return null,
    }
}

/// Cursor-shaped parameters (CUU/CUD/CUF/CUB/CHA/CUP/ICH/DCH/IL/DL):
/// both an absent parameter and an explicit 0 mean 1 per ECMA-48.
fn cursorParam(csi: core.CsiEvent, index: usize) usize {
    const value = paramAt(csi, index) orelse return 1;
    return if (value == 0) 1 else value;
}

/// Selector-shaped parameters (ED/EL): absent means 0, and 0 is meaningful.
fn selectParam(csi: core.CsiEvent, index: usize) usize {
    return paramAt(csi, index) orelse 0;
}

fn paramAt(csi: core.CsiEvent, index: usize) ?usize {
    if (index >= csi.params.len) return null;
    return csi.params[index];
}

test "ABI copies row text into caller buffer and reports copied byte count" {
    const terminal = kurotty_terminal_create(5, 2) orelse return error.TerminalCreateFailed;
    defer kurotty_terminal_destroy(terminal);

    try std.testing.expectEqual(@as(usize, 5), kurotty_terminal_feed(terminal, "abcde".ptr, "abcde".len));
    try std.testing.expectEqual(@as(usize, 2), kurotty_terminal_feed(terminal, "xy".ptr, "xy".len));

    var full_buffer: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), kurotty_terminal_copy_row(terminal, 0, &full_buffer, full_buffer.len));
    try std.testing.expectEqualStrings("abcde", &full_buffer);

    var short_buffer: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), kurotty_terminal_copy_row(terminal, 1, &short_buffer, short_buffer.len));
    try std.testing.expectEqualStrings("xy ", &short_buffer);
}

test "ABI row copy returns zero for null handle invalid row or empty buffer" {
    var buffer: [4]u8 = .{ 1, 2, 3, 4 };

    try std.testing.expectEqual(@as(usize, 0), kurotty_terminal_copy_row(null, 0, &buffer, buffer.len));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &buffer);

    const terminal = kurotty_terminal_create(4, 2) orelse return error.TerminalCreateFailed;
    defer kurotty_terminal_destroy(terminal);

    try std.testing.expectEqual(@as(usize, 0), kurotty_terminal_copy_row(terminal, 2, &buffer, buffer.len));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &buffer);
    try std.testing.expectEqual(@as(usize, 0), kurotty_terminal_copy_row(terminal, 0, &buffer, 0));
}
