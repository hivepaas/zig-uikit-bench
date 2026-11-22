# zig-uikit-bench

Reproducible measurements comparing GPUI's element-tree frame cost against a
Zig arena-based prototype, to decide whether a new Zig UI toolkit is worth
building — before building it.

**Short answer from the first run: not for frame time.** See [RESULTS.md](RESULTS.md).

These are the measurements behind [zig-uikit](https://github.com/hivepaas/zig-uikit).
Eight runs; most of the original hypotheses did not survive them, and the ones
that failed are written up here alongside the ones that held. The single
premise that did survive is **reactive granularity** — see the run index in
[RESULTS.md](RESULTS.md), which states per run what may and may not be
concluded from it.

Nothing here is a benchmark of GPUI against a finished toolkit. The Zig side is
a prototype missing most of what a real toolkit does; [what the Zig prototype
does NOT do](#what-the-zig-prototype-does-not-do) lists the gaps, and the
headline ratios are invalid until they are closed.

## Why this exists

A new UI toolkit is a 12–18 month project. The hypotheses that would justify it
were:

1. A frame-arena element tree beats `Box<dyn Element>` on allocation and cache behaviour.
2. Iterative layout avoids GPUI's recursion limit on deep trees.
3. A deliberate flexbox subset beats full Taffy.

(1) and (2) measured true. (3) is untested. None of them turned out to matter
for mean frame time, because GPUI already fits a 1649-element full refresh in
42% of a 120 fps budget with zero overruns.

The run did surface one thing worth chasing, which is now the open question:
**GPUI's reactive granularity is the view, not the element.** An `unchanged`
frame under a notified root costs the same as a full refresh. Element-level
memoisation would make the common frame near-free. That is an architecture bet,
not a language bet — and it is the next thing to measure.

## Layout

```
zig/                 arena-based element tree + layout + paint prototype
  src/tree_bench.zig   all topologies and element counts, prints a table
  src/single.zig       one config (wide/2048) so perf can attribute counters
  src/incremental.zig  element-level memoisation across GPUI's change classes
  src/quadbuf.zig      quad-buffer writes into Vulkan-mapped GPU memory
  src/vk.h             translation unit for the translate-c build step
  build.zig
gpui/                baseline harness driving Zed's own benchmarks
  setup.sh             builds the element-tree bench project from crates.io
  run.sh               the invocations used in RESULTS.md
  text/                GPUI's layout_line text bench, patched to system fonts
    setup.sh, run.sh
    layout_line.patched.rs, text_single.rs
RESULTS.md           measured numbers, machine, and what may be concluded
```

## Running the Zig side

```sh
cd zig
zig build -Doptimize=ReleaseFast
taskset -c 2 ./zig-out/bin/tree_bench
perf stat -e instructions,cycles,cache-misses,branch-misses \
    taskset -c 2 ./zig-out/bin/single
```

`single` runs 20 000 iterations of `wide/2048` and prints nothing, so perf
counters divide cleanly by iteration count.

Requires Zig 0.17. The prototype uses `std.os.linux.clock_gettime` directly
because 0.16 removed `std.time.Timer` when it moved I/O behind the `Io`
interface — a live example of the pre-1.0 churn this project would be exposed to.

## Running the GPUI baseline

```sh
cd gpui
./setup.sh      # copies gpui-pre-platform from the cargo registry, patches dev-deps
./run.sh        # full refresh / unchanged / leaf style / root layout, wide family
```

`setup.sh` exists because the published `gpui-pre-platform` crate ships its
benches but not their dev-dependencies, so `criterion` and `bench_metrics` have
to be added back before the bench will compile.

Useful knobs:

- `BENCH_MEASUREMENT=foreground-instructions` — retired instructions on the
  benchmark thread. Low noise; the right primary for frame cost.
- `BENCH_MEASUREMENT=foreground-allocations` — heap allocations on that thread.
- unset — wall time as primary, every supported counter as a secondary.

## Methodology notes

- The Zig prototype replicates GPUI's topology semantics from
  `gpui::randomized_element_tree`: `Wide` (all children of root), `Deep` (each
  under the previous), `Mixed` (parents chosen throughout), `Narrow` (four in
  five extend one branch).
- Both sides are pinned to core 2 with `taskset`.
- Element counts follow GPUI's bench families: `wide` 128–2048,
  `any`/`tall` 32–256 (`TALL_MAX_ELEMENTS`).

## What the Zig prototype does NOT do

This matters more than anything else here. Any instruction-count ratio against
GPUI is invalid until these are closed:

- no entity render dispatch (GPUI's trees are 11–24% entities)
- no event handler registration (19–30%)
- no real flexbox: no wrap, no min/max-content, no baseline alignment
- no style refinement (GPUI's style struct has ~100 fields)
- no hit-test region building, no a11y nodes
- no scene layer/clip stack
- **no GPU work at all** — and `window draw` is 3.02 of GPUI's 3.50 ms

Allocation counts and cache-miss counts are the exceptions: those follow from
memory layout, not from feature count, so they survive the gap.

## Open question — answered in run 2

Element-level memoisation was prototyped (`zig/src/incremental.zig`).
`unchanged` and `leaf_style` drop to 15 ns and zero allocations, against GPUI's
3.9 ms and ~8 450 allocations at the same 1649 elements. So there is a real
technical reason to build the toolkit, and it is **reactive granularity**, not
per-element speed.

Run 3 scoped that properly. Of GPUI's 3.121 ms `unchanged` frame, **74% (2.32 ms)
is the CPU executing** and 26% is blocked on GPU submit and present — derived
from 12.856 M cycles at a measured 5.55 GHz, and cross-checked by swapping in
lavapipe (+60% instructions, only +11% wall). So the avoidable CPU cost is
~2.32 ms per frame, not the ~0.9 ms run 2 guessed. That is 28% of a 120 fps
budget spent on a frame where nothing changed.

Run 6 settled the quad-buffer question by measuring writes into Vulkan-mapped
GPU memory: rewriting **all** 1649 quads costs 0.58–1.22 us, against GPUI's
2.32 ms of CPU per unchanged frame — 0.05%. **Persistently-mapped patching is a
micro-optimisation, not a requirement**, and run 2's caveat is withdrawn.

Run 7 measured text, which runs 1-6 had left alone. GPUI's uncached line layout
costs **186 ns and 2 834 instructions per character**; a full uncached screen of
50x80 chars is 743 us, or 8.9% of a 120 fps budget. Run 1's guess that GPUI was
"2-5x ahead on text" does not survive: on Linux it shapes with **rustybuzz**, a
Rust port of HarfBuzz, not C HarfBuzz — so a Zig stack binding C HarfBuzz is not
obviously behind. (macOS uses CoreText and is a different story, unmeasured.)

Still open: memoisation does not help wide trees for size changes, because
flexbox must rescan every sibling; and whether C HarfBuzz actually beats
rustybuzz here.

See [RESULTS.md](RESULTS.md), runs 2, 3, 6 and 7.
