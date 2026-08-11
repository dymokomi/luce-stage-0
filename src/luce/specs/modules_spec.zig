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
    \\    x: double
    \\    y: double
    \\
    \\struct Text:
    \\    static func twice(value: long) -> long:
    \\        return value * 2
    \\
    \\func make(x: double, y: double) -> Point:
    \\    return Point(x = x, y = y)
    \\
    \\func length(p: Point) -> double:
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
        \\    assert(geo.Text.twice(21) == 42)
        \\
    , &.{geo});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "an imported module compiles and runs the same with CRLF line endings" {
    // The layout rules run on the loaded text, so a module edited on
    // Windows blocks and dedents exactly like any other file.
    const windows: agree.File = .{ .name = "geo", .source = "func area() -> long:\r\n    var total: long = 0\r\n\r\n    for i in range(0, 3):\r\n        total = total + i\r\n\r\n    return total\r\n" };
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
        \\func check(value: long) -> bool:
        \\    if value == 0:
        \\        return true
        \\    return odd.check(value - 1)
        \\
    };
    const odd: agree.File = .{ .name = "odd", .source =
        \\import even
        \\
        \\func check(value: long) -> bool:
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
        .{ .name = "a", .source = "import b\n\nfunc step(v: long) -> long:\n    if v == 0:\n        return 0\n    return b.step(v - 1)\n" },
        .{ .name = "b", .source = "import c\n\nfunc step(v: long) -> long:\n    return c.step(v)\n" },
        .{ .name = "c", .source = "import a\n\nfunc step(v: long) -> long:\n    return a.step(v)\n" },
    });
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "constants reach across modules through imports" {
    // The importable half of S35: a folded value constant has no
    // runtime owner to hand over when it crosses a module boundary as
    // `module.name`.  Program-root containers cross by shared handle
    // under S46.  ownership_spec proves the rest within one file.
    const config: agree.File = .{ .name = "config", .source =
        \\struct Size:
        \\    rows: long
        \\    cols: long
        \\
        \\const version = "2.0"
        \\const rows = 24
        \\const screen = Size(rows = rows, cols = 80)
        \\
    };
    var program = try agree.project(
        \\import config
        \\import std.strings
        \\
        \\const banner = "loom " + config.version
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

test "subfolder modules run: dots map to folders, and as picks the binding" {
    // docs/PACKAGES.md D2, the half that runs: `import geo.shapes`
    // binds its last segment, `as` moves only the binding, and both
    // namespaces resolve like any other module — types, functions and
    // constants crossing the same way.  The last segments collide on
    // purpose (`shapes` twice), which is exactly what the alias is
    // for.
    const shapes: agree.File = .{ .name = "geo.shapes", .source =
        \\struct Rect:
        \\    width: double
        \\    height: double
        \\
        \\func area(r: Rect) -> double:
        \\    return r.width * r.height
        \\
    };
    const blocks: agree.File = .{ .name = "blocks.shapes", .source =
        \\const faces = 6
        \\
        \\func volume(edge: double) -> double:
        \\    return edge * edge * edge
        \\
    };
    var program = try agree.project(
        \\import geo.shapes
        \\import blocks.shapes as blocks
        \\
        \\func main():
        \\    let r = shapes.Rect(width = 3.0, height = 4.0)
        \\    assert(shapes.area(r) == 12.0)
        \\    assert(blocks.volume(2.0) == 8.0)
        \\    assert(blocks.faces == 6)
        \\
    , &.{ shapes, blocks });
    defer program.deinit();
    try agree.okProgram(&program, .{});
}
