//! The build identity printed by both shipped tools.
//!
//! A public archive is built from one immutable source revision. Keeping its
//! identity inside `luce` and `loom` lets a bug report name more than a mutable
//! download URL, while target and compatibility facts are read from the binary
//! rather than repeated by a release script.

const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const luce = @import("luce");

pub const version = build_options.version;
pub const source_commit = build_options.source_commit;

pub fn write(out: *std.Io.Writer, tool: []const u8) !void {
    try out.print(
        "{s} {s}\n" ++
            "source {s}\n" ++
            "target {s}-{s}-{s}\n" ++
            "optimize {s}\n" ++
            "module-format {d}\n" ++
            "host-abi {d}\n",
        .{
            tool,
            version,
            source_commit,
            @tagName(builtin.target.cpu.arch),
            @tagName(builtin.target.os.tag),
            @tagName(builtin.target.abi),
            @tagName(builtin.mode),
            luce.mir.module.format_version,
            luce.codegen.abi.version,
        },
    );
}

test "build information names every compatibility boundary" {
    var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();

    try write(&written.writer, "luce");
    const report = written.written();
    for ([_][]const u8{
        "luce ",
        "\nsource ",
        "\ntarget ",
        "\noptimize ",
        "\nmodule-format ",
        "\nhost-abi ",
    }) |field| try std.testing.expect(std.mem.indexOf(u8, report, field) != null);
    try std.testing.expect(std.mem.endsWith(u8, report, "\n"));
}
