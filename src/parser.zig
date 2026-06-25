const std = @import("std");

pub const CsiEvent = struct {
    final: u8,
    params: []const u16,
};

pub const Event = union(enum) {
    printable: struct { bytes: []const u8 },
    csi: CsiEvent,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        _ = self;
    }

    pub fn feed(self: *Parser, bytes: []const u8) ![]Event {
        var events: std.ArrayList(Event) = .empty;
        errdefer {
            for (events.items) |event| freeEvent(self.allocator, event);
            events.deinit(self.allocator);
        }

        var i: usize = 0;
        var printable_start: ?usize = null;
        while (i < bytes.len) {
            if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '[') {
                if (printable_start) |start| {
                    try appendPrintable(self.allocator, &events, bytes[start..i]);
                    printable_start = null;
                }

                var j = i + 2;
                while (j < bytes.len and !isCsiFinal(bytes[j])) : (j += 1) {}
                if (j >= bytes.len) break;

                try appendCsi(self.allocator, &events, bytes[i + 2 .. j], bytes[j]);
                i = j + 1;
                continue;
            }

            if (printable_start == null) printable_start = i;
            i += 1;
        }

        if (printable_start) |start| {
            if (start < bytes.len) try appendPrintable(self.allocator, &events, bytes[start..]);
        }

        return events.toOwnedSlice(self.allocator);
    }
};

fn appendPrintable(allocator: std.mem.Allocator, events: *std.ArrayList(Event), bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const owned = try allocator.dupe(u8, bytes);
    try events.append(allocator, .{ .printable = .{ .bytes = owned } });
}

fn appendCsi(
    allocator: std.mem.Allocator,
    events: *std.ArrayList(Event),
    param_bytes: []const u8,
    final: u8,
) !void {
    var params: std.ArrayList(u16) = .empty;
    errdefer params.deinit(allocator);

    if (param_bytes.len == 0) {
        try params.append(allocator, 0);
    } else {
        var it = std.mem.splitScalar(u8, param_bytes, ';');
        while (it.next()) |raw| {
            if (raw.len == 0) {
                try params.append(allocator, 0);
            } else {
                try params.append(allocator, try std.fmt.parseInt(u16, raw, 10));
            }
        }
    }

    try events.append(allocator, .{ .csi = .{ .final = final, .params = try params.toOwnedSlice(allocator) } });
}

fn isCsiFinal(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7e;
}

fn freeEvent(allocator: std.mem.Allocator, event: Event) void {
    switch (event) {
        .printable => |printable| allocator.free(printable.bytes),
        .csi => |csi| allocator.free(csi.params),
    }
}
