//! List, Map, Array, and Builder — every container operation Luce has,
//! and the three ownership verbs (`free`, `give`, `copy`) that act on
//! whole objects.
//!
//! Each function here takes values rather than IR registers, so the
//! interpreter and compiled code reach the same body by the same path.
//! Where an operation is polymorphic in Luce (`a[i]` reads a list, a
//! map, or an array) it is polymorphic here too: the object's own kind
//! decides, exactly as it does in the language.

const std = @import("std");
const heap = @import("heap.zig");
const operators = @import("operators.zig");
const value = @import("value.zig");

const Error = heap.Error;
const OwnedBy = heap.OwnedBy;
const Runtime = heap.Runtime;
const Value = value.Value;

/// `len(x)`: bytes for a String, elements for a list, entries for a
/// map, the first axis for an array, bytes for a Builder.
pub fn length(runtime: *Runtime, target: Value) Error!Value {
    const measured: usize = switch (target.view()) {
        .string => |text| text.len,
        .object => blk: {
            const object = try runtime.resolve(target);
            break :blk switch (object.data) {
                .list => |list| list.items.len,
                .map => |map| map.entries.items.len,
                .array => if (object.array.dims.len == 0)
                    0
                else
                    @intCast(object.array.dims[0]),
                .builder => |builder| builder.items.len,
            };
        },
        else => unreachable,
    };
    return Value.ofInt(@intCast(measured));
}

/// `a[i]`, `m[key]`, `grid[r, c]`.  A list or array index out of range
/// traps; a missing map key traps `key_missing` (`m.get(k, default)` is
/// the total form).
pub fn indexGet(runtime: *Runtime, target: Value, indices: []const Value) Error!Value {
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => |list| {
            const index = indices[0].asInt();
            if (index < 0 or index >= list.items.len) return runtime.fail(.index_bounds);
            return list.items[@intCast(index)];
        },
        .map => |map| {
            const at = map.find(&indices[0]) orelse return runtime.fail(.key_missing);
            return map.entries.items[at].value;
        },
        .array => {
            const flat = heap.flattenIndex(object.array.dims, indices) orelse
                return runtime.fail(.index_bounds);
            return object.array.at(flat);
        },
        .builder => unreachable,
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
    errdefer runtime.dropStorage(stored);
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => |*list| {
            const index = indices[0].asInt();
            if (index < 0 or index >= list.items.len) return runtime.fail(.index_bounds);
            // An element overwrite frees the old owned element (S22).
            runtime.freeValue(list.items[@intCast(index)]);
            list.items[@intCast(index)] = stored;
        },
        .map => |*map| {
            const key = indices[0];
            if (map.find(&key)) |at| {
                runtime.freeValue(map.entries.items[at].value);
                map.entries.items[at].value = stored;
            } else {
                // A fresh entry owns its key too, and frees it with
                // itself.
                const owned_key = try runtime.ownValue(key);
                errdefer runtime.dropStorage(owned_key);
                try map.insert(runtime.objects, .{ .key = owned_key, .value = stored });
            }
        },
        .array => {
            const flat = heap.flattenIndex(object.array.dims, indices) orelse
                return runtime.fail(.index_bounds);
            // An element overwrite frees the old owned element (S22);
            // only a `Value` cell can be holding one.
            if (object.array.kind == .value) runtime.freeValue(object.array.at(flat));
            object.array.put(flat, stored);
        },
        .builder => unreachable,
    }
    runtime.adopt(stored);
}

/// `xs[a:b]` on a list.  Slices copy — including deep copies of object
/// elements, since two containers can never own one object (S23, S31).
pub fn listSlice(runtime: *Runtime, target: Value, start: i64, end: i64) Error!Value {
    const object = try runtime.resolve(target);
    const list = object.data.list;
    if (start < 0 or end < start or end > list.items.len) return runtime.fail(.index_bounds);
    var copied: std.ArrayList(Value) = .empty;
    errdefer copied.deinit(runtime.objects);
    for (list.items[@intCast(start)..@intCast(end)]) |element| {
        const duplicate = try runtime.deepCopy(element);
        try copied.append(runtime.objects, duplicate);
        runtime.adopt(duplicate);
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
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => |*list| {
            errdefer runtime.dropStorage(held);
            try list.append(runtime.objects, held);
            runtime.adopt(held);
        },
        .builder => |*builder| try builder.appendSlice(runtime.objects, held.asString()),
        else => unreachable,
    }
}

/// `b.append_ascii(code)`.  ASCII only: the builder's bytes become a
/// String, and String is valid UTF-8.  Anything wider goes through
/// chr(), which encodes the codepoint.
pub fn appendAscii(runtime: *Runtime, target: Value, code: i64) Error!void {
    const object = try runtime.resolve(target);
    if (code < 0 or code > 0x7F) return runtime.fail(.bad_codepoint);
    try object.data.builder.append(runtime.objects, @intCast(code));
}

/// `xs.pop()`.  pop hands the element out of the container (S22);
/// whatever receives it owns it next.
pub fn pop(runtime: *Runtime, target: Value) Error!Value {
    const object = try runtime.resolve(target);
    const list = &object.data.list;
    const taken = list.pop() orelse return runtime.fail(.empty_collection);
    runtime.loosen(taken);
    return taken;
}

/// `xs.insert(i, v)`.  **Consumes `held`** (docs/STRINGS.md), including
/// on the out-of-range trap: nothing the caller handed over is left
/// without an owner.
pub fn insert(runtime: *Runtime, target: Value, index: i64, held: Value) Error!void {
    errdefer runtime.dropStorage(held);
    const object = try runtime.resolve(target);
    if (index < 0 or index > object.data.list.items.len) return runtime.fail(.index_bounds);
    try object.data.list.insert(runtime.objects, @intCast(index), held);
    runtime.adopt(held);
}

/// `xs.remove(i)` or `m.remove(key)`.  Removing an owned element frees
/// it (S22); removing a key a map does not hold does nothing.
pub fn remove(runtime: *Runtime, target: Value, which: Value) Error!void {
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => |*list| {
            const index = which.asInt();
            if (index < 0 or index >= list.items.len) return runtime.fail(.index_bounds);
            runtime.freeValue(list.orderedRemove(@intCast(index)));
        },
        .map => |*map| {
            if (map.find(&which)) |at| {
                const removed = map.removeAt(at);
                runtime.dropStorage(removed.key);
                runtime.freeValue(removed.value);
            }
        },
        else => unreachable,
    }
}

pub fn hasKey(runtime: *Runtime, target: Value, key: Value) Error!Value {
    const object = try runtime.resolve(target);
    return Value.ofBoolean(object.data.map.find(&key) != null);
}

/// `m.key_at(i)` — maps keep insertion order, so iteration by index is
/// stable.
pub fn keyAt(runtime: *Runtime, target: Value, index: i64) Error!Value {
    const object = try runtime.resolve(target);
    const entries = object.data.map.entries.items;
    if (index < 0 or index >= entries.len) return runtime.fail(.index_bounds);
    return entries[@intCast(index)].key;
}

pub fn valueAt(runtime: *Runtime, target: Value, index: i64) Error!Value {
    const object = try runtime.resolve(target);
    const entries = object.data.map.entries.items;
    if (index < 0 or index >= entries.len) return runtime.fail(.index_bounds);
    return entries[@intCast(index)].value;
}

pub fn dimSize(runtime: *Runtime, target: Value, axis: i64) Error!Value {
    const object = try runtime.resolve(target);
    const dims = object.array.dims;
    if (axis < 0 or axis >= dims.len) return runtime.fail(.index_bounds);
    return Value.ofInt(dims[@intCast(axis)]);
}

/// `xs.sort()` and `xs.reverse()`, in place, on a list or an array.
///
/// Stable, and O(n log n): `std.sort.block` is an in-place merge sort
/// (Wikisort), so it needs no scratch allocation and cannot fail.
/// Stability is not decoration — sort admits Float elements, and
/// `-0.0` and `0.0` compare equal while printing differently, so an
/// unstable order would be observable in a program's output.  It
/// replaces an insertion sort that was stable too, and quadratic.
pub fn sort(runtime: *Runtime, target: Value) Error!void {
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => |*list| std.sort.block(Value, list.items, {}, operators.orderedBefore),
        // An array's cells are its own storage type, so the sort runs
        // on `f64`s or `i64`s directly; the ordering is still Luce's,
        // read through `Value` by the comparator.
        .array => switch (object.array.kind) {
            inline else => |kind| {
                const Cell = kind.Cell();
                std.sort.block(Cell, object.array.cells(Cell), {}, cellBefore(kind).before);
            },
        },
        else => unreachable,
    }
}

pub fn reverse(runtime: *Runtime, target: Value) Error!void {
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => |*list| std.mem.reverse(Value, list.items),
        .array => switch (object.array.kind) {
            inline else => |kind| std.mem.reverse(kind.Cell(), object.array.cells(kind.Cell())),
        },
        else => unreachable,
    }
}

/// `xs.find(v)` — the index of the first equal element, or -1.
pub fn find(runtime: *Runtime, target: Value, wanted: Value) Error!i64 {
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => |*list| for (list.items, 0..) |element, at| {
            if (operators.compare(.equal, element, wanted)) return @intCast(at);
        },
        .array => {
            const array = object.array;
            for (0..array.count) |at| {
                if (operators.compare(.equal, array.at(at), wanted)) return @intCast(at);
            }
        },
        else => unreachable,
    }
    return -1;
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
                .float => Value.ofFloat(cell),
                .int => Value.ofInt(cell),
                .boolean => Value.ofBoolean(cell != 0),
            };
        }
    };
}

/// `xs.clear()` — clear frees all owned elements (S22).
pub fn clear(runtime: *Runtime, target: Value) Error!void {
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => |*list| {
            for (list.items) |item| runtime.freeValue(item);
            list.clearRetainingCapacity();
        },
        .map => |*map| {
            for (map.entries.items) |entry| {
                runtime.dropStorage(entry.key);
                runtime.freeValue(entry.value);
            }
            map.clear();
        },
        .builder => |*builder| builder.clearRetainingCapacity(),
        .array => unreachable,
    }
}

/// `m.keys()` — a fresh list of the keys.  Keys are Int or String, so
/// there is no object to own; a String key's bytes belong to the map's
/// entry, so the list takes its own copy (docs/STRINGS.md).
pub fn mapKeys(runtime: *Runtime, target: Value) Error!Value {
    const entries = (try runtime.resolve(target)).data.map.entries.items;
    var listed: std.ArrayList(Value) = .empty;
    errdefer {
        for (listed.items) |item| runtime.dropStorage(item);
        listed.deinit(runtime.objects);
    }
    for (entries) |entry| {
        try listed.append(runtime.objects, try runtime.ownValue(entry.key));
    }
    return runtime.attachList(listed);
}

/// `dir_list(path)` — a fresh `List(String)` the caller owns, holding
/// its own copy of every name.  Each engine reaches this with the
/// shape its host handed over, and the list they build is the same.
pub fn listOfText(runtime: *Runtime, names: []const []const u8) Error!Value {
    var listed: std.ArrayList(Value) = .empty;
    errdefer {
        for (listed.items) |item| runtime.dropStorage(item);
        listed.deinit(runtime.objects);
    }
    try listed.ensureTotalCapacity(runtime.objects, names.len);
    for (names) |name| {
        try listed.append(runtime.objects, try runtime.ownValue(Value.ofString(name)));
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
    var listed: std.ArrayList(Value) = .empty;
    errdefer {
        for (listed.items) |item| runtime.dropStorage(item);
        listed.deinit(runtime.objects);
    }
    var rest = joined;
    while (rest.len != 0) {
        const stop = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        try listed.append(runtime.objects, try runtime.ownValue(Value.ofString(rest[0..stop])));
        rest = if (stop == rest.len) rest[stop..] else rest[stop + 1 ..];
    }
    return runtime.attachList(listed);
}

/// `m.values()` — the returned list independently owns its elements, so
/// object values are deep-copied — two containers never own one object
/// (S23, mirrors listSlice).
pub fn mapValues(runtime: *Runtime, target: Value) Error!Value {
    // The entries are read out before the loop: deepCopy allocates
    // objects, which moves the object table, and the map's own entry
    // buffer does not move with it.
    const entries = (try runtime.resolve(target)).data.map.entries.items;
    var listed: std.ArrayList(Value) = .empty;
    errdefer listed.deinit(runtime.objects);
    for (entries) |entry| {
        const duplicate = try runtime.deepCopy(entry.value);
        try listed.append(runtime.objects, duplicate);
        runtime.adopt(duplicate);
    }
    return runtime.attachList(listed);
}

/// `m.get(key, fallback)` — a borrow of the stored value (like
/// m[key]), or the caller's default when the key is absent.
pub fn mapGet(runtime: *Runtime, target: Value, key: Value, fallback: Value) Error!Value {
    const object = try runtime.resolve(target);
    if (object.data.map.find(&key)) |at| {
        return object.data.map.entries.items[at].value;
    }
    return fallback;
}

/// `a.fill(v)` — every cell replaced.  A cell owns its storage, so the
/// old contents go back and every new one is its own copy.
pub fn arrayFill(runtime: *Runtime, target: Value, held: Value) Error!void {
    const object = try runtime.resolve(target);
    if (object.array.kind == .value) {
        for (object.array.cells(Value)) |cell| runtime.dropStorage(cell);
    }
    try runtime.fillArray(object.array, held);
}

// ---------------------------------------------------------------------------
// The ownership verbs
// ---------------------------------------------------------------------------
//
// One operation, spelled three times on its way down: Luce writes
// `free`, MIR calls the instruction `free_object`, and here it is
// `freeVerb`.  The suffix is the disambiguator — `free` alone is the
// allocator's word and this is not it — and all three of `free`, `give`
// and `copy` carry it, so the family reads as one.

/// `free(x)`.  Only the named owner frees (S6, S23): `expected` carries
/// the binding to verify against when the verb named one.
pub fn freeVerb(runtime: *Runtime, held: Value, expected: ?OwnedBy) Error!void {
    _ = try runtime.resolve(held);
    try runtime.checkGivable(held, expected);
    runtime.freeObject(held.asObject());
}

/// `give x`.  The dynamic ownership check (S23): giving what a
/// container owns — or what the named binding no longer owns — would
/// forge a second owner.  Verbs demand an object, so an unfilled slot
/// traps (S42).
pub fn giveVerb(runtime: *Runtime, held: Value, expected: ?OwnedBy) Error!Value {
    switch (held.view()) {
        .object => {
            _ = try runtime.resolve(held);
            try runtime.checkGivable(held, expected);
        },
        .strukt => try runtime.checkGivable(held, expected),
        else => unreachable,
    }
    return held;
}

/// `copy x`.  Verbs demand an object (S42): copying an unfilled or
/// freed slot traps.
pub fn copyVerb(runtime: *Runtime, held: Value) Error!Value {
    if (held.tag == .object) {
        _ = try runtime.resolve(held);
    }
    return runtime.deepCopy(held);
}
