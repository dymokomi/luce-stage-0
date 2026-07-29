//! The luce evaluator: Texels that compute with Luce source.
//!
//! A Texel owns Luce source as content (the code command writes it).
//! When demand reaches a texel whose evaluator is "luce", this service
//! compiles the content against the texel's own Port schema — the
//! ports, not the source, decide what input and output members exist —
//! caches the verified program by texel revision (source is
//! authoritative, native/compiled form is derived and disposable), and
//! runs it through the backend boundary under a budget.  Outputs the
//! program writes publish as available values; declared outputs it
//! does not write fall back to their stored sources (the passthrough
//! convention, which keeps the name port working), or stay
//! unavailable.  Traps and compile failures surface as error outcomes
//! on the computed outputs, never as partial results.

const std = @import("std");
const loom = @import("loom");
const luce = @import("luce");
const ops = @import("ops.zig");
const evaluators = @import("evaluators.zig");

const Allocator = std.mem.Allocator;
const Texel = loom.texel.Texel;
const TexelId = loom.texel_id.TexelId;
const Value = loom.value.Value;
const ValueType = loom.value.ValueType;
const Outcome = loom.spool.Outcome;
const OutcomeMap = loom.spool.OutcomeMap;
const Evaluator = loom.spool.Evaluator;
const SpoolError = loom.spool.Error;

const IdBytes = [TexelId.size]u8;

pub const evaluator_name = "luce";

/// Evaluation budget for one demanded texel; generous for interactive
/// work, bounded so a runaway loop traps instead of hanging the
/// terminal.
pub const budget: luce.backend.Budget = .{ .steps = 5_000_000, .call_depth = 128 };

// ---------------------------------------------------------------------------
// LuceService
// ---------------------------------------------------------------------------

/// Fabric builtins are enabled here: the terminal is the trusted
/// boundary that applies computed intents as ordinary transactions.
const evaluator_compile_options: luce.types.CompileOptions = .{
    .entry_mode = .evaluator,
    .allow_fabric = true,
};
const view_compile_options: luce.types.CompileOptions = .{
    .entry_mode = .evaluator,
    .allow_fabric = false,
};
const script_compile_options: luce.types.CompileOptions = .{
    .entry_mode = .script,
    .allow_fabric = true,
};

// ---------------------------------------------------------------------------
// Pending intents
// ---------------------------------------------------------------------------
//
// Texel-creation intents computed by evaluations, copied out of the
// evaluation arena and owned by the service until the terminal applies
// them after the dispatch that produced them.
//
pub const PendingPort = struct {
    name: []u8,
    declared: ValueType,
};

pub const PendingSet = struct {
    output: []u8,
    value: Value,
};

pub const PendingImage = struct {
    path: []u8,
    pages: u64,

    pub fn deinit(self: *PendingImage, allocator: Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const PendingTexel = struct {
    name: []u8,
    inputs: []PendingPort,
    outputs: []PendingPort,
    content: ?[]u8,
    evaluator: ?[]u8,
    sets: []PendingSet,

    pub fn deinit(self: *PendingTexel, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.inputs) |port| allocator.free(port.name);
        allocator.free(self.inputs);
        for (self.outputs) |port| allocator.free(port.name);
        allocator.free(self.outputs);
        if (self.content) |content| allocator.free(content);
        if (self.evaluator) |evaluator| allocator.free(evaluator);
        for (self.sets) |*set| {
            allocator.free(set.output);
            set.value.deinit(allocator);
        }
        allocator.free(self.sets);
        self.* = undefined;
    }
};

pub const LuceService = struct {
    allocator: Allocator,
    host: ?luce.backend.Host = null,
    cache: std.AutoHashMapUnmanaged(IdBytes, Cached) = .empty,
    view_cache: std.AutoHashMapUnmanaged(IdBytes, Cached) = .empty,
    pending: std.ArrayList(PendingTexel) = .empty,
    pending_images: std.ArrayList(PendingImage) = .empty,

    const Cached = struct {
        revision: u64,
        program: luce.ir.Program,
    };

    pub fn init(allocator: Allocator) LuceService {
        return .{ .allocator = allocator };
    }

    /// Install the terminal's long-lived trusted services.  The host
    /// context must outlive this service.
    pub fn setHost(self: *LuceService, host: luce.backend.Host) void {
        self.host = host;
    }

    pub fn deinit(self: *LuceService) void {
        var cached = self.cache.valueIterator();
        while (cached.next()) |entry| entry.program.deinit();
        self.cache.deinit(self.allocator);
        var views = self.view_cache.valueIterator();
        while (views.next()) |entry| entry.program.deinit();
        self.view_cache.deinit(self.allocator);
        for (self.pending.items) |*intent| intent.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        for (self.pending_images.items) |*intent| intent.deinit(self.allocator);
        self.pending_images.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn hasPending(self: *const LuceService) bool {
        return self.pending.items.len != 0 or self.pending_images.items.len != 0;
    }

    /// Hand the accumulated texel intents to the caller, which owns them.
    pub fn takePending(self: *LuceService) []PendingTexel {
        const taken = self.pending.toOwnedSlice(self.allocator) catch blk: {
            break :blk self.pending.items[0..0];
        };
        self.pending = .empty;
        return taken;
    }

    /// Hand the accumulated image intents to the caller, which owns them.
    pub fn takePendingImages(self: *LuceService) []PendingImage {
        const taken = self.pending_images.toOwnedSlice(self.allocator) catch blk: {
            break :blk self.pending_images.items[0..0];
        };
        self.pending_images = .empty;
        return taken;
    }

    pub const AppliedTexel = struct {
        name: []u8, // owned by the caller
        id: TexelId,
    };

    /// Create every pending texel in one transaction: name, typed
    /// ports, Luce content, evaluator, initial output sources.  Returns
    /// what was made, for the host to report; the caller owns the
    /// names and the slice.
    pub fn applyTexels(
        self: *LuceService,
        io: std.Io,
        store: *loom.store.Store,
    ) ![]AppliedTexel {
        const batch = self.takePending();
        defer {
            for (batch) |*intent| {
                var owned = intent.*;
                owned.deinit(self.allocator);
            }
            self.allocator.free(batch);
        }
        if (batch.len == 0) return &.{};

        var transaction = try store.begin();
        defer transaction.deinit();

        var applied: std.ArrayList(AppliedTexel) = .empty;
        errdefer {
            for (applied.items) |made| self.allocator.free(made.name);
            applied.deinit(self.allocator);
        }
        for (batch) |intent| {
            const spec = try self.borrowSpec(intent);
            defer self.freeSpec(spec);
            const id = try ops.buildTexel(self.allocator, io, &transaction, spec);
            const name = try self.allocator.dupe(u8, intent.name);
            errdefer self.allocator.free(name);
            try applied.append(self.allocator, .{ .name = name, .id = id });
        }
        try transaction.commit();
        return applied.toOwnedSlice(self.allocator);
    }

    pub fn evaluator(self: *LuceService) Evaluator {
        return .{ .context = self, .evaluateFn = run };
    }

    /// The verified program cached for a texel, when its revision is
    /// current — check() warms this.
    pub fn cachedFor(self: *LuceService, texel: *const Texel) ?*const luce.ir.Program {
        const cached = self.cache.getPtr(texel.id.bytes) orelse return null;
        if (cached.revision != texel.revision) return null;
        return &cached.program;
    }

    /// Compile a View with fabric builtins disabled.  The separate
    /// cache prevents a trusted template compilation from granting the
    /// same texel ambient fabric operations when it is presented.
    pub fn checkView(self: *LuceService, texel: *const Texel) error{OutOfMemory}!?[]u8 {
        const source = sourceOf(texel) orelse return null;
        var schema = try self.buildSchema(texel);
        defer schema.deinit(self.allocator);

        var compiled = try luce.compile.compile(self.allocator, source, schema.schema, view_compile_options);
        switch (compiled) {
            .success => |program| {
                try self.replaceViewCached(texel, program);
                return null;
            },
            .failure => |*diagnostics| {
                defer diagnostics.deinit();
                return try diagnostics.render(self.allocator, source);
            },
        }
    }

    pub fn cachedViewFor(self: *LuceService, texel: *const Texel) ?*const luce.ir.Program {
        const cached = self.view_cache.getPtr(texel.id.bytes) orelse return null;
        if (cached.revision != texel.revision) return null;
        return &cached.program;
    }

    /// Evaluate a previously checked View program.  Inputs and outputs
    /// parallel the program's sorted Port schema.  Returned strings
    /// borrow from the caller's arena.
    pub fn evaluateView(
        self: *LuceService,
        arena: Allocator,
        program: *const luce.ir.Program,
        inputs: []const luce.backend.InputValue,
        outputs: []?luce.backend.RuntimeValue,
    ) error{OutOfMemory}!luce.backend.Result {
        return self.evaluateProgram(arena, program, inputs, outputs);
    }

    /// Run a checked program through the same capability-gated host as
    /// ordinary demand and View evaluation.
    pub fn evaluateProgram(
        self: *LuceService,
        arena: Allocator,
        program: *const luce.ir.Program,
        inputs: []const luce.backend.InputValue,
        outputs: []?luce.backend.RuntimeValue,
    ) error{OutOfMemory}!luce.backend.Result {
        return luce.backend.evaluateHosted(arena, program, inputs, outputs, budget, self.host);
    }

    pub const ScriptOutcome = union(enum) {
        ok,
        diagnostics: []u8,
        trap: []u8,
    };

    /// Compile and run standalone Luce source with no ports and fabric
    /// enabled — the headless bootstrap path (lucia open IMAGE --luce
    /// FILE).  Intents land in pending for the host to apply; the
    /// caller owns any returned text.
    pub fn runScript(self: *LuceService, source: []const u8) error{OutOfMemory}!ScriptOutcome {
        return self.runScriptHosted(source, null);
    }

    /// Hosted script evaluation supplies explicit trusted callbacks
    /// for boundary builtins such as capability-gated file reads.
    pub fn runScriptHosted(
        self: *LuceService,
        source: []const u8,
        host: ?luce.backend.Host,
    ) error{OutOfMemory}!ScriptOutcome {
        var compiled = try luce.compile.compile(self.allocator, source, .{}, script_compile_options);
        switch (compiled) {
            .failure => |*diagnostics| {
                defer diagnostics.deinit();
                return .{ .diagnostics = try diagnostics.render(self.allocator, source) };
            },
            .success => |program| {
                var owned = program;
                defer owned.deinit();
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const result = try luce.backend.evaluateHosted(
                    arena.allocator(),
                    &owned,
                    &.{},
                    &.{},
                    budget,
                    host orelse self.host,
                );
                switch (result) {
                    .success => |intents| {
                        try self.copyIntents(intents);
                        return .ok;
                    },
                    .trap => |trapped| return .{
                        .trap = try self.allocator.dupe(u8, trapped.message),
                    },
                    .unavailable => return .ok,
                }
            },
        }
    }

    /// Compile a texel's content against its ports and render any
    /// diagnostics.  Null when the program is fine (and warms the
    /// cache) or when the texel carries no source.  The caller owns
    /// the rendered text.
    pub fn check(self: *LuceService, texel: *const Texel) error{OutOfMemory}!?[]u8 {
        const source = sourceOf(texel) orelse return null;
        var schema = try self.buildSchema(texel);
        defer schema.deinit(self.allocator);

        var compiled = try luce.compile.compile(self.allocator, source, schema.schema, evaluator_compile_options);
        switch (compiled) {
            .success => |program| {
                try self.replaceCached(texel, program);
                return null;
            },
            .failure => |*diagnostics| {
                defer diagnostics.deinit();
                return try diagnostics.render(self.allocator, source);
            },
        }
    }

    // The evaluator callback ------------------------------------------------

    fn run(
        context: *anyopaque,
        allocator: Allocator,
        texel: *const Texel,
        inputs: *const OutcomeMap,
        outputs: *OutcomeMap,
    ) SpoolError!void {
        const self: *LuceService = @ptrCast(@alignCast(context));

        const source = sourceOf(texel) orelse {
            try failComputed(allocator, texel, outputs, "no luce source (use code)");
            try evaluators.passthrough(allocator, texel, outputs);
            return;
        };

        const program = (try self.cachedProgram(texel, source, allocator, outputs)) orelse {
            try evaluators.passthrough(allocator, texel, outputs);
            return;
        };

        // Frames: inputs borrowed from the outcome map, outputs
        // scratch in the evaluation arena.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        const input_frame = try scratch.alloc(luce.backend.InputValue, program.inputs.len);
        for (program.inputs, input_frame) |port, *slot| {
            slot.* = fromOutcome(inputs.get(port.name), port.declared);
        }
        const output_frame = try scratch.alloc(?luce.backend.RuntimeValue, program.outputs.len);
        @memset(output_frame, null);

        const result = try self.evaluateProgram(scratch, program, input_frame, output_frame);
        switch (result) {
            .success => |intents| {
                for (program.outputs, output_frame) |port, written| {
                    const value = written orelse continue;
                    try outputs.put(allocator, port.name, .{
                        .available = try toValue(allocator, value),
                    });
                }
                // Intents outlive the evaluation arena only as copies
                // the service owns until the host applies them.
                try self.copyIntents(intents);
            },
            .unavailable => {
                for (program.outputs) |port| {
                    try outputs.put(allocator, port.name, .unavailable);
                }
            },
            .trap => |trapped| {
                const message = try std.fmt.allocPrint(allocator, "luce trap: {s}", .{trapped.message});
                defer allocator.free(message);
                for (program.outputs) |port| {
                    try outputs.put(allocator, port.name, try Outcome.initError(allocator, message));
                }
            },
        }
        try evaluators.passthrough(allocator, texel, outputs);
    }

    fn cachedProgram(
        self: *LuceService,
        texel: *const Texel,
        source: []const u8,
        allocator: Allocator,
        outputs: *OutcomeMap,
    ) SpoolError!?*const luce.ir.Program {
        if (self.cache.getPtr(texel.id.bytes)) |cached| {
            if (cached.revision == texel.revision) return &cached.program;
        }

        var schema = try self.buildSchema(texel);
        defer schema.deinit(self.allocator);
        var compiled = try luce.compile.compile(self.allocator, source, schema.schema, evaluator_compile_options);
        switch (compiled) {
            .success => |program| {
                try self.replaceCached(texel, program);
                return &self.cache.getPtr(texel.id.bytes).?.program;
            },
            .failure => |*diagnostics| {
                defer diagnostics.deinit();
                const rendered = try diagnostics.render(allocator, source);
                defer allocator.free(rendered);
                const trimmed = std.mem.trimEnd(u8, rendered, "\n");
                const message = try std.fmt.allocPrint(allocator, "luce compile failed\n{s}", .{trimmed});
                defer allocator.free(message);
                try failComputed(allocator, texel, outputs, message);
                return null;
            },
        }
    }

    fn replaceCached(self: *LuceService, texel: *const Texel, program: luce.ir.Program) error{OutOfMemory}!void {
        if (self.cache.getPtr(texel.id.bytes)) |cached| {
            cached.program.deinit();
            cached.* = .{ .revision = texel.revision, .program = program };
            return;
        }
        try self.cache.put(self.allocator, texel.id.bytes, .{
            .revision = texel.revision,
            .program = program,
        });
    }

    fn replaceViewCached(self: *LuceService, texel: *const Texel, program: luce.ir.Program) error{OutOfMemory}!void {
        if (self.view_cache.getPtr(texel.id.bytes)) |cached| {
            cached.program.deinit();
            cached.* = .{ .revision = texel.revision, .program = program };
            return;
        }
        try self.view_cache.put(self.allocator, texel.id.bytes, .{
            .revision = texel.revision,
            .program = program,
        });
    }

    pub fn copyIntents(self: *LuceService, intents: luce.fabric.Intents) error{OutOfMemory}!void {
        for (intents.images.items) |intent| {
            const copied_path = try self.allocator.dupe(u8, intent.path);
            errdefer self.allocator.free(copied_path);
            try self.pending_images.append(self.allocator, .{
                .path = copied_path,
                .pages = intent.pages,
            });
        }
        for (intents.texels.items) |intent| {
            try self.pending.append(self.allocator, try self.copyIntent(intent));
        }
    }

    /// An ops.TexelSpec borrowing one pending intent's strings; only
    /// the small spec arrays are allocated (freeSpec releases them).
    fn borrowSpec(self: *LuceService, intent: PendingTexel) error{OutOfMemory}!ops.TexelSpec {
        const inputs = try self.allocator.alloc(ops.PortSpec, intent.inputs.len);
        errdefer self.allocator.free(inputs);
        for (intent.inputs, inputs) |port, *slot| {
            slot.* = .{ .name = port.name, .declared = port.declared };
        }
        const outputs = try self.allocator.alloc(ops.PortSpec, intent.outputs.len);
        errdefer self.allocator.free(outputs);
        for (intent.outputs, outputs) |port, *slot| {
            slot.* = .{ .name = port.name, .declared = port.declared };
        }
        const sets = try self.allocator.alloc(ops.SetSpec, intent.sets.len);
        for (intent.sets, sets) |set, *slot| {
            slot.* = .{ .output = set.output, .value = set.value };
        }
        return .{
            .name = intent.name,
            .inputs = inputs,
            .outputs = outputs,
            .content = intent.content,
            .evaluator = intent.evaluator,
            .sets = sets,
        };
    }

    fn freeSpec(self: *LuceService, spec: ops.TexelSpec) void {
        self.allocator.free(spec.inputs);
        self.allocator.free(spec.outputs);
        self.allocator.free(spec.sets);
    }

    fn copyIntent(self: *LuceService, intent: luce.fabric.NewTexel) error{OutOfMemory}!PendingTexel {
        const gpa = self.allocator;
        const name = try gpa.dupe(u8, intent.name);
        errdefer gpa.free(name);

        const inputs = try copyPorts(gpa, intent.inputs.items);
        errdefer freePorts(gpa, inputs);
        const outputs = try copyPorts(gpa, intent.outputs.items);
        errdefer freePorts(gpa, outputs);

        const content = if (intent.content) |text| try gpa.dupe(u8, text) else null;
        errdefer if (content) |text| gpa.free(text);
        const assigned = if (intent.evaluator) |text| try gpa.dupe(u8, text) else null;
        errdefer if (assigned) |text| gpa.free(text);

        var sets: std.ArrayList(PendingSet) = .empty;
        errdefer {
            for (sets.items) |*set| {
                gpa.free(set.output);
                set.value.deinit(gpa);
            }
            sets.deinit(gpa);
        }
        for (intent.sets.items) |set| {
            const output = try gpa.dupe(u8, set.output);
            errdefer gpa.free(output);
            var value: Value = switch (set.value) {
                .boolean => |flag| .{ .boolean = flag },
                .int => |number| .{ .int = number },
                .float => |number| .{ .real = number },
                .text => |text| try Value.initText(gpa, text),
            };
            errdefer value.deinit(gpa);
            try sets.append(gpa, .{ .output = output, .value = value });
        }

        return .{
            .name = name,
            .inputs = inputs,
            .outputs = outputs,
            .content = content,
            .evaluator = assigned,
            .sets = try sets.toOwnedSlice(gpa),
        };
    }

    fn copyPorts(gpa: Allocator, ports: []const luce.fabric.PortSpec) error{OutOfMemory}![]PendingPort {
        var copied: std.ArrayList(PendingPort) = .empty;
        errdefer freePortList(gpa, &copied);
        for (ports) |port| {
            const name = try gpa.dupe(u8, port.name);
            errdefer gpa.free(name);
            try copied.append(gpa, .{ .name = name, .declared = valueType(port.declared) });
        }
        return copied.toOwnedSlice(gpa);
    }

    fn freePorts(gpa: Allocator, ports: []PendingPort) void {
        for (ports) |port| gpa.free(port.name);
        gpa.free(ports);
    }

    fn freePortList(gpa: Allocator, ports: *std.ArrayList(PendingPort)) void {
        for (ports.items) |port| gpa.free(port.name);
        ports.deinit(gpa);
    }

    fn valueType(declared: luce.types.PortType) ValueType {
        return switch (declared) {
            .boolean => .boolean,
            .int => .int,
            .float => .real,
            .string => .text,
            .bytes => .bytes,
        };
    }

    // Schema and value mapping ----------------------------------------------

    const OwnedSchema = struct {
        inputs: []luce.types.Port,
        outputs: []luce.types.Port,
        schema: luce.types.PortSchema,

        fn deinit(self: *OwnedSchema, allocator: Allocator) void {
            allocator.free(self.inputs);
            allocator.free(self.outputs);
            self.* = undefined;
        }
    };

    /// The Luce Port schema of a texel: every input and output whose
    /// type Luce can carry.  Ports with texel or blob types stay
    /// outside the language for now.
    fn buildSchema(self: *LuceService, texel: *const Texel) error{OutOfMemory}!OwnedSchema {
        var inputs: std.ArrayList(luce.types.Port) = .empty;
        errdefer inputs.deinit(self.allocator);
        for (texel.inputs.items) |port| {
            const mapped = portType(port.declared) orelse continue;
            try inputs.append(self.allocator, .{ .name = port.name, .declared = mapped });
        }
        var outputs: std.ArrayList(luce.types.Port) = .empty;
        errdefer outputs.deinit(self.allocator);
        for (texel.outputs.items) |port| {
            const mapped = portType(port.declared) orelse continue;
            try outputs.append(self.allocator, .{ .name = port.name, .declared = mapped });
        }
        const owned_inputs = try inputs.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_inputs);
        const owned_outputs = try outputs.toOwnedSlice(self.allocator);
        return .{
            .inputs = owned_inputs,
            .outputs = owned_outputs,
            .schema = .{ .inputs = owned_inputs, .outputs = owned_outputs },
        };
    }

    fn portType(declared: ValueType) ?luce.types.PortType {
        return switch (declared) {
            .boolean => .boolean,
            .int => .int,
            .real => .float,
            .text => .string,
            .bytes => .bytes,
            else => null,
        };
    }

    pub fn fromOutcome(outcome: ?Outcome, declared: luce.types.PortType) luce.backend.InputValue {
        const present = outcome orelse return .unavailable;
        if (present != .available) return .unavailable;
        const value = present.available;
        return switch (declared) {
            .boolean => if (value == .boolean) .{ .value = .{ .boolean = value.boolean } } else .unavailable,
            .int => if (value == .int) .{ .value = .{ .int = value.int } } else .unavailable,
            .float => if (value == .real) .{ .value = .{ .float = value.real } } else .unavailable,
            .string => if (value == .text) .{ .value = .{ .string = value.text } } else .unavailable,
            .bytes => if (value == .bytes) .{ .value = .{ .bytes = value.bytes } } else .unavailable,
        };
    }

    pub fn toValue(allocator: Allocator, value: luce.backend.RuntimeValue) error{OutOfMemory}!Value {
        return switch (value) {
            .boolean => |flag| .{ .boolean = flag },
            .int => |number| .{ .int = number },
            .float => |number| .{ .real = number },
            .string => |text| try Value.initText(allocator, text),
            .bytes => |bytes| try Value.initBytes(allocator, bytes),
            .none, .strukt => unreachable, // ports carry scalars only
        };
    }

    // Outcome helpers -------------------------------------------------------

    fn sourceOf(texel: *const Texel) ?[]const u8 {
        const content = texel.content orelse return null;
        if (content.tag() != .text) return null;
        return content.text;
    }

    /// Error outcomes for every computed output: Luce-typed outputs
    /// with no stored source.  Ports with sources keep their
    /// passthrough value even when the program is broken.
    fn failComputed(
        allocator: Allocator,
        texel: *const Texel,
        outputs: *OutcomeMap,
        message: []const u8,
    ) SpoolError!void {
        for (texel.outputs.items) |port| {
            if (portType(port.declared) == null) continue;
            if (port.source != null) continue;
            try outputs.put(allocator, port.name, try Outcome.initError(allocator, message));
        }
    }
};
