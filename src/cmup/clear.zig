const std = @import("std");

pub fn clearPlaylists(init: std.process.Init, path: []const u8) !void {
    var dir = try std.Io.Dir.openDirAbsolute(init.io, path, .{ .iterate = true });
    defer dir.close(init.io);

    var iter = dir.iterate();

    while (try iter.next(init.io)) |file| {
        try dir.deleteFile(init.io, file.name);
    }
}
