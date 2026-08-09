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
    ) error{OutOfMemory}!luce.source.Found {
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
        \\    label: string
        \\    value: long
        \\    fallback: long?
        \\
        \\const TITLE = "constant text whose bytes live beyond an inline value"
        \\const ANSWER: long = 40 + 2
        \\const CHOSEN = Kind.special
        \\const CELL = Cell(label = "row", value = ANSWER, fallback = none)
        \\const NUMBERS: list(long) = [3, 1, 2]
        \\const NUMBERS_ALIAS = NUMBERS
        \\const NUMBERS_EQUAL: list(long) = [3, 1, 2]
        \\const AGES = {"ada": 36, "alan": 41}
        \\const AGES_ALIAS = AGES
        \\const AGES_EQUAL = {"ada": 36, "alan": 41}
        \\const METHODS = {0: "stored", 8: "deflated"}
        \\const ROW: array(long, _) = [7, 8, 9]
        \\const ROW_ALIAS = ROW
        \\const ROW_EQUAL: array(long, _) = [7, 8, 9]
        \\const EMPTY_LIST: list(long) = []
        \\const EMPTY_ROW: array(long, _) = []
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
        \\    var sum: long = 0
        \\    for index, value in NUMBERS:
        \\        sum += index + value
        \\    assert(sum == 9)
        \\    assert(AGES.has("ada") and AGES["alan"] == 41)
        \\    var joined = new builder()
        \\    for key, value in AGES:
        \\        joined.append(key + string(value))
        \\    assert(joined.build() == "ada36alan41")
        \\    assert(METHODS[0] == "stored" and METHODS[8] == "deflated")
        \\    var row_total: long = 0
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
        \\func key_total(values: map(long, string)) -> long:
        \\    var total: long = 0
        \\    for key, value in values:
        \\        total += key
        \\    return total
        \\
        \\func main():
        \\    var numbers = {1: "one", 1: "last", 2: "two"}
        \\    var same_shape = {1: "last", 2: "two"}
        \\    assert(len(numbers) == 2 and numbers[1] == "last")
        \\    assert(numbers != same_shape)
        \\    var order = new builder()
        \\    for key, value in numbers:
        \\        order.append(string(key) + value)
        \\    assert(order.build() == "1last2two")
        \\    numbers[3] = "three"
        \\    numbers.remove(2)
        \\    assert(numbers.has(3) and not numbers.has(2) and key_total(numbers) == 4)
        \\    var mixed = {"whole": 1, "fraction": 2.5}
        \\    assert(mixed["whole"] == 1.0 and mixed["fraction"] == 2.5)
        \\    var nested: map(string, list(long)) = {"row": [1, 2], "row": [7]}
        \\    nested["row"].append(8)
        \\    assert(len(nested) == 1)
        \\    assert(nested["row"][0] == 7 and nested["row"][1] == 8)
        \\    var empty_list: list(long) = []
        \\    var empty_row: array(long, _) = []
        \\    var row: array(long, _) = [3, 1, 2]
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
        \\    var values: list(long) = [0]
        \\    var turn: long = 0
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
        \\const TABLE: list(long) = [5, 8]
        \\const ALIAS = TABLE
        \\const EQUAL: list(long) = [5, 8]
        \\
        \\func sees_table(values: list(long) = TABLE) -> bool:
        \\    return values == TABLE
        \\
        \\func distinct_defaults(left: list(long) = [5, 8], right: list(long) = [5, 8]) -> bool:
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
        \\const TABLE: list(long) = [4, 8]
        \\
        \\func apply(read: func() -> long) -> long:
        \\    return read()
        \\
        \\func main():
        \\    let last: func() -> long = () -> TABLE[1]
        \\    assert(last() == 8)
        \\    assert(apply(() -> TABLE[0]) == 4)
        \\
    );
}

test "constants: copy is the mutable door out of the program root" {
    try agree.ok(
        \\const LIST = [1, 2]
        \\const MAP = {"a": 1}
        \\const ARRAY: array(long, _) = [3, 4]
        \\
        \\func main():
        \\    var list_copy = copy LIST
        \\    list_copy.append(3)
        \\    list_copy[0] = 9
        \\    var map_copy = copy MAP
        \\    map_copy["b"] = 2
        \\    map_copy.remove("a")
        \\    var array_copy = copy ARRAY
        \\    array_copy.fill(7)
        \\    array_copy[1] = 8
        \\    assert(len(list_copy) == 3 and list_copy[0] == 9)
        \\    assert(len(LIST) == 2 and LIST[0] == 1)
        \\    assert(len(map_copy) == 1 and map_copy["b"] == 2 and MAP.has("a"))
        \\    assert(array_copy[0] == 7 and array_copy[1] == 8 and ARRAY[0] == 3)
        \\
    );
}

test "constants: unary elements keep arithmetic promotion widths" {
    try agree.ok(
        \\const SMALL: byte = 1
        \\const NARROW: short = 2
        \\const FRACTION: half = 1.5
        \\const INTEGERS: list(int) = [~SMALL, ~NARROW, -SMALL, -NARROW]
        \\const FLOATS: list(float) = [-FRACTION]
        \\
        \\func main():
        \\    assert(INTEGERS[0] == -2)
        \\    assert(INTEGERS[1] == -3)
        \\    assert(INTEGERS[2] == -1)
        \\    assert(INTEGERS[3] == -2)
        \\    assert(FLOATS[0] == float(-1.5))
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
        \\    label: string
        \\    weight: double
        \\    enabled: bool
        \\    mode: Mode
        \\    fallback: long?
        \\
        \\struct NarrowEntry:
        \\    small: byte?
        \\    fraction: half?
        \\
        \\const FLAGS = [true, false, true]
        \\const REALS: list(double) = [1, 2.5]
        \\const MODES = [Mode.idle, Mode.ready]
        \\const ENTRIES = [
        \\    Entry(label = "first", weight = 1.5, enabled = true, mode = Mode.idle, fallback = none),
        \\    Entry(label = "second", weight = 2.5, enabled = false, mode = Mode.ready, fallback = long(9)),
        \\]
        \\const BY_NUMBER = {
        \\    4: Entry(label = "mapped", weight = 3.5, enabled = true, mode = Mode.ready, fallback = none),
        \\}
        \\const NARROW = [NarrowEntry(small = 200, fraction = 1.5)]
        \\const WORDS: array(string, _) = ["alpha", "a string longer than inline storage"]
        \\
        \\func takes_byte(value: byte) -> bool:
        \\    return value == byte(200)
        \\
        \\func takes_half(value: half) -> bool:
        \\    return value == half(1.5)
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
        \\private const SECRET = [99]
        \\const PUBLIC = [1, 2, 3]
        \\const PUBLIC_ALIAS = PUBLIC
        \\
        \\func secret_value() -> long:
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
        \\private struct Hidden:
        \\    value: long
        \\
        \\const TABLE = [Hidden(value = 1)]
        \\
        \\func main():
        \\    return
        \\
    , "luce.sema.private", "TABLE is public and holds Hidden, which is marked private in this file; mark TABLE private or remove the mark on Hidden", "TABLE =");
}

test "constants: equal same-named imports remain distinct pool rows" {
    const left: agree.File = .{ .name = "left", .source = "const TABLE: list(long) = [1, 2]\n" };
    const right: agree.File = .{ .name = "right", .source = "const TABLE: list(long) = [1, 2]\n" };
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

    try expectProjectRefusedAt(
        \\import left
        \\import right
        \\
        \\func choose(flag: bool):
        \\    var values = left.TABLE
        \\    if flag:
        \\        values = right.TABLE
        \\    values.append(3)
        \\
        \\func main():
        \\    choose(true)
        \\
    , &.{
        .{ .name = "left", .source = left.source },
        .{ .name = "right", .source = right.source },
    }, "luce.sema.const", "this value may name a constant; append would write the program — use copy before the paths join [CONSTANTS.md R-D]", "values.append");
}

test "constants: a worker materializes its own constants and defaults" {
    try agree.ok(
        \\const TABLE: list(long) = [11, 31]
        \\
        \\func from_default(values: list(long) = TABLE) -> long:
        \\    assert(values == TABLE)
        \\    return values[0]
        \\
        \\func worker() -> long:
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
        \\    long(2): 2,
        \\}
        \\
        \\func main():
        \\    assert(len(BAD) == 2)
        \\
    , "luce.sema.const", "map key 2 is duplicated; it was first written on line 3", "long(2)");
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
        \\const MAYBE: int? = none
        \\const BAD = [MAYBE]
        \\
        \\func main():
        \\    assert(len(BAD) == 1)
        \\
    , "luce.sema.const", "constant container elements cannot be optional; choose a present value, or put the optional inside an object-free struct", "MAYBE]");
    try expectRefusedAt(
        \\const MAYBE: int? = none
        \\const BAD = {"answer": MAYBE}
        \\
        \\func main():
        \\    assert(len(BAD) == 1)
        \\
    , "luce.sema.const", "constant map values cannot be optional; choose a present value, or put the optional inside an object-free struct", "MAYBE}");
    try expectRefusedAt(
        \\const GRID: array(long, _, _) = [1, 2]
        \\
        \\func main():
        \\    assert(GRID.dim(0) == 2)
        \\
    , "luce.sema.const", "a flat bracket constant builds a rank-1 array; array(long, _, _) has rank 2", "[1, 2]");
    try expectRefusedAt(
        \\const EMPTY = []
        \\
        \\func main():
        \\    assert(len(EMPTY) == 0)
        \\
    , "luce.sema.const", "an empty [] needs a list(T) or array(T, _) annotation", "[]");
    // Flatness is a property of the annotated element type even when
    // the literal contains no elements to walk.
    try expectRefusedAt(
        \\const TASKS: list(task(long)) = []
        \\
        \\func main():
        \\    assert(len(TASKS) == 0)
        \\
    , "luce.sema.const", "constant containers are flat in this version; an element cannot itself carry a list, map, array, builder, file, or task [CONSTANTS.md R-E]", "[]");
    try expectRefusedAt(
        \\const TASKS: array(task(long), _) = []
        \\
        \\func main():
        \\    assert(TASKS.dim(0) == 0)
        \\
    , "luce.sema.const", "constant containers are flat in this version; an element cannot itself carry a list, map, array, builder, file, or task [CONSTANTS.md R-E]", "[]");
    try expectRefusedAt(
        \\const ROWS: list(list(long)) = []
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
    , "luce.parse.expression", "an empty map has no literal; write 'new map(K, V)' so its key and value types are explicit", "{}");
}

test "constants: every direct mutator is refused at the write site" {
    const list_prefix = "const TABLE: list(long) = [3, 1, 2]\n\nfunc main():\n    ";
    const array_prefix = "const ROW: array(long, _) = [3, 1, 2]\n\nfunc main():\n    ";
    const map_prefix = "const DICT = {\"a\": 1}\n\nfunc main():\n    ";
    const Case = struct {
        source: []const u8,
        name: []const u8,
        action: []const u8,
        marker: []const u8,
    };
    const cases = [_]Case{
        .{ .source = list_prefix ++ "TABLE.append(4)\n", .name = "TABLE", .action = "append", .marker = "TABLE.append" },
        .{ .source = list_prefix ++ "TABLE.insert(0, 4)\n", .name = "TABLE", .action = "insert", .marker = "TABLE.insert" },
        .{ .source = list_prefix ++ "TABLE.remove(0)\n", .name = "TABLE", .action = "remove", .marker = "TABLE.remove" },
        .{ .source = list_prefix ++ "let value = TABLE.pop()\n", .name = "TABLE", .action = "pop", .marker = "TABLE.pop" },
        .{ .source = list_prefix ++ "TABLE.clear()\n", .name = "TABLE", .action = "clear", .marker = "TABLE.clear" },
        .{ .source = list_prefix ++ "TABLE.sort()\n", .name = "TABLE", .action = "sort", .marker = "TABLE.sort" },
        .{ .source = list_prefix ++ "TABLE.reverse()\n", .name = "TABLE", .action = "reverse", .marker = "TABLE.reverse" },
        .{ .source = list_prefix ++ "TABLE[0] = 9\n", .name = "TABLE", .action = "an indexed store", .marker = "TABLE[0]" },
        .{ .source = array_prefix ++ "ROW.fill(9)\n", .name = "ROW", .action = "fill", .marker = "ROW.fill" },
        .{ .source = array_prefix ++ "ROW.sort()\n", .name = "ROW", .action = "sort", .marker = "ROW.sort" },
        .{ .source = array_prefix ++ "ROW.reverse()\n", .name = "ROW", .action = "reverse", .marker = "ROW.reverse" },
        .{ .source = array_prefix ++ "ROW[0] = 9\n", .name = "ROW", .action = "an indexed store", .marker = "ROW[0]" },
        .{ .source = map_prefix ++ "DICT.remove(\"a\")\n", .name = "DICT", .action = "remove", .marker = "DICT.remove" },
        .{ .source = map_prefix ++ "DICT.clear()\n", .name = "DICT", .action = "clear", .marker = "DICT.clear" },
        .{ .source = map_prefix ++ "DICT[\"a\"] = 9\n", .name = "DICT", .action = "an indexed store", .marker = "DICT[" },
    };
    for (cases) |case| {
        const message = try std.fmt.allocPrint(
            testing.allocator,
            "{s} is a constant; {s} would write the program [CONSTANTS.md R-D]",
            .{ case.name, case.action },
        );
        defer testing.allocator.free(message);
        try expectRefusedAt(case.source, "luce.sema.const", message, case.marker);
    }

    try expectRefusedAt(
        \\import std.lists
        \\
        \\const TABLE: list(long) = [3, 1, 2]
        \\
        \\func before(left: long, right: long) -> bool:
        \\    return left < right
        \\
        \\func main():
        \\    TABLE.sort_by(before)
        \\
    , "luce.sema.const", "TABLE is a constant; sort_by would write the program [CONSTANTS.md R-D]", "TABLE.sort_by");

    try expectRefusedAt(
        \\import std.lists
        \\
        \\const TABLE: list(long) = [3, 1, 2]
        \\
        \\func before(left: long, right: long) -> bool:
        \\    return left < right
        \\
        \\func main():
        \\    let alias = TABLE
        \\    alias.sort_by(before)
        \\
    , "luce.sema.const", "TABLE is a constant; sort_by would write the program [CONSTANTS.md R-D]", "alias.sort_by");
}

test "constants: aliases, same-row branches, loops, and chains keep provenance" {
    try expectRefusedAt(
        \\const TABLE: list(long) = [1, 2]
        \\
        \\func main():
        \\    let alias = TABLE
        \\    alias.append(3)
        \\
    , "luce.sema.const", "TABLE is a constant; append would write the program [CONSTANTS.md R-D]", "alias.append");

    try expectRefusedAt(
        \\const TABLE: list(long) = [1, 2]
        \\const SAME = TABLE
        \\
        \\func choose(flag: bool):
        \\    var values = TABLE
        \\    if flag:
        \\        values = SAME
        \\    else:
        \\        values = TABLE
        \\    values.clear()
        \\
        \\func main():
        \\    choose(true)
        \\
    , "luce.sema.const", "TABLE is a constant; clear would write the program [CONSTANTS.md R-D]", "values.clear");

    try expectRefusedAt(
        \\struct Cell:
        \\    value: long
        \\
        \\const CELLS = [Cell(value = 1)]
        \\
        \\func main():
        \\    CELLS[0].value = 2
        \\
    , "luce.sema.const", "CELLS is a constant; a nested store would write the program [CONSTANTS.md R-D]", "CELLS[0].value");

    try expectRefusedAt(
        \\const TABLE: list(long) = [9]
        \\
        \\func main():
        \\    var values: list(long) = [0]
        \\    var turn: long = 0
        \\    while turn < 2:
        \\        values.append(turn)
        \\        values = TABLE
        \\        turn += 1
        \\
    , "luce.sema.const", "this value may name a constant; append would write the program — use copy before the paths join [CONSTANTS.md R-D]", "values.append");
}

test "constants: ownership verbs and retaining stores cannot capture the program root" {
    const escape = "TABLE is a constant owned by the program; {s} cannot move or retain it — use copy on the value first [CONSTANTS.md R-C, R-D]";
    const Case = struct {
        source: []const u8,
        action: []const u8,
        marker: []const u8,
    };
    const cases = [_]Case{
        .{
            .source =
            \\const TABLE: list(long) = [1]
            \\
            \\func take(values: give list(long)):
            \\    assert(len(values) == 1)
            \\
            \\func main():
            \\    take(give TABLE)
            \\
            ,
            .action = "give",
            .marker = "give TABLE",
        },
        .{
            .source =
            \\const TABLE: list(long) = [1]
            \\
            \\func main():
            \\    free(TABLE)
            \\
            ,
            .action = "free",
            .marker = "free(TABLE)",
        },
        .{
            .source =
            \\const TABLE: list(long) = [1]
            \\
            \\func answer() -> list(long):
            \\    return TABLE
            \\
            \\func main():
            \\    let held = answer()
            \\
            ,
            .action = "return",
            .marker = "return TABLE",
        },
        .{
            .source =
            \\const TABLE: list(long) = [1]
            \\
            \\func main():
            \\    var target: list(long) = [0]
            \\    target = TABLE
            \\
            ,
            .action = "assignment",
            .marker = "target = TABLE",
        },
        .{
            .source =
            \\const TABLE: list(long) = [1]
            \\
            \\func main():
            \\    var rows = new list(list(long))
            \\    rows.append(TABLE)
            \\
            ,
            .action = "a container store",
            .marker = "TABLE",
        },
        .{
            .source =
            \\const TABLE: list(long) = [1]
            \\
            \\struct Box:
            \\    values: list(long)
            \\
            \\func main():
            \\    let box = Box(values = TABLE)
            \\
            ,
            .action = "a struct field",
            .marker = "values = TABLE",
        },
        .{
            .source =
            \\const TABLE: list(long) = [1]
            \\
            \\struct Box:
            \\    values: list(long)
            \\
            \\func main():
            \\    var box = Box(values = [0])
            \\    box.values = TABLE
            \\
            ,
            .action = "a field store",
            .marker = "box.values = TABLE",
        },
    };
    for (cases) |case| {
        const message = try std.fmt.allocPrint(testing.allocator, escape, .{case.action});
        defer testing.allocator.free(message);
        try expectRefusedAt(case.source, "luce.sema.const", message, case.marker);
    }
}

test "constants: container defaults borrow, and give defaults are refused" {
    try expectRefusedAt(
        \\const TABLE: list(long) = [1]
        \\
        \\func take(values: give list(long) = TABLE):
        \\    assert(len(values) == 1)
        \\
        \\func main():
        \\    take()
        \\
    , "luce.sema.own", "a give parameter takes ownership, so its default cannot be a shared constant container [OWNERSHIP.md S13, S32, S46]", "values: give");
}

test "constants: file.read refuses a direct or aliased constant buffer" {
    const source_prefix =
        \\import std.files
        \\
        \\const BUFFER: array(byte, _) = [byte(0), byte(0)]
        \\
        \\func main() -> !:
        \\    var file = try files.open("notes.txt")
        \\
    ;
    try expectRefusedAt(
        source_prefix ++ "    let count = try file.read(BUFFER)\n",
        "luce.sema.const",
        "BUFFER is a constant; file.read would write the program [CONSTANTS.md R-D]",
        "BUFFER",
    );
    try expectRefusedAt(
        source_prefix ++ "    let alias = BUFFER\n    let count = try file.read(alias)\n",
        "luce.sema.const",
        "BUFFER is a constant; file.read would write the program [CONSTANTS.md R-D]",
        "alias)",
    );
}

// ---------------------------------------------------------------------------
// Dynamic backstop
// ---------------------------------------------------------------------------

test "constants: a hidden list append traps immutable_object" {
    try agree.trapSays(
        \\const TABLE: list(long) = [1, 2]
        \\
        \\func mutate(values: list(long)):
        \\    values.append(3)
        \\
        \\func main():
        \\    mutate(TABLE)
        \\
    , .immutable_object, "constant container is immutable");

    try agree.trap(
        \\const TABLE: list(long) = [1, 2]
        \\
        \\func mutate(values: list(long) = TABLE):
        \\    values.append(3)
        \\
        \\func main():
        \\    mutate()
        \\
    , .immutable_object);

    try agree.trap(
        \\const TABLE: list(long) = [1, 2]
        \\
        \\func mutate(values: list(long)):
        \\    values[0] = 9
        \\
        \\func main():
        \\    mutate(TABLE)
        \\
    , .immutable_object);
}

test "constants: a worker's own root stays immutable through an unknown alias" {
    try agree.trapSays(
        \\const TABLE: list(long) = [1, 2]
        \\
        \\func mutate(values: list(long)):
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
        \\const TABLE: map(string, long) = {"a": 1}
        \\
        \\func mutate(values: map(string, long)):
        \\    values["a"] = 2
        \\
        \\func main():
        \\    mutate(TABLE)
        \\
    , .immutable_object);
    try agree.trap(
        \\const ROW: array(long, _) = [1, 2]
        \\
        \\func mutate(values: array(long, _)):
        \\    values.fill(9)
        \\
        \\func main():
        \\    mutate(ROW)
        \\
    , .immutable_object);
    try agree.trap(
        \\const ROW: array(long, _) = [1, 2]
        \\
        \\func mutate(values: array(long, _)):
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
        \\const TABLE: list(long) = [3, 1, 2]
        \\
        \\func before(left: long, right: long) -> bool:
        \\    return left < right
        \\
        \\func sort(values: list(long)):
        \\    values.sort_by(before)
        \\
        \\func main():
        \\    sort(TABLE)
        \\
    , .immutable_object);
}

test "constants: different visible roots keep a static maybe-constant taint" {
    try expectRefusedAt(
        \\const LEFT: list(long) = [1]
        \\const RIGHT: list(long) = [1]
        \\const ABSENT: list(long)? = none
        \\
        \\func choose(flag: bool):
        \\    var maybe = ABSENT
        \\    if flag:
        \\        maybe = LEFT
        \\    else:
        \\        maybe = ABSENT
        \\    let chosen = maybe else RIGHT
        \\    chosen.append(2)
        \\
        \\func main():
        \\    choose(true)
        \\
    , "luce.sema.const", "this value may name a constant; append would write the program — use copy before the paths join [CONSTANTS.md R-D]", "chosen.append");

    try expectRefusedAt(
        \\const TABLE: list(long) = [1]
        \\
        \\func choose(maybe: list(long)?):
        \\    let chosen = maybe else TABLE
        \\    chosen.append(2)
        \\
        \\func main():
        \\    choose(TABLE)
        \\
    , "luce.sema.const", "this value may name a constant; append would write the program — use copy before the paths join [CONSTANTS.md R-D]", "chosen.append");

    try expectRefusedAt(
        \\const LEFT: list(long) = [1]
        \\const RIGHT: list(long) = [1]
        \\
        \\func choose(flag: bool):
        \\    var chosen = LEFT
        \\    if flag:
        \\        chosen = RIGHT
        \\    chosen.append(2)
        \\
        \\func main():
        \\    choose(true)
        \\
    , "luce.sema.const", "this value may name a constant; append would write the program — use copy before the paths join [CONSTANTS.md R-D]", "chosen.append");
}

test "constants: file.read through a parameter traps before changing the world" {
    const world: agree.World = .withFile("notes.txt", "abcdef");
    var session = try agree.compare(
        \\import std.files
        \\
        \\const BUFFER: array(byte, _) = [byte(0), byte(0), byte(0)]
        \\
        \\func read(file: file, into: array(byte, _)) -> long!:
        \\    return try file.read(into)
        \\
        \\func main() -> !:
        \\    var file = try files.open("notes.txt")
        \\    let count = try read(file, BUFFER)
        \\    print(string(count))
        \\
    , .{ .world = world });
    defer session.deinit();
    try testing.expectEqual(luce.mir.TrapCode.immutable_object, session.end.trapped);
    try testing.expectEqualStrings("", session.printed());
    try testing.expectEqual(@as(usize, 0), session.reference.world.handle_position);
    try testing.expectEqual(@as(usize, 0), session.capture.world.handle_position);
    const remained = session.file() orelse return error.MissingFile;
    try testing.expectEqualStrings("notes.txt", remained.name);
    try testing.expectEqualStrings("abcdef", remained.content);
}
