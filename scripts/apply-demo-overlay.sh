#!/bin/bash
# ============================================================
# ShowPilot Demo — Apply Overlay
# ============================================================
# Copies the demo bundle's overlay/ files over the corresponding
# files in the live ShowPilot clone. Currently overlays:
#
#   overlay/routes/cloudflared.js → /opt/showpilot-demo/routes/cloudflared.js
#     (neuters tunnel install/token/start/stop endpoints — visitors
#      see the UI in its "online" state but can't actually configure
#      a tunnel from the demo box)
#
# Run AFTER any ShowPilot version bump (git checkout vX.Y.Z), since
# git checkout restores the upstream files and our overlay gets
# wiped.
#
# Idempotent: safe to re-run. Uses cp -f.
#
# Usage:
#   sudo /opt/showpilot-demo/scripts/apply-demo-overlay.sh
#
# Or, when running setup.sh from the bundle root for the first time:
#   bash scripts/apply-demo-overlay.sh
# ============================================================

set -euo pipefail

LIVE_DIR="/opt/showpilot-demo"

# Resolve the bundle root the same way setup.sh does — this script
# lives in scripts/, so the bundle root is one directory up. Works
# both during initial setup (BUNDLE_DIR/overlay/) and after install
# (LIVE_DIR/scripts/../overlay/ via a copied bundle layout, OR
# LIVE_DIR/scripts/overlay/ if setup.sh placed it directly there).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pick the first overlay dir that exists. Order matters: when running
# from a freshly-extracted bundle, $BUNDLE_DIR/overlay/ is the bundle's
# own copy (newest). Once setup.sh has copied it into the live tree,
# $SCRIPT_DIR/overlay/ is the canonical location and the bundle is gone.
if [ -d "$BUNDLE_DIR/overlay" ]; then
  OVERLAY_DIR="$BUNDLE_DIR/overlay"
elif [ -d "$SCRIPT_DIR/overlay" ]; then
  OVERLAY_DIR="$SCRIPT_DIR/overlay"
else
  OVERLAY_DIR=""
fi

log() { echo "[overlay] $*"; }
fail() { echo "[overlay] ERROR: $*" >&2; exit 1; }

if [ ! -d "$LIVE_DIR" ]; then
  fail "$LIVE_DIR does not exist — run setup.sh first"
fi
if [ -z "$OVERLAY_DIR" ]; then
  fail "overlay/ directory not found in bundle or in $SCRIPT_DIR — overlay files missing"
fi

# Walk every file in overlay/ and copy it over the matching path in
# LIVE_DIR. If the target file doesn't exist, that's a loud signal
# that ShowPilot moved/renamed something and the overlay is stale —
# bail rather than create files in unexpected places.
applied=0
while IFS= read -r -d '' overlay_file; do
  rel_path="${overlay_file#$OVERLAY_DIR/}"
  target="$LIVE_DIR/$rel_path"

  if [ ! -f "$target" ]; then
    fail "overlay target $target not found in ShowPilot — stale overlay?"
  fi

  log "applying overlay: $rel_path"
  cp -f "$overlay_file" "$target"
  chown showpilot:showpilot "$target"
  applied=$((applied + 1))
done < <(find "$OVERLAY_DIR" -type f -print0)

log "applied $applied file(s)"
