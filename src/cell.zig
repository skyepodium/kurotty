const std = @import("std");

/// Packed 32-bit color encoding shared between the grid and the C ABI.
/// Tag lives in bits 24-25:
///   0x00000000            -> terminal default color
///   0x01000000 | index    -> 256-color palette index (0-255)
///   0x02000000 | rrggbb   -> 24-bit truecolor
pub const Color = struct {
    pub const default: u32 = 0;
    pub const tag_indexed: u32 = 0x0100_0000;
    pub const tag_rgb: u32 = 0x0200_0000;

    pub fn indexed(index: u8) u32 {
        return tag_indexed | @as(u32, index);
    }

    pub fn rgb(r: u8, g: u8, b: u8) u32 {
        return tag_rgb | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    }
};

pub const Attributes = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    inverse: bool = false,
    _reserved: u10 = 0,

    pub fn none(self: Attributes) bool {
        return @as(u16, @bitCast(self)) == 0;
    }
};

pub const Style = struct {
    fg: u32 = Color.default,
    bg: u32 = Color.default,
    attrs: Attributes = .{},
};

pub const CellWidth = enum(u8) {
    /// Trailing half of a wide glyph; owns no codepoint of its own.
    continuation = 0,
    single = 1,
    /// Leading half of a wide glyph; the next cell is a continuation.
    wide = 2,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    width: CellWidth = .single,
    /// First combining mark attached to this cell, 0 when none.
    combining: u21 = 0,
    style: Style = .{},
};

/// Fixed-layout cell record crossing the C ABI. Field order and sizes are
/// part of the ABI contract documented in docs/abi.md.
pub const AbiCell = extern struct {
    codepoint: u32,
    fg: u32,
    bg: u32,
    attrs: u16,
    width: u8,
    pad: u8 = 0,
};

comptime {
    std.debug.assert(@sizeOf(AbiCell) == 16);
}

pub const DecodedCodepoint = struct {
    codepoint: u21,
    len: usize,
    /// True when the byte run ended before the sequence completed.
    incomplete: bool = false,
};

pub fn decodeUtf8(bytes: []const u8) DecodedCodepoint {
    const first = bytes[0];
    if (first < 0x80) return .{ .codepoint = first, .len = 1 };
    if (first & 0xe0 == 0xc0) {
        if (bytes.len < 2) return .{ .codepoint = first, .len = 1, .incomplete = true };
        return .{
            .codepoint = (@as(u21, first & 0x1f) << 6) | @as(u21, bytes[1] & 0x3f),
            .len = 2,
        };
    }
    if (first & 0xf0 == 0xe0) {
        if (bytes.len < 3) return .{ .codepoint = first, .len = 1, .incomplete = true };
        return .{
            .codepoint = (@as(u21, first & 0x0f) << 12) | (@as(u21, bytes[1] & 0x3f) << 6) | @as(u21, bytes[2] & 0x3f),
            .len = 3,
        };
    }
    if (first & 0xf8 == 0xf0) {
        if (bytes.len < 4) return .{ .codepoint = first, .len = 1, .incomplete = true };
        return .{
            .codepoint = (@as(u21, first & 0x07) << 18) | (@as(u21, bytes[1] & 0x3f) << 12) | (@as(u21, bytes[2] & 0x3f) << 6) | @as(u21, bytes[3] & 0x3f),
            .len = 4,
        };
    }
    return .{ .codepoint = first, .len = 1 };
}

pub fn utf8SequenceLength(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte & 0xe0 == 0xc0) return 2;
    if (first_byte & 0xf0 == 0xe0) return 3;
    if (first_byte & 0xf8 == 0xf0) return 4;
    return 1;
}

pub fn codepointWidth(codepoint: u21) usize {
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
