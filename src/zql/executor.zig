// NOTE: move filtering logic into separate module cuz it wlll grow

const std = @import("std");
const path = @import("../utils/path.zig");
const CmupPlaylist = @import("../cmup/cmup.zig").CmupPlaylist;
const Ast = @import("ast.zig");
const Token = @import("lexer.zig").Token;
const NodeType = Ast.NodeType;
const ASTNode = Ast.ASTNode;
const filterByName = @import("filters/filter-by-name.zig").filterByName;
const err = @import("error.zig");
const levenshteinDistance = @import("../levenshtein/levenshtein.zig").levenshteinDistance;
const findClosestIdentifier = @import("identifier-errors.zig").findClosestIdentifier;

pub const IdentifierLevenshteinDistance = struct {
    value: *[]const u8,
    distance: usize,
};

fn identifierDistanceLessThan(context: void, a: IdentifierLevenshteinDistance, b: IdentifierLevenshteinDistance) bool {
    _ = context;

    return a.distance < b.distance;
}

pub const SideEffectType = enum {
    Remove,
};

pub const RemoveEffect = struct { playlist: []const u8 };

pub const SideEffect = union(SideEffectType) { Remove: RemoveEffect };

pub const ExecutorResult = struct {
    playlist: CmupPlaylist,
    side_effects: std.ArrayList(SideEffect),

    pub fn deinit(result: ExecutorResult) void {
        result.side_effects.deinit();
    }
};

pub const Executor = struct {
    playlists: std.StringHashMap(CmupPlaylist),
    ast: []ASTNode,
    allocator: std.mem.Allocator,
    identifiers: std.StringHashMap(CmupPlaylist),
    stderr_buf: []u8,
    stderr: *std.Io.Writer,
    input: []const u8,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        playlists: std.StringHashMap(CmupPlaylist),
        ast: []ASTNode,
        stderr: std.Io.File,
        input: []const u8,
    ) !Executor {
        const stderr_buf: []u8 = try allocator.alloc(u8, 512);
        var stderr_writer = stderr.writer(io, stderr_buf).interface;

        return Executor{
            .playlists = playlists,
            .allocator = allocator,
            .identifiers = std.StringHashMap(CmupPlaylist).init(allocator),
            .ast = ast,
            .stderr = &stderr_writer,
            .stderr_buf = stderr_buf,
            .input = input,
        };
    }

    pub fn deinit(executor: *Executor) void {
        executor.identifiers.deinit();
        executor.side_effects.deinit();
        executor.allocator.destroy(executor.stderr_buf);
    }

    pub fn printErr(executor: *Executor, token: Token, er: err.Error) !void {
        try token.printErr(
            executor.allocator,
            executor.stderr,
            er,
            executor.input,
        );
    }

    pub fn executeRequire(executor: *Executor, data: Ast.RequireData) !void {
        for (data.sources) |source| {
            if (executor.playlists.get(source.source.lexeme)) |playlist| {
                try executor.identifiers.put(
                    if (source.as) |as| as.lexeme else source.source.lexeme,
                    playlist,
                );

                continue;
            }

            try executor.printErr(source.source, err.Error.PlaylistNotFound);
            std.debug.print("\nDid you mean `{s}`?\n", .{
                try findClosestIdentifier(executor.allocator, executor.playlists, source.source.lexeme),
            });
            return error.NoPlaylist;
        }
    }

    pub fn filterPlaylist(executor: *Executor, filters: []Ast.ASTFilter, playlist: CmupPlaylist) !std.ArrayList([]const u8) {
        var result: std.ArrayList([]const u8) = .empty;

        for (filters) |filter| {
            if (std.mem.eql(u8, filter.data.field.lexeme, "name")) {
                try filterByName(executor.allocator, &result, playlist, filter.data);
            }
        }

        return result;
    }

    pub fn executeAdd(executor: *Executor, result: *std.ArrayList([]const u8), data: Ast.AddData) !void {
        if (executor.identifiers.get(data.source.lexeme)) |value| {
            if (data.filters) |filters| {
                const tracks = try executor.filterPlaylist(filters, value);

                try result.appendSlice(executor.allocator, tracks.items);

                return;
            }

            try result.appendSlice(executor.allocator, value.content);

            return;
        }

        try executor.printErr(data.source, err.Error.ReferenceError);

        // TODO: remove std.debug.print
        std.debug.print("\nDid you mean `{s}`?\n", .{
            try findClosestIdentifier(executor.allocator, executor.identifiers, data.source.lexeme),
        });
        return error.ReferenceError;
    }

    pub fn executeHide(executor: *Executor, side_effects: *std.ArrayList(SideEffect), data: Ast.HideData) !void {
        const playlist: CmupPlaylist = executor.identifiers.get(data.playlist.lexeme) orelse {
            try executor.printErr(data.playlist, err.Error.ReferenceError);
            return error.ReferenceError;
        };

        try side_effects.append(executor.allocator, SideEffect{
            .Remove = .{ .playlist = playlist.name },
        });
    }

    pub fn execute(executor: *Executor, name: []const u8) !ExecutorResult {
        var result: std.ArrayList([]const u8) = .empty;
        var side_effects: std.ArrayList(SideEffect) = .empty;

        for (executor.ast) |node| {
            try switch (node.data) {
                NodeType.RequireStatement => |data| executor.executeRequire(data),
                NodeType.AddStatement => |data| executor.executeAdd(&result, data),
                NodeType.HideStatement => |data| executor.executeHide(&side_effects, data),
            };
        }

        return ExecutorResult{
            .side_effects = side_effects,
            .playlist = CmupPlaylist{
                .name = name,
                .content = result.items,
                .path = "",
                .sub_playlists = &[_]*CmupPlaylist{},
            },
        };
    }
};
