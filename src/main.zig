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
const config = @import("config.zig");

const listen_port: u16 = 8085;
const max_body_bytes: usize = 64 * 1024;

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
        };
        try routes.append(gpa, .{
            .channel = route_channel,
            .ntfy_url = cc.ntfy_url,
            .ntfy_token = cc.ntfy_token,
        });
    }

    var address = try net.IpAddress.parseIp4("0.0.0.0", listen_port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("ntfy.zig listening on :{d} with {d} channel(s)", .{ listen_port, routes.items.len });

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {t}", .{err});
            continue;
        };
        handleConnection(gpa, io, stream, routes.items) catch |err| {
            std.log.err("connection error: {t}", .{err});
        };
    }
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
            .location = .{ .url = "http://127.0.0.1:" ++ std.fmt.comptimePrint("{d}", .{listen_port}) ++ "/health" },
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
) !void {
    var stream = stream_in;
    defer stream.close(io);

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [8192]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    var request = server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };

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
            try request.respond("bad request", .{ .status = .bad_request, .keep_alive = false });
            return err;
        };
        break :blk body_reader.allocRemaining(gpa, Io.Limit.limited(max_body_bytes)) catch {
            try request.respond("payload too large", .{ .status = .payload_too_large, .keep_alive = false });
            return;
        };
    } else &.{};
    defer if (has_framed_body) gpa.free(body);

    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/health")) {
        try request.respond("ok", .{ .status = .ok, .keep_alive = false });
        return;
    }

    const matched: ?Route = for (routes) |r| {
        if (r.channel.matches(request.head.method, request.head.target)) break r;
    } else null;

    const route = matched orelse {
        try request.respond("not found", .{ .status = .not_found, .keep_alive = false });
        return;
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary = route.channel.summarize(arena, body) catch |err| blk: {
        std.log.warn("failed to parse webhook payload: {t}", .{err});
        break :blk Summary{
            .title = "ntfy.zig",
            .message = body,
            .priority = "3",
            .tags = "warning",
        };
    };

    forwardToNtfy(gpa, io, route.ntfy_url, route.ntfy_token, summary) catch |err| {
        std.log.err("failed to forward to ntfy: {t}", .{err});
    };

    try request.respond("ok", .{ .status = .ok, .keep_alive = false });
}

fn forwardToNtfy(gpa: std.mem.Allocator, io: Io, ntfy_url: []const u8, ntfy_token: []const u8, summary: Summary) !void {
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const auth_value = try std.fmt.allocPrint(gpa, "Bearer {s}", .{ntfy_token});
    defer gpa.free(auth_value);

    const result = try client.fetch(.{
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

    if (result.status != .ok) {
        std.log.err("ntfy responded with status {d}", .{@intFromEnum(result.status)});
    }
}

// `zig build test` only collects tests declared directly in this root file;
// tests in imported modules are otherwise never analyzed and silently never
// run. refAllDecls forces the compiler to see them.
test {
    std.testing.refAllDecls(channel);
    std.testing.refAllDecls(coolify);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(json_log);
}
