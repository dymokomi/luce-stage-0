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
//! are compared (`specs/agree.zig`).  The packages section
//! (docs/PACKAGES.md) is here for the same reason: package isolation,
//! a transitive dependency chain, aliased subfolder bindings and
//! package-qualified trap frames are all things a *running* program
//! observes, so each is proven on both engines; the store machinery
//! itself — discovery, manifests, hashes, diamonds — is the host's and
//! is proven in `src/apps/files.zig` and `src/apps/manifest.zig`.

const std = @import("std");
const testing = std.testing;

const agree = @import("agree.zig");
const luce = @import("luce");

const geo: agree.File = .{ .name = "geo", .source =
    \\pub struct Point:
    \\    pub x: f64
    \\    pub y: f64
    \\
    \\pub struct Text:
    \\    pub static func twice(value: i64) -> i64:
    \\        return value * 2
    \\
    \\pub func make(x: f64, y: f64) -> Point:
    \\    return Point(x = x, y = y)
    \\
    \\pub func length(p: Point) -> f64:
    \\    return sqrt(p.x * p.x + p.y * p.y)
    \\
};

const member_kit: agree.File = .{ .name = "shapes", .source =
    \\pub struct Point:
    \\    pub x: i64
    \\    pub y: i64
    \\
    \\pub class Widget:
    \\    pub width: i64
    \\
    \\pub enum Color:
    \\    red
    \\    green
    \\
    \\pub union Figure:
    \\    circle(radius: i64)
    \\    dot
    \\
    \\pub const origin = 7
    \\
    \\pub func span(p: Point) -> i64:
    \\    return p.x + p.y
    \\
    \\pub alias Spot = Point
    \\
    \\pub interface Sized:
    \\    func size() -> i64
    \\
};

test "a member import binds every declaration kind bare" {
    var program = try agree.project(
        \\from shapes import Point, Widget, Color, Figure, origin, span, Spot
        \\
        \\func main():
        \\    let p = Point(x = 2, y = 3)
        \\    let s: Spot = Point(x = 1, y = 1)
        \\    let w = Widget(width = 4)
        \\    let c = Color.red
        \\    let figure = Figure.dot
        \\    var total = span(p) + origin + w.width + s.x
        \\    if c == Color.red:
        \\        total += 1
        \\    match figure:
        \\        dot:
        \\            total += 1
        \\        else:
        \\            total += 0
        \\    assert(total == 19)
        \\
    , &.{member_kit});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "a member import renames with as and coexists with the whole import" {
    var program = try agree.project(
        \\import shapes
        \\from shapes import Point as Dot, span as measure
        \\
        \\func main():
        \\    let bare = Dot(x = 4, y = 5)
        \\    let qualified = shapes.Point(x = 1, y = 1)
        \\    assert(measure(bare) == 9)
        \\    assert(shapes.span(qualified) == 2)
        \\    let same: shapes.Point = bare
        \\    assert(same.y == 5)
        \\
    , &.{member_kit});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "an interface arrives through a member import with bare conformance" {
    var program = try agree.project(
        \\from shapes import Sized
        \\
        \\struct Tile: Sized:
        \\    edge: i64
        \\
        \\    func size() -> i64:
        \\        return self.edge * self.edge
        \\
        \\func total(items: list[Sized]) -> i64:
        \\    var sum = 0
        \\    for item in items:
        \\        sum += item.size()
        \\    return sum
        \\
        \\func main():
        \\    var items: list[Sized] = []
        \\    items.append(Tile(edge = 2))
        \\    items.append(Tile(edge = 3))
        \\    assert(total(items) == 13)
        \\
    , &.{member_kit});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "a member import folds an imported constant at file scope" {
    var program = try agree.project(
        \\from shapes import origin
        \\
        \\const doubled = origin * 2
        \\
        \\func main():
        \\    assert(doubled == 14)
        \\
    , &.{member_kit});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

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

test "an interface and its witness can cross a module boundary" {
    const drawing: agree.File = .{ .name = "drawing", .source =
        \\pub interface Drawable:
        \\    func render(value: i64) -> i64
        \\
        \\struct Button: Drawable:
        \\    offset: i64
        \\    func render(value: i64) -> i64:
        \\        return value + self.offset
        \\
        \\pub func make() -> Drawable:
        \\    return Button(offset = 2)
        \\
    };
    var program = try agree.project(
        \\import drawing
        \\
        \\func use(item: drawing.Drawable) -> i64:
        \\    return item.render(40)
        \\
        \\func main():
        \\    let item = drawing.make()
        \\    assert(use(item) == 42)
        \\
    , &.{drawing});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "a private interface cannot leak through a module's type surface" {
    const hidden: agree.File = .{ .name = "hidden", .source =
        \\interface Secret:
        \\    func value() -> i64
        \\
        \\struct Thing: Secret:
        \\    marker: i64
        \\    func value() -> i64:
        \\        return self.marker
        \\
        \\func make() -> Thing:
        \\    return Thing(marker = 7)
        \\
    };
    try expectProjectPrivate(
        \\import hidden
        \\
        \\func main():
        \\    let item: hidden.Secret = hidden.make()
        \\    _ = item
        \\
    , &.{hidden}, "Secret is private to hidden");
}

test "a private type alias stays inside its declaring module" {
    const hidden: agree.File = .{ .name = "hidden", .source =
        \\alias Secret = i64
        \\
        \\func reveal() -> Secret:
        \\    return 42
        \\
    };
    try expectProjectPrivate(
        \\import hidden
        \\
        \\func main():
        \\    let value: hidden.Secret = hidden.reveal()
        \\    _ = value
        \\
    , &.{hidden}, "Secret is private to hidden");
}

test "class: a private initializer is usable only inside its module" {
    const models: agree.File = .{ .name = "models", .source =
        \\pub class Token:
        \\    value: i64
        \\    init(value: i64):
        \\        self.value = value
        \\    pub static func make(value: i64) -> Token:
        \\        return Token(value)
        \\
    };
    try expectProjectPrivate(
        \\import models
        \\
        \\func main():
        \\    let token = models.Token(42)
        \\
    , &.{models}, "init is private to models");
}

fn expectProjectPrivate(
    root: []const u8,
    files: []const agree.File,
    saying: []const u8,
) !void {
    var found: agreeFiles = .{ .all = files };
    var result = try luce.compile.compileProject(
        testing.allocator,
        root,
        .{ .context = &found, .load = agreeFiles.find },
        agree.hosted,
    );
    defer result.deinit();
    switch (result) {
        .success => {
            std.debug.print("expected a private declaration refusal, but this compiled:\n{s}", .{root});
            return error.TestUnexpectedResult;
        },
        .failure => |diagnostics| {
            for (0..diagnostics.count()) |index| {
                const diagnostic = diagnostics.at(index).?;
                if (!std.mem.eql(u8, diagnostic.code, "luce.sema.private")) continue;
                if (std.mem.indexOf(u8, diagnostic.message, saying) != null) return;
            }
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("expected a private declaration refusal:\n{s}", .{rendered});
            return error.TestUnexpectedResult;
        },
    }
}

const agreeFiles = struct {
    all: []const agree.File,

    fn find(
        context: *anyopaque,
        arena: std.mem.Allocator,
        name: []const u8,
        from_root: []const u8,
    ) error{OutOfMemory}!luce.source.Found {
        const self: *@This() = @ptrCast(@alignCast(context));
        for (self.all) |file| {
            if (!std.mem.eql(u8, file.name, name)) continue;
            if (file.from) |only| {
                if (!std.mem.eql(u8, only, from_root)) continue;
            }
            return .{ .text = .{
                .bytes = try arena.dupe(u8, file.source),
                .path = file.path,
                .root = file.root,
            } };
        }
        return .missing;
    }
};

test "an imported module compiles and runs the same with CRLF line endings" {
    // The layout rules run on the loaded text, so a module edited on
    // Windows blocks and dedents exactly like any other file.
    const windows: agree.File = .{ .name = "geo", .source = "pub func area() -> i64:\r\n    var total: i64 = 0\r\n\r\n    for i in range(0, 3):\r\n        total = total + i\r\n\r\n    return total\r\n" };
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
        \\pub func check(value: i64) -> bool:
        \\    if value == 0:
        \\        return true
        \\    return odd.check(value - 1)
        \\
    };
    const odd: agree.File = .{ .name = "odd", .source =
        \\import even
        \\
        \\pub func check(value: i64) -> bool:
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
        .{ .name = "a", .source = "import b\n\npub func step(v: i64) -> i64:\n    if v == 0:\n        return 0\n    return b.step(v - 1)\n" },
        .{ .name = "b", .source = "import c\n\npub func step(v: i64) -> i64:\n    return c.step(v)\n" },
        .{ .name = "c", .source = "import a\n\npub func step(v: i64) -> i64:\n    return a.step(v)\n" },
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
        \\pub struct Size:
        \\    pub rows: i64
        \\    pub cols: i64
        \\
        \\pub const version = "2.0"
        \\pub const rows = 24
        \\pub const screen = Size(rows = rows, cols = 80)
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

test "two packages' same-named internals stay their own (docs/PACKAGES.md D4, D7)" {
    // The store's isolation promise, run: two packages each carry a
    // private `util.luc`, each package's `import util` is answered
    // inside its own root, and the two never merge, collide, or answer
    // for each other.  The loader stands in for the store — the
    // compiler never learns what a package is, only that the two utils
    // arrived under two root tokens.
    var program = try agree.project(
        \\import alpha
        \\import beta
        \\
        \\func main():
        \\    assert(alpha.scaled(2) == 20)
        \\    assert(beta.shifted(2) == 102)
        \\
    , &.{
        .{
            .name = "alpha",
            .root = "alpha-1.0.0",
            .path = ".luce/packages/alpha-1.0.0/alpha.luc",
            .source = "import util\n\npub func scaled(v: i64) -> i64:\n    return util.factor() * v\n",
        },
        .{
            .name = "beta",
            .root = "beta-1.0.0",
            .path = ".luce/packages/beta-1.0.0/beta.luc",
            .source = "import util\n\npub func shifted(v: i64) -> i64:\n    return util.factor() + v\n",
        },
        .{
            .name = "util",
            .from = "alpha-1.0.0",
            .root = "alpha-1.0.0",
            .path = ".luce/packages/alpha-1.0.0/util.luc",
            .source = "pub func factor() -> i64:\n    return 10\n",
        },
        .{
            .name = "util",
            .from = "beta-1.0.0",
            .root = "beta-1.0.0",
            .path = ".luce/packages/beta-1.0.0/util.luc",
            .source = "pub func factor() -> i64:\n    return 100\n",
        },
    });
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "a package module reached from outside and inside is one module: one struct, one type" {
    // The consumer writes `import geo.shapes`; the package's own entry
    // writes `import shapes`.  The host answers both with the same
    // file, and one file is one module — so the `Rect` a package
    // function returns is the very type the consumer names, not a
    // twin that looks alike.
    var program = try agree.project(
        \\import geo
        \\import geo.shapes
        \\
        \\func main():
        \\    let r = geo.unit()
        \\    assert(shapes.area(r) == 1.0)
        \\    let mine = shapes.Rect(width = 2.0, height = 3.0)
        \\    assert(shapes.area(mine) == 6.0)
        \\
    , &.{
        .{
            .name = "geo",
            .root = "geo-1.2.0",
            .path = ".luce/packages/geo-1.2.0/geo.luc",
            .source = "import shapes\n\npub func unit() -> shapes.Rect:\n    return shapes.Rect(width = 1.0, height = 1.0)\n",
        },
        .{
            .name = "geo.shapes",
            .from = "",
            .root = "geo-1.2.0",
            .path = ".luce/packages/geo-1.2.0/shapes.luc",
            .source = "pub struct Rect:\n    pub width: f64\n    pub height: f64\n\npub func area(r: Rect) -> f64:\n    return r.width * r.height\n",
        },
        .{
            .name = "shapes",
            .from = "geo-1.2.0",
            .root = "geo-1.2.0",
            .path = ".luce/packages/geo-1.2.0/shapes.luc",
            .source = "pub struct Rect:\n    pub width: f64\n    pub height: f64\n\npub func area(r: Rect) -> f64:\n    return r.width * r.height\n",
        },
    });
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "a transitive package chain runs: a dependency's dependency answers inside it (docs/PACKAGES.md D4)" {
    // The store resolves the whole want set eagerly: geo wants mathx,
    // the consumer never names mathx and never sees it — the loader
    // gates it to imports written inside geo, the way the want list
    // gates a real store.  The chain runs end to end on both engines,
    // and a package constant crosses to the consumer through the same
    // claims its functions cross by.
    var program = try agree.project(
        \\import geo
        \\
        \\func main():
        \\    assert(geo.area(2.0, 3.0) == 60.0)
        \\    assert(geo.label == "geo")
        \\
    , &.{
        .{
            .name = "geo",
            .root = "geo-1.2.0",
            .path = ".luce/packages/geo-1.2.0/geo.luc",
            .source = "import mathx\n\npub const label = \"geo\"\n\npub func area(w: f64, h: f64) -> f64:\n    return mathx.scale(w * h)\n",
        },
        .{
            .name = "mathx",
            .from = "geo-1.2.0",
            .root = "mathx-1.1.0",
            .path = ".luce/packages/mathx-1.1.0/mathx.luc",
            .source = "pub func scale(v: f64) -> f64:\n    return v * 10.0\n",
        },
    });
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "a trap inside a package is one report: same frames on both engines, the package named" {
    // The runtime half of root-qualified names (docs/PACKAGES.md D7):
    // a fault inside a package's private module unwinds through the
    // package, both engines report the same frames in the same order —
    // `compareProgram` holds the traces to byte equality — and the
    // frames say which package the fault came from, because the
    // serialized names carry the root token.
    var program = try agree.project(
        \\import geo
        \\
        \\func main():
        \\    let sampled = geo.sample()
        \\    assert(sampled == 0)
        \\
    , &.{
        .{
            .name = "geo",
            .root = "geo-1.2.0",
            .path = ".luce/packages/geo-1.2.0/geo.luc",
            .source = "import util\n\npub func sample() -> i64:\n    return util.pick()\n",
        },
        .{
            .name = "util",
            .from = "geo-1.2.0",
            .root = "geo-1.2.0",
            .path = ".luce/packages/geo-1.2.0/util.luc",
            .source = "pub func pick() -> i64:\n    var xs = [1, 2, 3]\n    var index = 7\n    return xs[index]\n",
        },
    });
    defer program.deinit();
    var session = try agree.compareProgram(&program, .{});
    defer session.deinit();
    try testing.expect(session.end == .trapped);
    try testing.expect(session.end.trapped == .index_bounds);
    try testing.expect(std.mem.indexOf(u8, session.trace(), "geo-1.2.0") != null);
}

test "subfolder modules run: dots map to folders, and as picks the binding" {
    // docs/PACKAGES.md D2, the half that runs: `import geo.shapes`
    // binds its last segment, `as` moves only the binding, and both
    // namespaces resolve like any other module — types, functions and
    // constants crossing the same way.  The last segments collide on
    // purpose (`shapes` twice), which is exactly what the alias is
    // for.
    const shapes: agree.File = .{ .name = "geo.shapes", .source =
        \\pub struct Rect:
        \\    pub width: f64
        \\    pub height: f64
        \\
        \\pub func area(r: Rect) -> f64:
        \\    return r.width * r.height
        \\
    };
    const blocks: agree.File = .{ .name = "blocks.shapes", .source =
        \\pub const faces = 6
        \\
        \\pub func volume(edge: f64) -> f64:
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
