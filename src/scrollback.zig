const std = @import("std");

pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    lines: std.ArrayList([]u8),
    byte_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Scrollback {
        var lines: std.ArrayList([]u8) = .empty;
        try lines.ensureTotalCapacity(allocator, @min(capacity, 4096));
        return .{
            .allocator = allocator,
            .capacity = capacity,
            .lines = lines,
        };
    }

    pub fn deinit(self: *Scrollback) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }

    pub fn appendFmt(self: *Scrollback, comptime fmt: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(line);
        try self.appendOwned(line);
    }

    pub fn append(self: *Scrollback, line: []const u8) !void {
        try self.appendOwned(try self.allocator.dupe(u8, line));
    }

    pub fn len(self: *const Scrollback) usize {
        return self.lines.items.len;
    }

    pub fn lineAt(self: *const Scrollback, index: usize) []const u8 {
        return self.lines.items[index];
    }

    pub fn bytesUsed(self: *const Scrollback) usize {
        return self.byte_count + self.lines.capacity * @sizeOf([]u8);
    }

    fn appendOwned(self: *Scrollback, line: []u8) !void {
        if (self.lines.items.len == self.capacity and self.capacity > 0) {
            const old = self.lines.orderedRemove(0);
            self.byte_count -= old.len;
            self.allocator.free(old);
        }
        try self.lines.append(self.allocator, line);
        self.byte_count += line.len;
    }
};
