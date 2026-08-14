//! Where a test may write files.
//!
//! Three of the modules here are about turning files into other files,
//! so three of them need a directory to do it in.  `std.testing.tmpDir`
//! makes one but hands back an open handle rather than a path, and the
//! code under test takes paths — so this turns the one into the other,
//! in one place rather than three.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The path of a `std.testing.tmpDir`, relative to the test's working
/// directory — which is where `tmpDir` created it.
pub fn path(gpa: Allocator, directory: std.testing.TmpDir) ![]const u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{directory.sub_path});
}

test "the path names the directory that was made" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const root = try path(arena, directory);
    const file = try std.fs.path.join(arena, &.{ root, "proof" });

    const io = std.testing.io;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "here" });
    const read = try std.Io.Dir.cwd().readFileAlloc(io, file, arena, .unlimited);
    try std.testing.expectEqualStrings("here", read);
}
