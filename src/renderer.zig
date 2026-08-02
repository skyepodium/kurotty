const std = @import("std");

pub const DamageRect = struct {
    row: u32,
    col: u32,
    rows: u32,
    cols: u32,
};

pub const GlyphKey = struct {
    codepoint: u21,
    style_hash: u32,
};

pub const RenderStats = struct {
    visible_cells: u32 = 0,
    dirty_rects: u32 = 0,
    draw_calls: u32 = 0,
    glyph_cache_pressure: f32 = 0,
};

pub const RendererOrchestrator = struct {
    /// Beyond this many pending rects the list collapses into a single
    /// bounding rect so a hostile or chatty feed cannot grow it unbounded.
    pub const max_damage_rects: usize = 64;

    allocator: std.mem.Allocator,
    damage: std.ArrayList(DamageRect),
    stats: RenderStats = .{},
    grid_rows: u32 = 0,
    grid_cols: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) RendererOrchestrator {
        return .{
            .allocator = allocator,
            .damage = .empty,
        };
    }

    pub fn deinit(self: *RendererOrchestrator) void {
        self.damage.deinit(self.allocator);
    }

    /// Records the grid dimensions used to validate and clip damage rects.
    /// Zero dimensions disable validation (renderer used standalone).
    pub fn setGridBounds(self: *RendererOrchestrator, rows: u32, cols: u32) void {
        self.grid_rows = rows;
        self.grid_cols = cols;
    }

    pub fn markDamage(self: *RendererOrchestrator, rect: DamageRect) !void {
        const clipped = self.clipRect(rect) orelse return;
        if (self.damage.items.len >= max_damage_rects) {
            self.collapseInto(clipped);
            return;
        }
        try self.damage.append(self.allocator, clipped);
        self.stats.dirty_rects = @intCast(self.damage.items.len);
    }

    pub fn beginFrame(self: *RendererOrchestrator, visible_cells: u32) RenderStats {
        self.stats.visible_cells = visible_cells;
        self.stats.draw_calls = if (self.damage.items.len == 0) 0 else 1;
        return self.stats;
    }

    pub fn endFrame(self: *RendererOrchestrator) void {
        self.damage.clearRetainingCapacity();
        self.stats.dirty_rects = 0;
    }

    fn clipRect(self: *const RendererOrchestrator, rect: DamageRect) ?DamageRect {
        if (rect.rows == 0 or rect.cols == 0) return null;
        if (self.grid_rows == 0 or self.grid_cols == 0) return rect;
        if (rect.row >= self.grid_rows or rect.col >= self.grid_cols) return null;
        return .{
            .row = rect.row,
            .col = rect.col,
            .rows = @min(rect.rows, self.grid_rows - rect.row),
            .cols = @min(rect.cols, self.grid_cols - rect.col),
        };
    }

    fn collapseInto(self: *RendererOrchestrator, rect: DamageRect) void {
        var merged = rect;
        for (self.damage.items) |existing| {
            merged = unionRect(merged, existing);
        }
        self.damage.clearRetainingCapacity();
        self.damage.appendAssumeCapacity(merged);
        self.stats.dirty_rects = 1;
    }
};

fn unionRect(a: DamageRect, b: DamageRect) DamageRect {
    const row = @min(a.row, b.row);
    const col = @min(a.col, b.col);
    const row_end = @max(a.row + a.rows, b.row + b.rows);
    const col_end = @max(a.col + a.cols, b.col + b.cols);
    return .{ .row = row, .col = col, .rows = row_end - row, .cols = col_end - col };
}
