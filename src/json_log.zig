// One JSON object per line on stderr instead of std.log's default
// "level: message" text, so log aggregators (Coolify's own log viewer,
// journald, etc.) can parse fields instead of grepping strings.
const std = @import("std");

pub fn jsonLog(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.default),
    comptime format: []const u8,
    args: anytype,
) void {
    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, format, args) catch &msg_buf;

    var stderr_buf: [1024]u8 = undefined;
    const locked = std.debug.lockStderr(&stderr_buf);
    defer std.debug.unlockStderr();

    // A failed log write must not crash the program, so drop the error.
    // ziglint-ignore: Z026
    // zlinter-disable-next-line no_swallow_error
    writeLine(&locked.file_writer.interface, message_level.asText(), @tagName(scope), msg) catch {};
}

fn writeLine(w: *std.Io.Writer, level: []const u8, scope: []const u8, msg: []const u8) !void {
    try w.print("{{\"level\":\"{s}\",\"scope\":\"{s}\",\"msg\":", .{ level, scope });
    try std.json.Stringify.encodeJsonString(msg, .{}, w);
    try w.writeAll("}\n");
}

test "writeLine escapes the message and keeps level/scope verbatim" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeLine(&writer, "error", "default", "boom: \"quoted\"\nline two");
    try std.testing.expectEqualStrings(
        "{\"level\":\"error\",\"scope\":\"default\",\"msg\":\"boom: \\\"quoted\\\"\\nline two\"}\n",
        writer.buffered(),
    );
}
