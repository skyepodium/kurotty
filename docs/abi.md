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

Dimension queries return the current Zig grid size after creation or resize. A null handle returns `0`, matching the existing cursor and metric query fallback shape.
