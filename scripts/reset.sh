#!/bin/bash
# ============================================================
# ShowPilot Demo — Reset Script
# ============================================================
# Stops the demo ShowPilot + fake-plugin processes, restores the
# data directory from the read-only seed, writes the next-reset
# timestamp, and restarts the processes.
#
# Designed to be cron'd every N minutes (default 10 — change in
# /etc/cron.d/showpilot-demo).
#
# Idempotent: if a previous run crashed mid-restore, the next run
# will complete cleanly because we always blow away the live data
# dir before copying.
#
# Logs to /var/log/showpilot-demo-reset.log (rotated by logrotate
# config bundled with this distribution).
# ============================================================

set -euo pipefail

LIVE_DIR="/opt/showpilot-demo"
SEED_DIR="/opt/showpilot-demo-seed"
RESET_INTERVAL_MIN="${RESET_INTERVAL_MIN:-10}"
LOG_FILE="/var/log/showpilot-demo-reset.log"

# Append-only logging with timestamps, suitable for tail -f
log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"
}

log "=== reset starting ==="

# 1. Stop services. PM2 stop is graceful; if PM2 isn't running yet
#    (first boot), this is a no-op.
log "stopping services..."
pm2 stop showpilot-demo >/dev/null 2>&1 || true
pm2 stop showpilot-demo-fakeplugin >/dev/null 2>&1 || true

# 2. Wipe live data dir. We use rm -rf and recreate, NOT mv-then-rm,
#    so any lingering open file handles in a hung node process don't
#    leave a phantom backup dir behind. The PM2 stop above should
#    have closed all handles already.
log "wiping live data dir..."
if [ -d "$LIVE_DIR/data" ]; then
  rm -rf "$LIVE_DIR/data"
fi

# 3. Copy seed data into place. Seed dir is read-only by intention;
#    we copy the contents, NOT the dir itself.
log "restoring from seed..."
if [ ! -d "$SEED_DIR/data" ]; then
  log "FATAL: seed dir missing at $SEED_DIR/data"
  exit 1
fi
cp -a "$SEED_DIR/data" "$LIVE_DIR/data"
chown -R showpilot:showpilot "$LIVE_DIR/data" 2>/dev/null || true

# 4. Write next-reset timestamp BEFORE we start showpilot, so when
#    the public endpoint comes online it has fresh data immediately.
NEXT_RESET="$(date -u -d "+${RESET_INTERVAL_MIN} minutes" +%Y-%m-%dT%H:%M:%S.000Z)"
cat > "$LIVE_DIR/data/demo-next-reset.json" <<EOF
{"nextResetAt":"$NEXT_RESET"}
EOF
chown showpilot:showpilot "$LIVE_DIR/data/demo-next-reset.json" 2>/dev/null || true
log "next reset at $NEXT_RESET"

# 5. Restart services. ShowPilot first — fake plugin needs it up
#    to send the bearer token.
log "starting showpilot..."
pm2 start showpilot-demo >/dev/null 2>&1
log "starting fake plugin..."
pm2 start showpilot-demo-fakeplugin >/dev/null 2>&1

log "=== reset complete ==="
