//! The collector behind stats.luciaos.com.
//!
//!   luciastats ingest --logs DIR --db FILE --out FILE [--geo FILE]
//!   luciastats report --db FILE --out FILE
//!   luciastats geo    --csv FILE --out FILE
//!
//! `ingest` is the whole job: read whatever the access logs have
//! gained since last time, count it, and write the report the
//! dashboard reads.  It runs from a systemd timer on the edge server
//! and is safe to run as often as you like — reading a log twice
//! counts it once.
//!
//! `report` rebuilds the JSON from the database without reading any
//! logs, which is what to run after changing how the report is shaped.
//! `geo` converts DB-IP's CSV into the table `ingest` looks addresses
//! up in; it is run when the monthly database is refreshed, not per
//! collection.
//!
//! Exit statuses: 0 done, 1 failed, 2 asked for wrongly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const geo = @import("geo.zig");
const ingest = @import("ingest.zig");
const report = @import("report.zig");
const store_module = @import("store.zig");

const Options = struct {
    logs: []const u8 = "/var/log/caddy",
    database: []const u8 = "/var/lib/luciaos-stats/stats.db",
    out: []const u8 = "",
    geo: []const u8 = "",
    csv: []const u8 = "",
    window: i64 = 90,
    quiet: bool = false,
};

const usage =
    \\usage: luciastats ingest --logs DIR --db FILE --out FILE [--geo FILE] [--window N]
    \\       luciastats report --db FILE --out FILE [--window N]
    \\       luciastats geo    --csv FILE --out FILE
    \\
;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const arguments = try init.args.toSlice(arena);

    if (arguments.len < 2) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const command = arguments[1];

    var options: Options = .{};
    var index: usize = 2;
    while (index < arguments.len) {
        const flag = arguments[index];
        if (std.mem.eql(u8, flag, "--quiet")) {
            options.quiet = true;
            index += 1;
            continue;
        }
        if (index + 1 >= arguments.len) {
            std.debug.print("luciastats: {s} needs a value\n", .{flag});
            return 2;
        }
        const value = arguments[index + 1];
        index += 2;

        if (std.mem.eql(u8, flag, "--logs")) {
            options.logs = value;
        } else if (std.mem.eql(u8, flag, "--db")) {
            options.database = value;
        } else if (std.mem.eql(u8, flag, "--out")) {
            options.out = value;
        } else if (std.mem.eql(u8, flag, "--geo")) {
            options.geo = value;
        } else if (std.mem.eql(u8, flag, "--csv")) {
            options.csv = value;
        } else if (std.mem.eql(u8, flag, "--window")) {
            options.window = std.fmt.parseInt(i64, value, 10) catch {
                std.debug.print("luciastats: --window wants a number of days\n", .{});
                return 2;
            };
        } else {
            std.debug.print("luciastats: unknown option {s}\n", .{flag});
            return 2;
        }
    }

    const run = if (std.mem.eql(u8, command, "ingest"))
        collect(gpa, io, options, true)
    else if (std.mem.eql(u8, command, "report"))
        collect(gpa, io, options, false)
    else if (std.mem.eql(u8, command, "geo"))
        convert(gpa, io, options)
    else {
        std.debug.print("luciastats: unknown command {s}\n{s}", .{ command, usage });
        return 2;
    };

    return run catch |failure| {
        std.debug.print("luciastats: {s}\n", .{@errorName(failure)});
        return 1;
    };
}

fn collect(gpa: Allocator, io: Io, options: Options, read_logs: bool) !u8 {
    if (options.out.len == 0) {
        std.debug.print("luciastats: --out is required\n", .{});
        return 2;
    }

    // SQLite wants a C string, and the database's directory has to
    // exist before it will make the file.
    if (std.fs.path.dirname(options.database)) |directory| {
        try Io.Dir.cwd().createDirPath(io, directory);
    }
    const database = try gpa.dupeZ(u8, options.database);
    defer gpa.free(database);

    var store = try store_module.Store.open(gpa, database);
    defer store.deinit();

    // The run's clock, in whole UTC seconds: what day a line falls on
    // and what "before today" means both come from this one reading.
    const now: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));

    if (read_logs) {
        var table: ?geo.Table = null;
        defer if (table) |*loaded| loaded.deinit();
        if (options.geo.len != 0) {
            table = geo.Table.load(gpa, io, options.geo) catch |failure| found: {
                // A missing or damaged country table costs the map,
                // not the run: every other number is still true.
                std.debug.print("luciastats: no country data ({s}): {s}\n", .{
                    options.geo,
                    @errorName(failure),
                });
                break :found null;
            };
        }

        try store.begin();
        errdefer store.connection.run("ROLLBACK") catch {};
        const summary = try ingest.run(gpa, io, store, table, options.logs, now);
        try store.commit();

        if (!options.quiet) {
            std.debug.print(
                "luciastats: {d} files, {d} lines, {d} requests, {d} other hosts, {d} unreadable\n",
                .{ summary.files, summary.lines, summary.requests, summary.foreign, summary.unreadable },
            );
        }
    }

    try report.write(gpa, io, store, now, .{ .window = options.window }, options.out);
    if (!options.quiet) std.debug.print("luciastats: wrote {s}\n", .{options.out});
    return 0;
}

fn convert(gpa: Allocator, io: Io, options: Options) !u8 {
    if (options.csv.len == 0 or options.out.len == 0) {
        std.debug.print("luciastats: geo needs --csv and --out\n", .{});
        return 2;
    }
    try geo.pack(gpa, io, options.csv, options.out);
    std.debug.print("luciastats: wrote {s}\n", .{options.out});
    return 0;
}

test {
    _ = @import("access.zig");
    _ = @import("classify.zig");
    _ = @import("day.zig");
    _ = @import("geo.zig");
    _ = @import("ingest.zig");
    _ = @import("report.zig");
    _ = @import("sqlite.zig");
    _ = @import("store.zig");
}
