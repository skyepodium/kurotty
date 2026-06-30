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

pub const EraseLineMode = enum {
    right,
    left,
    all,
};

pub const Grid = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    cells: []u8,
    scratch: []u8,
    alternate_screen: ?AlternateScreenSnapshot = null,
    cursor_row: usize = 0,
    cursor_col: usize = 0,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Grid {
        if (width == 0 or height == 0) return error.InvalidDimensions;
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
        if (self.alternate_screen) |snapshot| self.allocator.free(snapshot.cells);
        self.allocator.free(self.cells);
        self.allocator.free(self.scratch);
    }

    pub fn resize(self: *Grid, width: usize, height: usize) !void {
        const new_width = @max(width, 1);
        const new_height = @max(height, 1);
        const next = try self.allocator.alloc(u8, new_width * new_height);
        errdefer self.allocator.free(next);
        @memset(next, ' ');
        const copy_height = @min(self.height, new_height);
        const copy_width = @min(self.width, new_width);
        var row: usize = 0;
        while (row < copy_height) : (row += 1) {
            @memcpy(next[row * new_width .. row * new_width + copy_width], self.cells[row * self.width .. row * self.width + copy_width]);
        }
        self.allocator.free(self.cells);
        self.cells = next;
        self.width = new_width;
        self.height = new_height;
        self.cursor_row = @min(self.cursor_row, self.height - 1);
        self.cursor_col = @min(self.cursor_col, self.width - 1);

        self.allocator.free(self.scratch);
        self.scratch = try self.allocator.alloc(u8, self.width);
        @memset(self.scratch, ' ');
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

    pub fn setCursor(self: *Grid, row: usize, col: usize) void {
        self.cursor_row = @min(row, self.height - 1);
        self.cursor_col = @min(col, self.width - 1);
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

    pub fn eraseLine(self: *Grid, mode: EraseLineMode) void {
        switch (mode) {
            .right => {
                if (self.cursor_col < self.width) {
                    @memset(self.cells[self.index(self.cursor_row, self.cursor_col)..self.index(self.cursor_row, self.width)], ' ');
                }
            },
            .left => {
                @memset(self.cells[self.index(self.cursor_row, 0)..self.index(self.cursor_row, @min(self.cursor_col + 1, self.width))], ' ');
            },
            .all => {
                @memset(self.cells[self.index(self.cursor_row, 0)..self.index(self.cursor_row, self.width)], ' ');
            },
        }
    }

    pub fn insertCharacters(self: *Grid, count: usize) void {
        if (self.cursor_col >= self.width) return;
        const amount = @min(@max(count, 1), self.width - self.cursor_col);
        const row = self.cells[self.index(self.cursor_row, 0)..self.index(self.cursor_row, self.width)];
        std.mem.copyBackwards(u8, row[self.cursor_col + amount ..], row[self.cursor_col .. self.width - amount]);
        @memset(row[self.cursor_col .. self.cursor_col + amount], ' ');
    }

    pub fn deleteCharacters(self: *Grid, count: usize) void {
        if (self.cursor_col >= self.width) return;
        const amount = @min(@max(count, 1), self.width - self.cursor_col);
        const row = self.cells[self.index(self.cursor_row, 0)..self.index(self.cursor_row, self.width)];
        std.mem.copyForwards(u8, row[self.cursor_col .. self.width - amount], row[self.cursor_col + amount ..]);
        @memset(row[self.width - amount ..], ' ');
    }

    pub fn insertLines(self: *Grid, count: usize) void {
        const amount = @min(@max(count, 1), self.height - self.cursor_row);
        const start = self.index(self.cursor_row, 0);
        const end = self.width * self.height;
        std.mem.copyBackwards(u8, self.cells[start + amount * self.width .. end], self.cells[start .. end - amount * self.width]);
        @memset(self.cells[start .. start + amount * self.width], ' ');
    }

    pub fn deleteLines(self: *Grid, count: usize) void {
        const amount = @min(@max(count, 1), self.height - self.cursor_row);
        const start = self.index(self.cursor_row, 0);
        const end = self.width * self.height;
        std.mem.copyForwards(u8, self.cells[start .. end - amount * self.width], self.cells[start + amount * self.width .. end]);
        @memset(self.cells[end - amount * self.width ..], ' ');
    }

    pub fn enterAlternateScreen(self: *Grid) !void {
        if (self.alternate_screen != null) return;
        const saved = try self.allocator.dupe(u8, self.cells);
        self.alternate_screen = .{
            .width = self.width,
            .height = self.height,
            .cells = saved,
        };
        @memset(self.cells, ' ');
        self.cursor_row = 0;
        self.cursor_col = 0;
    }

    pub fn leaveAlternateScreen(self: *Grid) void {
        const saved = self.alternate_screen orelse return;
        @memset(self.cells, ' ');
        const copy_height = @min(saved.height, self.height);
        const copy_width = @min(saved.width, self.width);
        var row: usize = 0;
        while (row < copy_height) : (row += 1) {
            const saved_start = row * saved.width;
            const target_start = row * self.width;
            @memcpy(self.cells[target_start .. target_start + copy_width], saved.cells[saved_start .. saved_start + copy_width]);
        }
        self.allocator.free(saved.cells);
        self.alternate_screen = null;
        self.cursor_row = 0;
        self.cursor_col = 0;
    }

    pub fn rowText(self: *Grid, row: usize) []const u8 {
        @memcpy(self.scratch, self.cells[self.index(row, 0)..self.index(row, self.width)]);
        return self.scratch;
    }

    pub fn cellAt(self: *const Grid, row: usize, col: usize) u8 {
        if (row >= self.height or col >= self.width) return ' ';
        return self.cells[self.index(row, col)];
    }

    pub fn cursorRow(self: *const Grid) usize {
        return self.cursor_row;
    }

    pub fn cursorCol(self: *const Grid) usize {
        return self.cursor_col;
    }

    pub fn widthCells(self: *const Grid) usize {
        return self.width;
    }

    pub fn heightRows(self: *const Grid) usize {
        return self.height;
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

const AlternateScreenSnapshot = struct {
    width: usize,
    height: usize,
    cells: []u8,
};

fn clampAdd(value: usize, delta: isize, min: usize, max: usize) usize {
    const signed = @as(isize, @intCast(value)) + delta;
    if (signed < @as(isize, @intCast(min))) return min;
    if (signed > @as(isize, @intCast(max))) return max;
    return @as(usize, @intCast(signed));
}
