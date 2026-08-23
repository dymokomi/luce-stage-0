//! The executable specification of file-scope constants and constant
//! containers (docs/CONSTANTS.md).
//!
//! Values are folded exactly as before, but file scope is now spelled
//! `const`.  A flat list, map, or rank-1 array written there becomes
//! one object owned by the program root: aliases and uses of one
//! construction share its identity, while separately written equal
//! constructions do not.  Stage 4 refuses every write or ownership
//! escape whose root it can still name.  A borrow hides that fact at a
//! function boundary, so each mutating path is also proved against the
//! runtime's `immutable_object` backstop on both engines.
//!
//! Successful and trapping programs run interpreted and compiled and
//! must agree on output, trap, trace, leak census, and host world
//! (`agree.zig`).  Compile-time refusals have no engine to compare, so
//! they pin the diagnostic code, sentence, and source site here.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");

const testing = std.testing;

const compile_options: luce.types.CompileOptions = agree.hosted;

fn printAll(diagnostics: *const luce.diagnostics.Diagnostics) void {
    const rendered = diagnostics.render(testing.allocator) catch return;
    defer testing.allocator.free(rendered);
    std.debug.print("got:\n{s}", .{rendered});
}

/// Refuse one source program at the last occurrence of `marker`, with
/// the exact stable code and sentence.  The last occurrence lets a
/// case name its declaration and then point at the later misuse.
fn expectRefusedAt(
    source: []const u8,
    code: []const u8,
    message: []const u8,
    marker: []const u8,
) !void {
    var result = try luce.compile.compile(testing.allocator, source, compile_options);
    defer result.deinit();
    if (result == .success) {
        std.debug.print("expected {s}, but this compiled:\n{s}", .{ code, source });
        return error.TestUnexpectedResult;
    }
    const first = result.failure.at(0) orelse return error.TestUnexpectedResult;
    errdefer printAll(&result.failure);
    try testing.expectEqualStrings(code, first.code);
    try testing.expectEqualStrings(message, first.message);
    const expected = std.mem.lastIndexOf(u8, source, marker) orelse
        return error.MarkerMissing;
    try testing.expectEqual(expected, first.span.start);
}

const File = struct { name: []const u8, source: []const u8 };

const Files = struct {
    all: []const File,

    fn find(
        context: *anyopaque,
        arena: std.mem.Allocator,
        name: []const u8,
        from_root: []const u8,
    ) error{OutOfMemory}!luce.source.Found {
        _ = from_root; // One rootless table; the token distinguishes nothing here.
        const self: *Files = @ptrCast(@alignCast(context));
        for (self.all) |file| {
            if (std.mem.eql(u8, file.name, name)) {
                return .{ .text = .{ .bytes = try arena.dupe(u8, file.source) } };
            }
        }
        return .missing;
    }
};

fn expectProjectRefusedAt(
    root: []const u8,
    files: []const File,
    code: []const u8,
    message: []const u8,
    marker: []const u8,
) !void {
    var found: Files = .{ .all = files };
    var result = try luce.compile.compileProject(
        testing.allocator,
        root,
        .{ .context = &found, .load = Files.find },
        compile_options,
    );
    defer result.deinit();
    if (result == .success) {
        std.debug.print("expected {s}, but this project compiled:\n{s}", .{ code, root });
        return error.TestUnexpectedResult;
    }
    const first = result.failure.at(0) orelse return error.TestUnexpectedResult;
    errdefer printAll(&result.failure);
    try testing.expectEqualStrings(code, first.code);
    try testing.expectEqualStrings(message, first.message);
    try testing.expectEqual(luce.source.root_file, first.file);
    const expected = std.mem.lastIndexOf(u8, root, marker) orelse
        return error.MarkerMissing;
    try testing.expectEqual(expected, first.span.start);
}

// ---------------------------------------------------------------------------
// Values, materialization, and identity
// ---------------------------------------------------------------------------

test "constants: values and every flat container shape materialize once" {
    try agree.ok(
        \\import std.strings
        \\
        \\enum Kind:
        \\    plain
        \\    special = 8
        \\
        \\struct Cell:
        \\    label: str
        \\    value: i64
        \\    fallback: i64?
        \\
        \\const TITLE = "constant text whose bytes live beyond an inline value"
        \\const ANSWER: i64 = 40 + 2
        \\const CHOSEN = Kind.special
        \\const CELL = Cell(label = "row", value = ANSWER, fallback = none)
        \\const NUMBERS: list[i64] = [3, 1, 2]
        \\const NUMBERS_ALIAS = NUMBERS
        \\const NUMBERS_EQUAL: list[i64] = [3, 1, 2]
        \\const AGES = {"ada": 36, "alan": 41}
        \\const AGES_ALIAS = AGES
        \\const AGES_EQUAL = {"ada": 36, "alan": 41}
        \\const METHODS = {0: "stored", 8: "deflated"}
        \\const ROW: array[i64, _] = [7, 8, 9]
        \\const ROW_ALIAS = ROW
        \\const ROW_EQUAL: array[i64, _] = [7, 8, 9]
        \\const EMPTY_LIST: list[i64] = []
        \\const EMPTY_ROW: array[i64, _] = []
        \\
        \\func main():
        \\    assert(TITLE.contains("beyond"))
        \\    assert(ANSWER == 42)
        \\    assert(CHOSEN == Kind.special)
        \\    assert(CELL.label == "row" and CELL.value == 42)
        \\    assert(CELL.fallback == none)
        \\    assert(NUMBERS == NUMBERS_ALIAS)
        \\    assert(NUMBERS != NUMBERS_EQUAL)
        \\    assert(AGES == AGES_ALIAS)
        \\    assert(AGES != AGES_EQUAL)
        \\    assert(ROW == ROW_ALIAS)
        \\    assert(ROW != ROW_EQUAL)
        \\    assert(len(EMPTY_LIST) == 0 and EMPTY_ROW.dim(0) == 0)
        \\    var sum: i64 = 0
        \\    for index, value in NUMBERS:
        \\        sum += index + value
        \\    assert(sum == 9)
        \\    assert(AGES.has("ada") and AGES["alan"] == 41)
        \\    var joined = builder()
        \\    for key, value in AGES:
        \\        joined.append(key + str(value))
        \\    assert(joined.build() == "ada36alan41")
        \\    assert(METHODS[0] == "stored" and METHODS[8] == "deflated")
        \\    var row_total: i64 = 0
        \\    for value in ROW:
        \\        row_total += value
        \\    assert(row_total == 24 and ROW.dim(0) == 3)
        \\    var middle = NUMBERS[1:]
        \\    middle[0] = 99
        \\    assert(middle[0] == 99 and NUMBERS[1] == 1)
        \\    var keys = AGES.keys()
        \\    keys.append("grace")
        \\    assert(len(keys) == 3 and len(AGES.values()) == 2)
        \\
    );
}

test "constants: a runtime map literal is fresh, mutable, ordered, and owns values" {
    try agree.ok(
        \\func key_total(values: map[i64, str]) -> i64:
        \\    var total: i64 = 0
        \\    for key, value in values:
        \\        total += key
        \\    return total
        \\
        \\func main():
        \\    var numbers = {1: "one", 1: "last", 2: "two"}
        \\    var same_shape = {1: "last", 2: "two"}
        \\    assert(len(numbers) == 2 and numbers[1] == "last")
        \\    assert(numbers != same_shape)
        \\    var order = builder()
        \\    for key, value in numbers:
        \\        order.append(str(key) + value)
        \\    assert(order.build() == "1last2two")
        \\    numbers[3] = "three"
        \\    numbers.remove(2)
        \\    assert(numbers.has(3) and not numbers.has(2) and key_total(numbers) == 4)
        \\    var mixed: map[str, f64] = {"whole": 1.0, "fraction": 2.5}
        \\    assert(mixed["whole"] == 1.0 and mixed["fraction"] == 2.5)
        \\    var nested: map[str, list[i64]] = {"row": [1, 2], "row": [7]}
        \\    nested["row"].append(8)
        \\    assert(len(nested) == 1)
        \\    assert(nested["row"][0] == 7 and nested["row"][1] == 8)
        \\    var empty_list: list[i64] = []
        \\    var empty_row: array[i64, _] = []
        \\    var row: array[i64, _] = [3, 1, 2]
        \\    row.sort()
        \\    empty_list.append(9)
        \\    assert(empty_list[0] == 9 and empty_row.dim(0) == 0)
        \\    assert(row.dim(0) == 3 and row[0] == 1 and row[2] == 3)
        \\    numbers.clear()
        \\    assert(len(numbers) == 0)
        \\
    );
}

test "constants: a fresh-only reassignment loop stays mutable" {
    try agree.ok(
        \\func main():
        \\    var values: list[i64] = [0]
        \\    var turn: i64 = 0
        \\    while turn < 3:
        \\        values.append(turn)
        \\        values = [turn]
        \\        turn += 1
        \\    assert(len(values) == 1 and values[0] == 2)
        \\
    );
}

test "constants: aliases and defaults share a row; equal declarations do not" {
    try agree.ok(
        \\const TABLE: list[i64] = [5, 8]
        \\const ALIAS = TABLE
        \\const EQUAL: list[i64] = [5, 8]
        \\
        \\func sees_table(values: list[i64] = TABLE) -> bool:
        \\    return values == TABLE
        \\
        \\func distinct_defaults(left: list[i64] = [5, 8], right: list[i64] = [5, 8]) -> bool:
        \\    return left != right
        \\
        \\func main():
        \\    assert(TABLE == ALIAS)
        \\    assert(TABLE != EQUAL)
        \\    assert(sees_table())
        \\    assert(sees_table(ALIAS))
        \\    assert(distinct_defaults())
        \\
    );
}

test "constants: a lambda may read a constant container" {
    try agree.ok(
        \\const TABLE: list[i64] = [4, 8]
        \\
        \\func apply(read: func() -> i64) -> i64:
        \\    return read()
        \\
        \\func main():
        \\    let last: func() -> i64 = () => TABLE[1]
        \\    assert(last() == 8)
        \\    assert(apply(() => TABLE[0]) == 4)
        \\
    );
}

test "constants: unary elements retain their explicit widths" {
    try agree.ok(
        \\const SMALL: u8 = 1
        \\const NARROW: i16 = 2
        \\const FRACTION: f16 = 1.5
        \\const UNSIGNED: list[u8] = [~SMALL]
        \\const SIGNED: list[i16] = [~NARROW, -NARROW]
        \\const FLOATS: list[f16] = [-FRACTION]
        \\
        \\func main():
        \\    assert(UNSIGNED[0] == u8(254))
        \\    assert(SIGNED[0] == i16(-3))
        \\    assert(SIGNED[1] == i16(-2))
        \\    assert(FLOATS[0] == f16(-1.5))
        \\
    );
}

test "constants: every flat element value survives materialization" {
    try agree.ok(
        \\enum Mode:
        \\    idle
        \\    ready = 7
        \\
        \\struct Entry:
        \\    label: str
        \\    weight: f64
        \\    enabled: bool
        \\    mode: Mode
        \\    fallback: i64?
        \\
        \\struct NarrowEntry:
        \\    small: u8?
        \\    fraction: f16?
        \\
        \\const FLAGS = [true, false, true]
        \\const REALS: list[f64] = [1, 2.5]
        \\const MODES = [Mode.idle, Mode.ready]
        \\const ENTRIES = [
        \\    Entry(label = "first", weight = 1.5, enabled = true, mode = Mode.idle, fallback = none),
        \\    Entry(label = "second", weight = 2.5, enabled = false, mode = Mode.ready, fallback = i64(9)),
        \\]
        \\const BY_NUMBER = {
        \\    4: Entry(label = "mapped", weight = 3.5, enabled = true, mode = Mode.ready, fallback = none),
        \\}
        \\const NARROW = [NarrowEntry(small = 200, fraction = 1.5)]
        \\const WORDS: array[str, _] = ["alpha", "a string longer than inline storage"]
        \\
        \\func takes_byte(value: u8) -> bool:
        \\    return value == u8(200)
        \\
        \\func takes_half(value: f16) -> bool:
        \\    return value == f16(1.5)
        \\
        \\func main():
        \\    assert(FLAGS[0] and not FLAGS[1] and FLAGS[2])
        \\    assert(REALS[0] == 1.0 and REALS[1] == 2.5)
        \\    assert(MODES[0] == Mode.idle and MODES[1] == Mode.ready)
        \\    assert(ENTRIES[0].label == "first")
        \\    assert(ENTRIES[0].fallback == none)
        \\    assert((ENTRIES[1].fallback else 0) == 9 and ENTRIES[1].mode == Mode.ready)
        \\    assert(BY_NUMBER[4].label == "mapped" and BY_NUMBER[4].weight == 3.5)
        \\    assert(takes_byte(NARROW[0].small else 0))
        \\    assert(takes_half(NARROW[0].fraction else 0.0))
        \\    assert(WORDS.dim(0) == 2 and WORDS[1] == "a string longer than inline storage")
        \\
    );
}

// ---------------------------------------------------------------------------
// Imports and one root per runtime
// ---------------------------------------------------------------------------

test "constants: public imports keep identity and private constants stay inside" {
    const tables: agree.File = .{ .name = "tables", .source =
        \\const SECRET = [99]
        \\pub const PUBLIC = [1, 2, 3]
        \\pub const PUBLIC_ALIAS = PUBLIC
        \\
        \\pub func secret_value() -> i64:
        \\    return SECRET[0]
        \\
    };
    var program = try agree.project(
        \\import tables
        \\
        \\func main():
        \\    assert(tables.PUBLIC == tables.PUBLIC_ALIAS)
        \\    assert(tables.PUBLIC[2] == 3)
        \\    assert(tables.secret_value() == 99)
        \\
    , &.{tables});
    defer program.deinit();
    try agree.okProgram(&program, .{});

    try expectProjectRefusedAt(
        \\import tables
        \\
        \\func main():
        \\    assert(tables.SECRET[0] == 99)
        \\
    , &.{.{ .name = "tables", .source = tables.source }}, "luce.sema.private", "SECRET is private to tables", "tables.SECRET");

    try expectProjectRefusedAt(
        \\import tables
        \\
        \\func main():
        \\    tables.SECRET[0] = 1
        \\
    , &.{.{ .name = "tables", .source = tables.source }}, "luce.sema.private", "SECRET is private to tables", "tables.SECRET");

    try expectRefusedAt(
        \\struct Hidden:
        \\    value: i64
        \\
        \\pub const TABLE = [Hidden(value = 1)]
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.private", "TABLE is public and holds Hidden, which is private in this file; remove pub from TABLE or mark Hidden pub", "TABLE =");
}

test "constants: equal same-named imports remain distinct pool rows" {
    const left: agree.File = .{ .name = "left", .source = "pub const TABLE: list[i64] = [1, 2]\n" };
    const right: agree.File = .{ .name = "right", .source = "pub const TABLE: list[i64] = [1, 2]\n" };
    var program = try agree.project(
        \\import left
        \\import right
        \\
        \\func main():
        \\    assert(left.TABLE != right.TABLE)
        \\
    , &.{ left, right });
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "constants: a worker materializes its own constants and defaults" {
    try agree.ok(
        \\const TABLE: list[i64] = [11, 31]
        \\
        \\func from_default(values: list[i64] = TABLE) -> i64:
        \\    assert(values == TABLE)
        \\    return values[0]
        \\
        \\func worker() -> i64:
        \\    return TABLE[1] + from_default()
        \\
        \\func main():
        \\    assert(from_default() == 11)
        \\    let task = spawn worker()
        \\    assert(task.wait() == 42)
        \\
    );
}

// ---------------------------------------------------------------------------
// Static front line
// ---------------------------------------------------------------------------

test "constants: file scope is const, and constant maps reject duplicate keys" {
    try expectRefusedAt(
        "let OLD = 1\n\nfunc main():\n    assert(OLD == 1)\n",
        "luce.parse.top",
        "file scope declares with const; let lives inside functions",
        "let OLD",
    );
    try expectRefusedAt(
        \\const BAD = {
        \\    "same": 1,
        \\    "same": 2,
        \\}
        \\
        \\func main():
        \\    assert(len(BAD) == 1)
        \\
    , "luce.sema.const", "map key \"same\" is duplicated; it was first written on line 2", "\"same\"");
    try expectRefusedAt(
        \\const TWO = 1 + 1
        \\const BAD = {
        \\    TWO: 1,
        \\    i64(2): 2,
        \\}
        \\
        \\func main():
        \\    assert(len(BAD) == 2)
        \\
    , "luce.sema.const", "map key 2 is duplicated; it was first written on line 3", "i64(2)");
}

test "constants: flatness and explicit empty shapes are compile-time contracts" {
    try expectRefusedAt(
        \\const NESTED = [[1], [2]]
        \\
        \\func main():
        \\    assert(len(NESTED) == 2)
        \\
    , "luce.sema.const", "constant containers are flat in this version; an element cannot itself carry a list, map, array, builder, file, or task [CONSTANTS.md R-E]", "[1]");
    try expectRefusedAt(
        \\const MAYBE: i32? = none
        \\const BAD = [MAYBE]
        \\
        \\func main():
        \\    assert(len(BAD) == 1)
        \\
    , "luce.sema.const", "constant container elements cannot be optional; choose a present value, or put the optional inside an object-free struct", "MAYBE]");
    try expectRefusedAt(
        \\const MAYBE: i32? = none
        \\const BAD = {"answer": MAYBE}
        \\
        \\func main():
        \\    assert(len(BAD) == 1)
        \\
    , "luce.sema.const", "constant map values cannot be optional; choose a present value, or put the optional inside an object-free struct", "MAYBE}");
    try expectRefusedAt(
        \\const GRID: array[i64, _, _] = [1, 2]
        \\
        \\func main():
        \\    assert(GRID.dim(0) == 2)
        \\
    , "luce.sema.const", "a flat bracket constant builds a rank-1 array; array[i64, _, _] has rank 2", "[1, 2]");
    try expectRefusedAt(
        \\const EMPTY = []
        \\
        \\func main():
        \\    assert(len(EMPTY) == 0)
        \\
    , "luce.sema.const", "an empty [] needs a list[T] or array[T, _] annotation", "[]");
    // Flatness is a property of the annotated element type even when
    // the literal contains no elements to walk.
    try expectRefusedAt(
        \\const TASKS: list[task[i64]] = []
        \\
        \\func main():
        \\    assert(len(TASKS) == 0)
        \\
    , "luce.sema.const", "constant containers are flat in this version; an element cannot itself carry a list, map, array, builder, file, or task [CONSTANTS.md R-E]", "[]");
    try expectRefusedAt(
        \\const TASKS: array[task[i64], _] = []
        \\
        \\func main():
        \\    assert(TASKS.dim(0) == 0)
        \\
    , "luce.sema.const", "constant containers are flat in this version; an element cannot itself carry a list, map, array, builder, file, or task [CONSTANTS.md R-E]", "[]");
    try expectRefusedAt(
        \\const ROWS: list[list[i64]] = []
        \\
        \\func main():
        \\    assert(len(ROWS) == 0)
        \\
    , "luce.sema.const", "constant containers are flat in this version; an element cannot itself carry a list, map, array, builder, file, or task [CONSTANTS.md R-E]", "[]");
    try expectRefusedAt(
        \\const EMPTY = {}
        \\
        \\func main():
        \\    assert(len(EMPTY) == 0)
        \\
    , "luce.parse.expression", "an empty map has no literal; write 'map[K, V]()' so its key and value types are explicit", "{}");
}

// ---------------------------------------------------------------------------
// Dynamic backstop
// ---------------------------------------------------------------------------

test "constants: a hidden list append traps immutable_object" {
    try agree.trapSays(
        \\const TABLE: list[i64] = [1, 2]
        \\
        \\func mutate(values: list[i64]):
        \\    values.append(3)
        \\
        \\func main():
        \\    mutate(TABLE)
        \\
    , .immutable_object, "constant container is immutable");

    try agree.trap(
        \\const TABLE: list[i64] = [1, 2]
        \\
        \\func mutate(values: list[i64] = TABLE):
        \\    values.append(3)
        \\
        \\func main():
        \\    mutate()
        \\
    , .immutable_object);

    try agree.trap(
        \\const TABLE: list[i64] = [1, 2]
        \\
        \\func mutate(values: list[i64]):
        \\    values[0] = 9
        \\
        \\func main():
        \\    mutate(TABLE)
        \\
    , .immutable_object);
}

test "constants: a worker's own root stays immutable through an unknown alias" {
    try agree.trapSays(
        \\const TABLE: list[i64] = [1, 2]
        \\
        \\func mutate(values: list[i64]):
        \\    values[0] = 9
        \\
        \\func worker():
        \\    mutate(TABLE)
        \\
        \\func main():
        \\    let task = spawn worker()
        \\    task.wait()
        \\
    , .immutable_object, "constant container is immutable");
}

test "constants: hidden map, array method, and inline index writes trap" {
    try agree.trap(
        \\const TABLE: map[str, i64] = {"a": 1}
        \\
        \\func mutate(values: map[str, i64]):
        \\    values["a"] = 2
        \\
        \\func main():
        \\    mutate(TABLE)
        \\
    , .immutable_object);
    try agree.trap(
        \\const ROW: array[i64, _] = [1, 2]
        \\
        \\func mutate(values: array[i64, _]):
        \\    values.fill(9)
        \\
        \\func main():
        \\    mutate(ROW)
        \\
    , .immutable_object);
    try agree.trap(
        \\const ROW: array[i64, _] = [1, 2]
        \\
        \\func mutate(values: array[i64, _]):
        \\    values[0] = 9
        \\
        \\func main():
        \\    mutate(ROW)
        \\
    , .immutable_object);
}

test "constants: hidden sort_by reaches the immutable backstop" {
    try agree.trap(
        \\import std.lists
        \\
        \\const TABLE: list[i64] = [3, 1, 2]
        \\
        \\func before(left: i64, right: i64) -> bool:
        \\    return left < right
        \\
        \\func sort(values: list[i64]):
        \\    values.sort_by(before)
        \\
        \\func main():
        \\    sort(TABLE)
        \\
    , .immutable_object);
}

test "constants: file.read through a parameter traps before changing the world" {
    const world: agree.World = .withFile("notes.txt", "abcdef");
    var session = try agree.compare(
        \\import std.files
        \\
        \\const BUFFER: array[u8, _] = [u8(0), u8(0), u8(0)]
        \\
        \\func read(file: files.File, into: array[u8, _]) -> i64!:
        \\    return try file.read(into)
        \\
        \\func main() -> !:
        \\    var file = try files.File("notes.txt")
        \\    let count = try read(file, BUFFER)
        \\    print(str(count))
        \\
    , .{ .world = world });
    defer session.deinit();
    try testing.expectEqual(luce.mir.TrapCode.immutable_object, session.end.trapped);
    try testing.expectEqualStrings("", session.printed());
    try testing.expectEqual(@as(usize, 0), session.reference.world.open_rows[0].position);
    try testing.expectEqual(@as(usize, 0), session.capture.world.open_rows[0].position);
    const remained = session.file() orelse return error.MissingFile;
    try testing.expectEqualStrings("notes.txt", remained.name);
    try testing.expectEqualStrings("abcdef", remained.content);
}
