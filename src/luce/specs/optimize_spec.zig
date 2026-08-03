//! `07_optimize` may not change what a program does.
//!
//! The stage rewrites verified MIR in place — value numbering,
//! ownership elision, control-flow merging, dead-code sweeping — and
//! the one thing it is not allowed to do is change one printed byte,
//! one trap code, one trap message, or one live object.  That is a
//! claim about *running*, so it is proved here rather than beside the
//! passes: what the passes look like after each rewrite is checked in
//! `07_optimize/test.zig`, and what the program still does is checked
//! here.
//!
//! Each case is therefore compiled twice — with the stage off and with
//! it on — and each of those two programs is run on **both** engines
//! and compared (`specs/agree.zig`).  Four runs; one answer.
//!
//! The dangerous corner is ownership: `object_unbind` is the
//! deallocation, so an elision one step too clever leaks an object,
//! frees a live one, or stops a use-after-free from trapping.  The
//! leak census is what notices, and it is compared on both axes.
//!
//! The generated corpus at the end is the part that finds what nobody
//! thought to write down — and, now that it runs compiled too, it is
//! the widest differential net over the lowering that this tree has:
//! four hundred programs nobody wrote.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");
const mir = luce.mir;
const types = luce.types;

const testing = std.testing;
const Allocator = std.mem.Allocator;

const script: types.CompileOptions = .{
    .allow_host = true,
    .source_name = "test.luc",
};

/// The depth these programs run at; none of them recurses.
const budget: agree.Provided = .{ .call_depth = 256 };

/// Compile with the stage off and with it on, run each on both
/// engines, and demand all four say the same thing.
///
/// The two engine comparisons happen inside `compareProgram`; what is
/// left for this function is the axis the stage is actually about —
/// optimized against unoptimized — and it compares everything anyone
/// can observe: the transcript, how the run ended, the words a trap
/// or an error carried, and the census.
fn unchanged(source: []const u8) !void {
    var options = script;

    options.prune = false;
    var raw = try agree.programWith(source, options);
    defer raw.deinit();

    options.prune = true;
    var lean = try agree.programWith(source, options);
    defer lean.deinit();

    var without = try agree.compareProgram(&raw, budget);
    defer without.deinit();
    var with = try agree.compareProgram(&lean, budget);
    defer with.deinit();

    try testing.expectEqualStrings(without.printed(), with.printed());
    try testing.expectEqual(without.end, with.end);
    try testing.expectEqualStrings(without.message(), with.message());
    try testing.expectEqualStrings(without.trace(), with.trace());
}

test "ownership behaviour survives the elision" {
    // Each of these has the shape the ownership pass looks for, and
    // each one would break differently if it were one step too keen:
    // a leaked object, a double free, or a use-after-free that stops
    // trapping.
    const cases = [_][]const u8{
        // The plain case: a fresh object adopted by a named binding.
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    print(str(len(xs)))
        \\
        ,
        // A fresh object adopted by a container instead — the release
        // of the temporary is a real no-op at run time, but only
        // because `append` took ownership, which the pass cannot see.
        \\func main():
        \\    let outer = new List(List(Int))
        \\    outer.append(new List(Int))
        \\    outer[0].append(7)
        \\    print(str(len(outer[0])))
        \\
        ,
        // Early release, then the scope end that must not free twice.
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    free(xs)
        \\    print("done")
        \\
        ,
        // An alias outliving the owner's release still traps at use
        // (S9), and still traps in the same place.
        \\func main():
        \\    var xs = [1, 2]
        \\    let view = xs
        \\    free(xs)
        \\    print(str(view[0]))
        \\
        ,
        // Reassigning an owning var frees the old object at once (S5).
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    xs = [2, 3]
        \\    print(str(view[0]))
        \\
        ,
        // An object given away must not be freed by the binding that
        // gave it.
        \\func keep(v: give List(Int)) -> Int:
        \\    let n = len(v)
        \\    free(v)
        \\    return n
        \\
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    print(str(keep(give(xs))))
        \\
        ,
        // Rebinding in a loop: a fresh object per turn, each released
        // at the end of its scope.
        \\func main():
        \\    var total = 0
        \\    for index in range(0, 8):
        \\        let row = new List(Int)
        \\        row.append(index)
        \\        total = total + len(row)
        \\    print(str(total))
        \\
        ,
        // Returning an object moves it to the caller (S16).
        \\func make() -> List(Int):
        \\    let xs = new List(Int)
        \\    xs.append(3)
        \\    return xs
        \\
        \\func main():
        \\    let xs = make()
        \\    print(str(len(xs)))
        \\
        ,
        // A copy is a second object, and both have to come back.
        \\func main():
        \\    let xs = new List(Int)
        \\    xs.append(1)
        \\    let ys = copy(xs)
        \\    ys.append(2)
        \\    print(str(len(xs)) + " " + str(len(ys)))
        \\
        ,
    };
    for (cases) |source| try unchanged(source);
}

test "traps keep their code, their message, and their place" {
    const cases = [_][]const u8{
        \\func main():
        \\    var n = 0
        \\    print("before")
        \\    print(str(10 / n))
        \\
        ,
        \\func main():
        \\    let xs = new List(Int)
        \\    print("before")
        \\    print(str(xs[3]))
        \\
        ,
        \\func main():
        \\    var n = 9223372036854775807
        \\    print("before")
        \\    print(str(n + n))
        \\
        ,
        \\func main():
        \\    print("before")
        \\    trap("stop here")
        \\
        ,
        \\func main():
        \\    let m = new Map(String, Int)
        \\    print("before")
        \\    print(str(m["missing"]))
        \\
    };
    for (cases) |source| try unchanged(source);
}

// ---------------------------------------------------------------------------
// Fuzz: generated programs, run both ways
// ---------------------------------------------------------------------------

/// Build a random but always-valid script out of statement templates.
/// The point is not clever programs — it is the *shapes* the passes
/// reason about: repeated reads of one local, nested scopes holding
/// fresh objects, branches that leave blocks with one predecessor, and
/// arithmetic that sometimes traps.
fn generate(text: *std.ArrayList(u8), random: std.Random) Allocator.Error!void {
    try text.appendSlice(testing.allocator,
        \\func main():
        \\    var a = 3
        \\    var b = 7
        \\    let xs = new List(Int)
        \\
    );
    const statements = random.intRangeAtMost(usize, 1, 6);
    for (0..statements) |_| try statement(text, random, 1);
    try text.appendSlice(testing.allocator,
        \\    print(str(a) + " " + str(b) + " " + str(len(xs)))
        \\
    );
}

fn indent(text: *std.ArrayList(u8), depth: usize) Allocator.Error!void {
    for (0..depth) |_| try text.appendSlice(testing.allocator, "    ");
}

fn add(text: *std.ArrayList(u8), comptime format: []const u8, arguments: anytype) Allocator.Error!void {
    const line = try std.fmt.allocPrint(testing.allocator, format, arguments);
    defer testing.allocator.free(line);
    try text.appendSlice(testing.allocator, line);
}

var fresh_name: usize = 0;

fn statement(text: *std.ArrayList(u8), random: std.Random, depth: usize) Allocator.Error!void {
    const simple_only = depth >= 3;
    const choice = if (simple_only)
        random.intRangeAtMost(usize, 0, 4)
    else
        random.intRangeAtMost(usize, 0, 9);
    const value = random.intRangeAtMost(i64, -4, 9);
    switch (choice) {
        0 => {
            try indent(text, depth);
            try add(text, "a = a + {d} * {d}\n", .{ value, value });
        },
        1 => {
            try indent(text, depth);
            try add(text, "b = (a + b) % {d}\n", .{value});
        },
        2 => {
            try indent(text, depth);
            try add(text, "xs.append(a + b + {d})\n", .{value});
        },
        3 => {
            try indent(text, depth);
            try text.appendSlice(testing.allocator, "a = a + len(xs) + len(xs)\n");
        },
        4 => {
            try indent(text, depth);
            try add(text, "b = min(max(b, {d}), a + a)\n", .{value});
        },
        5 => {
            try indent(text, depth);
            try add(text, "if a % 3 == {d}:\n", .{@mod(value, 3)});
            try statement(text, random, depth + 1);
            try indent(text, depth);
            try text.appendSlice(testing.allocator, "else:\n");
            try statement(text, random, depth + 1);
        },
        6 => {
            try indent(text, depth);
            fresh_name += 1;
            const turn = fresh_name;
            try add(text, "for i{d} in range(0, {d}):\n", .{ turn, random.intRangeAtMost(usize, 0, 5) });
            try indent(text, depth + 1);
            try add(text, "b = b + i{d}\n", .{turn});
            try statement(text, random, depth + 1);
        },
        7 => {
            // A nested scope with its own object: the ownership pass's
            // whole reason for existing.
            try indent(text, depth);
            try text.appendSlice(testing.allocator, "if b > a:\n");
            fresh_name += 1;
            const name = fresh_name;
            try indent(text, depth + 1);
            try add(text, "let row{d} = new List(Int)\n", .{name});
            try indent(text, depth + 1);
            try add(text, "row{d}.append(a)\n", .{name});
            try statement(text, random, depth + 1);
            try indent(text, depth + 1);
            try add(text, "a = a + len(row{d})\n", .{name});
        },
        8 => {
            try indent(text, depth);
            try text.appendSlice(testing.allocator, "if len(xs) > 0:\n");
            try indent(text, depth + 1);
            try text.appendSlice(testing.allocator, "a = a + xs[0] + xs[0]\n");
        },
        else => {
            try indent(text, depth);
            try add(text, "while a < {d}:\n", .{random.intRangeAtMost(i64, -2, 6)});
            try indent(text, depth + 1);
            try text.appendSlice(testing.allocator, "a = a + 1\n");
        },
    }
}

test "fuzz: the stage changes nothing, and neither engine disagrees" {
    var seed: u64 = 0;
    while (seed < 400) : (seed += 1) {
        fresh_name = 0;
        var prng = std.Random.DefaultPrng.init(seed);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try generate(&text, prng.random());
        unchanged(text.items) catch |mistake| {
            std.debug.print("seed {d} disagreed\n", .{seed});
            return mistake;
        };
    }
}
