//! IR type, enum, and struct definitions.
//! All data types for the Luce intermediate representation.

const std = @import("std");
const types = @import("../support/types.zig");
const value = @import("../runtime/value.zig");
const vocabulary = @import("../support/vocabulary.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;
const StructLayout = types.StructLayout;

pub const Register = u32;

/// Which `runtime.Tag` a value of `of` wears once it is boxed, or null
/// for the one type that cannot say: a `T?` boxes as its payload's tag
/// when it is there and as `none` when it is not, so what it wears is
/// decided by the value and never by the type.
///
/// Here rather than in either engine because **both** need it and they
/// must not answer differently — a program's types and the runtime's
/// tags are two halves of one wire surface, which is the same reason
/// `TrapCode` is named in this file.
pub fn boxTag(of: Type) ?value.Tag {
    return switch (of) {
        .none => .none,
        .boolean => .boolean,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .f16 => .f16,
        .f32 => .f32,
        .f64 => .f64,
        .char => .char,
        .str => .str,
        .bytes => .bytes,
        .strukt => .strukt,
        // A union value is a struct value whose field 0 is the tag
        // (docs/UNION.md D8): to the runtime it is a field run, so it
        // boxes as one and the runtime never learns unions exist.
        .variant => .strukt,
        .heap => .object,
        // An enum boxes as the integer it is (docs/ENUMS.md D10): the
        // runtime is handed a value and never a program's type table,
        // and what it has to know about one is its width.
        .enumeration => |reference| boxTag(reference.backing.asType()),
        // A function value is a two-slot field run — the function it
        // names and the receiver it carries (docs/BINDING.md D12) — and
        // it wears a **tag of its own**, not `strukt`.  The shape is a
        // struct's; the ownership is not.  A function value owns the run
        // and never the objects inside it (D4), so every ownership walk
        // in `libluce_rt` has to stop at one instead of descending — and
        // a walk cannot tell a borrowed run from an owning one by
        // looking.  That is the one semantic the runtime learns here,
        // and the tag is how it is told.
        .function => .function,
        .optional => null,
    };
}
/// How a **map key** is stored. Integers keep their exact explicit width;
/// an enum uses its exact backing width; `str` answers itself. Both engines
/// call this seam, so a key cannot be boxed under one tag and searched under
/// another.
pub fn mapKeyStorage(key: Type) Type {
    return key.storage();
}

/// A function value's field run: how long it is, and which slot holds
/// what (docs/BINDING.md D12).
///
/// Here beside `boxTag` and for its reason — **both engines build one
/// and both engines read one**, and a disagreement about which slot is
/// which would not show up as a shape error anywhere, only as a program
/// calling the wrong thing.  The run is the same two slots whether the
/// value carries a receiver or not, so nothing downstream branches on
/// boundness to find its way around one.
pub const function_run_length: usize = 2;
pub const function_run_named: usize = 0;
pub const function_run_receiver: usize = 1;

/// An interface existential's field run. Slot zero is a one-based index
/// into `Program.interface_witnesses` (zero is the uninitialized sentinel);
/// slot one is the sole owned concrete payload.
pub const interface_run_length: usize = 2;
pub const interface_run_witness: usize = 0;
pub const interface_run_payload: usize = 1;

pub const BlockId = u32;
pub const LocalId = u32;

pub const BinaryOp = vocabulary.BinaryOp;

pub const UnaryOp = enum {
    negate,
    logic_not,
    /// `~x` — two's complement, so it is `-x - 1` (docs/BITWISE.md D3).
    bit_not,
};

pub const Intrinsic = enum {
    abs,
    min,
    max,
    clamp,
    sqrt,
    floor,
    ceil,
    /// `trunc(x)` — toward zero, alongside `floor`, `ceil`, and
    /// `math.round` (docs/NUMERICS.md §7).
    trunc,
    len,
    string_slice,
    string_byte,
    string_find_byte,
    assert_true,
    trap_message,
    null_object,
    /// The four an optional needs, and no instruction (docs/FAILURE.md).
    /// `none_value` materializes the absent value of its result type;
    /// `is_none` asks; `optional_wrap` is the `T <: T?` widening;
    /// `optional_unwrap` is what narrowing licensed — the analyzer has
    /// already proved the value is there, so it never checks.
    none_value,
    is_none,
    optional_wrap,
    optional_unwrap,
    /// The three an error needs beyond its terminators
    /// (docs/FAILURE.md).  `errored` asks whether the fallible call or
    /// intrinsic naming its one argument came back errored rather than
    /// returning; it is the only instruction that may read that
    /// register's outcome, and it must stand in the same block as what
    /// it asks about.  `error_message` reads the words out of the
    /// channel — what `catch NAME:` binds — and answers a borrow of
    /// run-lifetime storage, so a place that keeps them takes a copy in
    /// the ordinary way.  `forget` discards the pending error and its
    /// words — what `catch` does, and the reason a caught error leaks
    /// nothing; it stands *after* any `error_message` reading the same
    /// error, and after the copy that reading takes, so nothing has to
    /// know how long a forgotten error's words stay readable.
    errored,
    error_message,
    forget,
    /// `error("…")` — record `user_error` and the program's own words
    /// in the channel.  Not a terminator: the `unwind` that follows it
    /// comes *after* the releases this frame owes, and the words are
    /// copied into run-lifetime storage here, before any of them run
    /// (docs/FAILURE.md).  The same shape as `trap_message`, for the
    /// same reason.
    raise_error,
    index_get,
    index_set,
    list_slice,
    append_value,
    append_ascii,
    pop_value,
    insert_value,
    remove_entry,
    has_key,
    key_at,
    value_at,
    dim_size,
    copy_object,
    list_sort,
    list_reverse,
    list_find,
    list_contains,
    clear_object,
    map_keys,
    map_values,
    map_get,
    /// `m[k] OP= v` reads its place through this rather than
    /// `index_get`: a missing key is **defined** at the zero given as
    /// the third operand instead of trapping, because the operator on
    /// the left says this read is half of a write.  Maps only — a list
    /// or array compound assignment still reads through `index_get`
    /// and still traps out of range.
    map_place,
    array_fill,
    str_value,
    /// `str(f)` — the **name** of the function a function value
    /// names (docs/FUNCTIONS.md D3).  An intrinsic of its own rather
    /// than a case inside `str_value`, because it is a different act:
    /// `str_value` renders a number and this reads a name out of the
    /// program's own function table, which is a table only an engine
    /// holds.  Nothing about it reaches `libluce_rt`.
    function_name,
    parse_i64,
    parse_f64,
    /// `parse_str(data)` — immutable bytes as text, or absent when the
    /// bytes are not valid UTF-8.  The parse
    /// family's third member, named for what it produces exactly as
    /// its two siblings are: "not text" is the same reason every time,
    /// so absence carries all the information there is.  It is also
    /// the one door into a `str` that did not come from a literal
    /// or another string, which is why the validator behind it is
    /// `libluce_rt`'s and not a host's.
    parse_str,
    print,
    file_read,
    file_write,
    term_rows,
    term_cols,
    term_clear,
    term_move,
    term_style,
    term_write,
    term_flush,
    key_read,
    key_text,
    /// One line from standard input, with the prompt the host writes
    /// and flushes before it blocks — the same discipline `key_read`
    /// follows, and the reason a prompt is an argument rather than a
    /// print of its own.  Answers `str?`: end of input is "there is
    /// nothing there", with no reason worth carrying (docs/FAILURE.md).
    read_line,
    /// A line to standard error.  A second console, not a second
    /// `print`: stdout is the program's data and stderr is where a
    /// program says something to a person while its output is a pipe.
    print_error,
    /// Milliseconds on a monotonic clock whose origin is unspecified,
    /// so only differences mean anything, and `sleep_ms`, which waits
    /// at least that long.  Neither can fail; a host without them is
    /// `host_unavailable` like every other withheld service.
    clock_ms,
    sleep_ms,
    /// `epoch_ms()` — milliseconds since the Unix epoch, which is a
    /// different question from `clock_ms`'s and deliberately next to
    /// it.
    ///
    /// **Named for what it counts from, not for what it measures.**
    /// `clock_ms` is monotonic with an unspecified origin, so only
    /// differences mean anything; this one has a fixed origin and its
    /// *reading* is the answer.  A name like `time_ms` or `now_ms`
    /// would leave the pair distinguished only by which of the two a
    /// reader happened to learn first, and mistaking them is the
    /// classic bug in both directions — timing a span with a clock an
    /// operator can set backwards, or stamping a record with a number
    /// that means nothing off this machine.  `epoch_ms` cannot be
    /// read as elapsed time by anybody.
    ///
    /// A host that cannot tell the time refuses with
    /// `host_unavailable` rather than inventing a number, which is why
    /// its slot answers through the `Answer` convention the way the
    /// machine facts do and not as a bare number the way `clock_ms`
    /// does.  A calendar is still a library nobody has written
    /// (docs/MISSING.md): this answers the one number a calendar would
    /// be built on.
    epoch_ms,
    /// One environment variable, or absent when it is unset.  Absence
    /// again, for the same reason `read_line`'s is: "not set" is the
    /// same fact every time and carries no news.
    env_get,
    /// The four file services the world can say no to, beside
    /// `file_read` and `file_write` and fallible on the same grounds:
    /// no non-racy check stands in for the result (docs/FAILURE.md).
    file_append,
    file_delete,
    file_rename,
    dir_list,
    /// `dir_create(path)` — make a directory, and everything that
    /// leads to it.
    ///
    /// **It makes the parents** (`mkdir -p`), and **a directory that
    /// is already there is success.**  Both are one decision: the call
    /// says "there is a directory at this path when I am done", which
    /// is what every caller of it actually wants — a package store
    /// laying out `.luce/packages/NAME-VERSION/`, an extractor writing
    /// under a `papers/` nobody made yet.  The alternative — one
    /// component per call, an existing directory refused — puts the
    /// same loop in every program and a `file_exists` in front of
    /// every call, and that guard is a race, which is the same reason
    /// `file_exists` is not a guard for `file_read` (docs/FAILURE.md).
    /// A file standing in the way is still a failure: the caller asked
    /// for a directory and there is not one.
    ///
    /// Fallible on the same grounds as the four file services above:
    /// the world decides, and no non-racy check stands in for the
    /// result.
    dir_create,
    /// `path_kind(path)` — what is at this path, as a number: 0
    /// nothing, 1 a file, 2 a directory, 3 something else
    /// (docs/FILESYSTEM.md D11).
    ///
    /// **The primitive `file_exists` was not.**  A bool answered
    /// `false` for a name nothing holds *and* for a file under a
    /// directory nobody may open, which are two different facts with
    /// one bit between them — and it could not say "that is a
    /// directory" at all, so a program could only find out by trying
    /// to read one and reading the failure.  This asks the question
    /// once and the three answers the language has are exactly the
    /// three things that can happen: a number for what is there,
    /// zero for nothing there, and the error channel for a world that
    /// would not say (docs/FAILURE.md).
    ///
    /// A number and not an enum, because the runtime deliberately
    /// does not know the program's type table: `std.files` is where
    /// the four codes get their names, exactly as the byte channel's
    /// mode is a number here and a named door there.
    ///
    /// Fallible on the same grounds as every other file service: the
    /// world decides, and no non-racy check stands in for the result.
    path_kind,
    /// The backend-neutral native window/GPU channel.  The runtime owns
    /// opaque handles and scope-close; these names are the only language
    /// instructions that cross that seam.
    gpu_backend,
    ui_window_open,
    ui_window_surface,
    gpu_surface_size,
    gpu_surface_clear,
    gpu_surface_fill_rect,
    gpu_surface_present,
    /// The byte channel: a file reached through an open handle
    /// (docs/BYTES.md R4, R5).  `file_open` answers a `file` the
    /// caller's scope owns and whose end closes it — there is no
    /// `close` intrinsic, because `free f` is the close and
    /// MEMORY.md already said what it means.  `handle_read` fills
    /// an `array[u8, n]` and answers how many bytes landed, zero
    /// being the end of the file; `handle_write` writes the first
    /// `count` bytes of one and answers how many landed;
    /// `handle_flush` puts what was written on the device.  All four
    /// are fallible on the same grounds as every other file service:
    /// the world decides, and no non-racy check stands in for the
    /// result.
    file_open,
    handle_read,
    handle_write,
    handle_flush,
    /// `t.wait()` — join the worker this task owns and move its result
    /// here (docs/THREADS.md D4).  One argument, the task; the result
    /// is whatever the spawned function answers, and `.none` when it
    /// answers nothing.  Consuming: a second wait is refused in stage 4
    /// the way a second `give` is, and traps `use_after_free` for IR
    /// that arrived some other way.
    ///
    /// It is **conditionally fallible**, which no other intrinsic is:
    /// what crosses the join is whatever the worker did, so a task
    /// carrying a `-> T!` function answers `T!` here and one carrying
    /// a `-> T` cannot come back errored at all.  `isFallible` says
    /// yes because it *may*; the precise answer is the task's own heap
    /// type, which stage 4 reads to decide whether the site must say
    /// `try`, and `mir/verify.zig` reads to decide whether an
    /// `errored` may name it.
    task_wait,
    /// `exit(status)` — the program chooses to stop, carrying a
    /// status the host maps onto whatever its world calls one.  A
    /// fourth way a run ends (docs/LANGUAGE.md): not a trap (nothing
    /// is wrong), not an error (nothing failed), and the unwind rides
    /// the trap edge exactly as exhaustion does — every frame returns,
    /// nothing is reported, and `luce_rt_status` answers `exited`.
    /// Host-gated and fail-closed like every effect: a host with no
    /// `exited` slot traps `host_unavailable` at the call.
    exit_program,
    /// The machine's own facts, behind `std.os`: bytes of physical
    /// memory, bytes of it still available to ask for, and how many
    /// processors there are.  Each answers a `i64` and none can be
    /// folded — `os_available_memory` moves under the program's feet,
    /// which is the whole reason to ask it — and the host answering
    /// "I cannot tell" is `host_unavailable`, the same refusal a
    /// withheld service gives.
    os_total_memory,
    os_available_memory,
    os_cpu_count,
    /// `shell_run(command)` — run one host-shell command, capture its
    /// output, and hand the text back to the caller. The standard
    /// library presents this as `std.os.shell.run`; the raw builtin is
    /// reserved so the host boundary stays in one place.
    shell_run,
    /// The two halves of value storage (docs/STRINGS.md).  A string's
    /// bytes and a struct's field run have exactly one owner, so
    /// `own_storage` takes the copy every store into a place that
    /// outlives the statement needs, and `drop_storage` is the death
    /// point — it answers the emptied value, which the caller writes
    /// back, so releasing a place twice frees nothing the second time.
    /// Neither touches objects: an object's lifetime is the runtime's,
    /// not a store's.
    own_storage,
    drop_storage,
    /// The third: what `ret` does to a value on its way out of the
    /// frame that made it.  Short text lives in the value, and on the
    /// compiled path a value lives in a frame slot — so text that fits
    /// inline is copied into storage the caller owns, and everything
    /// already independent of the frame moves untouched.
    export_storage,
    /// Numeric data belonging to the most recent `key_read`: row,
    /// column, button, modifier bits, or wheel value by field number.
    /// The standard library presents this host query as `term.io`'s
    /// mouse and resize accessors.
    term_event_data,
    /// The object half of a value's lifetime, which value storage's three
    /// intrinsics deliberately never touch (docs/MEMORY.md).  `retain`
    /// raises the reference count of every object a value names — a new
    /// binding, cell, or field now holds it — and `release` lowers it,
    /// reclaiming the object the moment its last reference goes.  A
    /// reference is shared, so a store retains what it keeps and a scope's
    /// end releases what it held; both are no-ops on a value that names no
    /// object and on a program constant.  Neither answers a value.
    /// Appended so the intrinsic tags before them do not renumber.
    retain,
    release,
    /// `bytes(value)` — a fresh immutable byte run copied from valid
    /// text, `list[u8]`, or a rank-one `array[u8, _]`.  Appended so
    /// every earlier intrinsic keeps its wire number.
    bytes_value,

    // -- per-intrinsic facts, classified once ---------------------------
    //
    // Each of the three below was written twice or guarded by an
    // `else`, which is the same defect wearing two hats: adding an
    // intrinsic and forgetting to classify it was silent.  They live
    // on the enum, they name every tag, and they have no `else` — so
    // a new tag is a compile error here until somebody decides what it
    // is.  `optimize/effects.zig`'s `intrinsicEffect` is the model.

    /// Does this intrinsic call a host service **directly**?
    ///
    /// The one question the effect lock turns on (docs/THREADS.md D9):
    /// host services are called from one thread at a time, so an
    /// engine brackets exactly these with `Runtime.enterEffects` and
    /// `leaveEffects`.  The compiled path brackets at `callHost`,
    /// which is the same set said in the backend's own vocabulary —
    /// `codegen/lower.zig`'s test holds the two together.
    ///
    /// **The file services are deliberately `false`.**  Whole-file
    /// operations and the byte channel reach a host through
    /// `libluce_rt`, which takes the lock at each callback
    /// (`runtime/files.zig`) — the one place both engines pass through,
    /// and where a handle's close also happens with no engine standing.
    /// Saying `true` here as well would only take a recursive lock
    /// twice, and would give the oracle a wider Effects scope than the
    /// compiled path.
    pub fn reachesHost(self: Intrinsic) bool {
        return switch (self) {
            .print,
            .print_error,
            .read_line,
            .env_get,
            .clock_ms,
            .sleep_ms,
            .file_delete,
            .file_rename,
            .dir_list,
            .dir_create,
            .path_kind,
            .epoch_ms,
            .term_rows,
            .term_cols,
            .term_clear,
            .term_move,
            .term_style,
            .term_write,
            .term_flush,
            .key_read,
            .exit_program,
            .os_total_memory,
            .os_available_memory,
            .os_cpu_count,
            .shell_run,
            .term_event_data,
            => true,

            // `key_text` reads the slot the last `key_read` filled,
            // which is the run's own state and not the host's.
            .key_text,
            // The file runtime locks each host callback (see above).
            .file_read,
            .file_write,
            .file_append,
            .file_open,
            .handle_read,
            .handle_write,
            .handle_flush,
            // The graphics callbacks are reached through the runtime
            // channel, which takes its own effect lock around each host
            // operation just like files.
            .gpu_backend,
            .ui_window_open,
            .ui_window_surface,
            .gpu_surface_size,
            .gpu_surface_clear,
            .gpu_surface_fill_rect,
            .gpu_surface_present,
            // A wait joins a thread; it must **not** hold the lock
            // while it does, or a worker that prints could never
            // finish (docs/THREADS.md D9).
            .task_wait,
            .abs,
            .min,
            .max,
            .clamp,
            .sqrt,
            .floor,
            .ceil,
            .trunc,
            .len,
            .string_slice,
            .string_byte,
            .string_find_byte,
            .assert_true,
            .trap_message,
            .null_object,
            .none_value,
            .is_none,
            .optional_wrap,
            .optional_unwrap,
            .errored,
            .error_message,
            .forget,
            .raise_error,
            .index_get,
            .index_set,
            .list_slice,
            .append_value,
            .append_ascii,
            .pop_value,
            .insert_value,
            .remove_entry,
            .has_key,
            .key_at,
            .value_at,
            .dim_size,
            .copy_object,
            .list_sort,
            .list_reverse,
            .list_find,
            .list_contains,
            .clear_object,
            .map_keys,
            .map_values,
            .map_get,
            .map_place,
            .array_fill,
            .str_value,
            .function_name,
            .parse_i64,
            .parse_f64,
            .parse_str,
            .own_storage,
            .drop_storage,
            .export_storage,
            .retain,
            .release,
            .bytes_value,
            => false,
        };
    }

    /// Can this intrinsic come back **errored** rather than answering?
    ///
    /// Stage 4 asks so a call site is made to say which of `try` and
    /// `catch` it means; `mir/verify.zig` asks so an `errored` may
    /// name only an instruction that really has an outcome.  The two
    /// used to keep separate lists, and a program where they disagreed
    /// is one that could branch on a word nobody wrote.
    pub fn isFallible(self: Intrinsic) bool {
        return switch (self) {
            // The six file services the world can say no to, with no
            // non-racy check that stands in for the result
            // (docs/FAILURE.md).
            .file_read,
            .file_write,
            .file_append,
            .file_delete,
            .file_rename,
            .dir_list,
            // Making a directory is the same kind of ask: the world
            // may refuse it, and a check in front of the call is a
            // race rather than a guard.
            .dir_create,
            .path_kind,
            // The byte channel, on the same grounds.
            .file_open,
            .handle_read,
            .handle_write,
            .handle_flush,
            .ui_window_open,
            .ui_window_surface,
            .gpu_surface_size,
            .gpu_surface_clear,
            .gpu_surface_fill_rect,
            .gpu_surface_present,
            // Conditionally: the worker's own fallibility crosses the
            // join, and the task's heap type is what records it
            // (docs/THREADS.md D4).  Yes here means "may", which is
            // what both readers of this table need it to mean.
            .task_wait,
            .shell_run,
            => true,

            .abs,
            .min,
            .max,
            .clamp,
            .sqrt,
            .floor,
            .ceil,
            .trunc,
            .len,
            .string_slice,
            .string_byte,
            .string_find_byte,
            .assert_true,
            .trap_message,
            .null_object,
            .none_value,
            .is_none,
            .optional_wrap,
            .optional_unwrap,
            .errored,
            .error_message,
            .forget,
            .raise_error,
            .index_get,
            .index_set,
            .list_slice,
            .append_value,
            .append_ascii,
            .pop_value,
            .insert_value,
            .remove_entry,
            .has_key,
            .key_at,
            .value_at,
            .dim_size,
            .copy_object,
            .list_sort,
            .list_reverse,
            .list_find,
            .list_contains,
            .clear_object,
            .map_keys,
            .map_values,
            .map_get,
            .map_place,
            .array_fill,
            .str_value,
            .function_name,
            .parse_i64,
            .parse_f64,
            .parse_str,
            .print,
            .term_rows,
            .term_cols,
            .term_clear,
            .term_move,
            .term_style,
            .term_write,
            .term_flush,
            .key_read,
            .key_text,
            .read_line,
            .print_error,
            .clock_ms,
            .epoch_ms,
            .sleep_ms,
            .env_get,
            .exit_program,
            .os_total_memory,
            .os_available_memory,
            .os_cpu_count,
            .gpu_backend,
            .term_event_data,
            .own_storage,
            .drop_storage,
            .export_storage,
            .retain,
            .release,
            .bytes_value,
            => false,
        };
    }

    /// Does this intrinsic answer text (or a field run) that **nobody
    /// else owns** — storage the receiving register is responsible for
    /// — rather than a view into something that already has an owner?
    ///
    /// Stage 4's ownership walk asks, to decide whether a value needs
    /// releasing where it dies (docs/STRINGS.md).
    pub fn makesFreshStorage(self: Intrinsic) bool {
        return switch (self) {
            // `str` allocates, as do the host services that
            // answer text; `pop` takes the element's storage out of its
            // container, which leaves it owned by nobody; `copy`
            // duplicates; `own_storage` is the taking of a copy itself.
            .str_value,
            .parse_str,
            .file_read,
            .key_read,
            .read_line,
            .env_get,
            .shell_run,
            .pop_value,
            .copy_object,
            .own_storage,
            .bytes_value,
            // A worker's result is re-owned into *this* runtime as it
            // crosses the join, so a string that comes back is storage
            // nobody else owns (docs/THREADS.md).
            .task_wait,
            => true,

            // Everything else that answers text answers a *view*: a
            // slice, an element, a field, a map key, the key-text slot,
            // a constant, a parameter.  The rest answer no text at all.
            .abs,
            .min,
            .max,
            .clamp,
            .sqrt,
            .floor,
            .ceil,
            .trunc,
            .len,
            // The name of a function is a constant of the program's
            // own, not bytes anybody has to give back
            // (docs/FUNCTIONS.md D3).
            .function_name,
            .string_slice,
            .string_byte,
            .string_find_byte,
            .assert_true,
            .trap_message,
            .null_object,
            .none_value,
            .is_none,
            .optional_wrap,
            .optional_unwrap,
            .errored,
            .error_message,
            .forget,
            .raise_error,
            .index_get,
            .index_set,
            .list_slice,
            .append_value,
            .append_ascii,
            .insert_value,
            .remove_entry,
            .has_key,
            .key_at,
            .value_at,
            .dim_size,
            .list_sort,
            .list_reverse,
            .list_find,
            .list_contains,
            .clear_object,
            .map_keys,
            .map_values,
            .map_get,
            .map_place,
            .array_fill,
            .parse_i64,
            .parse_f64,
            .print,
            .file_write,
            .file_append,
            .file_delete,
            .file_rename,
            .dir_list,
            .dir_create,
            .path_kind,
            .gpu_backend,
            .ui_window_open,
            .ui_window_surface,
            .gpu_surface_size,
            .gpu_surface_clear,
            .gpu_surface_fill_rect,
            .gpu_surface_present,
            .term_rows,
            .term_cols,
            .term_clear,
            .term_move,
            .term_style,
            .term_write,
            .term_flush,
            .term_event_data,
            .key_text,
            .print_error,
            .clock_ms,
            .epoch_ms,
            .sleep_ms,
            .exit_program,
            .os_total_memory,
            .os_available_memory,
            .file_open,
            .handle_read,
            .handle_write,
            .handle_flush,
            .os_cpu_count,
            .drop_storage,
            .export_storage,
            .retain,
            .release,
            => false,
        };
    }

    /// Which argument is a **store into the receiver** — the one
    /// `libluce_rt` keeps rather than reads — or null when none is.
    ///
    /// Stage 4 asks so a literal in that position lands at the
    /// container's element width rather than at `i32`, and so the
    /// copy-on-store hazard is seen before a later operand can free
    /// the text being stored.  The receiver's own shape is the
    /// caller's business: these positions are the list methods', and a
    /// map or a builder spelling the same name stores nothing here.
    pub fn storedArgument(self: Intrinsic) ?usize {
        return switch (self) {
            .append_value => 1,
            .insert_value => 2,

            .abs,
            .min,
            .max,
            .clamp,
            .sqrt,
            .floor,
            .ceil,
            .trunc,
            .len,
            .string_slice,
            .string_byte,
            .string_find_byte,
            .assert_true,
            .trap_message,
            .null_object,
            .none_value,
            .is_none,
            .optional_wrap,
            .optional_unwrap,
            .errored,
            .error_message,
            .forget,
            .raise_error,
            .index_get,
            .index_set,
            .list_slice,
            .append_ascii,
            .pop_value,
            .remove_entry,
            .has_key,
            .key_at,
            .value_at,
            .dim_size,
            .copy_object,
            .list_sort,
            .list_reverse,
            .list_find,
            .list_contains,
            .clear_object,
            .map_keys,
            .map_values,
            .map_get,
            .map_place,
            .array_fill,
            .str_value,
            .function_name,
            .parse_i64,
            .parse_f64,
            .parse_str,
            .print,
            .file_read,
            .file_write,
            .file_append,
            .file_delete,
            .file_rename,
            .dir_list,
            .dir_create,
            .path_kind,
            .gpu_backend,
            .ui_window_open,
            .ui_window_surface,
            .gpu_surface_size,
            .gpu_surface_clear,
            .gpu_surface_fill_rect,
            .gpu_surface_present,
            .term_rows,
            .term_cols,
            .term_clear,
            .term_move,
            .term_style,
            .term_write,
            .term_flush,
            .key_read,
            .key_text,
            .read_line,
            .print_error,
            .clock_ms,
            .epoch_ms,
            .sleep_ms,
            .env_get,
            .exit_program,
            .os_total_memory,
            .os_available_memory,
            .file_open,
            .handle_read,
            .handle_write,
            .handle_flush,
            .task_wait,
            .os_cpu_count,
            .shell_run,
            .term_event_data,
            .own_storage,
            .drop_storage,
            .export_storage,
            .retain,
            .release,
            .bytes_value,
            => null,
        };
    }
};

/// The words the runtime says back (`support/vocabulary.zig`).  Named
/// here because a program's instructions and its traps are one wire
/// surface; defined below both stages because `libluce_rt` speaks them
/// too and must not import a compiler stage to do it.
pub const ErrorCode = vocabulary.ErrorCode;
pub const FileAct = vocabulary.FileAct;
pub const TrapCode = vocabulary.TrapCode;

pub const Instruction = union(enum) {
    const_boolean: bool,
    /// A numeric constant, **carried at the widest member of its
    /// family** — the register's own type is the width it lands on.
    ///
    /// This is the language's own rule about literals, kept one stage
    /// further down: a number has no type until it meets one
    /// (docs/TYPES.md D3), and what it meets here is the register.
    /// Every value an `i32` register can hold is exactly an `i64` and
    /// every value a `f32` register can hold is exactly an `f64`, so
    /// nothing is lost by carrying them this way and no width needs an
    /// instruction of its own — which is why adding `u8`, `i16`
    /// and `f16` will add none either.  `mir/verify.zig` checks
    /// the value really does fit the register it lands in.
    const_integer: i128,
    const_float: f64,
    const_str: u32,
    /// A program-root constant container: the index of the row whose
    /// contents each runtime materializes before it executes a
    /// function.  The register's heap type must be the row's `heap`.
    const_container: u32,
    /// A **function value**: the function it names, and the receiver it
    /// carries (docs/FUNCTIONS.md D2, docs/BINDING.md D12).  The
    /// register's own type is the signature it is allowed to be called
    /// at — the pair says which function and with what environment, and
    /// the type says what shape the call wears.
    ///
    /// It kept its `const_` name after gaining a receiver because the
    /// unbound form is still what it always was and is still the common
    /// one; what changed is that the environment may be non-empty, not
    /// what the instruction means.
    const_function: BoundFunction,
    local_get: LocalId,
    local_set: struct { local: LocalId, value: Register },
    /// Read a zeroing slot and upgrade its live target to one owned strong
    /// optional value. Ordinary registers never carry the weak tag.
    weak_local_get: LocalId,
    /// Store a strong optional reference as a non-owning weak handle.
    weak_local_set: struct { local: LocalId, value: Register },
    binary: Binary,
    unary: Unary,
    /// A numeric conversion: from the operand's type to this
    /// instruction's own result type.
    ///
    /// **There is no kind.**  A conversion already knows both ends —
    /// the operand carries the source and the register carries the
    /// destination — so a stored kind is information the verifier can
    /// derive and a second place for the two to disagree.  Seven types
    /// would have been up to forty-two kinds; there are none, and the
    /// instruction set got smaller rather than larger (docs/TYPES.md
    /// §3).
    convert: Register,
    /// Erase one concrete nominal value behind an interface witness.  The
    /// payload is stored exactly once, regardless of the contract's size.
    interface_make: InterfaceMake,
    struct_make: struct { layout: u32, fields: []Register },
    struct_get: struct { target: Register, layout: u32, field: u32 },
    struct_set: struct { target: Register, layout: u32, field: u32, value: Register },
    weak_struct_get: struct { target: Register, layout: u32, field: u32 },
    weak_struct_set: struct { target: Register, layout: u32, field: u32, value: Register },
    /// Build one union value: the member index in slot 0, then the
    /// member's payload fields in declaration order (docs/UNION.md D8).
    /// The struct path with one more register in front — built whole,
    /// never assigned into.
    variant_make: struct { variant: u32, member: u32, fields: []Register },
    /// The member index a union value holds — slot 0 of its run, as a
    /// `i64`.  What `match` dispatches on (docs/UNION.md D5).
    variant_tag: struct { target: Register },
    /// One payload field of a union value: slot `1 + field` of its run.
    /// Emitted only inside an arm that proved the member, so a
    /// wrong-arm read is unrepresentable rather than checked
    /// (docs/UNION.md D7).
    variant_field: struct { target: Register, variant: u32, member: u32, field: u32 },
    call: Call,
    /// A direct call whose implied receiver is a mutable local in the
    /// caller. `receiver` is logical parameter zero; `arguments` are
    /// only the parameters the source call writes. The callee's local
    /// zero is marked `inout` and aliases this local on both the normal
    /// and errored edges.
    call_inout: InoutCall,
    /// Dispatch through an interface value. The read form accepts any value;
    /// the inout form names the mutable local whose existential payload may
    /// be replaced by a `mutating` requirement.
    interface_call: InterfaceCall,
    interface_call_inout: InterfaceInoutCall,
    /// `spawn f(args)` — hand `f` and its arguments to a worker with a
    /// runtime of its own, and answer the `task` that owns it
    /// (docs/THREADS.md D2, D3).  The same shape as `call` because it
    /// *is* a call, made somewhere else: what differs is that the
    /// arguments cross a runtime boundary, so every object among them
    /// is **moved** here — stage 4 has already refused a bare object
    /// name, and every object argument reaching this instruction is one
    /// this frame owned and no longer does.
    spawn: Call,
    /// A call **through a function value** (docs/FUNCTIONS.md D2).  The
    /// same shape as `call` with the callee in a register instead of a
    /// table index; `signature` is the type the callee wears, which is
    /// what says the argument types, the result type, and which
    /// arguments were given rather than lent.
    ///
    /// **Both engines dispatch through the program's function table**:
    /// the value is an index, so the interpreter looks the function up
    /// and the compiled path loads a pointer out of a table it emitted.
    /// There is no second calling convention and no thunk.
    call_indirect: IndirectCall,
    intrinsic: IntrinsicCall,
    heap_new: HeapNew,
    jump: BlockId,
    branch: struct { condition: Register, then_block: BlockId, else_block: BlockId },
    ret: ?Register,
    trap: TrapCode,
    /// Leave this frame with an error already in the channel — what
    /// `try` does on the failing side, and what follows `raise_error`.
    /// It carries nothing because the releases it owes stand in the
    /// block in front of it: `lowerReturn`'s three lines with one
    /// terminator changed (docs/FAILURE.md).
    unwind,

    pub const Binary = struct { op: BinaryOp, operand_type: Type, left: Register, right: Register };
    pub const Unary = struct { op: UnaryOp, operand: Register };
    /// A function value as both engines build it: which function, and
    /// the register holding the receiver it travels with, or null when
    /// it travels with none (docs/BINDING.md D12).
    ///
    /// **Null is not a special case downstream.**  Both engines build
    /// the same two-slot run either way — the function index, then the
    /// receiver or `none` — so a bound value and a plain one are one
    /// shape at a call, and only this field says which was written.
    pub const BoundFunction = struct {
        function: u32,
        receiver: ?Register = null,
        /// Compiler-generated interface witness entries may point at a
        /// fallible implementation even though ordinary function values
        /// have no fallibility in their source type.
        fallible: bool = false,
    };
    pub const Call = struct { function: u32, arguments: []Register };
    pub const InoutCall = struct { function: u32, receiver: LocalId, arguments: []Register };
    pub const InterfaceMake = struct { layout: u32, witness: u32, receiver: Register };
    pub const InterfaceCall = struct {
        receiver: Register,
        layout: u32,
        method: u32,
        arguments: []Register,
        fallible: bool = false,
    };
    pub const InterfaceInoutCall = struct {
        receiver: LocalId,
        layout: u32,
        method: u32,
        arguments: []Register,
        fallible: bool = false,
    };
    pub const IndirectCall = struct {
        callee: Register,
        signature: u32,
        arguments: []Register,
        /// Whether the target is allowed to return through the error
        /// channel. Interface dispatch carries this at the call site because
        /// the source function type itself has no fallibility bit.
        fallible: bool = false,
    };
    pub const IntrinsicCall = struct { kind: Intrinsic, arguments: []Register };
    pub const HeapNew = struct { heap: u32, dims: []Register };

    pub fn isTerminator(self: Instruction) bool {
        return switch (self) {
            .jump, .branch, .ret, .trap, .unwind => true,
            else => false,
        };
    }
};

/// One statically verified conformance descriptor.  A runtime existential
/// stores only this row's one-based index and one owned payload. Method
/// indexes are in the interface declaration's order.
pub const InterfaceWitness = struct {
    interface: u32,
    receiver: Type,
    methods: []u32,
};

pub const Local = struct {
    name: []const u8,
    local_type: Type,
    /// True when this slot owns the string bytes and struct field runs
    /// it holds, and releases them when it dies (docs/STRINGS.md).
    /// False for a parameter, which borrows its caller's, and for the
    /// hidden slots a block-split spill uses, which borrow whatever
    /// they carry across the branch.
    ///
    /// Read by both engines to decide two things: that a frame's slot
    /// starts *empty* rather than at a shared zero, and that a trap
    /// unwinding past every release can still give the storage back.
    owns_storage: bool = false,
    /// Use the boxed Runtime.Value slot shape without claiming ownership.
    /// This is distinct from `owns_storage`: a closure bridge must preserve
    /// inline text while the destination cell, not the bridge, releases it.
    boxed_storage: bool = false,
    /// The slot contains a runtime weak handle while `local_type` remains
    /// the logical optional type seen by instruction results.
    weak: bool = false,
    /// Logical parameter zero of a writing method. Reads and writes
    /// alias the caller's receiver slot, and ownership operations use
    /// that binding's identity. This frame neither initializes nor
    /// releases the external slot.
    inout: bool = false,
};

pub const Block = struct {
    items: []Register,
};

pub const Origin = struct {
    line: u32,
    column: u32,
};

/// One flat value stored inside a constant-container row.
///
/// Strings name the program's shared byte pool.  Structs recurse only
/// through value fields; the verifier rejects every heap-bearing field
/// and accepts `absent` only for an optional field of such a struct.
/// All slices and their contents are arena-owned by the program.
pub const ConstantValue = union(enum) {
    boolean: bool,
    integer: i128,
    float: f64,
    str: u32,
    strukt: Struct,
    absent,

    pub const Struct = struct {
        layout: u32,
        fields: []ConstantValue,
    };
};

/// One declared constant container, kept distinct even when another
/// declaration has identical contents.  `source` and `origin` name
/// allocation failures during the eager per-runtime materialization;
/// release stripping clears them but keeps `name` for the row's
/// identity.  All referenced memory is arena-owned by the program.
pub const ContainerConstant = struct {
    name: []const u8,
    heap: u32,
    payload: Payload,
    source: []const u8 = "",
    origin: Origin = .{ .line = 0, .column = 0 },

    pub const MapEntry = struct {
        key: ConstantValue,
        value: ConstantValue,
    };

    pub const Payload = union(enum) {
        sequence: []ConstantValue,
        map: []MapEntry,
    };
};

pub const Function = struct {
    name: []const u8,
    parameter_count: u32,
    return_type: Type,
    /// Written `-> T!` or `-> !`: this function may come back errored
    /// instead of returning, and every caller has to say which of
    /// `try` and `catch` it means (docs/FAILURE.md).
    ///
    /// **Fallibility is an attribute of the function, not of its
    /// type.**  `return_type` is the `T`, unchanged and unwidened,
    /// which is what keeps `types.Type` out of this entirely — and
    /// what gives Luce Ok-wrapping for free: `return x` in a `-> T!`
    /// function returns `x`.
    fallible: bool = false,
    locals: []Local,
    instructions: []Instruction,
    result_types: []Type,
    blocks: []Block,
    origins: []Origin = &.{},
    source: []const u8 = "",
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    structs: []StructLayout = &.{},
    heap_types: []types.HeapType = &.{},
    /// One row per declared enum: its name, its width, and its members
    /// (docs/ENUMS.md D10).  Read where a name is needed — the zero of
    /// an enum-typed slot, `luce ir`, a diagnostic — and never on the
    /// execution path, where an enum is the integer it is stored as.
    enums: []types.EnumType = &.{},
    /// One row per declared union: its name and its members with their
    /// payload fields (docs/UNION.md D18).  What the three `variant_*`
    /// instructions index, exactly as `structs` is what the `struct_*`
    /// three index — never one through the other's table.
    variants: []types.VariantType = &.{},
    /// One row per distinct function type the program writes
    /// (docs/FUNCTIONS.md S2): what a call through it takes, with the
    /// verb each object parameter receives by, and what it answers.
    /// Read where a call through a value is checked and emitted, and by
    /// `luce ir`; never on the execution path, where a function value is
    /// the `i32` it is stored as.
    signatures: []types.Signature = &.{},
    interface_witnesses: []InterfaceWitness = &.{},
    functions: []Function = &.{},
    constants: []const []const u8 = &.{},
    /// Constant-container declarations after reachability pruning.
    /// Rows deliberately retain declaration identity; equal contents
    /// are not interned.
    container_constants: []ContainerConstant = &.{},
    entry_function: u32 = 0,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Drop debug info — the release build.  Traps in a stripped program
/// still name their functions, but carry no source lines, and the
/// encoded module is smaller.  Semantics never change: every check
/// and trap fires identically in both modes.
pub fn strip(program: *Program) void {
    for (program.functions) |*function| {
        function.origins = &.{};
        function.source = "";
    }
    for (program.container_constants) |*constant| {
        constant.source = "";
        constant.origin = .{ .line = 0, .column = 0 };
    }
}
