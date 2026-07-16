// Example of a ZQL query:
//
// require jump-bangers, vktrenokh-stwv
//
// add all from jump-bangers
// add all from vktrenokh-stwv where name contains 'voj'
//

// The name of the new playlist should be derived from the ZQL file name
// (e.g., "vktrenokh-eurobeat.zql" => "vktrenokh-eurobeat").
//
// The `require` statement specifies which playlists will be used to create the new playlist.
// - If a playlist is referenced later in the query but is not defined using `require`,
//   the query should terminate with an error.
// - If a playlist is defined in the `require` statement but is not found by the `zmup` program,
//   the query should also terminate with an error.
//
// String literals should only be created using double quotes ("").
// The double quote character (") within a string can be escaped using the backslash (\) character.

const std = @import("std");
const getFileNameWithoutExtension = @import("../utils/path.zig").getFileNameWithoutExtension;

const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("ast.zig").Parser;
const executr = @import("executor.zig");
const Executor = executr.Executor;

const cmup = @import("../cmup/cmup.zig");
const CmupPlaylist = cmup.CmupPlaylist;

pub const SideEffect = executr.SideEffect;

const colors = @import("../utils/colors.zig");

pub fn run(
    io: std.Io,
    parent_allocator: std.mem.Allocator,
    map: std.StringHashMap(CmupPlaylist),
    path: []const u8,
) !executr.ExecutorResult {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });

    var buf: [102400]u8 = undefined;

    var buf_reader = file.reader(io, &buf);

    const query = try buf_reader.interface.readAlloc(allocator, 102400);

    var lexer = Lexer.init(io, query, allocator);
    defer lexer.deinit();

    try lexer.parse();

    var parser = Parser.init(&lexer, allocator, io);
    defer parser.deinit();

    try parser.parse();

    var executor = try Executor.init(io, allocator, map, parser.nodes.items, std.Io.File.stderr(), query);

    return executor.execute(getFileNameWithoutExtension(path));
}
