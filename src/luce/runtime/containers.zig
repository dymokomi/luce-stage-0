//! List, Map, Array, and Builder — every container operation Luce has,
//! and the `copy` verb that deep-copies a whole object.
//!
//! Each function here takes values rather than IR registers, so the
//! interpreter and compiled code reach the same body by the same path.
//! Where an operation is polymorphic in Luce (`a[i]` reads a list, a
//! map, or an array) it is polymorphic here too: the object's own kind
//! decides, exactly as it does in the language.
//!
//! **No object is freed while a program runs.**  An element overwritten,
//! removed, or cleared leaks until the runtime's final sweep; only its
//! *value storage* — a String's bytes, a struct value's field run — is
//! given back at the store site, through `dropStorage`.  An object row
//! is reclaimed only at `Runtime.deinit`.

const std = @import("std");
const heap = @import("heap.zig");
const operators = @import("operators.zig");
const value = @import("value.zig");

const Error = heap.Error;
const Runtime = heap.Runtime;
const Value = value.Value;

/// `len(x)`: bytes for a String, elements for a list, entries for a
/// map, the first axis for an array, bytes for a Builder.
pub fn length(runtime: *Runtime, target: Value) Error!Value {
    const measured: usize = switch (target.tag) {
        .string => if (target.hasValidStringRepresentation())
            target.asString().len
        else
            return runtime.fail(.not_owned),
        .object => blk: {
            const object = try runtime.resolve(target);
            break :blk switch (object.data) {
                .list => object.elements.count,
                .map => |map| map.entries.items.len,
                .array => if (object.dims.len == 0) 0 else @intCast(object.dims[0]),
                .builder => |builder| builder.items.len,
                // The verifier admits no file here: a file is not a
                // container and has no length.
                .file, .task => return runtime.fail(.not_owned),
            };
        },
        else => return runtime.fail(.not_owned),
    };
    return Value.ofLong(@intCast(measured));
}

/// `a[i]`, `m[key]`, `grid[r, c]`.  A list or array index out of range
/// traps; a missing map key traps `key_missing` (`m.get(k, default)` is
/// the total form, and `mapPlace` is what a compound store reads
/// instead — a read that defines, because it is half of a write).
pub fn indexGet(runtime: *Runtime, target: Value, indices: []const Value) Error!Value {
    const object = try runtime.resolve(target);
    try requireIndexRank(runtime, object, indices);
    switch (object.data) {
        .list => {
            try requireLongIndex(runtime, indices[0]);
            const index = indices[0].asLong();
            if (index < 0 or index >= object.elements.count) {
                return runtime.fail(.index_bounds);
            }
            return object.elements.at(@intCast(index));
        },
        .map => |map| {
            try requireMapKey(runtime, indices[0]);
            const at = map.find(&indices[0]) orelse return runtime.fail(.key_missing);
            return map.entries.items[at].value;
        },
        .array => {
            for (indices) |index| try requireLongIndex(runtime, index);
            const flat = heap.flattenIndex(object.dims, indices) orelse
                return runtime.fail(.index_bounds);
            return object.elements.at(flat);
        },
        .builder, .file, .task => return runtime.fail(.not_owned),
    }
}

/// `a[i] = v`, `m[key] = v`, `grid[r, c] = v`.
///
/// **Consumes `held`**, which arrives already owned (docs/STRINGS.md):
/// the caller's IR either copied it with `own_storage` or handed over a
/// value of its own.  `m[k] = m[k]` is legal and stays legal, because
/// the copy the first form takes stands in front of this call rather
/// than inside it.
///
/// The **key** is the one value here that is still a borrow: a store
/// looks its key up before it stores anything, and an entry that
/// already exists must not pay for a copy of a key it will not keep.
pub fn indexSet(runtime: *Runtime, target: Value, indices: []const Value, held: Value) Error!void {
    const stored = held;
    // `stored` is consumed.  On an error return its value storage goes
    // back; any objects it carries leak until the run ends, like every
    // other object.
    errdefer runtime.dropStorage(stored);
    const object = try runtime.resolveMutable(target);
    try requireIndexRank(runtime, object, indices);
    switch (object.data) {
        .list => {
            try requireLongIndex(runtime, indices[0]);
            const index = indices[0].asLong();
            if (index < 0 or index >= object.elements.count) {
                return runtime.fail(.index_bounds);
            }
            // An element overwrite lets the old cell's value go: its
            // storage back and its reference released (docs/MEMORY.md).
            // Only a `Value` cell can hold either.
            if (object.elements.kind == .value) {
                runtime.freeValue(object.elements.at(@intCast(index)));
            }
            object.elements.put(@intCast(index), stored);
        },
        .map => |*map| {
            const key = indices[0];
            try requireMapKey(runtime, key);
            if (map.find(&key)) |at| {
                runtime.freeValue(map.entries.items[at].value);
                map.entries.items[at].value = stored;
            } else {
                // A fresh entry owns its key too, and its storage is
                // freed with the map at the final sweep.
                const owned_key = try runtime.ownValue(key);
                errdefer runtime.dropStorage(owned_key);
                try map.insert(runtime.objects, .{ .key = owned_key, .value = stored });
            }
        },
        .array => {
            for (indices) |index| try requireLongIndex(runtime, index);
            const flat = heap.flattenIndex(object.dims, indices) orelse
                return runtime.fail(.index_bounds);
            // An element overwrite lets the old cell's value go: its
            // storage back and its reference released (docs/MEMORY.md).
            // Only a `Value` cell can hold either.
            if (object.elements.kind == .value) {
                runtime.freeValue(object.elements.at(flat));
            }
            object.elements.put(flat, stored);
        },
        .builder, .file, .task => return runtime.fail(.not_owned),
    }
}

/// The verifier normally makes rank a type fact, but this is also the
/// runtime's last wall against decoded or hand-written MIR.  In particular,
/// checking before the list/map arms read `indices[0]` turns a malformed
/// call into a normal Luce trap instead of a host-language bounds panic.
fn requireIndexRank(runtime: *Runtime, object: *const heap.Object, indices: []const Value) Error!void {
    const wanted = switch (object.data) {
        .list, .map => 1,
        .array => object.dims.len,
        .builder, .file, .task => return runtime.fail(.not_owned),
    };
    if (indices.len != wanted) return runtime.fail(.index_bounds);
}

fn requireLongIndex(runtime: *Runtime, index: Value) Error!void {
    if (index.tag != .long) return runtime.fail(.not_owned);
}

fn requireMapKey(runtime: *Runtime, key: Value) Error!void {
    switch (key.tag) {
        .long => {},
        .string => if (!key.hasValidStringRepresentation()) return runtime.fail(.not_owned),
        else => return runtime.fail(.not_owned),
    }
}

/// `xs[a:b]` on a list.  Slices copy — including deep copies of object
/// elements, since two containers can never own one object (S23, S31).
pub fn listSlice(runtime: *Runtime, target: Value, start: i64, end: i64) Error!Value {
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => {},
        .map, .array, .builder, .file, .task => return runtime.fail(.not_owned),
    }
    const source = object.elements;
    if (start < 0 or end < start or end > source.count) return runtime.fail(.index_bounds);
    // The slice holds what the source holds, packed the same way.
    var copied: heap.Object.Elements = .{ .kind = source.kind };
    errdefer dropBuilt(runtime, &copied);
    try copied.ensureCapacity(runtime.objects, @intCast(end - start));
    var at: usize = @intCast(start);
    while (at < @as(usize, @intCast(end))) : (at += 1) {
        // `source` is a copy of the row's run, so the buffer it names
        // stays put while `deepCopy` allocates and moves the table.
        const duplicate = try runtime.deepCopy(source.at(at));
        copied.count += 1;
        copied.put(copied.count - 1, duplicate);
    }
    return runtime.attachList(copied);
}

/// `xs.append(v)` on a list, or `b.append(text)` on a Builder.
///
/// A list **consumes** `held`, like every other store site: it arrives
/// already owned, so `xs.append(xs[0])` is safe because the copy stands
/// in the IR in front of this call (docs/STRINGS.md).  A Builder does
/// not — it copies bytes into a buffer of its own and the text stays
/// the caller's, which is what it always did.
pub fn append(runtime: *Runtime, target: Value, held: Value) Error!void {
    // A List consumes `held` even when the immutable backstop rejects
    // the write; a Builder only borrows it.  Resolve once to learn
    // which contract applies, then enter the one mutable gate in the
    // matching arm.
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => {
            // A List consumes `held`, even when the immutable backstop
            // rejects the write: on any error its value storage goes
            // back and any objects it carries leak until the run ends.
            errdefer runtime.dropStorage(held);
            try runtime.requireMutable(object);
            try object.elements.append(runtime.objects, held);
        },
        .builder => {
            try runtime.requireMutable(object);
            if (!held.hasValidStringRepresentation()) return runtime.fail(.not_owned);
            try object.data.builder.appendSlice(runtime.objects, held.asString());
        },
        .map, .array, .file, .task => return runtime.fail(.not_owned),
    }
}

/// `b.append_ascii(code)`.  ASCII only: the builder's bytes become a
/// String, and String is valid UTF-8.  Anything wider goes through
/// chr(), which encodes the codepoint.
pub fn appendAscii(runtime: *Runtime, target: Value, code: i64) Error!void {
    const object = try runtime.resolveMutable(target);
    if (code < 0 or code > 0x7F) return runtime.fail(.bad_codepoint);
    switch (object.data) {
        .builder => |*builder| try builder.append(runtime.objects, @intCast(code)),
        .list, .map, .array, .file, .task => return runtime.fail(.not_owned),
    }
}

/// `xs.pop()`.  pop hands the element out of the container; whatever
/// receives it holds it next.
pub fn pop(runtime: *Runtime, target: Value) Error!Value {
    const object = try runtime.resolveMutable(target);
    switch (object.data) {
        .list => {},
        .map, .array, .builder, .file, .task => return runtime.fail(.not_owned),
    }
    return object.elements.pop() orelse return runtime.fail(.empty_collection);
}

/// `xs.insert(i, v)`.  **Consumes `held`** (docs/STRINGS.md), including
/// on the out-of-range trap: its value storage always goes back.
pub fn insert(runtime: *Runtime, target: Value, index: i64, held: Value) Error!void {
    errdefer runtime.dropStorage(held);
    const object = try runtime.resolveMutable(target);
    switch (object.data) {
        .list => {},
        .map, .array, .builder, .file, .task => return runtime.fail(.not_owned),
    }
    if (index < 0 or index > object.elements.count) return runtime.fail(.index_bounds);
    try object.elements.insert(runtime.objects, @intCast(index), held);
}

/// `xs.remove(i)` or `m.remove(key)`.  Removing an element drops its
/// value: its storage back and its reference released (docs/MEMORY.md).
/// Removing a key a map does not hold does nothing.
pub fn remove(runtime: *Runtime, target: Value, which: Value) Error!void {
    const object = try runtime.resolveMutable(target);
    switch (object.data) {
        .list => {
            try requireLongIndex(runtime, which);
            const index = which.asLong();
            if (index < 0 or index >= object.elements.count) {
                return runtime.fail(.index_bounds);
            }
            runtime.freeValue(object.elements.orderedRemove(@intCast(index)));
        },
        .map => |*map| {
            try requireMapKey(runtime, which);
            if (map.find(&which)) |at| {
                const removed = map.removeAt(at);
                // A key is a `long` or a String, storage only; a value can
                // hold a reference, so it is released, not just dropped.
                runtime.dropStorage(removed.key);
                runtime.freeValue(removed.value);
            }
        },
        .array, .builder, .file, .task => return runtime.fail(.not_owned),
    }
}

pub fn hasKey(runtime: *Runtime, target: Value, key: Value) Error!Value {
    const object = try runtime.resolve(target);
    return switch (object.data) {
        .map => |map| blk: {
            try requireMapKey(runtime, key);
            break :blk Value.ofBoolean(map.find(&key) != null);
        },
        .list, .array, .builder, .file, .task => runtime.fail(.not_owned),
    };
}

/// `m.key_at(i)` — maps keep insertion order, so iteration by index is
/// stable.
pub fn keyAt(runtime: *Runtime, target: Value, index: i64) Error!Value {
    const object = try runtime.resolve(target);
    const entries = switch (object.data) {
        .map => |map| map.entries.items,
        .list, .array, .builder, .file, .task => return runtime.fail(.not_owned),
    };
    if (index < 0 or index >= entries.len) return runtime.fail(.index_bounds);
    return entries[@intCast(index)].key;
}

pub fn valueAt(runtime: *Runtime, target: Value, index: i64) Error!Value {
    const object = try runtime.resolve(target);
    const entries = switch (object.data) {
        .map => |map| map.entries.items,
        .list, .array, .builder, .file, .task => return runtime.fail(.not_owned),
    };
    if (index < 0 or index >= entries.len) return runtime.fail(.index_bounds);
    return entries[@intCast(index)].value;
}

pub fn dimSize(runtime: *Runtime, target: Value, axis: i64) Error!Value {
    const object = try runtime.resolve(target);
    const dims = switch (object.data) {
        .array => object.dims,
        .list, .map, .builder, .file, .task => return runtime.fail(.not_owned),
    };
    if (axis < 0 or axis >= dims.len) return runtime.fail(.index_bounds);
    return Value.ofLong(dims[@intCast(axis)]);
}

/// `xs.sort()` and `xs.reverse()`, in place, on a list or an array.
///
/// Stable, and O(n log n): `std.sort.block` is an in-place merge sort
/// (Wikisort), so it needs no scratch allocation and cannot fail.
/// Stability is not decoration — sort admits double elements, and
/// `-0.0` and `0.0` compare equal while printing differently, so an
/// unstable order would be observable in a program's output.  It
/// replaces an insertion sort that was stable too, and quadratic.
pub fn sort(runtime: *Runtime, target: Value) Error!void {
    const object = try runtime.resolveMutable(target);
    switch (object.data) {
        // The cells are their own storage type, so the sort runs on
        // `f64`s or `i64`s directly; the ordering is still Luce's, read
        // through `Value` by the comparator.
        .list, .array => switch (object.elements.kind) {
            inline else => |kind| {
                const Cell = kind.Cell();
                std.sort.block(Cell, object.elements.cells(Cell), {}, cellBefore(kind).before);
            },
        },
        .map, .builder, .file, .task => return runtime.fail(.not_owned),
    }
}

pub fn reverse(runtime: *Runtime, target: Value) Error!void {
    const object = try runtime.resolveMutable(target);
    switch (object.data) {
        .list, .array => switch (object.elements.kind) {
            inline else => |kind| std.mem.reverse(
                kind.Cell(),
                object.elements.cells(kind.Cell()),
            ),
        },
        .map, .builder, .file, .task => return runtime.fail(.not_owned),
    }
}

/// `xs.find(v) -> long?` — the index of the first equal element, or
/// absence: the same rule `m.get` follows, so no caller ever compares
/// against a sentinel.
pub fn find(runtime: *Runtime, target: Value, wanted: Value) Error!Value {
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list, .array => {
            const stored = object.elements;
            for (0..stored.count) |at| {
                if (operators.compare(.equal, stored.at(at), wanted)) return Value.ofLong(@intCast(at));
            }
        },
        .map, .builder, .file, .task => return runtime.fail(.not_owned),
    }
    return Value.none;
}

/// Luce's ordering on one element kind's own cells.  `sort` is the
/// language's sort whatever an array stores, so the comparison goes
/// back through `Value` — which costs nothing: the wrapping folds
/// away once the kind is comptime.
fn cellBefore(comptime kind: heap.Object.ElementKind) type {
    return struct {
        fn before(_: void, left: kind.Cell(), right: kind.Cell()) bool {
            return operators.orderedBefore({}, lift(left), lift(right));
        }

        fn lift(cell: kind.Cell()) Value {
            return switch (kind) {
                .value => cell,
                .double => Value.ofDouble(cell),
                .long => Value.ofLong(cell),
                .float => Value.ofFloat(cell),
                .int => Value.ofInt(cell),
                .half => Value.ofHalf(cell),
                .short => Value.ofShort(cell),
                .byte => Value.ofByte(cell),
                .boolean => Value.ofBoolean(cell != 0),
            };
        }
    };
}

/// `xs.clear()` — drops every element's value storage; the elements'
/// objects, if any, leak until the final sweep.
pub fn clear(runtime: *Runtime, target: Value) Error!void {
    const object = try runtime.resolveMutable(target);
    switch (object.data) {
        .list => {
            if (object.elements.kind == .value) {
                for (object.elements.cells(Value)) |item| runtime.dropStorage(item);
            }
            object.elements.clear();
        },
        .map => |*map| {
            for (map.entries.items) |entry| {
                runtime.dropStorage(entry.key);
                runtime.dropStorage(entry.value);
            }
            map.clear();
        },
        .builder => |*builder| builder.clearRetainingCapacity(),
        .array, .file, .task => return runtime.fail(.not_owned),
    }
}

/// `m.keys()` — a fresh list of the keys.  Keys are long or String, so
/// there is no object to own; a String key's bytes belong to the map's
/// entry, so the list takes its own copy (docs/STRINGS.md).
///
/// `zero` is the key type's zero, here for the reason `newList` takes
/// one: it names the *kind* the elements are stored at (`emptyList`).
///
/// **That is also what gives an enum-keyed map its `list(Key)`.**  A key
/// is stored as the integer a `long` key would be (docs/ENUMS.md), and
/// the zero of an enum key names `.byte`/`.short`/`.int` cells — so
/// `put` narrows each key into its own width on the way in, which is the
/// exact inverse of the widening that stored it, and this function does
/// not learn that enums exist.
pub fn mapKeys(runtime: *Runtime, target: Value, zero: Value) Error!Value {
    const object = try runtime.resolve(target);
    const entries = switch (object.data) {
        .map => |map| map.entries.items,
        .list, .array, .builder, .file, .task => return runtime.fail(.not_owned),
    };
    var listed = emptyList(zero);
    errdefer dropBuilt(runtime, &listed);
    for (entries) |entry| {
        const key = try runtime.ownValue(entry.key);
        errdefer runtime.dropStorage(key);
        try listed.append(runtime.objects, key);
    }
    return runtime.attachList(listed);
}

/// A list under construction, storing its elements the way the
/// program's element type says — the zero's tag *is* that type
/// (`Object.ElementKind.of`).
///
/// **A `list(T)` is packed whoever built it** (docs/BYTES.md R1).  A
/// `.value` cell would hold a long or a String equally well and hand
/// back exactly what was put in it, so a boxed run is never *wrong*;
/// what it is is a different storage for the same type depending on
/// which code made the list.  Compiled code reads a list's cells
/// inline (docs/CODEGEN.md), and it can only do that if the kind is a
/// fact of the *type* rather than of the builder — so every
/// list-producing operation here takes the element zero and packs
/// exactly as `new list(T)` does, and the ones that can only ever
/// produce a `List(String)` say `.value` in full below, which is what
/// a String's zero would have said.
fn emptyList(zero: Value) heap.Object.Elements {
    return .{ .kind = .of(zero) };
}

/// The one element type that needs no parameter: a String, which is
/// stored boxed because its length is not a fact of the type.
const text_list: heap.Object.Elements = .{ .kind = .value };

/// Give back a half-built run and the value storage its elements own.
/// Any objects among those elements leak until the final sweep.
fn dropBuilt(runtime: *Runtime, listed: *heap.Object.Elements) void {
    if (listed.kind == .value) {
        for (listed.cells(Value)) |item| runtime.dropStorage(item);
    }
    listed.deinit(runtime.objects);
}

/// `dir_list(path)` — a fresh `List(String)` the caller owns, holding
/// its own copy of every name.  Each engine reaches this with the
/// shape its host handed over, and the list they build is the same.
pub fn listOfText(runtime: *Runtime, names: []const []const u8) Error!Value {
    var listed = text_list;
    errdefer dropBuilt(runtime, &listed);
    try listed.ensureCapacity(runtime.objects, names.len);
    for (names) |name| {
        const held = try runtime.ownValue(Value.ofString(name));
        errdefer runtime.dropStorage(held);
        try listed.append(runtime.objects, held);
    }
    return runtime.attachList(listed);
}

/// The same list, from the one shape the host ABI can carry: the names
/// NUL-separated in a single borrowed buffer.
///
/// A service answers bytes and a length, never a vector, so a compiled
/// program's host joins and this splits.  NUL is the separator because
/// it is the byte no file name may contain.  An empty buffer is an
/// empty directory, which is why the walk is written out rather than
/// handed to a general splitter that would answer one empty name.
pub fn listOfJoinedText(runtime: *Runtime, joined: []const u8) Error!Value {
    var listed = text_list;
    errdefer dropBuilt(runtime, &listed);
    var rest = joined;
    while (rest.len != 0) {
        const stop = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        const held = try runtime.ownValue(Value.ofString(rest[0..stop]));
        errdefer runtime.dropStorage(held);
        try listed.append(runtime.objects, held);
        rest = if (stop == rest.len) rest[stop..] else rest[stop + 1 ..];
    }
    return runtime.attachList(listed);
}

/// One program argument, borrowed for the length of the call — the
/// shape `08_llvm/abi.zig`'s `ArgFn` already has, named here so this
/// file needs nothing from the host ABI but the calling convention.
/// Answers `abi.Answer`: anything but zero means the out-parameters
/// were filled.
pub const ArgumentFn = *const fn (
    context: ?*anyopaque,
    index: i64,
    text: *[*c]const u8,
    length: *i64,
) callconv(.c) i32;

/// `main`'s `args`: the command line as the `List(String)` the entry
/// receives, owned by `main`'s scope (MEMORY.md).
///
/// A third spelling beside `listOfText` and `listOfJoinedText`, and for
/// the same reason they are two: the host hands its arguments over one
/// at a time and lends each one only for the moment of the call, so
/// each is copied into the run as it arrives rather than collected
/// first.  A host that offers neither service supplies an **empty**
/// list and not a trap — the entry cannot fail before `main` starts.
pub fn listOfArguments(
    runtime: *Runtime,
    count: i64,
    context: ?*anyopaque,
    get: ?ArgumentFn,
) Error!Value {
    if (count < 0) return runtime.fail(.host_unavailable);
    var listed = text_list;
    errdefer dropBuilt(runtime, &listed);
    if (get) |callback| {
        var index: i64 = 0;
        while (index < count) : (index += 1) {
            var text: [*c]const u8 = null;
            var size: i64 = 0;
            // A host that says no about an index it counted itself has
            // nothing left to say about the ones after it.
            const answer = callback(context, index, &text, &size);
            switch (answer) {
                0 => break,
                1 => {},
                -1 => {
                    runtime.exhausted = true;
                    return error.OutOfMemory;
                },
                else => return runtime.fail(.host_unavailable),
            }
            if (text == null) return runtime.fail(.host_unavailable);
            const text_length = std.math.cast(usize, size) orelse
                return runtime.fail(.host_unavailable);
            const borrowed = text[0..text_length];
            const held = try runtime.ownValue(Value.ofString(borrowed));
            errdefer runtime.dropStorage(held);
            try listed.append(runtime.objects, held);
        }
    }
    return runtime.attachList(listed);
}

/// `m.values()` — the returned list independently owns its elements, so
/// object values are deep-copied — two containers never own one object
/// (S23, mirrors listSlice).  `zero` is the value type's zero — see
/// `mapKeys`.
pub fn mapValues(runtime: *Runtime, target: Value, zero: Value) Error!Value {
    // The entries are read out before the loop: deepCopy allocates
    // objects, which moves the object table, and the map's own entry
    // buffer does not move with it.
    const object = try runtime.resolve(target);
    const entries = switch (object.data) {
        .map => |map| map.entries.items,
        .list, .array, .builder, .file, .task => return runtime.fail(.not_owned),
    };
    var listed = emptyList(zero);
    errdefer dropBuilt(runtime, &listed);
    for (entries) |entry| {
        const duplicate = try runtime.deepCopy(entry.value);
        errdefer runtime.dropStorage(duplicate);
        try listed.append(runtime.objects, duplicate);
    }
    return runtime.attachList(listed);
}

/// `m.get(key, fallback)` — a borrow of the stored value (like
/// m[key]), or the caller's default when the key is absent.
/// `m.get(k) -> V?` — the value, or absence.  Absence is the honest
/// answer for "not there" (docs/FAILURE.md), and `m.get(k) else d`
/// spells the old fallback form with the language's own machinery;
/// a plain `m[k]` keeps its `key_missing` trap, because indexing is
/// asking for something the program believes is present.
pub fn mapGet(runtime: *Runtime, target: Value, key: Value) Error!Value {
    const object = try runtime.resolve(target);
    return switch (object.data) {
        .map => |map| blk: {
            try requireMapKey(runtime, key);
            break :blk if (map.find(&key)) |at|
                map.entries.items[at].value
            else
                Value.none;
        },
        .list, .array, .builder, .file, .task => runtime.fail(.not_owned),
    };
}

/// `m[key] OP= v` — the place a compound store reads, brought into
/// existence at `zero` when the key is not there yet.
///
/// **This is the one read in the language that defines.**  A plain
/// `m[key]` traps `key_missing` and always will: asking a map for
/// something you never put in it is a bug in the program, not news
/// from the world.  A compound store is not asking.  It says in its
/// operator that it is writing, so the place it writes into is
/// defined first, at the value type's zero — and the divergence
/// between `m[k] += 1` and `m[k] = m[k] + 1` is deliberate, because
/// only one of the two spells a write on the left of the read
/// (docs/LANGUAGE.md, "Zero values").
///
/// **Maps only.**  A list or an array index that is out of range
/// still traps: an index is a position in something that already has
/// a shape, not a name that can be brought into being, and `append`
/// is the verb that grows a list.  The verifier refuses this
/// intrinsic on anything but a map, which is what makes the other
/// three arms below unreachable rather than merely unreached.
///
/// `key` and `zero` are both **borrows**: an entry that is already
/// there copies neither, and a fresh one copies both into storage it
/// owns and frees with itself.  What comes back is a borrow of the
/// value the map now holds, exactly as `indexGet` answers — the
/// `index_set` that follows frees it and stores the combination.
pub fn mapPlace(runtime: *Runtime, target: Value, key: Value, zero: Value) Error!Value {
    const object = try runtime.resolveMutable(target);
    switch (object.data) {
        .map => |*map| {
            try requireMapKey(runtime, key);
            if (map.find(&key)) |at| return map.entries.items[at].value;
            // `zero` becomes the map's value on this path, copied into
            // storage the map frees with itself at the final sweep.
            const owned_key = try runtime.ownValue(key);
            errdefer runtime.dropStorage(owned_key);
            const owned_zero = try runtime.ownValue(zero);
            errdefer runtime.dropStorage(owned_zero);
            try map.insert(runtime.objects, .{ .key = owned_key, .value = owned_zero });
            return owned_zero;
        },
        .list, .array, .builder, .file, .task => return runtime.fail(.not_owned),
    }
}

/// `a.fill(v)` — every cell replaced.  A cell owns its storage, so the
/// old contents go back and every new one is its own copy.
pub fn arrayFill(runtime: *Runtime, target: Value, held: Value) Error!void {
    if (!held.hasValidRepresentation()) return runtime.fail(.not_owned);
    const object = try runtime.resolveMutable(target);
    switch (object.data) {
        .array => {},
        .list, .map, .builder, .file, .task => return runtime.fail(.not_owned),
    }
    // Stage 4 refuses an object-carrying fill: one borrowed graph cannot
    // become the owner of every array slot.  Keep the same wall here for
    // verified MIR obtained some other way, before any old cell is
    // released.  This is double ownership, not specifically a cycle.
    if (carriesObject(held)) return runtime.fail(.not_owned);

    // A fill of a value with outside storage can fail once per cell.  Build
    // that replacement off to the side first: releasing the old cells and
    // then discovering an allocation failure would leave the destination
    // half-filled and would make a failed store observable as a mutation.
    if (object.elements.kind == .value and held.ownsStorage()) {
        const count = object.elements.count;
        if (count == 0) return;
        const byte_count = std.math.mul(usize, count, @sizeOf(Value)) catch
            return error.OutOfMemory;
        const bytes = try runtime.objects.alignedAlloc(u8, .of(Value), byte_count);
        var replacement: heap.Object.Elements = .{
            .kind = .value,
            .bytes = bytes,
            .count = count,
        };
        errdefer {
            for (replacement.cells(Value)) |cell| runtime.dropStorage(cell);
            replacement.deinit(runtime.objects);
        }
        try runtime.fillElements(replacement, held);

        const old = object.elements;
        object.elements.bytes = replacement.bytes;
        for (old.cells(Value)) |cell| runtime.dropStorage(cell);
        runtime.objects.free(old.bytes);
        return;
    }

    if (object.elements.kind == .value) {
        // The source language rejects object arrays at this method, but a
        // decoded or hand-built runtime value can still have object cells.
        // Replacing them drops their String/struct storage; the old
        // objects, if any, leak until the final sweep.
        for (object.elements.cells(Value)) |cell| runtime.dropStorage(cell);
    }
    try runtime.fillElements(object.elements, held);
}

fn carriesObject(held: Value) bool {
    return switch (held.tag) {
        .object => true,
        .strukt => blk: {
            const fields = held.asStruct();
            for (fields) |field| {
                if (carriesObject(field)) break :blk true;
            }
            break :blk false;
        },
        // A function value borrows the receiver it may carry and owns
        // none of it (docs/BINDING.md D4), so nothing inside one is an
        // object this value is answerable for.
        .function => false,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// The copy verb
// ---------------------------------------------------------------------------

/// `copy x`.  Verbs demand an object (S42): copying an unfilled or
/// freed slot traps.
pub fn copyVerb(runtime: *Runtime, held: Value) Error!Value {
    if (!held.hasValidRepresentation()) return runtime.fail(.not_owned);
    // Values copy as ordinary values; the explicit verb is reserved for a
    // resource-free object or carrying struct.  The analyzer normally
    // enforces this, but the C/MIR door must not silently accept a forged
    // scalar or function value.
    switch (held.tag) {
        .object => _ = try runtime.resolve(held),
        .strukt => {},
        else => return runtime.fail(.not_owned),
    }
    return runtime.deepCopy(held);
}
