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

    const run = b.addRunArtifact(tree_bench);
    b.step("run", "Run the element-tree benchmark table").dependOn(&run.step);
}
