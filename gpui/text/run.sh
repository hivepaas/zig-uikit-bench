#!/usr/bin/env bash
# The invocations behind RESULTS.md run 7.
set -euo pipefail
WORK="${1:-./work}"
CORE="${BENCH_CORE:-2}"
ITERS="${TEXT_ITERS:-2000}"

BIN="$(find "$WORK/target/release/deps" -name 'layout_line-*' -type f -perm -u+x ! -name '*.d' | head -1)"
[ -n "$BIN" ] || { echo "bench binary not found; run ./setup.sh first" >&2; exit 1; }

echo "########## criterion (wall time, 100 samples) ##########"
taskset -c "$CORE" "$BIN" --bench --measurement-time 5 --warm-up-time 2 2>&1 |
    grep -E "layout_line/|time:"

echo
echo "########## perf (instructions per call) ##########"
printf "%-18s %8s %14s %14s %7s\n" "case" "chars" "instr/call" "cycles/call" "IPC"
for c in no_fallback with_fallback mixed_direction; do
    OUT=$(perf stat -e instructions,cycles -x, taskset -c "$CORE" \
        "$WORK/target/release/examples/text_single" "$c" "$ITERS" 2>&1 >/dev/null)
    CH=$(echo "$OUT" | grep -oE "chars=[0-9]+" | head -1 | cut -d= -f2)
    echo "$OUT" | awk -F, -v c="$c" -v ch="$CH" -v n="$ITERS" \
        '/instructions/{i=$1} /cycles/{y=$1} END{printf "%-18s %8s %14.0f %14.0f %7.2f\n", c, ch, i/n, y/n, i/y}'
done
