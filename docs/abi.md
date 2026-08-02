# Zig C ABI

Swift uses `CoreBridge` to load `zig-out/lib/libkurotty_core.dylib` with `dlopen`.

Current exported functions:

- `kurotty_terminal_create(width, height)`
- `kurotty_terminal_destroy(handle)`
- `kurotty_terminal_feed(handle, bytes, len)`
- `kurotty_terminal_record_key(handle, timestamp_micros)`
- `kurotty_terminal_record_present(handle, timestamp_micros)`
- `kurotty_terminal_last_latency(handle)`
- `kurotty_terminal_cursor_row(handle)`
- `kurotty_terminal_cursor_col(handle)`
- `kurotty_terminal_width(handle)`
- `kurotty_terminal_height(handle)`
- `kurotty_terminal_mark_damage(handle, row, col, rows, cols)`
- `kurotty_terminal_begin_frame(handle, visible_cells)`
- `kurotty_terminal_end_frame(handle)`
- `kurotty_terminal_resize(handle, width, height)`
- `kurotty_terminal_cell_at(handle, row, col)`
- `kurotty_terminal_copy_row(handle, row, buffer, buffer_len)`
- `kurotty_terminal_copy_row_cells(handle, row, out_buffer, max_cells)`

Dimension queries return the current Zig grid size after creation or resize. A null handle returns `0`, matching the existing cursor and metric query fallback shape.

`kurotty_terminal_copy_row` is the first caller-buffer screen-state API for Swift-owned migration work. It copies the requested Zig-owned grid row into caller-owned memory and returns the number of bytes copied. The copy is bounded to `min(terminal_width, buffer_len)`, performs no allocation, and transfers no heap ownership across the ABI. A null handle, null buffer, invalid row, or zero-length buffer returns `0` and leaves caller memory unchanged.

`kurotty_terminal_copy_row` remains the legacy byte view: single-width ASCII cells copy through as their byte value, and any other cell (non-ASCII codepoint, wide head, wide continuation) degrades to a space. It exists only for compatibility with byte-oriented callers.

## Styled cell row copy

`kurotty_terminal_copy_row_cells(handle, row, out_buffer, max_cells) -> usize` fills caller-owned memory with one 16-byte record per cell and returns the number of cells written, bounded to `min(terminal_width, max_cells)`. A null handle, null buffer, invalid row, or zero `max_cells` returns `0` and leaves caller memory unchanged. No allocation happens and no ownership crosses the ABI.

Each record is this fixed-layout struct (C layout, 16 bytes, natural alignment):

```c
typedef struct {
    uint32_t codepoint; // Unicode scalar; 0 for wide-continuation cells
    uint32_t fg;        // packed color, see below
    uint32_t bg;        // packed color, see below
    uint16_t attrs;     // attribute bits, see below
    uint8_t  width;     // 1 = single, 2 = wide head, 0 = wide continuation
    uint8_t  pad;       // always 0
} kurotty_cell;
```

Color encoding (tag in bits 24-25):

- `0x00000000` — terminal default color
- `0x01000000 | index` — 256-color palette index (SGR 30-37/40-47 map to 0-7, 90-97/100-107 to 8-15, `38;5;n`/`48;5;n` to `n`)
- `0x02000000 | (r << 16) | (g << 8) | b` — 24-bit truecolor from `38;2;r;g;b` / `48;2;r;g;b`

Attribute bits, from bit 0: bold, dim, italic, underline, strikethrough, inverse. Higher bits are reserved and currently 0.

A wide glyph (CJK, Hangul, emoji, fullwidth forms) occupies two cells: the head cell carries the codepoint with `width == 2`, followed by one continuation cell with `width == 0` and `codepoint == 0`. Renderers should draw the head across both columns and skip continuations. The first combining mark following a base character attaches to that base cell and is currently not exposed through this struct.

Missing-symbol note for Swift: `kurotty_terminal_copy_row_cells` is newer than the rest of the surface. `CoreBridge` resolves it optionally, so an older dylib without the symbol still loads and only the styled row read degrades to unavailable.
