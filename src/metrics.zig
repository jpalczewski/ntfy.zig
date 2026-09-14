// In-process counters exposed at GET /metrics (see main.zig) in Prometheus
// text exposition format. No metrics library: the app only tracks a handful
// of counters, and connections run concurrently (see main.zig's
// `Io.Group.concurrent`), so every counter is a plain atomic.
const std = @import("std");
const ChannelType = @import("config.zig").ChannelType;

/// What happened to a webhook request that matched a channel route.
/// Deliberately not "the HTTP status code returned" — that would conflate a
/// notification ntfy.zig actually forwarded with one it chose to ignore.
pub const Outcome = enum {
    bad_request,
    forwarded,
    ignored,
    invalid_signature,
    parse_fallback,
    payload_too_large,
};

const Counter = std.atomic.Value(u64);

/// Per-channel forward outcome: always read and written together, so kept
/// as one struct instead of three parallel `EnumArray(ChannelType, Counter)`
/// fields that would otherwise have to be kept in sync by hand.
const ForwardStats = struct {
    failures: Counter = .init(0),
    duration_ns_sum: Counter = .init(0),
    count: Counter = .init(0),
};

pub const Metrics = struct {
    requests: std.EnumArray(ChannelType, std.EnumArray(Outcome, Counter)) =
        .initFill(.initFill(.init(0))),
    /// Requests whose path/method matched no configured channel route —
    /// there's no channel to label these with.
    unmatched_total: Counter = .init(0),
    forward: std.EnumArray(ChannelType, ForwardStats) = .initFill(.{}),

    pub fn recordRequest(self: *Metrics, kind: ChannelType, outcome: Outcome) void {
        _ = self.requests.getPtr(kind).getPtr(outcome).fetchAdd(1, .monotonic);
    }

    pub fn recordUnmatched(self: *Metrics) void {
        _ = self.unmatched_total.fetchAdd(1, .monotonic);
    }

    pub fn recordForwardFailure(self: *Metrics, kind: ChannelType) void {
        _ = self.forward.getPtr(kind).failures.fetchAdd(1, .monotonic);
    }

    /// `elapsed_ns` is wall-clock time spent attempting the forward
    /// (success or failure alike), from a monotonic clock reading.
    pub fn recordForwardDuration(self: *Metrics, kind: ChannelType, elapsed_ns: u64) void {
        const stats = self.forward.getPtr(kind);
        _ = stats.duration_ns_sum.fetchAdd(elapsed_ns, .monotonic);
        _ = stats.count.fetchAdd(1, .monotonic);
    }

    /// Renders every counter as Prometheus text exposition format:
    /// https://github.com/prometheus/docs/blob/main/docs/instrumenting/exposition_formats.md
    pub fn write(self: *const Metrics, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(
            \\# HELP ntfyzig_requests_total Webhook requests handled, by channel and outcome.
            \\# TYPE ntfyzig_requests_total counter
            \\
        );
        for (std.meta.tags(ChannelType)) |kind| {
            for (std.meta.tags(Outcome)) |outcome| {
                const count = self.requests.getPtrConst(kind).getPtrConst(outcome).load(.monotonic);
                try w.print(
                    "ntfyzig_requests_total{{channel=\"{t}\",outcome=\"{t}\"}} {d}\n",
                    .{ kind, outcome, count },
                );
            }
        }

        try w.writeAll(
            \\# HELP ntfyzig_unmatched_requests_total Requests that matched no configured channel route.
            \\# TYPE ntfyzig_unmatched_requests_total counter
            \\
        );
        try w.print("ntfyzig_unmatched_requests_total {d}\n", .{self.unmatched_total.load(.monotonic)});

        try w.writeAll(
            \\# HELP ntfyzig_forward_failures_total Forwards to ntfy that failed, errored, or timed out, by channel.
            \\# TYPE ntfyzig_forward_failures_total counter
            \\
        );
        for (std.meta.tags(ChannelType)) |kind| {
            const failures = self.forward.getPtrConst(kind).failures.load(.monotonic);
            try w.print("ntfyzig_forward_failures_total{{channel=\"{t}\"}} {d}\n", .{ kind, failures });
        }

        try w.writeAll(
            \\# HELP ntfyzig_forward_duration_seconds Time spent forwarding a webhook to ntfy, by channel.
            \\# TYPE ntfyzig_forward_duration_seconds summary
            \\
        );
        for (std.meta.tags(ChannelType)) |kind| {
            const stats = self.forward.getPtrConst(kind);
            const sum_ns = stats.duration_ns_sum.load(.monotonic);
            const count = stats.count.load(.monotonic);
            const sum_seconds = @as(f64, @floatFromInt(sum_ns)) / @as(f64, std.time.ns_per_s);
            try w.print("ntfyzig_forward_duration_seconds_sum{{channel=\"{t}\"}} {d}\n", .{ kind, sum_seconds });
            try w.print("ntfyzig_forward_duration_seconds_count{{channel=\"{t}\"}} {d}\n", .{ kind, count });
        }
    }
};

test "Metrics.write renders Prometheus text format" {
    var counters: Metrics = .{};
    counters.recordRequest(.coolify, .forwarded);
    counters.recordRequest(.coolify, .ignored);
    counters.recordUnmatched();
    counters.recordForwardFailure(.github);
    counters.recordForwardDuration(.coolify, 250 * std.time.ns_per_ms);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try counters.write(&writer);
    const out = writer.buffered();

    try expectContains(out, "ntfyzig_requests_total{channel=\"coolify\",outcome=\"forwarded\"} 1\n");
    try expectContains(out, "ntfyzig_requests_total{channel=\"coolify\",outcome=\"ignored\"} 1\n");
    try expectContains(out, "ntfyzig_requests_total{channel=\"github\",outcome=\"forwarded\"} 0\n");
    try expectContains(out, "ntfyzig_unmatched_requests_total 1\n");
    try expectContains(out, "ntfyzig_forward_failures_total{channel=\"github\"} 1\n");
    try expectContains(out, "ntfyzig_forward_failures_total{channel=\"coolify\"} 0\n");
    try expectContains(out, "ntfyzig_forward_duration_seconds_sum{channel=\"coolify\"} 0.25\n");
    try expectContains(out, "ntfyzig_forward_duration_seconds_count{channel=\"coolify\"} 1\n");
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

test "Metrics counters are safe to increment concurrently" {
    var counters: Metrics = .{};
    const increments_per_thread = 500;
    const thread_count = 4;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, incrementMany, .{ &counters, increments_per_thread });
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(
        @as(u64, thread_count * increments_per_thread),
        counters.requests.getPtrConst(.coolify).getPtrConst(.forwarded).load(.monotonic),
    );
}

fn incrementMany(counters: *Metrics, count: usize) void {
    for (0..count) |_| counters.recordRequest(.coolify, .forwarded);
}
