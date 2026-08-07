//! What machine is this?  The three system facts behind `std.os`.
//!
//! Three functions, no state, and nothing of the terminal or the file
//! system in them — which is why they are here and not in `host.zig`,
//! whose subject is a running program's world rather than the metal
//! under it.  `host.zig` wraps each one in a C shim and hands it to
//! the ABI table; `start.zig` gets them from the same place, because a
//! program's answers must not depend on who started it.
//!
//! **Null means this host cannot tell**, and it is the one thing that
//! is never faked.  A platform whose numbers we do not know how to ask
//! for, or an ask that failed, answers null; that becomes the ABI's
//! `no`, and the program traps `host_unavailable` at the call.  The
//! alternative — answering zero, or a guess — is a number the program
//! cannot tell from a measurement, and a program that believes a
//! machine has no memory will do something worse than stop.
//!
//! Total memory and the processor count come from `std`, which already
//! knows how to ask on every platform Zig targets.  Only *available*
//! memory is written out here, because there is no portable question
//! for it and the two platforms loom runs on disagree about what the
//! word even means.  Each answer says, in place, exactly what it
//! counted.

const std = @import("std");
const builtin = @import("builtin");

/// Bytes of physical memory the machine has.  Fixed for the life of a
/// run: this is the hardware, not a quota.
pub fn totalMemory() ?i64 {
    const bytes = std.process.totalSystemMemory() catch return null;
    return std.math.cast(i64, bytes);
}

/// How many processors the host would schedule work onto — logical
/// ones, so a machine with simultaneous multithreading counts threads.
pub fn cpuCount() ?i64 {
    const count = std.Thread.getCpuCount() catch return null;
    return std.math.cast(i64, count);
}

/// Bytes of memory the machine could still hand out.
///
/// **The two platforms mean different things by the word, and both
/// meanings are here rather than averaged into a lie.**  Neither is a
/// promise: it is what was true at the moment of asking, and it moves
/// while the answer is being carried back.
///
/// - **macOS**: free, inactive and purgeable pages together — what the
///   kernel can supply without swapping.  Not `free` alone, which on
///   macOS is close to meaningless: this machine reports 3.7 GiB free
///   out of 64 GiB and 38 GiB available, because macOS keeps almost
///   nothing idle and reclaims the difference on demand.
/// - **Linux**: the kernel's own `MemAvailable`, which is the number
///   the kernel publishes precisely so that userland stops adding up
///   the wrong fields.  Where `/proc` is not mounted, `sysinfo`'s free
///   plus buffers — an understatement, because it leaves out the
///   reclaimable page cache, and said so here rather than silently.
/// - **Anywhere else**: null.  We do not know how to ask.
pub fn availableMemory() ?i64 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => darwinAvailableMemory(),
        .linux => linuxAvailableMemory(),
        else => null,
    };
}

// ---------------------------------------------------------------------------
// macOS
// ---------------------------------------------------------------------------

/// `HOST_VM_INFO64`, the flavor of `host_statistics64` that answers
/// `vm_statistics64_data_t`.
const host_vm_info64: std.c.integer_t = 4;

/// The size of that structure in 32-bit words — `HOST_VM_INFO64_COUNT`
/// from `<mach/host_info.h>`, which is 40 on every Darwin this builds
/// for.  It is an in/out parameter: the kernel fills what it has and
/// writes back how many words that was, which is 38 on macOS 15, so
/// the buffer is asked for whole and the answer is checked rather than
/// assumed.
const host_vm_info64_count: std.c.mach_msg_type_number_t = 40;

/// The four page counts wanted out of `vm_statistics64_data_t`, as
/// indices into the run of 32-bit words it is.
///
/// Indices rather than a transcribed struct: only these four fields
/// are wanted, all four are 32-bit page counts, and the nine 64-bit
/// counters interleaved between them would otherwise have to be
/// spelled out exactly right for no gain.  Each is `offsetof` divided
/// by four, measured against `<mach/vm_statistics.h>`; the prefix
/// through `speculative_count` has been stable since the structure was
/// introduced, and `count` above is what proves the kernel filled it.
const vm_free_count = 0;
const vm_inactive_count = 2;
const vm_purgeable_count = 22;
const vm_speculative_count = 23;

fn darwinAvailableMemory() ?i64 {
    // `hw.pagesize` is a 32-bit sysctl; asking for eight bytes of it
    // is an EINVAL rather than a wide answer.
    var page_size: u32 = undefined;
    var page_size_length: usize = @sizeOf(u32);
    if (std.c.sysctlbyname("hw.pagesize", &page_size, &page_size_length, null, 0) != 0) {
        return null;
    }
    if (page_size == 0) return null;

    var statistics: [host_vm_info64_count]u32 align(8) = undefined;
    var filled: std.c.mach_msg_type_number_t = host_vm_info64_count;
    const host = std.c.mach_host_self();
    const answered = host_statistics64(host, host_vm_info64, &statistics, &filled);
    // `mach_host_self` hands over a send right; a program that polls
    // available memory in a loop would leak one per reading.
    _ = std.c.mach_port_deallocate(std.c.mach_task_self(), host);
    if (answered != 0) return null;
    if (filled <= vm_speculative_count) return null;

    // Speculative pages are *inside* `free_count` already — `vm_stat`
    // prints `free_count - speculative_count` as its "Pages free" row,
    // which is how you can tell — so they are available and are not
    // added a second time here.  `vm_speculative_count` earns its
    // place above as the bound `filled` is checked against: it is the
    // last field this reading depends on.
    const pages: u64 = @as(u64, statistics[vm_free_count]) +
        @as(u64, statistics[vm_inactive_count]) +
        @as(u64, statistics[vm_purgeable_count]);
    return std.math.cast(i64, pages * @as(u64, page_size));
}

extern "c" fn host_statistics64(
    host: std.c.mach_port_t,
    flavor: std.c.integer_t,
    info: [*]u32,
    count: *std.c.mach_msg_type_number_t,
) std.c.kern_return_t;

// ---------------------------------------------------------------------------
// Linux
// ---------------------------------------------------------------------------

fn linuxAvailableMemory() ?i64 {
    if (readMemAvailable()) |kilobytes| {
        return std.math.cast(i64, kilobytes * 1024);
    }
    // No `/proc`: free plus buffers, which understates by the whole
    // reclaimable page cache.  It is the honest floor of what is
    // available, and the reason `MemAvailable` is asked for first.
    var info: std.os.linux.Sysinfo = undefined;
    const result = std.os.linux.sysinfo(&info);
    if (std.os.linux.errno(result) != .SUCCESS) return null;
    const bytes = (@as(u64, info.freeram) + @as(u64, info.bufferram)) * info.mem_unit;
    return std.math.cast(i64, bytes);
}

/// `MemAvailable` out of `/proc/meminfo`, in kibibytes.
///
/// The kernel publishes this field precisely so that userland stops
/// adding up free, buffers and cache and getting it wrong; it accounts
/// for the reclaimable page cache and slab that `sysinfo` cannot see.
/// Read with the raw syscalls because this is the platform layer and
/// there is no `std.Io` down here to hand a file API.
fn readMemAvailable() ?u64 {
    const linux = std.os.linux;
    const opened = linux.open("/proc/meminfo", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const file: i32 = @intCast(opened);
    defer _ = linux.close(file);

    // `MemAvailable` is the third line of the file on every kernel
    // that has it, so one short read reaches it with room to spare.
    var text: [1024]u8 = undefined;
    const taken = linux.read(file, &text, text.len);
    if (linux.errno(taken) != .SUCCESS) return null;

    var lines = std.mem.splitScalar(u8, text[0..taken], '\n');
    while (lines.next()) |line| {
        const label = "MemAvailable:";
        if (!std.mem.startsWith(u8, line, label)) continue;
        const rest = std.mem.trim(u8, line[label.len..], " \t");
        const digits = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
        return std.fmt.parseInt(u64, digits, 10) catch null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the machine answers its own facts, and they hold together" {
    const total = totalMemory() orelse {
        // Only a platform `std` cannot ask may decline, and every
        // platform this is built for can.
        return error.TotalMemoryUnknown;
    };
    try testing.expect(total > 0);

    const processors = cpuCount() orelse return error.CpuCountUnknown;
    try testing.expect(processors >= 1);

    // The one fact with platform code of its own: required where that
    // code exists, permitted to decline where it does not.
    const available = availableMemory();
    switch (builtin.os.tag) {
        .macos, .linux => {
            const free_bytes = available orelse return error.AvailableMemoryUnknown;
            try testing.expect(free_bytes > 0);
            try testing.expect(free_bytes <= total);
        },
        else => {},
    }
}

test "available memory is read afresh, not remembered" {
    // Two readings of a moving number may be equal — a quiet machine
    // will give the same one twice — but neither may be a cache, and
    // asking twice must not be a way to make the host fail.  What is
    // actually under test is that the second call still answers on the
    // same terms as the first: the mach port taken for the first
    // reading was given back.
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    const first = availableMemory() orelse return error.AvailableMemoryUnknown;
    const second = availableMemory() orelse return error.AvailableMemoryUnknown;
    try testing.expect(first > 0);
    try testing.expect(second > 0);
}
