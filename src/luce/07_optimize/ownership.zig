//! Ownership dead-store elimination — the pass LLVM structurally
//! cannot write.
//!
//! **What ownership costs in MIR.**  Scope ownership (docs/OWNERSHIP.md,
//! S1-S43) is carried by two instructions.  `object_bind %L, rV` writes
//! "frame `serial`, local `%L`" into the owner field of every object
//! in rV; `object_unbind %L, rV` frees those objects *if that is still
//! who owns them*, and does nothing otherwise.  Compiled, each one is a
//! `luce_rt_bind` / `luce_rt_unbind` call.
//!
//! **The pattern this removes.**  Every fresh object is parked in a
//! hidden temporary first, so the end of the statement can release it
//! if nothing adopted it (S3, S19).  When something does adopt it —
//! `let xs = new List(Int)` — the lowering binds it twice and then
//! releases the temporary:
//!
//! ```text
//!     r0 = heap_new List(Int)
//!     local_set %0, r0        # the hidden temporary
//!     object_bind %0, r0
//!     local_set %1, r0        # xs
//!     object_bind %1, r0      # ... which overwrites the owner field
//!     object_unbind %0, r0    # ... so this can never match, and frees nothing
//! ```
//!
//! The second bind overwrites what the first one wrote before anything
//! reads it: a dead store, exactly like a dead store to memory. And the
//! unbind names `%0` while the object is owned by `%1`, so at run time
//! it walks the handle, compares two owner fields, and returns — every
//! time, on every path.  Both are deleted here.  What is *not* deleted
//! is the surviving pair: `object_unbind` is the deallocation, not a
//! release of a reference count, so dropping a load-bearing pair would
//! leak the object rather than cost a call.  That asymmetry is why this
//! pass deletes only stores it can prove are overwritten and only
//! unbinds it can prove are no-ops.
//!
//! **Why LLVM cannot.**  Downstream these are two opaque calls into
//! `libluce_rt` that take an object handle and a `(serial, local)`
//! pair.  Proving the second call's write kills the first's requires
//! knowing that the owner field is one field, that a bind writes it
//! unconditionally, and that an unbind reads it and compares — the
//! whole memory model.  `default<O2>` has none of that and must assume
//! both calls read and write the world.  Swift needed `@_semantics`
//! annotations and a dedicated SIL pass (`SemanticARCOpts`) to get the
//! same information; MIR names the operations, so we get it for free.
//!
//! **The window.**  Both rewrites hold only while nothing between the
//! two instructions can change an owner or free an object —
//! `effects.ownershipTransparent`.  A call, a container operation, or
//! a `give`/`free`/`copy` ends the window and everything known is
//! forgotten.  So does a `heap_new`, though nothing turns on it: a
//! fresh object is named at a generation no live handle carries even
//! when it moves into a row somebody else vacated, and the pattern
//! this pass serves has its allocation in front of both binds rather
//! than between them.
//! Knowledge is also keyed by *register*, not by object, and a bind
//! forgets every other register, because two registers may name one
//! object and rebinding through one of them would make a conclusion
//! about the other wrong.

const std = @import("std");
const defs = @import("../06_mir/defs.zig");
const effects = @import("effects.zig");

const Allocator = std.mem.Allocator;
const Function = defs.Function;
const LocalId = defs.LocalId;
const Program = defs.Program;
const Register = defs.Register;

/// What the walk knows about one register: which local last claimed
/// the objects it names, and where that claim was written.
const Claim = struct {
    local: LocalId,
    /// Position of the `object_bind` inside the block's item list, so
    /// a later bind can strike it out.
    position: usize,
};

/// Delete overwritten `object_bind`s and provably inert
/// `object_unbind`s across the whole program.
pub fn ownership(arena: Allocator, program: *Program) Allocator.Error!void {
    for (program.functions) |*function| try walkFunction(arena, function);
}

fn walkFunction(arena: Allocator, function: *Function) Allocator.Error!void {
    var claims: std.AutoHashMapUnmanaged(Register, Claim) = .empty;
    var dead: std.ArrayList(bool) = .empty;

    for (function.blocks) |*block| {
        claims.clearRetainingCapacity();
        dead.clearRetainingCapacity();
        try dead.appendNTimes(arena, false, block.items.len);
        var found = false;

        for (block.items, 0..) |item, position| {
            switch (function.instructions[item]) {
                .object_bind => |bind| {
                    if (claims.get(bind.value)) |earlier| {
                        // Overwritten before anybody could read it.
                        dead.items[earlier.position] = true;
                        found = true;
                    }
                    // Any other register may alias this object, and
                    // this write just changed its owner too.
                    claims.clearRetainingCapacity();
                    try claims.put(arena, bind.value, .{ .local = bind.local, .position = position });
                },
                .object_unbind => |unbind| {
                    const claim = claims.get(unbind.value) orelse continue;
                    if (claim.local != unbind.local) {
                        // Owned by somebody else, so this frees
                        // nothing.  Nothing about the heap changes,
                        // and the window stays open.
                        dead.items[position] = true;
                        found = true;
                        continue;
                    }
                    // A real release: the objects are gone and every
                    // handle to them is now stale.
                    claims.clearRetainingCapacity();
                },
                else => |other| if (!effects.ownershipTransparent(function, other)) {
                    claims.clearRetainingCapacity();
                },
            }
        }

        if (!found) continue;
        var kept: usize = 0;
        for (block.items, dead.items) |item, strike| {
            if (strike) continue;
            block.items[kept] = item;
            kept += 1;
        }
        block.items = block.items[0..kept];
    }
}
