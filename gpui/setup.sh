#!/usr/bin/env bash
# Builds the GPUI baseline bench from the cargo registry copy of
# gpui-pre-platform. Needed because the published crate ships its benches but
# not their dev-dependencies, so criterion and bench_metrics must be added back.
set -euo pipefail

VER="${GPUI_PRE_VERSION:-0.3.11}"
OUT="${1:-./work}"

SRC="$(find "${CARGO_HOME:-$HOME/.cargo}"/registry/src -maxdepth 2 \
        -type d -name "gpui-pre-platform-$VER" | head -1)"
if [ -z "$SRC" ]; then
    echo "gpui-pre-platform-$VER not in the registry; fetching it first:" >&2
    echo "  cargo new /tmp/fetch-gpui && cd /tmp/fetch-gpui && cargo add gpui-pre-platform@$VER" >&2
    exit 1
fi

rm -rf "$OUT"; mkdir -p "$OUT"
cp -r "$SRC"/. "$OUT"/
chmod -R u+w "$OUT"
rm -f "$OUT/Cargo.toml.orig"

cat >> "$OUT/Cargo.toml" <<TOML

[dev-dependencies.criterion]
version = "0.8.2"
features = ["html_reports"]

[dev-dependencies.bench_metrics]
version = "$VER"
package = "gpui-pre-bench-metrics"
TOML

cd "$OUT"
cargo bench --bench randomized_element_tree \
    --features bench-support,wayland,x11 --no-run
echo
echo "built. run ./run.sh (from the gpui/ directory)"
