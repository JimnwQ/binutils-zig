const std = @import("std");

pub const DDStep = struct {
    pub const Self = @This();

    const Build = std.Build;
    const Step = Build.Step;

    step: Step,
    global_args: std.ArrayList([]const u8),
    commands: std.ArrayList(Command),
    output: Build.GeneratedFile,

    outname: []const u8,

    const Input = union(enum) {
        source: Build.FileSource,
        path: []const u8,
    };

    const Command = struct {
        file: Input,
        args: std.ArrayList([]const u8),
    };

    pub fn create(owner: *Build, outname: []const u8) *Self {
        const self = owner.allocator.create(Self) catch @panic("OOM");
        self.* = Self{
            .step = Step.init(.{
                .id = .custom,
                .name = std.fmt.allocPrint(owner.allocator, "dd to {s}", .{outname}) catch @panic("OOM"),
                .owner = owner,
                .makeFn = make,
            }),
            .global_args = std.ArrayList([]const u8).init(owner.allocator),
            .commands = std.ArrayList(Command).init(owner.allocator),
            .output = Build.GeneratedFile{ .step = &self.step },

            .outname = owner.allocator.dupe(u8, outname) catch @panic("OOM"),
        };

        return self;
    }

    pub fn addOption(self: *Self, lhs: []const u8, rhs: anytype) void {
        const T = @TypeOf(rhs);
        const fmt = if (@typeInfo(T) == .Pointer) "{s}" else "{}";
        const b = self.step.owner;
        const arg = std.fmt.allocPrint(b.allocator, "{s}=" ++ fmt, .{ lhs, rhs }) catch @panic("OOM");
        if (self.commands.items.len == 0) {
            self.global_args.append(arg) catch @panic("OOM");
            return;
        }

        self.commands.items[self.commands.items.len - 1].args.append(arg) catch @panic("OOM");
    }

    pub fn addInputSource(self: *Self, source: Build.FileSource) void {
        switch (source) {
            .generated => |g| self.step.dependOn(g.step),
            .path => {},
        }

        self.commands.append(.{
            .file = .{ .source = source },
            .args = std.ArrayList([]const u8).init(self.step.owner.allocator),
        }) catch @panic("OOM");
    }

    pub fn addInputPath(self: *Self, path: []const u8) void {
        self.commands.append(.{
            .file = .{ .path = path },
            .args = std.ArrayList([]const u8).init(self.step.owner.allocator),
        }) catch @panic("OOM");
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

        var argvs = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(arena, self.commands.items.len);
        try argvs.resize(self.commands.items.len);

        for (self.commands.items, argvs.items) |command, *argv| {
            argv.* = std.ArrayList([]const u8).init(arena);
            try argv.append("dd");

            for (self.global_args.items) |arg| {
                try argv.append(arg);
                man.hash.addBytes(arg);
            }

            for (command.args.items) |arg| {
                try argv.append(arg);
                man.hash.addBytes(arg);
            }

            switch (command.file) {
                .path => |path| {
                    try argv.append(try std.fmt.allocPrint(arena, "if={s}", .{path}));
                    man.hash.addBytes(path);
                },
                .source => |source| {
                    const targetpath = source.getPath(b);
                    try argv.append(try std.fmt.allocPrint(arena, "if={s}", .{targetpath}));
                    man.hash.addBytes(targetpath);
                    _ = try man.addFile(targetpath, null);
                },
            }

            man.hash.addBytes(self.outname);
        }

        _ = try step.cacheHit(&man);

        const digest = man.final();
        const outpath = try b.cache_root.join(arena, &.{ "o", &digest, self.outname });
        self.output.path = outpath;

        if (step.result_cached) {
            return;
        }

        for (argvs.items) |*argv|
            try argv.append(try std.fmt.allocPrint(arena, "of={s}", .{outpath}));

        const output_subdirpath = std.fs.path.dirname(outpath).?;
        b.cache_root.handle.makePath(output_subdirpath) catch |err| {
            return step.fail("unable to make path '{}{s}': {s}", .{
                b.cache_root, output_subdirpath, @errorName(err),
            });
        };

        for (argvs.items) |*argv| {
            try Step.handleVerbose(b, b.build_root.path, argv.items);
            var child_process = std.ChildProcess.init(argv.items, arena);
            const retcode = try child_process.spawnAndWait();
            switch (retcode) {
                .Exited => |code| {
                    if (code == 0) {
                        continue;
                    } else {
                        return step.fail("dd exited with return code {d}", .{code});
                    }
                },
                else => return step.fail("dd exited with {s}", .{@tagName(retcode)}),
            }
        }

        try step.writeManifest(&man);
    }
};
