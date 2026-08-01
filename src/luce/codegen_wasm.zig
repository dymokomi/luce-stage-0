//! The WebAssembly backend — Luce IR to a self-contained `.wasm`
//! module (docs/NATIVE.md).
//!
//! A distribution target parallel to the native engines, not another
//! engine loom maps and jumps into: it emits a standalone module a
//! wasm runtime instantiates — the browser, wasmtime, node, deno —
//! with the host effects as imports.  It reuses everything above the
//! seam: the same verified Luce IR, the same trap codes, checked the
//! same way against the interpreter.
//!
//! Milestone 0, deliberately narrow (the bring-up scope the native
//! backends used): one function, the Int/Bool core, integer
//! arithmetic with the full trap semantics, control flow, and output
//! of computed integers.  Strings and the heap are milestone 1.
//!
//! Two facts shape the lowering.  WebAssembly is a *structured* stack
//! machine — no registers, no arbitrary jumps — so Luce's basic-block
//! CFG becomes a dispatch loop: a `$pc` local selected by `br_table`,
//! correct for any control-flow graph without a relooper.  And IR
//! registers and locals each become a wasm *local*, so values move by
//! `local.get`/`local.set` rather than by scheduling the operand
//! stack — the interpreter's register-array model, transliterated.
//!
//! Host boundary: two imports.  `emit_i64(i64)` is where a computed
//! integer leaves the module — `print(str(n))` lowers to it, so the
//! numeric pipeline is observable without a string runtime yet.
//! `trap(code)` records a Luce trap code before the module halts on
//! `unreachable`.

const std = @import("std");
const ir = @import("ir.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const available = true; // a pure byte emitter; no host machine code

/// Whether the program fits milestone 0: one entry function taking no
/// parameters and returning nothing, Int/Bool values, integer
/// arithmetic, control flow, `assert`, coded `trap`, and output of an
/// integer via `print(str(n))` — a str(Int) result must be consumed
/// by a print.
pub fn supported(program: *const ir.Program) bool {
    if (program.functions.len != 1) return false;
    const function = &program.functions[0];
    if (function.parameter_count != 0) return false;
    if (function.return_type != .none) return false;
    for (function.locals) |local| {
        if (!valueShaped(local.local_type)) return false;
    }
    for (function.result_types, 0..) |result, register| {
        if (result == .none) continue;
        // A str(Int) result is String-typed but lowered away into the
        // print that consumes it.
        if (result == .string) {
            const producer = function.instructions[register];
            if (producer != .intrinsic or producer.intrinsic.kind != .str_value) return false;
            continue;
        }
        if (!valueShaped(result)) return false;
    }
    for (function.instructions) |instruction| {
        switch (instruction) {
            .const_boolean, .const_int => {},
            .local_get, .local_set => {},
            .jump, .branch, .trap => {},
            .ret => |value| if (value != null) return false,
            .unary => {},
            .binary => |op| if (op.operand_type != .int) return false,
            .intrinsic => |call| switch (call.kind) {
                .assert_true => {},
                .print => {
                    const arg = function.instructions[call.arguments[0]];
                    if (arg != .intrinsic or arg.intrinsic.kind != .str_value) return false;
                    if (function.result_types[arg.intrinsic.arguments[0]] != .int) return false;
                },
                .str_value => if (function.result_types[call.arguments[0]] != .int) return false,
                else => return false,
            },
            else => return false,
        }
    }
    return true;
}

fn valueShaped(of: types.Type) bool {
    return switch (of) {
        .int, .boolean => true,
        else => false,
    };
}

/// Emit the whole program as one wasm module.  Assumes supported().
pub fn compile(arena: Allocator, program: *const ir.Program) error{OutOfMemory}![]const u8 {
    var emitter: Emitter = .{ .arena = arena, .program = program, .function = &program.functions[0] };
    return emitter.module();
}

// ---------------------------------------------------------------------------
// wasm opcode/value vocabulary (the subset milestone 0 uses)
// ---------------------------------------------------------------------------

const wasm = struct {
    const i32t: u8 = 0x7F;
    const i64t: u8 = 0x7E;
    const func_type: u8 = 0x60;
    const empty_type: u8 = 0x40; // block/if result: none

    const unreachable_: u8 = 0x00;
    const block: u8 = 0x02;
    const loop: u8 = 0x03;
    const if_: u8 = 0x04;
    const else_: u8 = 0x05;
    const end: u8 = 0x0B;
    const br: u8 = 0x0C;
    const br_table: u8 = 0x0E;
    const ret: u8 = 0x0F;
    const call: u8 = 0x10;

    const local_get: u8 = 0x20;
    const local_set: u8 = 0x21;
    const i32_const: u8 = 0x41;
    const i64_const: u8 = 0x42;

    const i32_eqz: u8 = 0x45;
    const i32_and: u8 = 0x71;

    const i64_eqz: u8 = 0x50;
    const i64_eq: u8 = 0x51;
    const i64_ne: u8 = 0x52;
    const i64_lt_s: u8 = 0x53;
    const i64_gt_s: u8 = 0x55;
    const i64_le_s: u8 = 0x57;
    const i64_ge_s: u8 = 0x59;
    const i64_add: u8 = 0x7C;
    const i64_sub: u8 = 0x7D;
    const i64_mul: u8 = 0x7E;
    const i64_div_s: u8 = 0x7F;
    const i64_rem_s: u8 = 0x81;
    const i64_and: u8 = 0x83;
    const i64_xor: u8 = 0x85;
};

const import_emit = 0; // emit_i64(i64)
const import_trap = 1; // trap(i32 code)
const import_count = 2;
const func_entry = import_count; // the single defined function

fn appendU32(list: *std.ArrayList(u8), arena: Allocator, value: u32) error{OutOfMemory}!void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try list.append(arena, byte);
        if (v == 0) break;
    }
}

fn appendI64(list: *std.ArrayList(u8), arena: Allocator, value: i64) error{OutOfMemory}!void {
    var v = value;
    while (true) {
        const low: u8 = @bitCast(@as(i8, @truncate(v)));
        var byte: u8 = low & 0x7F;
        v >>= 7;
        const sign = byte & 0x40;
        if ((v == 0 and sign == 0) or (v == -1 and sign != 0)) {
            try list.append(arena, byte);
            break;
        }
        byte |= 0x80;
        try list.append(arena, byte);
    }
}

const Emitter = struct {
    arena: Allocator,
    program: *const ir.Program,
    function: *const ir.Function,
    code: std.ArrayList(u8) = .empty,

    /// str(Int) is lowered away: its result register remembers the
    /// source Int register, which the consuming print emits.
    str_source: []?ir.Register = &.{},

    pc_local: u32 = 0,
    locals_base: u32 = 0,
    registers_base: u32 = 0,
    /// Extra wasm scopes open between here and the dispatch loop (an
    /// `if` adds one); a `br` to the loop crosses them.
    scope_extra: u32 = 0,
    loop_depth: u32 = 0,

    // -- code helpers -------------------------------------------------------

    fn op(self: *Emitter, code: u8) error{OutOfMemory}!void {
        try self.code.append(self.arena, code);
    }
    fn u32v(self: *Emitter, value: u32) error{OutOfMemory}!void {
        try appendU32(&self.code, self.arena, value);
    }
    fn constI64(self: *Emitter, value: i64) error{OutOfMemory}!void {
        try self.op(wasm.i64_const);
        try appendI64(&self.code, self.arena, value);
    }
    fn constI32(self: *Emitter, value: i32) error{OutOfMemory}!void {
        try self.op(wasm.i32_const);
        try appendI64(&self.code, self.arena, value);
    }
    fn localGet(self: *Emitter, index: u32) error{OutOfMemory}!void {
        try self.op(wasm.local_get);
        try self.u32v(index);
    }
    fn localSet(self: *Emitter, index: u32) error{OutOfMemory}!void {
        try self.op(wasm.local_set);
        try self.u32v(index);
    }
    fn callFunc(self: *Emitter, func: u32) error{OutOfMemory}!void {
        try self.op(wasm.call);
        try self.u32v(func);
    }
    fn regLocal(self: *const Emitter, register: ir.Register) u32 {
        return self.registers_base + register;
    }
    fn localLocal(self: *const Emitter, local: ir.LocalId) u32 {
        return self.locals_base + local;
    }
    fn i64Min(self: *Emitter) error{OutOfMemory}!void {
        try self.constI64(std.math.minInt(i64));
    }

    fn trap(self: *Emitter, code: ir.TrapCode) error{OutOfMemory}!void {
        try self.constI32(@intFromEnum(code));
        try self.callFunc(import_trap);
        try self.op(wasm.unreachable_);
    }

    /// <i32 condition on the stack>, then trap(code) when it is true.
    fn trapIf(self: *Emitter, code: ir.TrapCode) error{OutOfMemory}!void {
        try self.op(wasm.if_);
        try self.op(wasm.empty_type);
        try self.trap(code);
        try self.op(wasm.end);
    }

    /// Set $pc to `block` and branch to the dispatch loop.
    fn gotoBlock(self: *Emitter, block: ir.BlockId) error{OutOfMemory}!void {
        try self.constI32(@intCast(block));
        try self.localSet(self.pc_local);
        try self.op(wasm.br);
        try self.u32v(self.loop_depth + self.scope_extra);
    }

    // -- lowering -----------------------------------------------------------

    fn emitInstruction(self: *Emitter, item: ir.Register) error{OutOfMemory}!void {
        const function = self.function;
        switch (function.instructions[item]) {
            .const_int => |value| {
                try self.constI64(value);
                try self.localSet(self.regLocal(item));
            },
            .const_boolean => |value| {
                try self.constI32(@intFromBool(value));
                try self.localSet(self.regLocal(item));
            },
            .local_get => |local| {
                try self.localGet(self.localLocal(local));
                try self.localSet(self.regLocal(item));
            },
            .local_set => |set| {
                try self.localGet(self.regLocal(set.value));
                try self.localSet(self.localLocal(set.local));
            },
            .unary => |operation| switch (operation.op) {
                .negate => {
                    try self.localGet(self.regLocal(operation.operand));
                    try self.i64Min();
                    try self.op(wasm.i64_eq);
                    try self.trapIf(.integer_overflow);
                    try self.constI64(0);
                    try self.localGet(self.regLocal(operation.operand));
                    try self.op(wasm.i64_sub);
                    try self.localSet(self.regLocal(item));
                },
                .logic_not => {
                    try self.localGet(self.regLocal(operation.operand));
                    try self.op(wasm.i32_eqz);
                    try self.localSet(self.regLocal(item));
                },
            },
            .binary => |operation| try self.emitBinary(item, operation),
            .intrinsic => |call| try self.emitIntrinsic(item, call),
            .jump => |target| try self.gotoBlock(target),
            .branch => |branching| {
                try self.localGet(self.regLocal(branching.condition));
                try self.op(wasm.if_);
                try self.op(wasm.empty_type);
                self.scope_extra += 1;
                try self.gotoBlock(branching.then_block);
                self.scope_extra -= 1;
                try self.op(wasm.end);
                try self.gotoBlock(branching.else_block);
            },
            .ret => try self.op(wasm.ret),
            .trap => |code| try self.trap(code),
            else => unreachable, // supported() refused the rest
        }
    }

    fn emitBinary(self: *Emitter, item: ir.Register, operation: anytype) error{OutOfMemory}!void {
        const left = self.regLocal(operation.left);
        const right = self.regLocal(operation.right);
        const dest = self.regLocal(item);
        if (operation.op.isComparison()) {
            try self.localGet(left);
            try self.localGet(right);
            try self.op(switch (operation.op) {
                .equal => wasm.i64_eq,
                .not_equal => wasm.i64_ne,
                .less => wasm.i64_lt_s,
                .less_equal => wasm.i64_le_s,
                .greater => wasm.i64_gt_s,
                .greater_equal => wasm.i64_ge_s,
                else => unreachable,
            });
            try self.localSet(dest);
            return;
        }
        switch (operation.op) {
            .add, .subtract => {
                try self.localGet(left);
                try self.localGet(right);
                try self.op(if (operation.op == .add) wasm.i64_add else wasm.i64_sub);
                try self.localSet(dest);
                try self.overflowCheckAddSub(operation.op == .add, left, right, dest);
            },
            .multiply => {
                try self.localGet(left);
                try self.localGet(right);
                try self.op(wasm.i64_mul);
                try self.localSet(dest);
                // b != 0 and (a==MIN&&b==-1, or r/b != a); the check
                // divide is only reached when it is safe.
                try self.localGet(right);
                try self.op(wasm.i64_eqz);
                try self.op(wasm.if_);
                try self.op(wasm.empty_type); // b == 0: no overflow
                try self.op(wasm.else_);
                try self.localGet(left);
                try self.i64Min();
                try self.op(wasm.i64_eq);
                try self.localGet(right);
                try self.constI64(-1);
                try self.op(wasm.i64_eq);
                try self.op(wasm.i32_and);
                try self.trapIf(.integer_overflow);
                try self.localGet(dest);
                try self.localGet(right);
                try self.op(wasm.i64_div_s);
                try self.localGet(left);
                try self.op(wasm.i64_ne);
                try self.trapIf(.integer_overflow);
                try self.op(wasm.end);
            },
            .divide, .remainder => {
                try self.localGet(right);
                try self.op(wasm.i64_eqz);
                try self.trapIf(.divide_by_zero);
                try self.localGet(left);
                try self.i64Min();
                try self.op(wasm.i64_eq);
                try self.localGet(right);
                try self.constI64(-1);
                try self.op(wasm.i64_eq);
                try self.op(wasm.i32_and);
                try self.trapIf(.integer_overflow);
                try self.localGet(left);
                try self.localGet(right);
                try self.op(if (operation.op == .divide) wasm.i64_div_s else wasm.i64_rem_s);
                try self.localSet(dest);
            },
            else => unreachable,
        }
    }

    /// (a^r)&(b^r)<0 for add, (a^b)&(a^r)<0 for sub — the sign-based
    /// signed-overflow test, matching the interpreter's checked ops.
    fn overflowCheckAddSub(self: *Emitter, is_add: bool, left: u32, right: u32, dest: u32) error{OutOfMemory}!void {
        if (is_add) {
            try self.localGet(left);
            try self.localGet(dest);
            try self.op(wasm.i64_xor);
            try self.localGet(right);
            try self.localGet(dest);
            try self.op(wasm.i64_xor);
        } else {
            try self.localGet(left);
            try self.localGet(right);
            try self.op(wasm.i64_xor);
            try self.localGet(left);
            try self.localGet(dest);
            try self.op(wasm.i64_xor);
        }
        try self.op(wasm.i64_and);
        try self.constI64(0);
        try self.op(wasm.i64_lt_s);
        try self.trapIf(.integer_overflow);
    }

    fn emitIntrinsic(self: *Emitter, item: ir.Register, call: ir.Instruction.IntrinsicCall) error{OutOfMemory}!void {
        switch (call.kind) {
            .assert_true => {
                try self.localGet(self.regLocal(call.arguments[0]));
                try self.op(wasm.i32_eqz);
                try self.trapIf(.assertion_failed);
            },
            .str_value => {
                // Lowered away: remember the source integer.
                self.str_source[item] = call.arguments[0];
            },
            .print => {
                const int_register = self.str_source[call.arguments[0]].?;
                try self.localGet(self.regLocal(int_register));
                try self.callFunc(import_emit);
            },
            else => unreachable,
        }
    }

    // -- the dispatch loop --------------------------------------------------

    fn emitBody(self: *Emitter) error{OutOfMemory}!void {
        const function = self.function;
        const block_count: u32 = @intCast(function.blocks.len);

        // Prologue: pc = 0, then every local to its typed zero.
        try self.constI32(0);
        try self.localSet(self.pc_local);
        for (function.locals, 0..) |local, index| {
            if (local.local_type == .int) try self.constI64(0) else try self.constI32(0);
            try self.localSet(self.localLocal(@intCast(index)));
        }

        try self.op(wasm.block);
        try self.op(wasm.empty_type); // $exit
        try self.op(wasm.loop);
        try self.op(wasm.empty_type); // $loop
        var b: u32 = 0;
        while (b < block_count) : (b += 1) {
            try self.op(wasm.block);
            try self.op(wasm.empty_type);
        }
        // br_table: pc = j branches to $B{j}, relative depth
        // (block_count-1)-j; default is block 0.
        try self.localGet(self.pc_local);
        try self.op(wasm.br_table);
        try self.u32v(block_count);
        var j: u32 = 0;
        while (j < block_count) : (j += 1) try self.u32v(block_count - 1 - j);
        try self.u32v(block_count - 1);

        // Block bodies, innermost first: after end $B{k} comes block
        // k's code, whose branch to $loop is at depth k.
        var k: i64 = @as(i64, block_count) - 1;
        while (k >= 0) : (k -= 1) {
            try self.op(wasm.end); // close $B{k}
            self.loop_depth = @intCast(k);
            self.scope_extra = 0;
            for (function.blocks[@intCast(k)].items) |item| try self.emitInstruction(item);
        }
        try self.op(wasm.end); // close $loop
        try self.op(wasm.end); // close $exit
        try self.op(wasm.end); // close the function body
    }

    // -- module assembly ----------------------------------------------------

    fn module(self: *Emitter) error{OutOfMemory}![]const u8 {
        const function = self.function;
        self.str_source = try self.arena.alloc(?ir.Register, function.instructions.len);
        @memset(self.str_source, null);

        // Local layout: pc (i32), the Luce locals, then one slot per IR
        // register (str(Int)/none results leave i32 placeholders so
        // absolute indices stay exact).
        self.pc_local = 0;
        self.locals_base = 1;
        self.registers_base = self.locals_base + @as(u32, @intCast(function.locals.len));

        try self.emitBody();

        var out: std.ArrayList(u8) = .empty;
        const a = self.arena;
        try out.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 }); // \0asm, v1

        // Types: 0 (i64)->(), 1 (i32)->(), 2 ()->()
        var t: std.ArrayList(u8) = .empty;
        try appendU32(&t, a, 3);
        try t.appendSlice(a, &.{ wasm.func_type, 1, wasm.i64t, 0 });
        try t.appendSlice(a, &.{ wasm.func_type, 1, wasm.i32t, 0 });
        try t.appendSlice(a, &.{ wasm.func_type, 0, 0 });
        try section(&out, a, 1, t.items);

        // Imports: env.emit_i64 (type 0), env.trap (type 1).
        var im: std.ArrayList(u8) = .empty;
        try appendU32(&im, a, import_count);
        try appendImport(&im, a, "env", "emit_i64", 0);
        try appendImport(&im, a, "env", "trap", 1);
        try section(&out, a, 2, im.items);

        // Functions: one, type 2.
        var fs: std.ArrayList(u8) = .empty;
        try appendU32(&fs, a, 1);
        try appendU32(&fs, a, 2);
        try section(&out, a, 3, fs.items);

        // Exports: entry as "main".
        var ex: std.ArrayList(u8) = .empty;
        try appendU32(&ex, a, 1);
        try appendName(&ex, a, "main");
        try ex.append(a, 0x00); // kind: func
        try appendU32(&ex, a, func_entry);
        try section(&out, a, 7, ex.items);

        // Code: one entry — its locals then its body.
        var cs: std.ArrayList(u8) = .empty;
        try appendU32(&cs, a, 1);
        var body: std.ArrayList(u8) = .empty;
        try self.appendLocals(&body);
        try body.appendSlice(a, self.code.items);
        try appendU32(&cs, a, @intCast(body.items.len));
        try cs.appendSlice(a, body.items);
        try section(&out, a, 10, cs.items);

        return out.items;
    }

    /// The function's local declarations, one type per slot in index
    /// order (pc, each Luce local, each register slot), run-length
    /// encoded.  Registers whose result is none/String still take a
    /// slot so an IR register's index is exactly registers_base + r.
    fn appendLocals(self: *Emitter, body: *std.ArrayList(u8)) error{OutOfMemory}!void {
        const function = self.function;
        var kinds: std.ArrayList(u8) = .empty;
        try kinds.append(self.arena, wasm.i32t); // pc
        for (function.locals) |local| {
            try kinds.append(self.arena, if (local.local_type == .int) wasm.i64t else wasm.i32t);
        }
        for (function.result_types) |result| {
            try kinds.append(self.arena, if (result == .int) wasm.i64t else wasm.i32t);
        }
        // Run-length encode consecutive equal types.
        var groups: u32 = 0;
        var i: usize = 0;
        while (i < kinds.items.len) {
            var jj = i + 1;
            while (jj < kinds.items.len and kinds.items[jj] == kinds.items[i]) jj += 1;
            groups += 1;
            i = jj;
        }
        try appendU32(body, self.arena, groups);
        i = 0;
        while (i < kinds.items.len) {
            var jj = i + 1;
            while (jj < kinds.items.len and kinds.items[jj] == kinds.items[i]) jj += 1;
            try appendU32(body, self.arena, @intCast(jj - i));
            try body.append(self.arena, kinds.items[i]);
            i = jj;
        }
    }
};

fn section(out: *std.ArrayList(u8), arena: Allocator, id: u8, body: []const u8) error{OutOfMemory}!void {
    try out.append(arena, id);
    try appendU32(out, arena, @intCast(body.len));
    try out.appendSlice(arena, body);
}

fn appendName(list: *std.ArrayList(u8), arena: Allocator, name: []const u8) error{OutOfMemory}!void {
    try appendU32(list, arena, @intCast(name.len));
    try list.appendSlice(arena, name);
}

fn appendImport(list: *std.ArrayList(u8), arena: Allocator, module_name: []const u8, field: []const u8, type_index: u32) error{OutOfMemory}!void {
    try appendName(list, arena, module_name);
    try appendName(list, arena, field);
    try list.append(arena, 0x00); // import kind: func
    try appendU32(list, arena, type_index);
}

// ---------------------------------------------------------------------------
// tests — the gate and byte structure hold without a wasm runtime; the
// end-to-end oracle against the interpreter lives in tools/wasm-test.sh,
// which runs the emitted modules in deno.
// ---------------------------------------------------------------------------

const compile_mod = @import("compile.zig");
const testing = std.testing;
const script: types.CompileOptions = .{ .entry_mode = .script, .allow_host = true };

fn compileOrNull(source: []const u8) !?ir.Program {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    switch (result) {
        .failure => {
            result.deinit();
            return null;
        },
        .success => |program| return program,
    }
}

test "the integer core is supported; heap and string output are not yet" {
    // Nested loops, every operator, the branch, negation, assert,
    // print(str(Int)): all inside milestone 0.
    var core = (try compileOrNull(
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 10):
        \\        if i % 2 == 0:
        \\            total += i * i - i / 2
        \\        else:
        \\            total -= 0 - i
        \\    assert(total > 0)
        \\    print(str(total))
    )).?;
    defer core.deinit();
    try testing.expect(supported(&core));

    // A List is heap-shaped — milestone 1, refused now.
    var heap = (try compileOrNull(
        \\func main():
        \\    var xs = new List(Int)
        \\    xs.append(3)
        \\    print(str(len(xs)))
    )).?;
    defer heap.deinit();
    try testing.expect(!supported(&heap));

    // print(str) of a String literal is not the str(Int) pipeline.
    var text = (try compileOrNull(
        \\func main():
        \\    print("hello")
    )).?;
    defer text.deinit();
    try testing.expect(!supported(&text));
}

test "a supported program emits a well-formed wasm module" {
    var program = (try compileOrNull(
        \\func main():
        \\    var n = 1
        \\    while n < 1000:
        \\        n = n * 2
        \\    print(str(n))
    )).?;
    defer program.deinit();
    try testing.expect(supported(&program));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes = try compile(arena_state.allocator(), &program);

    // Magic \0asm and version 1.
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 }, bytes[0..8]);

    // Every section after the header is length-prefixed and consumes
    // exactly its declared bytes, in ascending id order — a structural
    // pass a runtime would otherwise catch.
    var offset: usize = 8;
    var last_id: u8 = 0;
    while (offset < bytes.len) {
        const id = bytes[offset];
        try testing.expect(id > last_id); // sections strictly ordered
        last_id = id;
        offset += 1;
        var length: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            const byte = bytes[offset];
            offset += 1;
            length |= @as(u32, byte & 0x7F) << shift;
            if (byte & 0x80 == 0) break;
            shift += 7;
        }
        offset += length;
    }
    try testing.expectEqual(bytes.len, offset); // sections tile the module exactly
}
