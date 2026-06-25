pub const Metrics = struct {
    pending_key_event_micros: ?u64 = null,
    last_latency_micros: u64 = 0,
    max_latency_micros: u64 = 0,
    frame_count: u64 = 0,

    pub fn init() Metrics {
        return .{};
    }

    pub fn recordKeyEvent(self: *Metrics, timestamp_micros: u64) void {
        self.pending_key_event_micros = timestamp_micros;
    }

    pub fn recordFramePresented(self: *Metrics, timestamp_micros: u64) void {
        self.frame_count += 1;
        if (self.pending_key_event_micros) |start| {
            if (timestamp_micros >= start) {
                const latency = timestamp_micros - start;
                self.last_latency_micros = latency;
                if (latency > self.max_latency_micros) self.max_latency_micros = latency;
            }
            self.pending_key_event_micros = null;
        }
    }

    pub fn lastInputToPresentMicros(self: *const Metrics) u64 {
        return self.last_latency_micros;
    }

    pub fn maxInputToPresentMicros(self: *const Metrics) u64 {
        return self.max_latency_micros;
    }
};
