const std = @import("std");

pub const CsiEvent = struct {
    final: u8,
    private: bool = false,
    prefix: ?u8 = null,
    params: []const u16,
};

pub const Event = union(enum) {
    printable: struct { bytes: []const u8 },
    csi: CsiEvent,
    osc: struct { bytes: []const u8 },
    control: u8,
};

pub const Parser = struct {
    pub const max_csi_sequence_bytes: usize = 256;
    pub const max_string_sequence_bytes: usize = 4096;

    allocator: std.mem.Allocator,
    state: State = .normal,
    printable: std.ArrayList(u8) = .empty,
    control: std.ArrayList(u8) = .empty,
    string: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        self.printable.deinit(self.allocator);
        self.control.deinit(self.allocator);
        self.string.deinit(self.allocator);
    }

    pub fn feed(self: *Parser, bytes: []const u8) ![]Event {
        var events: std.ArrayList(Event) = .empty;
        errdefer self.freeEvents(events.items);

        for (bytes) |byte| {
            switch (self.state) {
                .normal => switch (byte) {
                    0x1b => {
                        try self.flushPrintable(&events);
                        self.control.clearRetainingCapacity();
                        self.state = .escape;
                    },
                    0x08, 0x09, 0x0a, 0x0d => {
                        try self.flushPrintable(&events);
                        try events.append(self.allocator, .{ .control = byte });
                    },
                    0x00...0x07, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {
                        try self.flushPrintable(&events);
                    },
                    else => try self.printable.append(self.allocator, byte),
                },
                .escape => switch (byte) {
                    '[' => {
                        self.control.clearRetainingCapacity();
                        self.state = .csi;
                    },
                    ']' => {
                        self.string.clearRetainingCapacity();
                        self.state = .osc;
                    },
                    'P', '^', '_' => {
                        self.string.clearRetainingCapacity();
                        self.state = .string_control;
                    },
                    '(', ')', '*', '+', '-', '.', '/', '%' => {
                        self.state = .escape_designator;
                    },
                    '#' => {
                        self.state = .escape_dec_private;
                    },
                    else => {
                        try events.append(self.allocator, .{ .control = byte });
                        self.state = .normal;
                    },
                },
                .escape_designator => {
                    self.state = .normal;
                },
                .escape_dec_private => {
                    self.state = .normal;
                },
                .csi => {
                    if (isCsiFinal(byte)) {
                        self.appendCsi(&events, byte) catch |err| {
                            self.control.clearRetainingCapacity();
                            self.state = .normal;
                            return err;
                        };
                        self.control.clearRetainingCapacity();
                        self.state = .normal;
                    } else {
                        switch (try self.appendBoundedControlByte(byte)) {
                            .appended => {},
                            .overflow => self.state = .csi_discard,
                        }
                    }
                },
                .csi_discard => {
                    if (isCsiFinal(byte)) {
                        self.control.clearRetainingCapacity();
                        self.state = .normal;
                    }
                },
                .osc => switch (byte) {
                    0x07 => {
                        try self.appendOsc(&events);
                        self.string.clearRetainingCapacity();
                        self.state = .normal;
                    },
                    0x1b => self.state = .osc_escape,
                    else => switch (try self.appendBoundedStringByte(byte)) {
                        .appended => {},
                        .overflow => self.state = .osc_discard,
                    },
                },
                .osc_escape => {
                    if (byte == '\\') {
                        try self.appendOsc(&events);
                        self.string.clearRetainingCapacity();
                        self.state = .normal;
                    } else {
                        switch (try self.appendBoundedStringByte(0x1b)) {
                            .appended => switch (try self.appendBoundedStringByte(byte)) {
                                .appended => self.state = .osc,
                                .overflow => self.state = .osc_discard,
                            },
                            .overflow => self.state = .osc_discard,
                        }
                    }
                },
                .osc_discard => switch (byte) {
                    0x07 => {
                        self.string.clearRetainingCapacity();
                        self.state = .normal;
                    },
                    0x1b => self.state = .osc_discard_escape,
                    else => {},
                },
                .osc_discard_escape => {
                    if (byte == '\\') {
                        self.string.clearRetainingCapacity();
                        self.state = .normal;
                    } else {
                        self.state = .osc_discard;
                    }
                },
                .string_control => switch (byte) {
                    0x07 => {
                        self.string.clearRetainingCapacity();
                        self.state = .normal;
                    },
                    0x1b => self.state = .string_escape,
                    else => {},
                },
                .string_escape => {
                    if (byte == '\\') {
                        self.string.clearRetainingCapacity();
                        self.state = .normal;
                    } else {
                        self.state = .string_control;
                    }
                },
            }
        }

        if (self.state == .normal) {
            try self.flushPrintable(&events);
        }
        return events.toOwnedSlice(self.allocator);
    }

    pub fn freeEvents(self: *Parser, events: []const Event) void {
        for (events) |event| {
            switch (event) {
                .printable => |printable_event| self.allocator.free(printable_event.bytes),
                .csi => |csi_event| self.allocator.free(csi_event.params),
                .osc => |osc_event| self.allocator.free(osc_event.bytes),
                .control => {},
            }
        }
        self.allocator.free(events);
    }

    fn flushPrintable(self: *Parser, events: *std.ArrayList(Event)) !void {
        if (self.printable.items.len == 0) return;
        const owned = try self.printable.toOwnedSlice(self.allocator);
        try events.append(self.allocator, .{ .printable = .{ .bytes = owned } });
    }

    fn appendBoundedControlByte(self: *Parser, byte: u8) !BoundedAppendResult {
        if (self.control.items.len >= max_csi_sequence_bytes) {
            self.control.clearRetainingCapacity();
            return .overflow;
        }
        try self.control.append(self.allocator, byte);
        return .appended;
    }

    fn appendBoundedStringByte(self: *Parser, byte: u8) !BoundedAppendResult {
        if (self.string.items.len >= max_string_sequence_bytes) {
            self.string.clearRetainingCapacity();
            return .overflow;
        }
        try self.string.append(self.allocator, byte);
        return .appended;
    }

    fn appendCsi(self: *Parser, events: *std.ArrayList(Event), final: u8) !void {
        const raw = self.control.items;
        const private_prefix_len = privatePrefixLen(raw);
        const private = private_prefix_len > 0;
        const params_raw = raw[private_prefix_len..];
        var params: std.ArrayList(u16) = .empty;
        errdefer params.deinit(self.allocator);

        if (params_raw.len == 0) {
            try params.append(self.allocator, 0);
        } else {
            var it = std.mem.splitAny(u8, params_raw, ";:");
            while (it.next()) |part| {
                const digits = parameterDigits(part);
                if (digits.len == 0) {
                    try params.append(self.allocator, 0);
                } else {
                    try params.append(self.allocator, try std.fmt.parseInt(u16, digits, 10));
                }
            }
        }

        try events.append(self.allocator, .{ .csi = .{
            .final = final,
            .private = private,
            .prefix = if (private) raw[0] else null,
            .params = try params.toOwnedSlice(self.allocator),
        } });
    }

    fn appendOsc(self: *Parser, events: *std.ArrayList(Event)) !void {
        const owned = try self.string.toOwnedSlice(self.allocator);
        try events.append(self.allocator, .{ .osc = .{ .bytes = owned } });
    }
};

const State = enum {
    normal,
    escape,
    escape_designator,
    escape_dec_private,
    csi,
    csi_discard,
    osc,
    osc_escape,
    osc_discard,
    osc_discard_escape,
    string_control,
    string_escape,
};

const BoundedAppendResult = enum {
    appended,
    overflow,
};

fn isCsiFinal(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7e;
}

fn privatePrefixLen(raw: []const u8) usize {
    var len: usize = 0;
    while (len < raw.len and raw[len] >= 0x3c and raw[len] <= 0x3f) : (len += 1) {}
    return len;
}

fn parameterDigits(part: []const u8) []const u8 {
    var start: usize = 0;
    while (start < part.len and !std.ascii.isDigit(part[start])) : (start += 1) {}
    var end = start;
    while (end < part.len and std.ascii.isDigit(part[end])) : (end += 1) {}
    return part[start..end];
}
