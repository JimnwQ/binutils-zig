const std = @import("std");

pub const LinkerStep = struct {
    pub const Self = @This();

    const Build = std.Build;
    const Step = Build.Step;

    step: Step,
    targets: std.ArrayList(Build.FileSource),
    output: Build.GeneratedFile,

    args: std.ArrayList([]const u8),
    defsyms: std.ArrayList(DefSym),
    linkerscript: ?Build.FileSource = null,
    outname: []const u8,

    const DefSym = struct {
        sym: []const u8,
        val: []const u8,
    };

    pub fn create(owner: *Build, targets: []const Build.FileSource, outname: []const u8) *Self {
        const self = owner.allocator.create(Self) catch @panic("OOM");
        self.* = Self{
            .step = Step.init(.{
                .id = .custom,
                .name = std.fmt.allocPrint(owner.allocator, "Link {s}", .{outname}) catch @panic("OOM"),
                .owner = owner,
                .makeFn = make,
            }),
            .targets = std.ArrayList(Build.FileSource).fromOwnedSlice(owner.allocator, owner.allocator.dupe(Build.FileSource, targets) catch @panic("OOM")),
            .output = Build.GeneratedFile{ .step = &self.step },
            .args = std.ArrayList([]const u8).init(owner.allocator),
            .defsyms = std.ArrayList(DefSym).init(owner.allocator),
            .outname = owner.allocator.dupe(u8, outname) catch @panic("OOM"),
        };

        for (targets) |target| {
            switch (target) {
                .generated => |g| self.step.dependOn(g.step),
                .path => {},
            }
        }

        return self;
    }

    pub fn addDefsym(self: *Self, s: []const u8, v: anytype) void {
        const T = @TypeOf(v);
        const fmt = if (@typeInfo(T) == .Pointer) "{s}" else "{}";
        const b = self.step.owner;
        self.defsyms.append(.{
            .sym = b.allocator.dupe(u8, s) catch @panic("OOM"),
            .val = std.fmt.allocPrint(b.allocator, fmt, .{v}) catch @panic("OOM"),
        }) catch @panic("OOM");
    }

    pub fn addArg(self: *Self, arg: []const u8) void {
        self.args.append(arg) catch @panic("OOM");
    }

    pub fn setLinkerScript(self: *Self, script: Build.FileSource) void {
        self.linkerscript = script;
        switch (script) {
            .path => {},
            .generated => |g| self.step.dependOn(g.step),
        }
    }

    pub fn getOutputSource(self: *Self) Build.FileSource {
        return Build.FileSource{ .generated = &self.output };
    }

    fn make(step: *Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(Self, "step", step);
        const b = step.owner;
        const arena = b.allocator;

        var man = b.cache.obtain();
        defer man.deinit();

        var argv = std.ArrayList([]const u8).init(arena);
        try argv.append("ld");

        try argv.append("-o");
        try argv.append("");
        const output_placeholder = argv.items.len - 1;
        man.hash.addBytes(self.outname);

        if (self.linkerscript) |script| {
            const path = script.getPath(b);
            try argv.append("-T");
            try argv.append(path);

            man.hash.addBytes(path);
            _ = try man.addFile(path, null);
        }

        for (self.defsyms.items) |defsym| {
            try argv.append("--defsym");
            const arg = try std.fmt.allocPrint(arena, "{s}={s}", .{ defsym.sym, defsym.val });
            try argv.append(arg);
            man.hash.addBytes(arg);
        }

        for (self.args.items) |arg| {
            try argv.append(arg);
            man.hash.addBytes(arg);
        }

        for (self.targets.items) |target| {
            const targetpath = target.getPath(b);
            try argv.append(targetpath);
            man.hash.addBytes(targetpath);
            _ = try man.addFile(targetpath, null);
        }

        _ = try step.cacheHit(&man);

        const digest = man.final();
        const outpath = try b.cache_root.join(arena, &.{ "o", &digest, self.outname });
        self.output.path = outpath;

        if (step.result_cached) {
            return;
        }

        argv.items[output_placeholder] = outpath;
        const output_subdirpath = std.fs.path.dirname(outpath).?;
        b.cache_root.handle.makePath(output_subdirpath) catch |err| {
            return step.fail("unable to make path '{}{s}': {s}", .{
                b.cache_root, output_subdirpath, @errorName(err),
            });
        };

        try Step.handleVerbose(b, b.build_root.path, argv.items);
        var child_process = std.ChildProcess.init(argv.items, arena);
        const retcode = try child_process.spawnAndWait();
        switch (retcode) {
            .Exited => |code| if (code == 0) {
                try step.writeManifest(&man);
                return;
            },
            else => {},
        }

        return step.fail("Linker failed", .{});
    }
};

pub const ObjcopyStep = struct {
    pub const Self = @This();

    const Build = std.Build;
    const Step = Build.Step;

    step: Step,
    target: Build.FileSource,
    outname: []const u8,
    output: Build.GeneratedFile,

    args: std.ArrayList([]const u8),

    pub fn create(owner: *Build, target: Build.FileSource, outname: []const u8) *Self {
        const self = owner.allocator.create(Self) catch @panic("OOM");
        self.* = Self{
            .step = Step.init(.{
                .id = .custom,
                .name = std.fmt.allocPrint(owner.allocator, "Objcopy {s}", .{target.getDisplayName()}) catch @panic("OOM"),
                .owner = owner,
                .makeFn = make,
            }),
            .target = target,
            .outname = owner.allocator.dupe(u8, outname) catch @panic("OOM"),
            .output = Build.GeneratedFile{ .step = &self.step },

            .args = std.ArrayList([]const u8).init(owner.allocator),
        };

        switch (target) {
            .generated => |g| self.step.dependOn(g.step),
            .path => {},
        }

        return self;
    }

    pub fn addArg(self: *Self, arg: []const u8) void {
        self.args.append(arg) catch @panic("OOM");
    }

    pub fn getOutputSource(self: *Self) Build.FileSource {
        return Build.FileSource{ .generated = &self.output };
    }

    fn make(step: *Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(Self, "step", step);
        const b = step.owner;
        const arena = b.allocator;

        var man = b.cache.obtain();
        defer man.deinit();

        var argv = std.ArrayList([]const u8).init(arena);
        try argv.append("objcopy");

        for (self.args.items) |arg| {
            try argv.append(arg);
            man.hash.addBytes(arg);
        }

        const targetpath = self.target.getPath(b);
        try argv.append(targetpath);
        man.hash.addBytes(targetpath);
        _ = try man.addFile(targetpath, null);

        man.hash.addBytes(self.outname);

        _ = try step.cacheHit(&man);

        const digest = man.final();
        const outpath = try b.cache_root.join(arena, &.{ "o", &digest, self.outname });
        self.output.path = outpath;

        if (step.result_cached) {
            return;
        }

        try argv.append(outpath);

        const output_subdirpath = std.fs.path.dirname(outpath).?;
        b.cache_root.handle.makePath(output_subdirpath) catch |err| {
            return step.fail("unable to make path '{}{s}': {s}", .{
                b.cache_root, output_subdirpath, @errorName(err),
            });
        };

        try Step.handleVerbose(b, b.build_root.path, argv.items);
        var child_process = std.ChildProcess.init(argv.items, arena);
        const retcode = try child_process.spawnAndWait();
        switch (retcode) {
            .Exited => |code| if (code == 0) {
                try step.writeManifest(&man);
                return;
            },
            else => {},
        }

        return step.fail("Objcopy failed", .{});
    }
};

pub const AssemblerStep = struct {
    pub const Self = @This();

    const Build = std.Build;
    const Step = Build.Step;

    step: Step,
    target: Build.FileSource,
    output: Build.GeneratedFile,

    args: std.ArrayList([]const u8),
    defsyms: std.ArrayList(DefSym),

    const DefSym = struct {
        sym: []const u8,
        val: []const u8,
    };

    pub fn create(owner: *Build, target: Build.FileSource) *Self {
        const self = owner.allocator.create(Self) catch @panic("OOM");
        self.* = Self{
            .step = Step.init(.{
                .id = .custom,
                .name = std.fmt.allocPrint(owner.allocator, "Assemble {s}", .{target.getDisplayName()}) catch @panic("OOM"),
                .owner = owner,
                .makeFn = make,
            }),
            .target = target,
            .output = Build.GeneratedFile{ .step = &self.step },

            .args = std.ArrayList([]const u8).init(owner.allocator),
            .defsyms = std.ArrayList(DefSym).init(owner.allocator),
        };

        switch (target) {
            .generated => |g| self.step.dependOn(g.step),
            .path => {},
        }

        return self;
    }

    pub fn addDefsym(self: *Self, s: []const u8, v: anytype) void {
        const T = @TypeOf(v);
        const fmt = if (@typeInfo(T) == .Pointer) "{s}" else "{}";
        const b = self.step.owner;
        self.defsyms.append(.{
            .sym = b.allocator.dupe(u8, s) catch @panic("OOM"),
            .val = std.fmt.allocPrint(b.allocator, fmt, .{v}) catch @panic("OOM"),
        }) catch @panic("OOM");
    }

    pub fn addArg(self: *Self, arg: []const u8) void {
        self.args.append(arg) catch @panic("OOM");
    }

    pub fn getOutputSource(self: *Self) Build.FileSource {
        return Build.FileSource{ .generated = &self.output };
    }

    fn make(step: *Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(Self, "step", step);
        const b = step.owner;
        const arena = b.allocator;

        var man = b.cache.obtain();
        defer man.deinit();

        var argv = std.ArrayList([]const u8).init(arena);
        try argv.append("as");

        const targetpath = self.target.getPath(b);
        const basename = std.fs.path.basename(targetpath);
        const outname = try std.fmt.allocPrint(arena, "{s}.o", .{basename});

        try argv.append("-o");
        try argv.append("");
        const output_placeholder = argv.items.len - 1;
        man.hash.addBytes(outname);

        for (self.defsyms.items) |defsym| {
            try argv.append("--defsym");
            const arg = try std.fmt.allocPrint(arena, "{s}={s}", .{ defsym.sym, defsym.val });
            try argv.append(arg);
            man.hash.addBytes(arg);
        }

        for (self.args.items) |arg| {
            try argv.append(arg);
            man.hash.addBytes(arg);
        }

        try argv.append(targetpath);
        man.hash.addBytes(targetpath);
        _ = try man.addFile(targetpath, null);

        _ = try step.cacheHit(&man);

        const digest = man.final();
        const outpath = try b.cache_root.join(arena, &.{
            "o", &digest, outname,
        });
        self.output.path = outpath;

        if (step.result_cached) {
            return;
        }

        argv.items[output_placeholder] = outpath;
        const output_subdirpath = std.fs.path.dirname(outpath).?;
        b.cache_root.handle.makePath(output_subdirpath) catch |err| {
            return step.fail("unable to make path '{}{s}': {s}", .{
                b.cache_root, output_subdirpath, @errorName(err),
            });
        };

        try Step.handleVerbose(b, b.build_root.path, argv.items);
        var child_process = std.ChildProcess.init(argv.items, arena);
        const retcode = try child_process.spawnAndWait();
        switch (retcode) {
            .Exited => |code| if (code == 0) {
                try step.writeManifest(&man);
                return;
            },
            else => {},
        }

        return step.fail("Assembler failed", .{});
    }
};
