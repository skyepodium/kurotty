const std = @import("std");

pub const PtyConfig = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    shell: []const u8 = "/bin/zsh",
};

pub const Pty = struct {
    fd: std.posix.fd_t,
    pid: std.posix.pid_t,

    pub fn spawn(config: PtyConfig) !Pty {
        _ = config;
        return error.PtySpawnNotImplemented;
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        _ = self;
        _ = cols;
        _ = rows;
        return error.PtyResizeNotImplemented;
    }

    pub fn read(self: *Pty, buffer: []u8) !usize {
        return std.posix.read(self.fd, buffer);
    }

    pub fn write(self: *Pty, bytes: []const u8) !usize {
        return std.posix.write(self.fd, bytes);
    }
};
