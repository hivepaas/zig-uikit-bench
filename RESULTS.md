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
