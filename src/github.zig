// Reshapes GitHub webhook events into a title/message/priority/tags tuple
// ready to forward to ntfy. Unlike Coolify, GitHub webhooks carry a real
// shared secret: it signs each delivery with HMAC-SHA256 in the
// `X-Hub-Signature-256` header, so this channel verifies that signature
// instead of relying on a secret-in-URL. The event type isn't in the JSON
// body (GitHub has dozens of incompatible payload shapes) — it's in the
// `X-GitHub-Event` header instead, which is why `Channel.summarize` needs
// access to the request's raw headers.
//
// v1 only acts on `workflow_run` (GitHub Actions) and `deployment_status`
// (Deployments); every other event type, and non-terminal states of those
// two, resolve to `error.Ignored` so a webhook subscribed to "everything"
// doesn't spam ntfy.
//
// A successful `workflow_run` that matches the channel's `deploy` block
// (workflow name + branch) also sets `Summary.deploy`, which is what makes
// main.zig call Coolify's deploy webhook.
const std = @import("std");
const chan = @import("channel.zig");
const Channel = chan.Channel;
const Summary = chan.Summary;
const config = @import("config.zig");

pub const Github = struct {
    target_path: []const u8,
    secret: []const u8,
    deploy: ?config.DeployConfig,

    /// The route path is derived from `secret` (first 8 bytes of its
    /// SHA-256 digest, hex-encoded) rather than being the secret itself —
    /// the whole point of HMAC auth is that the secret never has to appear
    /// in a URL (and therefore in server/proxy logs). The derived path is
    /// logged at startup so it can be pasted into GitHub's webhook config.
    pub fn init(gpa: std.mem.Allocator, secret: []const u8, deploy: ?config.DeployConfig) !Github {
        var digest_buf: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(secret, &digest_buf, .{});
        const hex = std.fmt.bytesToHex(digest_buf[0..8].*, .lower);
        return .{
            .target_path = try std.fmt.allocPrint(gpa, "/webhook/github/{s}", .{&hex}),
            .secret = secret,
            .deploy = deploy,
        };
    }

    pub fn channel(self: *const Github) Channel {
        return .{ .ptr = @constCast(self), .vtable = &vtable };
    }

    const vtable: Channel.VTable = .{
        .matches = matches,
        .summarize = summarizeImpl,
    };

    fn matches(ptr: *anyopaque, method: std.http.Method, target: []const u8) bool {
        const self: *const Github = @ptrCast(@alignCast(ptr));
        return method == .POST and std.mem.eql(u8, target, self.target_path);
    }

    fn summarizeImpl(
        ptr: *anyopaque,
        // ziglint-ignore: Z023 (ptr must stay first to match Channel.VTable's fn-ptr signature)
        arena: std.mem.Allocator,
        body: []const u8,
        raw_headers: []const u8,
    ) anyerror!Summary {
        const self: *const Github = @ptrCast(@alignCast(ptr));

        const signature = chan.findHeader(raw_headers, "X-Hub-Signature-256") orelse
            return error.InvalidSignature;
        if (!verifySignature(body, self.secret, signature)) return error.InvalidSignature;

        const event = chan.findHeader(raw_headers, "X-GitHub-Event") orelse
            return error.Ignored;
        return summarize(arena, event, body, self.deploy);
    }
};

fn verifySignature(body: []const u8, secret: []const u8, header_value: []const u8) bool {
    const prefix = "sha256=";
    if (!std.mem.startsWith(u8, header_value, prefix)) return false;
    const hex_sig = header_value[prefix.len..];
    if (hex_sig.len != 64) return false; // must decode to exactly 32 bytes, see `expected_buf`

    var expected_buf: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_buf, hex_sig) catch return false;

    var actual_buf: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&actual_buf, body, secret);

    return std.crypto.timing_safe.eql([32]u8, expected_buf, actual_buf);
}

pub fn summarize(
    arena: std.mem.Allocator,
    event: []const u8,
    body: []const u8,
    deploy: ?config.DeployConfig,
) !Summary {
    if (std.mem.eql(u8, event, "ping")) return .{
        .title = "GitHub",
        .message = "Webhook connected",
        .priority = "1",
        .tags = "handshake",
    };
    if (std.mem.eql(u8, event, "workflow_run")) return summarizeWorkflowRun(arena, body, deploy);
    if (std.mem.eql(u8, event, "deployment_status")) return summarizeDeploymentStatus(arena, body);
    return error.Ignored;
}

fn summarizeWorkflowRun(arena: std.mem.Allocator, body: []const u8, deploy: ?config.DeployConfig) !Summary {
    const obj = try parseObject(arena, body);

    const action = getString(obj, "action") orelse "";
    if (!std.mem.eql(u8, action, "completed")) return error.Ignored;

    const run = try getObject(obj, "workflow_run");
    const name = getString(run, "display_title") orelse getString(run, "name") orelse "workflow";
    const conclusion = getString(run, "conclusion") orelse "unknown";
    const branch = getString(run, "head_branch");
    const repo_name = getRepoFullName(obj);

    var msg_buf = std.ArrayList(u8).empty;
    try msg_buf.appendSlice(arena, name);
    try msg_buf.appendSlice(arena, " — ");
    try msg_buf.appendSlice(arena, conclusion);
    if (branch) |b| {
        try msg_buf.appendSlice(arena, "\nBranch: ");
        try msg_buf.appendSlice(arena, b);
    }

    const succeeded = std.mem.eql(u8, conclusion, "success");
    var summary = buildSummary(repo_name orelse "GitHub Actions", msg_buf.items, succeeded);
    summary.deploy = succeeded and matchesDeploy(deploy, getString(run, "name"), branch);
    return summary;
}

fn matchesDeploy(deploy: ?config.DeployConfig, workflow: ?[]const u8, branch: ?[]const u8) bool {
    const rule = deploy orelse return false;
    return std.mem.eql(u8, rule.workflow, workflow orelse return false) and
        std.mem.eql(u8, rule.branch, branch orelse return false);
}

fn summarizeDeploymentStatus(arena: std.mem.Allocator, body: []const u8) !Summary {
    const obj = try parseObject(arena, body);

    const status = try getObject(obj, "deployment_status");
    const state = getString(status, "state") orelse "unknown";
    if (std.mem.eql(u8, state, "pending") or
        std.mem.eql(u8, state, "in_progress") or
        std.mem.eql(u8, state, "queued")) return error.Ignored;

    const description = getString(status, "description");
    const deployment = try getObject(obj, "deployment");
    const environment = getString(deployment, "environment") orelse getString(status, "environment");
    const repo_name = getRepoFullName(obj);

    var msg_buf = std.ArrayList(u8).empty;
    try msg_buf.appendSlice(arena, "Deployment");
    if (environment) |e| {
        try msg_buf.appendSlice(arena, " to ");
        try msg_buf.appendSlice(arena, e);
    }
    try msg_buf.appendSlice(arena, ": ");
    try msg_buf.appendSlice(arena, state);
    if (description) |d| {
        try msg_buf.appendSlice(arena, "\n");
        try msg_buf.appendSlice(arena, d);
    }

    return buildSummary(repo_name orelse "GitHub Deployments", msg_buf.items, std.mem.eql(u8, state, "success"));
}

fn buildSummary(title: []const u8, message: []const u8, success: bool) Summary {
    return .{
        .title = title,
        .message = message,
        .priority = if (success) "3" else "5",
        .tags = if (success) "white_check_mark" else "x",
    };
}

fn parseObject(arena: std.mem.Allocator, body: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return switch (parsed) {
        .object => |o| o,
        else => error.UnexpectedJson,
    };
}

fn getObject(obj: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const field = obj.get(key) orelse return error.UnexpectedJson;
    return switch (field) {
        .object => |o| o,
        else => error.UnexpectedJson,
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const field = obj.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

fn getRepoFullName(obj: std.json.ObjectMap) ?[]const u8 {
    const repo = obj.get("repository") orelse return null;
    return switch (repo) {
        .object => |o| getString(o, "full_name"),
        else => null,
    };
}

fn testHeaders(buf: []u8, signature: []const u8, event: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "POST /webhook/github/abcd HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "X-GitHub-Event: {s}\r\n" ++
            "X-Hub-Signature-256: {s}\r\n" ++
            "\r\n",
        .{ event, signature },
    );
}

fn hexSignature(body: []const u8, secret: []const u8) [71]u8 {
    var mac_buf: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac_buf, body, secret);
    const hex = std.fmt.bytesToHex(mac_buf, .lower);
    var out_buf: [71]u8 = undefined;
    @memcpy(out_buf[0..7], "sha256=");
    @memcpy(out_buf[7..], &hex);
    return out_buf;
}

test "verifySignature accepts a correctly computed HMAC" {
    const secret = "s3cr3t";
    const body = "{\"hello\":\"world\"}";
    const sig = hexSignature(body, secret);

    try std.testing.expect(verifySignature(body, secret, &sig));
}

test "verifySignature rejects a tampered body" {
    const secret = "s3cr3t";
    const sig = hexSignature("{\"hello\":\"world\"}", secret);

    try std.testing.expect(!verifySignature("{\"hello\":\"tampered\"}", secret, &sig));
}

test "verifySignature rejects a signature with the wrong secret" {
    const body = "{\"hello\":\"world\"}";
    const sig = hexSignature(body, "s3cr3t");

    try std.testing.expect(!verifySignature(body, "wrong secret", &sig));
}

test "verifySignature rejects a malformed header" {
    try std.testing.expect(!verifySignature("body", "secret", "not-a-signature"));
}

test "matches only the derived path with POST" {
    var impl = try Github.init(std.testing.allocator, "s3cr3t", null);
    defer std.testing.allocator.free(impl.target_path);
    const c = impl.channel();

    try std.testing.expect(c.matches(.POST, impl.target_path));
    try std.testing.expect(!c.matches(.GET, impl.target_path));
    try std.testing.expect(!c.matches(.POST, "/webhook/github/wrong"));
}

test "summarize: workflow_run completed success" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary = try summarize(arena, "workflow_run",
        \\{"action":"completed","workflow_run":{"display_title":"CI","conclusion":"success","head_branch":"main"},
        \\ "repository":{"full_name":"acme/api"}}
    , null);

    try std.testing.expectEqualStrings("acme/api", summary.title);
    try std.testing.expectEqualStrings("CI — success\nBranch: main", summary.message);
    try std.testing.expectEqualStrings("3", summary.priority);
    try std.testing.expectEqualStrings("white_check_mark", summary.tags);
}

test "summarize: workflow_run completed failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary = try summarize(arena, "workflow_run",
        \\{"action":"completed","workflow_run":{"display_title":"CI","conclusion":"failure","head_branch":"main"},
        \\ "repository":{"full_name":"acme/api"}}
    , null);

    try std.testing.expectEqualStrings("5", summary.priority);
    try std.testing.expectEqualStrings("x", summary.tags);
}

test "summarize: workflow_run in_progress is ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Ignored, summarize(arena, "workflow_run",
        \\{"action":"in_progress","workflow_run":{"conclusion":null},"repository":{"full_name":"acme/api"}}
    , null));
}

test "summarize: deployment_status success" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary = try summarize(arena, "deployment_status",
        \\{"deployment_status":{"state":"success","description":"all good"},
        \\ "deployment":{"environment":"production"},"repository":{"full_name":"acme/api"}}
    , null);

    try std.testing.expectEqualStrings("acme/api", summary.title);
    try std.testing.expectEqualStrings("Deployment to production: success\nall good", summary.message);
    try std.testing.expectEqualStrings("3", summary.priority);
}

test "summarize: deployment_status pending is ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Ignored, summarize(arena, "deployment_status",
        \\{"deployment_status":{"state":"pending"},"deployment":{"environment":"production"}}
    , null));
}

test "summarize: ping is a friendly confirmation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary = try summarize(arena, "ping", "{}", null);

    try std.testing.expectEqualStrings("GitHub", summary.title);
    try std.testing.expectEqualStrings("Webhook connected", summary.message);
}

test "summarize: unrecognized event is ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Ignored, summarize(arena, "star", "{}", null));
}

test "full request: valid signature and event dispatch through the vtable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var impl = try Github.init(std.testing.allocator, "s3cr3t", null);
    defer std.testing.allocator.free(impl.target_path);
    const c = impl.channel();

    const body =
        \\{"action":"completed","workflow_run":{"display_title":"CI","conclusion":"success"},
        \\ "repository":{"full_name":"acme/api"}}
    ;
    const sig = hexSignature(body, "s3cr3t");
    var header_buf: [256]u8 = undefined;
    const headers = try testHeaders(&header_buf, &sig, "workflow_run");

    const summary = try c.summarize(arena, body, headers);
    try std.testing.expectEqualStrings("acme/api", summary.title);
}

test "full request: invalid signature is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var impl = try Github.init(std.testing.allocator, "s3cr3t", null);
    defer std.testing.allocator.free(impl.target_path);
    const c = impl.channel();

    const body = "{}";
    var header_buf: [256]u8 = undefined;
    const headers = try testHeaders(&header_buf, "sha256=" ++ "0" ** 64, "ping");

    try std.testing.expectError(error.InvalidSignature, c.summarize(arena, body, headers));
}

const test_deploy: config.DeployConfig = .{
    .workflow = "Docker build",
    .url = "https://coolify.example.com/api/v1/deploy?uuid=abc",
    .token = "ck",
};

fn testWorkflowRun(buf: []u8, name: []const u8, branch: []const u8, conclusion: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"action\":\"completed\",\"workflow_run\":{{\"name\":\"{s}\",\"display_title\":\"x\"," ++
            "\"conclusion\":\"{s}\",\"head_branch\":\"{s}\"}},\"repository\":{{\"full_name\":\"acme/api\"}}}}",
        .{ name, conclusion, branch },
    );
}

test "deploy: matching workflow, branch and success sets summary.deploy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [512]u8 = undefined;

    const body = try testWorkflowRun(&buf, "Docker build", "main", "success");
    const summary = try summarize(arena_state.allocator(), "workflow_run", body, test_deploy);

    try std.testing.expect(summary.deploy);
}

test "deploy: no deploy block never triggers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [512]u8 = undefined;

    const body = try testWorkflowRun(&buf, "Docker build", "main", "success");
    const summary = try summarize(arena_state.allocator(), "workflow_run", body, null);

    try std.testing.expect(!summary.deploy);
}

test "deploy: other workflow, other branch or failure do not trigger" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [512]u8 = undefined;

    const cases = [_]struct { name: []const u8, branch: []const u8, conclusion: []const u8 }{
        .{ .name = "CI", .branch = "main", .conclusion = "success" },
        .{ .name = "Docker build", .branch = "feature", .conclusion = "success" },
        .{ .name = "Docker build", .branch = "main", .conclusion = "failure" },
    };
    for (cases) |c| {
        const body = try testWorkflowRun(&buf, c.name, c.branch, c.conclusion);
        const summary = try summarize(arena_state.allocator(), "workflow_run", body, test_deploy);
        try std.testing.expect(!summary.deploy);
    }
}
