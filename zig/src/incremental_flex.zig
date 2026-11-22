//! Run 9: does element-level memoisation survive REAL flexbox?
//!
//! Runs 2-5 measured per-element dirty tracking against a deliberately small
//! layout model: three size modes, one padding scalar, no wrap, no min/max, no
//! alignment, no shrink. On that model an `unchanged` frame cost 15 ns and a
//! `leaf_bounds` frame stayed local. The headline 23-46x CPU figure in
//! RESULTS.md rests on it.
//!
//! That model is not flexbox, and the gap was never in the toolkit's favour.
//! Real flexbox has at least five mechanisms that each destroy the assumption
//! that a child's change is local to that child:
//!
//!   1. flex-shrink. CSS defaults to `flex: 0 1 auto` -- EVERY item shrinks.
//!      Once a line overflows, one child growing redistributes size across all
//!      of its siblings. `any_grow_main` from run 4 does not see this at all.
//!   2. min/max clamping. Resolving flexible lengths is an iterative freeze
//!      loop (CSS 9.7): clamping one item frees space that must be redistributed
//!      among the rest, so the cost is passes x items, not items.
//!   3. flex-wrap. A size change can move an item to another line, which moves
//!      every later item and changes the container's cross size.
//!   4. justify-content other than flex-start. With space-between or center,
//!      every child's position depends on the total main size, so EARLIER
//!      siblings move too. Run 4's `repositionFrom` early-break is invalid.
//!   5. baseline alignment. Cross positions depend on the maximum baseline
//!      across the line, so one child's baseline change moves the others.
//!
//! This file implements all five and re-measures. The question is not whether
//! the win shrinks -- it must -- but whether what is left still justifies the
//! project.
//!
//! `incremental.zig` is left untouched so runs 2-8 stay reproducible. The
//! duplication is deliberate: in a benchmark repo a stable artefact is worth
//! more than a shared one, and the diff between the two files is the record of
//! what changed.
//!
//! Verification is unchanged and non-negotiable. Run 4 produced two fast-path
//! bugs that each reported themselves as a 2x improvement; `verifyLayout`
//! caught both by recomputing the whole layout and comparing. Every counter is
//! still asserted every frame.
//!
//! KNOWN UNDERSTATEMENT, stated here rather than discovered later: a wrapping
//! container must have a non-`fit` cross size in this model, because a correct
//! `fit` cross size for a wrap container depends on the available main size and
//! needs a second pass. Real engines run that extra pass. So wrap's cost here
//! is a LOWER bound, and the omitted part is itself an argument that
//! memoisation gets harder with real flexbox, not easier.

const std = @import("std");
const build_options = @import("build_options");

const NONE: u32 = std.math.maxInt(u32);

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ------------------------------------------------------------------ geometry

const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    fn eq(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
};

const Axis = enum(u8) { row, col };

/// `.fixed` -> flex-basis is a definite length. `.fit` -> basis is the content
/// size, flex-grow 0. `.grow` -> basis is the content size and flex-grow is the
/// element's `flex_grow`. Shrink is independent of the mode, as in CSS, where
/// flex-shrink defaults to 1 for every item regardless of its basis.
const SizeMode = enum(u8) { fixed, grow, fit };

const Justify = enum(u8) { start, center, end, space_between };
const AlignItems = enum(u8) { start, center, end, stretch, baseline };

// ------------------------------------------------------------------- element

const Element = struct {
    first_child: u32 = NONE,
    next_sibling: u32 = NONE,
    parent: u32 = NONE,
    child_count: u32 = 0,

    axis: Axis = .col,
    w_mode: SizeMode = .fit,
    h_mode: SizeMode = .fit,
    fixed_w: f32 = 0,
    fixed_h: f32 = 0,

    // --- real flexbox properties ---
    flex_grow: f32 = 0,
    /// CSS default is 1. This is the single most consequential difference from
    /// the run 2-5 model, because it means overflow couples every sibling.
    flex_shrink: f32 = 1,
    min_w: f32 = 0,
    min_h: f32 = 0,
    max_w: f32 = std.math.floatMax(f32),
    max_h: f32 = std.math.floatMax(f32),
    wrap: bool = false,
    justify: Justify = .start,
    align_items: AlignItems = .start,

    pad: f32 = 0,
    gap: f32 = 0,
    corner: f32 = 0,
    color: u32 = 0,

    intrinsic_w: f32 = 0,
    intrinsic_h: f32 = 0,
    /// Distance from this element's top edge to its first baseline. Needed by
    /// `align_items == .baseline`, and derivable bottom-up, so a baseline change
    /// propagates through the same dirty chain as a size change.
    baseline: f32 = 0,
    bounds: Rect = .{},

    entity: Handle = .{},
    render: ?RenderFn = null,
    has_handler: bool = false,

    // --- incremental bookkeeping ---
    /// Any child with flex-grow > 0 on this element's main axis.
    any_grow_main: bool = false,
    /// Any child with flex-shrink > 0 on this element's main axis. Almost always
    /// true under CSS defaults, which is the point.
    any_shrink_main: bool = false,
    /// Any child whose main size is clamped by a min/max, making the freeze loop
    /// reachable.
    any_clamp_main: bool = false,
    /// Sum of children's hypothetical outer main sizes plus gaps, maintained
    /// incrementally. This is what makes overflow detection O(1) instead of a
    /// full sibling scan -- without it, flex-shrink alone would force the slow
    /// path on every size change.
    sum_main: f32 = 0,
    /// Children's positions are a pure prefix scan: no grow, no reachable
    /// shrink, no wrap, justify at flex-start. Only then can repositioning start
    /// at a middle child and stop early.
    simple_main: bool = false,
    /// Children's cross positions do not depend on their siblings.
    simple_cross: bool = false,
};

const Quad = struct {
    rect: Rect = .{},
    color: u32 = 0,
    corner: f32 = 0,
    visible: bool = false,
};

const EntitySlot = struct { gen: u32 = 1, state: u32 = 0 };
const Handle = struct { idx: u32 = NONE, gen: u32 = 0 };
const RenderFn = *const fn (t: *Tree, el: u32, state: u32) void;

const Region = struct {
    rect: Rect = .{},
    el: u32 = NONE,
    handler: ?*const fn (u32) void = null,
};

fn onClickA(el: u32) void {
    std.mem.doNotOptimizeAway(el);
}
fn onClickB(el: u32) void {
    std.mem.doNotOptimizeAway(el);
}

fn renderEntityA(t: *Tree, el: u32, state: u32) void {
    const e = &t.els[el];
    e.color = state *% 2654435761;
    e.corner = @floatFromInt(state % 8);
    t.ctr.entity += 1;
}

fn renderEntityB(t: *Tree, el: u32, state: u32) void {
    const e = &t.els[el];
    e.color = (state *% 40503) ^ 0x9e37;
    e.pad = @floatFromInt(state % 4);
    t.ctr.entity += 1;
}

const Topology = enum { wide, deep, mixed, narrow };

/// How much real flexbox to switch on. `legacy` reproduces the run 2-5 model so
/// the two files can be compared on the same machine in the same session;
/// `css_default` is the honest one -- flex-shrink 1 everywhere, as CSS does it.
const FlexProfile = enum {
    /// No shrink, no wrap, no clamps, justify/align at start. Run 2-5 model.
    legacy,
    /// flex-shrink: 1 on every item, min/max clamps, and a realistic mix of
    /// justify-content and align-items. Wrap off.
    css_default,
    /// css_default plus flex-wrap on some containers.
    css_wrap,
};

// ---------------------------------------------------------------------- tree

const Counters = struct {
    build: u32 = 0,
    intrinsic: u32 = 0,
    position: u32 = 0,
    /// Items visited by the CSS 9.7 freeze loop, summed over passes. Separated
    /// from `position` because this is the cost real flexbox adds.
    flexloop: u32 = 0,
    paint: u32 = 0,
    entity: u32 = 0,
    region: u32 = 0,

    fn clear(self: *Counters) void {
        self.* = .{};
    }

    fn total(self: Counters) u32 {
        return self.build + self.intrinsic + self.position + self.flexloop +
            self.paint + self.entity + self.region;
    }
};

/// How often the incremental fast paths were actually usable. Reported, because
/// a win that only applies to 3% of containers is not a win.
const PathStats = struct {
    fast_main: u64 = 0,
    slow_main: u64 = 0,

    fn rate(self: PathStats) f64 {
        const d = self.fast_main + self.slow_main;
        if (d == 0) return 0;
        return @as(f64, @floatFromInt(self.fast_main)) / @as(f64, @floatFromInt(d));
    }
};

const Tree = struct {
    els: []Element,
    pre: []u32,
    post: []u32,
    quads: []Quad,
    stack: []u32,
    snapshot: []Rect,
    path_stamp: []u32,
    snap_intr: []Rect,
    snap_bl: []f32,
    entities: []EntitySlot,
    regions: []Region,

    // flex scratch, sized to the whole tree because one container may hold it all
    kids: []u32,
    base: []f32,
    target: []f32,
    frozen: []bool,
    hypo_cross: []f32,
    line_of: []u32,
    line_start: []u32,
    line_count: []u32,
    line_main: []f32,
    line_cross: []f32,
    line_bl: []f32,

    frame_no: u32 = 1,

    n: usize,
    topo: Topology,
    profile: FlexProfile,
    seed: u64,

    ctr: Counters = .{},
    stats: PathStats = .{},
    dbg_from: u32 = NONE,
    dbg_child: u32 = NONE,

    fn alloc(
        gpa: std.mem.Allocator,
        topo: Topology,
        profile: FlexProfile,
        count: usize,
        seed: u64,
    ) !Tree {
        const n = count + 1;
        return .{
            .els = try gpa.alloc(Element, n),
            .pre = try gpa.alloc(u32, n),
            .post = try gpa.alloc(u32, n),
            .quads = try gpa.alloc(Quad, n),
            .stack = try gpa.alloc(u32, n),
            .snapshot = try gpa.alloc(Rect, n),
            .path_stamp = try gpa.alloc(u32, n),
            .snap_intr = try gpa.alloc(Rect, n),
            .snap_bl = try gpa.alloc(f32, n),
            .entities = try gpa.alloc(EntitySlot, n),
            .regions = try gpa.alloc(Region, n),
            .kids = try gpa.alloc(u32, n),
            .base = try gpa.alloc(f32, n),
            .target = try gpa.alloc(f32, n),
            .frozen = try gpa.alloc(bool, n),
            .hypo_cross = try gpa.alloc(f32, n),
            .line_of = try gpa.alloc(u32, n),
            .line_start = try gpa.alloc(u32, n),
            .line_count = try gpa.alloc(u32, n),
            .line_main = try gpa.alloc(f32, n),
            .line_cross = try gpa.alloc(f32, n),
            .line_bl = try gpa.alloc(f32, n),
            .n = n,
            .topo = topo,
            .profile = profile,
            .seed = seed,
        };
    }

    fn free(self: *Tree, gpa: std.mem.Allocator) void {
        gpa.free(self.els);
        gpa.free(self.pre);
        gpa.free(self.post);
        gpa.free(self.quads);
        gpa.free(self.stack);
        gpa.free(self.snapshot);
        gpa.free(self.path_stamp);
        gpa.free(self.snap_intr);
        gpa.free(self.snap_bl);
        gpa.free(self.entities);
        gpa.free(self.regions);
        gpa.free(self.kids);
        gpa.free(self.base);
        gpa.free(self.target);
        gpa.free(self.frozen);
        gpa.free(self.hypo_cross);
        gpa.free(self.line_of);
        gpa.free(self.line_start);
        gpa.free(self.line_count);
        gpa.free(self.line_main);
        gpa.free(self.line_cross);
        gpa.free(self.line_bl);
    }

    // -------------------------------------------------------------- structure

    /// Same topology semantics as gpui::randomized_element_tree, with flex
    /// properties layered on according to `profile`.
    fn build(self: *Tree) void {
        @memset(self.path_stamp, 0);
        var prng = std.Random.DefaultPrng.init(self.seed);
        const r = prng.random();
        const els = self.els;
        const prof = self.profile;

        els[0] = .{
            .axis = .col,
            .w_mode = .fixed,
            .h_mode = .fixed,
            .fixed_w = 1920,
            .fixed_h = 1080,
            .pad = 8,
            .gap = 4,
            .flex_shrink = 0,
        };

        var last_deep: u32 = 0;
        var i: usize = 1;
        while (i < self.n) : (i += 1) {
            const parent: u32 = switch (self.topo) {
                .wide => 0,
                .deep => last_deep,
                .mixed => @intCast(r.uintLessThan(usize, i)),
                .narrow => if (r.uintLessThan(u8, 5) == 0) 0 else last_deep,
            };
            const leafish = r.uintLessThan(u8, 3) == 0;
            els[i] = .{
                .parent = parent,
                .axis = if (r.boolean()) .row else .col,
                .w_mode = if (leafish) .fixed else .grow,
                .h_mode = if (leafish) .fixed else .fit,
                .fixed_w = @floatFromInt(8 + r.uintLessThan(u32, 120)),
                .fixed_h = @floatFromInt(8 + r.uintLessThan(u32, 24)),
                .pad = @floatFromInt(r.uintLessThan(u32, 6)),
                .gap = @floatFromInt(r.uintLessThan(u32, 5)),
                .corner = @floatFromInt(r.uintLessThan(u32, 8)),
                .color = r.int(u32),
            };
            const e = &els[i];

            // flex-grow weight: CSS `flex-grow: 1` is overwhelmingly the common
            // case, but weighted grow does occur, and it changes the arithmetic.
            e.flex_grow = if (e.w_mode == .grow or e.h_mode == .grow)
                (if (r.uintLessThan(u32, 100) < 85) 1.0 else @as(f32, @floatFromInt(1 + r.uintLessThan(u32, 3))))
            else
                0;

            switch (prof) {
                .legacy => {
                    e.flex_shrink = 0;
                },
                .css_default, .css_wrap => {
                    // CSS default: every item shrinks.
                    e.flex_shrink = 1;
                    // min/max constraints on a minority of items, which is what
                    // makes the freeze loop reachable. `min-width: 0` is the CSS
                    // initial value but authors set real minimums constantly
                    // (buttons, icons, avatars).
                    if (r.uintLessThan(u32, 100) < 25) {
                        e.min_w = @max(4, e.fixed_w * 0.5);
                        e.min_h = @max(4, e.fixed_h * 0.5);
                    }
                    if (r.uintLessThan(u32, 100) < 15) {
                        e.max_w = e.fixed_w * 1.5;
                        e.max_h = e.fixed_h * 1.5;
                    }
                    // Realistic alignment mix. align-items: center on a row is
                    // one of the most common lines of CSS in any UI.
                    const jr = r.uintLessThan(u32, 100);
                    e.justify = if (jr < 70) .start else if (jr < 85) .space_between else if (jr < 94) .center else .end;
                    const ar = r.uintLessThan(u32, 100);
                    e.align_items = if (ar < 40) .center else if (ar < 65) .start else if (ar < 85) .stretch else if (ar < 95) .baseline else .end;
                },
            }
            if (prof == .css_wrap and r.uintLessThan(u32, 100) < 12) {
                // A wrap container needs a definite cross size in this model;
                // see the header note. Forcing it here keeps the model sound
                // rather than silently wrong.
                e.wrap = true;
                switch (e.axis) {
                    .row => if (e.h_mode == .fit) {
                        e.h_mode = .fixed;
                    },
                    .col => if (e.w_mode == .fit) {
                        e.w_mode = .fixed;
                    },
                }
            }

            if (r.uintLessThan(u32, 100) < 11) {
                self.entities[i] = .{ .gen = 1, .state = r.int(u32) };
                e.entity = .{ .idx = @intCast(i), .gen = 1 };
                e.render = if (i % 2 == 0) &renderEntityA else &renderEntityB;
            }
            e.has_handler = r.uintLessThan(u32, 100) < 19;
            e.next_sibling = els[parent].first_child;
            els[parent].first_child = @intCast(i);
            els[parent].child_count += 1;
            last_deep = @intCast(i);
            self.ctr.build += 1;
        }

        // Guarantee the leaf_bounds scenario has something to measure. It needs a
        // childless element whose main-axis size is a definite length, because a
        // `grow` item ignores fixed_w/h and changing it would measure a no-op.
        // The `deep` topology has exactly ONE childless element and whether it
        // qualifies is a coin flip that moves between profiles, since the CSS
        // profiles consume extra random draws. Forcing it keeps the scenario
        // comparable across profiles instead of silently measuring nothing.
        {
            var have = false;
            var last_leaf: u32 = NONE;
            var k: u32 = 1;
            while (k < self.n) : (k += 1) {
                if (els[k].first_child != NONE) continue;
                last_leaf = k;
                const fixed_on_main = switch (els[els[k].parent].axis) {
                    .row => els[k].w_mode == .fixed,
                    .col => els[k].h_mode == .fixed,
                };
                if (fixed_on_main) {
                    have = true;
                    break;
                }
            }
            if (!have and last_leaf != NONE) {
                switch (els[els[last_leaf].parent].axis) {
                    .row => els[last_leaf].w_mode = .fixed,
                    .col => els[last_leaf].h_mode = .fixed,
                }
            }
        }

        self.refreshFlags();
    }

    /// Recomputes the cached per-container predicates. Structural edits must
    /// call this; the benchmark's scenarios do not change structure, so it runs
    /// once per build.
    fn refreshFlags(self: *Tree) void {
        const els = self.els;
        for (els[0..self.n]) |*e| {
            var grow = false;
            var shrink = false;
            var clamp = false;
            var c = e.first_child;
            while (c != NONE) : (c = els[c].next_sibling) {
                const ch = &els[c];
                const main_mode = switch (e.axis) {
                    .row => ch.w_mode,
                    .col => ch.h_mode,
                };
                if (main_mode == .grow and ch.flex_grow > 0) grow = true;
                if (ch.flex_shrink > 0) shrink = true;
                const has_min = switch (e.axis) {
                    .row => ch.min_w > 0,
                    .col => ch.min_h > 0,
                };
                const has_max = switch (e.axis) {
                    .row => ch.max_w != std.math.floatMax(f32),
                    .col => ch.max_h != std.math.floatMax(f32),
                };
                if (has_min or has_max) clamp = true;
            }
            e.any_grow_main = grow;
            e.any_shrink_main = shrink;
            e.any_clamp_main = clamp;
            e.simple_main = !grow and !e.wrap and e.justify == .start;
            e.simple_cross = e.align_items == .start;
        }
    }

    fn computeOrders(self: *Tree) void {
        var sp: usize = 0;
        var k: usize = 0;
        self.stack[sp] = 0;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const idx = self.stack[sp];
            self.pre[k] = idx;
            k += 1;
            var c = self.els[idx].first_child;
            while (c != NONE) {
                self.stack[sp] = c;
                sp += 1;
                c = self.els[c].next_sibling;
            }
        }
        for (self.pre[0..k], 0..) |v, j| self.post[k - 1 - j] = v;
    }

    // ------------------------------------------------------------ flex helpers

    fn clampF(v: f32, lo: f32, hi: f32) f32 {
        return @min(@max(v, lo), hi);
    }

    /// An element's flex base size on the given axis: a definite length if the
    /// mode is `.fixed`, otherwise its content size.
    fn baseMain(self: *const Tree, idx: u32, axis: Axis) f32 {
        const e = &self.els[idx];
        return switch (axis) {
            .row => if (e.w_mode == .fixed) e.fixed_w else e.intrinsic_w,
            .col => if (e.h_mode == .fixed) e.fixed_h else e.intrinsic_h,
        };
    }

    fn minMain(self: *const Tree, idx: u32, axis: Axis) f32 {
        const e = &self.els[idx];
        return switch (axis) {
            .row => e.min_w,
            .col => e.min_h,
        };
    }

    fn maxMain(self: *const Tree, idx: u32, axis: Axis) f32 {
        const e = &self.els[idx];
        return switch (axis) {
            .row => e.max_w,
            .col => e.max_h,
        };
    }

    /// Hypothetical main size: the flex base size clamped by min/max. This is
    /// what line breaking and `sum_main` are computed from.
    fn hypoMain(self: *const Tree, idx: u32, axis: Axis) f32 {
        return clampF(self.baseMain(idx, axis), self.minMain(idx, axis), self.maxMain(idx, axis));
    }

    /// Hypothetical cross size, before any stretch is applied.
    fn hypoCross(self: *const Tree, idx: u32, axis: Axis) f32 {
        const e = &self.els[idx];
        return switch (axis) {
            // parent axis row -> cross is height
            .row => clampF(if (e.h_mode == .fixed) e.fixed_h else e.intrinsic_h, e.min_h, e.max_h),
            .col => clampF(if (e.w_mode == .fixed) e.fixed_w else e.intrinsic_w, e.min_w, e.max_w),
        };
    }

    /// Children's hypothetical outer main sizes plus gaps. O(k); callers that
    /// run every frame must use the cached `sum_main` instead.
    fn computeSumMain(self: *Tree, idx: u32) f32 {
        const e = &self.els[idx];
        var sum: f32 = 0;
        var kids: u32 = 0;
        var c = e.first_child;
        while (c != NONE) : (c = self.els[c].next_sibling) {
            sum += self.hypoMain(c, e.axis);
            kids += 1;
        }
        if (kids > 1) sum += e.gap * @as(f32, @floatFromInt(kids - 1));
        return sum;
    }

    // ----------------------------------------------------------------- layout

    /// Recomputes one element's content size and baseline from its children.
    /// Returns true if anything observable to the parent changed.
    ///
    /// With flexbox the content main size is the max-content size: the sum of
    /// the children's hypothetical outer main sizes. Wrap is deliberately not
    /// considered here; see the header note.
    fn recomputeIntrinsic(self: *Tree, idx: u32) bool {
        const e = &self.els[idx];
        const was_w = e.intrinsic_w;
        const was_h = e.intrinsic_h;
        const was_bl = e.baseline;

        var main_sz: f32 = 0;
        var cross: f32 = 0;
        var kids: u32 = 0;
        var bl_row: f32 = 0;
        var first_bl: f32 = 0;
        var c = e.first_child;
        while (c != NONE) : (c = self.els[c].next_sibling) {
            const hm = self.hypoMain(c, e.axis);
            const hc = self.hypoCross(c, e.axis);
            main_sz += hm;
            cross = @max(cross, hc);
            bl_row = @max(bl_row, self.els[c].baseline);
            if (kids == 0) first_bl = self.els[c].baseline;
            kids += 1;
        }
        if (kids > 1) main_sz += e.gap * @as(f32, @floatFromInt(kids - 1));
        e.sum_main = main_sz;
        main_sz += e.pad * 2;
        cross += e.pad * 2;

        switch (e.axis) {
            .row => {
                e.intrinsic_w = main_sz;
                e.intrinsic_h = cross;
            },
            .col => {
                e.intrinsic_h = main_sz;
                e.intrinsic_w = cross;
            },
        }
        if (e.w_mode == .fixed) e.intrinsic_w = e.fixed_w;
        if (e.h_mode == .fixed) e.intrinsic_h = e.fixed_h;

        // Baseline: a row takes the deepest child baseline, a column the first
        // child's, and a leaf synthesises one at 80% of its height the way a
        // single line of text would.
        if (kids == 0) {
            e.baseline = e.intrinsic_h * 0.8;
        } else switch (e.axis) {
            .row => e.baseline = e.pad + bl_row,
            .col => e.baseline = e.pad + first_bl,
        }

        self.ctr.intrinsic += 1 + kids;
        return e.intrinsic_w != was_w or e.intrinsic_h != was_h or e.baseline != was_bl;
    }

    fn intrinsicAll(self: *Tree) void {
        for (self.post[0..self.n]) |idx| _ = self.recomputeIntrinsic(idx);
    }

    /// CSS 9.7 "Resolve the flexible lengths": distribute free space by flex
    /// factor, clamp to min/max, freeze the items that violated their clamp, and
    /// repeat. `self.target[k]` receives the resolved main size for `kids[k]`.
    ///
    /// This loop is the cost item 2 in the header: with clamps reachable it runs
    /// more than once, and each pass is O(unfrozen).
    fn resolveFlexibleLengths(
        self: *Tree,
        axis: Axis,
        k0: usize,
        k1: usize,
        avail_main: f32,
        gap_total: f32,
    ) void {
        var sum_hypo: f32 = gap_total;
        var i = k0;
        while (i < k1) : (i += 1) {
            const c = self.kids[i];
            self.base[i] = self.baseMain(c, axis);
            self.target[i] = clampF(self.base[i], self.minMain(c, axis), self.maxMain(c, axis));
            sum_hypo += self.target[i];
        }
        const growing = sum_hypo < avail_main;

        // Freeze items that cannot flex in the needed direction.
        i = k0;
        while (i < k1) : (i += 1) {
            const c = self.kids[i];
            const e = &self.els[c];
            const main_mode = switch (axis) {
                .row => e.w_mode,
                .col => e.h_mode,
            };
            const factor = if (growing)
                (if (main_mode == .grow) e.flex_grow else 0)
            else
                e.flex_shrink;
            // Also frozen when the base size is already on the wrong side of
            // the clamp, per CSS.
            const clamped_wrong = if (growing)
                self.base[i] > self.target[i]
            else
                self.base[i] < self.target[i];
            self.frozen[i] = (factor == 0) or clamped_wrong;
            if (self.frozen[i]) self.target[i] = clampF(
                self.base[i],
                self.minMain(c, axis),
                self.maxMain(c, axis),
            );
        }

        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            // Remaining free space, and the total flex factor still in play.
            var used: f32 = gap_total;
            var factor_sum: f32 = 0;
            var scaled_sum: f32 = 0;
            var unfrozen: u32 = 0;
            i = k0;
            while (i < k1) : (i += 1) {
                const c = self.kids[i];
                const e = &self.els[c];
                if (self.frozen[i]) {
                    used += self.target[i];
                } else {
                    used += self.base[i];
                    unfrozen += 1;
                    const main_mode = switch (axis) {
                        .row => e.w_mode,
                        .col => e.h_mode,
                    };
                    if (growing) {
                        factor_sum += if (main_mode == .grow) e.flex_grow else 0;
                    } else {
                        factor_sum += e.flex_shrink;
                        scaled_sum += e.flex_shrink * self.base[i];
                    }
                }
            }
            self.ctr.flexloop += unfrozen;
            if (unfrozen == 0) break;

            const free_space = avail_main - used;
            var violation: f32 = 0;
            i = k0;
            while (i < k1) : (i += 1) {
                if (self.frozen[i]) continue;
                const c = self.kids[i];
                const e = &self.els[c];
                var want: f32 = self.base[i];
                if (growing) {
                    const main_mode = switch (axis) {
                        .row => e.w_mode,
                        .col => e.h_mode,
                    };
                    const f = if (main_mode == .grow) e.flex_grow else 0;
                    if (factor_sum > 0) want = self.base[i] + free_space * (f / factor_sum);
                } else {
                    // Shrinking is weighted by flex-shrink x base size, so a big
                    // item gives up more than a small one, as CSS specifies.
                    const sf = e.flex_shrink * self.base[i];
                    if (scaled_sum > 0) want = self.base[i] + free_space * (sf / scaled_sum);
                }
                const clamped = clampF(want, self.minMain(c, axis), self.maxMain(c, axis));
                violation += clamped - want;
                self.target[i] = clamped;
            }

            if (violation == 0) {
                i = k0;
                while (i < k1) : (i += 1) self.frozen[i] = true;
                break;
            }
            // Freeze the items whose clamp fired in the direction of the total
            // violation; the rest get another pass with the freed space.
            i = k0;
            while (i < k1) : (i += 1) {
                if (self.frozen[i]) continue;
                const c = self.kids[i];
                const lo = self.minMain(c, axis);
                const hi = self.maxMain(c, axis);
                if (violation > 0) {
                    if (self.target[i] >= lo and self.base[i] < lo) self.frozen[i] = true;
                    if (self.target[i] == lo) self.frozen[i] = true;
                } else {
                    if (self.target[i] == hi) self.frozen[i] = true;
                }
            }
        }
    }

    /// Full flexbox layout of one element's children: materialise items, break
    /// into lines, resolve flexible lengths per line, then apply
    /// justify-content and align-items. Returns true if any child moved.
    fn positionChildren(self: *Tree, idx: u32) bool {
        const e = &self.els[idx];
        if (e.first_child == NONE) return false;

        const inner_x = e.bounds.x + e.pad;
        const inner_y = e.bounds.y + e.pad;
        const inner_w = @max(0, e.bounds.w - e.pad * 2);
        const inner_h = @max(0, e.bounds.h - e.pad * 2);
        const avail_main = switch (e.axis) {
            .row => inner_w,
            .col => inner_h,
        };
        const avail_cross = switch (e.axis) {
            .row => inner_h,
            .col => inner_w,
        };

        // --- materialise children, in document order ---
        var k: usize = 0;
        var c = e.first_child;
        while (c != NONE) : (c = self.els[c].next_sibling) {
            self.kids[k] = c;
            k += 1;
        }
        var work: u32 = @intCast(k);

        // --- line breaking ---
        var n_lines: usize = 0;
        if (!e.wrap) {
            self.line_start[0] = 0;
            self.line_count[0] = @intCast(k);
            n_lines = 1;
        } else {
            var i: usize = 0;
            var ls: usize = 0;
            var run: f32 = 0;
            while (i < k) : (i += 1) {
                const hm = self.hypoMain(self.kids[i], e.axis);
                const add = if (i == ls) hm else e.gap + hm;
                if (i > ls and run + add > avail_main) {
                    self.line_start[n_lines] = @intCast(ls);
                    self.line_count[n_lines] = @intCast(i - ls);
                    n_lines += 1;
                    ls = i;
                    run = hm;
                } else {
                    run += add;
                }
            }
            self.line_start[n_lines] = @intCast(ls);
            self.line_count[n_lines] = @intCast(k - ls);
            n_lines += 1;
            work += @intCast(k); // the extra pass line breaking costs
        }

        // --- per line: resolve main sizes, then cross extent ---
        var li: usize = 0;
        var cross_total: f32 = 0;
        while (li < n_lines) : (li += 1) {
            const k0: usize = self.line_start[li];
            const k1: usize = k0 + self.line_count[li];
            const cnt = k1 - k0;
            const gap_total = if (cnt > 1) e.gap * @as(f32, @floatFromInt(cnt - 1)) else 0;

            self.resolveFlexibleLengths(e.axis, k0, k1, avail_main, gap_total);

            var used: f32 = gap_total;
            var line_cross: f32 = 0;
            var max_bl: f32 = 0;
            var max_below: f32 = 0;
            var i = k0;
            while (i < k1) : (i += 1) {
                const ci = self.kids[i];
                used += self.target[i];
                const hc = self.hypoCross(ci, e.axis);
                self.hypo_cross[i] = hc;
                line_cross = @max(line_cross, hc);
                if (e.align_items == .baseline) {
                    const bl = self.els[ci].baseline;
                    max_bl = @max(max_bl, bl);
                    max_below = @max(max_below, hc - bl);
                }
            }
            if (e.align_items == .baseline) line_cross = @max(line_cross, max_bl + max_below);
            self.line_main[li] = used;
            self.line_bl[li] = max_bl;
            self.line_cross[li] = if (n_lines == 1 and !e.wrap)
                @max(line_cross, avail_cross)
            else
                line_cross;
            cross_total += self.line_cross[li];
        }
        if (n_lines > 1) cross_total += e.gap * @as(f32, @floatFromInt(n_lines - 1));

        // --- place ---
        var any_moved = false;
        var cross_cursor: f32 = switch (e.axis) {
            .row => inner_y,
            .col => inner_x,
        };
        li = 0;
        while (li < n_lines) : (li += 1) {
            const k0: usize = self.line_start[li];
            const k1: usize = k0 + self.line_count[li];
            const cnt = k1 - k0;
            const lc = self.line_cross[li];

            // justify-content: where the line starts, and extra gap between items
            const slack = avail_main - self.line_main[li];
            var main_cursor: f32 = switch (e.axis) {
                .row => inner_x,
                .col => inner_y,
            };
            var extra: f32 = 0;
            switch (e.justify) {
                .start => {},
                .center => main_cursor += @max(0, slack) / 2,
                .end => main_cursor += @max(0, slack),
                .space_between => if (cnt > 1) {
                    extra = @max(0, slack) / @as(f32, @floatFromInt(cnt - 1));
                },
            }

            var i = k0;
            while (i < k1) : (i += 1) {
                const ci = self.kids[i];
                const ch = &self.els[ci];
                const main_sz = self.target[i];

                // align-items on the cross axis
                var cross_sz = self.hypo_cross[i];
                var cross_off: f32 = 0;
                switch (e.align_items) {
                    .start => {},
                    .center => cross_off = @max(0, lc - cross_sz) / 2,
                    .end => cross_off = @max(0, lc - cross_sz),
                    .stretch => {
                        const cross_auto = switch (e.axis) {
                            .row => ch.h_mode != .fixed,
                            .col => ch.w_mode != .fixed,
                        };
                        if (cross_auto) {
                            const lo = switch (e.axis) {
                                .row => ch.min_h,
                                .col => ch.min_w,
                            };
                            const hi = switch (e.axis) {
                                .row => ch.max_h,
                                .col => ch.max_w,
                            };
                            cross_sz = clampF(lc, lo, hi);
                        } else {
                            cross_off = 0;
                        }
                    },
                    .baseline => cross_off = @max(0, self.line_bl[li] - ch.baseline),
                }

                const nb: Rect = switch (e.axis) {
                    .row => .{
                        .x = main_cursor,
                        .y = cross_cursor + cross_off,
                        .w = main_sz,
                        .h = cross_sz,
                    },
                    .col => .{
                        .x = cross_cursor + cross_off,
                        .y = main_cursor,
                        .w = cross_sz,
                        .h = main_sz,
                    },
                };
                if (!nb.eq(ch.bounds)) {
                    ch.bounds = nb;
                    any_moved = true;
                }
                main_cursor += main_sz + e.gap + extra;
                work += 1;
            }
            cross_cursor += lc + e.gap;
        }

        self.ctr.position += work;
        return any_moved;
    }

    fn positionAll(self: *Tree) void {
        self.els[0].bounds = .{ .w = self.els[0].fixed_w, .h = self.els[0].fixed_h };
        for (self.pre[0..self.n]) |idx| _ = self.positionChildren(idx);
    }

    fn repositionSubtree(self: *Tree, root_idx: u32) void {
        self.stack[0] = root_idx;
        self.drainReposition(1);
    }

    /// Repositions `start_child` and its later siblings, leaving earlier
    /// siblings untouched.
    ///
    /// Valid only when the parent's children are a pure prefix scan. With real
    /// flexbox that needs FOUR conditions, not run 4's one:
    ///
    ///   - no flex-grow on the main axis (one child's size would change others')
    ///   - no wrap (a size change can move an item to another line)
    ///   - justify-content at flex-start (otherwise earlier siblings move too)
    ///   - no overflow, so flex-shrink is not active
    ///
    /// The first three are static and cached in `simple_main`. The fourth is
    /// dynamic, and is the reason `sum_main` is maintained incrementally: it
    /// makes the overflow test O(1). Without that cache, flex-shrink defaulting
    /// to 1 would force the slow path on literally every size change, and the
    /// fast path would be dead code under CSS semantics.
    fn repositionFrom(self: *Tree, parent: u32, start_child: u32) void {
        const e = &self.els[parent];

        const avail_main = switch (e.axis) {
            .row => @max(0, e.bounds.w - e.pad * 2),
            .col => @max(0, e.bounds.h - e.pad * 2),
        };
        const overflowing = e.any_shrink_main and e.sum_main > avail_main;
        if (!e.simple_main or overflowing) {
            self.stats.slow_main += 1;
            self.repositionSubtree(parent);
            return;
        }
        self.stats.fast_main += 1;

        const inner_x = e.bounds.x + e.pad;
        const inner_y = e.bounds.y + e.pad;
        const inner_w = @max(0, e.bounds.w - e.pad * 2);
        const inner_h = @max(0, e.bounds.h - e.pad * 2);
        const avail_cross = switch (e.axis) {
            .row => inner_h,
            .col => inner_w,
        };

        // Single line, no grow, no shrink: each child's main size is its
        // hypothetical size and the line's cross extent is the container's.
        const lc = avail_cross;

        var sp: usize = 0;
        var work: u32 = 0;
        var cursor: f32 = switch (e.axis) {
            .row => self.els[start_child].bounds.x,
            .col => self.els[start_child].bounds.y,
        };

        var c = start_child;
        while (c != NONE) : (c = self.els[c].next_sibling) {
            const ch = &self.els[c];
            const main_sz = self.hypoMain(c, e.axis);
            var cross_sz = self.hypoCross(c, e.axis);
            if (e.align_items == .stretch) {
                const cross_auto = switch (e.axis) {
                    .row => ch.h_mode != .fixed,
                    .col => ch.w_mode != .fixed,
                };
                if (cross_auto) {
                    const lo = switch (e.axis) {
                        .row => ch.min_h,
                        .col => ch.min_w,
                    };
                    const hi = switch (e.axis) {
                        .row => ch.max_h,
                        .col => ch.max_w,
                    };
                    cross_sz = clampF(lc, lo, hi);
                }
            }

            const nb: Rect = switch (e.axis) {
                .row => .{ .x = cursor, .y = inner_y, .w = main_sz, .h = cross_sz },
                .col => .{ .x = inner_x, .y = cursor, .w = cross_sz, .h = main_sz },
            };
            work += 1;
            const is_start = c == start_child;
            if (!is_start and nb.eq(ch.bounds)) break;
            ch.bounds = nb;
            self.paintElement(c);
            if (ch.first_child != NONE) {
                self.stack[sp] = c;
                sp += 1;
            }
            cursor += main_sz + e.gap;
        }
        self.ctr.position += work;
        self.drainReposition(sp);
    }

    fn drainReposition(self: *Tree, seeded: usize) void {
        var sp = seeded;
        while (sp > 0) {
            sp -= 1;
            const idx = self.stack[sp];
            const moved = self.positionChildren(idx);
            self.paintElement(idx);
            var c = self.els[idx].first_child;
            while (c != NONE) : (c = self.els[c].next_sibling) {
                if (moved) self.paintElement(c);
                if (self.els[c].first_child == NONE) continue;
                if (moved or self.path_stamp[c] == self.frame_no) {
                    self.stack[sp] = c;
                    sp += 1;
                }
            }
        }
    }

    // ------------------------------------------------------------------ paint

    fn paintElement(self: *Tree, idx: u32) void {
        const e = &self.els[idx];
        self.quads[idx] = .{
            .rect = e.bounds,
            .color = e.color,
            .corner = e.corner,
            .visible = e.bounds.w > 0 and e.bounds.h > 0,
        };
        self.ctr.paint += 1;
        if (e.has_handler) {
            self.regions[idx] = .{
                .rect = e.bounds,
                .el = idx,
                .handler = if (idx % 2 == 0) &onClickA else &onClickB,
            };
            self.ctr.region += 1;
        }
    }

    fn paintAll(self: *Tree) void {
        for (self.pre[0..self.n]) |idx| self.paintElement(idx);
    }

    // -------------------------------------------------------------- scenarios

    fn renderEntities(self: *Tree) void {
        for (self.pre[0..self.n]) |idx| {
            const e = self.els[idx];
            const rf = e.render orelse continue;
            const h = e.entity;
            if (h.idx == NONE) continue;
            const slot = self.entities[h.idx];
            if (slot.gen != h.gen) continue;
            rf(self, idx, slot.state);
        }
    }

    fn renderEntity(self: *Tree, idx: u32) void {
        const e = self.els[idx];
        const rf = e.render orelse return;
        const h = e.entity;
        if (h.idx == NONE) return;
        const slot = self.entities[h.idx];
        if (slot.gen != h.gen) return;
        rf(self, idx, slot.state);
    }

    fn fullRefresh(self: *Tree) void {
        self.build();
        self.computeOrders();
        self.renderEntities();
        self.intrinsicAll();
        self.positionAll();
        self.paintAll();
    }

    fn unchanged(_: *Tree) void {}

    fn leafStyle(self: *Tree, leaf: u32) void {
        if (self.els[leaf].render != null) {
            self.entities[self.els[leaf].entity.idx].state +%= 1;
            self.renderEntity(leaf);
        } else {
            self.els[leaf].color ^= 0x00ff_00ff;
        }
        self.paintElement(leaf);
    }

    fn leafBounds(self: *Tree, leaf: u32, delta: f32) void {
        const e = &self.els[leaf];
        e.fixed_w += delta;
        e.fixed_h += delta;
        if (e.w_mode == .fixed) e.intrinsic_w = e.fixed_w;
        if (e.h_mode == .fixed) e.intrinsic_h = e.fixed_h;
        e.baseline = e.intrinsic_h * 0.8;
        self.ctr.intrinsic += 1;

        var child_on_path = leaf;
        var node = self.els[leaf].parent;
        while (node != NONE) {
            const changed = self.recomputeIntrinsic(node);
            if (!changed) break;
            child_on_path = node;
            node = self.els[node].parent;
        }
        // The loop has two exits and they are NOT the same case.
        //
        //   break    -> `node` is an ancestor whose own size did not change, so
        //               it stays put and only its children from
        //               `child_on_path` onward need repositioning.
        //   node==NONE -> the change propagated all the way out of the tree.
        //               There is no parent to reposition from, and
        //               `child_on_path` is the root itself. Feeding that to
        //               `repositionFrom` lays the root out as its own child and
        //               adds its own padding to its own origin.
        //
        // Collapsing the two with `if (node == NONE) 0 else node` is wrong and
        // put the root at x=8 instead of x=0. It is latent in incremental.zig
        // too; it only became reachable here because tracking `baseline` lets a
        // change propagate to the root, which the run 2-5 model could not do.
        const from: u32 = if (node == NONE) 0 else node;
        self.dbg_from = from;
        self.dbg_child = child_on_path;

        self.frame_no +%= 1;
        if (self.frame_no == 0) {
            @memset(self.path_stamp, 0);
            self.frame_no = 1;
        }
        var m: u32 = leaf;
        while (m != NONE) : (m = self.els[m].parent) {
            self.path_stamp[m] = self.frame_no;
            if (m == from) break;
        }

        if (node == NONE) {
            // Root size is pinned, so only its children need laying out again.
            self.repositionSubtree(0);
        } else {
            // `recomputeIntrinsic` refreshed `sum_main` for every ancestor it
            // visited. The one it stopped at did NOT change its own size, but
            // its children's sum did, so the overflow test in `repositionFrom`
            // needs it updated or the fast path would be taken on a line that
            // now overflows.
            self.els[from].sum_main = self.computeSumMain(from);
            self.repositionFrom(from, child_on_path);
        }
    }

    fn rootLayout(self: *Tree, delta: f32) void {
        self.els[0].fixed_w += delta;
        self.els[0].intrinsic_w = self.els[0].fixed_w;
        self.els[0].bounds.w = self.els[0].fixed_w;
        self.repositionSubtree(0);
    }
};

// ----------------------------------------------------------------- harness

const Scenario = enum { full_refresh, unchanged, leaf_style, leaf_bounds, root_layout };

var verify_leaf: u32 = NONE;

/// A fast path that is wrong is worthless. Snapshots what the incremental path
/// produced, recomputes everything from scratch, and compares. This caught two
/// real bugs in run 4, each of which looked like a 2x improvement.
fn verifyLayout(t: *Tree, label: []const u8) void {
    for (t.els[0..t.n], 0..) |e, i| {
        t.snapshot[i] = e.bounds;
        t.snap_intr[i] = .{ .w = e.intrinsic_w, .h = e.intrinsic_h };
        t.snap_bl[i] = e.baseline;
    }
    t.intrinsicAll();
    var stale: u32 = 0;
    for (t.els[0..t.n], 0..) |e, i| {
        const bad = e.intrinsic_w != t.snap_intr[i].w or
            e.intrinsic_h != t.snap_intr[i].h or
            e.baseline != t.snap_bl[i];
        if (bad) {
            if (stale < 8) std.debug.print(
                "  STALE el {d}: incr {d}x{d} bl {d} != full {d}x{d} bl {d} (parent {d})\n",
                .{
                    i,              t.snap_intr[i].w, t.snap_intr[i].h, t.snap_bl[i],
                    e.intrinsic_w,  e.intrinsic_h,    e.baseline,       e.parent,
                },
            );
            stale += 1;
        }
    }
    if (stale > 0) std.debug.print("  stale intrinsics: {d}; leaf = {d}\n", .{ stale, verify_leaf });
    t.positionAll();
    for (t.els[0..t.n], 0..) |e, i| {
        if (!e.bounds.eq(t.snapshot[i])) {
            std.debug.print(
                "VERIFY FAIL {s}: element {d} incremental {any} != full {any}\n",
                .{ label, i, t.snapshot[i], e.bounds },
            );
            std.debug.print(
                "  leaf={d} from={d} child_on_path={d}\n",
                .{ verify_leaf, t.dbg_from, t.dbg_child },
            );
            std.debug.print("  chain from {d} up:\n", .{i});
            var dn: u32 = @intCast(i);
            while (dn != NONE) : (dn = t.els[dn].parent) {
                const d = t.els[dn];
                std.debug.print(
                    "    el {d:>4} parent {d:>4} axis {s} w {s} h {s} kids {d:>3} pad {d} gap {d}" ++
                        " grow {any} shrink {any} wrap {any} just {s} align {s} simple {any} sum {d} intr {d}x{d}\n",
                    .{
                        dn,                     d.parent,
                        @tagName(d.axis),       @tagName(d.w_mode),
                        @tagName(d.h_mode),     d.child_count,
                        d.pad,                  d.gap,
                        d.any_grow_main,        d.any_shrink_main,
                        d.wrap,                 @tagName(d.justify),
                        @tagName(d.align_items), d.simple_main,
                        d.sum_main,             d.intrinsic_w,
                        d.intrinsic_h,
                    },
                );
            }
            @panic("incremental layout diverged from full layout");
        }
    }
}

const Sample = struct {
    ns: u64,
    ctr: Counters,
};

fn runScenario(t: *Tree, s: Scenario, leaf: u32, i: usize) Sample {
    t.ctr.clear();
    const t0 = nowNs();
    switch (s) {
        .full_refresh => t.fullRefresh(),
        .unchanged => t.unchanged(),
        .leaf_style => t.leafStyle(leaf),
        .leaf_bounds => t.leafBounds(leaf, if (i % 2 == 0) 1.0 else -1.0),
        .root_layout => t.rootLayout(if (i % 2 == 0) 1.0 else -1.0),
    }
    const t1 = nowNs();
    std.mem.doNotOptimizeAway(t.quads.ptr);
    return .{ .ns = t1 - t0, .ctr = t.ctr };
}

/// `profile` matters: under `legacy` nothing has a flex factor, so an
/// overflowing line genuinely resolves no flexible lengths. Asserting
/// flexloop > 0 there was wrong, and this assertion caught it on the first run.
fn checkCounters(s: Scenario, c: Counters, n: usize, profile: FlexProfile) void {
    switch (s) {
        .full_refresh => {
            if (c.paint < n) @panic("full refresh must paint every element");
            if (c.intrinsic < n) @panic("full refresh must size every element");
            if (c.build < n - 1) @panic("full refresh must build every element");
            if (c.entity == 0) @panic("full refresh must render entities");
            if (c.region == 0) @panic("full refresh must register input regions");
            if (profile != .legacy and c.flexloop == 0)
                @panic("full refresh must resolve flexible lengths when items can flex");
        },
        .unchanged => {
            if (c.total() != 0) @panic("unchanged must do no work");
        },
        .leaf_style => {
            if (c.paint != 1) @panic("leaf style must repaint exactly one element");
            if (c.intrinsic != 0 or c.position != 0) @panic("leaf style must not touch layout");
            if (c.flexloop != 0) @panic("leaf style must not resolve flexible lengths");
        },
        .leaf_bounds => {
            if (c.intrinsic < 1) @panic("leaf bounds must resize at least the leaf");
            if (c.paint < 1) @panic("leaf bounds must repaint something");
        },
        .root_layout => {
            if (c.position < 1) @panic("root layout must reposition");
        },
    }
}

const Case = struct { topo: Topology, count: usize };

fn pickLeaf(t: *Tree, count: usize) u32 {
    const want: u32 = @intCast(count / 2);
    var best_idx: u32 = NONE;
    var best_dist: u32 = std.math.maxInt(u32);
    var k: u32 = 1;
    while (k < t.n) : (k += 1) {
        const e = t.els[k];
        if (e.first_child != NONE) continue;
        const fixed_on_main = switch (t.els[e.parent].axis) {
            .row => e.w_mode == .fixed,
            .col => e.h_mode == .fixed,
        };
        if (!fixed_on_main) continue;
        const dist = if (k > want) k - want else want - k;
        if (dist < best_dist) {
            best_dist = dist;
            best_idx = k;
        }
    }
    if (best_idx == NONE) @panic("no fixed-on-main-axis leaf found");
    return best_idx;
}

fn perfMain(gpa: std.mem.Allocator, profile: FlexProfile, which: Scenario, iters: usize) !void {
    var t = try Tree.alloc(gpa, .wide, profile, 1649, 0x5eed);
    defer t.free(gpa);
    t.ctr.clear();
    t.fullRefresh();
    const leaf = pickLeaf(&t, 1649);

    var acc: u64 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const sm = runScenario(&t, which, leaf, i);
        acc +%= sm.ns +% sm.ctr.total();
    }
    std.mem.doNotOptimizeAway(&acc);
}

pub fn main() !void {
    var dbg = std.heap.DebugAllocator(.{}).init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    const perf_scenario: ?Scenario = comptime blk: {
        const name = build_options.scenario;
        if (std.mem.eql(u8, name, "full")) break :blk .full_refresh;
        if (std.mem.eql(u8, name, "unchanged")) break :blk .unchanged;
        if (std.mem.eql(u8, name, "leaf-style")) break :blk .leaf_style;
        if (std.mem.eql(u8, name, "leaf-bounds")) break :blk .leaf_bounds;
        if (std.mem.eql(u8, name, "root-layout")) break :blk .root_layout;
        break :blk null;
    };
    const perf_profile: FlexProfile = comptime blk: {
        const p = build_options.profile;
        if (std.mem.eql(u8, p, "legacy")) break :blk .legacy;
        if (std.mem.eql(u8, p, "css-wrap")) break :blk .css_wrap;
        break :blk .css_default;
    };
    if (perf_scenario) |w| {
        try perfMain(gpa, perf_profile, w, 20000);
        return;
    }

    const cases = [_]Case{
        .{ .topo = .wide, .count = 1649 },
        .{ .topo = .wide, .count = 2048 },
        .{ .topo = .mixed, .count = 256 },
        .{ .topo = .deep, .count = 256 },
        .{ .topo = .narrow, .count = 256 },
    };
    const scenarios = [_]Scenario{ .full_refresh, .unchanged, .leaf_style, .leaf_bounds, .root_layout };
    const profiles = [_]FlexProfile{ .legacy, .css_default, .css_wrap };

    const warmup = 200;
    const iters = 2000;

    for (profiles) |profile| {
        std.debug.print("\n=== profile: {s} ===\n", .{@tagName(profile)});
        std.debug.print(
            "{s:<7} {s:>6} {s:<13} {s:>9} {s:>9} {s:>7} {s:>7} {s:>7} {s:>8} {s:>7} {s:>6} {s:>6} {s:>7}\n",
            .{
                "topo",  "count",    "scenario", "mean ns", "best ns",
                "build", "intr",     "pos",      "flexlp",  "paint",
                "ent",   "region",   "fast%",
            },
        );
        std.debug.print("----------------------------------------------------------------------------------------------------------------------\n", .{});

        for (cases) |case| {
            var t = try Tree.alloc(gpa, case.topo, profile, case.count, 0x5eed);
            defer t.free(gpa);

            t.ctr.clear();
            t.fullRefresh();
            const leaf = pickLeaf(&t, case.count);

            for (scenarios) |s| {
                t.ctr.clear();
                t.fullRefresh();
                t.stats = .{};

                verify_leaf = leaf;
                var w: usize = 0;
                while (w < warmup) : (w += 1) {
                    _ = runScenario(&t, s, leaf, w);
                    if (w < 4) verifyLayout(&t, @tagName(s));
                }

                var sum: u64 = 0;
                var best: u64 = std.math.maxInt(u64);
                var last: Counters = .{};
                var i: usize = 0;
                while (i < iters) : (i += 1) {
                    const sm = runScenario(&t, s, leaf, i);
                    checkCounters(s, sm.ctr, t.n, profile);
                    sum += sm.ns;
                    if (sm.ns < best) best = sm.ns;
                    last = sm.ctr;
                }

                std.debug.print(
                    "{s:<7} {d:>6} {s:<13} {d:>9} {d:>9} {d:>7} {d:>7} {d:>7} {d:>8} {d:>7} {d:>6} {d:>6} {d:>6.0}\n",
                    .{
                        @tagName(case.topo), case.count,
                        @tagName(s),         sum / iters,
                        best,                last.build,
                        last.intrinsic,      last.position,
                        last.flexloop,       last.paint,
                        last.entity,         last.region,
                        t.stats.rate() * 100,
                    },
                );
            }
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("sizeOf(Element)={d} sizeOf(Quad)={d}\n", .{ @sizeOf(Element), @sizeOf(Quad) });
    std.debug.print("fast%% is the share of leaf_bounds repositions that kept the prefix-scan path\n", .{});
    std.debug.print("work is asserted every frame; layout is verified against a full recompute\n", .{});
}
