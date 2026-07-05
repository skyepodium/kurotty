const std = @import("std");

pub const max_winsize_dimension = std.math.maxInt(u16);

pub const PtyDimensions = struct {
    cols: u16,
    rows: u16,

    pub fn init(cols: u32, rows: u32) !PtyDimensions {
        if (cols == 0 or rows == 0) return error.InvalidDimensions;
        if (cols > max_winsize_dimension or rows > max_winsize_dimension) return error.DimensionOverflow;

        return .{
            .cols = @intCast(cols),
            .rows = @intCast(rows),
        };
    }
};

pub const PtyResizeSource = enum {
    unknown,
    renderer,
    user,
    programmatic,
};

pub const PtyResizeRequest = struct {
    dimensions: PtyDimensions,
    source: PtyResizeSource,
    sequence: u64,

    pub fn init(cols: u32, rows: u32, source: PtyResizeSource, sequence: u64) !PtyResizeRequest {
        return .{
            .dimensions = try PtyDimensions.init(cols, rows),
            .source = source,
            .sequence = sequence,
        };
    }
};

pub const PtyRuntimeOwner = enum {
    unclaimed,
    swift_scaffold,
    zig_core,
};

pub const PtyRuntimeOwnershipSample = struct {
    owner: PtyRuntimeOwner,
    dimensions: PtyDimensions,
    source: PtyResizeSource,
    sequence: u64,
};

pub const PtyRuntimeOwnershipSummary = struct {
    current_owner: PtyRuntimeOwner,
    current_dimensions: ?PtyDimensions,
    current_source: PtyResizeSource,
    last_sequence: u64,
    claim_count: u32,
    has_owner_handoff: bool,
    has_dimension_divergence: bool,
};

pub const PtyRuntimeOwnershipLedger = struct {
    current_owner: PtyRuntimeOwner = .unclaimed,
    current_dimensions: ?PtyDimensions = null,
    current_source: PtyResizeSource = .unknown,
    last_sequence: u64 = 0,
    claim_count: u32 = 0,
    has_owner_handoff: bool = false,
    has_dimension_divergence: bool = false,

    pub fn init() PtyRuntimeOwnershipLedger {
        return .{};
    }

    pub fn record(self: *PtyRuntimeOwnershipLedger, sample: PtyRuntimeOwnershipSample) !void {
        if (sample.owner == .unclaimed) return error.UnclaimedOwnershipSample;
        if (self.claim_count > 0 and sample.sequence <= self.last_sequence) {
            return error.StaleOwnershipSample;
        }

        if (self.current_owner != .unclaimed and self.current_owner != sample.owner) {
            self.has_owner_handoff = true;
        }
        if (self.current_dimensions) |dimensions| {
            if (dimensions.cols != sample.dimensions.cols or dimensions.rows != sample.dimensions.rows) {
                self.has_dimension_divergence = true;
            }
        }

        self.current_owner = sample.owner;
        self.current_dimensions = sample.dimensions;
        self.current_source = sample.source;
        self.last_sequence = sample.sequence;
        self.claim_count += 1;
    }

    pub fn summary(self: PtyRuntimeOwnershipLedger) PtyRuntimeOwnershipSummary {
        return .{
            .current_owner = self.current_owner,
            .current_dimensions = self.current_dimensions,
            .current_source = self.current_source,
            .last_sequence = self.last_sequence,
            .claim_count = self.claim_count,
            .has_owner_handoff = self.has_owner_handoff,
            .has_dimension_divergence = self.has_dimension_divergence,
        };
    }

    pub fn hasDivergence(self: PtyRuntimeOwnershipLedger) bool {
        return self.has_owner_handoff or self.has_dimension_divergence;
    }
};

pub const PtySizeStatus = enum {
    matched,
    mismatch,
};

pub const PtySizeDiagnostic = struct {
    pty: PtyDimensions,
    renderer: PtyDimensions,
    status: PtySizeStatus,
    cols_delta: i32,
    rows_delta: i32,

    pub fn compare(pty: PtyDimensions, renderer: PtyDimensions) PtySizeDiagnostic {
        const pty_cols: i32 = @intCast(pty.cols);
        const renderer_cols: i32 = @intCast(renderer.cols);
        const pty_rows: i32 = @intCast(pty.rows);
        const renderer_rows: i32 = @intCast(renderer.rows);
        const cols_delta = renderer_cols - pty_cols;
        const rows_delta = renderer_rows - pty_rows;

        return .{
            .pty = pty,
            .renderer = renderer,
            .status = if (cols_delta == 0 and rows_delta == 0) .matched else .mismatch,
            .cols_delta = cols_delta,
            .rows_delta = rows_delta,
        };
    }

    pub fn matches(self: PtySizeDiagnostic) bool {
        return self.status == .matched;
    }
};

pub const PtyConfig = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    shell: []const u8 = "/bin/zsh",

    pub fn dimensions(self: PtyConfig) !PtyDimensions {
        return PtyDimensions.init(self.cols, self.rows);
    }
};

pub const Pty = struct {
    fd: std.posix.fd_t,
    pid: std.posix.pid_t,

    pub fn spawn(config: PtyConfig) !Pty {
        _ = try config.dimensions();
        return error.PtySpawnNotImplemented;
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        _ = self;
        _ = try PtyResizeRequest.init(cols, rows, .programmatic, 0);
        return error.PtyResizeNotImplemented;
    }

    pub fn read(self: *Pty, buffer: []u8) !usize {
        return std.posix.read(self.fd, buffer);
    }

    pub fn write(self: *Pty, bytes: []const u8) !usize {
        return std.posix.write(self.fd, bytes);
    }
};
