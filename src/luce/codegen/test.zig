//! End-to-end proof for the LLVM backend.
//!
//! Two kinds of test, both of them about the one code generator that
//! ships.  The first kind renders the LLVM IR the lowering produced
//! and reads it: what a construct became, what the runtime library was
//! asked for, what the compiler told LLVM about each call.  The second
//! kind runs the program — through libLLVM, `cc` and `dlopen` — beside
//! the interpreter, and demands they agree.
//!
//! Nothing about that path is mocked: if it passes, a Luce program
//! really did execute as machine code.
//!
//! The harness is `specs/agree.zig` and is shared with the rest of the
//! executable specification, which is why this file belongs to the
//! `specs` module rather than to `emit` (`src/luce/specs.zig` says
//! why).  It stays here, beside the backend, because the backend is
//! what it proves.

const std = @import("std");

// The language and the emitter come in as modules: this file belongs
// to `specs`, which is the one module that names both.
const luce = @import("luce");
const emit = @import("emit");
const spec = @import("../specs/agree.zig");

const interpreter = luce.interpreter;
const mir = luce.mir;
const abi = luce.codegen.abi;
const artifact = luce.codegen.artifact;
const runtime_effects = luce.codegen.effects;

const Capture = spec.Capture;
const Provided = spec.Provided;
const World = spec.World;
const render = spec.render;
const run = spec.run;
const runBuilt = spec.runBuilt;
const agree = spec.agree;
const agreeGiven = spec.agreeGiven;

// ---------------------------------------------------------------------------
// The shape of what is generated
// ---------------------------------------------------------------------------

test "the entry point is exported and every Luce function is internal" {
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\func main():
        \\    print("hi")
        \\
    )).?;
    defer gpa.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "define i32 @luce_main(ptr") != null);
    // The result is the *outcome* word, not a bit: a Luce function
    // answers ok, trapped, or errored (docs/FAILURE.md).
    try std.testing.expect(std.mem.indexOf(u8, rendered, "define internal i32 @luce.") != null);
}

test "checked integer arithmetic lowers to the overflow intrinsics" {
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\func main():
        \\    let a = 2
        \\    let b = 3
        \\    assert(a * b + a - b == 5)
        \\
    )).?;
    defer gpa.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "smul.with.overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "sadd.with.overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ssub.with.overflow") != null);
}

test "an optional lowers to its payload beside a presence bit" {
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\func main(args: list[str]):
        \\    let n = parse_int(args[0])
        \\    print(str(n else 0))
        \\
    )).?;
    defer gpa.free(rendered);

    // `{ i64, i1 }` is the whole representation, and nothing about it
    // reaches memory or the runtime: absence is `extractvalue`, and
    // the fallback is a branch on the bit.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "{ i64, i1 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "extractvalue") != null);
}

test "floats, structs, and the host services all lower" {
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\struct Point:
        \\    x: f64
        \\    y: f64
        \\
        \\func main(args: list[str]) -> !:
        \\    let p = Point(x = 1.5, y = -0.0)
        \\    print(str(p.x * 2.0) + str(i64(p.y)) + str(sqrt(f32(4.0))) + str(sqrt(p.x)))
        \\    print(args[0] + str(len(args)) + str(try path_kind("nowhere")))
        \\    term_move(term_rows(), term_cols())
        \\    term_flush()
        \\
    )).?;
    defer gpa.free(rendered);

    for ([_][]const u8{
        "fmul",
        "fneg",
        "fptosi",
        // `sqrt` answers whichever float width it was given
        // (docs/TYPES.md §9): the first call explicitly asks for f32
        // and the struct field is f64, so both intrinsics have to be
        // here — one alone would mean a written width was discarded.
        "llvm.sqrt.f32",
        "llvm.sqrt.f64",
        "declare i32 @luce_rt_struct_make",
        "declare i32 @luce_rt_args_list",
    }) |wanted| {
        if (std.mem.indexOf(u8, rendered, wanted) == null) {
            std.debug.print("missing: {s}\n", .{wanted});
            return error.NotGenerated;
        }
    }
}

test "a union builds through the struct path and is read inline" {
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\    rect(width: f64, height: f64)
        \\
        \\func kind(s: Shape) -> i64:
        \\    match s:
        \\        empty:
        \\            return 0
        \\        circle(radius):
        \\            return i64(radius)
        \\        rect:
        \\            return 2
        \\
        \\func main():
        \\    var cells = new array[Shape](2)
        \\    cells[1] = Shape.circle(radius = 4.0)
        \\    print(str(kind(cells[1])))
        \\
    )).?;
    defer gpa.free(rendered);

    // Construction is `luce_rt_struct_make` with one more slot in
    // front — no union-shaped export exists to call (docs/UNION.md
    // D8).  Exactly one declaration and one call site: the one
    // `variant_make` in `main`.  The match in `kind` reads the tag
    // and the payload as a `gep` and a load, so if a read ever became
    // a runtime call this count is what moves.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "declare i32 @luce_rt_struct_make") != null);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, rendered, "@luce_rt_struct_make"),
    );
    // The array element zero is one private constant run per union
    // (D13), padded to the union's static run length: one slot for
    // the tag and two for `rect`, the widest member (D8, D12).
    const zero_at = std.mem.indexOf(u8, rendered, "@luce.zero.Shape").?;
    try std.testing.expect(std.mem.indexOf(u8, rendered[zero_at..@min(zero_at + 80, rendered.len)], "[3 x") != null);
}

test "the runtime library is called, not reimplemented" {
    const gpa = std.testing.allocator;
    // A Map, because a Map is the container that stays a call: a hash
    // probe is genuinely call-worthy where an element load is not, and
    // `len` of a List or an Array is generated inline (docs/CODEGEN.md).
    const rendered = (try render(
        \\func main():
        \\    let xs = new list[i64]
        \\    let counts = new map[str, i64]
        \\    xs.append(1)
        \\    print(str(len(counts)) + str(xs.pop()))
        \\
    )).?;
    defer gpa.free(rendered);

    for ([_][]const u8{
        "declare i32 @luce_rt_new_list",
        "declare i32 @luce_rt_pop",
        "declare i32 @luce_rt_len",
        "declare i32 @luce_rt_str",
        "declare noalias ptr @luce_rt_open",
    }) |wanted| {
        if (std.mem.indexOf(u8, rendered, wanted) == null) {
            std.debug.print("missing: {s}\n", .{wanted});
            return error.NotCalled;
        }
    }
}

test "a release artifact carries no origin table, and a debug one does" {
    // `--release` strips the origins and changes nothing else
    // (docs/MODES.md), and the artifact is where that has to be
    // visible: the tag says which build this is, and a loader reads it
    // before it calls anything.  Asserting only that `strip` empties
    // the MIR would leave the two ends free to disagree — a stripped
    // program whose artifact still claimed origins, or a debug one
    // that quietly shipped none.
    const gpa = std.testing.allocator;
    const source =
        \\func ratio(value: i64) -> i64:
        \\    return 10 // value
        \\
        \\func main():
        \\    print(str(ratio(2)))
        \\
    ;

    const debug = (try spec.renderBuilt(source, .debug)).?;
    defer gpa.free(debug);
    const release = (try spec.renderBuilt(source, .release)).?;
    defer gpa.free(release);

    // Debug carries a table per function and says so in the tag; the
    // last two `i32`s of `artifact.Artifact` are `debug` and `reserved`.
    try std.testing.expect(std.mem.indexOf(u8, debug, "@luce.origins.") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug, "i32 1, i32 0") != null);

    // Release carries neither, and its function names survive — that
    // is the whole of the difference.
    try std.testing.expect(std.mem.indexOf(u8, release, "@luce.origins.") == null);
    try std.testing.expect(std.mem.indexOf(u8, release, "i32 1, i32 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, release, "i32 0, i32 0") != null);
    // The trace table stands in both, and the function names it holds
    // are still there: a stripped trap says `ratio`, only without a
    // line beside it.
    try std.testing.expect(std.mem.indexOf(u8, release, "@luce.functions") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug, "@luce.functions") != null);
    try std.testing.expect(std.mem.indexOf(u8, release, "c\"ratio\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug, "c\"ratio\"") != null);
    // And the file name goes with the origins.
    try std.testing.expect(std.mem.indexOf(u8, debug, "c\"test.luc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, release, "c\"test.luc\"") == null);

    // And stripping only ever removes: the release artifact is the
    // smaller of the two.
    try std.testing.expect(release.len < debug.len);
}

test "LLVM refuses function equality in hostile MIR" {
    // Function equality is refused by stage 4 and by the MIR verifier: a
    // function type cannot say whether a value carries a receiver.  This
    // test deliberately adds the impossible binary *after* compilation so
    // it reaches the backend boundary without pretending that the verifier
    // is the only line of defense.  The old backend compared only the named
    // slot and silently treated different binds as equal.
    const gpa = std.testing.allocator;
    var program = try spec.program(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func apply(f: func(i64) -> i64, n: i64) -> i64:
        \\    return f(n)
        \\
        \\func main():
        \\    let left: func(i64) -> i64 = twice
        \\    let right: func(i64) -> i64 = twice
        \\    print(str(apply(left, 1)))
        \\    print(str(apply(right, 2)))
    );
    defer program.deinit();

    const entry = &program.functions[program.entry_function];
    var operands: [2]mir.Register = undefined;
    var found: usize = 0;
    for (entry.instructions, 0..) |instruction, register| {
        if (instruction != .const_function or found == operands.len) continue;
        operands[found] = @intCast(register);
        found += 1;
    }
    try std.testing.expectEqual(@as(usize, operands.len), found);

    var return_block: ?usize = null;
    for (entry.blocks, 0..) |block, index| {
        if (block.items.len == 0) continue;
        const last = block.items[block.items.len - 1];
        if (entry.instructions[last] == .ret) {
            return_block = index;
            break;
        }
    }
    const block = &entry.blocks[return_block orelse return error.NoReturnBlock];
    const old_items = block.items;
    const old_return = old_items[old_items.len - 1];
    const binary_register: mir.Register = @intCast(entry.instructions.len);
    const function_type = entry.result_types[operands[0]];
    try std.testing.expect(function_type == .function);

    const instructions = try program.arena.allocator().alloc(
        mir.Instruction,
        entry.instructions.len + 1,
    );
    @memcpy(instructions[0..entry.instructions.len], entry.instructions);
    instructions[binary_register] = .{ .binary = .{
        .op = .equal,
        .operand_type = function_type,
        .left = operands[0],
        .right = operands[1],
    } };
    entry.instructions = instructions;

    const result_types = try program.arena.allocator().alloc(
        luce.types.Type,
        entry.result_types.len + 1,
    );
    @memcpy(result_types[0..entry.result_types.len], entry.result_types);
    result_types[binary_register] = .boolean;
    entry.result_types = result_types;

    const items = try program.arena.allocator().alloc(mir.Register, old_items.len + 1);
    @memcpy(items[0 .. old_items.len - 1], old_items[0 .. old_items.len - 1]);
    items[old_items.len - 1] = binary_register;
    items[old_items.len] = old_return;
    block.items = items;

    const triple = try emit.hostTriple(gpa);
    defer gpa.free(triple);
    switch (try luce.codegen.lowerToText(gpa, &program, .{ .triple = triple })) {
        .unsupported => |what| try std.testing.expectEqualStrings(
            "a comparison of function values",
            what,
        ),
        .text => |rendered| {
            defer gpa.free(rendered);
            return error.FunctionEqualityLowered;
        },
    }
}

test "a hoisted container read lands on the retired row when the handle is null" {
    // `luce.dead.row` is not a diagnostic code, whatever its shape
    // suggests: it is the name of a private constant this backend
    // emits, and the only place a lifted container read can point when
    // the handle it lifted is null.  Loop hoisting is what asks for
    // it, so an Array indexed in a loop — the shape loops.zig was
    // written for — is what proves it is there, and that it carries
    // the retired generation, which is what makes the read resolve to
    // "nothing" rather than to whoever holds that row next.
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\func main():
        \\    var grid = new array[i64](2, 2)
        \\    var row = 0
        \\    while row < 2:
        \\        grid[row, 0] = row * 2
        \\        row = row + 1
        \\    print(str(grid[1, 0]))
        \\
    )).?;
    defer gpa.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "@luce.dead.row") != null);
    // Private and constant: it is this module's own, and nothing
    // writes it.
    const at = std.mem.indexOf(u8, rendered, "@luce.dead.row =").?;
    const declaration = rendered[at..std.mem.indexOfScalarPos(u8, rendered, at, '\n').?];
    try std.testing.expect(std.mem.indexOf(u8, declaration, "private") != null);
    try std.testing.expect(std.mem.indexOf(u8, declaration, "constant") != null);
    // And it is reached by a select, which is the null test: the row
    // is chosen, not branched to, so the loads that follow it are
    // unconditional and the checks stay where they were.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "select i1") != null);
}

test "every runtime declaration carries what the compiler knows about it" {
    const gpa = std.testing.allocator;
    // A bare `declare` is the most pessimistic thing LLVM can be told:
    // reads and writes all memory, may unwind, may never come back.
    // `effects.zig` says otherwise for every entry point, and this is
    // what proves the saying reaches the module.
    const rendered = (try render(
        \\func main():
        \\    let counts = new map[str, i64]
        \\    counts["one"] = 1
        \\    print(str(len(counts)) + str(counts["one"]))
        \\
    )).?;
    defer gpa.free(rendered);

    var line_start: usize = 0;
    var checked: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rendered, line_start, '\n')) |line_end| {
        const line = rendered[line_start..line_end];
        line_start = line_end + 1;
        if (!std.mem.startsWith(u8, line, "declare ")) continue;
        if (std.mem.indexOf(u8, line, "@luce_rt_") == null) continue;
        checked += 1;
        const symbol_at = std.mem.indexOf(u8, line, "@luce_rt_").? + 1;
        const symbol_end = std.mem.indexOfScalarPos(u8, line, symbol_at, '(').?;
        const service = std.meta.stringToEnum(
            runtime_effects.Service,
            line[symbol_at..symbol_end],
        ) orelse return error.Undescribed;
        const effect = runtime_effects.describe(service);
        // Function attributes travel in a numbered group; the
        // declaration names the group it belongs to.  A service whose
        // exact description promises neither nounwind nor willreturn
        // may legitimately have no function group at all.
        const marker = std.mem.lastIndexOfScalar(u8, line, '#') orelse {
            try std.testing.expect(!effect.nounwind and !effect.willreturn);
            continue;
        };
        const group = try std.fmt.allocPrint(gpa, "attributes {s} = ", .{line[marker..]});
        defer gpa.free(group);
        const at = std.mem.indexOf(u8, rendered, group) orelse return error.Undescribed;
        const end = std.mem.indexOfScalarPos(u8, rendered, at, '\n').?;
        const described = rendered[at..end];
        for (
            [_][]const u8{ "nounwind", "willreturn" },
            [_]bool{ effect.nounwind, effect.willreturn },
        ) |wanted, expected| {
            const present = std.mem.indexOf(u8, described, wanted) != null;
            if (present != expected) {
                std.debug.print("{s}\n  is {s}\n  wants {s}={any}\n", .{
                    line,
                    described,
                    wanted,
                    expected,
                });
                return error.Undescribed;
            }
        }
    }
    try std.testing.expect(checked >= 8);

    // `luce_rt_len(rt, target, out)` carries the whole vocabulary: a
    // runtime pointer, a box it only borrows, a box it only fills.
    const at_len = std.mem.indexOf(u8, rendered, "declare i32 @luce_rt_len(").?;
    const len_line = rendered[at_len..std.mem.indexOfScalarPos(u8, rendered, at_len, '\n').?];
    for ([_][]const u8{
        "nocapture",
        "readonly",
        "writeonly",
        "nonnull",
        "noundef",
        "dereferenceable(24)",
        "align 8",
    }) |wanted| {
        if (std.mem.indexOf(u8, len_line, wanted) == null) {
            std.debug.print("{s}\n  wants {s}\n", .{ len_line, wanted });
            return error.Undescribed;
        }
    }
    // A reader of the heap is not a writer of it: it may write its own
    // arguments, and everything else it only looks at.  A *mutator*
    // says nothing, because since inline container access the heap is
    // memory this module can reach and "may move anything" is the
    // truth — see `runtime_effects.zig`, and note that `memory(...)`
    // prints nothing when it claims the default.
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "memory(read, argmem: readwrite)",
    ) != null);
    // The trap machinery is off the straight-line path.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cold") != null);
}

const flat_constants_source =
    \\struct Label:
    \\    text: str
    \\    rank: i64
    \\
    \\const labels: list[Label] = [Label(text = "first", rank = 1)]
    \\const axis: array[i64, _] = [3, 5, 8]
    \\const lookup: map[str, i64] = {"one": 1, "two": 2}
    \\
    \\func main():
    \\    assert(labels[0].text == "first")
    \\    assert(labels[0].rank == lookup["one"])
    \\    assert(axis[2] == 8)
    \\
;

test "constant containers materialize once and load from the program root" {
    const gpa = std.testing.allocator;
    const rendered = (try render(flat_constants_source)).?;
    defer gpa.free(rendered);
    errdefer std.debug.print("rendered IR:\n{s}\n", .{rendered});

    for ([_][]const u8{
        "define internal i32 @luce.constants(ptr",
        "call i32 @luce_rt_constants_begin",
        "call i32 @luce_rt_new_list",
        "call i32 @luce_rt_new_array",
        "call i32 @luce_rt_new_map",
        "call i32 @luce_rt_own_storage",
        "call i32 @luce_rt_constant_publish",
        "call void @luce_rt_constants_finish",
        "call void @luce_rt_constant_load",
        "call void @luce_rt_discard_loose",
        "call void @luce_rt_constants_abort",
    }) |wanted| {
        if (std.mem.indexOf(u8, rendered, wanted) == null) return error.NotGenerated;
    }
    // One runtime and no workers: the prologue invokes the helper
    // exactly once, however many declarations it materializes.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, rendered, "call i32 @luce.constants(ptr"),
    );
    // The one failure tail owns teardown in this order: the current
    // loose construction, then already-published roots, then the
    // synthetic declaration frame.  Keeping this structural makes an
    // allocator-failure path testable without asking the process
    // allocator to fail at a particular byte.
    const discard = std.mem.indexOf(u8, rendered, "call void @luce_rt_discard_loose").?;
    const abort = std.mem.indexOfPos(u8, rendered, discard, "call void @luce_rt_constants_abort").?;
    const origin = std.mem.indexOfPos(u8, rendered, abort, "call void @luce_rt_unwound").?;
    try std.testing.expect(discard < abort and abort < origin);
    // One main function plus three declaration descriptors are handed
    // to the runtime; `unwound(function_count + slot, 0)` resolves the
    // latter through the same table as an ordinary frame.
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "call ptr @luce_rt_open(ptr @luce.functions, i64 4)",
    ) != null);
}

test "an unused constant container leaves no pool or prologue behind" {
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\const unused: list[i64] = [1, 2, 3]
        \\
        \\func main():
        \\    assert(2 + 2 == 4)
        \\
    )).?;
    defer gpa.free(rendered);

    // Stage 7 pruned the unreachable pool row.  Stage 8 responds by
    // emitting neither the helper nor even declarations for its
    // runtime surface: laziness is observable as absent code.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "@luce.constants") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "luce_rt_constants_begin") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "luce_rt_constant_load") == null);
}

const worker_constants_source =
    \\const seeds: list[i64] = [13, 21]
    \\
    \\func first() -> i64:
    \\    return seeds[0]
    \\
    \\func main():
    \\    let task = spawn first()
    \\    assert(task.wait() == 13)
    \\
;

test "every worker runtime materializes its own constant roots" {
    const gpa = std.testing.allocator;
    const rendered = (try render(worker_constants_source)).?;
    defer gpa.free(rendered);
    errdefer std.debug.print("rendered IR:\n{s}\n", .{rendered});

    try std.testing.expect(std.mem.indexOf(u8, rendered, "define internal i32 @luce.worker") != null);
    // The root wrapper and the generated worker trampoline each call
    // the same helper on their own Runtime.  A declaration is never
    // shared across that boundary.
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, rendered, "call i32 @luce.constants(ptr"),
    );
}

test "constant declaration origins survive only in debug artifacts" {
    const gpa = std.testing.allocator;
    const source =
        \\const seeds: list[i64] = [3, 1, 2]
        \\
        \\func main():
        \\    assert(seeds[0] == 3)
        \\
    ;
    const debug = (try spec.renderBuilt(source, .debug)).?;
    defer gpa.free(debug);
    const release = (try spec.renderBuilt(source, .release)).?;
    defer gpa.free(release);

    try std.testing.expect(std.mem.indexOf(u8, debug, "@luce.origins.constant.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, release, "@luce.origins.constant.0") == null);
    // The declaration name is trace structure and survives stripping;
    // its source and single origin are debug data and do not.
    try std.testing.expect(std.mem.indexOf(u8, debug, "c\"seeds\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, release, "c\"seeds\"") != null);
}

// ---------------------------------------------------------------------------
// Running the machine code
// ---------------------------------------------------------------------------

test "compiled constant materialization preserves every flat container shape" {
    try agree(flat_constants_source);
}

test "a compiled worker reads its runtime-local constant root" {
    try agree(worker_constants_source);
}

test "inout calls mutate the caller on return, error, and nested forwarding" {
    try agree(
        \\struct Counter:
        \\    value: i64
        \\
        \\    func step():
        \\        self.value += 1
        \\
        \\    func twice():
        \\        self.step()
        \\        self.step()
        \\
        \\    func reject(value: i64) -> !:
        \\        self.value = value
        \\        error("failed")
        \\
        \\struct Holder:
        \\    values: list[i64]
        \\
        \\    func replace():
        \\        self = Holder(values = [9])
        \\
        \\func main():
        \\    var counter = Counter(value = 1)
        \\    counter.twice()
        \\    assert(counter.value == 3)
        \\    counter.reject(8) catch:
        \\        assert(counter.value == 8)
        \\    assert(counter.value == 8)
        \\
        \\    var holder = Holder(values = [1])
        \\    holder.replace()
        \\    assert(holder.values[0] == 9)
        \\
    );
}

test "a compiled program prints through the host table" {
    var capture: Capture = .{};

    const status = try run(
        \\func main():
        \\    print("hello from a compiled .lc")
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("hello from a compiled .lc\n", capture.printed());
    try std.testing.expectEqual(@as(?mir.TrapCode, null), capture.trap_code);
}

test "arithmetic, comparison, control flow, locals, and String(long) run" {
    var capture: Capture = .{};

    const status = try run(
        \\func main():
        \\    var total = 0
        \\    var index = 1
        \\    while index <= 10:
        \\        if index % 2 == 0:
        \\            total = total + index * index
        \\        else:
        \\            total = total - index
        \\        index = index + 1
        \\    print(str(total))
        \\    print(str(-total))
        \\    print(str(total // 4))
        \\
    , &capture, .{});

    // 4 + 16 + 36 + 64 + 100 = 220; 1 + 3 + 5 + 7 + 9 = 25; 220 - 25 = 195.
    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("195\n-195\n48\n", capture.printed());
}

test "calls and recursion carry values back and traps forward" {
    var capture: Capture = .{};

    const status = try run(
        \\func fib(n: i64) -> i64:
        \\    if n < 2:
        \\        return n
        \\    return fib(n - 1) + fib(n - 2)
        \\
        \\func name_of(name: str, value: i64) -> str:
        \\    if value > 0:
        \\        return name
        \\    return "none"
        \\
        \\func main():
        \\    print(name_of("fib", fib(20)))
        \\    print(str(fib(20)))
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("fib\n6765\n", capture.printed());
}

test "string of an unwritten function traps null_object on both engines" {
    var program = try spec.program(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    let chosen: func(i64) -> i64 = twice
        \\    print(str(chosen))
        \\
    );
    defer program.deinit();

    // Source cannot ask for a function value's zero, but a verified MIR
    // function may still read a local before a store.  Replace the
    // constant with such a read: both frame implementations fill the
    // slot with -1, and `function_name` must range-check it before
    // indexing the name table.
    const entry = &program.functions[program.entry_function];
    var function_value: ?mir.Register = null;
    for (entry.instructions, 0..) |instruction, register| switch (instruction) {
        .const_function => function_value = @intCast(register),
        else => {},
    };
    try std.testing.expect(function_value != null);
    const function_type = entry.result_types[function_value.?];
    try std.testing.expect(function_type == .function);

    const original_locals = entry.locals;
    const locals = try program.arena.allocator().alloc(mir.Local, original_locals.len + 1);
    @memcpy(locals[0..original_locals.len], original_locals);
    locals[original_locals.len] = .{
        .name = "unwritten",
        .local_type = function_type,
    };
    entry.locals = locals;
    entry.instructions[function_value.?] = .{ .local_get = @intCast(original_locals.len) };

    try mir.verify(std.testing.allocator, &program);
    try spec.trapProgram(&program, .{}, .null_object);
}

test "a call inside a loop does not grow the frame" {
    var capture: Capture = .{};

    // The scratch slot for the call result lives in the entry block, so
    // a million iterations cost one stack slot, not a million.
    const status = try run(
        \\func step(total: i64, index: i64) -> i64:
        \\    if index % 7 == 0:
        \\        return total + index
        \\    return total
        \\
        \\func main():
        \\    var total: i64 = 0
        \\    var index = 0
        \\    while index < 1000000:
        \\        total = step(total, index)
        \\        index = index + 1
        \\    print(str(total))
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("71428928571\n", capture.printed());
}

test "booleans and not run" {
    var capture: Capture = .{};

    const status = try run(
        \\func main():
        \\    let yes = true
        \\    let no = not yes
        \\    assert(not no)
        \\    assert(yes != no)
        \\    if no:
        \\        print("wrong")
        \\    else:
        \\        print("right")
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("right\n", capture.printed());
}

test "division by zero traps with the interpreter's code and message" {
    var capture: Capture = .{};

    const status = try run(
        \\func divide(a: i64, b: i64) -> i64:
        \\    return a // b
        \\
        \\func main():
        \\    print("before")
        \\    print(str(divide(1, 0)))
        \\    print("after")
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.divide_by_zero, capture.trap_code.?);
    try std.testing.expectEqualStrings("division by zero", capture.trapMessage());
    // The trap unwound out of `divide` without running the rest of main.
    try std.testing.expectEqualStrings("before\n", capture.printed());
}

test "integer overflow traps instead of wrapping" {
    var capture: Capture = .{};

    const status = try run(
        \\func main():
        \\    var value = 1
        \\    var step = 0
        \\    while step < 100:
        \\        value = value * 3
        \\        step = step + 1
        \\    print(str(value))
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.integer_overflow, capture.trap_code.?);
    try std.testing.expectEqualStrings("", capture.printed());
}

test "a failed assertion traps" {
    var capture: Capture = .{};

    const status = try run(
        \\func main():
        \\    assert(1 == 2)
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.assertion_failed, capture.trap_code.?);
    try std.testing.expectEqualStrings("assertion failed", capture.trapMessage());
}

test "trap(message) reports the program's own words" {
    var capture: Capture = .{};

    const status = try run(
        \\func main():
        \\    print("starting")
        \\    trap("nothing left to do")
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.explicit_trap, capture.trap_code.?);
    try std.testing.expectEqualStrings("nothing left to do", capture.trapMessage());
    try std.testing.expectEqualStrings("starting\n", capture.printed());
}

// ---------------------------------------------------------------------------
// Call depth and the call trace
// ---------------------------------------------------------------------------

test "the ABI's default depth is the interpreter's, so neither engine is deeper" {
    try std.testing.expectEqual(
        @as(i64, (interpreter.Budget{}).call_depth),
        abi.default_call_depth,
    );
}

test "runaway recursion traps instead of overflowing the machine's stack" {
    // A million frames is more than any native stack holds.  Compiled
    // code counts frames rather than hoping, so this is a trap with a
    // message and a trace, the way docs/LANGUAGE.md says it is — on
    // both engines, at the same call.
    try agree(
        \\func deep(n: i64) -> i64:
        \\    return 1 + deep(n - 1)
        \\
        \\func main():
        \\    print("before")
        \\    print(str(deep(1000000)))
        \\
    );
}

test "mutual recursion and a shallow limit agree on where the depth ran out" {
    try agreeGiven(
        \\func ping(n: i64) -> i64:
        \\    return pong(n + 1)
        \\
        \\func pong(n: i64) -> i64:
        \\    return ping(n + 1)
        \\
        \\func main():
        \\    print(str(ping(0)))
        \\
    , .{ .call_depth = 7 });
    // A host that allows no frames at all refuses `main` itself.
    try agreeGiven(
        \\func main():
        \\    print("never runs")
        \\
    , .{ .call_depth = 0 });
    // One frame is exactly enough for a program that calls nothing.
    try agreeGiven(
        \\func main():
        \\    print("just main")
        \\
    , .{ .call_depth = 1 });
}

test "a debug build reports file, line, column, and the whole call stack" {
    var capture: Capture = .{};

    const status = try runBuilt(
        \\func divide(a: i64, b: i64) -> i64:
        \\    return a // b
        \\
        \\func ratio(n: i64) -> i64:
        \\    return divide(n, 0)
        \\
        \\func main():
        \\    print(str(ratio(7)))
        \\
    , &capture, .{}, .debug);

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.divide_by_zero, capture.trap_code.?);
    try std.testing.expectEqualStrings(
        \\divide test.luc:2:5
        \\ratio test.luc:5:5
        \\main test.luc:8:5
        \\
    , capture.trapTrace());
}

test "a release build strips the lines and still names the functions" {
    var capture: Capture = .{};

    const status = try runBuilt(
        \\func divide(a: i64, b: i64) -> i64:
        \\    return a // b
        \\
        \\func ratio(n: i64) -> i64:
        \\    return divide(n, 0)
        \\
        \\func main():
        \\    print(str(ratio(7)))
        \\
    , &capture, .{}, .release);

    // Names are structure, not debug info (docs/MODES.md): the same
    // three frames, with nowhere to point.
    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.divide_by_zero, capture.trap_code.?);
    try std.testing.expectEqualStrings(
        \\divide :0:0
        \\ratio :0:0
        \\main :0:0
        \\
    , capture.trapTrace());
}

test "a deep trace keeps its innermost frames and counts the rest" {
    var capture: Capture = .{};

    _ = try run(
        \\func deep(n: i64) -> i64:
        \\    return 1 + deep(n - 1)
        \\
        \\func main():
        \\    print(str(deep(1000000)))
        \\
    , &capture, .{ .call_depth = 200 });

    // 200 frames live, 64 kept: 136 counted, and the innermost frame
    // is the recursive call that was refused.
    try std.testing.expectEqual(mir.TrapCode.call_depth_exceeded, capture.trap_code.?);
    const reported = capture.trapTrace();
    try std.testing.expect(std.mem.startsWith(u8, reported, "deep test.luc:2:5\n"));
    try std.testing.expect(std.mem.endsWith(u8, reported, "... 136 more\n"));
}

test "a missing host service fails closed" {
    var capture: Capture = .{};

    const status = try run(
        \\func main():
        \\    print("this host has no console")
        \\
    , &capture, .{ .print = false });

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.host_unavailable, capture.trap_code.?);
    try std.testing.expectEqualStrings("", capture.printed());
}

test "a compiled host rejects an unknown Answer before continuing" {
    var capture: Capture = .{};

    const status = try runBuilt(
        \\func main():
        \\    print("first")
        \\    print("second")
        \\
    , &capture, .{ .malformed_answer = true }, .debug);

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.host_unavailable, capture.trap_code.?);
    try std.testing.expectEqualStrings("first\n", capture.printed());
}

test "a compiled host rejects an out-of-range path kind" {
    var capture: Capture = .{};

    const status = try runBuilt(
        \\func main() -> !:
        \\    print(str(try path_kind(".")))
        \\
    , &capture, .{ .malformed_path_kind = true }, .debug);

    try std.testing.expectEqual(abi.Status.trapped, status);
    try std.testing.expectEqual(mir.TrapCode.host_unavailable, capture.trap_code.?);
    try std.testing.expectEqualStrings("", capture.printed());
}

// ---------------------------------------------------------------------------
// The two engines, side by side
// ---------------------------------------------------------------------------
//
// The old architecture had a differential oracle because it had four
// engines (docs/CODEGEN.md).  There are two left — the interpreter and
// compiled code — and they now share one implementation of every
// semantic below the instruction level, so the oracle's job is smaller:
// prove that sharing is real.  A disagreement here means the lowering
// marshalled something wrongly, not that a semantic was written twice.

test "lists, maps, strings, and ownership agree with the interpreter" {
    try agree(
        \\func total(xs: list[i64]) -> i64:
        \\    var sum: i64 = 0
        \\    for x in xs:
        \\        sum = sum + x
        \\    return sum
        \\
        \\func main():
        \\    let xs = new list[i64]
        \\    var i = 1
        \\    while i <= 5:
        \\        xs.append(i * i)
        \\        i = i + 1
        \\    xs.append(0)
        \\    xs.sort()
        \\    print(str(xs[0]) + "," + str(xs[5]) + "," + str(len(xs)))
        \\    print(str(total(xs)))
        \\    print(str(xs.find(9) else -1) + " " + str(xs.contains(7)))
        \\
        \\    let names = new map[str, i64]
        \\    names["one"] = 1
        \\    names["two"] = 2
        \\    names["one"] = 11
        \\    print(str(len(names)) + " " + str(names["one"]) + " " + str(names.get("three") else -1))
        \\    for name, count in names:
        \\        print(name + "=" + str(count))
        \\    print(str(names.has("two")) + " " + str(len(names.keys())))
        \\
        \\    let text = new builder
        \\    text.append("ab")
        \\    text.append_ascii(99)
        \\    let word = text.build()
        \\    print(word + " " + str(len(word)) + " " + str(word.byte_at(0)))
        \\    print(word[1:3] + " " + str(word.find_byte(99, 0)))
        \\    print(str(41 + 1) + str(char(33)) + str(u32('A')))
        \\    print(str("abc" < "abd") + str("abc" == "abc"))
        \\
        \\    let kept = xs
        \\    print(str(len(kept)))
        \\
    );
}

test "a store that traps still owns what it was handed" {
    try agree(
        \\func main():
        \\    let head = "a string comfortably past the inline threshold"
        \\    var xs: list[str] = [head]
        \\    print(str(len(xs)))
        \\    # The value moved into this call, so the trap inside it is
        \\    # the only thing left that can give the bytes back.
        \\    xs.insert(9, head + "-tail well past the threshold as well")
        \\    print("unreachable")
        \\
    );
}

test "a fallible call's result is carried, not taken, and still agrees" {
    try agree(
        \\func main():
        \\    # A fallible call's result crosses the branch on its
        \\    # outcome in a slot that is *reloaded*, so that slot keeps
        \\    # owning its storage and the stores below copy out of it
        \\    # (docs/STRINGS.md).
        \\    file_write("notes.txt", "a string comfortably past the inline threshold") catch:
        \\        print("no write")
        \\        return
        \\    var xs: list[str] = []
        \\    let text = file_read("notes.txt") catch "(none)"
        \\    xs.append(text)
        \\    xs.append(file_read("notes.txt") catch "(none)")
        \\    xs.append(text + "!")
        \\    print(str(len(xs)) + " " + str(len(xs[0])) + " " + str(len(xs[2])))
        \\
    );
}

test "a nested container agrees, and the leak census counts the same" {
    try agree(
        \\func main():
        \\    let rows = new list[list[i64]]
        \\    var r = 0
        \\    while r < 3:
        \\        let row = new list[i64]
        \\        row.append(r)
        \\        row.append(r * 10)
        \\        rows.append(row)
        \\        r = r + 1
        \\    print(str(len(rows)) + " " + str(rows[2][1]))
        \\    let leaked = new list[i64]
        \\    leaked.append(1)
        \\    print("done")
        \\
    );
}

test "an index out of bounds agrees" {
    try agree(
        \\func main():
        \\    let xs = new list[i64]
        \\    xs.append(1)
        \\    print("one")
        \\    print(str(xs[3]))
        \\
    );
}

// ---------------------------------------------------------------------------
// Floats
// ---------------------------------------------------------------------------
//
// The special values travel through a `List(double)`, which no optimizer
// can see into: without that, LLVM would fold the whole table at
// compile time and the test would only prove that its constant folder
// agrees, not that the generated instructions do.

test "float arithmetic, comparison, and formatting agree over the special values" {
    try agree(
        \\func main():
        \\    let values = new list[f64]
        \\    values.append(0.0)
        \\    values.append(-0.0)
        \\    values.append(1.5)
        \\    values.append(-2.5)
        \\    values.append(1.0 / 0.0)
        \\    values.append(-1.0 / 0.0)
        \\    values.append(0.0 / 0.0)
        \\    values.append((1.0 / 0.0) - (1.0 / 0.0))
        \\    values.append(0.0 * (1.0 / 0.0))
        \\    values.append((1.0 / 0.0) / (1.0 / 0.0))
        \\    var i = 0
        \\    while i < len(values):
        \\        var j = 0
        \\        while j < len(values):
        \\            let a = values[i]
        \\            let b = values[j]
        \\            print(str(a) + " " + str(b) + " = " + str(a + b) + " " + str(a - b) +
        \\                " " + str(a * b) + " " + str(a / b) + " " + str(a % b))
        \\            print("  " + str(a == b) + str(a != b) + str(a < b) +
        \\                str(a <= b) + str(a > b) + str(a >= b))
        \\            print("  " + str(min(a, b)) + " " + str(max(a, b)) + " " +
        \\                str(clamp(a, -1.0, 1.0)) + " " + str(abs(a)) + " " + str(-a))
        \\            j = j + 1
        \\        i = i + 1
        \\
    );
}

test "negating a float flips the sign bit, so -0.0 survives" {
    try agree(
        \\func main():
        \\    var zero = 0.0
        \\    let negative = -zero
        \\    print(str(negative) + " " + str(1.0 / negative))
        \\    print(str(zero == negative) + str(1.0 / zero == 1.0 / negative))
        \\    print(str(-negative) + " " + str(0.0 - zero))
        \\
    );
}

// A `min`/`max` reduction exercises the explicit floating-point
// compare/select lowering in `lower.emitExtremum`.  The generated code
// must answer what the interpreter's one-at-a-time loop answers, down to
// which signed zero it kept; target-specific min/max instructions are not
// allowed to change that choice.  Nothing below is a constant to the
// optimizer: the values come out of a List and the length out of `len`,
// so the reductions stay loops long enough to exercise the lowering.
test "min and max reductions over an array agree, signed zeros and all" {
    try agree(
        \\func lowest(xs: array[f64, _]) -> f64:
        \\    var smallest = xs[0]
        \\    for i in range(1, len(xs)):
        \\        smallest = min(smallest, xs[i])
        \\    return smallest
        \\
        \\func highest(xs: array[f64, _]) -> f64:
        \\    var largest = xs[0]
        \\    for i in range(1, len(xs)):
        \\        largest = max(largest, xs[i])
        \\    return largest
        \\
        \\func main():
        \\    let control = new list[f64]
        \\    control.append(0.0)
        \\    control.append(-0.0)
        \\    control.append(0.0 / 0.0)
        \\    let n = len(control) * 5
        \\    var xs = new array[f64](n)
        \\    for pattern in range(0, 32):
        \\        for i in range(0, n):
        \\            xs[i] = control[(pattern // (i % 5 + 1)) % 2]
        \\        let low = lowest(xs)
        \\        let high = highest(xs)
        \\        print(str(low) + " " + str(1.0 / low) + " " +
        \\            str(high) + " " + str(1.0 / high))
        \\    for at in range(0, n):
        \\        for i in range(0, n):
        \\            xs[i] = f64(i + 1)
        \\        xs[at] = control[2]
        \\        print(str(lowest(xs)) + " " + str(highest(xs)))
        \\
    );
}

test "clamp agrees when the bounds cross and when they are not numbers" {
    try agree(
        \\func main():
        \\    let bounds = new list[f64]
        \\    bounds.append(-1.0)
        \\    bounds.append(1.0)
        \\    bounds.append(0.0)
        \\    bounds.append(-0.0)
        \\    bounds.append(0.0 / 0.0)
        \\    var low = 0
        \\    while low < len(bounds):
        \\        var high = 0
        \\        while high < len(bounds):
        \\            let held = f64(low) - f64(high) * 0.5
        \\            print(str(clamp(held, bounds[low], bounds[high])))
        \\            high = high + 1
        \\        low = low + 1
        \\    print(str(clamp(5, 9, 2)) + " " + str(clamp(0, 9, 2)))
        \\
    );
}

test "the float builtins agree" {
    try agree(
        \\func main():
        \\    let xs = new list[f64]
        \\    xs.append(0.0)
        \\    xs.append(4.0)
        \\    xs.append(2.999)
        \\    xs.append(-2.999)
        \\    xs.append(1.0 / 0.0)
        \\    for x in xs:
        \\        print(str(x) + ": " + str(sqrt(abs(x))) + " " + str(floor(x)) +
        \\            " " + str(ceil(x)) + " " + str(f64(i64(clamp(x, -9.0, 9.0)))))
        \\
    );
}

test "long(double) agrees at the range boundaries" {
    try agree(
        \\func main():
        \\    var scale = 1.0
        \\    var step = 0
        \\    while step < 63:
        \\        scale = scale * 2.0
        \\        step = step + 1
        \\    print(str(i64(0.0 - scale)))
        \\    print(str(i64(scale - 1024.0)))
        \\    print(str(i64(2.7)) + " " + str(i64(-2.7)) + " " + str(i64(-0.0)))
        \\    print("at the edge")
        \\    print(str(i64(scale)))
        \\
    );
}

test "long(NaN) and long(infinity) trap the same way" {
    try agree(
        \\func main():
        \\    let nan = 0.0 / 0.0
        \\    print("before")
        \\    print(str(i64(nan)))
        \\
    );
    try agree(
        \\func main():
        \\    let far = -1.0 / 0.0
        \\    print("before")
        \\    print(str(i64(far)))
        \\
    );
}

test "the long math builtins agree, and abs of the smallest long traps" {
    try agree(
        \\func main():
        \\    let xs = new list[i64]
        \\    xs.append(0)
        \\    xs.append(7)
        \\    xs.append(-7)
        \\    xs.append(9223372036854775807)
        \\    xs.append(0 - 9223372036854775807 - 1)
        \\    for x in xs:
        \\        print(str(min(x, 3)) + " " + str(max(x, 3)) + " " + str(clamp(x, -2, 2)))
        \\
    );
    try agree(
        \\func main():
        \\    let xs = new list[i64]
        \\    xs.append(0 - 9223372036854775807 - 1)
        \\    print(str(abs(7)) + " " + str(abs(-7)))
        \\    print(str(abs(xs[0])))
        \\
    );
}

// ---------------------------------------------------------------------------
// Struct values
// ---------------------------------------------------------------------------

test "nested struct equality recurses into fields, not the slots holding them" {
    try agree(
        \\struct Inner:
        \\    n: i64
        \\    tag: str
        \\
        \\struct Outer:
        \\    left: Inner
        \\    right: Inner
        \\
        \\func main():
        \\    let a = Outer(left = Inner(n = 1, tag = "x"), right = Inner(n = 2, tag = "y"))
        \\    let b = Outer(left = Inner(n = 1, tag = "x"), right = Inner(n = 2, tag = "y"))
        \\    let c = Outer(left = Inner(n = 1, tag = "x"), right = Inner(n = 3, tag = "y"))
        \\    print(str(a == b) + str(a != b))
        \\    print(str(a == c) + str(a != c))
        \\    print(str(a.left == b.left) + str(a.right == c.right))
        \\
    );
}

test "a struct carrying a String copies by value and agrees" {
    try agree(
        \\struct Person:
        \\    name: str
        \\    age: i64
        \\    score: f64
        \\
        \\func renamed(who: Person, to: str) -> Person:
        \\    var changed = who
        \\    changed.name = to
        \\    return changed
        \\
        \\func main():
        \\    var ada = Person(name = "ada", age = 36, score = 1.5)
        \\    let grace = renamed(ada, "grace")
        \\    print(ada.name + " " + str(ada.age) + " " + str(ada.score))
        \\    print(grace.name + " " + str(grace.age) + " " + str(grace.score))
        \\    ada.age = 37
        \\    print(str(ada.age) + " " + str(grace.age) + " " + str(ada == grace))
        \\
    );
}

test "zero-initialized structs agree, nested ones included" {
    try agree(
        \\struct Inner:
        \\    n: i64
        \\    tag: str
        \\
        \\struct Outer:
        \\    label: str
        \\    inner: Inner
        \\    weight: f64
        \\
        \\func main():
        \\    var grid = new array[Outer](2, 2)
        \\    print("[" + grid[0, 0].label + "][" + grid[0, 0].inner.tag + "]")
        \\    print(str(grid[1, 1].inner.n) + " " + str(grid[1, 1].weight))
        \\    grid[1, 0].inner.n = 7
        \\    print(str(grid[1, 0].inner.n) + " " + str(grid[0, 1].inner.n))
        \\    print(str(grid[0, 0] == grid[0, 1]) + str(grid[0, 0] == grid[1, 0]))
        \\
    );
}

test "an inline array access agrees on every element kind and rank" {
    // Since `Array` storage is typed (`runtime/heap.zig`), a double
    // array is `f64`s and a Bool array is bytes, while a String or an
    // object element keeps the 24-byte slot — and compiled code reads
    // each one inline rather than through the runtime.  Four kinds,
    // two ranks, both engines.
    try agree(
        \\func main():
        \\    var grid = new array[i64](3, 4)
        \\    for r in range(0, 3):
        \\        for c in range(0, 4):
        \\            grid[r, c] = r * 10 + c
        \\    var total: i64 = 0
        \\    for r in range(0, 3):
        \\        for c in range(0, 4):
        \\            total += grid[r, c]
        \\    print(str(total) + " " + str(grid.dim(0)) + " " + str(grid.dim(1)) + " " + str(len(grid)))
        \\
        \\    var names = new array[str](3)
        \\    var flags = new array[bool](3)
        \\    var weights = new array[f64](3)
        \\    for i in range(0, 3):
        \\        names[i] = "n" + str(i)
        \\        flags[i] = i % 2 == 0
        \\        weights[i] = f64(i) * 0.5
        \\    for i in range(0, 3):
        \\        print(names[i] + " " + str(flags[i]) + " " + str(weights[i]))
        \\
        \\    var rows = new array[list[i64]](2)
        \\    for i in range(0, 2):
        \\        var row = new list[i64]
        \\        row.append(i)
        \\        rows[i] = row
        \\    print(str(rows[0][0] + rows[1][0]))
        \\
        \\
    );
}

test "a resolution lifted out of a loop still traps where the access is" {
    // `loops.zig` reads an Array's row once per loop instead of once per
    // access.  What must not move with it is the *deciding*: an index
    // past the end still traps at the access it was made at, with the
    // loop's resolution already lifted above it.
    try agree(
        \\func main():
        \\    var a = new array[f64](4)
        \\    var total: f64 = 0.0
        \\    for i in range(0, 6):
        \\        total += a[i]
        \\    print("unreachable " + str(i64(total)))
        \\
    );
}

test "a lifted resolution on a null row still traps at the access" {
    // The null handle's lifted resolution reads the module's retired row
    // rather than the table: still `null_object`, still at the access and
    // not at the preheader.
    try agree(
        \\func main():
        \\    var rows = new array[array[i64, _]](2)
        \\    var inner = rows[0]
        \\    var total: i64 = 0
        \\    for i in range(0, 3):
        \\        total += inner[i]
        \\    print("unreachable " + str(total))
        \\
    );
}

test "inline str scalar length and slicing agree with explicit raw bytes" {
    try agree(
        \\func main():
        \\    let text = "héllo wörld"
        \\    print(str(len(text)) + " " + str(text.byte_at(0)) + " " + str(text.byte_at(1)))
        \\    print(text[0:1] + "|" + text[1:3] + "|" + text[0:0] + "|" + text[3:len(text)])
        \\    let encoded = bytes(text)
        \\    var i = 0
        \\    var total: i64 = 0
        \\    while i < len(encoded):
        \\        total += i64(encoded[i])
        \\        i += 1
        \\    print(str(total))
        \\
    );
    // Scalar slice bounds cannot split UTF-8. The end of a byte run is
    // still a legal slice bound and not a legal byte index.
    try agree(
        \\func main():
        \\    let text = "héllo"
        \\    print(text[0:2])
        \\
    );
    try agree(
        \\func main():
        \\    let text = "abc"
        \\    print(str(text.byte_at(3)))
        \\
    );
}

test "structs inside containers agree" {
    try agree(
        \\struct Cell:
        \\    value: i64
        \\    name: str
        \\
        \\func main():
        \\    var cells = [Cell(value = 10, name = "a"), Cell(value = 20, name = "b")]
        \\    cells[1].value = 99
        \\    for cell in cells:
        \\        print(cell.name + "=" + str(cell.value))
        \\    print(str(cells[0] == cells[1]) + str(len(cells)))
        \\
    );
}

test "a struct carrying an object is owned and released through its fields" {
    // The struct crosses a return, so the ownership walk has to reach
    // into its fields on both the loosen and the release side; the leak
    // census is what says it did.
    try agree(
        \\struct Bag:
        \\    items: list[i64]
        \\    label: str
        \\
        \\func fill(label: str) -> Bag:
        \\    let xs = new list[i64]
        \\    xs.append(1)
        \\    xs.append(2)
        \\    return Bag(items = xs, label = label)
        \\
        \\func main():
        \\    var bag = fill("b")
        \\    print(str(len(bag.items)) + bag.label)
        \\    bag.items.append(3)
        \\    print(str(len(bag.items)))
        \\
    );
}

// ---------------------------------------------------------------------------
// Absence
// ---------------------------------------------------------------------------
//
// A `T?` lowers to `{T, i1}` and absence on the interpreter is
// `Value.Tag.none`, so these two are the least alike of anything the
// oracle compares: neither engine's representation is the other's.
// What has to match is every answer either can be asked for.

test "a value-typed optional agrees on absence, narrowing, and else" {
    try agree(
        \\func maybe(want: bool) -> i64?:
        \\    if want:
        \\        return 7
        \\    return none
        \\
        \\func main():
        \\    let there = maybe(true)
        \\    if there != none:
        \\        print("there=" + str(there))
        \\    let gone = maybe(false)
        \\    if gone == none:
        \\        print("gone")
        \\    print(str(maybe(false) else -1) + " " + str(maybe(true) else -1))
        \\    var slot: i64? = none
        \\    print(str(slot else -2))
        \\    slot = maybe(true)
        \\    print(str(slot else -2))
        \\
    );
}

test "the else fallback runs only where there was no value, and chains" {
    // The fallback is lazy: `loud` prints, so the printed bytes are
    // what says which side ran.  A chain is the same shape nested, and
    // its middle link must not run either once the first supplies one.
    try agree(
        \\func maybe(want: bool) -> i64?:
        \\    if want:
        \\        return 7
        \\    return none
        \\
        \\func loud(answer: i64) -> i64:
        \\    print("fallback ran")
        \\    return answer
        \\
        \\func main():
        \\    print(str(maybe(true) else loud(1)))
        \\    print(str(maybe(false) else loud(2)))
        \\    print(str(maybe(true) else maybe(false) else loud(3)))
        \\    print(str(maybe(false) else maybe(true) else loud(4)))
        \\    print(str(maybe(false) else maybe(false) else loud(5)))
        \\
    );
}

test "parse_int and parse_float agree when the text is a number and when it is not" {
    // The `long?`/`double?` that made optionals load-bearing on day one.
    try agree(
        \\func main():
        \\    print(str(parse_int("41") else -1))
        \\    print(str(parse_int("") else -1))
        \\    print(str(parse_int("12x") else -1))
        \\    print(str(parse_int("-9") else -1))
        \\    print(str(parse_float("2.5") else -1.0))
        \\    print(str(parse_float("nope") else -1.0))
        \\    let n = parse_int("77")
        \\    if n != none:
        \\        print("narrowed=" + str(n + 1))
        \\
    );
}

test "x else trap is the assert-unwrap, and it traps where it is written" {
    // The trap code, the message, and every frame of the trace have to
    // match — which is the whole of `calc.luc`'s error path.
    try agree(
        \\func want(text: str) -> i64:
        \\    return parse_int(text) else trap("not a number: " + text)
        \\
        \\func middle(text: str) -> i64:
        \\    return want(text) + 1
        \\
        \\func main():
        \\    print(str(middle("41")))
        \\    print(str(middle("oops")))
        \\
    );
}

test "an optional struct field agrees, absent and present" {
    // A `T?` field is stored as a `runtime.Value` on both engines, so
    // this is where the lowered pair meets the tagged slot: absence has
    // to box as the `none` tag and read back as the absent pair.
    try agree(
        \\struct Slot:
        \\    label: str
        \\    room: i64?
        \\
        \\func main():
        \\    var empty = Slot(label = "a", room = none)
        \\    if empty.room == none:
        \\        print("a has no room")
        \\    empty.room = 12
        \\    print("a=" + str(empty.room else 0))
        \\    let filled = Slot(label = "b", room = 3)
        \\    let room = filled.room
        \\    if room != none:
        \\        print("b=" + str(room))
        \\    var zeroed: Slot
        \\    print(str(zeroed.room else -1))
        \\
    );
}

test "a struct recurses through an optional field, which is what ends it" {
    // `Node` holds a `Node?`, and the optional is what makes a struct
    // cycle finite: the field is one `Value` whether or not anything is
    // in it.  Reading one back is the boxed `strukt` payload.
    try agree(
        \\struct Node:
        \\    value: i64
        \\    next: Node?
        \\
        \\func total(from: Node) -> i64:
        \\    var sum = from.value
        \\    let step = from.next
        \\    if step != none:
        \\        sum = sum + total(step)
        \\    return sum
        \\
        \\func main():
        \\    let tail = Node(value = 2, next = none)
        \\    let head = Node(value = 1, next = tail)
        \\    print(str(total(head)))
        \\    print(str(total(tail)))
        \\    let step = head.next
        \\    if step != none:
        \\        print("next=" + str(step.value))
        \\
    );
}

test "a heap optional agrees, and holding none owns nothing (S43)" {
    // The leak census is the proof: the object that came back inside a
    // `T?` is released at the end of the scope that received it, and
    // the absent one leaves nothing behind to release.  A `none` owns
    // nothing, so neither engine may count it.
    try agree(
        \\func pick(want: bool) -> list[i64]?:
        \\    if want:
        \\        let made = new list[i64]
        \\        made.append(3)
        \\        made.append(4)
        \\        return made
        \\    return none
        \\
        \\func main():
        \\    var held: list[i64]? = none
        \\    if held == none:
        \\        print("absent")
        \\    let got = pick(true)
        \\    if got != none:
        \\        print("len=" + str(len(got)) + " first=" + str(got[0]))
        \\    let missing = pick(false)
        \\    if missing == none:
        \\        print("nothing came back")
        \\    let owned = pick(true)
        \\    if owned != none:
        \\        print("owned=" + str(len(owned)))
        \\
    );
}

test "optionals in a loop agree, boxed into container cells and back" {
    // Three seams at once: a `T?` rebuilt every iteration through the
    // one scratch box the call site owns, a `T?` local carrying loop
    // state, and structs with an optional field stored in a `List` —
    // where the field is a `runtime.Value` in a container cell rather
    // than in a frame slot.
    try agree(
        \\struct Cell:
        \\    tag: str
        \\    room: i64?
        \\
        \\func even(n: i64) -> i64?:
        \\    if n % 2 == 0:
        \\        return n
        \\    return none
        \\
        \\func show(room: i64?) -> str:
        \\    if room == none:
        \\        return "-"
        \\    return str(room)
        \\
        \\func main():
        \\    var seen: i64 = 0
        \\    var i = 0
        \\    while i < 8:
        \\        let maybe = even(i)
        \\        if maybe != none:
        \\            seen = seen + maybe
        \\        i = i + 1
        \\    print("sum of evens=" + str(seen))
        \\    var last: i64? = none
        \\    var j = 0
        \\    while j < 5:
        \\        last = even(j)
        \\        j = j + 1
        \\    print("last=" + str(last else -1))
        \\    let cells = new list[Cell]
        \\    var k = 0
        \\    while k < 4:
        \\        cells.append(Cell(tag = str(k), room = even(k)))
        \\        k = k + 1
        \\    var out = ""
        \\    for cell in cells:
        \\        out = out + cell.tag + ":" + show(cell.room) + " "
        \\    print(out)
        \\    print(show(even(2)) + "/" + show(even(3)))
        \\
    );
}

test "every payload a T? can hold survives being returned" {
    // A returned `T?` travels through `%out`, whose `dereferenceable`
    // comes from `resultSize` — a hand-written table, and the one place
    // a wrong number would be a fault rather than a wrong answer.
    // `Bool?` is the corner: `{i1, i1}` really is two bytes, not the
    // eight every other payload rounds up to.
    try agree(
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\func flag(want: bool) -> bool?:
        \\    if want:
        \\        return false
        \\    return none
        \\
        \\func text(want: bool) -> str?:
        \\    if want:
        \\        return "hi"
        \\    return none
        \\
        \\func ratio(want: bool) -> f64?:
        \\    if want:
        \\        return 2.5
        \\    return none
        \\
        \\func spot(want: bool) -> Point?:
        \\    if want:
        \\        return Point(x = 1, y = 2)
        \\    return none
        \\
        \\func main():
        \\    print(str(flag(true) else true) + " " + str(flag(false) else true))
        \\    print((text(true) else "-") + " " + (text(false) else "-"))
        \\    print(str(ratio(true) else -1.0) + " " + str(ratio(false) else -1.0))
        \\    let here = spot(true)
        \\    if here != none:
        \\        print("x=" + str(here.x) + " y=" + str(here.y))
        \\    if spot(false) == none:
        \\        print("no spot")
        \\    let f = flag(true)
        \\    if f != none:
        \\        if f:
        \\            print("true branch")
        \\        else:
        \\            print("false branch")
        \\
    );
}

test "the null object put in a T? is present, because absence is not a handle" {
    // The case that decides the representation.  `raw` is the zero of
    // an object-typed place — the null handle, a value that is *there*
    // and traps on use (S40) — and borrowing it into a `List(long)?`
    // is accepted without a diagnostic.  The interpreter answers
    // "present" because absence there is the tag.  Had the lowering
    // spent the null index on `none`, as docs/FAILURE.md first
    // proposed, this program would answer "absent" instead and the two
    // engines would part company here and nowhere else.
    try agree(
        \\func look(xs: list[i64]?) -> bool:
        \\    return xs == none
        \\
        \\func main():
        \\    var raw: list[i64]
        \\    print("absent=" + str(look(raw)))
        \\    let real = new list[i64]
        \\    real.append(1)
        \\    print("absent=" + str(look(real)))
        \\
    );
}

// ---------------------------------------------------------------------------
// The host services
// ---------------------------------------------------------------------------

test "files, arguments, the screen, and the keyboard agree" {
    try agree(
        \\func main(args: list[str]) -> !:
        \\    print(str(len(args)) + " " + args[0] + "," + args[1])
        \\    print(str(try path_kind("notes.txt")))
        \\    try file_write("notes.txt", "hello world")
        \\    print(str(try path_kind("notes.txt")) + " " + try file_read("notes.txt"))
        \\    print(str(term_rows()) + "x" + str(term_cols()))
        \\    term_clear()
        \\    term_move(2, 3)
        \\    term_style(114, 236, true)
        \\    term_write("drawn")
        \\    term_flush()
        \\    var pressed = 0
        \\    while pressed < 4:
        \\        let name = key_read()
        \\        print((name else "<end of input>") + "/" + key_text())
        \\        pressed = pressed + 1
        \\
    );
}

test "a keyboard that has run dry answers none on both engines" {
    // The default script is three keys and this asks for five, so the
    // last two are end of input.  Both engines have to say `none`, and
    // both have to empty `key_text` with it: a payload left standing
    // from the last real key would make the two answers differ in the
    // one place a program looks.
    //
    // This is the case that used to have no answer at all.  `no` from
    // the host was read by nobody, so a program at the end of its
    // input asked again forever.
    try agree(
        \\func main():
        \\    var pressed = 0
        \\    while pressed < 5:
        \\        let name = key_read()
        \\        if name == none:
        \\            print("dry/" + key_text())
        \\        else:
        \\            print(name + "/" + key_text())
        \\        pressed = pressed + 1
        \\
    );
}

test "a file that was never written errors on both engines" {
    // The world said no, so this is news and not a bug: the two
    // engines have to agree on the code, the words, and the one line
    // the error records (docs/FAILURE.md).
    try agree(
        \\func main() -> !:
        \\    print("before")
        \\    print(try file_read("nothing-here.txt"))
        \\
    );
}

// ---------------------------------------------------------------------------
// The host surface, on both engines
// ---------------------------------------------------------------------------

test "standard input, standard error, the clock and the environment agree" {
    try agree(
        \\func main():
        \\    let first = read_line("> ") else "(nothing)"
        \\    let second = read_line("> ") else "(nothing)"
        \\    let third = read_line("> ") else "(nothing)"
        \\    print(first + "|" + second + "|" + third)
        \\    print_error("something went sideways")
        \\    let started = clock_ms()
        \\    sleep_ms(25)
        \\    let ended = clock_ms()
        \\    print("elapsed " + str(ended - started))
        \\    sleep_ms(0)
        \\    sleep_ms(-1)
        \\    print(env("LUCE_MODE") else "(unset)")
        \\    print("[" + (env("EMPTY") else "(unset)") + "]")
        \\    print(env("NOT_SET_ANYWHERE") else "(unset)")
        \\
    );
}

test "end of input is absence, and narrowing sees it on both engines" {
    try agree(
        \\func main():
        \\    var count = 0
        \\    var line = read_line("")
        \\    while line != none:
        \\        count = count + 1
        \\        print(str(count) + ": " + line)
        \\        line = read_line("")
        \\    print("read " + str(count) + " lines, then nothing")
        \\
    );
}

test "the file services beyond read and write agree, and so does what they refuse" {
    try agree(
        \\func main() -> !:
        \\    try file_write("notes.txt", "one\n")
        \\    try file_append("notes.txt", "two\n")
        \\    print(try file_read("notes.txt"))
        \\    try file_rename("notes.txt", "kept.txt")
        \\    print(str(try path_kind("notes.txt")) + " " + str(try path_kind("kept.txt")))
        \\    try file_delete("kept.txt")
        \\    print(str(try path_kind("kept.txt")))
        \\    file_delete("kept.txt") catch:
        \\        print("nothing to delete")
        \\    file_rename("gone.txt", "elsewhere.txt") catch:
        \\        print("nothing to rename")
        \\    try file_append("fresh.txt", "made by append\n")
        \\    print(try file_read("fresh.txt"))
        \\
    );
}

test "a directory listing is a List(String) the program owns, on both engines" {
    try agree(
        \\func main() -> !:
        \\    let names = try dir_list(".")
        \\    print(str(len(names)))
        \\    for name in names:
        \\        print(name)
        \\    names.sort()
        \\    print(names[0])
        \\
    );
}

test "a directory that will not list is an error on both engines" {
    try agree(
        \\func main() -> !:
        \\    print("before")
        \\    let names = try dir_list("nowhere")
        \\
    );
}

test "a caught listing failure leaks nothing on either engine" {
    // The failing side parks a value nobody reads, and the value it
    // parks must not be an object the census then counts.
    try agree(
        \\func main():
        \\    var found: i64 = 0
        \\    let names = dir_list("nowhere") catch new list[str]
        \\    found = len(names)
        \\    print("caught, " + str(found) + " names")
        \\
    );
}

test "each new host service fails closed on its own" {
    try agreeGiven(
        \\func main():
        \\    print(read_line("> ") else "x")
        \\
    , .{ .input = false });
    try agreeGiven(
        \\func main():
        \\    print_error("nobody is listening")
        \\
    , .{ .diagnostics = false });
    try agreeGiven(
        \\func main():
        \\    print(str(clock_ms()))
        \\
    , .{ .clock = false });
    try agreeGiven(
        \\func main():
        \\    sleep_ms(5)
        \\
    , .{ .clock = false });
    try agreeGiven(
        \\func main():
        \\    print(env("PATH") else "x")
        \\
    , .{ .environment = false });
    try agreeGiven(
        \\func main() -> !:
        \\    try file_append("x.txt", "y")
        \\
    , .{ .files = false });
    try agreeGiven(
        \\func main() -> !:
        \\    try file_delete("x.txt")
        \\
    , .{ .files = false });
    try agreeGiven(
        \\func main() -> !:
        \\    try file_rename("x.txt", "y.txt")
        \\
    , .{ .files = false });
    try agreeGiven(
        \\func main() -> !:
        \\    let names = try dir_list(".")
        \\
    , .{ .files = false });
}

test "a caught error is handled and the run finishes clean" {
    try agree(
        \\func main():
        \\    let text = file_read("nothing-here.txt") catch "(none)"
        \\    print(text)
        \\    file_write("/nowhere/at/all/notes.txt", "x") catch:
        \\        print("write refused")
        \\    print("still running")
        \\
    );
}

test "error() crosses several frames, and the origin is the raise site" {
    try agree(
        \\func inner(n: i64) -> i64!:
        \\    if n > 2:
        \\        error("too big: " + str(n))
        \\    return n * 2
        \\
        \\func middle(n: i64) -> i64!:
        \\    return try inner(n)
        \\
        \\func outer(n: i64) -> i64!:
        \\    return try middle(n)
        \\
        \\func main() -> !:
        \\    print(str(try outer(1)))
        \\    print(str(try outer(5)))
        \\
    );
}

test "an error path releases the objects and the String storage it owns" {
    // The leak census is the proof: every frame the error left
    // through released what it owned, so a caught error leaves the
    // heap exactly where a returning call would (S4, S34).
    try agree(
        \\func gather(path: str) -> i64!:
        \\    let words = new list[str]
        \\    words.append("alpha")
        \\    words.append("beta")
        \\    let held = "prefix-" + path
        \\    let text = try file_read(path)
        \\    words.append(held + text)
        \\    return len(words)
        \\
        \\func main():
        \\    var total: i64 = 0
        \\    var round = 0
        \\    while round < 3:
        \\        total = total + (gather("nothing-here.txt") catch -1)
        \\        round = round + 1
        \\    print(str(total))
        \\
    );
}

test "text carried across a try keeps the form it was in" {
    // The crossing a `try` needs is where errors and small-string
    // optimisation meet.  A fallible call's result has to survive the
    // branch on its outcome, and the slot it crosses in is the slot
    // that owns it — so short text stays inside the value and long
    // text keeps pointing where it did (docs/STRINGS.md).  Carrying
    // it in a borrowing slot instead marked inline text as *outside*,
    // and the release at the end of the statement freed a pointer into
    // the frame.
    try agree(
        \\func main() -> !:
        \\    try file_write("notes.txt", "hello world")
        \\    let brief = try file_read("notes.txt")
        \\    print(brief + "/" + str(len(brief)))
        \\    try file_write("notes.txt", "a string well past the inline capacity of a value")
        \\    let lengthy = try file_read("notes.txt")
        \\    print(lengthy + "/" + str(len(lengthy)))
        \\    print(str(try path_kind("notes.txt")) + " " + try file_read("notes.txt"))
        \\
    );
}

test "a caught error leaves the value it never produced releasable" {
    // A fallible function that errors writes nothing through `%out`,
    // and the store that carries its result across the branch runs on
    // that path too.  So the errored edge empties `%out` on the way
    // out, and what the caller carries is the empty String rather than
    // whatever the stack held — which the census then proves.
    try agree(
        \\func load(path: str) -> str!:
        \\    return try file_read(path)
        \\
        \\func main():
        \\    var round = 0
        \\    while round < 3:
        \\        let text = load("nothing-here.txt") catch "(none)"
        \\        print(text)
        \\        round = round + 1
        \\
    );
}

test "a fallible call handing back an object gives it up on both paths" {
    try agree(
        \\func load(path: str) -> list[str]!:
        \\    let lines = new list[str]
        \\    lines.append(try file_read(path))
        \\    return lines
        \\
        \\func main():
        \\    let missing = load("nothing-here.txt") catch new list[str]
        \\    print(str(len(missing)))
        \\
    );
}

test "an argument index out of range traps index_bounds on both engines" {
    // `args` is an ordinary List, so reading past it is the language's
    // own bounds trap and not a channel of its own (docs/LANGUAGE.md).
    try agree(
        \\func main(args: list[str]):
        \\    print(args[0])
        \\    print(args[9])
        \\
    );
}

test "a withheld service group fails closed on both engines" {
    try agreeGiven(
        \\func main() -> !:
        \\    print(str(try path_kind("notes.txt")))
        \\
    , .{ .files = false });
    try agreeGiven(
        \\func main():
        \\    print(str(term_rows()))
        \\
    , .{ .terminal = false });
    try agreeGiven(
        \\func main():
        \\    print(key_text())
        \\
    , .{ .terminal = false });
}

test "owned String bytes agree, census included" {
    // docs/STRINGS.md's store sites, all on one page: a returned view
    // of a parameter, a container that keeps what it is handed, a copy
    // that outlives its original, a field assigned twice, a map's keys
    // and values, and a read that survives a call emptying the
    // container it came from.  `agree` compares the leak census as
    // well as the bytes, so a store that forgot to copy shows up here
    // even when it prints the same.
    try agree(
        \\import std.strings
        \\
        \\struct Tag:
        \\    label: str
        \\    count: i64
        \\
        \\func widen(s: str) -> str:
        \\    return strings.trim(s)
        \\
        \\func drop_first(pieces: list[str]) -> i64:
        \\    pieces.remove(0)
        \\    return 1
        \\
        \\func measure(left: str, right: i64) -> i64:
        \\    return len(left) + right
        \\
        \\func main():
        \\    let trimmed = widen("   padded   ")
        \\    print(trimmed)
        \\
        \\    var names = new list[str]
        \\    names.append("ada")
        \\    names.append(trimmed + "-lovelace")
        \\    names[0] = names[1]
        \\    print(names[0] + " " + str(len(names)))
        \\    var duplicate = names
        \\    print(duplicate[1])
        \\
        \\    var tag = Tag(label = "one", count = 1)
        \\    tag.label = "two"
        \\    tag.label = tag.label + "-three"
        \\    var copied = tag
        \\    copied.label = "other"
        \\    print(tag.label + " " + copied.label)
        \\
        \\    var table = new map[str, str]
        \\    table["k" + str(1)] = "v1"
        \\    table["k1"] = "v" + str(2)
        \\    var keys = table.keys()
        \\    var values = table.values()
        \\    print(keys[0] + values[0])
        \\    table.remove("k1")
        \\
        \\    var pieces = new list[str]
        \\    pieces.append("first-piece")
        \\    pieces.append("second")
        \\    print(str(measure(pieces[0], drop_first(pieces))))
        \\
        \\    var text = "abcdef"
        \\    text = text[1:5]
        \\    text = text + text
        \\    print(text)
        \\
        \\    var cells = new array[str](3)
        \\    cells[0] = "x" + str(0)
        \\    cells[1] = cells[0]
        \\    cells[0] = "y"
        \\    print(cells[0] + cells[1] + str(len(cells[2])))
        \\
    );
}

test "text agrees on both sides of the boundary between its two forms" {
    // Short text lives inside the value and long text behind a pointer
    // (docs/STRINGS.md), and the two engines choose the same form for
    // the same bytes — but nothing in the language says so, which is
    // exactly why every length around the boundary is checked here on
    // every path a String can take: a binding, a container element, a
    // map key, a struct field, a return, a slice, and a concat.
    //
    // 22 is `runtime.inline_capacity`.  If that number ever moves,
    // these lengths must move with it.
    try agree(
        \\import std.strings
        \\
        \\struct Held:
        \\    label: str
        \\
        \\func echo(s: str) -> str:
        \\    return s
        \\
        \\func grow(s: str) -> str:
        \\    return s + s
        \\
        \\func main():
        \\    var words = new list[str]
        \\    var table = new map[str, str]
        \\    for size in [0, 1, 21, 22, 23, 64]:
        \\        let text = strings.repeat("a", size)
        \\        let kept = echo(text)
        \\        words.append(kept)
        \\        table[kept] = kept
        \\        let held = Held(label = kept)
        \\        print(str(size) + " " + str(len(kept)) + " " + str(len(held.label)) +
        \\            " " + str(len(words[len(words) - 1])) + " " + str(len(table[kept])) +
        \\            " " + str(table.has(kept)))
        \\
    );
    // The transitions in both directions: short grown long by `+`,
    // long cut back to short by a slice, and both stored afterwards.
    try agree(
        \\import std.strings
        \\
        \\func grow(s: str) -> str:
        \\    return s + s
        \\
        \\func main():
        \\    var kept = new list[str]
        \\    for size in [1, 11, 12, 21, 22, 23]:
        \\        var text = strings.repeat("b", size)
        \\        text = grow(text)
        \\        kept.append(text)
        \\        var cut = text[0:1]
        \\        cut = cut + text[0:size]
        \\        kept.append(cut)
        \\        print(str(len(text)) + ":" + text + " " + str(len(cut)) + ":" + cut)
        \\    var joined = ""
        \\    for piece in kept:
        \\        joined = joined + str(len(piece)) + ","
        \\    print(joined)
        \\
    );
    // A long String cut down to short, kept, and then the original
    // overwritten — the case where a borrow of the long bytes would
    // still be looking at them.
    try agree(
        \\import std.strings
        \\
        \\func main():
        \\    var source = strings.repeat("cd", 40)
        \\    var small = source[0:6]
        \\    var cells = new array[str](2)
        \\    cells[0] = small
        \\    cells[1] = source
        \\    source = "replaced"
        \\    small = small + "!"
        \\    print(cells[0] + " " + str(len(cells[1])) + " " + small + " " + source)
        \\
    );
}

test "a loop name agrees whether it borrows its element or copies it" {
    try agree(
        \\func main():
        \\    var words = new list[str]
        \\    words.append("aa")
        \\    words.append("bb")
        \\    words.append("cc")
        \\    var total: i64 = 0
        \\    for w in words:
        \\        total += len(w)
        \\    print(str(total))
        \\    var seen = ""
        \\    for w in words:
        \\        seen = seen + w
        \\        words[0] = "zz"
        \\    print(seen)
        \\
        \\    var table = new map[str, str]
        \\    table["a"] = "1"
        \\    table["b"] = "2"
        \\    var joined = ""
        \\    for key, value in table:
        \\        joined = joined + key + value
        \\    print(joined)
        \\
    );
}

test "a trap agrees while every frame is still holding String bytes" {
    try agree(
        \\struct Tag:
        \\    label: str
        \\    count: i64
        \\
        \\func deeper(name: str) -> i64:
        \\    let held = name + "-held"
        \\    var tag = Tag(label = held, count = 1)
        \\    trap(tag.label)
        \\
        \\func main():
        \\    let outer = "kept" + "-here"
        \\    var also = Tag(label = outer, count = 2)
        \\    print(str(deeper(also.label)))
        \\
    );
}

test "array loops carry the two alias scopes, and runtime calls carry neither" {
    // Task #45's payoff, pinned at the IR: element accesses disclaim
    // the rows scope and row facts disclaim the elements one, so LICM
    // may hoist a row's facts over a loop of element stores.  The
    // scopes' shape (domain, named scopes) is proven at the Builder
    // (codegen/builder.zig); what this pins is that the lowering
    // actually says it.
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\func main():
        \\    var grid = new array[i64](64)
        \\    var i = 0
        \\    while i < 64:
        \\        grid[i] = i * 2
        \\        i += 1
        \\    print(str(grid[63]))
        \\
    )).?;
    defer gpa.free(rendered);
    errdefer std.debug.print("rendered IR:\n{s}\n", .{rendered});

    try std.testing.expect(std.mem.indexOf(u8, rendered, "!alias.scope !") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "!noalias !") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "!\"luce.rows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "!\"luce.elements\"") != null);
    // The store of an element wears both scopes on its line, and no
    // runtime call wears either — calls stay conservative.
    var lines = std.mem.splitScalar(u8, rendered, '\n');
    var element_store_scoped = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "call ") != null) {
            try std.testing.expect(std.mem.indexOf(u8, line, "!alias.scope") == null);
            continue;
        }
        if (std.mem.indexOf(u8, line, "store i64 ") == null) continue;
        if (std.mem.indexOf(u8, line, "!alias.scope") != null and
            std.mem.indexOf(u8, line, "!noalias") != null) element_store_scoped = true;
    }
    try std.testing.expect(element_store_scoped);
}

test "fresh container writes omit the constant guard and unknown aliases keep it" {
    // ARC makes references shareable, but it does not make a row created by
    // heap_new capable of becoming a program constant after the constants
    // prologue. Keeping the guard out of this path is what lets LLVM
    // vectorize a loop of writes; the final-MIR proof in mutability.zig is the
    // authority, not a trusted source or serialized flag.
    const gpa = std.testing.allocator;
    const fresh = (try render(
        \\func main():
        \\    var values = new array[i64](64)
        \\    for i in range(0, 64):
        \\        values[i] = i
        \\    print(str(values[63]))
        \\
    )).?;
    defer gpa.free(fresh);
    const immutable = mir.TrapCode.immutable_object.message();
    try std.testing.expect(std.mem.indexOf(u8, fresh, immutable) == null);

    // A parameter may be an alias of a file-scope constant, so its inline
    // store keeps the runtime's immutable_object backstop.
    const unknown = (try render(
        \\const VALUES: array[i64, _] = [1, 2]
        \\
        \\func change(values: array[i64, _]):
        \\    values[0] = 9
        \\
        \\func main():
        \\    change(VALUES)
        \\
    )).?;
    defer gpa.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, immutable) != null);
}

test "a program that never spawns pays nothing for threads" {
    // **This is docs/THREADS.md D11, and it is structural rather than
    // measured.**  The claim is not that the effect lock is cheap; it
    // is that a spawn-free program's module does not contain one — no
    // worker trampoline, no `luce_rt_workers_install` in the prologue,
    // and no `luce_rt_effects_enter` around the `print` that reaches
    // the host.  A benchmark can only ever say "within noise"; this
    // says "not emitted", which is the promise that was made.
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\func main():
        \\    var total: i64 = 0
        \\    for i in range(0, 10):
        \\        total = total + i
        \\    print(str(total))
        \\
    )).?;
    defer gpa.free(rendered);
    errdefer std.debug.print("rendered IR:\n{s}\n", .{rendered});

    try std.testing.expect(std.mem.indexOf(u8, rendered, "luce.worker") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "luce_rt_workers_install") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "luce_rt_effects_enter") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "luce_rt_effects_leave") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "luce_rt_spawn") == null);
}

test "a program that spawns installs the channel once and brackets every host call" {
    // The other direction of the same promise: what a spawning program
    // *does* emit, so the absence above is a fact about the program
    // rather than about the lowering having been left out.
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\func announce(n: i64) -> i64:
        \\    print(str(n))
        \\    return n
        \\
        \\func main():
        \\    let t = spawn announce(1)
        \\    print(str(t.wait()))
        \\
    )).?;
    defer gpa.free(rendered);
    errdefer std.debug.print("rendered IR:\n{s}\n", .{rendered});

    try std.testing.expect(std.mem.indexOf(u8, rendered, "@luce.worker") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "luce_rt_workers_install") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "luce_rt_spawn") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "luce_rt_task_wait") != null);
    // Exactly one install, in the prologue, however many spawns there
    // are: it is a fact about the run and not about a call site.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, rendered, "call void @luce_rt_workers_install"),
    );
    // The lock brackets each host call, and both halves are there.
    const entered = std.mem.count(u8, rendered, "call void @luce_rt_effects_enter");
    const left = std.mem.count(u8, rendered, "call void @luce_rt_effects_leave");
    try std.testing.expect(entered != 0);
    try std.testing.expectEqual(entered, left);
}
