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
const budget: luce.backend.Budget = .{ .steps = 5_000_000, .call_depth = 128 };

// ---------------------------------------------------------------------------
// LuceService
// ---------------------------------------------------------------------------

pub const LuceService = struct {
    allocator: Allocator,
    cache: std.AutoHashMapUnmanaged(IdBytes, Cached) = .empty,

    const Cached = struct {
        revision: u64,
        program: luce.ir.Program,
    };

    pub fn init(allocator: Allocator) LuceService {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LuceService) void {
        var cached = self.cache.valueIterator();
        while (cached.next()) |entry| entry.program.deinit();
        self.cache.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn evaluator(self: *LuceService) Evaluator {
        return .{ .context = self, .evaluateFn = run };
    }

    /// Compile a texel's content against its ports and render any
    /// diagnostics.  Null when the program is fine (and warms the
    /// cache) or when the texel carries no source.  The caller owns
    /// the rendered text.
    pub fn check(self: *LuceService, texel: *const Texel) error{OutOfMemory}!?[]u8 {
        const source = sourceOf(texel) orelse return null;
        var schema = try self.buildSchema(texel);
        defer schema.deinit(self.allocator);

        var compiled = try luce.compile.compile(self.allocator, source, schema.schema);
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
            try passthrough(allocator, texel, outputs);
            return;
        };

        const program = (try self.cachedProgram(texel, source, allocator, outputs)) orelse {
            try passthrough(allocator, texel, outputs);
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

        const result = try luce.backend.evaluate(scratch, program, input_frame, output_frame, budget);
        switch (result) {
            .success => {
                for (program.outputs, output_frame) |port, written| {
                    const value = written orelse continue;
                    try outputs.put(allocator, port.name, .{
                        .available = try toValue(allocator, value),
                    });
                }
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
        try passthrough(allocator, texel, outputs);
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
        var compiled = try luce.compile.compile(self.allocator, source, schema.schema);
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

    fn fromOutcome(outcome: ?Outcome, declared: luce.types.PortType) luce.backend.InputValue {
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

    fn toValue(allocator: Allocator, value: luce.backend.RuntimeValue) error{OutOfMemory}!Value {
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

    /// Declared outputs not produced fall back to stored sources, and
    /// anything still missing is unavailable — the Spool requires
    /// every declared output.
    fn passthrough(allocator: Allocator, texel: *const Texel, outputs: *OutcomeMap) SpoolError!void {
        for (texel.outputs.items) |port| {
            if (outputs.contains(port.name)) continue;
            if (port.source) |stored| {
                try outputs.put(allocator, port.name, .{ .available = try stored.clone(allocator) });
            } else {
                try outputs.put(allocator, port.name, .unavailable);
            }
        }
    }
};
