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
