//! The small, local package workflow exposed by `luce package`.
//!
//! A package being authored is ordinary source in a direct child directory
//! of the project (`greet/` beside `main.luc`).  The `.luce/packages/` tree
//! is reserved for installed, versioned copies.  Keeping those two jobs
//! separate makes a package pleasant to edit without changing the resolver's
//! installed-package contract.
//!
//! The registry half is intentionally not guessed at here.  There is no
//! registry endpoint or authentication protocol in this repository, so
//! `publish` validates the package boundary and reports that publishing is
//! unavailable rather than pretending an upload happened.

const std = @import("std");
const files = @import("files");

const Allocator = std.mem.Allocator;

const Project = struct {
    root: []const u8,
    text: []const u8,
    parsed: files.ProjectManifest,
};

pub fn run(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    arguments: []const []const u8,
) !u8 {
    if (arguments.len == 0) return usage(err);

    const subcommand = arguments[0];
    if (std.mem.eql(u8, subcommand, "new")) {
        if (arguments.len < 2 or arguments.len > 3) {
            return refuse(err, "usage: luce package new NAME [VERSION]", .{});
        }
        const version = if (arguments.len == 3) arguments[2] else "0.1.0";
        return create(gpa, io, out, err, arguments[1], version);
    }
    if (std.mem.eql(u8, subcommand, "version")) {
        if (arguments.len != 3) {
            return refuse(err, "usage: luce package version NAME VERSION", .{});
        }
        return versionPackage(gpa, io, out, err, arguments[1], arguments[2]);
    }
    if (std.mem.eql(u8, subcommand, "publish")) {
        if (arguments.len != 2) {
            return refuse(err, "usage: luce package publish NAME", .{});
        }
        return publish(gpa, io, out, err, arguments[1]);
    }
    return refuse(err, "unknown package command {s}", .{subcommand});
}

fn usage(err: *std.Io.Writer) !u8 {
    try err.writeAll(
        "usage:\n" ++
            "  luce package new NAME [VERSION]\n" ++
            "  luce package version NAME VERSION\n" ++
            "  luce package publish NAME\n",
    );
    return 1;
}

fn refuse(err: *std.Io.Writer, comptime format: []const u8, arguments: anytype) !u8 {
    try err.print("luce package: " ++ format ++ "\n", arguments);
    try err.writeAll("run `luce package` for usage\n");
    return 1;
}

fn create(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    name: []const u8,
    version: []const u8,
) !u8 {
    if (!validPackageName(name)) {
        return refuse(err, "{s} is not a valid package name", .{name});
    }
    if (!validVersion(version)) {
        return refuse(err, "{s} is not a valid package version", .{version});
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = (try projectForNew(io, err, arena)) orelse return 1;
    for (project.parsed.packages) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return refuse(err, "package {s} is already listed in the project's packages", .{name});
        }
    }
    for (project.parsed.override) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return refuse(err, "package {s} is already listed in the project's override section", .{name});
        }
    }

    const package_directory = try std.fs.path.join(arena, &.{ project.root, name });
    if (pathExists(io, package_directory)) {
        return refuse(err, "{s}/ already exists; choose another name or remove it first", .{name});
    }
    const root_module = try std.fmt.allocPrint(arena, "{s}.luc", .{name});
    const root_module_path = try std.fs.path.join(arena, &.{ project.root, root_module });
    if (pathExists(io, root_module_path)) {
        return refuse(err, "{s}.luc already exists beside main.luc and would make import {s} ambiguous", .{ name, name });
    }

    const package_manifest_path = try std.fs.path.join(arena, &.{ package_directory, files.manifest_file_name });
    const package_entry_path = try std.fs.path.join(arena, &.{ package_directory, root_module });
    const root_manifest_path = try std.fs.path.join(arena, &.{ project.root, files.manifest_file_name });
    const updated_root = try addPackageWant(gpa, project.text, name, version);
    defer gpa.free(updated_root);

    std.Io.Dir.cwd().createDirPath(io, package_directory) catch |mistake| {
        return refuse(err, "cannot create {s}/: {s}", .{ name, @errorName(mistake) });
    };
    files.writeWhole(io, package_manifest_path, try std.fmt.allocPrint(
        arena,
        "name: {s}\nversion: {s}\n",
        .{ name, version },
    )) catch |mistake| {
        return refuse(err, "cannot write {s}/luce.yaml: {s}", .{ name, @errorName(mistake) });
    };
    files.writeWhole(io, package_entry_path, "# Package entry module. Add declarations here.\n") catch |mistake| {
        return refuse(err, "cannot write {s}/{s}.luc: {s}", .{ name, name, @errorName(mistake) });
    };
    files.writeWhole(io, root_manifest_path, updated_root) catch |mistake| {
        return refuse(err, "cannot update luce.yaml: {s}", .{@errorName(mistake)});
    };

    try out.print("created package {s} {s} in {s}/\n", .{ name, version, name });
    try out.flush();
    return 0;
}

fn versionPackage(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    name: []const u8,
    version: []const u8,
) !u8 {
    if (!validPackageName(name)) {
        return refuse(err, "{s} is not a valid package name", .{name});
    }
    if (!validVersion(version)) {
        return refuse(err, "{s} is not a valid package version", .{version});
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const project = (try governedProject(io, err, arena)) orelse return 1;
    const package_directory = try std.fs.path.join(arena, &.{ project.root, name });
    const package_manifest_path = try std.fs.path.join(arena, &.{ package_directory, files.manifest_file_name });
    const package_text = files.readWhole(arena, io, package_manifest_path) catch |mistake| {
        return refuse(err, "cannot read {s}/luce.yaml: {s}", .{ name, @errorName(mistake) });
    };
    const package_manifest = switch (try files.parseManifest(arena, package_text)) {
        .manifest => |parsed| parsed,
        .refused => |refusal| {
            if (refusal.line == 0) return refuse(err, "{s}/luce.yaml: {s}", .{ name, refusal.reason });
            return refuse(err, "{s}/luce.yaml:{d}: {s}", .{ name, refusal.line, refusal.reason });
        },
    };
    if (!std.mem.eql(u8, package_manifest.name, name)) {
        return refuse(err, "{s}/luce.yaml names package {s}", .{ name, package_manifest.name });
    }

    const package_updated = try replaceTopVersion(gpa, package_text, version);
    defer gpa.free(package_updated);
    const root_updated = if (findPackageWant(project.text, name)) |found| blk: {
        _ = found;
        break :blk try replacePackageWantVersion(gpa, project.text, name, version);
    } else try addPackageWant(gpa, project.text, name, version);
    defer gpa.free(root_updated);

    files.writeWhole(io, package_manifest_path, package_updated) catch |mistake| {
        return refuse(err, "cannot update {s}/luce.yaml: {s}", .{ name, @errorName(mistake) });
    };
    const root_manifest_path = try std.fs.path.join(arena, &.{ project.root, files.manifest_file_name });
    files.writeWhole(io, root_manifest_path, root_updated) catch |mistake| {
        return refuse(err, "cannot update project luce.yaml: {s}", .{@errorName(mistake)});
    };

    try out.print("versioned package {s}: {s} -> {s}\n", .{ name, package_manifest.version, version });
    try out.flush();
    return 0;
}

fn publish(
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    name: []const u8,
) !u8 {
    _ = out;
    if (!validPackageName(name)) {
        return refuse(err, "{s} is not a valid package name", .{name});
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const project = (try governedProject(io, err, arena)) orelse return 1;
    const package_directory = try std.fs.path.join(arena, &.{ project.root, name });
    if (!pathExists(io, package_directory)) {
        return refuse(err, "package {s}/ does not exist in the project source tree", .{name});
    }
    const package_manifest_path = try std.fs.path.join(arena, &.{ package_directory, files.manifest_file_name });
    const package_text = files.readWhole(arena, io, package_manifest_path) catch |mistake| {
        return refuse(err, "cannot read {s}/luce.yaml: {s}", .{ name, @errorName(mistake) });
    };
    const package_manifest = switch (try files.parseManifest(arena, package_text)) {
        .manifest => |parsed| parsed,
        .refused => |refusal| {
            if (refusal.line == 0) return refuse(err, "{s}/luce.yaml: {s}", .{ name, refusal.reason });
            return refuse(err, "{s}/luce.yaml:{d}: {s}", .{ name, refusal.line, refusal.reason });
        },
    };
    if (!std.mem.eql(u8, package_manifest.name, name)) {
        return refuse(err, "{s}/luce.yaml names package {s}", .{ name, package_manifest.name });
    }
    return refuse(
        err,
        "publishing is not available yet; no package registry is configured (package is ready at {s}/)",
        .{package_directory},
    );
}

/// Require a manifest for commands that must edit an existing project.
fn governedProject(
    io: std.Io,
    err: *std.Io.Writer,
    arena: Allocator,
) !?Project {
    const discovered = try files.discoverProject(arena, io, "main.luc");
    return switch (discovered) {
        .governed => |project| try projectContext(io, arena, project),
        .rootless => blk: {
            _ = try refuse(err, "no luce.yaml governs this directory; run `luce package new NAME` to initialize a package in a project", .{});
            break :blk null;
        },
        .refused => |why| blk: {
            _ = try refuse(err, "cannot use this project: {s}", .{why});
            break :blk null;
        },
    };
}

/// `new` is allowed to bootstrap a root manifest when the current directory
/// is still a rootless source tree.  Existing governed projects are left
/// entirely under the caller's control.
fn projectForNew(
    io: std.Io,
    err: *std.Io.Writer,
    arena: Allocator,
) !?Project {
    const discovered = try files.discoverProject(arena, io, "main.luc");
    return switch (discovered) {
        .governed => |project| try projectContext(io, arena, project),
        .rootless => {
            const root = std.process.currentPathAlloc(io, arena) catch |mistake| {
                _ = try refuse(err, "cannot determine the project directory: {s}", .{@errorName(mistake)});
                return null;
            };
            const base = std.fs.path.basename(root);
            const project_name = if (validPackageName(base)) base else "project";
            const text = try std.fmt.allocPrint(arena, "name: {s}\nversion: 0.1.0\n", .{project_name});
            const path = try std.fs.path.join(arena, &.{ root, files.manifest_file_name });
            files.writeWhole(io, path, text) catch |mistake| {
                _ = try refuse(err, "cannot create luce.yaml: {s}", .{@errorName(mistake)});
                return null;
            };
            const parsed = switch (try files.parseManifest(arena, text)) {
                .manifest => |parsed| parsed,
                .refused => unreachable,
            };
            return .{ .root = root, .text = text, .parsed = parsed };
        },
        .refused => |why| blk: {
            _ = try refuse(err, "cannot use this project: {s}", .{why});
            break :blk null;
        },
    };
}

fn projectContext(
    io: std.Io,
    arena: Allocator,
    project: files.Governed,
) !Project {
    const path = try std.fs.path.join(arena, &.{ project.root, files.manifest_file_name });
    const text = files.readWhole(arena, io, path) catch |mistake| return mistake;
    return .{ .root = project.root, .text = text, .parsed = project.manifest };
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn validPackageName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    if (std.mem.eql(u8, name, "std")) return false;
    for (name[1..]) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '_') return false;
    }
    return true;
}

fn validVersion(version: []const u8) bool {
    if (version.len == 0) return false;
    for (version) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '.' and character != '-' and character != '+' and character != '_') return false;
    }
    return true;
}

fn lineKey(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '#') return null;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return std.mem.trimEnd(u8, line[0..colon], " ");
}

fn packageKey(line: []const u8) ?[]const u8 {
    var first = line.len;
    var indent: usize = 0;
    while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
    if (indent == 0) return null;
    const colon = std.mem.indexOfScalarPos(u8, line, indent, ':') orelse return null;
    first = colon;
    return std.mem.trim(u8, line[indent..first], " ");
}

fn addPackageWant(gpa: Allocator, text: []const u8, name: []const u8, version: []const u8) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| try lines.append(gpa, line);

    var packages_line: ?usize = null;
    var insert_at: usize = lines.items.len;
    for (lines.items, 0..) |line, index| {
        if (lineKey(line)) |key| {
            if (std.mem.eql(u8, key, "packages")) {
                packages_line = index;
                continue;
            }
            if (packages_line != null) {
                insert_at = index;
                break;
            }
        }
    }
    if (packages_line == null and lines.items.len != 0 and lines.items[lines.items.len - 1].len == 0) {
        insert_at = lines.items.len - 1;
    }
    const entry = try std.fmt.allocPrint(gpa, "  {s}: {s} path:{s}", .{ name, version, name });
    defer gpa.free(entry);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    for (0..lines.items.len + 1) |index| {
        if (index == insert_at) {
            if (packages_line == null) {
                if (result.items.len != 0 and result.items[result.items.len - 1] != '\n') {
                    try result.append(gpa, '\n');
                }
                try result.appendSlice(gpa, "packages:\n");
            } else if (index == lines.items.len and result.items.len != 0 and result.items[result.items.len - 1] != '\n') {
                try result.append(gpa, '\n');
            }
            try result.appendSlice(gpa, entry);
            try result.append(gpa, '\n');
        }
        if (index < lines.items.len) {
            try result.appendSlice(gpa, lines.items[index]);
            if (index + 1 < lines.items.len) try result.append(gpa, '\n');
        }
    }
    return result.toOwnedSlice(gpa);
}

fn findPackageWant(text: []const u8, name: []const u8) ?void {
    var in_packages = false;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| {
        if (lineKey(line)) |key| {
            in_packages = std.mem.eql(u8, key, "packages");
            continue;
        }
        if (in_packages) {
            if (packageKey(line)) |key| {
                if (std.mem.eql(u8, key, name)) return {};
            }
        }
    }
    return null;
}

fn replaceTopVersion(gpa: Allocator, text: []const u8, version: []const u8) ![]u8 {
    return replaceVersionLines(gpa, text, null, version);
}

fn replacePackageWantVersion(gpa: Allocator, text: []const u8, name: []const u8, version: []const u8) ![]u8 {
    return replaceVersionLines(gpa, text, name, version);
}

fn replaceVersionLines(gpa: Allocator, text: []const u8, package_name: ?[]const u8, version: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    var in_packages = false;
    var replaced = false;
    var split = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (split.next()) |line| {
        if (!first) try result.append(gpa, '\n');
        first = false;
        var match = false;
        if (package_name == null) {
            match = lineKey(line) != null and std.mem.eql(u8, lineKey(line).?, "version");
        } else if (lineKey(line)) |key| {
            in_packages = std.mem.eql(u8, key, "packages");
        } else if (in_packages) if (packageKey(line)) |key| {
            match = std.mem.eql(u8, key, package_name.?);
        };
        if (match and !replaced) {
            const rewritten = try rewriteVersionToken(gpa, line, version);
            defer gpa.free(rewritten);
            try result.appendSlice(gpa, rewritten);
            replaced = true;
        } else {
            try result.appendSlice(gpa, line);
        }
    }
    if (!replaced) return error.PackageVersionNotFound;
    return result.toOwnedSlice(gpa);
}

fn rewriteVersionToken(gpa: Allocator, line: []const u8, version: []const u8) ![]u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.PackageVersionNotFound;
    var value_start = colon + 1;
    while (value_start < line.len and (line[value_start] == ' ' or line[value_start] == '\t')) : (value_start += 1) {}
    var value_end = value_start;
    while (value_end < line.len and line[value_end] != ' ' and line[value_end] != '\t' and line[value_end] != '#') : (value_end += 1) {}
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ line[0..value_start], version, line[value_end..] });
}

test "package manifest edits keep the source path and section order" {
    const gpa = std.testing.allocator;
    const original =
        "name: atlas\n" ++
        "version: 0.1.0\n" ++
        "\n" ++
        "packages:\n" ++
        "  old: 1.0.0\n" ++
        "\n" ++
        "override:\n" ++
        "  pinned: 2.0.0\n";
    const added = try addPackageWant(gpa, original, "new", "0.2.0");
    defer gpa.free(added);
    try std.testing.expect(std.mem.indexOf(u8, added, "  new: 0.2.0 path:new\noverride:") != null);

    const bumped = try replacePackageWantVersion(gpa, added, "new", "0.3.0");
    defer gpa.free(bumped);
    try std.testing.expect(std.mem.indexOf(u8, bumped, "  new: 0.3.0 path:new") != null);
}

test "a package want can be appended to a manifest without a final newline" {
    const gpa = std.testing.allocator;
    const added = try addPackageWant(gpa, "name: atlas\nversion: 0.1.0", "greet", "0.1.0");
    defer gpa.free(added);
    try std.testing.expectEqualStrings(
        "name: atlas\nversion: 0.1.0\npackages:\n  greet: 0.1.0 path:greet\n",
        added,
    );
}
