# uiwing-bench

Reproducible measurements comparing GPUI's element-tree frame cost against a
Zig arena-based prototype, to decide whether a new Zig UI toolkit is worth
building — before building it.

**Short answer from the first run: not for frame time.** See [RESULTS.md](RESULTS.md).

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
  build.zig
gpui/                baseline harness driving Zed's own benchmark
  setup.sh             builds the bench project from crates.io
  run.sh               the invocations used in RESULTS.md
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

Two caveats decide whether that converts into a user-visible win, and neither is
measured yet: how much of GPUI's 3.9 ms is CPU a real toolkit would actually
skip (GPU present is 3.02 ms of it), and whether the renderer can patch its quad
buffer in place instead of re-uploading. Also found: memoisation does not help
wide trees for size changes, because flexbox must rescan every sibling.

See [RESULTS.md](RESULTS.md), run 2.
