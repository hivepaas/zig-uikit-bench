//! Zig counterpart to GPUI's `RandomizedTree/full refresh` benchmark.
//!
//! Replicates GPUI's topology semantics (gpui::randomized_element_tree):
//!   Wide   - every element is a direct child of the root
//!   Deep   - every element is the child of the previous element
//!   Mixed  - elements choose parents throughout the existing tree
//!   Narrow - four in five extend one deep branch, the rest are root children
//!
//! Measures one full frame: build element tree -> layout -> paint (emit quads).
//! Element storage is a bump arena reset each frame, so allocation count per
//! frame is O(1) rather than O(elements). Layout and paint are iterative with
//! an explicit work stack: no recursion, so Deep/Narrow trees of any size are
//! fine (GPUI needs its `stacker` feature past ~384-512 deep elements).

const std = @import("std");

// ---------------------------------------------------------------- bump arena

const Bump = struct {
    buf: []u8,
    off: usize = 0,
    allocs: usize = 0,
    peak: usize = 0,

    fn init(buf: []u8) Bump {
        return .{ .buf = buf };
    }

    fn reset(self: *Bump) void {
        if (self.off > self.peak) self.peak = self.off;
        self.off = 0;
        self.allocs = 0;
    }

    fn allocSlice(self: *Bump, comptime T: type, n: usize) []T {
        const al = @alignOf(T);
        const start = std.mem.alignForward(usize, self.off, al);
        const end = start + n * @sizeOf(T);
        if (end > self.buf.len) @panic("bump arena exhausted");
        self.off = end;
        self.allocs += 1;
        const ptr: [*]T = @ptrCast(@alignCast(self.buf.ptr + start));
        return ptr[0..n];
    }
};

// ------------------------------------------------------------------ geometry

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

const Axis = enum(u8) { row, col };

const SizeMode = enum(u8) { fixed, grow, fit };

// ------------------------------------------------------------------ elements
//
// Index-based arena, struct-of-arrays-ish AoS. No pointers, no vtables:
// dispatch is a switch the compiler can inline, which is the whole point of
// the comparison against GPUI's `Box<dyn Element>` tree.

const NONE: u32 = std.math.maxInt(u32);

/// Monotonic nanoseconds. `std.time.Timer` was removed when 0.16 moved I/O
/// behind the `Io` interface, so go to the clock directly.
fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Element = struct {
    // tree links
    first_child: u32 = NONE,
    next_sibling: u32 = NONE,
    parent: u32 = NONE,
    child_count: u32 = 0,

    // style
    axis: Axis = .col,
    w_mode: SizeMode = .fit,
    h_mode: SizeMode = .fit,
    fixed_w: f32 = 0,
    fixed_h: f32 = 0,
    pad: f32 = 0,
    gap: f32 = 0,
    corner: f32 = 0,
    color: u32 = 0,

    // layout output
    intrinsic_w: f32 = 0,
    intrinsic_h: f32 = 0,
    bounds: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

const Quad = struct {
    rect: Rect,
    color: u32,
    corner: f32,
};

const Topology = enum { wide, deep, mixed, narrow };

// --------------------------------------------------------------------- build

/// Builds a tree of `count` elements (plus a root) with the given topology.
/// Mirrors how GPUI's generator attaches each new element.
fn buildTree(bump: *Bump, rng: *std.Random.DefaultPrng, topo: Topology, count: usize) []Element {
    const els = bump.allocSlice(Element, count + 1);
    const r = rng.random();

    els[0] = .{ .axis = .col, .w_mode = .fixed, .h_mode = .fixed, .fixed_w = 1920, .fixed_h = 1080, .pad = 8, .gap = 4 };

    var last_deep: u32 = 0;

    var i: usize = 1;
    while (i <= count) : (i += 1) {
        const parent: u32 = switch (topo) {
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

        // prepend as child of parent (O(1), order irrelevant to cost)
        els[i].next_sibling = els[parent].first_child;
        els[parent].first_child = @intCast(i);
        els[parent].child_count += 1;

        last_deep = @intCast(i);
    }

    return els;
}

// -------------------------------------------------------------------- layout
//
// Two iterative passes with an explicit stack:
//   pass 1, bottom-up: intrinsic (fit) sizes
//   pass 2, top-down:  final bounds, distributing grow space
// Post-order is produced once and reused by both passes and by paint.

fn postOrder(bump: *Bump, els: []Element) []u32 {
    const order = bump.allocSlice(u32, els.len);
    const stack = bump.allocSlice(u32, els.len);
    var sp: usize = 0;
    var n: usize = 0;

    stack[sp] = 0;
    sp += 1;
    while (sp > 0) {
        sp -= 1;
        const idx = stack[sp];
        order[n] = idx;
        n += 1;
        var c = els[idx].first_child;
        while (c != NONE) {
            stack[sp] = c;
            sp += 1;
            c = els[c].next_sibling;
        }
    }
    // `order` is currently pre-order; reversing gives a valid bottom-up order.
    std.mem.reverse(u32, order[0..n]);
    return order[0..n];
}

fn layoutIntrinsic(els: []Element, bottom_up: []const u32) void {
    for (bottom_up) |idx| {
        const e = &els[idx];
        var main_sz: f32 = 0;
        var cross: f32 = 0;
        var kids: u32 = 0;

        var c = e.first_child;
        while (c != NONE) : (c = els[c].next_sibling) {
            const ch = &els[c];
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
    }
}

fn layoutPosition(els: []Element, pre_order: []const u32) void {
    els[0].bounds = .{ .x = 0, .y = 0, .w = els[0].fixed_w, .h = els[0].fixed_h };

    for (pre_order) |idx| {
        const e = &els[idx];
        const inner_x = e.bounds.x + e.pad;
        const inner_y = e.bounds.y + e.pad;
        const inner_w = @max(0, e.bounds.w - e.pad * 2);
        const inner_h = @max(0, e.bounds.h - e.pad * 2);

        // how much main-axis space the fixed/fit children already claim
        var used: f32 = 0;
        var grow_n: f32 = 0;
        var kids: u32 = 0;
        var c = e.first_child;
        while (c != NONE) : (c = els[c].next_sibling) {
            const ch = &els[c];
            const grows = switch (e.axis) {
                .row => ch.w_mode == .grow,
                .col => ch.h_mode == .grow,
            };
            if (grows) {
                grow_n += 1;
            } else {
                used += switch (e.axis) {
                    .row => ch.intrinsic_w,
                    .col => ch.intrinsic_h,
                };
            }
            kids += 1;
        }
        if (kids > 1) used += e.gap * @as(f32, @floatFromInt(kids - 1));

        const avail = switch (e.axis) {
            .row => inner_w,
            .col => inner_h,
        };
        const extra = @max(0, avail - used);
        const per_grow = if (grow_n > 0) extra / grow_n else 0;

        var cursor: f32 = switch (e.axis) {
            .row => inner_x,
            .col => inner_y,
        };
        c = e.first_child;
        while (c != NONE) : (c = els[c].next_sibling) {
            const ch = &els[c];
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

            switch (e.axis) {
                .row => {
                    ch.bounds = .{ .x = cursor, .y = inner_y, .w = cw, .h = chh };
                    cursor += cw + e.gap;
                },
                .col => {
                    ch.bounds = .{ .x = inner_x, .y = cursor, .w = cw, .h = chh };
                    cursor += chh + e.gap;
                },
            }
        }
    }
}

// --------------------------------------------------------------------- paint

fn paint(bump: *Bump, els: []const Element, pre_order: []const u32) []Quad {
    const quads = bump.allocSlice(Quad, pre_order.len);
    var n: usize = 0;
    for (pre_order) |idx| {
        const e = &els[idx];
        if (e.bounds.w <= 0 or e.bounds.h <= 0) continue;
        quads[n] = .{ .rect = e.bounds, .color = e.color, .corner = e.corner };
        n += 1;
    }
    return quads[0..n];
}

// ----------------------------------------------------------------- one frame

const FrameCost = struct {
    build_ns: u64,
    layout_ns: u64,
    paint_ns: u64,
    total_ns: u64,
    allocs: usize,
    bytes: usize,
    quads: usize,
};

fn frame(bump: *Bump, seed: u64, topo: Topology, count: usize) FrameCost {
    bump.reset();
    var rng = std.Random.DefaultPrng.init(seed);
    const t0 = nowNs();
    const els = buildTree(bump, &rng, topo, count);
    const t1 = nowNs();

    const bottom_up = postOrder(bump, els);
    layoutIntrinsic(els, bottom_up);
    // pre-order is the reverse of the bottom-up order
    const pre = bump.allocSlice(u32, bottom_up.len);
    for (bottom_up, 0..) |v, i| pre[bottom_up.len - 1 - i] = v;
    layoutPosition(els, pre);
    const t2 = nowNs();

    const quads = paint(bump, els, pre);
    const t3 = nowNs();

    std.mem.doNotOptimizeAway(quads.ptr);

    return .{
        .build_ns = t1 - t0,
        .layout_ns = t2 - t1,
        .paint_ns = t3 - t2,
        .total_ns = t3 - t0,
        .allocs = bump.allocs,
        .bytes = bump.off,
        .quads = quads.len,
    };
}

// ----------------------------------------------------------------------- main

const Case = struct { topo: Topology, count: usize };

pub fn main() !void {
    const backing = try std.heap.page_allocator.alloc(u8, 64 << 20);
    defer std.heap.page_allocator.free(backing);
    var bump = Bump.init(backing);

    const cases = [_]Case{
        // GPUI family "wide": 128..=2048 elements, Wide topology
        .{ .topo = .wide, .count = 128 },
        .{ .topo = .wide, .count = 256 },
        .{ .topo = .wide, .count = 512 },
        .{ .topo = .wide, .count = 1024 },
        .{ .topo = .wide, .count = 2048 },
        // GPUI families "any"/"tall": 32..=256 (TALL_MAX_ELEMENTS)
        .{ .topo = .mixed, .count = 256 },
        .{ .topo = .deep, .count = 256 },
        .{ .topo = .narrow, .count = 256 },
        // past GPUI's stacker-free recursion limit (~384-512 deep)
        .{ .topo = .deep, .count = 2048 },
    };

    const warmup = 200;
    const iters = 2000;

    std.debug.print("{s:<8} {s:>6} {s:>10} {s:>10} {s:>10} {s:>11} {s:>7} {s:>9} {s:>7}\n", .{
        "topo", "count", "build ns", "layout ns", "paint ns", "total ns", "allocs", "bytes", "quads",
    });
    std.debug.print("--------------------------------------------------------------------------------------------\n", .{});

    for (cases) |case| {
        var w: usize = 0;
        while (w < warmup) : (w += 1) {
            _ = frame(&bump, 0x5eed, case.topo, case.count);
        }

        var best: FrameCost = frame(&bump, 0x5eed, case.topo, case.count);
        var sum_total: u64 = 0;
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const c = frame(&bump, 0x5eed + @as(u64, @intCast(i % 8)), case.topo, case.count);
            sum_total += c.total_ns;
            if (c.total_ns < best.total_ns) best = c;
        }
        const mean = sum_total / iters;

        std.debug.print("{s:<8} {d:>6} {d:>10} {d:>10} {d:>10} {d:>11} {d:>7} {d:>9} {d:>7}\n", .{
            @tagName(case.topo), case.count,
            best.build_ns,       best.layout_ns,
            best.paint_ns,       mean,
            best.allocs,         best.bytes,
            best.quads,
        });
    }

    std.debug.print("\ntotal ns = mean over {d} iters; build/layout/paint = best frame\n", .{iters});
    std.debug.print("allocs = arena allocations per frame (O(1) in element count)\n", .{});
}
