//! Element-level incremental rebuild, measured against the same change classes
//! as GPUI's `randomized_element_tree`.
//!
//! The question this answers: GPUI's dirty tracking is per *view*, so a notified
//! root re-renders its whole element subtree and `unchanged` costs the same as
//! `full refresh` (measured: 8454 vs 8451 allocations). If dirty tracking is per
//! *element* instead, what do those frames cost?
//!
//! Design consequence worth stating up front: a frame arena that is reset
//! wholesale is incompatible with reusing last frame's subtrees. The tree here
//! is therefore RETAINED -- allocated once, mutated in place -- so incremental
//! frames allocate nothing at all.
//!
//! Work counters are asserted after every frame. A frame that got faster by
//! skipping work it owed is a bug, not an improvement; this is the same
//! discipline GPUI's bench applies to its own counters.

const std = @import("std");

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
const SizeMode = enum(u8) { fixed, grow, fit };

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
    pad: f32 = 0,
    gap: f32 = 0,
    corner: f32 = 0,
    color: u32 = 0,

    intrinsic_w: f32 = 0,
    intrinsic_h: f32 = 0,
    bounds: Rect = .{},
};

/// One quad slot per element rather than a packed array, so patching a single
/// element's paint output is O(1). A real renderer wants quads packed for GPU
/// upload; with a persistently-mapped buffer it can patch slots in place, but
/// if it re-uploads the whole buffer every frame then incremental paint saves
/// the CPU-side construction and not the upload. Called out in RESULTS.md.
const Quad = struct {
    rect: Rect = .{},
    color: u32 = 0,
    corner: f32 = 0,
    visible: bool = false,
};

const Topology = enum { wide, deep, mixed, narrow };

// ---------------------------------------------------------------------- tree

const Counters = struct {
    build: u32 = 0,
    intrinsic: u32 = 0,
    position: u32 = 0,
    paint: u32 = 0,

    fn clear(self: *Counters) void {
        self.* = .{};
    }

    fn total(self: Counters) u32 {
        return self.build + self.intrinsic + self.position + self.paint;
    }
};

const Tree = struct {
    els: []Element,
    pre: []u32, // pre-order traversal
    post: []u32, // bottom-up traversal (reverse of pre)
    quads: []Quad, // one slot per element
    stack: []u32, // scratch for iterative walks

    n: usize, // element count including root
    topo: Topology,
    seed: u64,

    ctr: Counters = .{},

    fn alloc(gpa: std.mem.Allocator, topo: Topology, count: usize, seed: u64) !Tree {
        const n = count + 1;
        return .{
            .els = try gpa.alloc(Element, n),
            .pre = try gpa.alloc(u32, n),
            .post = try gpa.alloc(u32, n),
            .quads = try gpa.alloc(Quad, n),
            .stack = try gpa.alloc(u32, n),
            .n = n,
            .topo = topo,
            .seed = seed,
        };
    }

    fn free(self: *Tree, gpa: std.mem.Allocator) void {
        gpa.free(self.els);
        gpa.free(self.pre);
        gpa.free(self.post);
        gpa.free(self.quads);
        gpa.free(self.stack);
    }

    // -------------------------------------------------------------- structure

    /// Same topology semantics as gpui::randomized_element_tree.
    fn build(self: *Tree) void {
        var prng = std.Random.DefaultPrng.init(self.seed);
        const r = prng.random();
        const els = self.els;

        els[0] = .{
            .axis = .col,
            .w_mode = .fixed,
            .h_mode = .fixed,
            .fixed_w = 1920,
            .fixed_h = 1080,
            .pad = 8,
            .gap = 4,
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
            els[i].next_sibling = els[parent].first_child;
            els[parent].first_child = @intCast(i);
            els[parent].child_count += 1;
            last_deep = @intCast(i);
            self.ctr.build += 1;
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

    // ----------------------------------------------------------------- layout

    /// Recomputes one element's intrinsic size from its children. Returns true
    /// if it changed, which is what stops upward propagation.
    fn recomputeIntrinsic(self: *Tree, idx: u32) bool {
        const e = &self.els[idx];
        const was_w = e.intrinsic_w;
        const was_h = e.intrinsic_h;

        var main_sz: f32 = 0;
        var cross: f32 = 0;
        var kids: u32 = 0;
        var c = e.first_child;
        while (c != NONE) : (c = self.els[c].next_sibling) {
            const ch = &self.els[c];
            const cw = if (ch.w_mode == .fixed) ch.fixed_w else ch.intrinsic_w;
            const chh = if (ch.h_mode == .fixed) ch.fixed_h else ch.intrinsic_h;
            switch (e.axis) {
                .row => {
                    main_sz += cw;
                    cross = @max(cross, chh);
                },
                .col => {
                    main_sz += chh;
                    cross = @max(cross, cw);
                },
            }
            kids += 1;
        }
        if (kids > 1) main_sz += e.gap * @as(f32, @floatFromInt(kids - 1));
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

        self.ctr.intrinsic += 1 + kids;
        return e.intrinsic_w != was_w or e.intrinsic_h != was_h;
    }

    fn intrinsicAll(self: *Tree) void {
        for (self.post[0..self.n]) |idx| _ = self.recomputeIntrinsic(idx);
    }

    /// Lays out one element's children. Returns true if any child's bounds moved,
    /// which is what gates descending into that child.
    fn positionChildren(self: *Tree, idx: u32) bool {
        const e = &self.els[idx];
        const inner_x = e.bounds.x + e.pad;
        const inner_y = e.bounds.y + e.pad;
        const inner_w = @max(0, e.bounds.w - e.pad * 2);
        const inner_h = @max(0, e.bounds.h - e.pad * 2);

        var used: f32 = 0;
        var grow_n: f32 = 0;
        var kids: u32 = 0;
        var c = e.first_child;
        while (c != NONE) : (c = self.els[c].next_sibling) {
            const ch = &self.els[c];
            const grows = switch (e.axis) {
                .row => ch.w_mode == .grow,
                .col => ch.h_mode == .grow,
            };
            if (grows) grow_n += 1 else used += switch (e.axis) {
                .row => ch.intrinsic_w,
                .col => ch.intrinsic_h,
            };
            kids += 1;
        }
        if (kids > 1) used += e.gap * @as(f32, @floatFromInt(kids - 1));

        const avail = switch (e.axis) {
            .row => inner_w,
            .col => inner_h,
        };
        const per_grow = if (grow_n > 0) @max(0, avail - used) / grow_n else 0;

        var any_moved = false;
        var cursor: f32 = switch (e.axis) {
            .row => inner_x,
            .col => inner_y,
        };
        c = e.first_child;
        while (c != NONE) : (c = self.els[c].next_sibling) {
            const ch = &self.els[c];
            var cw = switch (ch.w_mode) {
                .fixed => ch.fixed_w,
                .fit => ch.intrinsic_w,
                .grow => if (e.axis == .row) per_grow else inner_w,
            };
            var chh = switch (ch.h_mode) {
                .fixed => ch.fixed_h,
                .fit => ch.intrinsic_h,
                .grow => if (e.axis == .col) per_grow else inner_h,
            };
            cw = @min(cw, inner_w);
            chh = @min(chh, inner_h);

            const nb: Rect = switch (e.axis) {
                .row => .{ .x = cursor, .y = inner_y, .w = cw, .h = chh },
                .col => .{ .x = inner_x, .y = cursor, .w = cw, .h = chh },
            };
            if (!nb.eq(ch.bounds)) {
                ch.bounds = nb;
                any_moved = true;
            }
            cursor += switch (e.axis) {
                .row => cw + e.gap,
                .col => chh + e.gap,
            };
        }
        // counts child slots examined: flex must scan every sibling to
        // redistribute grow space, so this is the real work unit, not the call
        self.ctr.position += kids * 2;
        return any_moved;
    }

    fn positionAll(self: *Tree) void {
        self.els[0].bounds = .{ .w = self.els[0].fixed_w, .h = self.els[0].fixed_h };
        for (self.pre[0..self.n]) |idx| _ = self.positionChildren(idx);
    }

    /// Repositions the subtree under `root_idx`, descending only where a child
    /// actually moved. This is what makes a bounds change cost O(affected)
    /// rather than O(tree).
    fn repositionSubtree(self: *Tree, root_idx: u32) void {
        var sp: usize = 0;
        self.stack[sp] = root_idx;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const idx = self.stack[sp];
            const moved = self.positionChildren(idx);
            self.paintElement(idx);
            if (!moved) continue;
            var c = self.els[idx].first_child;
            while (c != NONE) : (c = self.els[c].next_sibling) {
                self.paintElement(c);
                if (self.els[c].first_child != NONE) {
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
    }

    fn paintAll(self: *Tree) void {
        for (self.pre[0..self.n]) |idx| self.paintElement(idx);
    }

    // -------------------------------------------------------------- scenarios

    fn fullRefresh(self: *Tree) void {
        self.build();
        self.computeOrders();
        self.intrinsicAll();
        self.positionAll();
        self.paintAll();
    }

    /// Root notified, nothing actually changed. With per-element dirty tracking
    /// there is no work to do; GPUI pays a full refresh here.
    fn unchanged(_: *Tree) void {
        // no dirty elements -> nothing to rebuild, relayout or repaint
    }

    /// A leaf's colour changes. Cannot affect layout, so it is one quad patch.
    fn leafStyle(self: *Tree, leaf: u32) void {
        self.els[leaf].color ^= 0x00ff_00ff;
        self.paintElement(leaf);
    }

    /// A leaf's size changes: propagate intrinsic sizes up to the highest
    /// ancestor that actually changed, then reposition from that ancestor's
    /// parent, since later siblings shift.
    fn leafBounds(self: *Tree, leaf: u32, delta: f32) void {
        const e = &self.els[leaf];
        e.fixed_w += delta;
        e.fixed_h += delta;
        if (e.w_mode == .fixed) e.intrinsic_w = e.fixed_w;
        if (e.h_mode == .fixed) e.intrinsic_h = e.fixed_h;
        self.ctr.intrinsic += 1;

        var top = leaf;
        var node = self.els[leaf].parent;
        while (node != NONE) {
            const changed = self.recomputeIntrinsic(node);
            top = node;
            if (!changed) break;
            node = self.els[node].parent;
        }

        const from = if (self.els[top].parent == NONE) top else self.els[top].parent;
        self.repositionSubtree(from);
    }

    /// The root's own layout changes, so every position is recomputed, but the
    /// tree structure and all intrinsic sizes below it are reused.
    fn rootLayout(self: *Tree, delta: f32) void {
        self.els[0].fixed_w += delta;
        self.els[0].bounds.w = self.els[0].fixed_w;
        self.repositionSubtree(0);
    }
};

// ----------------------------------------------------------------- harness

const Scenario = enum { full_refresh, unchanged, leaf_style, leaf_bounds, root_layout };

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
        // alternate the sign so the tree does not drift away over 2000 frames
        .leaf_bounds => t.leafBounds(leaf, if (i % 2 == 0) 1.0 else -1.0),
        .root_layout => t.rootLayout(if (i % 2 == 0) 1.0 else -1.0),
    }
    const t1 = nowNs();
    std.mem.doNotOptimizeAway(t.quads.ptr);
    return .{ .ns = t1 - t0, .ctr = t.ctr };
}

/// A frame that got faster by skipping work it owed is a bug. Same discipline as
/// GPUI's bench, which asserts its tree's work counters after each measured loop.
fn checkCounters(s: Scenario, c: Counters, n: usize) void {
    switch (s) {
        .full_refresh => {
            if (c.paint < n) @panic("full refresh must paint every element");
            if (c.intrinsic < n) @panic("full refresh must size every element");
            if (c.build < n - 1) @panic("full refresh must build every element");
        },
        .unchanged => {
            if (c.total() != 0) @panic("unchanged must do no work");
        },
        .leaf_style => {
            if (c.paint != 1) @panic("leaf style must repaint exactly one element");
            if (c.intrinsic != 0 or c.position != 0) @panic("leaf style must not touch layout");
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

pub fn main() !void {
    var dbg = std.heap.DebugAllocator(.{}).init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    const cases = [_]Case{
        .{ .topo = .wide, .count = 1649 }, // matches GPUI wide/seed-0
        .{ .topo = .wide, .count = 2048 },
        .{ .topo = .mixed, .count = 256 },
        .{ .topo = .deep, .count = 256 },
        .{ .topo = .narrow, .count = 256 },
    };
    const scenarios = [_]Scenario{ .full_refresh, .unchanged, .leaf_style, .leaf_bounds, .root_layout };

    const warmup = 200;
    const iters = 2000;

    std.debug.print("{s:<7} {s:>6} {s:<14} {s:>10} {s:>10} {s:>8} {s:>8} {s:>8} {s:>8}\n", .{
        "topo", "count", "scenario", "mean ns", "best ns", "build", "intrins", "pos", "paint",
    });
    std.debug.print("----------------------------------------------------------------------------------------\n", .{});

    for (cases) |case| {
        var t = try Tree.alloc(gpa, case.topo, case.count, 0x5eed);
        defer t.free(gpa);

        // one full build so incremental scenarios start from a laid-out tree
        t.ctr.clear();
        t.fullRefresh();

        // A leaf whose size change actually propagates: childless, and fixed
        // along its parent's main axis. A `grow` child ignores fixed_w/h, so
        // measuring one would measure a no-op. Scan the whole tree and take the
        // candidate nearest the middle, since in a deep tree only the last
        // element is childless.
        const leaf: u32 = blk: {
            const want: u32 = @intCast(case.count / 2);
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
            break :blk best_idx;
        };

        for (scenarios) |s| {
            // leave the tree laid out before each scenario's own warm-up
            t.ctr.clear();
            t.fullRefresh();

            var w: usize = 0;
            while (w < warmup) : (w += 1) _ = runScenario(&t, s, leaf, w);

            var sum: u64 = 0;
            var best: u64 = std.math.maxInt(u64);
            var last: Counters = .{};
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const sm = runScenario(&t, s, leaf, i);
                checkCounters(s, sm.ctr, t.n);
                sum += sm.ns;
                if (sm.ns < best) best = sm.ns;
                last = sm.ctr;
            }

            std.debug.print("{s:<7} {d:>6} {s:<14} {d:>10} {d:>10} {d:>8} {d:>8} {d:>8} {d:>8}\n", .{
                @tagName(case.topo), case.count,     @tagName(s), sum / iters,
                best,                last.build,     last.intrinsic,
                last.position,       last.paint,
            });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("counters are from the last measured frame; work is asserted every frame\n", .{});
    std.debug.print("tree is retained, so incremental frames allocate nothing\n", .{});
}
