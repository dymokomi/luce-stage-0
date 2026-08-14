# Collections

Collections answer different questions. Decide what the data means before
choosing an API:

| Use | Luce type | Shape |
| --- | --- | --- |
| ordered values that grow or shrink | `list(T)` | a sequence of elements |
| values addressed by a runtime key | `map(K, V)` | an insertion-ordered dictionary |
| a fixed-shape numeric or tabular block | `array(T, ...)` | one to four dimensions |

All three are owned objects. A binding that receives a fresh collection owns
it; assigning a named collection aliases it; `copy` makes an explicit deep
copy for resource-free graphs. See [memory](/guide/memory/) before putting
collections in structs or other collections.

## Choose by the operation

Use a list when position and order matter. `append`, `insert`, `remove`,
`pop`, `sort`, `reverse`, `find`, and `contains` are list operations. A list
literal such as `[2, 4, 8]` infers its element type; an empty literal needs an
annotation or an explicit `new list(T)`.

Use a map when the key is the thing you know. Keys are `long` or `string`.
Iteration follows insertion order. `has` and `get(key, fallback)` represent a
missing key as ordinary absence; indexing a missing key is a trap. A compound
store such as `counts[word] += 1` creates a missing value at the value type's
zero because the left side has declared a write.

Use an array when shape is part of the algorithm. `new array(double, rows,
columns)` fixes the dimensions at runtime; `array(double, _, _)` names the
rank in a parameter. `dim(axis)` reports a dimension, and rank-one arrays
share the basic search, sorting and fill operations. Up to four dimensions are
available.

## Iteration is uniform

`for value in collection` visits values. `for index, value in collection`
visits a zero-based index or key together with the value. A loop borrows the
collection while it runs: do not resize or free that collection during the
iteration. If a loop needs a different shape, make a new collection before
the loop or after it.

## Read the focused chapters

- [Lists](/guide/lists/) — mutation, stable comparator sorting, slices and
  nested ownership.
- [Maps](/guide/maps/) — insertion order, safe lookup, counting and map
  values/keys.
- [Arrays and grids](/guide/arrays/) — dimensions, zero values and numeric
  reductions.
- [std.lists](/library/lists/) — stable comparator sorting for list values.
- [std.math](/library/math/) — whole-array numeric operations.

The [Reference](/reference/types/) gives the exact type and ownership rules;
the [Library](/library/) gives the APIs that operate on these values.
