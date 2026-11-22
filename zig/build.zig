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

    // Run 9: the same change classes under REAL flexbox -- shrink, min/max
    // freeze loop, wrap, justify-content, baseline alignment. Separate file so
    // runs 2-8 stay reproducible against the original model.
    const flex_profile = b.option([]const u8, "flex-profile", "legacy|css-default|css-wrap") orelse "css-default";
    const flex_opts = b.addOptions();
    flex_opts.addOption([]const u8, "scenario", perf);
    flex_opts.addOption([]const u8, "profile", flex_profile);

    const inc_flex_mod = b.createModule(.{
        .root_source_file = b.path("src/incremental_flex.zig"),
        .target = target,
        .optimize = optimize,
    });
    inc_flex_mod.addOptions("build_options", flex_opts);
    const inc_flex = b.addExecutable(.{
        .name = "incremental_flex",
        .root_module = inc_flex_mod,
    });
    b.installArtifact(inc_flex);

    // Is a persistently-mapped quad buffer necessary? Writes into real
    // GPU-visible memory via Vulkan. Needs the Vulkan loader and headers.
    // @cImport was removed in Zig 0.17, so the C header is translated as a
    // build step and imported as a module.
    const vk_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/vk.h"),
        .target = target,
        .optimize = optimize,
    });
    const quadbuf_mod = b.createModule(.{
        .root_source_file = b.path("src/quadbuf.zig"),
        .target = target,
        .optimize = optimize,
    });
    quadbuf_mod.addImport("vk", vk_translate.createModule());
    quadbuf_mod.link_libc = true;
    quadbuf_mod.linkSystemLibrary("vulkan", .{});
    const quadbuf = b.addExecutable(.{
        .name = "quadbuf",
        .root_module = quadbuf_mod,
    });
    b.installArtifact(quadbuf);

    // C HarfBuzz shaping, against the rustybuzz reference from run 7.
    const shape_mode = b.option([]const u8, "shape-mode", "report|verify|perf") orelse "report";
    const corpus = b.option([]const u8, "corpus", "path to the corpus file") orelse
        "../gpui/text/ref/corpus_no_fallback.txt";
    const shape_opts = b.addOptions();
    shape_opts.addOption([]const u8, "mode", shape_mode);
    shape_opts.addOption([]const u8, "corpus", corpus);

    const hb_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/hb.h"),
        .target = target,
        .optimize = optimize,
    });
    hb_translate.addIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });

    const shape_mod = b.createModule(.{
        .root_source_file = b.path("src/shape.zig"),
        .target = target,
        .optimize = optimize,
    });
    shape_mod.addImport("hb", hb_translate.createModule());
    shape_mod.addOptions("build_options", shape_opts);
    shape_mod.link_libc = true;
    shape_mod.linkSystemLibrary("harfbuzz", .{});
    const shape = b.addExecutable(.{ .name = "shape", .root_module = shape_mod });
    b.installArtifact(shape);

    const run = b.addRunArtifact(tree_bench);
    b.step("run", "Run the element-tree benchmark table").dependOn(&run.step);
}
