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

/// `len(x)`: bytes for a String or Bytes, elements for a list, entries
/// for a map, the first axis for an array, bytes for a Builder.
pub fn length(runtime: *Runtime, target: Value) Error!Value {
    const measured: usize = switch (target.view()) {
        .string => |text| text.len,
        .bytes => |text| text.len,
        .object => blk: {
            const object = try runtime.resolve(target);
            break :blk switch (object.data) {
                .list => |list| list.items.len,
                .map => |map| map.entries.items.len,
                .array => |array| if (array.dims.len == 0) 0 else @intCast(array.dims[0]),
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
            const at = map.find(indices[0]) orelse return runtime.fail(.key_missing);
            return map.entries.items[at].value;
        },
        .array => |array| {
            const flat = heap.flattenIndex(array.dims, indices) orelse
                return runtime.fail(.index_bounds);
            return array.elements[flat];
        },
        .builder => unreachable,
    }
}

/// `a[i] = v`, `m[key] = v`, `grid[r, c] = v`.
pub fn indexSet(runtime: *Runtime, target: Value, indices: []const Value, held: Value) Error!void {
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => |*list| {
            const index = indices[0].asInt();
            if (index < 0 or index >= list.items.len) return runtime.fail(.index_bounds);
            // An element overwrite frees the old owned element (S22).
            runtime.freeValue(list.items[@intCast(index)]);
            list.items[@intCast(index)] = held;
        },
        .map => |*map| {
            const key = indices[0];
            if (map.find(key)) |at| {
                runtime.freeValue(map.entries.items[at].value);
                map.entries.items[at].value = held;
            } else {
                try map.insert(runtime.objects, .{ .key = key, .value = held });
            }
        },
        .array => |array| {
            const flat = heap.flattenIndex(array.dims, indices) orelse
                return runtime.fail(.index_bounds);
            runtime.freeValue(array.elements[flat]);
            array.elements[flat] = held;
        },
        .builder => unreachable,
    }
    runtime.adopt(held);
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
pub fn append(runtime: *Runtime, target: Value, held: Value) Error!void {
    const object = try runtime.resolve(target);
    switch (object.data) {
        .list => |*list| {
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

pub fn insert(runtime: *Runtime, target: Value, index: i64, held: Value) Error!void {
    const object = try runtime.resolve(target);
    const list = &object.data.list;
    if (index < 0 or index > list.items.len) return runtime.fail(.index_bounds);
    try list.insert(runtime.objects, @intCast(index), held);
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
            if (map.find(which)) |at| runtime.freeValue(map.removeAt(at).value);
        },
        else => unreachable,
    }
}

pub fn hasKey(runtime: *Runtime, target: Value, key: Value) Error!Value {
    const object = try runtime.resolve(target);
    return Value.ofBoolean(object.data.map.find(key) != null);
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
    const array = object.data.array;
    if (axis < 0 or axis >= array.dims.len) return runtime.fail(.index_bounds);
    return Value.ofInt(array.dims[@intCast(axis)]);
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
    std.sort.block(Value, try elementsOf(runtime, target), {}, operators.orderedBefore);
}

pub fn reverse(runtime: *Runtime, target: Value) Error!void {
    std.mem.reverse(Value, try elementsOf(runtime, target));
}

/// `xs.find(v)` — the index of the first equal element, or -1.
pub fn find(runtime: *Runtime, target: Value, wanted: Value) Error!i64 {
    for (try elementsOf(runtime, target), 0..) |element, at| {
        if (operators.compare(.equal, element, wanted)) return @intCast(at);
    }
    return -1;
}

/// The mutable elements of a list or an array; the two sequence
/// algorithms treat them alike.
fn elementsOf(runtime: *Runtime, target: Value) Error![]Value {
    const object = try runtime.resolve(target);
    return switch (object.data) {
        .list => |*list| list.items,
        .array => |array| array.elements,
        else => unreachable,
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
            for (map.entries.items) |entry| runtime.freeValue(entry.value);
            map.clear();
        },
        .builder => |*builder| builder.clearRetainingCapacity(),
        .array => unreachable,
    }
}

/// `m.keys()` — a fresh list of the keys.  Keys are Int or String, so
/// there is nothing to own and nothing to copy.
pub fn mapKeys(runtime: *Runtime, target: Value) Error!Value {
    const entries = (try runtime.resolve(target)).data.map.entries.items;
    var listed: std.ArrayList(Value) = .empty;
    errdefer listed.deinit(runtime.objects);
    for (entries) |entry| {
        try listed.append(runtime.objects, entry.key);
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
    if (object.data.map.find(key)) |at| {
        return object.data.map.entries.items[at].value;
    }
    return fallback;
}

pub fn arrayFill(runtime: *Runtime, target: Value, held: Value) Error!void {
    const object = try runtime.resolve(target);
    @memset(object.data.array.elements, held);
}

// ---------------------------------------------------------------------------
// The ownership verbs
// ---------------------------------------------------------------------------

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
