// TODO: fully refactor cmup

const std = @import("std");
const fmts = @import("../utils/fmts.zig");
const path_utils = @import("../utils/path.zig");

pub const CmupPlaylist = struct {
    name: []const u8,
    content: [][]const u8,
    path: []const u8,
    sub_playlists: []*CmupPlaylist,
};

const PlaylistContent = struct {
    items: [][]const u8,
    sub_playlists: []*CmupPlaylist,
};

const cmup_used_music_extensions: []const []const u8 = &[_][]const u8{
    "flac",
    "mp3",
    "opus",
    "webm",
};

const reset = "\x1b[0m";
const yellow = "\x1b[33m";
const green = "\x1b[32m";
const red = "\x1b[31m";

pub fn isMusic(file_name: []const u8) bool {
    for (cmup_used_music_extensions) |ext| {
        if (file_name.len <= ext.len) {
            return false;
        }

        if (std.ascii.endsWithIgnoreCase(file_name, ext)) {
            return true;
        }
    }

    return false;
}

pub const ZqlSrc = struct {
    src: []const u8,
    parent_name: []const u8,
};

pub fn isZql(file_name: []const u8) bool {
    const zql_ext = comptime ".zql";

    if (file_name.len <= zql_ext.len) {
        return false;
    }

    if (std.ascii.endsWithIgnoreCase(file_name, zql_ext)) {
        return true;
    }

    return false;
}

pub fn getDirEntryNames(io: std.Io, allocator: std.mem.Allocator, path: []const u8) anyerror!std.ArrayList([]const u8) {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();

    var result: std.ArrayList([]const u8) = .empty;

    while (try iterator.next(io)) |value| {
        switch (value.kind) {
            .directory => try result.append(allocator, try allocator.dupe(u8, value.name)),
            else => try printUnsuportedEntryError(io, allocator, value.name),
        }
    }

    return result;
}

pub fn addMusicToPlaylist(
    allocator: std.mem.Allocator,
    path: []const u8,
    result: *std.ArrayList([]const u8),
    zql_result: *std.ArrayList(ZqlSrc),
    entry: std.Io.Dir.Entry,
    playlist_name: []const u8,
) !void {
    const file_path = try std.fs.path.join(allocator, &.{ path, entry.name });

    if (isMusic(entry.name)) {
        try result.append(allocator, file_path);
        return;
    }

    if (isZql(entry.name)) {
        try zql_result.append(allocator, ZqlSrc{
            .src = file_path,
            .parent_name = playlist_name,
        });
    }
}

pub fn printUnsuportedEntryError(io: std.Io, allocator: std.mem.Allocator, name: []const u8) !void {
    if (std.mem.eql(u8, name, "zchat")) {
        return;
    }

    var buf: [256]u8 = .{0} ** 256;
    var writer = std.Io.File.stderr().writer(io, &buf).interface;

    const fmt = try std.fmt.allocPrint(allocator, fmts.zmup_warn_fmt ++ "Unknown entry format at {s}\n", .{name});

    try writer.writeAll(fmt);
}

pub fn endsWithDollar(string: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path_utils.getFileNameWithoutExtension(string), "$");
}

pub fn createCmusSubPlaylist(
    io: std.Io,
    allocator: std.mem.Allocator,
    ptrs: *std.ArrayList(*CmupPlaylist),
    cmus_path: []const u8,
    parent_path: []const u8,
    name: []const u8,
    zql_paths: *std.ArrayList(ZqlSrc),
) anyerror!void {
    const playlist = try allocator.create(CmupPlaylist);

    playlist.* = try createCmupPlaylist(
        io,
        allocator,
        try allocator.dupe(u8, name),
        cmus_path,
        parent_path,
        zql_paths,
    );

    try ptrs.append(allocator, playlist);
}

pub fn readCmupPlaylist(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    cmus_path: []const u8,
    zql_paths: *std.ArrayList(ZqlSrc),
    playlist_name: []const u8,
) anyerror!PlaylistContent {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    var iterator = dir.iterate();

    var ptrs: std.ArrayList(*CmupPlaylist) = .empty;

    var result: std.ArrayList([]const u8) = .empty;

    while (try iterator.next(io)) |item| {
        try switch (item.kind) {
            .file, .sym_link => addMusicToPlaylist(allocator, path, &result, zql_paths, item, playlist_name),
            .directory => createCmusSubPlaylist(io, allocator, &ptrs, cmus_path, path, item.name, zql_paths),
            else => printUnsuportedEntryError(io, allocator, item.name),
        };
    }

    return PlaylistContent{
        .items = result.items,
        .sub_playlists = ptrs.items,
    };
}

pub fn removeLast(string: []const u8) []const u8 {
    return string[0 .. string.len - 1];
}

pub fn formatSubPlaylist(allocator: std.mem.Allocator, parent_name: []const u8, child: []const u8) ![]const u8 {
    return try std.mem.join(allocator, "-", &[_][]const u8{ parent_name, child });
}

pub fn expandDollar(allocator: std.mem.Allocator, path: []const u8, entry: []const u8) anyerror![]const u8 {
    return try formatSubPlaylist(allocator, std.fs.path.basename(path), entry);
}

pub fn createCmupPlaylist(
    io: std.Io,
    allocator: std.mem.Allocator,
    entry: []const u8,
    cmus_path: []const u8,
    cmus_parent_path: ?[]const u8,
    zql_paths: *std.ArrayList(ZqlSrc),
) anyerror!CmupPlaylist {
    const is_dollared = endsWithDollar(entry);

    const true_name = if (is_dollared) try expandDollar(allocator, cmus_parent_path orelse cmus_path, removeLast(entry)) else entry;

    const path = try std.fs.path.join(allocator, &.{ cmus_parent_path orelse cmus_path, entry });

    const content = try readCmupPlaylist(io, allocator, path, cmus_path, zql_paths, true_name);

    return CmupPlaylist{
        .name = true_name,
        .path = path,
        .content = content.items,
        .sub_playlists = content.sub_playlists,
    };
}

pub fn writeCmupPlaylist(io: std.Io, playlist: CmupPlaylist, path: []const u8) !void {
    if (playlist.content.len > 0) {
        var dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
        defer dir.close(io);

        var file = try dir.createFile(io, playlist.name, .{});
        defer file.close(io);

        var buf: [1024]u8 = .{0} ** 1024;
        var file_writer = file.writer(io, &buf);

        const writer = &file_writer.interface;

        const newline = comptime "\n";

        for (playlist.content) |music| {
            try writer.writeAll(music);
            try writer.writeAll(newline);
        }

        try writer.flush();
    }

    for (playlist.sub_playlists) |sub_playlist| {
        try writeCmupPlaylist(io, sub_playlist.*, path);
    }
}

const CmupResult = struct {
    playlists: std.ArrayList(CmupPlaylist),
    zql: std.ArrayList(ZqlSrc),

    pub fn deinit(result: *CmupResult, allocator: std.mem.Allocator) void {
        result.playlists.deinit(allocator);
        result.zql.deinit(allocator);
    }
};

pub fn cmup(
    io: std.Io,
    allocator: std.mem.Allocator,
    write: ?bool,
    music_path: []const u8,
    playlist_path: []const u8,
) anyerror!CmupResult {
    var path = music_path;

    const playlists = getDirEntryNames(io, allocator, music_path) catch blk: {
        path = try std.fs.path.join(allocator, &.{
            std.fs.path.dirname(music_path).?,
            "music",
        });

        break :blk getDirEntryNames(io, allocator, try std.fs.path.join(allocator, &.{
            std.fs.path.dirname(music_path).?,
            "music",
        })) catch {
            std.debug.print("Couldn't open dir {s}\n", .{music_path});

            std.process.exit(1);
        };
    };

    var result: std.ArrayList(CmupPlaylist) = .empty;
    var zql_result: std.ArrayList(ZqlSrc) = .empty;

    for (playlists.items) |value| {
        if (std.ascii.startsWithIgnoreCase(value, ".")) {
            continue;
        }

        const playlist = try createCmupPlaylist(io, allocator, value, path, null, &zql_result);

        if (write orelse false) {
            try writeCmupPlaylist(io, playlist, playlist_path);
        }

        try result.append(allocator, playlist);
    }

    return CmupResult{
        .playlists = result,
        .zql = zql_result,
    };
}

pub fn printCmupPlaylist(
    io: std.Io,
    allocator: std.mem.Allocator,
    playlist: CmupPlaylist,
    comptime spacing: []const u8,
) !void {
    var buf: [256]u8 = .{0} ** 256;

    var file_writer = std.Io.File.stderr().writer(io, &buf);

    const writer = &file_writer.interface;

    const playlist_fmt = try std.fmt.allocPrint(
        allocator,
        "Playlist" ++ green ++ " {s} " ++ reset ++ "on path {s} with {} items\n",
        .{ playlist.name, playlist.path, playlist.content.len },
    );

    try writer.writeAll(playlist_fmt);

    for (playlist.content) |value| {
        const content_fmt = try std.fmt.allocPrint(allocator, spacing ++ "  {s}\n", .{value});
        try writer.writeAll(content_fmt);
    }

    try writer.flush();

    for (playlist.sub_playlists) |sub_playlist| {
        try printCmupPlaylist(io, allocator, sub_playlist.*, "  ");
    }
}

pub fn printCmupPlaylists(io: std.Io, allocator: std.mem.Allocator, playlists: []const CmupPlaylist, comptime spacing: []const u8) !void {
    for (playlists) |item| {
        try printCmupPlaylist(io, allocator, item, spacing);
    }
}
