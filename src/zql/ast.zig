const lxer = @import("lexer.zig");
const Lexer = lxer.Lexer;
const std = @import("std");
const err = @import("error.zig");

pub const NodeType = enum {
    RequireStatement,
    AddStatement,
    HideStatement,
};

pub fn ASTData(comptime data_type: type) type {
    return struct {
        data: data_type,
        token: lxer.Token,

        const Self = @This();

        pub fn init(data: data_type, token: lxer.Token) Self {
            return Self{
                .data = data,
                .token = token,
            };
        }
    };
}

// NOTE: move filtering things into separate module cuz they will grow
pub const MatchType = enum {
    Is,
    Contains,

    pub fn toMatchType(value: []const u8) !MatchType {
        if (std.mem.eql(u8, value, "is")) {
            return MatchType.Is;
        }

        if (std.mem.eql(u8, value, "contains")) {
            return MatchType.Contains;
        }

        return error.NotMatchType;
    }
};

pub const Source = struct {
    source: lxer.Token,
    as: ?lxer.Token,
};

pub const RequireData = struct {
    sources: []Source,
};

const ASTMatchType = ASTData(MatchType);

pub const Filter = struct {
    field: lxer.Token,
    match_type: ASTMatchType,
    target: lxer.Token,
};

pub const ASTFilter = ASTData(Filter);

pub const AddData = struct {
    source: lxer.Token,
    filters: ?[]ASTFilter,
};

pub const HideData = struct {
    playlist: lxer.Token,
};

const NodeData = union(NodeType) {
    RequireStatement: RequireData,
    AddStatement: AddData,
    HideStatement: HideData,
};

pub const ASTNode = struct {
    type: NodeType,
    data: NodeData,
    token: lxer.Token,
};

pub const Parser = struct {
    lexer: *Lexer,
    position: usize,
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(ASTNode),
    io: std.Io,

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator, io: std.Io) Parser {
        const nodes: std.ArrayList(ASTNode) = .empty;

        return Parser{
            .lexer = lexer,
            .allocator = allocator,
            .nodes = nodes,
            .position = 0,
            .io = io,
        };
    }

    pub fn deinit(parser: *Parser) void {
        parser.nodes.deinit(parser.allocator);
    }

    pub fn move(parser: *Parser) void {
        parser.position += 1;
    }

    pub fn printSyntaxError(parser: *Parser, token: lxer.Token) !void {
        var buf: [512]u8 = .{0} ** 512;
        var stderr = std.Io.File.stderr().writer(parser.io, &buf).interface;

        try token.printErr(
            parser.allocator,
            &stderr,
            err.Error.SyntaxError,
            parser.lexer.input,
        );
    }

    pub fn peekNextToken(parser: *Parser) ?lxer.Token {
        if (parser.position + 1 >= parser.lexer.tokens.items.len - 1) {
            return null;
        }

        return parser.lexer.tokens.items[parser.position + 1];
    }

    pub fn parseRequire(parser: *Parser, token: lxer.Token) !ASTNode {
        // TODO: fix memory leak here later
        var sources: std.ArrayList(Source) = .empty;

        while (parser.peekNextToken()) |value| {
            if (value.type != .Identifier) {
                break;
            }

            parser.move();

            if (parser.peekNextToken()) |as_token| {
                if (as_token.type == .As) {
                    parser.move();

                    const as_target = try parser.expectTokenType(as_token, .Identifier);

                    try sources.append(parser.allocator, Source{ .as = as_target, .source = value });

                    continue;
                }
            }

            try sources.append(parser.allocator, Source{ .source = value, .as = null });
        }

        if (sources.items.len == 0) {
            try parser.printSyntaxError(token);

            return error.SyntaxError;
        }

        return ASTNode{
            .type = .RequireStatement,
            .data = .{
                .RequireStatement = .{
                    .sources = sources.items,
                },
            },
            .token = token,
        };
    }

    pub fn expectTokenType(parser: *Parser, current_token: lxer.Token, expeceted_type: lxer.TokenType) !lxer.Token {
        const token = parser.peekNextToken() orelse {
            try parser.printSyntaxError(current_token);
            return error.SyntaxError;
        };

        if (token.type != expeceted_type) {
            try parser.printSyntaxError(token);
            return error.SyntaxError;
        }

        parser.move();

        return token;
    }

    pub fn parseFilter(parser: *Parser, prev_token: lxer.Token) !ASTFilter {
        const name = try parser.expectTokenType(prev_token, .Identifier);
        const match_type = try parser.expectTokenType(name, .MatchType);
        const target = try parser.expectTokenType(match_type, .String);

        return ASTFilter{
            .data = .{
                .field = name,
                .match_type = ASTMatchType.init(try MatchType.toMatchType(match_type.lexeme), match_type),
                .target = target,
            },
            .token = target,
        };
    }

    pub fn parseFilters(parser: *Parser) !?[]ASTFilter {
        const nextToken = parser.peekNextToken();

        if (nextToken) |value| {
            if (value.type != .Where) {
                return null;
            }

            parser.move();

            // TODO: fix memory leaks here
            var filters: std.ArrayList(ASTFilter) = .empty;

            const filter = try parser.parseFilter(value);

            while (parser.peekNextToken()) |token| {
                if (token.type != .Or) {
                    break;
                }

                parser.move();

                try filters.append(parser.allocator, try parser.parseFilter(value));
            }

            try filters.append(parser.allocator, filter);

            return filters.items;
        }

        return null;
    }

    pub fn parseAdd(parser: *Parser, token: lxer.Token) !ASTNode {
        const next = try parser.expectTokenType(token, .All);
        const from = try parser.expectTokenType(next, .From);
        const source = try parser.expectTokenType(from, .Identifier);

        const filters = try parser.parseFilters();

        return ASTNode{
            .type = .AddStatement,
            .token = token,
            .data = .{
                .AddStatement = .{
                    .source = source,
                    .filters = filters,
                },
            },
        };
    }

    pub fn parseHide(parser: *Parser, token: lxer.Token) !ASTNode {
        const playlist = try parser.expectTokenType(token, .Identifier);

        return ASTNode{
            .type = .HideStatement,
            .token = token,
            .data = .{ .HideStatement = .{ .playlist = playlist } },
        };
    }

    pub fn parse(parser: *Parser) !void {
        while (parser.position < parser.lexer.tokens.items.len) : ({
            parser.move();
        }) {
            var buf: [512]u8 = .{0} ** 512;

            var stderr = std.Io.File.stderr().writer(parser.io, &buf); // TODO: fix this later
            const item = parser.lexer.tokens.items[parser.position];

            const node = try switch (item.type) {
                .Require => parser.parseRequire(item),
                .Add => parser.parseAdd(item),
                .Hide => parser.parseHide(item),
                .Unknown => {
                    try item.printErr(
                        parser.allocator,
                        &stderr.interface,
                        err.Error.SyntaxError,
                        parser.lexer.input,
                    );
                    return error.SyntaxError;
                },
                else => continue,
            };

            try parser.nodes.append(parser.allocator, node);
        }
    }
};
