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
