#!/usr/bin/env bash
# Generate keymap visualizations from config/totem.keymap using keymap-drawer:
#   1. docs/images/keymap.svg            — full multi-layer SVG (for README/docs)
#   2. ~/.local/share/totem-keymap/      — per-layer PNGs + layers.json manifest
#      (consumed by the Caelestia dashboard Keymap tab)
# The physical layout (key positions/rotations) is read from the local shield's
# totem-layouts.dtsi, so this works fully offline.
set -euo pipefail
cd "$(dirname "$0")/.."

KEYMAP=~/.venvs/keymap-drawer/bin/keymap
PYTHON=~/.venvs/keymap-drawer/bin/python
DTS_LAYOUT="$PWD/config/boards/shields/totem/totem-layouts.dtsi"
OUT_DIR=~/.local/share/totem-keymap
SCALE=3 # PNG render scale (crisp on HiDPI, dashboard scales down)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$KEYMAP" parse -z config/totem.keymap -c 5 -o "$TMP/keymap.yaml"

# Inject the physical layout spec (parsed keymap only carries zmk_keyboard name)
# plus drawing tweaks, sized proportionally to the layout's actual bounding box:
# - inner gaps: ~8% of a key cell (5/60) — keys keep breathing room
# - outer pads: ~10% of a key cell (6/60) — default was 50%/100% which wasted
#   ~28% of the canvas height; per-layer PNGs don't need a margin, the
#   dashboard card provides it
# - per-layer layer-name headers are stripped post-draw (pills show the name)
DTS_LAYOUT="$DTS_LAYOUT" "$PYTHON" - "$TMP/keymap.yaml" <<'EOF'
import os, sys, yaml
path = sys.argv[1]
d = yaml.safe_load(open(path))
d['layout'] = {'dts_layout': os.environ['DTS_LAYOUT']}
d['draw_config'] = {
    'inner_pad_w': 5,   # gap on each side of a key cell (default 2)
    'inner_pad_h': 5,
    'outer_pad_w': 6,   # canvas margin (default 30 = key_w/2)
    'outer_pad_h': 6,   # canvas margin (default 56 = key_h)
    'key_rx': 8,
    'key_ry': 8,
    'svg_extra_style': 'svg.keymap { font-size: 15px; } text.key { font-weight: 600; }',
}
open(path, 'w').write(yaml.dump(d, default_flow_style=False, sort_keys=False))
EOF

# 1. Full multi-layer SVG for docs
"$KEYMAP" draw "$TMP/keymap.yaml" -o docs/images/keymap.svg
echo "wrote docs/images/keymap.svg"

# 2. Per-layer PNGs + manifest for the desktop UI
mkdir -p "$OUT_DIR/layers"
LAYERS=$(
	"$PYTHON" - "$TMP/keymap.yaml" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print('\n'.join(d['layers'].keys()))
EOF
)

# resvg via nix (cached after first use); run one nix shell for all conversions.
# Layer names may contain spaces ("TVP 1") — pass them NUL-separated.
export KEYMAP TMP OUT_DIR SCALE
printf '%s' "$LAYERS" | nix shell nixpkgs#resvg -c bash -c '
set -euo pipefail
while IFS= read -r layer; do
  slug=$(echo "$layer" | tr "[:upper:] " "[:lower:]_")
  "$KEYMAP" draw "$TMP/keymap.yaml" -s "$layer" -o "$TMP/$slug.svg"
  # strip the layer-name header text (redundant with the UI pill, frees the top band)
  sed -i "s|<text[^>]*class=\"label\"[^>]*>[^<]*</text>||" "$TMP/$slug.svg"
  resvg -z "$SCALE" "$TMP/$slug.svg" "$OUT_DIR/layers/$slug.png"
done
'

# Manifest (JSON) the QML tab watches
"$PYTHON" - "$TMP/keymap.yaml" "$OUT_DIR" <<'EOF'
import json, sys, time, yaml, os
d = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2]
def slug(n): return n.lower().replace(' ', '_')
layers = [{'name': n, 'file': f'{out}/layers/{slug(n)}.png'} for n in d['layers'].keys()]
manifest = {'generated': int(time.time()), 'layers': layers}
with open(f'{out}/layers.json.tmp', 'w') as f:
    json.dump(manifest, f, indent=2)
os.replace(f'{out}/layers.json.tmp', f'{out}/layers.json')
print('wrote', f'{out}/layers.json', [l['name'] for l in layers])
EOF

# Active-layer state file (written by the host daemon in the live-layer phase);
# create a default once so the QML FileView has something to watch.
[ -f "$OUT_DIR/active-layer" ] || echo 0 >"$OUT_DIR/active-layer"
