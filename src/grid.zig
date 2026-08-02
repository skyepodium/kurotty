const std = @import("std");
const cell_mod = @import("cell.zig");

pub const Cell = cell_mod.Cell;
pub const Style = cell_mod.Style;
pub const Attributes = cell_mod.Attributes;
pub const Color = cell_mod.Color;
pub const CellWidth = cell_mod.CellWidth;
pub const AbiCell = cell_mod.AbiCell;

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

const blank_cell = Cell{};

pub const Grid = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    cells: []Cell,
    alternate_screen: ?AlternateScreenSnapshot = null,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    current_style: Style = .{},
    utf8_pending: [4]u8 = undefined,
    utf8_pending_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Grid {
        if (width == 0 or height == 0) return error.InvalidDimensions;
        const cells = try allocator.alloc(Cell, width * height);
        @memset(cells, blank_cell);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .cells = cells,
        };
    }

    pub fn deinit(self: *Grid) void {
        if (self.alternate_screen) |snapshot| self.allocator.free(snapshot.cells);
        self.allocator.free(self.cells);
    }

    pub fn resize(self: *Grid, width: usize, height: usize) !void {
        const new_width = @max(width, 1);
        const new_height = @max(height, 1);
        const next = try self.allocator.alloc(Cell, new_width * new_height);
        @memset(next, blank_cell);
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
    }

    pub fn write(self: *Grid, bytes: []const u8) !void {
        _ = try self.writeBounded(bytes);
    }

    /// Decodes UTF-8 input into styled cells. Wide codepoints occupy a head
    /// cell plus one continuation cell; combining marks attach to the cell
    /// behind the cursor without advancing it. An incomplete trailing UTF-8
    /// sequence is buffered until the next call. Returns bytes consumed.
    pub fn writeBounded(self: *Grid, bytes: []const u8) !usize {
        var consumed: usize = 0;
        while (consumed < bytes.len) {
            if (bytes[consumed] == '\n') {
                self.newline();
                consumed += 1;
                continue;
            }
            const step = self.consumeUtf8(bytes[consumed..]);
            if (step.codepoint) |codepoint| self.putCodepoint(codepoint);
            consumed += step.len;
        }
        return consumed;
    }

    pub fn putCodepoint(self: *Grid, codepoint: u21) void {
        const glyph_width = cell_mod.codepointWidth(codepoint);
        if (glyph_width == 0) {
            self.attachCombining(codepoint);
            return;
        }
        if (self.cursor_row >= self.height) self.scrollOne();
        if (self.cursor_col >= self.width) self.newline();
        if (glyph_width == 2) {
            if (self.width < 2) return;
            if (self.cursor_col + 2 > self.width) self.newline();
        }
        const col = self.cursor_col;
        self.clearWideNeighbors(self.cursor_row, col);
        self.cells[self.index(self.cursor_row, col)] = .{
            .codepoint = codepoint,
            .width = if (glyph_width == 2) .wide else .single,
            .style = self.current_style,
        };
        if (glyph_width == 2) {
            self.clearWideNeighbors(self.cursor_row, col + 1);
            self.cells[self.index(self.cursor_row, col + 1)] = .{
                .codepoint = 0,
                .width = .continuation,
                .style = self.current_style,
            };
        }
        self.cursor_col = col + glyph_width;
    }

    /// Moves the cursor to the next tab stop (multiples of 8) without
    /// touching cell contents. Clamps at the last column.
    pub fn tab(self: *Grid) void {
        self.cursor_col = @min(((self.cursor_col / 8) + 1) * 8, self.width - 1);
    }

    pub fn moveCursor(self: *Grid, movement: CursorMove) void {
        self.cursor_row = clampAdd(self.cursor_row, movement.row_delta, 0, self.height - 1);
        self.cursor_col = clampAdd(self.cursor_col, movement.col_delta, 0, self.width - 1);
    }

    pub fn setCursor(self: *Grid, row: usize, col: usize) void {
        self.cursor_row = @min(row, self.height - 1);
        self.cursor_col = @min(col, self.width - 1);
    }

    pub fn setStyle(self: *Grid, next_style: Style) void {
        self.current_style = next_style;
    }

    pub fn style(self: *const Grid) Style {
        return self.current_style;
    }

    pub fn eraseDisplay(self: *Grid, mode: EraseMode) void {
        switch (mode) {
            .all => @memset(self.cells, blank_cell),
            .below => {
                const col = @min(self.cursor_col, self.width);
                @memset(self.cells[self.index(self.cursor_row, col)..self.index(self.cursor_row, self.width)], blank_cell);
                var row = self.cursor_row + 1;
                while (row < self.height) : (row += 1) {
                    @memset(self.cells[self.index(row, 0)..self.index(row, self.width)], blank_cell);
                }
            },
            .above => {
                var row: usize = 0;
                while (row < self.cursor_row) : (row += 1) {
                    @memset(self.cells[self.index(row, 0)..self.index(row, self.width)], blank_cell);
                }
                @memset(self.cells[self.index(self.cursor_row, 0)..self.index(self.cursor_row, @min(self.cursor_col + 1, self.width))], blank_cell);
            },
        }
    }

    pub fn eraseLine(self: *Grid, mode: EraseLineMode) void {
        switch (mode) {
            .right => {
                const col = @min(self.cursor_col, self.width);
                @memset(self.cells[self.index(self.cursor_row, col)..self.index(self.cursor_row, self.width)], blank_cell);
            },
            .left => {
                @memset(self.cells[self.index(self.cursor_row, 0)..self.index(self.cursor_row, @min(self.cursor_col + 1, self.width))], blank_cell);
            },
            .all => {
                @memset(self.cells[self.index(self.cursor_row, 0)..self.index(self.cursor_row, self.width)], blank_cell);
            },
        }
    }

    pub fn insertCharacters(self: *Grid, count: usize) void {
        const col = @min(self.cursor_col, self.width - 1);
        const amount = @min(@max(count, 1), self.width - col);
        const row = self.cells[self.index(self.cursor_row, 0)..self.index(self.cursor_row, self.width)];
        std.mem.copyBackwards(Cell, row[col + amount ..], row[col .. self.width - amount]);
        @memset(row[col .. col + amount], blank_cell);
    }

    pub fn deleteCharacters(self: *Grid, count: usize) void {
        const col = @min(self.cursor_col, self.width - 1);
        const amount = @min(@max(count, 1), self.width - col);
        const row = self.cells[self.index(self.cursor_row, 0)..self.index(self.cursor_row, self.width)];
        std.mem.copyForwards(Cell, row[col .. self.width - amount], row[col + amount ..]);
        @memset(row[self.width - amount ..], blank_cell);
    }

    pub fn insertLines(self: *Grid, count: usize) void {
        const amount = @min(@max(count, 1), self.height - self.cursor_row);
        const start = self.index(self.cursor_row, 0);
        const end = self.width * self.height;
        std.mem.copyBackwards(Cell, self.cells[start + amount * self.width .. end], self.cells[start .. end - amount * self.width]);
        @memset(self.cells[start .. start + amount * self.width], blank_cell);
    }

    pub fn deleteLines(self: *Grid, count: usize) void {
        const amount = @min(@max(count, 1), self.height - self.cursor_row);
        const start = self.index(self.cursor_row, 0);
        const end = self.width * self.height;
        std.mem.copyForwards(Cell, self.cells[start .. end - amount * self.width], self.cells[start + amount * self.width .. end]);
        @memset(self.cells[end - amount * self.width ..], blank_cell);
    }

    pub fn enterAlternateScreen(self: *Grid) !void {
        if (self.alternate_screen != null) return;
        const saved = try self.allocator.dupe(Cell, self.cells);
        self.alternate_screen = .{
            .width = self.width,
            .height = self.height,
            .cells = saved,
            .cursor_row = self.cursor_row,
            .cursor_col = self.cursor_col,
        };
        @memset(self.cells, blank_cell);
        self.cursor_row = 0;
        self.cursor_col = 0;
    }

    pub fn leaveAlternateScreen(self: *Grid) void {
        const saved = self.alternate_screen orelse return;
        @memset(self.cells, blank_cell);
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
        self.cursor_row = @min(saved.cursor_row, self.height - 1);
        self.cursor_col = @min(saved.cursor_col, self.width - 1);
    }

    /// Encodes the row's codepoints as UTF-8 into the caller-provided buffer.
    /// Continuation cells are skipped so a wide glyph appears once. The
    /// buffer should hold up to 4 bytes per column.
    pub fn rowText(self: *const Grid, row: usize, buffer: []u8) []const u8 {
        if (row >= self.height) return buffer[0..0];
        var used: usize = 0;
        var col: usize = 0;
        while (col < self.width) : (col += 1) {
            const cell = self.cells[self.index(row, col)];
            if (cell.width == .continuation) continue;
            used += encodeCodepoint(cell.codepoint, buffer[used..]);
            if (cell.combining != 0) used += encodeCodepoint(cell.combining, buffer[used..]);
        }
        return buffer[0..used];
    }

    /// Legacy byte view: ASCII codepoints copy through, anything else
    /// (wide heads, continuations, non-ASCII) degrades to a space.
    pub fn copyRow(self: *const Grid, row: usize, destination: []u8) usize {
        if (row >= self.height or destination.len == 0) return 0;
        const copied = @min(self.width, destination.len);
        var col: usize = 0;
        while (col < copied) : (col += 1) {
            const cell = self.cells[self.index(row, col)];
            destination[col] = if (cell.width == .single and cell.codepoint < 0x80)
                @intCast(cell.codepoint)
            else
                ' ';
        }
        return copied;
    }

    /// Styled cell view for the ABI: fills caller-owned AbiCell records.
    pub fn copyRowCells(self: *const Grid, row: usize, destination: []AbiCell) usize {
        if (row >= self.height or destination.len == 0) return 0;
        const copied = @min(self.width, destination.len);
        var col: usize = 0;
        while (col < copied) : (col += 1) {
            const cell = self.cells[self.index(row, col)];
            destination[col] = .{
                .codepoint = cell.codepoint,
                .fg = cell.style.fg,
                .bg = cell.style.bg,
                .attrs = @bitCast(cell.style.attrs),
                .width = @intFromEnum(cell.width),
            };
        }
        return copied;
    }

    pub fn cellAt(self: *const Grid, row: usize, col: usize) u8 {
        if (row >= self.height or col >= self.width) return ' ';
        const cell = self.cells[self.index(row, col)];
        if (cell.width == .single and cell.codepoint < 0x80) return @intCast(cell.codepoint);
        return ' ';
    }

    pub fn cellInfoAt(self: *const Grid, row: usize, col: usize) Cell {
        if (row >= self.height or col >= self.width) return blank_cell;
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

    const Utf8Step = struct {
        codepoint: ?u21,
        len: usize,
    };

    fn consumeUtf8(self: *Grid, bytes: []const u8) Utf8Step {
        if (self.utf8_pending_len > 0) {
            const needed = cell_mod.utf8SequenceLength(self.utf8_pending[0]);
            const take = @min(needed - self.utf8_pending_len, bytes.len);
            @memcpy(self.utf8_pending[self.utf8_pending_len .. self.utf8_pending_len + take], bytes[0..take]);
            self.utf8_pending_len += take;
            if (self.utf8_pending_len < needed) return .{ .codepoint = null, .len = take };
            const decoded = cell_mod.decodeUtf8(self.utf8_pending[0..self.utf8_pending_len]);
            self.utf8_pending_len = 0;
            return .{ .codepoint = decoded.codepoint, .len = take };
        }
        const decoded = cell_mod.decodeUtf8(bytes);
        if (decoded.incomplete) {
            @memcpy(self.utf8_pending[0..bytes.len], bytes);
            self.utf8_pending_len = bytes.len;
            return .{ .codepoint = null, .len = bytes.len };
        }
        return .{ .codepoint = decoded.codepoint, .len = decoded.len };
    }

    fn attachCombining(self: *Grid, codepoint: u21) void {
        var row = self.cursor_row;
        var col = self.cursor_col;
        if (col == 0) {
            if (row == 0) return;
            row -= 1;
            col = self.width;
        }
        col -= 1;
        if (self.cells[self.index(row, col)].width == .continuation) {
            if (col == 0) return;
            col -= 1;
        }
        const target = &self.cells[self.index(row, col)];
        if (target.combining == 0) target.combining = codepoint;
    }

    fn clearWideNeighbors(self: *Grid, row: usize, col: usize) void {
        const cell = self.cells[self.index(row, col)];
        if (cell.width == .continuation and col > 0) {
            self.cells[self.index(row, col - 1)] = blank_cell;
        }
        if (cell.width == .wide and col + 1 < self.width) {
            self.cells[self.index(row, col + 1)] = blank_cell;
        }
    }

    fn newline(self: *Grid) void {
        self.cursor_col = 0;
        self.cursor_row += 1;
        if (self.cursor_row >= self.height) self.scrollOne();
    }

    fn scrollOne(self: *Grid) void {
        if (self.height <= 1) {
            @memset(self.cells, blank_cell);
            self.cursor_row = 0;
            self.cursor_col = 0;
            return;
        }
        std.mem.copyForwards(Cell, self.cells[0 .. self.width * (self.height - 1)], self.cells[self.width..]);
        @memset(self.cells[self.width * (self.height - 1) ..], blank_cell);
        self.cursor_row = self.height - 1;
    }

    fn index(self: *const Grid, row: usize, col: usize) usize {
        return row * self.width + col;
    }
};

const AlternateScreenSnapshot = struct {
    width: usize,
    height: usize,
    cells: []Cell,
    cursor_row: usize,
    cursor_col: usize,
};

fn encodeCodepoint(codepoint: u21, buffer: []u8) usize {
    return std.unicode.utf8Encode(codepoint, buffer) catch blk: {
        if (buffer.len == 0) break :blk 0;
        buffer[0] = '?';
        break :blk 1;
    };
}

fn clampAdd(value: usize, delta: isize, min: usize, max: usize) usize {
    const signed = @as(isize, @intCast(value)) + delta;
    if (signed < @as(isize, @intCast(min))) return min;
    if (signed > @as(isize, @intCast(max))) return max;
    return @as(usize, @intCast(signed));
}
