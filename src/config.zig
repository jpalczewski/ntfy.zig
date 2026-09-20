// Loads the list of channels to serve from the JSON file named by
// `CONFIG_FILE`. Coolify can mount a file with inline content into the
// container (Persistent Storage -> File Mount), so a single JSON file covers
// every deployment shape and lets a channel keep its trigger and action
// (`deploy`) together in one block.
const std = @import("std");
const Io = std.Io;
const Environ = std.process.Environ;

pub const ChannelType = enum { coolify, github };

/// Tags are uppercase because std.json matches enum tags by exact name and
/// the config spells HTTP methods the usual way (`"method": "POST"`).
// zlinter-disable-next-line field_naming
pub const DeployMethod = enum { GET, POST };

/// Trigger and action in one block: when a `github` channel sees a
/// successful `workflow_run` of `workflow` on `branch`, the relay calls
/// Coolify's deploy `url` with `token`.
pub const DeployConfig = struct {
    /// Exact `workflow_run.name` to react to (e.g. "Docker build"). Needed so
    /// an unrelated workflow such as CI doesn't trigger a deploy.
    workflow: []const u8,
    branch: []const u8 = "main",
    /// Coolify deploy webhook, e.g. `https://coolify.example.com/api/v1/deploy?uuid=<uuid>`.
    url: []const u8,
    /// HTTP method for the deploy call. Newer Coolify versions answer a `GET`
    /// with 405 and require `POST`; `GET` stays the default for older ones.
    method: DeployMethod = .GET,
    /// Coolify API token with deploy permission, sent as `Authorization: Bearer`.
    token: []const u8,
};

pub const ChannelConfig = struct {
    type: ChannelType,
    /// For `coolify`, the secret path segment (`/webhook/<secret>`) — the
    /// only auth Coolify's webhook config can carry. For `github`, the
    /// HMAC-SHA256 signing secret shared with GitHub's webhook config
    /// (`X-Hub-Signature-256`); GitHub supports a real secret, so it's
    /// verified rather than embedded in the URL.
    secret: []const u8,
    ntfy_url: []const u8,
    ntfy_token: []const u8,
    /// Only valid on `github` channels.
    deploy: ?DeployConfig = null,
};

const max_config_file_bytes: usize = 64 * 1024;

/// Returned slice (and the strings it points to) are arena-owned by `arena`.
pub fn load(arena: std.mem.Allocator, io: Io, environ_map: *const Environ.Map) ![]const ChannelConfig {
    const path = environ_map.get("CONFIG_FILE") orelse return error.NoConfig;
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, Io.Limit.limited(max_config_file_bytes));
    return parseChannels(arena, bytes);
}

fn parseChannels(arena: std.mem.Allocator, bytes: []const u8) ![]const ChannelConfig {
    const Doc = struct { channels: []const ChannelConfig };
    const doc = try std.json.parseFromSliceLeaky(Doc, arena, bytes, .{});
    if (doc.channels.len == 0) return error.NoChannels;
    try validate(doc.channels);
    return doc.channels;
}

fn validate(channels: []const ChannelConfig) !void {
    for (channels, 0..) |a, i| {
        for (channels[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.secret, b.secret)) {
                std.log.warn(
                    "duplicate channel secret: two channels share the same secret, the second is unreachable",
                    .{},
                );
                return error.DuplicateSecret;
            }
        }

        const deploy = a.deploy orelse continue;
        if (a.type != .github) {
            std.log.warn("`deploy` is only supported on github channels", .{});
            return error.DeployOnNonGithubChannel;
        }
        _ = std.Uri.parse(deploy.url) catch |err| {
            std.log.warn("deploy url is not a valid URL: {t}", .{err});
            return error.InvalidDeployUrl;
        };
    }
}

fn testParse(json: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    _ = try parseChannels(arena_state.allocator(), json);
}

test "parseChannels reads a coolify channel" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const channels = try parseChannels(arena_state.allocator(),
        \\{"channels":[
        \\  {"type":"coolify","secret":"s3cr3t","ntfy_url":"https://ntfy.example.com","ntfy_token":"tk_abc"}
        \\]}
    );

    try std.testing.expectEqual(1, channels.len);
    try std.testing.expectEqual(ChannelType.coolify, channels[0].type);
    try std.testing.expectEqualStrings("s3cr3t", channels[0].secret);
    try std.testing.expectEqualStrings("https://ntfy.example.com", channels[0].ntfy_url);
    try std.testing.expectEqualStrings("tk_abc", channels[0].ntfy_token);
    try std.testing.expect(channels[0].deploy == null);
}

test "parseChannels reads several channels in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const channels = try parseChannels(arena_state.allocator(),
        \\{"channels":[
        \\  {"type":"coolify","secret":"one","ntfy_url":"https://n/one","ntfy_token":"tk_one"},
        \\  {"type":"github","secret":"two","ntfy_url":"https://n/two","ntfy_token":"tk_two"}
        \\]}
    );

    try std.testing.expectEqual(2, channels.len);
    try std.testing.expectEqualStrings("one", channels[0].secret);
    try std.testing.expectEqual(ChannelType.github, channels[1].type);
}

test "parseChannels reads a github deploy block, branch defaults to main" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const channels = try parseChannels(arena_state.allocator(),
        \\{"channels":[{"type":"github","secret":"s","ntfy_url":"https://n","ntfy_token":"t",
        \\  "deploy":{"workflow":"Docker build","token":"ck",
        \\    "url":"https://coolify.example.com/api/v1/deploy?uuid=abc"}}]}
    );

    const deploy = channels[0].deploy.?;
    try std.testing.expectEqualStrings("Docker build", deploy.workflow);
    try std.testing.expectEqualStrings("main", deploy.branch);
    try std.testing.expectEqualStrings("https://coolify.example.com/api/v1/deploy?uuid=abc", deploy.url);
    try std.testing.expectEqualStrings("ck", deploy.token);
    try std.testing.expectEqual(DeployMethod.GET, deploy.method);
}

test "parseChannels reads a deploy method of POST" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const channels = try parseChannels(arena_state.allocator(),
        \\{"channels":[{"type":"github","secret":"s","ntfy_url":"https://n","ntfy_token":"t",
        \\  "deploy":{"workflow":"w","url":"https://c/deploy","token":"k","method":"POST"}}]}
    );

    try std.testing.expectEqual(DeployMethod.POST, channels[0].deploy.?.method);
}

test "parseChannels rejects an unknown deploy method" {
    try std.testing.expectError(error.InvalidEnumTag, testParse(
        \\{"channels":[{"type":"github","secret":"s","ntfy_url":"https://n","ntfy_token":"t",
        \\  "deploy":{"workflow":"w","url":"https://c/deploy","token":"k","method":"PATCH"}}]}
    ));
}

test "parseChannels rejects a lowercase deploy method" {
    try std.testing.expectError(error.InvalidEnumTag, testParse(
        \\{"channels":[{"type":"github","secret":"s","ntfy_url":"https://n","ntfy_token":"t",
        \\  "deploy":{"workflow":"w","url":"https://c/deploy","token":"k","method":"post"}}]}
    ));
}

test "parseChannels rejects a deploy block missing its token" {
    try std.testing.expectError(error.MissingField, testParse(
        \\{"channels":[{"type":"github","secret":"s","ntfy_url":"https://n","ntfy_token":"t",
        \\  "deploy":{"workflow":"w","url":"https://c/deploy"}}]}
    ));
}

test "parseChannels rejects a misspelled deploy field" {
    try std.testing.expectError(error.UnknownField, testParse(
        \\{"channels":[{"type":"github","secret":"s","ntfy_url":"https://n","ntfy_token":"t",
        \\  "deploy":{"workflow":"w","brnach":"main","url":"https://c/deploy","token":"k"}}]}
    ));
}

test "parseChannels rejects deploy on a coolify channel" {
    try std.testing.expectError(error.DeployOnNonGithubChannel, testParse(
        \\{"channels":[{"type":"coolify","secret":"s","ntfy_url":"https://n","ntfy_token":"t",
        \\  "deploy":{"workflow":"w","url":"https://c/deploy","token":"k"}}]}
    ));
}

test "parseChannels rejects an unparseable deploy url" {
    try std.testing.expectError(error.InvalidDeployUrl, testParse(
        \\{"channels":[{"type":"github","secret":"s","ntfy_url":"https://n","ntfy_token":"t",
        \\  "deploy":{"workflow":"w","url":"not a url","token":"k"}}]}
    ));
}

test "parseChannels rejects an unknown channel type" {
    try std.testing.expectError(error.InvalidEnumTag, testParse(
        \\{"channels":[{"type":"made_up","secret":"s","ntfy_url":"https://n","ntfy_token":"t"}]}
    ));
}

test "parseChannels rejects two channels sharing a secret" {
    try std.testing.expectError(error.DuplicateSecret, testParse(
        \\{"channels":[
        \\  {"type":"coolify","secret":"shared","ntfy_url":"https://n/one","ntfy_token":"a"},
        \\  {"type":"coolify","secret":"shared","ntfy_url":"https://n/two","ntfy_token":"b"}
        \\]}
    ));
}

test "parseChannels rejects an empty channel list" {
    try std.testing.expectError(error.NoChannels, testParse("{\"channels\":[]}"));
}
