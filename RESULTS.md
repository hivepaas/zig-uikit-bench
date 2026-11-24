# Results — 2026-11-20

## Machine

| | |
|---|---|
| CPU | AMD Ryzen 9 9950X, 16C/32T (Zen 5) |
| GPU | AMD, `amdgpu`, PCI `1002:13C0` |
| OS | Ubuntu 26.04.1 LTS, kernel 7.0.0-43-generic |
| Zig | 0.17.0 |
| Rust | rustc 1.99.1 / cargo 1.99.1 |
| GPUI | `gpui-pre-platform` 0.3.11 (snapshot of `zed@f816e1f`) |

Both sides pinned to core 2. This is a fast desktop CPU — absolute numbers are
generous, ratios should travel better than the absolutes.

## GPUI baseline

`randomized_element_tree`, family `wide`, seed-0: **1649 elements, 11% entities,
19% handlers**. Window holds **8.3 MB** after the first frame.

| Scenario | allocs/frame | bytes/frame | cache miss/frame | wall/frame |
|---|---|---|---|---|
| full refresh | 8 451 | 4.746 MB | 290.8 K | 3.50 ms |
| **unchanged** | **8 454** | **4.746 MB** | 307.9 K | 3.91 ms |
| **leaf style** | **10 115** | **4.910 MB** | 305.8 K | 3.65 ms |
| root layout | 8 456 | 4.746 MB | 296.5 K | 2.78 ms |

Full refresh, additional counters:

| | |
|---|---|
| instructions | 34.526 M (foreground 34.525 M) |
| cycles | 13.303 M |
| IPC | 2.595 |
| branch misses | 41.296 K |
| page faults | 413 |
| window dirty-to-draw | mean 3.026 ms |
| window draw | mean 3.024 ms |
| frame budget overruns @120 fps | **0** |

Seed-1 for cross-check (**1535 elements, 24% entities, 30% handlers**, window
7.9 MB): full refresh 33.923 M instructions, 13.317 M cycles, 293.6 K cache
misses, 10 745 allocations.

> Criterion reported `samples: 1` at the measurement times used. Allocation and
> instruction counts are near-deterministic and trustworthy; the wall times are
> single samples and should not be quoted tightly.

## Zig prototype

`tree_bench`, two runs. `total ns` is the mean over 2000 iterations;
build/layout/paint are the best frame.

| topo | count | build ns | layout ns | paint ns | total ns (r1 / r2) | allocs | bytes | quads |
|---|---|---|---|---|---|---|---|---|
| wide | 128 | 850 | 1 180 | 110 | 2 219 / 2 177 | 5 | 13 416 | 111 |
| wide | 256 | 1 670 | 2 420 | 220 | 4 395 / 4 368 | 5 | 26 728 | 223 |
| wide | 512 | 3 340 | 4 760 | 420 | 8 620 / 8 614 | 5 | 53 352 | 466 |
| wide | 1024 | 5 240 | 7 580 | 710 | 16 518 / 15 093 | 5 | 106 600 | 902 |
| wide | 2048 | 10 440 | 15 230 | 1 380 | 27 947 / 28 641 | 5 | 213 096 | 1 809 |
| mixed | 256 | 1 500 | 1 330 | 120 | 3 102 / 3 106 | 5 | 26 728 | 129 |
| deep | 256 | 1 330 | 2 260 | 70 | 3 740 | 5 | 26 728 | 8 |
| narrow | 256 | 1 480 | 1 740 | 160 | 3 525 | 5 | 26 728 | 185 |
| deep | 2048 | 10 630 | 18 460 | 700 | 38 022 | 5 | 213 096 | 7 |

`perf stat` on `single` — 20 000 iterations of `wide/2048`:

| | total | per frame |
|---|---|---|
| instructions | 13 188 366 591 | **659 418** |
| cycles | 3 385 338 657 | 169 267 |
| cache misses | 72 629 | **3.6** |
| branch misses | 13 326 355 | 666 |
| elapsed | 0.6107 s | 30.5 µs |

IPC **3.90**.

Allocations are **5 per frame at every element count** — the arena is reset per
frame, so allocation count is O(1) in element count rather than O(n).

`deep/2048` runs fine. GPUI needs its `stacker` feature past roughly 384–512
deep elements, because its layout and paint recurse once per element; the
prototype's layout and paint are iterative over an explicit work stack.

## Normalised comparison

Per element, per frame. GPUI at 1649 elements vs prototype at 2048.

| | GPUI | prototype | ratio |
|---|---|---|---|
| instructions | 20 923 | 322 | 65× |
| allocations | 5.1 | 0.0024 | ~2 100× |
| allocated bytes | 2 880 | 104 | 28× |
| cache misses | 176 | 0.0018 | ~98 000× |
| IPC | 2.60 | 3.90 | 1.5× |

## What may and may not be concluded

**Not valid: the 65× instruction ratio.** The prototype omits entity dispatch,
handler registration, real flexbox, style refinement, hit-testing, a11y, the
scene layer stack, and all GPU work — and `window draw` alone is 3.02 of GPUI's
3.50 ms. Do not quote this number. See README, "What the Zig prototype does NOT do".

**Valid, because they follow from memory layout rather than feature count:**

- **8 451 allocations/frame vs 5.** GPUI pays roughly 5 heap allocations per
  element per frame, inherent to `Box<dyn Element>` plus Taffy nodes plus style
  boxes. A full-featured arena design would land in the tens, not the thousands.
- **290.8 K cache misses/frame vs 3.6.** A heap-scattered boxed tree versus one
  contiguous buffer. This also explains the IPC gap. Adding features does not
  make an arena non-contiguous.
- **4.75 MB allocated per frame, 8.3 MB resident per window** at 1649 elements.

**Valid and decisive: there is no frame-time problem to solve.** 1649 elements,
full refresh, 3.50 ms wall — 42% of a 120 fps budget, zero overruns. What the
arena buys is p99 jitter and memory footprint, not mean frame time.

## The finding that changes the decision

`unchanged` costs the same as `full refresh`: 8 454 vs 8 451 allocations,
4.746 MB both. `leaf style` costs **more** (10 115).

GPUI's dirty tracking is per **view**, not per **element**. Notify a root and
the entire element subtree is rebuilt, laid out and painted again. Savings come
only from splitting an app into many small entities so that a change notifies a
small subtree.

So the opportunity is not per-element speed. It is **element-level incremental
rebuild**: skipping unchanged subtrees at element granularity would take
`unchanged` and `leaf style` from near-full cost to near zero — and those are
~95% of frames in a real app.

That is the next measurement, and it is the one that decides the project.

## Next

1. **Decisive:** prototype element-level memoisation; re-measure `unchanged`.
2. Add entity dispatch, handler registration and real flexbox to the prototype
   so an instruction ratio becomes honest.
3. Separate GPUI's CPU cost from GPU submit to compare the same scope.
4. Raise criterion sample counts for wall-time confidence.
5. Re-run on a slower machine and on an ARM machine; check whether the ratios hold.

---

# Run 2 — element-level memoisation (2026-11-20)

The decisive experiment from Run 1: if GPUI's dirty tracking is per *view*, what
does per-*element* tracking cost on the same change classes?

`zig/src/incremental.zig`. The tree is **retained** (allocated once, mutated in
place) rather than rebuilt into a frame arena, because an arena reset wholesale
is incompatible with reusing last frame's subtrees. Work counters are asserted
every frame, counting work units — child slots examined — not calls.

## Measured

ns, mean over 2000 frames, pinned to core 2. **Zero allocations on every
incremental frame.**

| topo | count | full_refresh | unchanged | leaf_style | leaf_bounds | root_layout |
|---|---|---|---|---|---|---|
| wide | 1649 | 26 692 | **15** | **15** | 9 984 | 8 253 |
| wide | 2048 | 32 084 | **15** | **15** | 12 426 | 10 297 |
| mixed | 256 | 3 694 | **15** | **16** | **41** | 1 069 |
| deep | 256 | 4 244 | **15** | **15** | 21 | 39 |
| narrow | 256 | 4 035 | **15** | **16** | 21 | 789 |

Work counters, last frame (build / intrinsic / position / paint):

| topo/count | full_refresh | unchanged | leaf_style | leaf_bounds | root_layout |
|---|---|---|---|---|---|
| wide/1649 | 1649/3299/3298/1650 | 0/0/0/0 | 0/0/0/1 | 0/1651/3298/1650 | 0/0/3298/1650 |
| mixed/256 | 256/513/512/257 | 0/0/0/0 | 0/0/0/1 | 0/18/8/1 | 0/0/482/353 |
| deep/256 | 256/513/512/257 | 0/0/0/0 | 0/0/0/1 | 0/3/2/1 | 0/0/6/5 |

## Against GPUI, same element count (1649)

| | GPUI | Zig incremental |
|---|---|---|
| `unchanged` | 3.91 ms, 8 454 allocations | 15 ns, 0 allocations |
| `leaf style` | 3.65 ms, 10 115 allocations | 15 ns, 0 allocations |

## What this does and does not establish

**Establishes:** per-element dirty tracking makes `unchanged` and `leaf_style`
effectively free where per-view tracking pays full-refresh cost. The retained
tree supports it, and the mechanism survives the work-counter assertions.

**Does not establish that a real toolkit hits 15 ns.** That path is close to an
empty function. A complete toolkit still owes input processing, the dirty scan
over notified views, animation ticks, entity dispatch and text.

**GPU present does not go away.** `window draw` is 3.02 of GPUI's 3.91 ms, so the
CPU share is only ~0.9 ms. Capturing the `leaf_style` win requires a
persistently-mapped quad buffer patched in place; a renderer that re-uploads the
whole buffer each frame saves the CPU-side construction and nothing else. This is
a **renderer design requirement**, not a free consequence of memoisation.

**Memoisation does not save wide trees from size changes.** `wide/1649
leaf_bounds` costs 9 984 ns and the counters show why: all 1649 siblings are
rescanned (position 3298) and all 1650 repainted. Flexbox must redistribute grow
space across every sibling when one child's size changes. `mixed/256` is 41 ns,
O(depth). **The benefit is topology-dependent: deeply nested UIs gain a lot, flat
lists of many siblings gain nothing.**

Not yet implemented, and it would fix much of that: if no sibling uses `grow`
along the main axis, a size change only shifts siblings *after* it, so the grow
redistribution pass can be skipped entirely.

**Memoisation is not free.** `full_refresh` costs 26 692 ns here versus roughly
22 500 ns for the plain arena at the same 1649 elements — about **18% more** on
the full-refresh path, for the bounds comparisons and per-element quad slots. The
trade is clearly correct given `unchanged`/`leaf_style` are ~95% of real frames.

**Degenerate trees:** `deep` and `narrow` collapse to ~7 visible quads because
nested padding drives bounds to zero. Their leaf_bounds figures reflect a
degenerate tree, not a result.

## Verdict

There is a real technical reason to build the toolkit, and it is not per-element
speed — it is **reactive granularity**. GPUI rebuilds an element subtree whenever
its view is notified; doing it per element instead takes the common frame from
~3.9 ms to approximately nothing, at the cost of ~18% on full refresh.

Whether that converts into a user-visible win depends on two things this run did
not measure: how much of GPUI's 3.9 ms is CPU that a real toolkit would actually
avoid, and whether the renderer can patch its quad buffer in place.

## Next

1. Separate GPUI's CPU cost from GPU submit, so the `unchanged` comparison is
   scoped to work a real toolkit could actually skip.
2. Add the no-`grow` fast path and re-measure `wide/leaf_bounds`.
3. Add entity dispatch, handler registration and real flexbox, then re-measure
   `full_refresh` — the 18% memoisation overhead will move.
4. Fix the degenerate `deep`/`narrow` scenes (clamp padding) so their numbers mean something.
5. Prototype a persistently-mapped quad buffer and confirm a single-quad patch
   reaches the GPU without a full re-upload.

---

# Run 3 — separating CPU from GPU (2026-11-20)

Run 2 left one thing blocking any quotable number: how much of GPUI's frame is
CPU a real toolkit could skip, versus GPU submit it would still pay.

`perf record` is unavailable here — Ubuntu 26.04 confines perf_event sampling
(`perf stat` counting works, sampling returns "Access to performance monitoring
and observability operations is limited" even at `perf_event_paranoid=2`). So the
split is derived from counters plus a measured clock, and cross-checked with a
driver swap.

## Measured clock on core 2

| source | cycles | elapsed | GHz |
|---|---|---|---|
| pure-CPU spin loop | 3 041 345 639 | 544.63 ms | 5.58 |
| `zig-out/bin/single` | 3 385 338 657 | 610.68 ms | 5.54 |

Core 2 sustains **~5.55 GHz** on CPU-bound work.

## `unchanged`, wide/seed-0 (1649 elements), by driver

| | amdgpu | lavapipe (software Vulkan) |
|---|---|---|
| instructions/frame | 34.513 M | 55.095 M (+60%) |
| cycles/frame | 12.856 M | 21.472 M |
| wall/frame | 3.121 ms | 3.452 ms (**+11%**) |
| window dirty-to-draw | 2.895 ms | 3.132 ms |
| window draw | 2.893 ms | 3.128 ms |
| foreground executor work | 0.990 ms | 1.064 ms |
| IPC | 2.684 | 2.566 |

## The split

12.856 M cycles at 5.55 GHz = **2.32 ms executing**, against 3.121 ms wall:

| | ms | share |
|---|---|---|
| CPU executing | 2.32 | **74%** |
| blocked (GPU submit, present, syscalls) | 0.81 | 26% |

An earlier run reported `foreground share of instructions: 1.000`, so all 34.5 M
instructions are on the benchmark thread. There is no background thread doing
meaningful work to confound this.

The lavapipe swap confirms the shape: replacing a real GPU with a CPU rasteriser
adds **+60% instructions but only +11% wall**, because the GPU path was already
idle-waiting and lavapipe fills that gap rather than extending the frame.

### Correcting run 2

Run 2 claimed "`window draw` is 3.02 of 3.91 ms, so the CPU share is only
~0.9 ms." That was wrong. `window draw` is predominantly **CPU scene building**,
not GPU submit. The avoidable CPU cost is about 2.5x larger than stated.

## The quotable comparison

GPUI, `unchanged`, 1649 elements: **~2.32 ms of foreground CPU, 34.5 M
instructions, 8 454 allocations** — all of it rebuilding an element tree that did
not change. That is **28% of a 120 fps budget spent on a frame where nothing
happened.**

Per-element memoisation (run 2): **15 ns, 0 allocations.**

Allowing a real toolkit still owes input processing, the dirty scan and present —
call it 50-100 us — the saving is **~2.2-2.3 ms of CPU per common frame, roughly
23-46x less**.

## Side finding: software Vulkan is a viable fallback

lavapipe costs +11% wall on this UI workload. That supports taking the software
fallback for free from lavapipe/WARP rather than writing a CPU rasteriser, which
is why run 1's plan dropped that phase.

## What is still unmeasured

- Where the 2.32 ms goes inside GPUI (render / Taffy / paint / allocator). Needs
  sampling, so it needs `perf_event_paranoid` relaxed, or a build with
  instrumentation, or GPUI's `HeadlessAppContext` + `PlatformHeadlessRenderer`
  driven directly.
- Whether 50-100 us is the right floor for a real toolkit's fixed per-frame cost.
- Everything in run 2's "next" list that is still open: the no-`grow` fast path,
  entity dispatch and real flexbox in the prototype, the degenerate deep/narrow
  scenes, and the persistently-mapped quad buffer.

---

# Runs 4-5 — fast path, verification, entity dispatch (2026-11-20)

Steps (b) and (c) of the plan at the end of run 3. Step (a) — function-level
attribution inside GPUI's 2.32 ms — is still open: it needs `perf_event_paranoid`
relaxed or valgrind installed, both of which need root, so it was not done.

What replaced it: GPUI's own **`changing share`** group, which varies the fraction
of elements changed per frame. That answers the same question more directly.

## GPUI cost vs amount changed (wide/seed-0, 1649 elements)

| elements changed | instr/frame | allocs/frame | bytes/frame |
|---|---|---|---|
| **0%** (root notified, nothing changed) | 34.458 M | 8 454 | 4.746 M |
| 1% | 35.631 M | 10 342 | 5.076 M |
| 5% | 35.623 M | 10 346 | 5.076 M |
| 25% | 35.715 M | 10 352 | 5.080 M |
| **100%** | 36.299 M | 10 360 | 5.097 M |
| 5% spread | 35.315 M | 10 124 | 4.924 M |
| 25% spread | 35.517 M | 10 136 | 4.934 M |

**0% to 100% moves instructions by 5.3%.** Allocations rise 22.5%, and nearly all
of that is the 0%→1% step (8 454 → 10 342); 1% to 100% adds 18 allocations.
Locality is irrelevant: spread and localized differ by under 1%.

GPUI's frame cost is therefore independent of how much changed. Recolouring one
element of 1649 costs within 2% of recolouring all of them. The marginal cost of
a change is ~0; the fixed cost of *any* change is the whole tree. This is the
view-granularity finding stated by Zed's own harness rather than inferred.

## (b) The no-grow layout fast path

Two changes to the incremental path:

- Skip the grow-redistribution scan when no child uses `grow` along the parent's
  main axis. One child's size then cannot change another's.
- Reposition from the changed child onward rather than from the parent's content
  edge, breaking as soon as a sibling lands where it already was.

| | run 2 | run 4 |
|---|---|---|
| wide/1649 leaf_bounds | 9 984 | **6 048** (−39%) |
| wide/1649 root_layout | 8 253 | **5 780** (−30%) |
| wide/2048 leaf_bounds | 12 426 | **7 514** (−40%) |
| mixed/256 leaf_bounds | 41 | 87 (+112%) |

`mixed` got slower because **run 2's 41 ns was wrong** — see below.

## Verification found two real bugs, and one measurement artefact

`verifyLayout` snapshots what the incremental path produced, recomputes the whole
layout, and compares every element's bounds and intrinsic size.

1. **Wrong climb scope.** The climb set `top` to the first ancestor whose
   intrinsic was unchanged, then repositioned *that element among its siblings*.
   An element whose size did not change does not move — but its children still
   need laying out, starting from the one on the path.
2. **Descent gated on movement.** `drainReposition` skipped a subtree when none
   of a parent's children moved. A child can land exactly where it was while a
   descendant still needs repositioning; the alternating +1/−1 delta reproduces
   this reliably. Fixed by stamping the chain of changed intrinsics and
   descending along it regardless of movement.

Bug 2 is why run 2's `mixed/256 leaf_bounds` read 41 ns: it was skipping work it
owed. The correct figure is 87 ns. **A benchmark without verification would have
reported that bug as a 2x speed-up.**

3. **Self-inflicted measurement artefact.** Moving the position counter into the
   hot loop made the faster version measurably slower — 1 649 memory increments
   per frame instead of one. `leaf_bounds` read 11 129 ns until the counter was
   accumulated in a local, then 8 000 ns for the same work.

## (c) Entity dispatch and input regions

Added so the `full_refresh` comparison is no longer against a toy:

- **11% of elements are entity-backed.** Render goes through a function pointer
  (two bodies, so the call cannot be devirtualised) after a slot-table lookup
  with a generation check, the way `Entity<T>` resolves.
- **19% register an input region** {rect, element, handler} during paint.

Fidelity check against GPUI's wide/seed-0: measured 172/1649 entities (10.4%, target
11%) and 303 regions (18.4%, target 19%).

Cost: `full_refresh` 27 842 → **30 939 ns (+11%)** at wide/1649, and
`sizeOf(Element)` 68 → 88 bytes.

Deliberately **not** added: full flexbox (wrap, min/max-content, baseline). The
subset is a design choice argued in run 1, not an omission — matching Taffy's
feature set would be a different project. The remaining instruction gap below is
therefore partly real design difference and partly missing features, and the
distinction cannot be collapsed.

## Final prototype numbers (wide/1649, after all of the above)

ns, mean over 2000 frames. **Zero allocations on every incremental frame.**

| scenario | mean ns | instr/frame | cycles/frame | cache miss/frame | IPC |
|---|---|---|---|---|---|
| full_refresh | 30 939 | 690 349 | 165 516 | 0.46 | 4.17 |
| **unchanged** | **15** | **217** | 210 | 0.23 | 1.03 |
| **leaf_style** | **16** | **295** | 219 | 0.24 | 1.35 |
| leaf_bounds | 6 150 | 101 236 | 35 798 | 0.27 | 2.83 |

At IPC 1.03 the `unchanged` figure is dominated by the measurement apparatus —
the `clock_gettime` vdso call — not by work. The real cost of that frame in this
design is "check a dirty set and return".

## Head to head, same 1649 elements

| scenario | GPUI | prototype | ratio |
|---|---|---|---|
| instructions, nothing changed | 34 458 000 | **217** | ~159 000x |
| instructions, one element's style | ~35 631 000 | **295** | ~121 000x |
| instructions, full refresh | 34 526 000 | 690 349 | **50x** |
| allocations, nothing changed | 8 454 | **0** | — |
| cache misses, nothing changed | 307 853 | **0.23** | — |

The `full_refresh` ratio tightened from run 1's 65x to **50x** once entities and
handler regions were included. The rest is subset flexbox, a 12-field style
against GPUI's ~100, no scene layer/clip stack, no GPU submit, and no text.

## Verdict after five runs

The project has a measured technical justification, and it is narrow and specific:
**GPUI pays its full frame cost for any change, however small.** Per-element dirty
tracking makes the common frame cost essentially nothing.

Everything else that looked like a reason did not survive measurement. Zig is not
meaningfully faster per element. The arena wins allocation count and cache
behaviour, which buys p99 jitter and memory, not mean frame time. GPUI is already
fast enough that a full refresh of 1649 elements fits in 42% of a 120 fps budget.

## Still open

1. Where GPUI's 2.32 ms goes by function — needs root for perf or valgrind.
2. A persistently-mapped quad buffer, to confirm a single-quad patch reaches the
   GPU without a full re-upload. Without this, the `leaf_style` win stops at the
   CPU boundary.
3. Text. Untouched by all five runs, and run 1 put GPUI 2-5x ahead there.
4. The degenerate `deep`/`narrow` scenes, whose bounds collapse to ~7 visible quads.
5. Whether 50-100 us is the right floor for a real toolkit's fixed per-frame cost
   (input, dirty scan, present).

## Note on Zig pre-1.0

Three breaking changes were hit while writing ~900 lines of benchmark against
0.17: `std.time.Timer` removed, `std.posix.clock_gettime` gone, and
`std.process.args` reworked (arguments and environment both became non-global in
0.16). The scenario selector ended up as a comptime build option to avoid the
argument API entirely. This is the churn risk from run 1's plan, observed rather
than predicted.

---

# Run 6 — is a persistently-mapped quad buffer necessary? (2026-11-20)

Run 2 claimed that without one, the `leaf_style` win "stops at the CPU boundary",
because the renderer would re-upload the whole quad buffer each frame. That was
asserted without measuring. **It is wrong.**

`zig/src/quadbuf.zig` writes into real GPU-visible memory mapped through Vulkan
(no swapchain, no pipeline, no command buffers — purely the cost of writing to
host-visible device memory).

Device: **AMD Ryzen 9 9950X integrated GPU (RADV RAPHAEL_MENDOCINO)**.

Memory types found: `DEVICE_LOCAL|HOST_VISIBLE` (type 3, heap 1, 21 675 MB),
`HOST_VISIBLE|HOST_CACHED` (type 5, heap 0), `HOST_VISIBLE|HOST_COHERENT` (type 2).

## Measured (best of 200)

| target | quads | KB | full rewrite | 1 quad | half | GB/s |
|---|---|---|---|---|---|---|
| DEVICE_LOCAL\|HOST_VISIBLE (BAR) | 1649 | 45 | **1 160 ns** | 2 ns | 630 ns | 39.80 |
| DEVICE_LOCAL\|HOST_VISIBLE (BAR) | 2048 | 56 | 1 500 ns | 3 ns | 760 ns | 38.23 |
| DEVICE_LOCAL\|HOST_VISIBLE (BAR) | 10 000 | 273 | 8 580 ns | 2 ns | 4 390 ns | 32.63 |
| DEVICE_LOCAL\|HOST_VISIBLE (BAR) | 50 000 | 1 367 | 45 871 ns | 3 ns | 23 870 ns | 30.52 |
| HOST_VISIBLE\|HOST_CACHED | 1649 | 45 | **580 ns** | 1 ns | 300 ns | 79.61 |
| HOST_VISIBLE\|HOST_CACHED | 50 000 | 1 367 | 16 450 ns | 1 ns | 7 820 ns | 85.11 |
| HOST_VISIBLE\|HOST_COHERENT | 1649 | 45 | 1 220 ns | 2 ns | 690 ns | 37.85 |
| plain heap (reference) | 1649 | 45 | 580 ns | 1 ns | 300 ns | 79.61 |
| plain heap (reference) | 50 000 | 1 367 | 16 510 ns | 1 ns | 7 850 ns | 84.80 |

## Conclusion

Rewriting the **entire** quad buffer for GPUI's 1649-element tree costs
**0.58–1.22 us**, against the 2 320 000 ns of CPU that GPUI spends on an
unchanged frame. That is **0.05%**.

**Persistently-mapped patching is a micro-optimisation, not a Phase 1
architectural requirement.** A renderer that rewrites every quad every frame
loses about a microsecond. Run 2's caveat is withdrawn, and one item comes off
the Phase 1 requirements list.

Secondary observations:

- `HOST_CACHED` takes CPU writes at 2x the rate of BAR memory (79.6 vs 39.8 GB/s)
  and matches plain heap exactly. The GPU then reads it across the bus, which
  this run does not measure, so it is not a free win — just a real trade.
- A single-quad patch is 1–3 ns, i.e. one cache line. Nothing surprising.
- Throughput falls off above the cache: 39.8 → 30.5 GB/s from 45 KB to 1.37 MB.

## Caveats, and the one that matters

**This is an integrated GPU with unified memory.** A discrete card writes BAR
memory across PCIe, where uncached write-combining typically achieves 2–8 GB/s
rather than 40. The same 45 KB would then cost roughly 6–20 us instead of 1.2 us
— still microseconds, still negligible against 2.32 ms, but with roughly 10x less
margin. The conclusion holds; the headroom does not.

Also unmeasured: barriers, cache maintenance for non-coherent memory, and command
buffer submission. `HOST_COHERENT` avoids explicit `vkFlushMappedMemoryRanges`;
non-coherent memory would not.

## Note on Zig pre-1.0, continued

Two more breaking changes while writing this file, bringing the total to **five**
across roughly 1 100 lines of benchmark against 0.17:

4. **`@cImport` was removed.** C headers are now translated as a build step via
   `b.addTranslateC`, imported as a module.
5. **`std.ArrayList`'s initialisation changed** again; replaced with fixed storage.

(4) is not a detail for this project. A Zig UI toolkit needs harfbuzz, freetype,
SheenBidi and SDL3 through C interop, and all of that now goes through
`addTranslateC` build steps rather than inline `@cImport`. That shapes the build
graph, so it belongs in the Phase 0 spike rather than being discovered later.

---

# Run 7 — GPUI's text baseline (2026-11-20)

Text was untouched by runs 1-6, and run 1 guessed GPUI would be "2-5x ahead,
closing slowly". That was never measured. This measures it.

GPUI's own `layout_line` benchmark, from `gpui-pre-wgpu` 0.3.11. It lays out one
long display line of ASCII code text in three configurations: a single font, a
font with a fallback chain, and a corpus containing a bidi paragraph separator
plus Hebrew to force the per-paragraph path.

**Font substitution.** The published crate's `include_bytes!` paths point outside
the crate (`../../../assets/fonts/...`), so the upstream Lilex and IBM Plex fonts
are unavailable. System **DejaVu Sans Mono** (primary) and **DejaVu Sans**
(fallback) are substituted — the same shape of configuration. DejaVu has broad
coverage and large GPOS/GSUB tables; Lilex is a coding font with ligatures. The
direction of the resulting bias is unknown, so **absolute numbers here are not
comparable to upstream runs of this benchmark**, only to each other and to a Zig
counterpart measured on the same two fonts.

Corpus: **7 928 characters, 7 928 glyphs, one run, one line.** (The bench's own
comment says "~4 000 chars"; it is 7 928.)

## Measured

criterion, 100 samples each:

| case | time | vs no_fallback |
|---|---|---|
| `no_fallback` | **1.4241 ms** [1.4126, 1.4389] | — |
| `with_fallback_ascii` | 1.5074 ms [1.5012, 1.5151] | +5.9% |
| `mixed_direction_paragraphs` | 1.5193 ms [1.5151, 1.5240] | +6.7% |

`perf`, 2 000 fixed iterations of the same calls:

| case | chars | instr/call | cycles/call | ns/call (cycles / 5.55 GHz) | IPC |
|---|---|---|---|---|---|
| no_fallback | 7 928 | 22 470 960 | 8 171 286 | 1 472 304 | 2.75 |
| with_fallback | 7 928 | 24 517 620 | 8 392 184 | 1 512 105 | 2.92 |
| mixed_direction | 7 931 | 23 353 727 | 7 915 248 | 1 426 171 | 2.95 |

The two methods agree within 3% (1.472 ms derived vs 1.4241 ms measured), which
is the first cross-validated timing in this whole exercise.

## Per character, and at realistic sizes

**2 834 instructions, 1 031 cycles, 186 ns per character** — uncached.

| | instructions | time |
|---|---|---|
| one 80-char code line | 0.23 M | 14.9 us |
| 50 lines x 80 chars (one screen, fully uncached) | 11.34 M | **743 us** |
| for comparison: one 1649-element frame rebuild | 34.5 M | 2 320 us |

743 us is **8.9% of a 120 fps budget** for laying out an entire screen of text
from scratch. In practice GPUI caches line layouts, so a steady-state frame pays
far less; this is the cost of a cache miss.

## The finding that matters

GPUI on Linux shapes with **`rustybuzz` 0.20.1** via cosmic-text 0.19 — a Rust
reimplementation of HarfBuzz — not C HarfBuzz. The rest of the stack is `swash`
0.2.6 for rasterisation, `ttf-parser` 0.25, `unicode-bidi` 0.3, `fontdb` 0.23.

rustybuzz is generally slower than C HarfBuzz. A Zig stack binding C HarfBuzz
directly is therefore **not obviously behind on Linux**, which is the opposite of
what run 1 assumed.

### Correcting run 1

Run 1 put GPUI "2-5x ahead on text, closing slowly" and called text the factor
that "can dominate everything else". That was an unmeasured guess and the data
does not support it as stated:

- Uncached layout is 186 ns/char; a full uncached screen is 8.9% of a 120 fps budget.
- The shaping engine is rustybuzz, not a hand-tuned C path.
- On **macOS** GPUI uses CoreText, which is a different and much more
  heavily optimised story. The Linux result does not transfer there.

Text is still the largest remaining unknown, but it is not the blocker run 1
described.

## Secondary observations

- A fallback chain costs **+9% instructions** (22.47 → 24.52 M) even though the
  content is pure ASCII and fallback never fires. Configuring a chain is not free.
- The bidi/mixed-direction path is **not expensive**: 23.35 M instructions
  against 22.47 M, and fewer cycles than `no_fallback`. GPUI's per-paragraph
  path is cheap, so bidi support need not be deferred on performance grounds.
- IPC 2.75-2.95: compute-bound, not stall-bound. 1 031 cycles per ASCII
  character is a lot of actual work.

## Caveats

- Font substitution, as above. Bias direction unknown.
- The uncached path only. Real frames hit GPUI's line-layout cache.
- A 7 928-character single line is far longer than any real display line; the
  per-character figures are the transferable numbers, not the per-call ones.
- Linux/cosmic-text only. macOS CoreText is unmeasured.
- Allocation per call is unmeasured here; a 7 928-glyph `Vec<ShapedRun>` is
  roughly 250 KB per call, which is likely a visible share of the cost.

## Next

1. **Test the C HarfBuzz hypothesis.** A Zig text spike — C HarfBuzz + FreeType
   through `addTranslateC`, same two DejaVu fonts, same corpus — measuring
   instructions per character against 2 834. This is now the highest-value
   remaining measurement, because run 1's text assumption was wrong and the
   answer changes whether text is a reason to build or a reason not to.
2. Measure allocations per `layout_line` call, to see how much of the 2 834 is
   shaping versus building the glyph vector.
3. Still open from earlier runs: function-level attribution inside GPUI's 2.32 ms
   (needs root), and the degenerate `deep`/`narrow` scenes.

---

# Run 8 — C HarfBuzz vs rustybuzz, verified (2026-11-20)

Run 7's finding was that GPUI shapes with rustybuzz on Linux, not C HarfBuzz, so
a Zig stack binding C HarfBuzz might not be behind at all. This tests that.

**Correctness first.** Three dumps of glyph id, cluster and x position over the
same 7 928-character corpus and the same font, compared pairwise:

| pair | glyph ids | clusters | max x deviation |
|---|---|---|---|
| GPUI `layout_line` vs rustybuzz-direct | identical | identical | 0.0000 px |
| GPUI `layout_line` vs C HarfBuzz | identical | identical | 0.0038 px |
| rustybuzz-direct vs C HarfBuzz | identical | identical | 0.0038 px |

0 of 7 928 glyph ids differ. The 0.0038 px residual over a 66 820 px line is f32
accumulation noise.

A bug found on the way: `hb_font_set_scale(font, size * 64, size * 64)` quantises
advances to 1/64 px, which over this line drifted **60 px** away from rustybuzz.
Setting the scale to the design units and converting in f32 — what rustybuzz does
— removes it. A toolkit that wants subpixel-accurate positions must not take the
26.6 shortcut.

## Measured, all three on the same corpus and font

| | instr/char | cycles/char | ns/char | IPC |
|---|---|---|---|---|
| GPUI `layout_line` (cosmic-text 0.19 + rustybuzz 0.20.1) | 2 834 | 1 031 | 186 | 2.75 |
| **rustybuzz direct** (engine only) | **960** | 286 | **51.5** | 3.36 |
| **C HarfBuzz 12.3.2** (engine only) | **293** | 55.9 | **9.8** | 5.24 |

"Engine only" means the same hardcoded direction (LTR), script (Latin) and
language (en), a reused shaping buffer, and a pre-allocated output array on both
sides. That makes the two engine rows a fair comparison with each other.

## Decomposition

**Engine to engine:** C HarfBuzz is **3.3x fewer instructions and 5.3x faster**
than rustybuzz for identical output. The IPC progression — 5.24, 3.36, 2.75 —
says C HarfBuzz is very well optimised, rustybuzz's port is reasonable, and
cosmic-text's layer costs again on top.

**But the engine is only 34% of the path.** 2 834 − 960 = **1 874 instructions
per character, 66% of GPUI's `layout_line`, is not shaping**: bidi paragraph
analysis, per-character fallback coverage checks, run segmentation, and
allocating `Vec<ShapedRun>`/`Vec<ShapedGlyph>` (~250 KB per call at this length).

So swapping the engine alone takes 2 834 → 1 874 + 293 = 2 167 instructions per
character: **about 1.3x overall**, not 9.7x. The 19x time ratio between GPUI's
full path and a bare C HarfBuzz call is **not an achievable win** — two thirds of
it is work a real toolkit also has to do.

### Where the remaining opportunity actually is

1 874 instructions per character for bidi, fallback and allocation is high, and
that is the part a different design could attack — a retained glyph buffer
removes the per-call allocation, and a toolkit that knows a run is single-script
ASCII can skip most of the analysis. **None of that is measured.** It is the next
question, not a result.

### Correcting runs 1 and 7, in order

- **Run 1** guessed GPUI was "2-5x ahead on text, closing slowly" and called text
  the factor that could "dominate everything else". Wrong: on Linux the engine it
  uses is 3.3x more expensive than the C one a Zig stack would bind.
- **Run 7** reported the rustybuzz finding but left the implication open. The
  implication is narrower than it looked: the engine swap is worth ~1.3x on the
  whole path, because the engine is a third of it.

Text is therefore neither the blocker of run 1 nor the open goal of run 7. It is
a modest win with an unmeasured larger one behind it.

## Caveats

- Font substitution from run 7 still applies (DejaVu for Lilex/IBM Plex).
- Linux only. macOS GPUI uses CoreText, unmeasured, and likely a different answer.
- ASCII only. Complex scripts would exercise GSUB/GPOS much harder and the ratio
  could move either way.
- The Zig path hardcodes direction, script and language and never resolves
  fallback, so it is not a usable text system — it is the shaping core of one.
- Rasterisation is not measured at all. `layout_line` does not rasterise either,
  so the comparison is consistent, but a text stack needs a glyph atlas on top.

## Note on Zig pre-1.0, continued

Breaking change six, hit in this run: **`std.fs.cwd()` no longer exists.** The
filesystem moved to `std.Io.Dir`, and every call takes an `Io` value — the "I/O
as an interface" rework. Reading a font file now means constructing
`std.Io.Threaded` and threading `io` through. `std.ArrayList` also lost
`.writer()`, so the dump is built with `std.fmt.bufPrint` into a plain buffer.

Running total: six breaking changes across roughly 1 500 lines of benchmark
written against 0.17.

# Run 9 — does element-level memoisation survive real flexbox? (2026-11-22)

Runs 2-5 measured per-element dirty tracking against a deliberately small layout
model: three size modes, one padding scalar, no shrink, no min/max, no wrap, no
alignment. The 23-46x CPU figure rests on it, and RESULTS.md has said since run 2
that the figure is invalid until real flexbox is in.

`zig/src/incremental_flex.zig` adds the five mechanisms that each break the
assumption that a child's change is local:

1. **flex-shrink.** CSS defaults to `flex: 0 1 auto` — every item shrinks. Once a
   line overflows, one child growing redistributes size across all its siblings.
   `any_grow_main` from run 4 cannot see this.
2. **min/max clamping.** CSS 9.7 resolves flexible lengths with a freeze loop:
   clamping one item frees space that must be redistributed among the rest, so
   cost is passes x items.
3. **flex-wrap.** A size change can move an item to another line, moving every
   later item.
4. **justify-content** other than `flex-start`. With `space-between` or `center`
   every child's position depends on the line's total main size, so **earlier**
   siblings move too — run 4's early-break is invalid.
5. **baseline alignment.** Cross positions depend on the maximum baseline across
   the line.

Three profiles: `legacy` reproduces the run 2-5 model, `css_default` turns on
shrink/clamps/alignment with a realistic mix, `css_wrap` adds wrap.
`incremental.zig` is untouched, so runs 2-8 stay reproducible.

## Measured — wide/1649 (GPUI's own topology: one root, 1649 children)

| scenario | legacy | css_default | css_wrap |
| --- | --- | --- | --- |
| `unchanged` | 15 ns | **15 ns** | **15 ns** |
| `leaf_style` | 15 ns | **16 ns** | **16 ns** |
| `leaf_bounds` | 8 784 ns (fast 100%) | **20 650 ns (fast 0%)** | 19 942 ns (fast 0%) |
| `full_refresh` | 45 566 ns | 48 717 ns | 49 561 ns |

Instructions per frame, `css_default`, via `perf stat` over 20 000 iterations:

| scenario | instructions | cycles | cache misses |
| --- | --- | --- | --- |
| `unchanged` | **245** | 229 | 0.26 |
| `leaf_style` | 281 | 228 | 0.24 |
| `leaf_bounds` | 496 599 | 111 703 | 0.41 |
| `full_refresh` | 1 215 102 | 275 945 | 9.80 |

## Measured — mixed/256 (realistic branching, 2-3 children per node)

| scenario | legacy | css_default | css_wrap |
| --- | --- | --- | --- |
| `leaf_bounds` | 56 ns (fast 100%) | **298 ns (fast 100%)** | 1 627 ns (fast 0%) |

## The finding

**The premise survives, and the reason is worth being precise about: it was never
a claim about layout cost.**

`unchanged` and `leaf_style` are **identical across all three profiles** — 15 ns
and 245 instructions, zero allocations, 0.26 cache misses. An unchanged frame
does no layout work, so how complicated the layout model is cannot affect it.
The comparison against GPUI's unchanged frame — 2.32 ms of CPU, 34 458 000
instructions, 8 454 allocations, 307 853 cache misses — does not move at all.

That is the whole architectural bet, and real flexbox does not touch it.

## What did degrade, and by how much

**Size-change propagation, by 2.35x on wide trees, and the prefix-scan fast path
dies completely there** (100% -> 0% of repositions).

The cause is mechanism 1. The `wide` root holds 1649 children in a 1080 px
column — it overflows by roughly 30x. With `flex-shrink: 1` the line is always
shrinking, so every sibling's resolved size depends on every other's, and
repositioning from a middle child is simply invalid. `leaf_bounds` degenerates
into a full relayout of the container: 3 298 position visits and 1 439 freeze-loop
visits, against 824 and 0 under `legacy`.

Two things keep this from being fatal:

- **20.65 us is 0.25% of a 120 fps frame budget.** The degradation is real and
  does not matter in absolute terms.
- **The fast path survives realistic branching.** `mixed/256` holds 100% under
  `css_default`. It dies specifically where a container overflows by an order of
  magnitude, which is already broken UI.

`full_refresh` cost only +7% (45 566 -> 48 717 ns). Real flexbox is not expensive
to run; it is expensive to *memoise*.

## A design requirement this run produced

Overflow has to be detected in O(1) or the fast path is dead everywhere, not just
on overflowing containers — testing it the obvious way means scanning every
sibling, which is the work being avoided. `incremental_flex.zig` keeps `sum_main`
(children's hypothetical outer main sizes plus gaps) per container, updated as
intrinsics are recomputed on the climb. Without that cache, `flex-shrink: 1`
alone would force the slow path on every single size change.

This is a requirement on the real toolkit, not a benchmark trick.

## Verification earned its keep again

**One real bug.** `leafBounds` collapsed the climb loop's two exits:

```zig
const from: u32 = if (node == NONE) 0 else node;   // wrong
```

`break` means an ancestor's own size did not change, so only its children from
the path child onward need repositioning. `node == NONE` means the change
propagated out of the tree entirely, and `child_on_path` is the root itself —
feeding that to `repositionFrom` lays the root out as its own child and adds its
own padding to its own origin. It put the root at `x = 8` instead of `x = 0`, and
`verifyLayout` caught it on the fourth warm-up frame of `deep/256`.

This bug is **latent in `incremental.zig` too.** It only became reachable here
because tracking `baseline` lets a change propagate all the way to the root,
which the run 2-5 model could not express. Runs 2-8 are unaffected — their
`verifyLayout` passed on all five cases — but the defect is real in that file and
is left in place deliberately so those runs stay reproducible.

**One wrong assumption of mine, caught by a counter assertion rather than by a
bug.** `checkCounters` asserted `flexloop > 0` on every full refresh. Under
`legacy` nothing has a flex factor, so an overflowing line resolves no flexible
lengths and the counter is legitimately 0. The assertion was wrong, not the code.
It is now profile-aware. Worth recording because this is the failure mode the
discipline is *supposed* to have: a wrong expectation surfacing immediately
instead of becoming a silent assumption.

## Caveats

- **Wrap's cost is a lower bound.** A wrapping container needs a non-`fit` cross
  size in this model, because a correct `fit` cross size for a wrap container
  depends on the available main size and needs a second pass. Real engines run
  that pass. The omitted work would make memoisation harder, not easier.
- `css_wrap` / `wide` / `leaf_bounds` reports `paint: 1`: the measured delta is
  absorbed by a clamp, so nothing moves — yet the full container relayout
  (3 298 + 1 448 visits) is still paid to discover that. That cell measures the
  cost of *finding out* nothing changed, not the cost of propagation. It is a
  genuine flexbox property and a genuine measurement, but not of what the other
  cells measure.
- Still absent, and still enough to invalidate any ratio against GPUI's full
  refresh: the ~100-field style struct, style refinement, the scene layer and
  clip stack, hit-test region trees, a11y nodes, and all GPU work.
- `flex-basis` is modelled as fixed-or-content, not as a third independent
  length. Percentage bases, `auto` margins and `align-self` overrides are absent.
- The realistic-mix proportions (70% `justify: start`, 40% `align: center`, 25%
  with minimums) are my estimates of common CSS, not data from a corpus of real
  UIs. The `legacy` -> `css_default` direction of the result is robust; the exact
  2.35x is not.

## Verdict

Spike A set out to find whether the headline claim survives real flexbox. It
does, unchanged, because it is a claim about frames that do no layout. The
secondary claim — that size changes stay local — survives in realistic trees and
fails in overflowing ones, at a cost (20 us) far below anything a user could
perceive.

The premise holds. Proceed to spike B, which is the one that can actually kill
the project: IME and accessibility are load-bearing for the self-drawn design,
and neither has been attempted in Zig.

# Correction to run 9 — the fast path was taken where it was invalid (2026-11-24)

Porting `zig/src/incremental_flex.zig` into the toolkit
([zig-uikit](https://github.com/hivepaas/zig-uikit)) added a **randomised**
equivalence test: build random trees, make random style changes, demand that
the incremental result match a full recompute exactly. It failed on its first
run, in a `deep` topology, with 37 of 67 elements off by three pixels on the
cross axis.

The cause is in `repositionFrom`:

```zig
.row => .{ .x = cursor, .y = inner_y, .w = main_sz, .h = cross_sz },
```

It writes the container's content edge unconditionally and **ignores
`align_items` entirely**. `positionChildren`, the slow path, computes a
`cross_off` for `center`, `end` and `baseline`; the fast path does not. So any
container with cross alignment other than `start` was repositioned wrongly.

`verifyLayout` did not catch this across runs 2-9 because it ran five fixed
cases. The randomised sweep found it immediately. That is the same lesson run 4
taught in the other direction — there, verification caught two bugs that
reported themselves as 2x improvements — and it says the verification was
necessary but not sufficient.

## What this invalidates

- **The `fast%` column of run 9 is invalid** for the `css_default` and
  `css_wrap` profiles. Those profiles assign `align_items` randomly, with
  `center` 40% of the time, so the fast path was being taken on containers
  where it produced wrong geometry. `mixed/256 css_default`, reported at
  `fast 100%` and 298 ns, is the clearest case affected.
- The **`legacy` profile is unaffected.** It never sets `justify` or
  `align_items`, so both stay at `.start` and the fast path's assumption held.
  That covers every run before 9.

## What this does NOT invalidate

**The headline claim is untouched.** `unchanged` and `leaf_style` do no layout
work at all — 15 ns, 245 instructions, zero allocations, identical across all
three profiles — so a bug inside the repositioning fast path cannot reach them.
The comparison against GPUI's 2.32 ms of CPU on an unchanged frame stands.

Also unaffected: the finding that `full_refresh` costs only +7% with real
flexbox, and that an overflowing wide container forces the slow path
(`fast 0%`), since that path is the correct one.

## The fix, and why it lives in the toolkit and not here

The toolkit now caches `max_cross` per container — the cross-axis mirror of
`sum_main` — so the fast path can compute the alignment offset without the
sibling scan it exists to avoid, and excludes `baseline` alignment, which would
need two further running maxima.

`incremental_flex.zig` is **deliberately left unfixed.** It is the artefact runs
2 through 9 were produced by, and editing it would make those numbers
unreproducible. The correction is recorded here instead, which is the same
reason the run 9 climb bug was left in place in `incremental.zig`.
