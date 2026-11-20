#!/usr/bin/env bash
# The invocations behind RESULTS.md. Needs a display: the harness opens a window.
set -euo pipefail

WORK="${1:-./work}"
CORE="${BENCH_CORE:-2}"
FAMILY="${BENCH_FAMILY:-wide}"
MEASURE="${BENCH_MEASUREMENT:-foreground-instructions}"

BIN="$(find "$WORK/target/release/deps" -name 'randomized_element_tree-*' \
        -type f -perm -u+x ! -name '*.d' | head -1)"
[ -n "$BIN" ] || { echo "bench binary not found; run ./setup.sh first" >&2; exit 1; }

for group in "full refresh" "unchanged" "leaf style" "root layout"; do
    echo "########## $group / $FAMILY ##########"
    BENCH_MEASUREMENT="$MEASURE" taskset -c "$CORE" "$BIN" \
        --measurement-time 5 --warm-up-time 2 \
        "RandomizedTree/$group/tree/$FAMILY" 2>&1 |
        grep -iE "tree: $FAMILY|instructions per iter|allocations per iter|allocated bytes per iter|cache misses per iter|wall time per iter|IPC|budget overruns"
    echo
done
