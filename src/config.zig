// Loads the list of channels to serve from either a JSON config file or
// numbered environment variables. Two loaders, one model (`ChannelConfig`):
// a JSON file scales better once there are several channels, but Coolify's
// own UI only offers env vars, so both stay supported rather than picking
// one and forcing a workaround for the other.
const std = @import("std");
const Io = std.Io;
const Environ = std.process.Environ;

pub const ChannelType = enum { coolify };

pub const ChannelConfig = struct {
    type: ChannelType,
    secret: []const u8,
    ntfy_url: []const u8,
    ntfy_token: []const u8,
};

const max_config_file_bytes: usize = 64 * 1024;

/// Returned slice (and the strings it points to) are arena-owned by `arena`.
pub fn load(arena: std.mem.Allocator, io: Io, environ_map: *const Environ.Map) ![]const ChannelConfig {
    if (environ_map.get("CONFIG_FILE")) |path| {
        return loadFromFile(arena, io, path);
    }
    if (environ_map.get("CHANNEL_1_TYPE") != null) {
        return loadFromEnv(arena, environ_map);
    }
    return error.NoConfig;
}

fn loadFromFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const ChannelConfig {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, Io.Limit.limited(max_config_file_bytes));

    const Doc = struct { channels: []const ChannelConfig };
    const doc = try std.json.parseFromSliceLeaky(Doc, arena, bytes, .{});
    if (doc.channels.len == 0) return error.NoChannels;
    try checkDuplicateSecrets(doc.channels);
    return doc.channels;
}

fn loadFromEnv(arena: std.mem.Allocator, environ_map: *const Environ.Map) ![]const ChannelConfig {
    var channels = std.ArrayList(ChannelConfig).empty;

    var i: usize = 1;
    while (true) : (i += 1) {
        const type_key = try std.fmt.allocPrint(arena, "CHANNEL_{d}_TYPE", .{i});
        const type_str = environ_map.get(type_key) orelse break;

        const channel_type = std.meta.stringToEnum(ChannelType, type_str) orelse {
            std.log.warn("{s}={s} is not a known channel type", .{ type_key, type_str });
            return error.UnknownChannelType;
        };

        try channels.append(arena, .{
            .type = channel_type,
            .secret = try requireIndexedEnv(arena, environ_map, "SECRET", i),
            .ntfy_url = try requireIndexedEnv(arena, environ_map, "NTFY_URL", i),
            .ntfy_token = try requireIndexedEnv(arena, environ_map, "NTFY_TOKEN", i),
        });
    }

    try checkDuplicateSecrets(channels.items);
    return channels.items;
}

fn requireIndexedEnv(
    arena: std.mem.Allocator,
    environ_map: *const Environ.Map,
    name: []const u8,
    index: usize,
) ![]const u8 {
    const key = try std.fmt.allocPrint(arena, "CHANNEL_{d}_{s}", .{ index, name });
    return environ_map.get(key) orelse {
        std.log.warn("{s} not set", .{key});
        return error.MissingEnvVar;
    };
}

fn checkDuplicateSecrets(channels: []const ChannelConfig) !void {
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
    }
}

test "loadFromEnv reads a single channel" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map = Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("CHANNEL_1_TYPE", "coolify");
    try map.put("CHANNEL_1_SECRET", "s3cr3t");
    try map.put("CHANNEL_1_NTFY_URL", "https://ntfy.example.com");
    try map.put("CHANNEL_1_NTFY_TOKEN", "tk_abc");

    const channels = try loadFromEnv(arena, &map);

    try std.testing.expectEqual(1, channels.len);
    try std.testing.expectEqual(ChannelType.coolify, channels[0].type);
    try std.testing.expectEqualStrings("s3cr3t", channels[0].secret);
    try std.testing.expectEqualStrings("https://ntfy.example.com", channels[0].ntfy_url);
    try std.testing.expectEqualStrings("tk_abc", channels[0].ntfy_token);
}

test "loadFromEnv reads multiple channels until the sequence breaks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map = Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("CHANNEL_1_TYPE", "coolify");
    try map.put("CHANNEL_1_SECRET", "one");
    try map.put("CHANNEL_1_NTFY_URL", "https://ntfy.example.com/one");
    try map.put("CHANNEL_1_NTFY_TOKEN", "tk_one");
    try map.put("CHANNEL_2_TYPE", "coolify");
    try map.put("CHANNEL_2_SECRET", "two");
    try map.put("CHANNEL_2_NTFY_URL", "https://ntfy.example.com/two");
    try map.put("CHANNEL_2_NTFY_TOKEN", "tk_two");

    const channels = try loadFromEnv(arena, &map);

    try std.testing.expectEqual(2, channels.len);
    try std.testing.expectEqualStrings("one", channels[0].secret);
    try std.testing.expectEqualStrings("two", channels[1].secret);
}

test "loadFromEnv fails when a sibling var is missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map = Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("CHANNEL_1_TYPE", "coolify");
    try map.put("CHANNEL_1_SECRET", "s3cr3t");

    try std.testing.expectError(error.MissingEnvVar, loadFromEnv(arena, &map));
}

test "loadFromEnv rejects an unknown channel type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map = Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("CHANNEL_1_TYPE", "made_up");

    try std.testing.expectError(error.UnknownChannelType, loadFromEnv(arena, &map));
}

test "loadFromEnv rejects two channels sharing a secret" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map = Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("CHANNEL_1_TYPE", "coolify");
    try map.put("CHANNEL_1_SECRET", "shared");
    try map.put("CHANNEL_1_NTFY_URL", "https://ntfy.example.com/one");
    try map.put("CHANNEL_1_NTFY_TOKEN", "tk_one");
    try map.put("CHANNEL_2_TYPE", "coolify");
    try map.put("CHANNEL_2_SECRET", "shared");
    try map.put("CHANNEL_2_NTFY_URL", "https://ntfy.example.com/two");
    try map.put("CHANNEL_2_NTFY_TOKEN", "tk_two");

    try std.testing.expectError(error.DuplicateSecret, loadFromEnv(arena, &map));
}

test "loadFromFile parses a JSON document" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Doc = struct { channels: []const ChannelConfig };
    const doc = try std.json.parseFromSliceLeaky(Doc, arena,
        \\{"channels":[
        \\  {"type":"coolify","secret":"s3cr3t","ntfy_url":"https://ntfy.example.com","ntfy_token":"tk_abc"}
        \\]}
    , .{});

    try std.testing.expectEqual(1, doc.channels.len);
    try std.testing.expectEqual(ChannelType.coolify, doc.channels[0].type);
    try std.testing.expectEqualStrings("s3cr3t", doc.channels[0].secret);
}
