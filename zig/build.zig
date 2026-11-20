const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Full table across topologies and element counts.
    const tree_bench = b.addExecutable(.{
        .name = "tree_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tree_bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(tree_bench);

    // One configuration (wide/2048), silent, so perf counters divide by iters.
    const single = b.addExecutable(.{
        .name = "single",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/single.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(single);


    // Element-level incremental rebuild across GPUI's change classes.
    // -Dperf=<scenario> builds a silent single-scenario runner so that perf
    // counters divide cleanly by iteration count. Selected at comptime because
    // Zig 0.16 made both process arguments and environment variables
    // non-global, and 0.17 reworked the argument API again.
    const perf = b.option([]const u8, "perf", "silent single-scenario runner: full|unchanged|leaf-style|leaf-bounds") orelse "none";
    const perf_opts = b.addOptions();
    perf_opts.addOption([]const u8, "scenario", perf);

    const incremental_mod = b.createModule(.{
        .root_source_file = b.path("src/incremental.zig"),
        .target = target,
        .optimize = optimize,
    });
    incremental_mod.addOptions("build_options", perf_opts);
    const incremental = b.addExecutable(.{
        .name = "incremental",
        .root_module = incremental_mod,
    });
    b.installArtifact(incremental);

    const run = b.addRunArtifact(tree_bench);
    b.step("run", "Run the element-tree benchmark table").dependOn(&run.step);
}
