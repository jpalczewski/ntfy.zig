// Relays webhooks from one or more input channels to ntfy. Each channel
// (see channel.zig) owns a fixed, source-specific JSON schema that can't
// talk to ntfy directly — ntfy needs auth plus a title/message/priority
// shape, not a raw payload dumped as the message body. Coolify's built-in
// "Webhook" notification channel (see Coolify's SendWebhookJob/
// WebhookChannel) is the only input wired up today; new sources mean adding
// a Channel implementation, an enum value in config.zig, and a switch arm
// below — the request-handling loop itself never changes.
const std = @import("std");
const http = std.http;
const Io = std.Io;
const net = Io.net;
const json_log = @import("json_log.zig");
const channel = @import("channel.zig");
const Route = channel.Route;
const Summary = channel.Summary;
const coolify = @import("coolify.zig");
const github = @import("github.zig");
const config = @import("config.zig");
const metrics = @import("metrics.zig");

const listen_port: u16 = 8085;
/// Serves only `/health` and `/metrics` — kept off `listen_port` so exposing
/// the webhook port to the internet doesn't also expose request counters and
/// forward-latency data. Not published in the Dockerfile; reach it via the
/// container network (e.g. a Prometheus scrape target of
/// `<container>:9090`) or `docker exec`/a debug port-forward.
const internal_port: u16 = 9090;
const max_body_bytes: usize = 64 * 1024;
const ntfy_timeout: Io.Duration = .{ .nanoseconds = 10 * std.time.ns_per_s };

pub const std_options: std.Options = .{
    .logFn = json_log.jsonLog,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    if (isHealthcheckInvocation(init.minimal.args)) {
        return runHealthcheck(gpa, io);
    }

    // Config strings (secrets, ntfy URLs/tokens) need to outlive this
    // function, so this arena is deliberately never deinitialized.
    var config_arena_state = std.heap.ArenaAllocator.init(gpa);
    const config_arena = config_arena_state.allocator();

    const channel_configs = config.load(config_arena, io, init.environ_map) catch |err| {
        std.log.err("failed to load channel config: {t}", .{err});
        std.process.exit(1);
    };

    var routes = std.ArrayList(Route).empty;
    for (channel_configs) |cc| {
        const route_channel = switch (cc.type) {
            .coolify => blk: {
                const c = try gpa.create(coolify.Coolify);
                c.* = try coolify.Coolify.init(gpa, cc.secret);
                break :blk c.channel();
            },
            .github => blk: {
                const c = try gpa.create(github.Github);
                c.* = try github.Github.init(gpa, cc.secret);
                // The path is derived from the secret (not the secret itself, see
                // github.zig), so it isn't knowable ahead of time — log it so it can
                // be pasted into GitHub's webhook "Payload URL" field.
                std.log.info("github channel: payload URL path is {s}", .{c.target_path});
                break :blk c.channel();
            },
        };
        try routes.append(gpa, .{
            .channel = route_channel,
            .ntfy_url = cc.ntfy_url,
            .ntfy_token = cc.ntfy_token,
            .kind = cc.type,
        });
    }

    var app_metrics: metrics.Metrics = .{};

    // Shared across all forward-to-ntfy calls so concurrent webhook handlers
    // reuse pooled TCP/TLS connections instead of opening a fresh one per
    // request (see fetchNtfy) — Client.fetch is documented threadsafe, and
    // its connection_pool/ca_bundle are lock-guarded, so sharing one
    // instance across concurrent tasks is safe. Like config_arena_state
    // above, this is deliberately never deinitialized: deinit() asserts no
    // in-flight requests, and both the accept loop and the internal-server
    // task run forever.
    var ntfy_client: http.Client = .{ .allocator = gpa, .io = io };

    var address = try net.IpAddress.parseIp4("0.0.0.0", listen_port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var internal_address = try net.IpAddress.parseIp4("0.0.0.0", internal_port);
    var internal_server = try internal_address.listen(io, .{ .reuse_address = true });
    defer internal_server.deinit(io);

    std.log.info(
        "ntfy.zig listening on :{d} (webhooks) and :{d} (health/metrics) with {d} channel(s)",
        .{ listen_port, internal_port, routes.items.len },
    );

    // Each connection is handled in its own task so a slow channel/ntfy
    // response can't stall unrelated webhooks. `Group.concurrent` (rather
    // than `.async`) is what actually guarantees a separate thread — `.async`
    // is allowed to run inline once the implementation's (CPU-count-based)
    // async_limit is reached, which on a single-core container is 0. `gpa`
    // and `io` are documented threadsafe (see std.process.Init); routes are
    // built once above and never mutated afterward, so sharing them across
    // tasks is safe.
    var tasks: Io.Group = .init;

    // The health/metrics loop below never returns, so it must actually run
    // on a separate worker — if no concurrency capacity is available to spawn
    // it, running it inline here would block this thread forever and take
    // the webhook loop down with it. Log and keep the webhook loop running
    // instead of crashing the whole process over it; Docker's HEALTHCHECK
    // (which depends on this same port, see runHealthcheck) will start
    // failing and eventually restart the container regardless.
    tasks.concurrent(io, runInternalServer, .{ io, &internal_server, &app_metrics }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => std.log.err(
            "health/metrics server unavailable: no concurrency capacity to run it",
            .{},
        ),
    };

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {t}", .{err});
            continue;
        };
        const args = .{ gpa, io, stream, routes.items, &app_metrics, &ntfy_client };
        tasks.concurrent(io, handleConnectionTask, args) catch |err| switch (err) {
            error.ConcurrencyUnavailable => @call(.auto, handleConnectionTask, args),
        };
    }
}

fn handleConnectionTask(
    gpa: std.mem.Allocator,
    io: Io,
    stream: net.Stream,
    routes: []const Route,
    app_metrics: *metrics.Metrics,
    ntfy_client: *http.Client,
) void {
    handleConnection(gpa, io, stream, routes, app_metrics, ntfy_client) catch |err| {
        std.log.err("connection error: {t}", .{err});
    };
}

// Runs for the lifetime of the process. Connections here (health checks,
// Prometheus scrapes) do no outbound I/O and finish in microseconds, so
// unlike the webhook loop above they're handled inline rather than each
// getting their own task — there's nothing here that could stall.
fn runInternalServer(io: Io, server: *net.Server, app_metrics: *metrics.Metrics) void {
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("internal accept failed: {t}", .{err});
            continue;
        };
        handleMetricsConnection(io, stream, app_metrics) catch |err| {
            std.log.err("internal connection error: {t}", .{err});
        };
    }
}

// Owns the per-connection I/O buffers and HTTP framing state that both
// `handleConnection` and `handleMetricsConnection` need. Kept as a struct
// (rather than a helper function returning a `Request`) because
// `http.Server`/`Request` hold pointers into the reader/writer/buffers —
// those have to live in the *caller's* stack frame for the lifetime of the
// request, not get built and dropped inside a helper function.
const HttpConn = struct {
    // Every field below is assigned in `receiveHead` before anything reads
    // it — `undefined` here only reserves the storage these self-referential
    // pointers (reader → buffer, server → reader/writer) need to live at a
    // stable address. See the struct doc comment above.
    // zlinter-disable-next-line no_undefined
    send_buffer: [4096]u8 = undefined,
    // zlinter-disable-next-line no_undefined
    recv_buffer: [8192]u8 = undefined,
    // zlinter-disable-next-line no_undefined
    reader: net.Stream.Reader = undefined,
    // zlinter-disable-next-line no_undefined
    writer: net.Stream.Writer = undefined,
    // zlinter-disable-next-line no_undefined
    server: http.Server = undefined,

    /// Returns `null` if the client closed the connection before sending a
    /// request — routine with keep-alive probes, not an error.
    fn receiveHead(self: *HttpConn, io: Io, stream: net.Stream) !?http.Server.Request {
        self.reader = stream.reader(io, &self.recv_buffer);
        self.writer = stream.writer(io, &self.send_buffer);
        self.server = .init(&self.reader.interface, &self.writer.interface);
        const request = self.server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return null,
            else => return err,
        };
        return request;
    }
};

fn handleMetricsConnection(io: Io, stream_in: net.Stream, app_metrics: *metrics.Metrics) !void {
    var stream = stream_in;
    defer stream.close(io);

    var conn: HttpConn = .{};
    var request = (try conn.receiveHead(io, stream)) orelse return;

    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/health")) {
        try request.respond("ok", .{ .status = .ok, .keep_alive = false });
        return;
    }

    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/metrics")) {
        var metrics_buf: [4096]u8 = undefined;
        var metrics_writer = std.Io.Writer.fixed(&metrics_buf);
        try app_metrics.write(&metrics_writer);
        try request.respond(metrics_writer.buffered(), .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; version=0.0.4" }},
        });
        return;
    }

    try request.respond("not found", .{ .status = .not_found, .keep_alive = false });
}

// `docker run --entrypoint /ntfy.zig ... healthcheck` re-execs the same
// static binary in a self-check mode: the image is FROM scratch, so there's
// no shell, curl, or wget for a normal Docker HEALTHCHECK to call.
fn isHealthcheckInvocation(args: std.process.Args) bool {
    var it: std.process.Args.Iterator = .init(args);
    _ = it.next(); // argv[0]
    const first = it.next() orelse return false;
    return std.mem.eql(u8, first, "healthcheck");
}

fn runHealthcheck(gpa: std.mem.Allocator, io: Io) void {
    ok: {
        var client: http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();

        const result = client.fetch(.{
            .location = .{ .url = "http://127.0.0.1:" ++ std.fmt.comptimePrint("{d}", .{internal_port}) ++ "/health" },
            .method = .GET,
        }) catch break :ok;

        if (result.status == .ok) std.process.exit(0);
    }
    std.process.exit(1);
}

fn handleConnection(
    gpa: std.mem.Allocator,
    io: Io,
    stream_in: net.Stream,
    routes: []const Route,
    app_metrics: *metrics.Metrics,
    ntfy_client: *http.Client,
) !void {
    var stream = stream_in;
    defer stream.close(io);

    var conn: HttpConn = .{};
    var request = (try conn.receiveHead(io, stream)) orelse return;

    const matched: ?Route = for (routes) |r| {
        if (r.channel.matches(request.head.method, request.head.target)) break r;
    } else null;

    const route = matched orelse {
        app_metrics.recordUnmatched();
        try request.respond("not found", .{ .status = .not_found, .keep_alive = false });
        return;
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `request.head`/`request.head_buffer` (and therefore `target`/`method`
    // used above) are only valid up to this point: initializing the body
    // reader below invalidates every pointer into them (confirmed live — a
    // debug build segfaults on a poisoned `undefined` read if you touch
    // `head_buffer` afterward). So the raw header bytes a channel might need
    // (GitHub's signature/event headers) must be copied out now, before the
    // body is read, not passed as a view into the connection buffer.
    const raw_headers = try arena.dupe(u8, request.head_buffer);

    // A POST with neither content-length nor chunked transfer-encoding is
    // unframed — std.http's bodyReader falls back to handing us the raw
    // connection reader in that case (reads until the peer closes), which
    // hangs forever against a keep-alive client that's still waiting on a
    // response. Confirmed live: an empty `curl -X POST` deadlocked the
    // connection. Treat unframed as "no body" ourselves instead of ever
    // reading from that unbounded reader.
    const has_framed_body = request.head.content_length != null or
        request.head.transfer_encoding == .chunked;

    const body = if (has_framed_body) blk: {
        const body_reader = request.readerExpectContinue(&.{}) catch |err| {
            app_metrics.recordRequest(route.kind, .bad_request);
            try request.respond("bad request", .{ .status = .bad_request, .keep_alive = false });
            return err;
        };
        break :blk body_reader.allocRemaining(gpa, Io.Limit.limited(max_body_bytes)) catch {
            app_metrics.recordRequest(route.kind, .payload_too_large);
            try request.respond("payload too large", .{ .status = .payload_too_large, .keep_alive = false });
            return;
        };
    } else &.{};
    defer if (has_framed_body) gpa.free(body);

    var outcome: metrics.Outcome = .forwarded;
    const summary = route.channel.summarize(arena, body, raw_headers) catch |err| switch (err) {
        error.InvalidSignature => {
            std.log.warn("rejected webhook: invalid signature", .{});
            app_metrics.recordRequest(route.kind, .invalid_signature);
            try request.respond("unauthorized", .{ .status = .unauthorized, .keep_alive = false });
            return;
        },
        error.Ignored => {
            app_metrics.recordRequest(route.kind, .ignored);
            try request.respond("ok", .{ .status = .ok, .keep_alive = false });
            return;
        },
        else => blk: {
            std.log.warn("failed to parse webhook payload: {t}", .{err});
            outcome = .parse_fallback;
            break :blk Summary{
                .title = "ntfy.zig",
                .message = body,
                .priority = "3",
                .tags = "warning",
            };
        },
    };
    app_metrics.recordRequest(route.kind, outcome);

    const forward_start = Io.Clock.awake.now(io);
    forwardToNtfy(gpa, io, ntfy_client, route.ntfy_url, route.ntfy_token, summary) catch |err| {
        switch (err) {
            // Already logged with the specific status/timeout detail below.
            error.NtfyTimeout, error.NtfyRejected => {},
            else => std.log.err("failed to forward to ntfy: {t}", .{err}),
        }
        app_metrics.recordForwardFailure(route.kind);
    };
    const elapsed_ns = forward_start.durationTo(Io.Clock.awake.now(io)).nanoseconds;
    app_metrics.recordForwardDuration(route.kind, @intCast(@max(elapsed_ns, 0)));

    try request.respond("ok", .{ .status = .ok, .keep_alive = false });
}

const NtfyOutcome = union(enum) {
    fetch: http.Client.FetchError!http.Client.FetchResult,
    timed_out: void,
};

fn forwardToNtfy(
    gpa: std.mem.Allocator,
    io: Io,
    ntfy_client: *http.Client,
    ntfy_url: []const u8,
    ntfy_token: []const u8,
    summary: Summary,
) !void {
    const auth_value = try std.fmt.allocPrint(gpa, "Bearer {s}", .{ntfy_token});
    defer gpa.free(auth_value);

    // Race the ntfy request against a timer so a hung/slow ntfy endpoint
    // can't pin this connection's thread forever. Both legs must use
    // `.concurrent`, not `.async`: `.async` is allowed to run its function
    // inline (blocking, to completion) instead of on a separate task once
    // the Io implementation's thread limit is reached — on a single-core
    // container that limit is 0, which would turn the "race" into just
    // running one leg fully before the other ever starts.
    var outcome_buf: [2]NtfyOutcome = undefined;
    var select: Io.Select(NtfyOutcome) = .init(io, &outcome_buf);
    // Guarantees the still-running leg (if any) is interrupted and reaped
    // before this stack frame — and the `select`/`outcome_buf` it points
    // into — goes away, on every return path including `error.Canceled`
    // from `await` below. Safe to call more than once (e.g. after the
    // explicit calls below already ran it).
    defer select.cancelDiscard();

    select.concurrent(.fetch, fetchNtfy, .{ ntfy_client, ntfy_url, auth_value, summary }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            const result = fetchNtfy(ntfy_client, ntfy_url, auth_value, summary);
            return reportFetchResult(result);
        },
    };
    select.concurrent(.timed_out, sleepFor, .{ io, ntfy_timeout }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return reportFetchResult((try select.await()).fetch),
    };

    switch (try select.await()) {
        .fetch => |result| try reportFetchResult(result),
        .timed_out => {
            std.log.err(
                "ntfy request timed out after {d}s",
                .{@divTrunc(ntfy_timeout.nanoseconds, std.time.ns_per_s)},
            );
            return error.NtfyTimeout;
        },
    }
}

fn fetchNtfy(
    client: *http.Client,
    ntfy_url: []const u8,
    auth_value: []const u8,
    summary: Summary,
) http.Client.FetchError!http.Client.FetchResult {
    return client.fetch(.{
        .location = .{ .url = ntfy_url },
        .method = .POST,
        .payload = summary.message,
        .headers = .{ .authorization = .{ .override = auth_value } },
        .extra_headers = &.{
            .{ .name = "X-Title", .value = summary.title },
            .{ .name = "X-Priority", .value = summary.priority },
            .{ .name = "X-Tags", .value = summary.tags },
        },
    });
}

fn sleepFor(io: Io, duration: Io.Duration) void {
    // The only error is `error.Canceled`, which happens whenever the fetch
    // leg of the race wins (this task then gets reaped by `cancelDiscard`);
    // there is nothing to report.
    // ziglint-ignore: Z026
    // zlinter-disable-next-line no_swallow_error
    io.sleep(duration, .awake) catch {};
}

fn reportFetchResult(result: http.Client.FetchError!http.Client.FetchResult) !void {
    const fetch_result = try result;
    if (fetch_result.status != .ok) {
        std.log.err("ntfy responded with status {d}", .{@intFromEnum(fetch_result.status)});
        return error.NtfyRejected;
    }
}

test "reportFetchResult succeeds for a 200 response" {
    try reportFetchResult(.{ .status = .ok });
}

// Not tested here: a non-2xx status returning error.NtfyRejected. Verified
// manually instead (see PR description) — it calls std.log.err, and Zig's
// test runner fails the whole `zig build test` step ("N errors were
// logged") whenever *any* test causes an .err-level log, independent of
// that test's own pass/fail. Downgrading the log level just to make this
// path testable would lose a genuinely useful production signal (ntfy
// rejected a forward), so it isn't worth it for one unit test.

test "reportFetchResult propagates the underlying fetch error unchanged" {
    try std.testing.expectError(
        error.UnsupportedCompressionMethod,
        reportFetchResult(error.UnsupportedCompressionMethod),
    );
}

// `zig build test` only collects tests declared directly in this root file;
// tests in imported modules are otherwise never analyzed and silently never
// run. refAllDecls forces the compiler to see them.
test {
    std.testing.refAllDecls(channel);
    std.testing.refAllDecls(coolify);
    std.testing.refAllDecls(github);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(json_log);
    std.testing.refAllDecls(metrics);
}
