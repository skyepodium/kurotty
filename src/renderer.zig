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
    allocator: std.mem.Allocator,
    damage: std.ArrayList(DamageRect),
    stats: RenderStats = .{},

    pub fn init(allocator: std.mem.Allocator) RendererOrchestrator {
        return .{
            .allocator = allocator,
            .damage = .empty,
        };
    }

    pub fn deinit(self: *RendererOrchestrator) void {
        self.damage.deinit(self.allocator);
    }

    pub fn markDamage(self: *RendererOrchestrator, rect: DamageRect) !void {
        try self.damage.append(self.allocator, rect);
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
};
