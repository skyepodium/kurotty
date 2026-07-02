const std = @import("std");
const parser = @import("parser.zig");

pub const ScreenViewport = struct {
    width: usize,
    height: usize,
};

pub const ScreenMutation = union(enum) {
    printable: PrintableMutation,
    csi: CsiMutation,
    osc: OscMutation,
    control: u8,
};

pub const PrintableMutation = struct {
    bytes: []const u8,
    row: usize,
    col: usize,
    cell_count: usize,
    raw_cell_count: usize,
};

pub const CsiMutation = struct {
    final: u8,
    private: bool,
    prefix: ?u8,
    params: []const u16,
};

pub const OscMutation = struct {
    bytes: []const u8,
};

pub const ScreenMutationRecorder = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    mutations: std.ArrayList(ScreenMutation) = .empty,

    pub fn init(allocator: std.mem.Allocator, viewport: ScreenViewport) ScreenMutationRecorder {
        return .{
            .allocator = allocator,
            .width = @max(viewport.width, 1),
            .height = @max(viewport.height, 1),
        };
    }

    pub fn deinit(self: *ScreenMutationRecorder) void {
        self.clear();
        self.mutations.deinit(self.allocator);
    }

    pub fn clear(self: *ScreenMutationRecorder) void {
        for (self.mutations.items) |mutation| {
            switch (mutation) {
                .printable => |printable| self.allocator.free(printable.bytes),
                .csi => |csi| self.allocator.free(csi.params),
                .osc => |osc| self.allocator.free(osc.bytes),
                .control => {},
            }
        }
        self.mutations.clearRetainingCapacity();
    }

    pub fn recordEvents(self: *ScreenMutationRecorder, events: []const parser.Event) !void {
        for (events) |event| try self.recordEvent(event);
    }

    pub fn recordEvent(self: *ScreenMutationRecorder, event: parser.Event) !void {
        switch (event) {
            .printable => |printable_event| try self.recordPrintable(printable_event.bytes),
            .csi => |csi_event| try self.recordCsi(csi_event),
            .osc => |osc_event| try self.recordOsc(osc_event.bytes),
            .control => |control| try self.recordControl(control),
        }
    }

    pub fn items(self: *const ScreenMutationRecorder) []const ScreenMutation {
        return self.mutations.items;
    }

    pub fn cursorRow(self: *const ScreenMutationRecorder) usize {
        return self.cursor_row;
    }

    pub fn cursorCol(self: *const ScreenMutationRecorder) usize {
        return self.cursor_col;
    }

    pub fn widthCells(self: *const ScreenMutationRecorder) usize {
        return self.width;
    }

    pub fn heightRows(self: *const ScreenMutationRecorder) usize {
        return self.height;
    }

    fn recordPrintable(self: *ScreenMutationRecorder, bytes: []const u8) !void {
        const start_row = self.cursor_row;
        const start_col = self.cursor_col;
        const available = self.width - @min(self.cursor_col, self.width);
        const raw_cell_count = displayCells(bytes);
        const fit = fittingPrefix(bytes, available);
        const owned = try self.allocator.dupe(u8, bytes[0..fit.byte_len]);
        errdefer self.allocator.free(owned);

        try self.mutations.append(self.allocator, .{ .printable = .{
            .bytes = owned,
            .row = start_row,
            .col = start_col,
            .cell_count = fit.cells,
            .raw_cell_count = raw_cell_count,
        } });
        self.cursor_col = @min(self.cursor_col + fit.cells, self.width);
    }

    fn recordCsi(self: *ScreenMutationRecorder, csi_event: parser.CsiEvent) !void {
        const params = try self.allocator.dupe(u16, csi_event.params);
        errdefer self.allocator.free(params);

        try self.mutations.append(self.allocator, .{ .csi = .{
            .final = csi_event.final,
            .private = csi_event.private,
            .prefix = csi_event.prefix,
            .params = params,
        } });
    }

    fn recordOsc(self: *ScreenMutationRecorder, bytes: []const u8) !void {
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        try self.mutations.append(self.allocator, .{ .osc = .{ .bytes = owned } });
    }

    fn recordControl(self: *ScreenMutationRecorder, control: u8) !void {
        try self.mutations.append(self.allocator, .{ .control = control });
        switch (control) {
            '\n' => self.newline(),
            '\r' => self.cursor_col = 0,
            '\t' => self.cursor_col = @min(((self.cursor_col / 8) + 1) * 8, self.width),
            0x08 => if (self.cursor_col > 0) {
                self.cursor_col -= 1;
            },
            else => {},
        }
    }

    fn newline(self: *ScreenMutationRecorder) void {
        self.cursor_col = 0;
        self.cursor_row = @min(self.cursor_row + 1, self.height - 1);
    }
};

fn displayCells(bytes: []const u8) usize {
    var cells: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const decoded = decodeUtf8(bytes[index..]);
        cells += codepointWidth(decoded.codepoint);
        index += decoded.len;
    }
    return cells;
}

const FittingPrefix = struct {
    byte_len: usize,
    cells: usize,
};

fn fittingPrefix(bytes: []const u8, max_cells: usize) FittingPrefix {
    var cells: usize = 0;
    var index: usize = 0;
    var byte_len: usize = 0;
    while (index < bytes.len) {
        const decoded = decodeUtf8(bytes[index..]);
        const width = codepointWidth(decoded.codepoint);
        if (width > 0 and cells + width > max_cells) {
            break;
        }
        cells += width;
        index += decoded.len;
        byte_len = index;
    }
    return .{ .byte_len = byte_len, .cells = cells };
}

const DecodedCodepoint = struct {
    codepoint: u21,
    len: usize,
};

fn decodeUtf8(bytes: []const u8) DecodedCodepoint {
    const first = bytes[0];
    if (first < 0x80) return .{ .codepoint = first, .len = 1 };
    if (first & 0xe0 == 0xc0 and bytes.len >= 2) {
        return .{
            .codepoint = (@as(u21, first & 0x1f) << 6) | @as(u21, bytes[1] & 0x3f),
            .len = 2,
        };
    }
    if (first & 0xf0 == 0xe0 and bytes.len >= 3) {
        return .{
            .codepoint = (@as(u21, first & 0x0f) << 12) | (@as(u21, bytes[1] & 0x3f) << 6) | @as(u21, bytes[2] & 0x3f),
            .len = 3,
        };
    }
    if (first & 0xf8 == 0xf0 and bytes.len >= 4) {
        return .{
            .codepoint = (@as(u21, first & 0x07) << 18) | (@as(u21, bytes[1] & 0x3f) << 12) | (@as(u21, bytes[2] & 0x3f) << 6) | @as(u21, bytes[3] & 0x3f),
            .len = 4,
        };
    }
    return .{ .codepoint = first, .len = 1 };
}

fn codepointWidth(codepoint: u21) usize {
    if (codepoint == 0) return 0;
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0)) return 0;
    if ((codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f))
    {
        return 0;
    }
    if ((codepoint >= 0x1100 and codepoint <= 0x115f) or
        (codepoint >= 0x2329 and codepoint <= 0x232a) or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f300 and codepoint <= 0x1faff))
    {
        return 2;
    }
    return 1;
}
