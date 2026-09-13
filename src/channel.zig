// Strategy interface for webhook input channels. Each channel knows which
// request it owns (method + path) and how to turn that request's body into
// the title/message/priority/tags shape ntfy needs. Adding a new source
// (GitHub, Grafana, a generic webhook, ...) means writing one more Channel
// and registering it in main.zig — the request-handling loop itself never
// changes.
const std = @import("std");

pub const Summary = struct {
    title: []const u8,
    message: []const u8,
    priority: []const u8,
    tags: []const u8,
};

pub const Channel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        matches: *const fn (ptr: *anyopaque, method: std.http.Method, target: []const u8) bool,
        summarize: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, body: []const u8) anyerror!Summary,
    };

    pub fn matches(self: Channel, method: std.http.Method, target: []const u8) bool {
        return self.vtable.matches(self.ptr, method, target);
    }

    pub fn summarize(self: Channel, arena: std.mem.Allocator, body: []const u8) !Summary {
        return self.vtable.summarize(self.ptr, arena, body);
    }
};
