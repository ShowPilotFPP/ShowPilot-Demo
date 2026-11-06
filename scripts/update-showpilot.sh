#!/bin/bash
# ============================================================
# ShowPilot Demo — update the live ShowPilot to the latest main
# ============================================================
# Run as root (ShipPilot's "ShowPilot Demo" environment runs it over SSH):
#
#   bash /opt/showpilot-demo-bundle/scripts/update-showpilot.sh
#
# Steps:
#   1. Fetch ShowPilot main.
#   2. BEFORE switching anything, check that the demo's tunnel overlay
#      (overlay/routes/cloudflared.js) defines every endpoint the new
#      routes/cloudflared.js has. If ShowPilot added a tunnel control the
#      overlay doesn't neuter, stop here and keep the current version:
#      demo visitors are admins and must never reach a real tunnel control.
#   3. Switch to the new code, copy the overlay over the real file,
#      install dependencies, and restart through reset.sh (kills whatever
#      holds the port and re-registers the PM2 processes).
#
# Why a whole-file copy and not `git apply` of a patch: a patch carries
# surrounding lines and stops applying as soon as ShowPilot edits nearby
# code (that is what kept the demo off v0.33.239+). A copy always applies;
# step 2 is what catches real changes to the tunnel endpoints.
# ============================================================

set -euo pipefail

LIVE_DIR="${LIVE_DIR:-/opt/showpilot-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERLAY="$BUNDLE_DIR/overlay/routes/cloudflared.js"
as_sp() { sudo -u showpilot "$@"; }

# "router.post('/token'" -> "post /token", one per line, sorted.
routes_in() { grep -oE "router\.(get|post|put|patch|delete)\(['\"][^'\"]+" | sed -E "s/router\.([a-z]+)\(['\"]/\1 /" | sort -u; }

[ -f "$OVERLAY" ] || { echo "ERROR: overlay not found at $OVERLAY"; exit 1; }
cd "$LIVE_DIR"

echo "Current: $(grep '"version"' package.json | tr -d ' ,')"
as_sp git fetch --depth 1 origin main
NEW_VERSION="$(as_sp git show FETCH_HEAD:package.json | grep '"version"' | tr -d ' ,')"
echo "Latest main: $NEW_VERSION"

MISSING="$(comm -23 <(as_sp git show FETCH_HEAD:routes/cloudflared.js | routes_in) <(routes_in < "$OVERLAY"))"
if [ -n "$MISSING" ]; then
  echo "ERROR: ShowPilot's tunnel routes have endpoints the demo overlay doesn't cover:"
  echo "$MISSING" | sed 's/^/  /'
  echo "Staying on the current version. Add them to overlay/routes/cloudflared.js in the demo bundle."
  exit 1
fi

as_sp git reset --hard FETCH_HEAD
install -o showpilot -g showpilot -m 644 "$OVERLAY" "$LIVE_DIR/routes/cloudflared.js"
grep -q "ShowPilot Demo — neutered Cloudflare Tunnel routes" "$LIVE_DIR/routes/cloudflared.js" \
  || { echo "ERROR: overlay copy didn't take"; exit 1; }
as_sp npm install --omit=dev --no-audit --no-fund

# Restart through the reset script, not `pm2 restart`. PM2 on this LXC
# loses track of the running ShowPilot from time to time; `pm2 restart`
# then fails and the OLD process keeps serving while the new files sit on
# disk underneath it. Modules it loads later come from the new version and
# don't match the old code in memory, so the viewer page errors out
# (seen after v0.33.265). reset.sh kills whatever holds the port, restores
# the seed data and re-registers both processes from ecosystem.config.js.
bash "$SCRIPT_DIR/reset.sh"

echo "Updated to: $(grep '"version"' package.json | tr -d ' ,') (tunnel controls neutered)"
