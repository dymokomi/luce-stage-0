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
const abi = luce.llvm.abi;
const artifact = luce.llvm.artifact;
const runtime_effects = luce.llvm.effects;

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
        \\func main(args: list(string)):
        \\    let n = parse_int(args[0])
        \\    print(string(n else 0))
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
        \\    x: double
        \\    y: double
        \\
        \\func main(args: list(string)) -> !:
        \\    let p = Point(x = 1.5, y = -0.0)
        \\    print(string(p.x * 2.0) + string(long(p.y)) + string(sqrt(4.0)) + string(sqrt(p.x)))
        \\    print(args[0] + string(len(args)) + string(try path_kind("nowhere")))
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
        // (docs/TYPES.md §9): the unannotated literal is a `float` and
        // the struct field is a `double`, so both intrinsics have to
        // be here — one of them alone would mean the analyzer had
        // widened something it was told not to.
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
        \\    circle(radius: double)
        \\    rect(width: double, height: double)
        \\
        \\func kind(s: Shape) -> long:
        \\    match s:
        \\        empty:
        \\            return 0
        \\        circle(radius):
        \\            return long(radius)
        \\        rect:
        \\            return 2
        \\
        \\func main():
        \\    var cells = new array(Shape, 2)
        \\    cells[1] = Shape.circle(radius = 4.0)
        \\    print(string(kind(cells[1])))
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
        \\    let xs = new list(long)
        \\    let counts = new map(string, long)
        \\    xs.append(1)
        \\    print(string(len(counts)) + string(xs.pop()))
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
        \\func ratio(value: long) -> long:
        \\    return 10 // value
        \\
        \\func main():
        \\    print(string(ratio(2)))
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
        \\func twice(n: long) -> long:
        \\    return n * 2
        \\
        \\func apply(f: func(long) -> long, n: long) -> long:
        \\    return f(n)
        \\
        \\func main():
        \\    let left: func(long) -> long = twice
        \\    let right: func(long) -> long = twice
        \\    print(string(apply(left, 1)))
        \\    print(string(apply(right, 2)))
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
    switch (try luce.llvm.lowerToText(gpa, &program, .{ .triple = triple })) {
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
        \\    var grid = new array(long, 2, 2)
        \\    var row = 0
        \\    while row < 2:
        \\        grid[row, 0] = row * 2
        \\        row = row + 1
        \\    print(string(grid[1, 0]))
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
        \\    let counts = new map(string, long)
        \\    counts["one"] = 1
        \\    print(string(len(counts)) + string(counts["one"]))
        \\    free(counts)
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
    \\    text: string
    \\    rank: long
    \\
    \\const labels: list(Label) = [Label(text = "first", rank = 1)]
    \\const axis: array(long, _) = [3, 5, 8]
    \\const lookup: map(string, long) = {"one": 1, "two": 2}
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
        \\const unused: list(long) = [1, 2, 3]
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
    \\const seeds: list(long) = [13, 21]
    \\
    \\func first() -> long:
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
        \\const seeds: list(long) = [3, 1, 2]
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
        \\    value: long
        \\
        \\    func step():
        \\        self.value += 1
        \\
        \\    func twice():
        \\        self.step()
        \\        self.step()
        \\
        \\    func reject(value: long) -> !:
        \\        self.value = value
        \\        error("failed")
        \\
        \\struct Holder:
        \\    values: list(long)
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
        \\    print(string(total))
        \\    print(string(-total))
        \\    print(string(total // 4))
        \\
    , &capture, .{});

    // 4 + 16 + 36 + 64 + 100 = 220; 1 + 3 + 5 + 7 + 9 = 25; 220 - 25 = 195.
    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("195\n-195\n48\n", capture.printed());
}

test "calls and recursion carry values back and traps forward" {
    var capture: Capture = .{};

    const status = try run(
        \\func fib(n: long) -> long:
        \\    if n < 2:
        \\        return n
        \\    return fib(n - 1) + fib(n - 2)
        \\
        \\func name_of(name: string, value: long) -> string:
        \\    if value > 0:
        \\        return name
        \\    return "none"
        \\
        \\func main():
        \\    print(name_of("fib", fib(20)))
        \\    print(string(fib(20)))
        \\
    , &capture, .{});

    try std.testing.expectEqual(abi.Status.ok, status);
    try std.testing.expectEqualStrings("fib\n6765\n", capture.printed());
}

test "string of an unwritten function traps null_object on both engines" {
    var program = try spec.program(
        \\func twice(n: long) -> long:
        \\    return n * 2
        \\
        \\func main():
        \\    let chosen: func(long) -> long = twice
        \\    print(string(chosen))
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
        \\func step(total: long, index: long) -> long:
        \\    if index % 7 == 0:
        \\        return total + index
        \\    return total
        \\
        \\func main():
        \\    var total: long = 0
        \\    var index = 0
        \\    while index < 1000000:
        \\        total = step(total, index)
        \\        index = index + 1
        \\    print(string(total))
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
        \\func divide(a: long, b: long) -> long:
        \\    return a // b
        \\
        \\func main():
        \\    print("before")
        \\    print(string(divide(1, 0)))
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
        \\    print(string(value))
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
        \\func deep(n: long) -> long:
        \\    return 1 + deep(n - 1)
        \\
        \\func main():
        \\    print("before")
        \\    print(string(deep(1000000)))
        \\
    );
}

test "mutual recursion and a shallow limit agree on where the depth ran out" {
    try agreeGiven(
        \\func ping(n: long) -> long:
        \\    return pong(n + 1)
        \\
        \\func pong(n: long) -> long:
        \\    return ping(n + 1)
        \\
        \\func main():
        \\    print(string(ping(0)))
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
        \\func divide(a: long, b: long) -> long:
        \\    return a // b
        \\
        \\func ratio(n: long) -> long:
        \\    return divide(n, 0)
        \\
        \\func main():
        \\    print(string(ratio(7)))
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
        \\func divide(a: long, b: long) -> long:
        \\    return a // b
        \\
        \\func ratio(n: long) -> long:
        \\    return divide(n, 0)
        \\
        \\func main():
        \\    print(string(ratio(7)))
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
        \\func deep(n: long) -> long:
        \\    return 1 + deep(n - 1)
        \\
        \\func main():
        \\    print(string(deep(1000000)))
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
        \\    print(string(try path_kind(".")))
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
        \\func total(xs: list(long)) -> long:
        \\    var sum: long = 0
        \\    for x in xs:
        \\        sum = sum + x
        \\    return sum
        \\
        \\func main():
        \\    let xs = new list(long)
        \\    var i = 1
        \\    while i <= 5:
        \\        xs.append(i * i)
        \\        i = i + 1
        \\    xs.append(0)
        \\    xs.sort()
        \\    print(string(xs[0]) + "," + string(xs[5]) + "," + string(len(xs)))
        \\    print(string(total(xs)))
        \\    print(string(xs.find(9) else -1) + " " + string(xs.contains(7)))
        \\
        \\    let names = new map(string, long)
        \\    names["one"] = 1
        \\    names["two"] = 2
        \\    names["one"] = 11
        \\    print(string(len(names)) + " " + string(names["one"]) + " " + string(names.get("three") else -1))
        \\    for name, count in names:
        \\        print(name + "=" + string(count))
        \\    print(string(names.has("two")) + " " + string(len(names.keys())))
        \\
        \\    let text = new builder
        \\    text.append("ab")
        \\    text.append_ascii(99)
        \\    let word = text.build()
        \\    print(word + " " + string(len(word)) + " " + string(word.byte_at(0)))
        \\    print(word[1:3] + " " + string(word.find_byte(99, 0)))
        \\    print(string(41 + 1) + chr(33) + string(ord("A")))
        \\    print(string("abc" < "abd") + string("abc" == "abc"))
        \\
        \\    let kept = copy xs
        \\    print(string(len(kept)))
        \\    free(kept)
        \\    free(names)
        \\    free(text)
        \\    free(xs)
        \\
    );
}

// Move-instead-of-copy (docs/STRINGS.md step 6).  Every string below
// is well past the twenty-two byte inline threshold, so each store is
// a real allocation with a real owner: a move that skipped a release
// is a leak the census and the test allocator both report, and a move
// that should not have happened is a double free.
test "a fresh value moves into every kind of place, and a borrow still copies" {
    try agree(
        \\struct Note:
        \\    title: string
        \\    body: string
        \\
        \\func joined(a: string, b: string) -> string:
        \\    return a + b
        \\
        \\func main():
        \\    let head = "a string comfortably past the inline threshold"
        \\    let tail = "-and a tail that is well past it on its own"
        \\
        \\    # A list element takes the temporary's allocation; a
        \\    # borrow of an element still copies, because appending can
        \\    # move the very cell it was read out of.
        \\    var xs: list(string) = [head + tail]
        \\    xs.append(joined(head, tail))
        \\    xs.append(xs[0])
        \\    xs.append(xs[0][0:30])
        \\    xs.insert(0, head + tail)
        \\    print(string(len(xs)) + " " + string(len(xs[2])) + " " + string(len(xs[4])))
        \\
        \\    # A map value moves; the key beside it is a borrow the map
        \\    # copies for itself, and m[k] = m[k] stays legal.
        \\    var m: map(string, string) = new map(string, string)
        \\    m[head] = head + tail
        \\    m[head] = m[head]
        \\    m[tail] = joined(tail, head)
        \\    print(string(len(m)) + " " + string(len(m[head])) + " " + string(len(m[tail])))
        \\
        \\    # A struct field moves at construction and at assignment;
        \\    # a field read out of the same struct copies.
        \\    var note = Note(title = head + tail, body = head)
        \\    note.body = joined(tail, head)
        \\    note.title = note.body
        \\    print(string(len(note.title)) + " " + string(len(note.body)))
        \\
        \\    free(xs)
        \\    free(m)
        \\
    );
}

test "a value still live after a store is copied, and a returned borrow too" {
    try agree(
        \\func fresh(a: string, b: string) -> string:
        \\    return a + b
        \\
        \\func borrowed(s: string) -> string:
        \\    return s[4:40]
        \\
        \\func passed(s: string) -> string:
        \\    return s
        \\
        \\func main():
        \\    let head = "a string comfortably past the inline threshold"
        \\    let tail = "-and a tail that is well past it on its own"
        \\
        \\    # `kept` is read after both stores, so neither can take
        \\    # its bytes; a reassignment that reads its own place is
        \\    # the same question one statement wide.
        \\    var kept = head + tail
        \\    var xs: list(string) = [kept]
        \\    xs.append(kept)
        \\    kept = kept[2:44]
        \\    kept = kept + "!"
        \\    print(string(len(kept)) + " " + string(len(xs[0])) + " " + string(len(xs[1])))
        \\
        \\    # A string return is a copy unless the frame made it.
        \\    xs.append(fresh(head, tail))
        \\    xs.append(borrowed(head))
        \\    xs.append(passed(head))
        \\    print(string(len(xs[2])) + " " + string(len(xs[3])) + " " + string(len(xs[4])))
        \\    free(xs)
        \\
    );
}

test "a store that traps still owns what it was handed" {
    try agree(
        \\func main():
        \\    let head = "a string comfortably past the inline threshold"
        \\    var xs: list(string) = [head]
        \\    print(string(len(xs)))
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
        \\    var xs: list(string) = []
        \\    let text = file_read("notes.txt") catch "(none)"
        \\    xs.append(text)
        \\    xs.append(file_read("notes.txt") catch "(none)")
        \\    xs.append(text + "!")
        \\    print(string(len(xs)) + " " + string(len(xs[0])) + " " + string(len(xs[2])))
        \\    free(xs)
        \\
    );
}

test "a nested container agrees, and the leak census counts the same" {
    try agree(
        \\func main():
        \\    let rows = new list(list(long))
        \\    var r = 0
        \\    while r < 3:
        \\        let row = new list(long)
        \\        row.append(r)
        \\        row.append(r * 10)
        \\        rows.append(give row)
        \\        r = r + 1
        \\    print(string(len(rows)) + " " + string(rows[2][1]))
        \\    let leaked = new list(long)
        \\    leaked.append(1)
        \\    print("done")
        \\    free(rows)
        \\
    );
}

test "an alias used after the owner freed agrees: use_after_free (S9)" {
    try agree(
        \\func main():
        \\    var xs = new list(long)
        \\    xs.append(1)
        \\    let view = xs
        \\    free(xs)
        \\    print("freed")
        \\    print(string(len(view)))
        \\
    );
}

test "a stale alias whose row was reused agrees: still use_after_free (S9)" {
    // The row `xs` vacates is the row `fresh` moves into, so the two
    // handles differ only in their generation — and that is the whole
    // of what keeps `stale` from quietly becoming a second name for
    // `fresh` on either engine.  Compiled code makes this test itself,
    // inline, with the row's generation against the handle's.
    try agree(
        \\func main():
        \\    var xs = new list(long)
        \\    xs.append(1)
        \\    let stale = xs
        \\    free(xs)
        \\    let fresh = new list(long)
        \\    fresh.append(10)
        \\    fresh.append(20)
        \\    if stale == fresh:
        \\        print("aliased")
        \\    else:
        \\        print("distinct")
        \\    print(string(len(fresh)))
        \\    print(string(len(stale)))
        \\
    );
}

test "a reused row is refused by every door, and the newcomer by none" {
    // The same reuse reached through indexing, iteration and the
    // ownership verbs rather than through `len`, because each takes a
    // different route to the row.
    try agree(
        \\func main():
        \\    var rows = new list(list(long))
        \\    var doomed = new list(long)
        \\    doomed.append(7)
        \\    let stale = doomed
        \\    free(doomed)
        \\    let fresh = new list(long)
        \\    fresh.append(3)
        \\    rows.append(give fresh)
        \\    print(string(rows[0][0]))
        \\    print(string(stale[0]))
        \\
    );
}

test "an index out of bounds agrees" {
    try agree(
        \\func main():
        \\    let xs = new list(long)
        \\    xs.append(1)
        \\    print("one")
        \\    print(string(xs[3]))
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
        \\    let values = new list(double)
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
        \\            print(string(a) + " " + string(b) + " = " + string(a + b) + " " + string(a - b) +
        \\                " " + string(a * b) + " " + string(a / b) + " " + string(a % b))
        \\            print("  " + string(a == b) + string(a != b) + string(a < b) +
        \\                string(a <= b) + string(a > b) + string(a >= b))
        \\            print("  " + string(min(a, b)) + " " + string(max(a, b)) + " " +
        \\                string(clamp(a, -1.0, 1.0)) + " " + string(abs(a)) + " " + string(-a))
        \\            j = j + 1
        \\        i = i + 1
        \\    free(values)
        \\
    );
}

test "negating a float flips the sign bit, so -0.0 survives" {
    try agree(
        \\func main():
        \\    var zero = 0.0
        \\    let negative = -zero
        \\    print(string(negative) + " " + string(1.0 / negative))
        \\    print(string(zero == negative) + string(1.0 / zero == 1.0 / negative))
        \\    print(string(-negative) + " " + string(0.0 - zero))
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
        \\func lowest(xs: array(double, _)) -> double:
        \\    var smallest = xs[0]
        \\    for i in range(1, len(xs)):
        \\        smallest = min(smallest, xs[i])
        \\    return smallest
        \\
        \\func highest(xs: array(double, _)) -> double:
        \\    var largest = xs[0]
        \\    for i in range(1, len(xs)):
        \\        largest = max(largest, xs[i])
        \\    return largest
        \\
        \\func main():
        \\    let control = new list(double)
        \\    control.append(0.0)
        \\    control.append(-0.0)
        \\    control.append(0.0 / 0.0)
        \\    let n = len(control) * 5
        \\    var xs = new array(double, n)
        \\    for pattern in range(0, 32):
        \\        for i in range(0, n):
        \\            xs[i] = control[(pattern // (i % 5 + 1)) % 2]
        \\        let low = lowest(xs)
        \\        let high = highest(xs)
        \\        print(string(low) + " " + string(1.0 / low) + " " +
        \\            string(high) + " " + string(1.0 / high))
        \\    for at in range(0, n):
        \\        for i in range(0, n):
        \\            xs[i] = double(i + 1)
        \\        xs[at] = control[2]
        \\        print(string(lowest(xs)) + " " + string(highest(xs)))
        \\    free(xs)
        \\    free(control)
        \\
    );
}

test "clamp agrees when the bounds cross and when they are not numbers" {
    try agree(
        \\func main():
        \\    let bounds = new list(double)
        \\    bounds.append(-1.0)
        \\    bounds.append(1.0)
        \\    bounds.append(0.0)
        \\    bounds.append(-0.0)
        \\    bounds.append(0.0 / 0.0)
        \\    var low = 0
        \\    while low < len(bounds):
        \\        var high = 0
        \\        while high < len(bounds):
        \\            let held = double(low) - double(high) * 0.5
        \\            print(string(clamp(held, bounds[low], bounds[high])))
        \\            high = high + 1
        \\        low = low + 1
        \\    print(string(clamp(5, 9, 2)) + " " + string(clamp(0, 9, 2)))
        \\    free(bounds)
        \\
    );
}

test "the float builtins agree" {
    try agree(
        \\func main():
        \\    let xs = new list(double)
        \\    xs.append(0.0)
        \\    xs.append(4.0)
        \\    xs.append(2.999)
        \\    xs.append(-2.999)
        \\    xs.append(1.0 / 0.0)
        \\    for x in xs:
        \\        print(string(x) + ": " + string(sqrt(abs(x))) + " " + string(floor(x)) +
        \\            " " + string(ceil(x)) + " " + string(double(long(clamp(x, -9.0, 9.0)))))
        \\    free(xs)
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
        \\    print(string(long(0.0 - scale)))
        \\    print(string(long(scale - 1024.0)))
        \\    print(string(long(2.7)) + " " + string(long(-2.7)) + " " + string(long(-0.0)))
        \\    print("at the edge")
        \\    print(string(long(scale)))
        \\
    );
}

test "long(NaN) and long(infinity) trap the same way" {
    try agree(
        \\func main():
        \\    let nan = 0.0 / 0.0
        \\    print("before")
        \\    print(string(long(nan)))
        \\
    );
    try agree(
        \\func main():
        \\    let far = -1.0 / 0.0
        \\    print("before")
        \\    print(string(long(far)))
        \\
    );
}

test "the long math builtins agree, and abs of the smallest long traps" {
    try agree(
        \\func main():
        \\    let xs = new list(long)
        \\    xs.append(0)
        \\    xs.append(7)
        \\    xs.append(-7)
        \\    xs.append(9223372036854775807)
        \\    xs.append(0 - 9223372036854775807 - 1)
        \\    for x in xs:
        \\        print(string(min(x, 3)) + " " + string(max(x, 3)) + " " + string(clamp(x, -2, 2)))
        \\    free(xs)
        \\
    );
    try agree(
        \\func main():
        \\    let xs = new list(long)
        \\    xs.append(0 - 9223372036854775807 - 1)
        \\    print(string(abs(7)) + " " + string(abs(-7)))
        \\    print(string(abs(xs[0])))
        \\
    );
}

// ---------------------------------------------------------------------------
// Struct values
// ---------------------------------------------------------------------------

test "nested struct equality recurses into fields, not the slots holding them" {
    try agree(
        \\struct Inner:
        \\    n: long
        \\    tag: string
        \\
        \\struct Outer:
        \\    left: Inner
        \\    right: Inner
        \\
        \\func main():
        \\    let a = Outer(left = Inner(n = 1, tag = "x"), right = Inner(n = 2, tag = "y"))
        \\    let b = Outer(left = Inner(n = 1, tag = "x"), right = Inner(n = 2, tag = "y"))
        \\    let c = Outer(left = Inner(n = 1, tag = "x"), right = Inner(n = 3, tag = "y"))
        \\    print(string(a == b) + string(a != b))
        \\    print(string(a == c) + string(a != c))
        \\    print(string(a.left == b.left) + string(a.right == c.right))
        \\
    );
}

test "a struct carrying a String copies by value and agrees" {
    try agree(
        \\struct Person:
        \\    name: string
        \\    age: long
        \\    score: double
        \\
        \\func renamed(who: Person, to: string) -> Person:
        \\    var changed = who
        \\    changed.name = to
        \\    return changed
        \\
        \\func main():
        \\    var ada = Person(name = "ada", age = 36, score = 1.5)
        \\    let grace = renamed(ada, "grace")
        \\    print(ada.name + " " + string(ada.age) + " " + string(ada.score))
        \\    print(grace.name + " " + string(grace.age) + " " + string(grace.score))
        \\    ada.age = 37
        \\    print(string(ada.age) + " " + string(grace.age) + " " + string(ada == grace))
        \\
    );
}

test "zero-initialized structs agree, nested ones included" {
    try agree(
        \\struct Inner:
        \\    n: long
        \\    tag: string
        \\
        \\struct Outer:
        \\    label: string
        \\    inner: Inner
        \\    weight: double
        \\
        \\func main():
        \\    var grid = new array(Outer, 2, 2)
        \\    print("[" + grid[0, 0].label + "][" + grid[0, 0].inner.tag + "]")
        \\    print(string(grid[1, 1].inner.n) + " " + string(grid[1, 1].weight))
        \\    grid[1, 0].inner.n = 7
        \\    print(string(grid[1, 0].inner.n) + " " + string(grid[0, 1].inner.n))
        \\    print(string(grid[0, 0] == grid[0, 1]) + string(grid[0, 0] == grid[1, 0]))
        \\    free(grid)
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
        \\    var grid = new array(long, 3, 4)
        \\    for r in range(0, 3):
        \\        for c in range(0, 4):
        \\            grid[r, c] = r * 10 + c
        \\    var total: long = 0
        \\    for r in range(0, 3):
        \\        for c in range(0, 4):
        \\            total += grid[r, c]
        \\    print(string(total) + " " + string(grid.dim(0)) + " " + string(grid.dim(1)) + " " + string(len(grid)))
        \\
        \\    var names = new array(string, 3)
        \\    var flags = new array(bool, 3)
        \\    var weights = new array(double, 3)
        \\    for i in range(0, 3):
        \\        names[i] = "n" + string(i)
        \\        flags[i] = i % 2 == 0
        \\        weights[i] = double(i) * 0.5
        \\    for i in range(0, 3):
        \\        print(names[i] + " " + string(flags[i]) + " " + string(weights[i]))
        \\
        \\    var rows = new array(list(long), 2)
        \\    for i in range(0, 2):
        \\        var row = new list(long)
        \\        row.append(i)
        \\        rows[i] = give row
        \\    print(string(rows[0][0] + rows[1][0]))
        \\
        \\    free(rows)
        \\    free(weights)
        \\    free(flags)
        \\    free(names)
        \\    free(grid)
        \\
    );
}

test "a resolution lifted out of a loop still traps where the access is" {
    // `loops.zig` reads an Array's row once per loop instead of once
    // per access.  What must not move with it is the *deciding*: a
    // loop that never runs must not trap for an array that is already
    // freed, and one that does run must trap at the access, not at the
    // preheader.  Both engines, one source, twice.
    try agree(
        \\func drop(xs: give array(double, _)):
        \\    free(xs)
        \\
        \\func main():
        \\    var a = new array(double, 4)
        \\    let alias = a
        \\    drop(give a)
        \\    var total: double = 0.0
        \\    for i in range(0, 0):
        \\        total += alias[i]
        \\    print("survived " + string(long(total)))
        \\
    );
    try agree(
        \\func drop(xs: give array(double, _)):
        \\    free(xs)
        \\
        \\func main():
        \\    var a = new array(double, 4)
        \\    let alias = a
        \\    drop(give a)
        \\    var total: double = 0.0
        \\    for i in range(0, 4):
        \\        total += alias[i]
        \\    print("unreachable " + string(long(total)))
        \\
    );
    // And an index past the end still traps at the access it was made
    // at, with the loop's resolution already lifted above it.
    try agree(
        \\func main():
        \\    var a = new array(double, 4)
        \\    var total: double = 0.0
        \\    for i in range(0, 6):
        \\        total += a[i]
        \\    print("unreachable " + string(long(total)))
        \\
    );
}

test "a lifted resolution sees the generation, so a reoccupied row still traps" {
    // The row `a` vacates is the row `reborn` moves into, and the
    // lifted resolution reads that row in the preheader — so what
    // stands between `alias` and `reborn`'s elements is the one
    // comparison the loop kept: the row's generation against the
    // handle's.
    try agree(
        \\func main():
        \\    var a = new array(long, 4)
        \\    a.fill(5)
        \\    let alias = a
        \\    free(a)
        \\    var reborn = new array(long, 4)
        \\    reborn.fill(1)
        \\    var total: long = 0
        \\    for i in range(0, 3):
        \\        total += alias[i]
        \\    print("unreachable " + string(total))
        \\
    );
    // And the null handle, whose lifted resolution reads the module's
    // retired row rather than the table: still `null_object`, still at
    // the access.
    try agree(
        \\func main():
        \\    var rows = new array(array(long, _), 2)
        \\    var inner = rows[0]
        \\    var total: long = 0
        \\    for i in range(0, 3):
        \\        total += inner[i]
        \\    print("unreachable " + string(total))
        \\
    );
}

test "inline String length, byte_at and slicing agree, boundaries included" {
    try agree(
        \\func main():
        \\    let text = "héllo wörld"
        \\    print(string(len(text)) + " " + string(text.byte_at(0)) + " " + string(text.byte_at(1)))
        \\    print(text[0:1] + "|" + text[1:3] + "|" + text[0:0] + "|" + text[3:len(text)])
        \\    var i = 0
        \\    var total: long = 0
        \\    while i < len(text):
        \\        total += text.byte_at(i)
        \\        i += 1
        \\    print(string(total))
        \\
    );
    // The end of a String is a legal bound and the byte there is not
    // ours to read; splitting a sequence is a trap, not a wrong answer.
    try agree(
        \\func main():
        \\    let text = "héllo"
        \\    print(text[0:2])
        \\
    );
    try agree(
        \\func main():
        \\    let text = "abc"
        \\    print(string(text.byte_at(3)))
        \\
    );
}

test "structs inside containers agree" {
    try agree(
        \\struct Cell:
        \\    value: long
        \\    name: string
        \\
        \\func main():
        \\    var cells = [Cell(value = 10, name = "a"), Cell(value = 20, name = "b")]
        \\    cells[1].value = 99
        \\    for cell in cells:
        \\        print(cell.name + "=" + string(cell.value))
        \\    print(string(cells[0] == cells[1]) + string(len(cells)))
        \\    free(cells)
        \\
    );
}

test "a struct carrying an object is owned and released through its fields" {
    // The struct crosses a return, so the ownership walk has to reach
    // into its fields on both the loosen and the release side; the leak
    // census is what says it did.
    try agree(
        \\struct Bag:
        \\    items: list(long)
        \\    label: string
        \\
        \\func fill(label: string) -> Bag:
        \\    let xs = new list(long)
        \\    xs.append(1)
        \\    xs.append(2)
        \\    return Bag(items = give xs, label = label)
        \\
        \\func main():
        \\    var bag = fill("b")
        \\    print(string(len(bag.items)) + bag.label)
        \\    bag.items.append(3)
        \\    print(string(len(bag.items)))
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
        \\func maybe(want: bool) -> long?:
        \\    if want:
        \\        return 7
        \\    return none
        \\
        \\func main():
        \\    let there = maybe(true)
        \\    if there != none:
        \\        print("there=" + string(there))
        \\    let gone = maybe(false)
        \\    if gone == none:
        \\        print("gone")
        \\    print(string(maybe(false) else -1) + " " + string(maybe(true) else -1))
        \\    var slot: long? = none
        \\    print(string(slot else -2))
        \\    slot = maybe(true)
        \\    print(string(slot else -2))
        \\
    );
}

test "the else fallback runs only where there was no value, and chains" {
    // The fallback is lazy: `loud` prints, so the printed bytes are
    // what says which side ran.  A chain is the same shape nested, and
    // its middle link must not run either once the first supplies one.
    try agree(
        \\func maybe(want: bool) -> long?:
        \\    if want:
        \\        return 7
        \\    return none
        \\
        \\func loud(answer: long) -> long:
        \\    print("fallback ran")
        \\    return answer
        \\
        \\func main():
        \\    print(string(maybe(true) else loud(1)))
        \\    print(string(maybe(false) else loud(2)))
        \\    print(string(maybe(true) else maybe(false) else loud(3)))
        \\    print(string(maybe(false) else maybe(true) else loud(4)))
        \\    print(string(maybe(false) else maybe(false) else loud(5)))
        \\
    );
}

test "parse_int and parse_float agree when the text is a number and when it is not" {
    // The `long?`/`double?` that made optionals load-bearing on day one.
    try agree(
        \\func main():
        \\    print(string(parse_int("41") else -1))
        \\    print(string(parse_int("") else -1))
        \\    print(string(parse_int("12x") else -1))
        \\    print(string(parse_int("-9") else -1))
        \\    print(string(parse_float("2.5") else -1.0))
        \\    print(string(parse_float("nope") else -1.0))
        \\    let n = parse_int("77")
        \\    if n != none:
        \\        print("narrowed=" + string(n + 1))
        \\
    );
}

test "x else trap is the assert-unwrap, and it traps where it is written" {
    // The trap code, the message, and every frame of the trace have to
    // match — which is the whole of `calc.luc`'s error path.
    try agree(
        \\func want(text: string) -> long:
        \\    return parse_int(text) else trap("not a number: " + text)
        \\
        \\func middle(text: string) -> long:
        \\    return want(text) + 1
        \\
        \\func main():
        \\    print(string(middle("41")))
        \\    print(string(middle("oops")))
        \\
    );
}

test "an optional struct field agrees, absent and present" {
    // A `T?` field is stored as a `runtime.Value` on both engines, so
    // this is where the lowered pair meets the tagged slot: absence has
    // to box as the `none` tag and read back as the absent pair.
    try agree(
        \\struct Slot:
        \\    label: string
        \\    room: long?
        \\
        \\func main():
        \\    var empty = Slot(label = "a", room = none)
        \\    if empty.room == none:
        \\        print("a has no room")
        \\    empty.room = 12
        \\    print("a=" + string(empty.room else 0))
        \\    let filled = Slot(label = "b", room = 3)
        \\    let room = filled.room
        \\    if room != none:
        \\        print("b=" + string(room))
        \\    var zeroed: Slot
        \\    print(string(zeroed.room else -1))
        \\
    );
}

test "a struct recurses through an optional field, which is what ends it" {
    // `Node` holds a `Node?`, and the optional is what makes a struct
    // cycle finite: the field is one `Value` whether or not anything is
    // in it.  Reading one back is the boxed `strukt` payload.
    try agree(
        \\struct Node:
        \\    value: long
        \\    next: Node?
        \\
        \\func total(from: Node) -> long:
        \\    var sum = from.value
        \\    let step = from.next
        \\    if step != none:
        \\        sum = sum + total(step)
        \\    return sum
        \\
        \\func main():
        \\    let tail = Node(value = 2, next = none)
        \\    let head = Node(value = 1, next = tail)
        \\    print(string(total(head)))
        \\    print(string(total(tail)))
        \\    let step = head.next
        \\    if step != none:
        \\        print("next=" + string(step.value))
        \\
    );
}

test "a heap optional agrees, and holding none owns nothing (S43)" {
    // The leak census is the proof: the object that came back inside a
    // `T?` is released at the end of the scope that received it, and
    // the absent one leaves nothing behind to release.  A `none` owns
    // nothing, so neither engine may count it.
    try agree(
        \\func pick(want: bool) -> list(long)?:
        \\    if want:
        \\        let made = new list(long)
        \\        made.append(3)
        \\        made.append(4)
        \\        return made
        \\    return none
        \\
        \\func main():
        \\    var held: list(long)? = none
        \\    if held == none:
        \\        print("absent")
        \\    let got = pick(true)
        \\    if got != none:
        \\        print("len=" + string(len(got)) + " first=" + string(got[0]))
        \\        free(got)
        \\    let missing = pick(false)
        \\    if missing == none:
        \\        print("nothing came back")
        \\    let owned = pick(true)
        \\    if owned != none:
        \\        print("owned=" + string(len(owned)))
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
        \\    tag: string
        \\    room: long?
        \\
        \\func even(n: long) -> long?:
        \\    if n % 2 == 0:
        \\        return n
        \\    return none
        \\
        \\func show(room: long?) -> string:
        \\    if room == none:
        \\        return "-"
        \\    return string(room)
        \\
        \\func main():
        \\    var seen: long = 0
        \\    var i = 0
        \\    while i < 8:
        \\        let maybe = even(i)
        \\        if maybe != none:
        \\            seen = seen + maybe
        \\        i = i + 1
        \\    print("sum of evens=" + string(seen))
        \\    var last: long? = none
        \\    var j = 0
        \\    while j < 5:
        \\        last = even(j)
        \\        j = j + 1
        \\    print("last=" + string(last else -1))
        \\    let cells = new list(Cell)
        \\    var k = 0
        \\    while k < 4:
        \\        cells.append(Cell(tag = string(k), room = even(k)))
        \\        k = k + 1
        \\    var out = ""
        \\    for cell in cells:
        \\        out = out + cell.tag + ":" + show(cell.room) + " "
        \\    print(out)
        \\    free(cells)
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
        \\    x: long
        \\    y: long
        \\
        \\func flag(want: bool) -> bool?:
        \\    if want:
        \\        return false
        \\    return none
        \\
        \\func text(want: bool) -> string?:
        \\    if want:
        \\        return "hi"
        \\    return none
        \\
        \\func ratio(want: bool) -> double?:
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
        \\    print(string(flag(true) else true) + " " + string(flag(false) else true))
        \\    print((text(true) else "-") + " " + (text(false) else "-"))
        \\    print(string(ratio(true) else -1.0) + " " + string(ratio(false) else -1.0))
        \\    let here = spot(true)
        \\    if here != none:
        \\        print("x=" + string(here.x) + " y=" + string(here.y))
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
        \\func look(xs: list(long)?) -> bool:
        \\    return xs == none
        \\
        \\func main():
        \\    var raw: list(long)
        \\    print("absent=" + string(look(raw)))
        \\    let real = new list(long)
        \\    real.append(1)
        \\    print("absent=" + string(look(real)))
        \\    free(real)
        \\
    );
}

// ---------------------------------------------------------------------------
// The host services
// ---------------------------------------------------------------------------

test "files, arguments, the screen, and the keyboard agree" {
    try agree(
        \\func main(args: list(string)) -> !:
        \\    print(string(len(args)) + " " + args[0] + "," + args[1])
        \\    print(string(try path_kind("notes.txt")))
        \\    try file_write("notes.txt", "hello world")
        \\    print(string(try path_kind("notes.txt")) + " " + try file_read("notes.txt"))
        \\    print(string(term_rows()) + "x" + string(term_cols()))
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
        \\    print("elapsed " + string(ended - started))
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
        \\        print(string(count) + ": " + line)
        \\        line = read_line("")
        \\    print("read " + string(count) + " lines, then nothing")
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
        \\    print(string(try path_kind("notes.txt")) + " " + string(try path_kind("kept.txt")))
        \\    try file_delete("kept.txt")
        \\    print(string(try path_kind("kept.txt")))
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
        \\    print(string(len(names)))
        \\    for name in names:
        \\        print(name)
        \\    names.sort()
        \\    print(names[0])
        \\    free(names)
        \\
    );
}

test "a directory that will not list is an error on both engines" {
    try agree(
        \\func main() -> !:
        \\    print("before")
        \\    let names = try dir_list("nowhere")
        \\    free(names)
        \\
    );
}

test "a caught listing failure leaks nothing on either engine" {
    // The failing side parks a value nobody reads, and the value it
    // parks must not be an object the census then counts.
    try agree(
        \\func main():
        \\    var found: long = 0
        \\    let names = dir_list("nowhere") catch new list(string)
        \\    found = len(names)
        \\    print("caught, " + string(found) + " names")
        \\    free(names)
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
        \\    print(string(clock_ms()))
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
        \\    free(names)
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
        \\func inner(n: long) -> long!:
        \\    if n > 2:
        \\        error("too big: " + string(n))
        \\    return n * 2
        \\
        \\func middle(n: long) -> long!:
        \\    return try inner(n)
        \\
        \\func outer(n: long) -> long!:
        \\    return try middle(n)
        \\
        \\func main() -> !:
        \\    print(string(try outer(1)))
        \\    print(string(try outer(5)))
        \\
    );
}

test "an error path releases the objects and the String storage it owns" {
    // The leak census is the proof: every frame the error left
    // through released what it owned, so a caught error leaves the
    // heap exactly where a returning call would (S4, S34).
    try agree(
        \\func gather(path: string) -> long!:
        \\    let words = new list(string)
        \\    words.append("alpha")
        \\    words.append("beta")
        \\    let held = "prefix-" + path
        \\    let text = try file_read(path)
        \\    words.append(held + text)
        \\    return len(words)
        \\
        \\func main():
        \\    var total: long = 0
        \\    var round = 0
        \\    while round < 3:
        \\        total = total + (gather("nothing-here.txt") catch -1)
        \\        round = round + 1
        \\    print(string(total))
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
        \\    let short = try file_read("notes.txt")
        \\    print(short + "/" + string(len(short)))
        \\    try file_write("notes.txt", "a string well past the inline capacity of a value")
        \\    let lengthy = try file_read("notes.txt")
        \\    print(lengthy + "/" + string(len(lengthy)))
        \\    print(string(try path_kind("notes.txt")) + " " + try file_read("notes.txt"))
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
        \\func load(path: string) -> string!:
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
        \\func load(path: string) -> list(string)!:
        \\    let lines = new list(string)
        \\    lines.append(try file_read(path))
        \\    return lines
        \\
        \\func main():
        \\    let missing = load("nothing-here.txt") catch new list(string)
        \\    print(string(len(missing)))
        \\    free(missing)
        \\
    );
}

test "an argument index out of range traps index_bounds on both engines" {
    // `args` is an ordinary List, so reading past it is the language's
    // own bounds trap and not a channel of its own (docs/METHODS.md).
    try agree(
        \\func main(args: list(string)):
        \\    print(args[0])
        \\    print(args[9])
        \\
    );
}

test "a withheld service group fails closed on both engines" {
    try agreeGiven(
        \\func main() -> !:
        \\    print(string(try path_kind("notes.txt")))
        \\
    , .{ .files = false });
    try agreeGiven(
        \\func main():
        \\    print(string(term_rows()))
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
        \\    label: string
        \\    count: long
        \\
        \\func widen(s: string) -> string:
        \\    return strings.trim(s)
        \\
        \\func drop_first(pieces: list(string)) -> long:
        \\    pieces.remove(0)
        \\    return 1
        \\
        \\func measure(left: string, right: long) -> long:
        \\    return len(left) + right
        \\
        \\func main():
        \\    let trimmed = widen("   padded   ")
        \\    print(trimmed)
        \\
        \\    var names = new list(string)
        \\    names.append("ada")
        \\    names.append(trimmed + "-lovelace")
        \\    names[0] = names[1]
        \\    print(names[0] + " " + string(len(names)))
        \\    var duplicate = copy names
        \\    free(names)
        \\    print(duplicate[1])
        \\    free(duplicate)
        \\
        \\    var tag = Tag(label = "one", count = 1)
        \\    tag.label = "two"
        \\    tag.label = tag.label + "-three"
        \\    var copied = tag
        \\    copied.label = "other"
        \\    print(tag.label + " " + copied.label)
        \\
        \\    var table = new map(string, string)
        \\    table["k" + string(1)] = "v1"
        \\    table["k1"] = "v" + string(2)
        \\    var keys = table.keys()
        \\    var values = table.values()
        \\    print(keys[0] + values[0])
        \\    free(keys)
        \\    free(values)
        \\    table.remove("k1")
        \\    free(table)
        \\
        \\    var pieces = new list(string)
        \\    pieces.append("first-piece")
        \\    pieces.append("second")
        \\    print(string(measure(pieces[0], drop_first(pieces))))
        \\    free(pieces)
        \\
        \\    var text = "abcdef"
        \\    text = text[1:5]
        \\    text = text + text
        \\    print(text)
        \\
        \\    var cells = new array(string, 3)
        \\    cells[0] = "x" + string(0)
        \\    cells[1] = cells[0]
        \\    cells[0] = "y"
        \\    print(cells[0] + cells[1] + string(len(cells[2])))
        \\    free(cells)
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
        \\    label: string
        \\
        \\func echo(s: string) -> string:
        \\    return s
        \\
        \\func grow(s: string) -> string:
        \\    return s + s
        \\
        \\func main():
        \\    var words = new list(string)
        \\    var table = new map(string, string)
        \\    for size in [0, 1, 21, 22, 23, 64]:
        \\        let text = strings.repeat("a", size)
        \\        let kept = echo(text)
        \\        words.append(kept)
        \\        table[kept] = kept
        \\        let held = Held(label = kept)
        \\        print(string(size) + " " + string(len(kept)) + " " + string(len(held.label)) +
        \\            " " + string(len(words[len(words) - 1])) + " " + string(len(table[kept])) +
        \\            " " + string(table.has(kept)))
        \\    free(words)
        \\    free(table)
        \\
    );
    // The transitions in both directions: short grown long by `+`,
    // long cut back to short by a slice, and both stored afterwards.
    try agree(
        \\import std.strings
        \\
        \\func grow(s: string) -> string:
        \\    return s + s
        \\
        \\func main():
        \\    var kept = new list(string)
        \\    for size in [1, 11, 12, 21, 22, 23]:
        \\        var text = strings.repeat("b", size)
        \\        text = grow(text)
        \\        kept.append(text)
        \\        var cut = text[0:1]
        \\        cut = cut + text[0:size]
        \\        kept.append(cut)
        \\        print(string(len(text)) + ":" + text + " " + string(len(cut)) + ":" + cut)
        \\    var joined = ""
        \\    for piece in kept:
        \\        joined = joined + string(len(piece)) + ","
        \\    print(joined)
        \\    free(kept)
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
        \\    var cells = new array(string, 2)
        \\    cells[0] = small
        \\    cells[1] = source
        \\    source = "replaced"
        \\    small = small + "!"
        \\    print(cells[0] + " " + string(len(cells[1])) + " " + small + " " + source)
        \\    free(cells)
        \\
    );
}

test "a loop name agrees whether it borrows its element or copies it" {
    try agree(
        \\func main():
        \\    var words = new list(string)
        \\    words.append("aa")
        \\    words.append("bb")
        \\    words.append("cc")
        \\    var total: long = 0
        \\    for w in words:
        \\        total += len(w)
        \\    print(string(total))
        \\    var seen = ""
        \\    for w in words:
        \\        seen = seen + w
        \\        words[0] = "zz"
        \\    print(seen)
        \\    free(words)
        \\
        \\    var table = new map(string, string)
        \\    table["a"] = "1"
        \\    table["b"] = "2"
        \\    var joined = ""
        \\    for key, value in table:
        \\        joined = joined + key + value
        \\    print(joined)
        \\    free(table)
        \\
    );
}

test "a trap agrees while every frame is still holding String bytes" {
    try agree(
        \\struct Tag:
        \\    label: string
        \\    count: long
        \\
        \\func deeper(name: string) -> long:
        \\    let held = name + "-held"
        \\    var tag = Tag(label = held, count = 1)
        \\    trap(tag.label)
        \\
        \\func main():
        \\    let outer = "kept" + "-here"
        \\    var also = Tag(label = outer, count = 2)
        \\    print(string(deeper(also.label)))
        \\
    );
}

test "array loops carry the two alias scopes, and runtime calls carry neither" {
    // Task #45's payoff, pinned at the IR: element accesses disclaim
    // the rows scope and row facts disclaim the elements one, so LICM
    // may hoist a row's facts over a loop of element stores.  The
    // scopes' shape (domain, named scopes) is proven at the Builder
    // (08_llvm/builder.zig); what this pins is that the lowering
    // actually says it.
    const gpa = std.testing.allocator;
    const rendered = (try render(
        \\func main():
        \\    var grid = new array(long, 64)
        \\    var i = 0
        \\    while i < 64:
        \\        grid[i] = i * 2
        \\        i += 1
        \\    print(string(grid[63]))
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
        \\    var total: long = 0
        \\    for i in range(0, 10):
        \\        total = total + i
        \\    print(string(total))
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
        \\func announce(n: long) -> long:
        \\    print(string(n))
        \\    return n
        \\
        \\func main():
        \\    let t = spawn announce(1)
        \\    print(string(t.wait()))
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
