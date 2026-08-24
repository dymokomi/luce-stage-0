//! The FFI boundary, on both engines (docs/FFI.md).
//!
//! The probe symbols live in `runtime/ffi.zig` and ride `libluce_rt`,
//! so the compiled arm resolves them at link time and the oracle
//! resolves them in its own image through the shim — one set of
//! symbols, two dispatch strategies, compared like everything else.
//!
//! What is deliberately absent: an unknown-symbol session.  The two
//! arms answer that case at different times by design — the compiled
//! arm at link, the oracle at the call — so there is no one behavior
//! to compare, and the compile-time refusals below are where the
//! boundary's rules are pinned.

const std = @import("std");
const luce = @import("luce");
const agree = @import("agree.zig");

const testing = std.testing;

fn expectRejected(source: []const u8, code: []const u8) !void {
    var result = try luce.compile.compile(testing.allocator, source, .{ .allow_host = true });
    defer result.deinit();
    switch (result) {
        .success => {
            std.debug.print("expected {s}, but the program compiled:\n{s}\n", .{ code, source });
            return error.TestUnexpectedResult;
        },
        .failure => |diagnostics| {
            for (0..diagnostics.count()) |index| {
                if (std.mem.eql(u8, diagnostics.at(index).?.code, code)) return;
            }
            std.debug.print("expected {s}, but the diagnostics were:\n", .{code});
            for (0..diagnostics.count()) |index| {
                const one = diagnostics.at(index).?;
                std.debug.print("  {s}: {s}\n", .{ one.code, one.message });
            }
            return error.TestUnexpectedResult;
        },
    }
}

test "an extern call crosses the boundary and back, every Tier-1 return kind" {
    try agree.prints(
        \\extern func luce_ffi_probe_add(a: i64, b: i64) -> i64
        \\extern func luce_ffi_probe_narrow(a: u32) -> u32
        \\extern func luce_ffi_probe_pi() -> f64
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_add(40, 2)))
        \\    print(str(luce_ffi_probe_narrow(9)))
        \\    print(str(luce_ffi_probe_pi()))
        \\    let held = luce_ffi_probe_add(luce_ffi_probe_add(1, 2), 3)
        \\    print(str(held))
        \\
    ,
        \\42
        \\10
        \\3.5
        \\6
        \\
    );
}

test "the extern declaration's refusals keep the C shape the whole truth" {
    // A parameter outside the boundary vocabulary — a heap container
    // has no C shape and never will.
    try expectRejected(
        \\extern func speaks(words: list[i64]) -> i64
        \\
        \\func main():
        \\    var held = list[i64]()
        \\    print(str(speaks(held)))
        \\
    , "luce.sema.extern");
    // A named argument: the C shape promises no names.
    try expectRejected(
        \\extern func luce_ffi_probe_add(a: i64, b: i64) -> i64
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_add(a = 1, b = 2)))
        \\
    , "luce.sema.extern");
    // Arity is exact.
    try expectRejected(
        \\extern func luce_ffi_probe_add(a: i64, b: i64) -> i64
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_add(1)))
        \\
    , "luce.sema.extern");
    // A width C itself does not pass: `f16` is not a C scalar, so it
    // stays outside the boundary vocabulary even now that the narrow
    // integers cross (docs/FFI.md).
    try expectRejected(
        \\extern func tiny(a: f16) -> i64
        \\
        \\func main():
        \\    print(str(tiny(1.0)))
        \\
    , "luce.sema.extern");
}

test "the scoped buffer form hands real memory across and back" {
    // `zstring` builds the NUL-terminated bytes, `with_bytes` pins
    // them for the scope and hands over the address, and the C side
    // reads the actual memory: 'A' + 'B' + 0 = 131 on both engines.
    //
    // The parameter is `foreign?` deliberately: an **empty** buffer
    // has no address, so `with_bytes` hands over the zero token, and
    // a callee accepting C's null-with-zero-count convention declares
    // the nullable slot — a bare `foreign` would trap `null_foreign`
    // on exactly that call, which the trap specs below pin.
    try agree.prints(
        \\import std.c
        \\
        \\extern func luce_ffi_probe_sum_bytes(at: foreign?, count: u64) -> i64
        \\
        \\func main():
        \\    var data = c.zstring("AB")
        \\    let total = c.with_bytes(data, (p) => luce_ffi_probe_sum_bytes(p, 3))
        \\    print(str(total))
        \\    var empty = list[u8]()
        \\    print(str(c.with_bytes(empty, (p) => luce_ffi_probe_sum_bytes(p, 0))))
        \\
    ,
        \\131
        \\0
        \\
    );
}

test "a blocking extern answers outside the effect lock on both engines" {
    // `blocking` is the declaration's opt-out of the effect lock — the
    // callee promises its own thread-safety and may park the thread.
    // The answer is the same either way; what this pins is that the
    // unlocked path executes at all, on both engines, and stays a
    // per-declaration fact rather than a call-site one.
    try agree.prints(
        \\extern blocking func luce_ffi_probe_add(a: i64, b: i64) -> i64
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_add(20, 22)))
        \\
    ,
        \\42
        \\
    );
}

test "foreign? decodes at the boundary: C's null is none, a token is present" {
    try agree.prints(
        \\extern func luce_ffi_probe_null() -> foreign?
        \\extern func luce_ffi_probe_token() -> foreign?
        \\
        \\func main():
        \\    let absent = luce_ffi_probe_null()
        \\    print(str(absent == none))
        \\    let held = luce_ffi_probe_token()
        \\    print(str(held == none))
        \\
    ,
        \\true
        \\false
        \\
    );
}

test "foreign? encodes at the boundary: none crosses as 0 and round-trips" {
    // `echo` answers its own argument, so `none` -> 0 -> `none` and a
    // present token -> itself -> present are watched in one call each.
    try agree.prints(
        \\extern func luce_ffi_probe_token() -> foreign
        \\extern func luce_ffi_probe_echo(token: foreign?) -> foreign?
        \\
        \\func main():
        \\    let absent: foreign? = none
        \\    print(str(luce_ffi_probe_echo(absent) == none))
        \\    let held = luce_ffi_probe_token()
        \\    let back = luce_ffi_probe_echo(held)
        \\    print(str(back == none))
        \\
    ,
        \\true
        \\false
        \\
    );
}

test "a bare foreign return enforces its non-null contract" {
    try agree.trapSays(
        \\extern func luce_ffi_probe_null() -> foreign
        \\
        \\func main():
        \\    let held = luce_ffi_probe_null()
        \\    print(str(held == held))
        \\
    , .null_foreign, "null crossed a non-null C boundary");
}

test "a bare foreign parameter enforces its non-null contract" {
    // The zero token is the type's zero value — constructible without
    // any boundary crossing — and the boundary refuses to carry it
    // through a non-? slot.
    try agree.trap(
        \\extern func luce_ffi_probe_echo(token: foreign) -> foreign
        \\
        \\func main():
        \\    var zero: foreign
        \\    let back = luce_ffi_probe_echo(zero)
        \\    print(str(back == back))
        \\
    , .null_foreign);
}

test "a present zero token inside foreign? is not none" {
    // The agree case the representation ruling demands (docs/FFI.md):
    // the niche lives in the ABI, never in the type.  A zero token is
    // a *present* value, and both engines must say so.  The wrap goes
    // through a function so flow analysis cannot fold the question.
    try agree.prints(
        \\func wrap(token: foreign) -> foreign?:
        \\    return token
        \\
        \\func main():
        \\    var zero: foreign
        \\    let wrapped = wrap(zero)
        \\    print(str(wrapped == none))
        \\
    ,
        \\false
        \\
    );
}

test "optionals of non-foreign types still do not cross" {
    try expectRejected(
        \\extern func bad(flag: i64?) -> i64
        \\
        \\func main():
        \\    print(str(bad(none)))
        \\
    , "luce.sema.extern");
    try expectRejected(
        \\extern func bad() -> u32?
        \\
        \\func main():
        \\    print(str(bad() == none))
        \\
    , "luce.sema.extern");
}

test "str crosses seamlessly: an argument becomes C's NUL-terminated text" {
    try agree.prints(
        \\extern func luce_ffi_probe_text_len(text: str) -> i64
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_text_len("hello")))
        \\    print(str(luce_ffi_probe_text_len("")))
        \\    let held = "two words"
        \\    print(str(luce_ffi_probe_text_len(held)))
        \\
    ,
        \\5
        \\0
        \\9
        \\
    );
}

test "a -> str result is copied and validated at the boundary" {
    try agree.prints(
        \\extern func luce_ffi_probe_greet() -> str
        \\
        \\func main():
        \\    let text = luce_ffi_probe_greet()
        \\    print(text)
        \\    print(str(len(text)))
        \\
    ,
        \\hello from C
        \\12
        \\
    );
}

test "invalid C text refuses to become a str" {
    try agree.trapSays(
        \\extern func luce_ffi_probe_bad_text() -> str
        \\
        \\func main():
        \\    print(luce_ffi_probe_bad_text())
        \\
    , .invalid_utf8, "C text is not valid UTF-8");
}

test "a named handle is nominal: Window is not Renderer, foreign, or an integer" {
    // The whole point of `extern type` (docs/FFI.md): the type system
    // carries what C's own pointer types carry, so a `Window` in a
    // `Renderer` slot is a compile refusal, not a runtime mystery.
    try expectRejected(
        \\extern type Window
        \\extern type Renderer
        \\
        \\extern func luce_ffi_probe_token() -> Window
        \\extern func luce_ffi_probe_echo(token: Renderer) -> Renderer
        \\
        \\func main():
        \\    let w = luce_ffi_probe_token()
        \\    let r = luce_ffi_probe_echo(w)
        \\    print(str(r == r))
        \\
    , "luce.sema.type");
    // An integer is not a handle either, whatever the representation.
    try expectRejected(
        \\extern type Device = i32
        \\
        \\extern func luce_ffi_probe_echo_i32(v: Device) -> Device
        \\
        \\func main():
        \\    let held: i32 = 3
        \\    let back = luce_ffi_probe_echo_i32(held)
        \\    print(str(back == back))
        \\
    , "luce.sema.type");
    // A bare `foreign` does not become a handle implicitly: the
    // conversion has one direction and it is not this one.
    try expectRejected(
        \\extern type Window
        \\
        \\extern func luce_ffi_probe_token() -> foreign
        \\extern func luce_ffi_probe_echo(token: Window) -> Window
        \\
        \\func main():
        \\    let raw = luce_ffi_probe_token()
        \\    let w = luce_ffi_probe_echo(raw)
        \\    print(str(w == w))
        \\
    , "luce.sema.type");
}

test "a pointer-shaped handle round-trips, and its ? decodes null to none" {
    try agree.prints(
        \\extern type Window
        \\
        \\extern func luce_ffi_probe_token() -> Window
        \\extern func luce_ffi_probe_echo(token: Window) -> Window
        \\extern func luce_ffi_probe_null() -> Window?
        \\
        \\func main():
        \\    let w = luce_ffi_probe_token()
        \\    let back = luce_ffi_probe_echo(w)
        \\    print(str(back == w))
        \\    let absent = luce_ffi_probe_null()
        \\    print(str(absent == none))
        \\
    ,
        \\true
        \\true
        \\
    );
}

test "an integer-shaped handle's zero is a value and takes no trap" {
    // `extern type Device = i32` crosses at C's exact `int` width, and
    // zero is an ordinary value — CUDA device 0 is the first GPU — so
    // the boundary neither traps it nor decodes it (docs/FFI.md).
    try agree.prints(
        \\extern type Device = i32
        \\
        \\extern func luce_ffi_probe_echo_i32(v: Device) -> Device
        \\
        \\func main():
        \\    var first: Device
        \\    let back = luce_ffi_probe_echo_i32(first)
        \\    print(str(back == first))
        \\
    ,
        \\true
        \\
    );
    // Its `?` has no C encoding — a present zero and an absent slot
    // would be indistinguishable — so the boundary refuses it.  In
    // ordinary Luce code the optional stays legal like any other T?.
    try expectRejected(
        \\extern type Device = i32
        \\
        \\extern func broken() -> Device?
        \\
        \\func main():
        \\    print(str(broken() == none))
        \\
    , "luce.sema.extern");
}

test "a bare pointer-shaped handle keeps the non-null contract" {
    try agree.trap(
        \\extern type Window
        \\
        \\extern func luce_ffi_probe_echo(token: Window) -> Window
        \\
        \\func main():
        \\    var zero: Window
        \\    let back = luce_ffi_probe_echo(zero)
        \\    print(str(back == back))
        \\
    , .null_foreign);
}

test "foreign(w) is the one explicit escape, and it has one direction" {
    try agree.prints(
        \\extern type Window
        \\
        \\extern func luce_ffi_probe_token() -> Window
        \\extern func luce_ffi_probe_echo(token: foreign) -> foreign
        \\
        \\func main():
        \\    let w = luce_ffi_probe_token()
        \\    let raw = foreign(w)
        \\    let back = luce_ffi_probe_echo(raw)
        \\    print(str(back == raw))
        \\
    ,
        \\true
        \\
    );
    // An integer-shaped handle has nothing to strip: its value is an
    // integer, not a token (docs/FFI.md).
    try expectRejected(
        \\extern type Device = i32
        \\
        \\extern func luce_ffi_probe_echo_i32(v: Device) -> Device
        \\
        \\func main():
        \\    var d: Device
        \\    print(str(foreign(d) == foreign(d)))
        \\
    , "luce.sema.convert");
}

test "the extern type declaration's refusals" {
    // The representation vocabulary is exactly the four Tier-1 widths.
    try expectRejected(
        \\extern type Bad = u8
        \\
        \\func main():
        \\    print("never")
        \\
    , "luce.parse.extern");
    // A handle shares the type namespace: one name, one declaration.
    try expectRejected(
        \\struct Window:
        \\    x: i64
        \\
        \\extern type Window
        \\
        \\func main():
        \\    print("never")
        \\
    , "luce.sema.duplicate");
}

test "the C reads copy out of foreign memory" {
    // The buffer is Luce's own, handed out as a token and read back
    // through the two copy verbs — which is exactly the shape of
    // reading C-owned memory, with a lifetime this spec controls.
    try agree.prints(
        \\import std.c
        \\
        \\func main():
        \\    var data = c.zstring("AB")
        \\    let copied = c.with_bytes(data, (p) => i64(len(c.bytes_at(p, 2))))
        \\    print(str(copied))
        \\    var text = c.zstring("hola")
        \\    let read = c.with_bytes(text, (p) => i64(len(c.cstring_at(p))))
        \\    print(str(read))
        \\
    ,
        \\2
        \\4
        \\
    );
}

// ---------------------------------------------------------------------------
// 0.21 phase 3: out parameters, the full scalar set, no arity cap, str?
// ---------------------------------------------------------------------------

test "out parameters become extra results after the declared return" {
    // The call writes no argument for an out slot; the compiler
    // allocates it, C fills it, and the values come back in
    // declaration order after the declared return — received by the
    // ordinary destructuring (docs/FFI.md, docs/RETURNS.md).  The
    // negative split pins that an i32 out slot keeps its sign.
    try agree.prints(
        \\extern func luce_ffi_probe_split(v: i64, out hi: i32, out lo: i32) -> bool
        \\
        \\func main():
        \\    let ok, hi, lo = luce_ffi_probe_split(4294967298)
        \\    print(str(ok))
        \\    print(str(hi))
        \\    print(str(lo))
        \\    let sign, top, bottom = luce_ffi_probe_split(-1)
        \\    print(str(sign))
        \\    print(str(top))
        \\    print(str(bottom))
        \\    luce_ffi_probe_split(7)
        \\
    ,
        \\true
        \\1
        \\2
        \\true
        \\-1
        \\-1
        \\
    );
}

test "a void return with one out slot answers a single value" {
    try agree.prints(
        \\extern func luce_ffi_probe_out_token(token: u64, out slot: u64)
        \\
        \\func main():
        \\    let held = luce_ffi_probe_out_token(7)
        \\    print(str(held))
        \\
    ,
        \\7
        \\
    );
}

test "a handle out slot takes the same decode as a handle result" {
    // A pointer-shaped handle read back out of a slot obeys the
    // phase-1 rules whole (docs/FFI.md): `?` decodes C's 0 to `none`,
    // and a present token is the value.
    try agree.prints(
        \\extern type Window
        \\
        \\extern func luce_ffi_probe_out_token(token: u64, out w: Window?)
        \\
        \\func main():
        \\    let absent = luce_ffi_probe_out_token(0)
        \\    print(str(absent == none))
        \\    let held = luce_ffi_probe_out_token(4660)
        \\    print(str(held == none))
        \\
    ,
        \\true
        \\false
        \\
    );
    // The bare form is the enforced non-null contract, in the out
    // direction too.
    try agree.trap(
        \\extern type Window
        \\
        \\extern func luce_ffi_probe_out_token(token: u64, out w: Window)
        \\
        \\func main():
        \\    let held = luce_ffi_probe_out_token(0)
        \\    print(str(held == held))
        \\
    , .null_foreign);
}

test "the full scalar set round-trips at its exact C width" {
    // Sign is the point: a u8 200 and an i8 -5 come back themselves
    // only when each crossed with the extension its signedness earns,
    // and the i8 sum is visibly wrong if a negative was zero-extended.
    try agree.prints(
        \\extern func luce_ffi_probe_echo_u8(v: u8) -> u8
        \\extern func luce_ffi_probe_echo_i8(v: i8) -> i8
        \\extern func luce_ffi_probe_echo_u16(v: u16) -> u16
        \\extern func luce_ffi_probe_echo_i16(v: i16) -> i16
        \\extern func luce_ffi_probe_echo_f32(v: f32) -> f32
        \\extern func luce_ffi_probe_echo_bool(v: bool) -> bool
        \\extern func luce_ffi_probe_add_i8(a: i8, b: i8) -> i64
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_echo_u8(200)))
        \\    print(str(luce_ffi_probe_echo_i8(-5)))
        \\    print(str(luce_ffi_probe_echo_u16(60000)))
        \\    print(str(luce_ffi_probe_echo_i16(-12345)))
        \\    print(str(luce_ffi_probe_echo_f32(2.5)))
        \\    print(str(luce_ffi_probe_echo_bool(true)))
        \\    print(str(luce_ffi_probe_echo_bool(false)))
        \\    print(str(luce_ffi_probe_add_i8(-5, -6)))
        \\
    ,
        \\200
        \\-5
        \\60000
        \\-12345
        \\2.5
        \\true
        \\false
        \\-11
        \\
    );
}

test "eleven mixed arguments marshal position-correct on both engines" {
    // The cuLaunchKernel shape (docs/FFI.md): integers and doubles
    // interleaved past the eighth slot.  The probe folds every
    // position with its own weight, so a swapped or skipped slot
    // changes the answer.
    try agree.prints(
        \\extern func luce_ffi_probe_arity11(a: i32, b: f64, c: i64, d: f64, e: i32, f: i64, g: f64, h: i32, i: i64, j: f64, k: i32) -> f64
        \\
        \\func main():
        \\    let total = luce_ffi_probe_arity11(1, 2.0, 3, 4.0, 5, 6, 7.0, 8, 9, 10.0, 11)
        \\    print(str(total))
        \\
    ,
        \\506
        \\
    );
}

test "fourteen mixed arguments spill past the registers and stay ordered" {
    // The cblas_dgemm shape (docs/FFI.md): enough arguments to spill
    // past both register files on every emitted target.
    try agree.prints(
        \\extern func luce_ffi_probe_arity14(a: i32, b: i32, c: i32, d: i64, e: i64, f: i64, g: f64, h: i64, i: i64, j: f64, k: i64, l: i64, m: f64, n: i64) -> f64
        \\
        \\func main():
        \\    let total = luce_ffi_probe_arity14(1, 2, 3, 4, 5, 6, 7.0, 8, 9, 10.0, 11, 12, 13.0, 14)
        \\    print(str(total))
        \\
    ,
        \\1015
        \\
    );
}

test "str? crosses both ways: none is C's NULL and NULL is none" {
    try agree.prints(
        \\extern func luce_ffi_probe_echo_text(text: str?) -> str?
        \\
        \\func main():
        \\    let absent: str? = none
        \\    print(str(luce_ffi_probe_echo_text(absent) == none))
        \\    let back = luce_ffi_probe_echo_text("hola") else "missing"
        \\    print(back)
        \\
    ,
        \\true
        \\hola
        \\
    );
}

test "out is a modifier only when another name follows" {
    // `out: i32` stays a parameter *named* out, exactly as `blocking`
    // stays an ordinary identifier outside its position.
    try agree.prints(
        \\extern func luce_ffi_probe_echo_i32(out: i32) -> i32
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_echo_i32(41)))
        \\
    ,
        \\41
        \\
    );
}

test "the out declaration's refusals" {
    // Outside an extern parameter list `out` is not a modifier at
    // all: an ordinary function reads it as a parameter name, and a
    // second name behind it is the ordinary parse mistake it looks
    // like.
    try expectRejected(
        \\func fills(out x: i64) -> i64:
        \\    return x
        \\
        \\func main():
        \\    print(str(fills(1)))
        \\
    , "luce.parse.expected");
    // Text has no caller-allocated word: `str` stays out of the out
    // position (docs/FFI.md).
    try expectRejected(
        \\extern func bad(out words: str) -> bool
        \\
        \\func main():
        \\    let ok, words = bad()
        \\    print(words)
        \\
    , "luce.sema.extern");
    // An integer-shaped handle's optional has no C encoding in the
    // out direction either.
    try expectRejected(
        \\extern type Device = i32
        \\
        \\extern func bad(out d: Device?) -> bool
        \\
        \\func main():
        \\    let ok, d = bad()
        \\    print(str(ok))
        \\
    , "luce.sema.extern");
    // The extra results ride the ordinary shape rules: the name count
    // must match what the call answers.
    try expectRejected(
        \\extern func luce_ffi_probe_split(v: i64, out hi: i32, out lo: i32) -> bool
        \\
        \\func main():
        \\    let ok, hi = luce_ffi_probe_split(7)
        \\    print(str(ok))
        \\
    , "luce.sema.shape");
    // And the ordinary shape positions: a multi-value answer cannot
    // stand in an argument.
    try expectRejected(
        \\extern func luce_ffi_probe_split(v: i64, out hi: i32, out lo: i32) -> bool
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_split(7)))
        \\
    , "luce.sema.call");
}
