const zql = @import("zql/zql.zig");
const cmup = @import("cmup/cmup.zig");
const clear = @import("cmup/clear.zig").clearPlaylists;
const std = @import("std");
const colors = @import("utils/colors.zig");
const CmupPlaylist = cmup.CmupPlaylist;
const path_utils = @import("utils/path.zig");

pub fn printSuccess(io: std.Io) !void {
    var buf: [1024]u8 = .{0} ** 1024;
    var writer = std.Io.File.stdout().writer(io, &buf);

    try writer.interface.writeAll("\nUpdated playlists :)\n");
    try writer.interface.flush();
}

pub fn printInfo(io: std.Io) !void {
    var buf: [256]u8 = .{0} ** 256;
    var writer = std.Io.File.stdout().writer(io, &buf).interface;

    try writer.writeAll("If you wish to write playlists into your cmus config playlists\ntry adding --write flag");
}

pub fn hasArg(args: std.process.Args, comptime arg_name: []const u8) bool {
    var iterator = args.iterate();

    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, arg_name)) {
            return true;
        }
    }
    return false;
}

pub fn getArgValue(args: std.process.Args, comptime key: []const u8) ![]const u8 {
    var iterator = args.iterate();

    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, key)) {
            const next_arg = iterator.next();

            if (iterator.next()) |value| {
                return value;
            } else {
                return error.NoValueForArgument;
            }

            return next_arg;
        }
    }

    return error.NoArg;
}

pub fn printQueriesInfo(io: std.Io, allocator: std.mem.Allocator, out: std.Io.File, queries_amount: usize, is_pure: bool) !void {
    var buf: [256]u8 = .{0} ** 256;

    var writer = out.writer(io, &buf).interface;

    const pure_text = if (is_pure) " (Pure)" else "";

    const fmt = try std.fmt.allocPrint(
        allocator,
        colors.green_text("Zql{s}" ++ colors.dim_text(": ") ++ "{} queries found \n\n"),
        .{ pure_text, queries_amount },
    );

    try writer.writeAll(fmt);
}

pub fn putCmupPlaylist(map: *std.StringHashMap(CmupPlaylist), playlist: CmupPlaylist) !void {
    try map.put(playlist.name, playlist);

    for (playlist.sub_playlists) |sub_playlist| {
        try putCmupPlaylist(map, sub_playlist.*);
    }
}

pub fn removePlaylist(
    io: std.Io,
    allocator: std.mem.Allocator,
    playlists_path: []const u8,
    path: []const u8,
) !void {
    const playlist_path = try std.fs.path.join(allocator, &[_][]const u8{ playlists_path, path });
    defer allocator.free(playlist_path);

    try std.Io.Dir.deleteDirAbsolute(io, playlist_path);
}

pub fn executeSideEffects(io: std.Io, allocator: std.mem.Allocator, side_effects: []zql.SideEffect, playlist_path: []const u8) !void {
    for (side_effects) |side_effect| {
        switch (side_effect) {
            .Remove => |data| try removePlaylist(io, allocator, playlist_path, data.playlist),
        }
    }
}

pub fn executeZqls(
    io: std.Io,
    allocator: std.mem.Allocator,
    zql_src: []cmup.ZqlSrc,
    map: std.StringHashMap(CmupPlaylist),
    playlist_path: []const u8,
    stdout: std.Io.File,
    pure: bool,
) !void {
    var buf: [256]u8 = .{0} ** 256;
    var stdout_writer = stdout.writer(io, &buf).interface;

    for (zql_src) |src| {
        var result = zql.run(io, allocator, map, src.src) catch {
            std.process.exit(1);
        };

        const name = path_utils.getFileNameWithoutExtension(src.src);

        if (cmup.endsWithDollar(name)) {
            // TODO: fix memory leak here
            result.playlist.name = try cmup.formatSubPlaylist(allocator, src.parent_name, name[0 .. name.len - 1]);
        }

        try cmup.writeCmupPlaylist(io, result.playlist, playlist_path);

        const fmt = try std.fmt.allocPrint(
            allocator,
            colors.green_text("") ++ " {s}\n",
            .{result.playlist.name},
        );

        try stdout_writer.writeAll(fmt);

        if (!pure) {
            try executeSideEffects(io, allocator, result.side_effects.items, playlist_path);
        }
    }
}

pub fn cmupPlaylistsToHashMap(
    allocator: std.mem.Allocator,
    playlists: []CmupPlaylist,
) !std.StringHashMap(CmupPlaylist) {
    var map = std.StringHashMap(CmupPlaylist).init(allocator);

    for (playlists) |playlist| {
        try putCmupPlaylist(&map, playlist);
    }

    return map;
}

pub fn normalizeInputPath(allocator: std.mem.Allocator, home: []const u8, input: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(input)) {
        return @constCast(input);
    }

    return std.fs.path.join(allocator, &.{ home, input });
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = init.minimal.args;

    const has_write = hasArg(args, "--write");

    const should_clear = hasArg(args, "clear");

    const input = getArgValue(args, "--input") catch null;

    const home = init.environ_map.get("HOME");

    if (home) |value| {
        const cmus_playlist_path = try std.fs.path.join(allocator, &[_][]const u8{ value, ".config/cmus/playlists" });

        const cmus_music_path = try if (input) |input_path| normalizeInputPath(allocator, value, input_path) else std.fs.path.join(allocator, &.{ value, "Music" });

        var writer_buf: [256]u8 = .{0} ** 256;

        const stdout = std.Io.File.stdout();

        var stdout_writer = stdout.writer(init.io, &writer_buf).interface;

        if (should_clear) {
            try clear(init, cmus_playlist_path);
            try stdout_writer.writeAll("cleared playlists\n");
            return;
        }

        var result = try cmup.cmup(init.io, allocator, has_write, cmus_music_path, cmus_playlist_path);
        defer result.deinit(allocator);

        var map = try cmupPlaylistsToHashMap(allocator, result.playlists.items);
        defer map.deinit();

        if (hasArg(args, "--print-everything")) {
            try cmup.printCmupPlaylists(init.io, allocator, result.playlists.items, "");
        }

        const is_pure = hasArg(args, "--pure");

        try printQueriesInfo(init.io, allocator, stdout, result.zql.items.len, is_pure);

        if (has_write) {
            try executeZqls(init.io, allocator, result.zql.items, map, cmus_playlist_path, stdout, hasArg(args, "--pure"));
            try printSuccess(init.io);
        } else {
            try printInfo(init.io);
        }
    } else {
        return error.NoHome;
    }
}
