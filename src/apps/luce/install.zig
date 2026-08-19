//! `luce install` — fill the store from the manifest's own rows
//! (docs/BUILD.md phase B).
//!
//! The manifest is the whole instruction: a want row that states
//! `url:` can be fetched, and a fetched row **must** state `sha256:` —
//! an unverifiable download is refused, not warned about.  The hash is
//! the same tree hash the resolver already verifies
//! (`files.hashPackageDirectory`), so one key means one thing: the
//! archive is unpacked into a staging directory, the staging tree is
//! hashed, and only a tree that matches is renamed into
//! `.luce/packages/NAME-VERSION/` — write-then-rename, so a killed
//! install never leaves half a package where the resolver probes.
//!
//! Install is idempotent, `make_directory`'s rule: a row already
//! satisfied by the store is verified and reported, never re-fetched.
//! `https` is required everywhere except the loopback host, which is
//! how the product test serves a real archive without owning a
//! certificate authority.

const std = @import("std");

const files = @import("files");

const Allocator = std.mem.Allocator;

pub fn run(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    arguments: []const []const u8,
) !u8 {
    if (arguments.len != 0) {
        return refuse(err, "install takes no arguments; the manifest's want list says everything", .{});
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const governed = switch (try files.discoverProject(arena, io, ".")) {
        .rootless => return refuse(
            err,
            "install needs a project: no luce.yaml governs this directory",
            .{},
        ),
        .refused => |reason| return refuse(err, "{s}", .{reason}),
        .governed => |governing| governing,
    };

    if (governed.manifest.packages.len == 0) {
        try out.print("nothing to install: {s} wants no packages\n", .{governed.manifest.name});
        try out.flush();
        return 0;
    }

    for (governed.manifest.packages) |row| {
        const status = try place(gpa, io, arena, governed.root, row, err);
        switch (status) {
            .refused => return 1,
            .development => try out.print("{s} {s}: development path:{s} — nothing to install\n", .{
                row.name, row.version, row.path.?,
            }),
            .already => try out.print("{s} {s}: already installed\n", .{ row.name, row.version }),
            .installed => try out.print("installed {s} {s}\n", .{ row.name, row.version }),
        }
    }
    try out.flush();
    return 0;
}

const Placed = enum { refused, development, already, installed };

/// Bring one want row to its installed state, or say why not.
fn place(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    root: []const u8,
    row: files.ManifestEntry,
    err: *std.Io.Writer,
) !Placed {
    if (row.path != null) return .development;

    const store = try std.fs.path.join(arena, &.{ root, ".luce", "packages" });
    const bundle = try std.fmt.allocPrint(arena, "{s}-{s}", .{ row.name, row.version });
    const settled = try std.fs.path.join(arena, &.{ store, bundle });

    // Already in the store: verify when the row says how, and leave it.
    if (std.Io.Dir.cwd().statFile(io, settled, .{})) |told| {
        if (told.kind != .directory) {
            _ = try refuse(err, "{s} is not a directory; move it aside", .{settled});
            return .refused;
        }
        if (row.sha256) |stated| {
            if (try mismatch(io, arena, settled, stated, err, row)) return .refused;
        }
        return .already;
    } else |_| {}

    const from = row.url orelse {
        _ = try refuse(
            err,
            "package {s} {s} is not in the store and names no url: to fetch from; add one, or vendor it under .luce/packages/{s}",
            .{ row.name, row.version, bundle },
        );
        return .refused;
    };
    const stated = row.sha256 orelse {
        _ = try refuse(
            err,
            "package {s} {s} names url: but no sha256:; an unverifiable fetch is refused",
            .{ row.name, row.version },
        );
        return .refused;
    };
    if (!isHexDigest(stated)) {
        _ = try refuse(
            err,
            "package {s} {s}: sha256:{s} is not a sha256 hash; the value is 64 hex digits",
            .{ row.name, row.version, stated },
        );
        return .refused;
    }
    if (!allowedOrigin(from)) {
        _ = try refuse(
            err,
            "package {s} {s}: url:{s} is not https; only the loopback host may be fetched over http",
            .{ row.name, row.version, from },
        );
        return .refused;
    }

    // Fetch the archive whole.  The staging tree and the temporary
    // archive both live under `.luce/`, so the final rename cannot
    // cross a filesystem.
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const fetched = client.fetch(.{
        .location = .{ .url = from },
        .response_writer = &body.writer,
    }) catch |mistake| {
        _ = try refuse(
            err,
            "package {s} {s}: {s} could not be fetched: {s}",
            .{ row.name, row.version, from, @errorName(mistake) },
        );
        return .refused;
    };
    if (fetched.status != .ok) {
        _ = try refuse(
            err,
            "package {s} {s}: {s} answered {d} {s}",
            .{ row.name, row.version, from, @intFromEnum(fetched.status), fetched.status.phrase() orelse "" },
        );
        return .refused;
    }

    try std.Io.Dir.cwd().createDirPath(io, store);
    const held = try std.fmt.allocPrint(arena, "{s}.fetched.zip", .{settled});
    const staging = try std.fmt.allocPrint(arena, "{s}.staging", .{settled});
    // A prior interrupted install may have left either behind; a fresh
    // start is the only honest one.
    std.Io.Dir.cwd().deleteFile(io, held) catch {};
    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, held) catch {};
    errdefer std.Io.Dir.cwd().deleteTree(io, staging) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = held, .data = body.written() });
    if (try unpack(io, err, row, held, staging)) return .refused;

    // The staging tree must hash to the manifest's word and carry the
    // identity the directory name claims, or nothing lands.
    if (try mismatch(io, arena, staging, stated, err, row)) {
        std.Io.Dir.cwd().deleteTree(io, staging) catch {};
        return .refused;
    }
    if (try foreignIdentity(io, arena, staging, row, err)) {
        std.Io.Dir.cwd().deleteTree(io, staging) catch {};
        return .refused;
    }

    const cwd = std.Io.Dir.cwd();
    cwd.rename(staging, cwd, settled, io) catch |mistake| {
        _ = try refuse(
            err,
            "package {s} {s}: the verified tree could not move into the store: {s}",
            .{ row.name, row.version, @errorName(mistake) },
        );
        std.Io.Dir.cwd().deleteTree(io, staging) catch {};
        return .refused;
    };
    return .installed;
}

/// Extract the fetched archive into the staging directory, answering
/// whether that failed.  Extraction refuses paths that escape the
/// destination (`std.zip` normalizes and rejects them), so a hostile
/// archive cannot write outside `.luce/`.
fn unpack(
    io: std.Io,
    err: *std.Io.Writer,
    row: files.ManifestEntry,
    held: []const u8,
    staging: []const u8,
) !bool {
    try std.Io.Dir.cwd().createDirPath(io, staging);
    var archive = std.Io.Dir.cwd().openFile(io, held, .{}) catch |mistake| {
        _ = try refuse(err, "package {s} {s}: the fetched archive cannot be reopened: {s}", .{
            row.name, row.version, @errorName(mistake),
        });
        return true;
    };
    defer archive.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = archive.reader(io, &buffer);
    var destination = std.Io.Dir.cwd().openDir(io, staging, .{}) catch |mistake| {
        _ = try refuse(err, "package {s} {s}: the staging directory cannot be opened: {s}", .{
            row.name, row.version, @errorName(mistake),
        });
        return true;
    };
    defer destination.close(io);
    std.zip.extract(destination, &reader, .{}) catch |mistake| {
        _ = try refuse(err, "package {s} {s}: the archive is not a zip this tool reads: {s}", .{
            row.name, row.version, @errorName(mistake),
        });
        return true;
    };
    return false;
}

/// Hash the directory and compare it to the manifest's word, answering
/// whether they disagree (and saying so when they do).
fn mismatch(
    io: std.Io,
    arena: Allocator,
    directory: []const u8,
    stated: []const u8,
    err: *std.Io.Writer,
    row: files.ManifestEntry,
) !bool {
    if (!isHexDigest(stated)) {
        _ = try refuse(err, "package {s} {s}: sha256:{s} is not a sha256 hash; the value is 64 hex digits", .{
            row.name, row.version, stated,
        });
        return true;
    }
    const computed = files.hashPackageDirectory(io, arena, directory) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unreadable => {
            _ = try refuse(err, "package {s} {s} at {s} cannot be hashed: a file in it cannot be read", .{
                row.name, row.version, directory,
            });
            return true;
        },
    };
    if (!std.ascii.eqlIgnoreCase(&computed, stated)) {
        _ = try refuse(err, "package {s} {s} does not match its stated hash: luce.yaml says sha256:{s}, the tree hashes to sha256:{s}; nothing was installed", .{
            row.name, row.version, stated, &computed,
        });
        return true;
    }
    return false;
}

/// Check the unpacked package's own `luce.yaml` against the identity
/// the want row claims, answering whether they disagree.
fn foreignIdentity(
    io: std.Io,
    arena: Allocator,
    staging: []const u8,
    row: files.ManifestEntry,
    err: *std.Io.Writer,
) !bool {
    const inner_path = try std.fs.path.join(arena, &.{ staging, files.manifest_file_name });
    const text = std.Io.Dir.cwd().readFileAlloc(io, inner_path, arena, .limited(1024 * 1024)) catch {
        _ = try refuse(err, "package {s} {s}: the archive carries no readable {s}", .{
            row.name, row.version, files.manifest_file_name,
        });
        return true;
    };
    const inner = switch (try files.parseManifest(arena, text)) {
        .manifest => |parsed| parsed,
        .refused => |refusal| {
            _ = try refuse(err, "package {s} {s}: its own {s} is not a manifest: {s}", .{
                row.name, row.version, files.manifest_file_name, refusal.reason,
            });
            return true;
        },
    };
    if (!std.mem.eql(u8, inner.name, row.name) or !std.mem.eql(u8, inner.version, row.version)) {
        _ = try refuse(err, "package {s} {s}: the archive says it is {s} {s}; nothing was installed", .{
            row.name, row.version, inner.name, inner.version,
        });
        return true;
    }
    return false;
}

/// `https:` anywhere; `http:` only to the machine itself — the
/// loopback exemption that lets a test serve a real archive.
fn allowedOrigin(url: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(url, "https://")) return true;
    if (!std.ascii.startsWithIgnoreCase(url, "http://")) return false;
    const rest = url["http://".len..];
    const authority = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
    const host = host: {
        if (std.mem.startsWith(u8, authority, "[")) {
            const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
            break :host authority[1..close];
        }
        break :host authority[0 .. std.mem.lastIndexOfScalar(u8, authority, ':') orelse authority.len];
    };
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "::1");
}

fn isHexDigest(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |character| {
        if (!std.ascii.isHex(character)) return false;
    }
    return true;
}

fn refuse(err: *std.Io.Writer, comptime format: []const u8, arguments: anytype) !u8 {
    try err.print("luce install: " ++ format ++ "\n", arguments);
    return 1;
}

// ---------------------------------------------------------------------------
// Tests — the pure rules; the fetch itself is proved by the product test
// ---------------------------------------------------------------------------

const testing = std.testing;

test "https is allowed anywhere and http only on the loopback" {
    try testing.expect(allowedOrigin("https://pkg.example.com/geo-1.2.0.zip"));
    try testing.expect(allowedOrigin("http://127.0.0.1:8080/geo.zip"));
    try testing.expect(allowedOrigin("http://localhost/geo.zip"));
    try testing.expect(allowedOrigin("http://[::1]:9000/geo.zip"));
    try testing.expect(!allowedOrigin("http://pkg.example.com/geo.zip"));
    try testing.expect(!allowedOrigin("http://127.0.0.1.evil.com/geo.zip"));
    try testing.expect(!allowedOrigin("ftp://127.0.0.1/geo.zip"));
}

test "a digest is 64 hex digits and nothing else" {
    try testing.expect(isHexDigest("ab" ** 32));
    try testing.expect(!isHexDigest("ab" ** 31));
    try testing.expect(!isHexDigest("zz" ** 32));
}
