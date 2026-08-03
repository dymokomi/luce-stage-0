//! Several files, one program.
//!
//! A Luce project is a root file and the siblings it imports; the
//! compiler joins them into a single verified module with one entry
//! (`compile/modules.zig`).  What that means at run time is stated
//! here: qualified names resolve, types cross file boundaries, a ring
//! of imports runs, and a file-scope constant declared in one file is
//! folded into another.
//!
//! The rejections — an import that cannot be found, a namespace nobody
//! imported, a constant cycle — are compile-time facts and stay in
//! `compile/test.zig` beside the driver that produces them.  What is
//! here is the half that runs, so it runs on both engines and the two
//! are compared (`specs/agree.zig`).

const agree = @import("agree.zig");

const geo: agree.File = .{ .name = "geo", .source =
    \\struct Point:
    \\    x: Float
    \\    y: Float
    \\
    \\struct Text:
    \\    func double(value: Int) -> Int:
    \\        return value * 2
    \\
    \\func make(x: Float, y: Float) -> Point:
    \\    return Point(x = x, y = y)
    \\
    \\func length(p: Point) -> Float:
    \\    return sqrt(p.x * p.x + p.y * p.y)
    \\
};

test "a file is a module: imports, qualified names, and shared types run" {
    var program = try agree.project(
        \\import geo
        \\
        \\func main():
        \\    let made = geo.make(3.0, 4.0)
        \\    assert(geo.length(made) == 5.0)
        \\    let direct = geo.Point(x = 1.0, y = 2.0)
        \\    let copied: geo.Point = direct
        \\    assert(copied.y == 2.0)
        \\    assert(geo.Text.double(21) == 42)
        \\
    , &.{geo});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "an imported module compiles and runs the same with CRLF line endings" {
    // The layout rules run on the loaded text, so a module edited on
    // Windows blocks and dedents exactly like any other file.
    const windows: agree.File = .{ .name = "geo", .source = "func area() -> Int:\r\n    var total = 0\r\n\r\n    for i in range(0, 3):\r\n        total = total + i\r\n\r\n    return total\r\n" };
    var program = try agree.project(
        \\import geo
        \\
        \\func main():
        \\    assert(geo.area() == 3)
        \\
    , &.{windows});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "modules may import each other; mutual recursion crosses files" {
    const even: agree.File = .{ .name = "even", .source =
        \\import odd
        \\
        \\func check(value: Int) -> Bool:
        \\    if value == 0:
        \\        return true
        \\    return odd.check(value - 1)
        \\
    };
    const odd: agree.File = .{ .name = "odd", .source =
        \\import even
        \\
        \\func check(value: Int) -> Bool:
        \\    if value == 0:
        \\        return false
        \\    return even.check(value - 1)
        \\
    };
    var program = try agree.project(
        \\import even
        \\
        \\func main():
        \\    assert(even.check(10))
        \\    assert(not even.check(7))
        \\
    , &.{ even, odd });
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "an import cycle is allowed: a three-file ring loads, compiles, and runs" {
    // The policy, written down (compile/modules.zig): a Luce module
    // has no initialization phase, so there is nothing to catch half
    // done and no reason to inherit Python's partially initialized
    // module.  The circularity that *does* mean something — a constant
    // that depends on itself through two files — is a diagnostic, and
    // is proved beside the driver that raises it.
    var program = try agree.project(
        \\import a
        \\
        \\func main():
        \\    assert(a.step(9) == 0)
        \\
    , &.{
        .{ .name = "a", .source = "import b\n\nfunc step(v: Int) -> Int:\n    if v == 0:\n        return 0\n    return b.step(v - 1)\n" },
        .{ .name = "b", .source = "import c\n\nfunc step(v: Int) -> Int:\n    return c.step(v)\n" },
        .{ .name = "c", .source = "import a\n\nfunc step(v: Int) -> Int:\n    return a.step(v)\n" },
    });
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "constants reach across modules through imports" {
    const config: agree.File = .{ .name = "config", .source =
        \\struct Size:
        \\    rows: Int
        \\    cols: Int
        \\
        \\let version = "2.0"
        \\let rows = 24
        \\let screen = Size(rows = rows, cols = 80)
        \\
    };
    var program = try agree.project(
        \\import config
        \\import std.strings
        \\
        \\let banner = "loom " + config.version
        \\
        \\func main():
        \\    assert(config.rows == 24)
        \\    assert(config.screen.cols == 80)
        \\    assert(banner == "loom 2.0")
        \\    assert(banner.starts_with("loom"))
        \\    assert(config.version.contains("."))
        \\
    , &.{config});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}
