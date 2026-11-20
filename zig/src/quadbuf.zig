//! Is a persistently-mapped quad buffer actually necessary?
//!
//! Run 2 claimed that without one, the `leaf_style` win (2.32 ms -> ~0) "stops
//! at the CPU boundary", because the renderer would re-upload the whole quad
//! buffer every frame. That claim was made without measuring, and the quad
//! buffer for GPUI's wide/seed-0 tree is only 1649 * 28 = 45 KB.
//!
//! This measures writes into real GPU-visible memory, mapped through Vulkan:
//!   - full rewrite of every quad   (what a naive renderer does each frame)
//!   - single-quad patch            (what `leaf_style` needs)
//!   - a contiguous dirty range     (what `leaf_bounds` needs)
//!
//! No swapchain, no pipeline, no command buffers: the question is purely the
//! cost of writing to host-visible device memory. That makes this the
//! optimistic case for both sides, and the comparison between them fair. A
//! staging-buffer path would be strictly more expensive than the full rewrite
//! measured here.

const std = @import("std");
const c = @import("vk");

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Matches the Quad in incremental.zig: rect + colour + corner + visible.
const Quad = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: u32,
    corner: f32,
    visible: u32,
};

const QUAD_COUNTS = [_]usize{ 1649, 2048, 10_000, 50_000 };

fn check(r: c.VkResult, what: []const u8) void {
    if (r != c.VK_SUCCESS) {
        std.debug.print("vulkan call failed ({s}): {d}\n", .{ what, r });
        @panic("vulkan");
    }
}

const Target = struct {
    name: []const u8,
    ptr: [*]Quad,
    capacity: usize,
};

fn fillAll(t: Target, n: usize, seed: u32) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        t.ptr[i] = .{
            .x = @floatFromInt(i & 1023),
            .y = @floatFromInt((i >> 10) & 1023),
            .w = 120,
            .h = 18,
            .color = seed +% @as(u32, @intCast(i)),
            .corner = 4,
            .visible = 1,
        };
    }
}

fn patchOne(t: Target, idx: usize, seed: u32) void {
    t.ptr[idx] = .{
        .x = 10,
        .y = 20,
        .w = 120,
        .h = 18,
        .color = seed,
        .corner = 4,
        .visible = 1,
    };
}

fn patchRange(t: Target, start: usize, len: usize, seed: u32) void {
    var i = start;
    const end = start + len;
    while (i < end) : (i += 1) patchOne(t, i, seed +% @as(u32, @intCast(i)));
}

const Row = struct {
    target: []const u8,
    quads: usize,
    full_ns: u64,
    one_ns: u64,
    range_ns: u64,
};

fn measure(t: Target, n: usize, iters: usize) Row {
    // warm up: first touch of mapped device memory faults pages in
    var w: usize = 0;
    while (w < 32) : (w += 1) fillAll(t, n, @intCast(w));

    var best_full: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        fillAll(t, n, @intCast(i));
        const dt = nowNs() - t0;
        if (dt < best_full) best_full = dt;
    }

    // single-quad patch, measured in batches since one patch is below timer
    // resolution; 1000 patches per sample, then divided back out
    const batch = 1000;
    var best_one: u64 = std.math.maxInt(u64);
    i = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        var k: usize = 0;
        while (k < batch) : (k += 1) patchOne(t, (k * 7919) % n, @intCast(i));
        const dt = nowNs() - t0;
        if (dt < best_one) best_one = dt;
    }

    const range_len = @max(1, n / 2);
    var best_range: u64 = std.math.maxInt(u64);
    i = 0;
    while (i < iters) : (i += 1) {
        const t0 = nowNs();
        patchRange(t, 0, range_len, @intCast(i));
        const dt = nowNs() - t0;
        if (dt < best_range) best_range = dt;
    }

    return .{
        .target = t.name,
        .quads = n,
        .full_ns = best_full,
        .one_ns = best_one / batch,
        .range_ns = best_range,
    };
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const max_quads = QUAD_COUNTS[QUAD_COUNTS.len - 1];
    const bytes: c.VkDeviceSize = max_quads * @sizeOf(Quad);

    // ---------------------------------------------------------------- vulkan
    var app = c.VkApplicationInfo{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "quadbuf",
        .apiVersion = c.VK_API_VERSION_1_1,
    };
    var ici = c.VkInstanceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };
    var instance: c.VkInstance = undefined;
    check(c.vkCreateInstance(&ici, null, &instance), "vkCreateInstance");
    defer c.vkDestroyInstance(instance, null);

    var n_dev: u32 = 0;
    check(c.vkEnumeratePhysicalDevices(instance, &n_dev, null), "enumerate count");
    if (n_dev == 0) {
        std.debug.print("no vulkan device\n", .{});
        return;
    }
    const devs = try gpa.alloc(c.VkPhysicalDevice, n_dev);
    defer gpa.free(devs);
    check(c.vkEnumeratePhysicalDevices(instance, &n_dev, devs.ptr), "enumerate");

    // prefer a real GPU over a software implementation
    var phys = devs[0];
    for (devs) |d| {
        var props: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(d, &props);
        if (props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU or
            props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU)
        {
            phys = d;
            break;
        }
    }
    var props: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(phys, &props);
    std.debug.print("device: {s}\n\n", .{@as([*:0]const u8, @ptrCast(&props.deviceName))});

    var mem_props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(phys, &mem_props);

    var qprio: f32 = 1.0;
    var qci = c.VkDeviceQueueCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = 0,
        .queueCount = 1,
        .pQueuePriorities = &qprio,
    };
    var dci = c.VkDeviceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
    };
    var device: c.VkDevice = undefined;
    check(c.vkCreateDevice(phys, &dci, null, &device), "vkCreateDevice");
    defer c.vkDestroyDevice(device, null);

    var bci = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = bytes,
        .usage = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };

    const HOST_VISIBLE = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
    const HOST_COHERENT = c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    const HOST_CACHED = c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    const DEVICE_LOCAL = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

    // Two interesting heaps: device-local + host-visible (resizable BAR, what a
    // persistently-mapped buffer wants) and host-cached (fast CPU writes, but
    // the GPU reads it over the bus).
    const Want = struct { name: []const u8, require: u32, forbid: u32 };
    const wants = [_]Want{
        .{ .name = "DEVICE_LOCAL|HOST_VISIBLE (BAR)", .require = DEVICE_LOCAL | HOST_VISIBLE, .forbid = HOST_CACHED },
        .{ .name = "HOST_VISIBLE|HOST_CACHED", .require = HOST_VISIBLE | HOST_CACHED, .forbid = 0 },
        .{ .name = "HOST_VISIBLE|HOST_COHERENT", .require = HOST_VISIBLE | HOST_COHERENT, .forbid = DEVICE_LOCAL },
    };

    // fixed storage: 3 candidate memory types + the heap reference, times
    // QUAD_COUNTS. std.ArrayList's init signature changed again in 0.17.
    var rows: [32]Row = undefined;
    var n_rows: usize = 0;

    for (wants) |want| {
        var chosen: ?u32 = null;
        var ti: u32 = 0;
        while (ti < mem_props.memoryTypeCount) : (ti += 1) {
            const f = mem_props.memoryTypes[ti].propertyFlags;
            if ((f & want.require) == want.require and (f & want.forbid) == 0) {
                chosen = ti;
                break;
            }
        }
        const type_index = chosen orelse {
            std.debug.print("{s}: no such memory type\n", .{want.name});
            continue;
        };

        var buffer: c.VkBuffer = undefined;
        check(c.vkCreateBuffer(device, &bci, null, &buffer), "vkCreateBuffer");
        defer c.vkDestroyBuffer(device, buffer, null);

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(device, buffer, &req);

        var mai = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = type_index,
        };
        var memory: c.VkDeviceMemory = undefined;
        const ar = c.vkAllocateMemory(device, &mai, null, &memory);
        if (ar != c.VK_SUCCESS) {
            std.debug.print("{s}: allocation failed ({d})\n", .{ want.name, ar });
            continue;
        }
        defer c.vkFreeMemory(device, memory, null);
        check(c.vkBindBufferMemory(device, buffer, memory, 0), "bind");

        var mapped: ?*anyopaque = null;
        check(c.vkMapMemory(device, memory, 0, c.VK_WHOLE_SIZE, 0, &mapped), "map");
        defer c.vkUnmapMemory(device, memory);

        const heap = mem_props.memoryTypes[type_index].heapIndex;
        std.debug.print("{s}: type {d}, heap {d} ({d} MB)\n", .{
            want.name,                                              type_index,
            heap,                                                   mem_props.memoryHeaps[heap].size / (1024 * 1024),
        });

        const target = Target{
            .name = want.name,
            .ptr = @ptrCast(@alignCast(mapped.?)),
            .capacity = max_quads,
        };
        for (QUAD_COUNTS) |n| {
            rows[n_rows] = measure(target, n, 200);
            n_rows += 1;
        }
    }

    // plain heap memory as the reference point
    const host = try gpa.alloc(Quad, max_quads);
    defer gpa.free(host);
    const host_target = Target{ .name = "plain heap (reference)", .ptr = host.ptr, .capacity = max_quads };
    for (QUAD_COUNTS) |n| {
        rows[n_rows] = measure(host_target, n, 200);
        n_rows += 1;
    }

    // ------------------------------------------------------------------ report
    std.debug.print("\n{s:<34} {s:>7} {s:>8} {s:>11} {s:>11} {s:>11} {s:>10}\n", .{
        "target", "quads", "KB", "full ns", "1 quad ns", "half ns", "full GB/s",
    });
    std.debug.print("------------------------------------------------------------------------------------------------\n", .{});
    for (rows[0..n_rows]) |r| {
        const kb = r.quads * @sizeOf(Quad) / 1024;
        const gbs = @as(f64, @floatFromInt(r.quads * @sizeOf(Quad))) /
            @as(f64, @floatFromInt(r.full_ns));
        std.debug.print("{s:<34} {d:>7} {d:>8} {d:>11} {d:>11} {d:>11} {d:>10.2}\n", .{
            r.target, r.quads, kb, r.full_ns, r.one_ns, r.range_ns, gbs,
        });
    }
    std.debug.print("\nbest-of-200; 1-quad timed in batches of 1000 and divided back out\n", .{});
    std.debug.print("sizeOf(Quad)={d}\n", .{@sizeOf(Quad)});
}
