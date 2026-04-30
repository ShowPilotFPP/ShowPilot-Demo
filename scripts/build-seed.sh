#!/bin/bash
# ============================================================
# ShowPilot Demo — Seed Builder
# ============================================================
# Constructs /opt/showpilot-demo-seed/data from scratch:
#   1. Wipes any existing live data dir
#   2. Boots ShowPilot fresh (auto-generates secrets)
#   3. Runs the fake plugin briefly to populate the sequences table
#   4. Sets the admin password to "admin" (overrides must_change_password)
#   5. Stops everything
#   6. Copies the populated data dir to /opt/showpilot-demo-seed/data
#
# Run this ONCE during initial LXC setup. Not driven by cron.
#
# Re-run it whenever you want to change the demo's preconfigured state
# (e.g. after manually customizing the theme via the admin UI on a
# running demo, snapshot that state to become the new seed).
#
# Customization workflow:
#   1. Run setup.sh (first time)
#   2. Run build-seed.sh (creates initial seed)
#   3. Visit demo, customize theme/voting mode/etc. via admin UI
#   4. Run build-seed.sh again — it'll snapshot your customizations
# ============================================================

set -euo pipefail

LIVE_DIR="/opt/showpilot-demo"
SEED_DIR="/opt/showpilot-demo-seed"
FAKE_PLUGIN_DIR="/opt/showpilot-demo-fakeplugin"

# How long to let the fake plugin run while seeding. 8 seconds is
# plenty for it to acquire token + post sync-sequences + send a few
# heartbeats. We don't want a long-running track-change because it
# would write play_history rows we'd then have to clean up.
SEED_PLUGIN_RUN_SECONDS=8

# Mode: "fresh" (default) wipes everything and starts over, or
# "snapshot" snapshots the live dir without restarting (so you
# can preserve any in-UI customizations made on a running demo).
MODE="${1:-fresh}"

log() { echo "[seed-build] $*"; }

if [ "$MODE" = "snapshot" ]; then
  log "snapshot mode — capturing live data without restart"
  if [ ! -d "$LIVE_DIR/data" ]; then
    log "ERROR: no live data to snapshot at $LIVE_DIR/data"
    exit 1
  fi
  log "stopping services briefly to ensure consistent snapshot..."
  pm2 stop showpilot-demo >/dev/null 2>&1 || true
  pm2 stop showpilot-demo-fakeplugin >/dev/null 2>&1 || true
  sleep 1

  rm -rf "$SEED_DIR/data"
  mkdir -p "$SEED_DIR"
  cp -a "$LIVE_DIR/data" "$SEED_DIR/data"
  # Don't snapshot the next-reset file — it's regenerated every cycle
  rm -f "$SEED_DIR/data/demo-next-reset.json"

  log "starting services again..."
  pm2 start showpilot-demo >/dev/null 2>&1
  pm2 start showpilot-demo-fakeplugin >/dev/null 2>&1
  log "snapshot complete: $SEED_DIR/data"
  exit 0
fi

# ===== fresh mode =====
log "fresh-build mode — full reset and reseed"

# Stop everything
pm2 stop showpilot-demo >/dev/null 2>&1 || true
pm2 stop showpilot-demo-fakeplugin >/dev/null 2>&1 || true

# Wipe live + seed
rm -rf "$LIVE_DIR/data"
rm -rf "$SEED_DIR/data"
mkdir -p "$LIVE_DIR/data" "$SEED_DIR"
chown -R showpilot:showpilot "$LIVE_DIR/data" 2>/dev/null || true

# Boot ShowPilot. PM2 picks up the demoMode=true config and stale
# data is gone, so this is a clean first-run.
log "starting fresh ShowPilot..."
pm2 start showpilot-demo >/dev/null 2>&1
log "waiting for ShowPilot to come up..."
for i in {1..30}; do
  if curl -fsS "http://127.0.0.1:3100/api/public/demo-status" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Run the fake plugin long enough to seed sequences
log "running fake plugin briefly to seed sequences..."
pm2 start showpilot-demo-fakeplugin >/dev/null 2>&1
sleep "$SEED_PLUGIN_RUN_SECONDS"
pm2 stop showpilot-demo-fakeplugin >/dev/null 2>&1

# A fresh ShowPilot install already creates user 'admin' with password
# 'admin' (bcrypt-hashed by db.js init). The only thing we need to do
# is clear must_change_password so visitors aren't prompted to change
# the password on first login. We DON'T re-hash the password — leaving
# it as the value db.js already set means we always match whatever
# bcrypt version + salt strategy ShowPilot uses, with zero risk of drift.

log "clearing must_change_password flag on admin user..."
sqlite3 "$LIVE_DIR/data/showpilot.db" <<EOF
UPDATE users
SET must_change_password = 0
WHERE username = 'admin';
EOF

# Insert demo viewer-page templates so visitors can preview different
# looks via Settings → Templates → Activate. The HTML lives next to
# this script in templates/ so it's source-controlled and easy to
# tweak. We use sqlite3's `.import` of CSV would be a pain with HTML
# (commas, quotes), so we go through stdin parameter binding instead.
#
# Path resolution: works for both the initial-bundle layout
# ($BUNDLE_DIR/scripts/build-seed.sh + $BUNDLE_DIR/templates/) and
# the installed layout (/opt/showpilot-demo/scripts/build-seed.sh +
# /opt/showpilot-demo/templates/). Both collapse to ../templates from
# the script's own dir.
TEMPLATES_DIR="$(dirname "$(readlink -f "$0")")/../templates"
if [ -d "$TEMPLATES_DIR" ]; then
  log "inserting demo viewer templates from $TEMPLATES_DIR..."
  for tpl in "$TEMPLATES_DIR"/*.html; do
    [ -f "$tpl" ] || continue
    fname="$(basename "$tpl" .html)"
    # Pretty-print the template name: "holiday-marquee" → "Holiday Marquee"
    tpl_name="$(echo "$fname" | sed -e 's/-/ /g' -e 's/\b./\u&/g')"
    # Use Python for reliable SQL escaping — bash quoting + 5KB of
    # HTML is a recipe for footguns. python3 is already installed
    # (apt-installed by setup.sh).
    python3 - "$LIVE_DIR/data/showpilot.db" "$tpl_name" "$tpl" <<'PYEOF'
import sqlite3, sys
db_path, name, html_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(html_path, 'r', encoding='utf-8') as f:
    html = f.read()
con = sqlite3.connect(db_path)
# Insert as builtin so the demo's template list always shows them,
# but NOT active — the default "Default (ShowPilot)" template stays
# active so visitors land on familiar UI first and discover these
# via Settings → Templates.
con.execute(
    "INSERT INTO viewer_page_templates (name, html, is_active, is_builtin) VALUES (?, ?, 0, 1)",
    (name, html)
)
con.commit()
con.close()
PYEOF
    log "  + $tpl_name"
  done
else
  log "no templates/ directory found — skipping demo template import"
fi

# Stop the live server so we can snapshot a quiet data dir
log "stopping ShowPilot to snapshot..."
pm2 stop showpilot-demo >/dev/null 2>&1
sleep 2

# Copy live data to seed
log "snapshotting to $SEED_DIR/data ..."
cp -a "$LIVE_DIR/data" "$SEED_DIR/data"
# Strip the next-reset file; it'll be regenerated by reset.sh
rm -f "$SEED_DIR/data/demo-next-reset.json"

# Note: we deliberately do NOT chmod the seed read-only. cp -a in
# reset.sh would propagate the read-only bits to the live copy, and
# ShowPilot couldn't write to its own DB. The seed dir is in /opt
# (root-owned) which is protection enough — only intentional `sudo`
# operations can clobber it.

log "seed built: $SEED_DIR/data"
log "you can now run reset.sh to test, or just let cron handle it"

# Restart services with the freshly-seeded state
log "restoring live state from seed for first run..."
rm -rf "$LIVE_DIR/data"
cp -a "$SEED_DIR/data" "$LIVE_DIR/data"
chown -R showpilot:showpilot "$LIVE_DIR/data" 2>/dev/null || true

NEXT_RESET="$(date -u -d "+10 minutes" +%Y-%m-%dT%H:%M:%S.000Z)"
echo "{\"nextResetAt\":\"$NEXT_RESET\"}" > "$LIVE_DIR/data/demo-next-reset.json"
chown showpilot:showpilot "$LIVE_DIR/data/demo-next-reset.json" 2>/dev/null || true

pm2 start showpilot-demo >/dev/null 2>&1
pm2 start showpilot-demo-fakeplugin >/dev/null 2>&1
log "done"
