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

    /// Set when this element is backed by an entity whose render must run.
    entity: Handle = .{},
    render: ?RenderFn = null,
    has_handler: bool = false,

    /// Whether any child uses `grow` along THIS element's main axis. When none
    /// do, a child's size change cannot change any other child's size, so the
    /// grow-redistribution pass is pointless and siblings before the changed
    /// one cannot move. Maintained at build time and on structural change.
    any_grow_main: bool = false,
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

/// A retained entity: GPUI resolves `Entity<T>` through a slot table with a
/// generation check before calling the view's `render`. Modelled here so the
/// indirect call and the handle check are paid, not optimised away.
const EntitySlot = struct { gen: u32 = 1, state: u32 = 0 };

const Handle = struct { idx: u32 = NONE, gen: u32 = 0 };

const RenderFn = *const fn (t: *Tree, el: u32, state: u32) void;

/// A registered input region. GPUI rebuilds these every frame as part of paint;
/// a retained design can patch only the ones whose bounds moved.
const Region = struct {
    rect: Rect = .{},
    el: u32 = NONE,
    handler: ?*const fn (u32) void = null,
};

fn onClickA(el: u32) void {
    @import("std").mem.doNotOptimizeAway(el);
}
fn onClickB(el: u32) void {
    @import("std").mem.doNotOptimizeAway(el);
}

/// Two render bodies so the call site cannot be devirtualised to one target.
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

// ---------------------------------------------------------------------- tree

const Counters = struct {
    build: u32 = 0,
    intrinsic: u32 = 0,
    position: u32 = 0,
    paint: u32 = 0,
    entity: u32 = 0,
    region: u32 = 0,

    fn clear(self: *Counters) void {
        self.* = .{};
    }

    fn total(self: Counters) u32 {
        return self.build + self.intrinsic + self.position + self.paint +
            self.entity + self.region;
    }
};

const Tree = struct {
    els: []Element,
    pre: []u32, // pre-order traversal
    post: []u32, // bottom-up traversal (reverse of pre)
    quads: []Quad, // one slot per element
    stack: []u32, // scratch for iterative walks
    snapshot: []Rect, // scratch for verifying incremental layout against full
    /// Frame stamp marking the chain of elements whose intrinsic size changed.
    /// Descent must follow this chain even where bounds did not move: a child
    /// can land exactly where it was while a descendant still needs laying out.
    /// A stamp avoids an O(n) clear each frame.
    path_stamp: []u32,
    snap_intr: []Rect, // scratch: intrinsic sizes, for the same verification
    entities: []EntitySlot,
    regions: []Region, // one slot per element, patched in place
    frame_no: u32 = 1,

    n: usize, // element count including root
    topo: Topology,
    seed: u64,

    ctr: Counters = .{},
    dbg_from: u32 = NONE,
    dbg_child: u32 = NONE,

    fn alloc(gpa: std.mem.Allocator, topo: Topology, count: usize, seed: u64) !Tree {
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
            .entities = try gpa.alloc(EntitySlot, n),
            .regions = try gpa.alloc(Region, n),
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
        gpa.free(self.snapshot);
        gpa.free(self.path_stamp);
        gpa.free(self.snap_intr);
        gpa.free(self.entities);
        gpa.free(self.regions);
    }

    // -------------------------------------------------------------- structure

    /// Same topology semantics as gpui::randomized_element_tree.
    fn build(self: *Tree) void {
        @memset(self.path_stamp, 0);
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
            // GPUI's wide/seed-0 tree is 11% entities, 19% handlers
            if (r.uintLessThan(u32, 100) < 11) {
                self.entities[i] = .{ .gen = 1, .state = r.int(u32) };
                els[i].entity = .{ .idx = @intCast(i), .gen = 1 };
                els[i].render = if (i % 2 == 0) &renderEntityA else &renderEntityB;
            }
            els[i].has_handler = r.uintLessThan(u32, 100) < 19;
            els[i].next_sibling = els[parent].first_child;
            els[parent].first_child = @intCast(i);
            els[parent].child_count += 1;
            last_deep = @intCast(i);
            self.ctr.build += 1;
        }

        for (els[0..self.n], 0..) |*e, idx| {
            _ = idx;
            var any = false;
            var c = e.first_child;
            while (c != NONE) : (c = els[c].next_sibling) {
                const grows = switch (e.axis) {
                    .row => els[c].w_mode == .grow,
                    .col => els[c].h_mode == .grow,
                };
                if (grows) {
                    any = true;
                    break;
                }
            }
            e.any_grow_main = any;
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

        var per_grow: f32 = 0;
        var kids: u32 = 0;
        var work: u32 = 0;
        if (e.any_grow_main) {
            // grow children exist, so every sibling's main size depends on the
            // total claimed by the others: the full scan is unavoidable
            var used: f32 = 0;
            var grow_n: f32 = 0;
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
            per_grow = if (grow_n > 0) @max(0, avail - used) / grow_n else 0;
            work += kids; // the grow-redistribution scan
        }

        var any_moved = false;
        var cursor: f32 = switch (e.axis) {
            .row => inner_x,
            .col => inner_y,
        };
        var c = e.first_child;
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
            work += 1;
        }
        self.ctr.position += work;
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
        self.stack[0] = root_idx;
        self.drainReposition(1);
    }

    /// Repositions `start_child` and every later sibling, leaving earlier
    /// siblings untouched. Only valid when the parent has no `grow` child on its
    /// main axis: then one child's size cannot change another's, so the cursor
    /// can start at `start_child`'s existing position instead of the parent's
    /// content edge. Breaks as soon as a child lands exactly where it already
    /// was, because every later sibling then lands where it already was too.
    fn repositionFrom(self: *Tree, parent: u32, start_child: u32) void {
        const e = &self.els[parent];
        if (e.any_grow_main) {
            self.repositionSubtree(parent);
            return;
        }

        const inner_x = e.bounds.x + e.pad;
        const inner_y = e.bounds.y + e.pad;
        const inner_w = @max(0, e.bounds.w - e.pad * 2);
        const inner_h = @max(0, e.bounds.h - e.pad * 2);

        var sp: usize = 0;
        var work: u32 = 0;
        var cursor: f32 = switch (e.axis) {
            .row => self.els[start_child].bounds.x,
            .col => self.els[start_child].bounds.y,
        };

        var c = start_child;
        while (c != NONE) : (c = self.els[c].next_sibling) {
            const ch = &self.els[c];
            var cw = switch (ch.w_mode) {
                .fixed => ch.fixed_w,
                .fit => ch.intrinsic_w,
                .grow => inner_w, // cross axis here, since main has no grow
            };
            var chh = switch (ch.h_mode) {
                .fixed => ch.fixed_h,
                .fit => ch.intrinsic_h,
                .grow => inner_h,
            };
            cw = @min(cw, inner_w);
            chh = @min(chh, inner_h);

            const nb: Rect = switch (e.axis) {
                .row => .{ .x = cursor, .y = inner_y, .w = cw, .h = chh },
                .col => .{ .x = inner_x, .y = cursor, .w = cw, .h = chh },
            };
            work += 1;
            // The start child's own bounds may be unchanged while its children's
            // sizes are not, so it always gets descended into. For later
            // siblings, landing where they already were means every sibling
            // after them does too.
            const is_start = c == start_child;
            if (!is_start and nb.eq(ch.bounds)) break;
            ch.bounds = nb;
            self.paintElement(c);
            if (ch.first_child != NONE) {
                self.stack[sp] = c;
                sp += 1;
            }
            cursor += switch (e.axis) {
                .row => cw + e.gap,
                .col => chh + e.gap,
            };
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
                // descend when the child moved, or when it carries a changed
                // intrinsic further down even though it did not move itself
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

    /// Resolves the handle then calls render through a function pointer, the
    /// way a view-backed element is rebuilt.
    fn renderEntities(self: *Tree) void {
        for (self.pre[0..self.n]) |idx| {
            const e = self.els[idx];
            const rf = e.render orelse continue;
            const h = e.entity;
            if (h.idx == NONE) continue;
            const slot = self.entities[h.idx];
            if (slot.gen != h.gen) continue; // stale handle
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

    /// Root notified, nothing actually changed. With per-element dirty tracking
    /// there is no work to do; GPUI pays a full refresh here.
    fn unchanged(_: *Tree) void {
        // no dirty elements -> nothing to rebuild, relayout or repaint
    }

    /// A leaf's colour changes. Cannot affect layout, so it is one quad patch.
    fn leafStyle(self: *Tree, leaf: u32) void {
        if (self.els[leaf].render != null) {
            // state change on the backing entity, then re-render just that element
            self.entities[self.els[leaf].entity.idx].state +%= 1;
            self.renderEntity(leaf);
        } else {
            self.els[leaf].color ^= 0x00ff_00ff;
        }
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

        // Climb while each ancestor's own size keeps changing. The first
        // ancestor whose intrinsic is unchanged does not move and neither do
        // its siblings -- but its children must be laid out again, starting
        // from the one on the path. `child_on_path` tracks that child.
        var child_on_path = leaf;
        var node = self.els[leaf].parent;
        while (node != NONE) {
            const changed = self.recomputeIntrinsic(node);
            if (!changed) break;
            child_on_path = node;
            node = self.els[node].parent;
        }
        const from: u32 = if (node == NONE) 0 else node;
        self.dbg_from = from;
        self.dbg_child = child_on_path;

        // Mark leaf..from so descent can follow the chain of changed intrinsics
        // even through elements whose own bounds happen not to move.
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

        self.repositionFrom(from, child_on_path);
    }

    /// The root's own layout changes, so every position is recomputed, but the
    /// tree structure and all intrinsic sizes below it are reused.
    fn rootLayout(self: *Tree, delta: f32) void {
        self.els[0].fixed_w += delta;
        // root is fixed on both axes, so its intrinsic must track fixed_w or the
        // cached value goes stale -- harmless for layout, but inconsistent state
        self.els[0].intrinsic_w = self.els[0].fixed_w;
        self.els[0].bounds.w = self.els[0].fixed_w;
        self.repositionSubtree(0);
    }
};

// ----------------------------------------------------------------- harness

const Scenario = enum { full_refresh, unchanged, leaf_style, leaf_bounds, root_layout };

/// A fast path that is wrong is worthless. Snapshots the bounds the incremental
/// path produced, recomputes the whole layout from scratch, and compares.
var verify_leaf: u32 = NONE;

fn verifyLayout(t: *Tree, label: []const u8) void {
    for (t.els[0..t.n], 0..) |e, i| {
        t.snapshot[i] = e.bounds;
        t.snap_intr[i] = .{ .w = e.intrinsic_w, .h = e.intrinsic_h };
    }
    t.intrinsicAll();
    // report stale intrinsics before layout masks them
    var stale: u32 = 0;
    for (t.els[0..t.n], 0..) |e, i| {
        if (e.intrinsic_w != t.snap_intr[i].w or e.intrinsic_h != t.snap_intr[i].h) {
            if (stale < 8) std.debug.print(
                "  STALE INTRINSIC el {d}: incremental {d}x{d} != full {d}x{d} (parent {d}, h {s})\n",
                .{ i, t.snap_intr[i].w, t.snap_intr[i].h, e.intrinsic_w, e.intrinsic_h, e.parent, @tagName(e.h_mode) },
            );
            stale += 1;
        }
    }
    if (stale > 0) std.debug.print("  stale intrinsics: {d}; measured leaf = {d}\n", .{ stale, verify_leaf });
    t.positionAll();
    for (t.els[0..t.n], 0..) |e, i| {
        if (!e.bounds.eq(t.snapshot[i])) {
            std.debug.print(
                "VERIFY FAIL {s}: element {d} incremental {any} != full {any}\n",
                .{ label, i, t.snapshot[i], e.bounds },
            );
            // dump the chain from the bad element up to the root
            std.debug.print(
                "  leaf={d} climb stopped at from={d} child_on_path={d}; from.grow_main={any}\n",
                .{ verify_leaf, t.dbg_from, t.dbg_child, if (t.dbg_from == NONE) false else t.els[t.dbg_from].any_grow_main },
            );
            {
                // is the bad element a descendant of the climb entry point?
                var a: u32 = @intCast(i);
                var depth: u32 = 0;
                while (a != NONE and a != t.dbg_from) : (a = t.els[a].parent) depth += 1;
                std.debug.print("  el {d} is {s} from (depth {d}); leaf chain:", .{
                    i, if (a == t.dbg_from) "under" else "NOT under", depth,
                });
                var l: u32 = verify_leaf;
                while (l != NONE) : (l = t.els[l].parent) std.debug.print(" {d}", .{l});
                std.debug.print("\n", .{});
            }
            std.debug.print("  chain from {d} up:\n", .{i});
            var dn: u32 = @intCast(i);
            while (dn != NONE) : (dn = t.els[dn].parent) {
                const d = t.els[dn];
                std.debug.print(
                    "    el {d:>4} parent {d:>4} axis {s} w {s} h {s} kids {d:>3} pad {d} gap {d} grow_main {any} intr {d}x{d}\n",
                    .{ dn, d.parent, @tagName(d.axis), @tagName(d.w_mode), @tagName(d.h_mode), d.child_count, d.pad, d.gap, d.any_grow_main, d.intrinsic_w, d.intrinsic_h },
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
            if (c.entity == 0) @panic("full refresh must render entities");
            if (c.region == 0) @panic("full refresh must register input regions");
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

/// Silent single-scenario runner so perf counters divide by iteration count.
/// Usage: incremental perf-<scenario> [iters]
fn perfMain(gpa: std.mem.Allocator, which: Scenario, iters: usize) !void {
    var t = try Tree.alloc(gpa, .wide, 1649, 0x5eed);
    defer t.free(gpa);
    t.ctr.clear();
    t.fullRefresh();

    const leaf: u32 = blk: {
        var k: u32 = 1;
        while (k < t.n) : (k += 1) {
            const e = t.els[k];
            if (e.first_child != NONE) continue;
            const fixed_on_main = switch (t.els[e.parent].axis) {
                .row => e.w_mode == .fixed,
                .col => e.h_mode == .fixed,
            };
            if (fixed_on_main and k > t.n / 2) break :blk k;
        }
        @panic("no leaf");
    };

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
        break :blk null;
    };
    if (perf_scenario) |w| {
        try perfMain(gpa, w, 20000);
        return;
    }

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

    std.debug.print("{s:<7} {s:>6} {s:<14} {s:>10} {s:>10} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7}\n", .{
        "topo",  "count", "scenario", "mean ns", "best ns",
        "build", "intr",  "pos",      "paint",   "entity",
        "region",
    });
    std.debug.print("--------------------------------------------------------------------------------------------------\n", .{});

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
                checkCounters(s, sm.ctr, t.n);
                sum += sm.ns;
                if (sm.ns < best) best = sm.ns;
                last = sm.ctr;
            }

            std.debug.print("{s:<7} {d:>6} {s:<14} {d:>10} {d:>10} {d:>7} {d:>7} {d:>7} {d:>7} {d:>7} {d:>7}\n", .{
                @tagName(case.topo), case.count,
                @tagName(s),         sum / iters,
                best,                last.build,
                last.intrinsic,      last.position,
                last.paint,          last.entity,
                last.region,
            });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("sizeOf(Element)={d} sizeOf(Quad)={d}\n", .{ @sizeOf(Element), @sizeOf(Quad) });
    std.debug.print("counters are from the last measured frame; work is asserted every frame\n", .{});
    std.debug.print("tree is retained, so incremental frames allocate nothing\n", .{});
}
