//! The terminal command contract.

const session_mod = @import("session.zig");

pub const Session = session_mod.Session;

pub const Result = enum {
    ok,
    err,
    exit,
    unknown,
};

pub const Error = error{ OutOfMemory, WriteFailed };

// ---------------------------------------------------------------------------
// Command
// ---------------------------------------------------------------------------
//
// One terminal command.  words[0] is the command name; the rest are its
// arguments, already checked against argument_count by the dispatcher.
// Commands return .unknown never; that outcome belongs to dispatch.
//
pub const Command = struct {
    name: []const u8,
    alias: []const u8,
    argument_count: usize,
    usage: []const u8,
    run: *const fn (session: *Session, words: []const []const u8) Error!Result,
};
