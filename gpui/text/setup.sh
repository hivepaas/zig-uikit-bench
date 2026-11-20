#!/usr/bin/env bash
# Builds GPUI's layout_line text benchmark, patched to use system DejaVu fonts.
#
# The published gpui-pre-wgpu crate ships the bench but its `include_bytes!`
# paths point outside the crate (../../../assets/fonts/...), so the upstream
# Lilex and IBM Plex fonts are unavailable. DejaVu Sans Mono + DejaVu Sans are
# substituted: same shape of configuration (monospace primary, sans fallback),
# but absolute numbers are NOT comparable to upstream runs.
set -euo pipefail

VER="${GPUI_PRE_VERSION:-0.3.11}"
OUT="${1:-./work}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC="$(find "${CARGO_HOME:-$HOME/.cargo}"/registry/src -maxdepth 2 \
        -type d -name "gpui-pre-wgpu-$VER" | head -1)"
[ -n "$SRC" ] || { echo "gpui-pre-wgpu-$VER not in the registry" >&2; exit 1; }

for f in /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
         /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf; do
    [ -f "$f" ] || { echo "missing font: $f" >&2; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT"
cp -r "$SRC"/. "$OUT"/
chmod -R u+w "$OUT"
rm -f "$OUT/Cargo.toml.orig"

cp "$HERE/layout_line.patched.rs" "$OUT/benches/layout_line.rs"
mkdir -p "$OUT/examples"
cp "$HERE/text_single.rs" "$OUT/examples/text_single.rs"

cat >> "$OUT/Cargo.toml" <<TOML

[dev-dependencies.criterion]
version = "0.8.2"
features = ["html_reports"]

[[example]]
name = "text_single"
path = "examples/text_single.rs"
TOML

cd "$OUT"
cargo bench --bench layout_line --no-run
cargo build --release --example text_single
echo
echo "built. run ./run.sh (from gpui/text/)"
