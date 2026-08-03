//! libLLVM's stable C surface: bitcode in, object code out.
//!
//! This file is the only place in the tree that links against LLVM,
//! and it deliberately uses the narrowest, most stable part of the C
//! API — parse a bitcode module, make a target machine, run the pass
//! pipeline, emit an object.  That is the tier LLVM's own developer
//! policy describes as "take this IR file and compile it"; IR
//! *construction*, the part that has broken repeatedly across
//! releases, happens in `lower.zig` against `std.zig.llvm.Builder`
//! instead (docs/CODEGEN.md).
//!
//! The declarations below are plain Zig `extern fn`s.  There is no C
//! or C++ shim, because nothing here needs one.

const std = @import("std");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// LLVM target triple.  Empty means the host, as LLVM reports it.
    triple: []const u8 = "",
    /// Target CPU and feature string; empty means the target's own
    /// defaults, which for AArch64 is the generic baseline rather than
    /// the machine in front of us.  Clang, for the same triple, names
    /// `apple-m1` and a page of features.
    ///
    /// **Deliberately left empty, and measured rather than assumed.**
    /// Both `apple-m1` (clang's default here) and `apple-m4` (this
    /// host) were tried across the whole `bench/` set: every program
    /// landed inside ±1%, because the generated code's hot path is
    /// opaque calls into `libluce_rt` rather than arithmetic an
    /// instruction-selector can improve.  Naming a CPU would therefore
    /// buy nothing today and cost the artifact its portability — an
    /// object built here would refuse to run on an older Mac.  Revisit
    /// when the container operations are generated inline: at that
    /// point there is a vectorizable loop to tune for, and the knob is
    /// already here.
    cpu: []const u8 = "",
    features: []const u8 = "",
    /// The pass pipeline, in the new pass manager's textual form.
    passes: []const u8 = "default<O2>",
    /// Position-independent code, which a shared library needs.
    relocation: Relocation = .pic,
};

pub const Relocation = enum(c_uint) {
    default = 0,
    static = 1,
    pic = 2,
    dynamic_no_pic = 3,
};

pub const Result = union(enum) {
    /// A relocatable object file for `Options.triple`.  Caller owns it.
    object: []const u8,
    /// What LLVM said went wrong.  Caller owns it.
    failed: []const u8,
};

/// Compile LLVM bitcode to a relocatable object.
///
/// `bitcode` is borrowed for the duration of the call.  Both arms of
/// the result are allocated from `gpa` and owned by the caller;
/// everything LLVM allocated is released before returning.
///
/// One caller at a time: LLVM's target registry is process-global.
pub fn compile(gpa: Allocator, bitcode: []const u8, options: Options) error{OutOfMemory}!Result {
    ensureTargets();

    const triple = if (options.triple.len != 0)
        try gpa.dupeZ(u8, options.triple)
    else
        try hostTriple(gpa);
    defer gpa.free(triple);
    const cpu = try gpa.dupeZ(u8, options.cpu);
    defer gpa.free(cpu);
    const features = try gpa.dupeZ(u8, options.features);
    defer gpa.free(features);
    const passes = try gpa.dupeZ(u8, options.passes);
    defer gpa.free(passes);

    const context = LLVMContextCreate();
    defer LLVMContextDispose(context);

    // The buffer only borrows `bitcode`, and parsing borrows the
    // buffer: the parse is eager, so both can go once it returns.
    const source = LLVMCreateMemoryBufferWithMemoryRange(
        bitcode.ptr,
        bitcode.len,
        "luce.bc",
        0,
    );
    var module: ModuleRef = undefined;
    const rejected = LLVMParseBitcodeInContext2(context, source, &module) != 0;
    LLVMDisposeMemoryBuffer(source);
    if (rejected) {
        return .{ .failed = try gpa.dupe(u8, "LLVM rejected the generated bitcode") };
    }
    defer LLVMDisposeModule(module);

    var target: TargetRef = undefined;
    var message: ?[*:0]u8 = null;
    if (LLVMGetTargetFromTriple(triple.ptr, &target, &message) != 0) {
        return .{ .failed = try take(gpa, &message, "no LLVM target for this triple") };
    }

    const machine = LLVMCreateTargetMachine(
        target,
        triple.ptr,
        cpu.ptr,
        features.ptr,
        @intFromEnum(OptLevel.default),
        @intFromEnum(options.relocation),
        @intFromEnum(CodeModel.default),
    ) orelse {
        return .{ .failed = try gpa.dupe(u8, "LLVM could not create a target machine") };
    };
    defer LLVMDisposeTargetMachine(machine);

    const pass_options = LLVMCreatePassBuilderOptions();
    defer LLVMDisposePassBuilderOptions(pass_options);
    if (LLVMRunPasses(module, passes.ptr, machine, pass_options)) |failure| {
        const text = LLVMGetErrorMessage(failure);
        defer LLVMDisposeErrorMessage(text);
        return .{ .failed = try gpa.dupe(u8, std.mem.span(text)) };
    }

    var emitted: MemoryBufferRef = undefined;
    if (LLVMTargetMachineEmitToMemoryBuffer(
        machine,
        module,
        @intFromEnum(FileType.object),
        &message,
        &emitted,
    ) != 0) {
        return .{ .failed = try take(gpa, &message, "LLVM could not emit an object") };
    }
    defer LLVMDisposeMemoryBuffer(emitted);

    const start = LLVMGetBufferStart(emitted);
    const length = LLVMGetBufferSize(emitted);
    return .{ .object = try gpa.dupe(u8, start[0..length]) };
}

/// The LLVM triple for the machine this compiler is running on.  The
/// caller owns the result.
pub fn hostTriple(gpa: Allocator) error{OutOfMemory}![:0]u8 {
    const reported = LLVMGetDefaultTargetTriple();
    defer LLVMDisposeMessage(reported);
    return gpa.dupeZ(u8, std.mem.span(reported));
}

/// Copy an LLVM-allocated message into our allocator and release it;
/// `fallback` covers the case where LLVM reported nothing.
fn take(gpa: Allocator, message: *?[*:0]u8, fallback: []const u8) error{OutOfMemory}![]const u8 {
    const reported = message.* orelse return gpa.dupe(u8, fallback);
    defer LLVMDisposeMessage(reported);
    message.* = null;
    return gpa.dupe(u8, std.mem.span(reported));
}

// ---------------------------------------------------------------------------
// Target registration
// ---------------------------------------------------------------------------

// LLVM's target registry is process-global and registered by hand.
// We register exactly the targets docs/CODEGEN.md commits to; adding
// another costs four lines.

/// Whether the registry has been filled in.  A plain flag, not an
/// atomic: `TargetRegistry::RegisterTarget` is not thread-safe on
/// LLVM's side either, so `compile` is documented as one caller at a
/// time rather than pretending otherwise.
var targets_registered = false;

fn ensureTargets() void {
    if (targets_registered) return;
    targets_registered = true;

    LLVMInitializeAArch64TargetInfo();
    LLVMInitializeAArch64Target();
    LLVMInitializeAArch64TargetMC();
    LLVMInitializeAArch64AsmPrinter();

    LLVMInitializeX86TargetInfo();
    LLVMInitializeX86Target();
    LLVMInitializeX86TargetMC();
    LLVMInitializeX86AsmPrinter();

    LLVMInitializeWebAssemblyTargetInfo();
    LLVMInitializeWebAssemblyTarget();
    LLVMInitializeWebAssemblyTargetMC();
    LLVMInitializeWebAssemblyAsmPrinter();
}

// ---------------------------------------------------------------------------
// The C declarations
// ---------------------------------------------------------------------------

const ContextRef = *opaque {};
const ModuleRef = *opaque {};
const MemoryBufferRef = *opaque {};
const TargetRef = *opaque {};
const TargetMachineRef = *opaque {};
const PassBuilderOptionsRef = *opaque {};
const ErrorRef = *opaque {};

const OptLevel = enum(c_uint) { none = 0, less = 1, default = 2, aggressive = 3 };
const CodeModel = enum(c_uint) { default = 0 };
const FileType = enum(c_uint) { assembly = 0, object = 1 };

extern fn LLVMInitializeAArch64TargetInfo() void;
extern fn LLVMInitializeAArch64Target() void;
extern fn LLVMInitializeAArch64TargetMC() void;
extern fn LLVMInitializeAArch64AsmPrinter() void;
extern fn LLVMInitializeX86TargetInfo() void;
extern fn LLVMInitializeX86Target() void;
extern fn LLVMInitializeX86TargetMC() void;
extern fn LLVMInitializeX86AsmPrinter() void;
extern fn LLVMInitializeWebAssemblyTargetInfo() void;
extern fn LLVMInitializeWebAssemblyTarget() void;
extern fn LLVMInitializeWebAssemblyTargetMC() void;
extern fn LLVMInitializeWebAssemblyAsmPrinter() void;

extern fn LLVMContextCreate() ContextRef;
extern fn LLVMContextDispose(context: ContextRef) void;
extern fn LLVMDisposeModule(module: ModuleRef) void;
extern fn LLVMDisposeMessage(message: [*:0]u8) void;

extern fn LLVMCreateMemoryBufferWithMemoryRange(
    data: [*]const u8,
    length: usize,
    name: [*:0]const u8,
    requires_null_terminator: c_int,
) MemoryBufferRef;
extern fn LLVMGetBufferStart(buffer: MemoryBufferRef) [*]const u8;
extern fn LLVMGetBufferSize(buffer: MemoryBufferRef) usize;
extern fn LLVMDisposeMemoryBuffer(buffer: MemoryBufferRef) void;

/// Borrows `buffer` rather than taking it: the parse is eager, so the
/// caller disposes the buffer once this returns.
extern fn LLVMParseBitcodeInContext2(
    context: ContextRef,
    buffer: MemoryBufferRef,
    out_module: *ModuleRef,
) c_int;

extern fn LLVMGetDefaultTargetTriple() [*:0]u8;
extern fn LLVMGetTargetFromTriple(
    triple: [*:0]const u8,
    out_target: *TargetRef,
    out_message: *?[*:0]u8,
) c_int;
extern fn LLVMCreateTargetMachine(
    target: TargetRef,
    triple: [*:0]const u8,
    cpu: [*:0]const u8,
    features: [*:0]const u8,
    level: c_uint,
    relocation: c_uint,
    code_model: c_uint,
) ?TargetMachineRef;
extern fn LLVMDisposeTargetMachine(machine: TargetMachineRef) void;
extern fn LLVMTargetMachineEmitToMemoryBuffer(
    machine: TargetMachineRef,
    module: ModuleRef,
    file_type: c_uint,
    out_message: *?[*:0]u8,
    out_buffer: *MemoryBufferRef,
) c_int;

extern fn LLVMCreatePassBuilderOptions() PassBuilderOptionsRef;
extern fn LLVMDisposePassBuilderOptions(options: PassBuilderOptionsRef) void;
extern fn LLVMRunPasses(
    module: ModuleRef,
    passes: [*:0]const u8,
    machine: TargetMachineRef,
    options: PassBuilderOptionsRef,
) ?ErrorRef;
extern fn LLVMGetErrorMessage(handle: ErrorRef) [*:0]u8;
extern fn LLVMDisposeErrorMessage(message: [*:0]u8) void;
