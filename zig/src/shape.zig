//! Does C HarfBuzz beat rustybuzz on the same corpus and font?
//!
//! Run 7 found that GPUI on Linux shapes with rustybuzz 0.20.1 (via
//! cosmic-text 0.19), a Rust reimplementation of HarfBuzz, and costs 2 834
//! instructions per character for an uncached `layout_line`. Run 1 had assumed
//! GPUI's text was 2-5x ahead and hard to catch; that assumption was never
//! measured, and the shaping engine turns out not to be a hand-tuned C path.
//!
//! This shapes the byte-identical corpus with the same font through C HarfBuzz
//! and reports instructions per character.
//!
//! VERIFY FIRST. A faster shaper that produces different glyphs is worthless,
//! and run 4 already showed that an unverified fast path reports its own bugs
//! as improvements. `-Dshape-mode=verify` dumps glyph ids and x positions in
//! the same format as the rustybuzz reference so the two can be diffed.
//!
//! Scope, stated plainly: this measures shaping plus glyph-array construction.
//! GPUI's `layout_line` additionally does bidi paragraph analysis, per-character
//! font fallback resolution, and run segmentation. The ratio below is therefore
//! an UPPER BOUND on the shaping difference, not a measurement of it.

const std = @import("std");
const build_options = @import("build_options");
const hb = @import("hb");

const FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
const FONT_SIZE: f64 = 14.0;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Mirrors gpui::ShapedGlyph's measured fields: id, cluster index, x position.
const Glyph = struct {
    index: u32,
    id: u32,
    x: f32,
};

const Shaper = struct {
    blob: *hb.hb_blob_t,
    face: *hb.hb_face_t,
    font: *hb.hb_font_t,
    buf: *hb.hb_buffer_t,
    /// FONT_SIZE / upem. HarfBuzz quantises advances to the scale it is given,
    /// so setting the scale to the design units and converting in f32 avoids
    /// the 1/64 px rounding that `hb_font_set_scale(size * 64)` imposes. Over a
    /// 7 928-glyph line that rounding drifts 60 px away from rustybuzz, which
    /// does the same multiply in floating point.
    px_per_unit: f32,

    fn init(font_bytes: []const u8) !Shaper {
        const blob = hb.hb_blob_create(
            font_bytes.ptr,
            @intCast(font_bytes.len),
            hb.HB_MEMORY_MODE_READONLY,
            null,
            null,
        ) orelse return error.BlobFailed;
        const face = hb.hb_face_create(blob, 0) orelse return error.FaceFailed;
        const font = hb.hb_font_create(face) orelse return error.FontFailed;

        const upem = hb.hb_face_get_upem(face);
        const scale: c_int = @intCast(upem);
        hb.hb_font_set_scale(font, scale, scale);

        const buf = hb.hb_buffer_create() orelse return error.BufferFailed;
        return .{
            .blob = blob,
            .face = face,
            .font = font,
            .buf = buf,
            .px_per_unit = @as(f32, @floatCast(FONT_SIZE)) / @as(f32, @floatFromInt(upem)),
        };
    }

    fn deinit(self: *Shaper) void {
        hb.hb_buffer_destroy(self.buf);
        hb.hb_font_destroy(self.font);
        hb.hb_face_destroy(self.face);
        hb.hb_blob_destroy(self.blob);
    }

    /// One shaping pass over `text`, filling `out` with positioned glyphs.
    /// The buffer is reset rather than recreated, which is the realistic path
    /// for a toolkit that shapes every frame.
    fn shape(self: *Shaper, text: []const u8, out: []Glyph) usize {
        hb.hb_buffer_reset(self.buf);
        hb.hb_buffer_add_utf8(self.buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        hb.hb_buffer_set_direction(self.buf, hb.HB_DIRECTION_LTR);
        hb.hb_buffer_set_script(self.buf, hb.HB_SCRIPT_LATIN);
        hb.hb_buffer_set_language(self.buf, hb.hb_language_from_string("en", 2));

        hb.hb_shape(self.font, self.buf, null, 0);

        var n: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(self.buf, &n);
        const posns = hb.hb_buffer_get_glyph_positions(self.buf, &n);
        const count = @min(@as(usize, n), out.len);

        var x: f32 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            out[i] = .{
                .index = infos[i].cluster,
                .id = infos[i].codepoint,
                .x = x + @as(f32, @floatFromInt(posns[i].x_offset)) * self.px_per_unit,
            };
            x += @as(f32, @floatFromInt(posns[i].x_advance)) * self.px_per_unit;
        }
        return count;
    }
};

/// Zig 0.17 routes the filesystem through `std.Io.Dir` and every call takes an
/// `Io`, the "I/O as an interface" rework that landed in 0.16. `std.fs.cwd()`
/// no longer exists. For a benchmark the single-threaded instance is enough.
fn readAll(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 24));
}

pub fn main() !void {
    var dbg = std.heap.DebugAllocator(.{}).init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    const corpus_path = build_options.corpus;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const corpus = readAll(io, gpa, corpus_path) catch |e| {
        std.debug.print("cannot read corpus {s}: {s}\n", .{ corpus_path, @errorName(e) });
        std.debug.print("run gpui/text/setup.sh and its dump mode first\n", .{});
        return;
    };
    defer gpa.free(corpus);

    const font_bytes = try readAll(io, gpa, FONT_PATH);
    defer gpa.free(font_bytes);

    var shaper = try Shaper.init(font_bytes);
    defer shaper.deinit();

    const glyphs = try gpa.alloc(Glyph, corpus.len + 16);
    defer gpa.free(glyphs);

    const chars = std.unicode.utf8CountCodepoints(corpus) catch corpus.len;

    const mode = build_options.mode;

    if (std.mem.eql(u8, mode, "verify")) {
        const n = shaper.shape(corpus, glyphs);
        // plain buffer: std.ArrayList lost .writer() in 0.17
        const out = try gpa.alloc(u8, n * 40 + 128);
        defer gpa.free(out);
        var off: usize = 0;
        off += (try std.fmt.bufPrint(out[off..], "# shaper=c-harfbuzz font_size={d} glyphs={d}\n", .{ FONT_SIZE, n })).len;
        for (glyphs[0..n]) |g| {
            off += (try std.fmt.bufPrint(out[off..], "{d} {d} {d:.4}\n", .{ g.index, g.id, g.x })).len;
        }
        const path = "harfbuzz.dump";
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out[0..off] });
        std.debug.print("corpus={s} bytes={d} chars={d} glyphs={d}\n", .{
            corpus_path, corpus.len, chars, n,
        });
        std.debug.print("wrote {s}\n", .{path});
        return;
    }

    if (std.mem.eql(u8, mode, "perf")) {
        // silent fixed-iteration runner for perf counters
        var acc: u64 = 0;
        var i: usize = 0;
        while (i < 2000) : (i += 1) acc +%= shaper.shape(corpus, glyphs);
        std.mem.doNotOptimizeAway(&acc);
        return;
    }

    // default: timed report
    var w: usize = 0;
    while (w < 50) : (w += 1) _ = shaper.shape(corpus, glyphs);

    const iters = 2000;
    var best: u64 = std.math.maxInt(u64);
    var sum: u64 = 0;
    var n_glyphs: usize = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        n_glyphs = shaper.shape(corpus, glyphs);
        const dt = nowNs() - t0;
        sum += dt;
        if (dt < best) best = dt;
    }
    const mean = sum / iters;

    std.debug.print("corpus={s}\n", .{corpus_path});
    std.debug.print("  bytes={d} chars={d} glyphs={d}\n", .{ corpus.len, chars, n_glyphs });
    std.debug.print("  mean {d} ns/call, best {d} ns/call\n", .{ mean, best });
    std.debug.print("  mean {d:.1} ns/char, best {d:.1} ns/char\n", .{
        @as(f64, @floatFromInt(mean)) / @as(f64, @floatFromInt(chars)),
        @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(chars)),
    });
}
