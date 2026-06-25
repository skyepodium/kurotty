const std = @import("std");

pub const CursorMove = struct {
    row_delta: isize = 0,
    col_delta: isize = 0,
};

pub const EraseMode = enum {
    below,
    above,
    all,
};

pub const Grid = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    cells: []u8,
    scratch: []u8,
    cursor_row: usize = 0,
    cursor_col: usize = 0,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Grid {
        const cells = try allocator.alloc(u8, width * height);
        errdefer allocator.free(cells);
        const scratch = try allocator.alloc(u8, width);
        @memset(cells, ' ');
        @memset(scratch, ' ');
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .cells = cells,
            .scratch = scratch,
        };
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.scratch);
    }

    pub fn write(self: *Grid, bytes: []const u8) !void {
        _ = try self.writeBounded(bytes);
    }

    pub fn writeBounded(self: *Grid, bytes: []const u8) !usize {
        var written: usize = 0;
        for (bytes) |byte| {
            if (byte == '\n') {
                self.newline();
                continue;
            }
            if (self.cursor_row >= self.height) self.scrollOne();
            if (self.cursor_col >= self.width) self.newline();
            self.cells[self.index(self.cursor_row, self.cursor_col)] = byte;
            self.cursor_col += 1;
            written += 1;
        }
        return written;
    }

    pub fn moveCursor(self: *Grid, movement: CursorMove) void {
        self.cursor_row = clampAdd(self.cursor_row, movement.row_delta, 0, self.height - 1);
        self.cursor_col = clampAdd(self.cursor_col, movement.col_delta, 0, self.width);
    }

    pub fn eraseDisplay(self: *Grid, mode: EraseMode) void {
        switch (mode) {
            .all => @memset(self.cells, ' '),
            .below => {
                if (self.cursor_col < self.width) {
                    @memset(self.cells[self.index(self.cursor_row, self.cursor_col)..self.index(self.cursor_row, self.width)], ' ');
                }
                var row = self.cursor_row + 1;
                while (row < self.height) : (row += 1) {
                    @memset(self.cells[self.index(row, 0)..self.index(row, self.width)], ' ');
                }
            },
            .above => {
                var row: usize = 0;
                while (row < self.cursor_row) : (row += 1) {
                    @memset(self.cells[self.index(row, 0)..self.index(row, self.width)], ' ');
                }
                @memset(self.cells[self.index(self.cursor_row, 0)..self.index(self.cursor_row, self.cursor_col + 1)], ' ');
            },
        }
    }

    pub fn rowText(self: *Grid, row: usize) []const u8 {
        @memcpy(self.scratch, self.cells[self.index(row, 0)..self.index(row, self.width)]);
        return self.scratch;
    }

    pub fn cursorRow(self: *const Grid) usize {
        return self.cursor_row;
    }

    pub fn cursorCol(self: *const Grid) usize {
        return self.cursor_col;
    }

    fn newline(self: *Grid) void {
        self.cursor_col = 0;
        self.cursor_row += 1;
        if (self.cursor_row >= self.height) self.scrollOne();
    }

    fn scrollOne(self: *Grid) void {
        if (self.height <= 1) {
            @memset(self.cells, ' ');
            self.cursor_row = 0;
            self.cursor_col = 0;
            return;
        }
        std.mem.copyForwards(u8, self.cells[0 .. self.width * (self.height - 1)], self.cells[self.width..]);
        @memset(self.cells[self.width * (self.height - 1) ..], ' ');
        self.cursor_row = self.height - 1;
    }

    fn index(self: *const Grid, row: usize, col: usize) usize {
        return row * self.width + col;
    }
};

fn clampAdd(value: usize, delta: isize, min: usize, max: usize) usize {
    const signed = @as(isize, @intCast(value)) + delta;
    if (signed < @as(isize, @intCast(min))) return min;
    if (signed > @as(isize, @intCast(max))) return max;
    return @as(usize, @intCast(signed));
}
