// Reshapes Coolify's fixed webhook JSON schema (`event`, `message`,
// `success`, `application_name`, `project`, `environment`, ...) into a
// title/message/priority/tags tuple ready to forward to ntfy.
//
// Auth for this channel is a secret path segment (/webhook/<secret>) since
// Coolify's webhook config has nowhere to put a header or query param
// either.
const std = @import("std");
const channel = @import("channel.zig");
const Channel = channel.Channel;
const Summary = channel.Summary;

pub const Coolify = struct {
    target_path: []const u8,

    pub fn init(gpa: std.mem.Allocator, secret: []const u8) !Coolify {
        return .{ .target_path = try std.fmt.allocPrint(gpa, "/webhook/{s}", .{secret}) };
    }

    pub fn deinit(self: Coolify, gpa: std.mem.Allocator) void {
        gpa.free(self.target_path);
    }

    pub fn channel(self: *const Coolify) Channel {
        return .{ .ptr = @constCast(self), .vtable = &vtable };
    }

    const vtable: Channel.VTable = .{
        .matches = matches,
        .summarize = summarizeImpl,
    };

    fn matches(ptr: *anyopaque, method: std.http.Method, target: []const u8) bool {
        const self: *const Coolify = @ptrCast(@alignCast(ptr));
        return method == .POST and std.mem.eql(u8, target, self.target_path);
    }

    fn summarizeImpl(
        ptr: *anyopaque,
        // ziglint-ignore: Z023 (ptr must stay first to match Channel.VTable's fn-ptr signature)
        arena: std.mem.Allocator,
        body: []const u8,
        raw_headers: []const u8,
    ) anyerror!Summary {
        _ = ptr;
        _ = raw_headers;
        return summarize(arena, body);
    }
};

pub fn summarize(arena: std.mem.Allocator, body: []const u8) !Summary {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.UnexpectedJson,
    };

    const event = getString(obj, "event") orelse "event";
    const message = getString(obj, "message") orelse event;
    const app_name = getString(obj, "application_name");
    const project = getString(obj, "project");
    const environment = getString(obj, "environment");
    const success = if (obj.get("success")) |v| switch (v) {
        .bool => |b| b,
        else => null,
    } else null;

    var title_buf = std.ArrayList(u8).empty;
    if (project) |p| {
        try title_buf.appendSlice(arena, p);
        if (app_name) |a| {
            try title_buf.appendSlice(arena, " / ");
            try title_buf.appendSlice(arena, a);
        }
    } else if (app_name) |a| {
        try title_buf.appendSlice(arena, a);
    } else {
        try title_buf.appendSlice(arena, "Coolify");
    }

    var msg_buf = std.ArrayList(u8).empty;
    try msg_buf.appendSlice(arena, message);
    if (environment) |e| {
        try msg_buf.appendSlice(arena, "\nEnvironment: ");
        try msg_buf.appendSlice(arena, e);
    }

    return .{
        .title = title_buf.items,
        .message = msg_buf.items,
        .priority = if (success == false) "5" else "3",
        .tags = if (success == false) "x" else "white_check_mark",
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const field = obj.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

test "full payload: project, app, environment and a failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary = try summarize(arena,
        \\{"event":"deployment","message":"Deploy failed","application_name":"api",
        \\ "project":"acme","environment":"production","success":false}
    );

    try std.testing.expectEqualStrings("acme / api", summary.title);
    try std.testing.expectEqualStrings("Deploy failed\nEnvironment: production", summary.message);
    try std.testing.expectEqualStrings("5", summary.priority);
    try std.testing.expectEqualStrings("x", summary.tags);
}

test "minimal payload falls back to defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary = try summarize(arena, "{}");

    try std.testing.expectEqualStrings("Coolify", summary.title);
    try std.testing.expectEqualStrings("event", summary.message);
    try std.testing.expectEqualStrings("3", summary.priority);
    try std.testing.expectEqualStrings("white_check_mark", summary.tags);
}

test "success payload uses the low-priority tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary = try summarize(arena, "{\"message\":\"Deploy finished\",\"success\":true}");

    try std.testing.expectEqualStrings("3", summary.priority);
    try std.testing.expectEqualStrings("white_check_mark", summary.tags);
}

test "non-object JSON is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.UnexpectedJson, summarize(arena, "[1,2,3]"));
}

test "invalid JSON is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.SyntaxError, summarize(arena, "not json"));
}
