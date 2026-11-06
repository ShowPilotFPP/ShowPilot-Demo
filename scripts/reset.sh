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
# v0.1.4 hardening: PM2's name-based `pm2 stop` silently no-ops if
# its registry has lost track of the running process (which has
# happened repeatedly on this LXC — see PPID/port-mismatch bug).
# When that happens, the live ShowPilot keeps running with an open
# DB handle, the rm-rf-then-cp leaves a stale inode in memory, and
# the API returns DB values that don't match what's on disk. The
# fix: explicitly find anything bound to ShowPilot's port and kill
# it by PID, then wait for the port to be free before proceeding.
# Also: rebuild the PM2 registry from ecosystem.config.js on each
# reset (delete + start) so corrupted state can't accumulate.
#
# Logs to /var/log/showpilot-demo-reset.log (rotated by logrotate
# config bundled with this distribution).
# ============================================================

set -euo pipefail

LIVE_DIR="/opt/showpilot-demo"
SEED_DIR="/opt/showpilot-demo-seed"
SHOWPILOT_PORT="${SHOWPILOT_PORT:-3100}"
RESET_INTERVAL_MIN="${RESET_INTERVAL_MIN:-10}"
LOG_FILE="/var/log/showpilot-demo-reset.log"

# Append-only logging with timestamps, suitable for tail -f
log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"
}

# Find PIDs of anything listening on a TCP port. Returns space-
# separated PIDs, or empty string if nothing's listening.
pids_on_port() {
  local port="$1"
  ss -tlnp "sport = :$port" 2>/dev/null \
    | awk -F'pid=' 'NR>1 { for (i=2; i<=NF; i++) { split($i, a, ","); print a[1] } }' \
    | sort -u | tr '\n' ' '
}

log "=== reset starting ==="

# ============================================================
# 1. Tell PM2 to stop the processes (best-effort). PM2's daemon
#    may or may not actually find them — that's why step 2 exists.
# ============================================================
log "stopping services via PM2..."
pm2 stop showpilot-demo            >/dev/null 2>&1 || true
pm2 stop showpilot-demo-fakeplugin >/dev/null 2>&1 || true

# ============================================================
# 2. Verify port is free. If anything is still listening, PM2
#    didn't actually stop the process — kill it directly.
# ============================================================
PIDS="$(pids_on_port "$SHOWPILOT_PORT")"
if [ -n "$PIDS" ]; then
  log "WARN: PM2 stop didn't free port $SHOWPILOT_PORT — orphan PIDs: $PIDS"
  for pid in $PIDS; do
    log "  killing orphan PID $pid (TERM)..."
    kill "$pid" 2>/dev/null || true
  done
  # Give it 3 seconds to die gracefully
  for i in 1 2 3; do
    sleep 1
    PIDS="$(pids_on_port "$SHOWPILOT_PORT")"
    [ -z "$PIDS" ] && break
  done
  # Still alive? Force kill.
  if [ -n "$PIDS" ]; then
    log "  orphan still alive after TERM — escalating to KILL: $PIDS"
    for pid in $PIDS; do
      kill -9 "$pid" 2>/dev/null || true
    done
    sleep 1
  fi
  PIDS="$(pids_on_port "$SHOWPILOT_PORT")"
  if [ -n "$PIDS" ]; then
    log "FATAL: could not free port $SHOWPILOT_PORT after KILL (PIDs: $PIDS) — aborting reset"
    exit 1
  fi
fi

# ============================================================
# 3. Wipe live data dir. By this point we've verified nothing has
#    an open DB handle — ShowPilot is fully stopped.
# ============================================================
log "wiping live data dir..."
if [ -d "$LIVE_DIR/data" ]; then
  rm -rf "$LIVE_DIR/data"
fi

# ============================================================
# 4. Copy seed data into place.
# ============================================================
log "restoring from seed..."
if [ ! -d "$SEED_DIR/data" ]; then
  log "FATAL: seed dir missing at $SEED_DIR/data"
  exit 1
fi
cp -a "$SEED_DIR/data" "$LIVE_DIR/data"
chown -R showpilot:showpilot "$LIVE_DIR/data" 2>/dev/null || true

# ============================================================
# 5. Write next-reset timestamp BEFORE starting showpilot, so when
#    the public endpoint comes online it has fresh data immediately.
# ============================================================
NEXT_RESET="$(date -u -d "+${RESET_INTERVAL_MIN} minutes" +%Y-%m-%dT%H:%M:%S.000Z)"
cat > "$LIVE_DIR/data/demo-next-reset.json" <<EOF
{"nextResetAt":"$NEXT_RESET"}
EOF
chown showpilot:showpilot "$LIVE_DIR/data/demo-next-reset.json" 2>/dev/null || true
log "next reset at $NEXT_RESET"

# ============================================================
# 6. Rebuild PM2 registry from ecosystem.config.js.
#    `pm2 restart` won't recover from a corrupted registry —
#    delete + start does. Cheap and idempotent.
# ============================================================
log "(re-)registering processes from ecosystem..."
pm2 delete showpilot-demo            >/dev/null 2>&1 || true
pm2 delete showpilot-demo-fakeplugin >/dev/null 2>&1 || true
pm2 start "$LIVE_DIR/ecosystem.config.js" >/dev/null 2>&1
pm2 save --force >/dev/null 2>&1 || true

# Verify ShowPilot actually came up before declaring complete
PIDS=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  PIDS="$(pids_on_port "$SHOWPILOT_PORT")"
  [ -n "$PIDS" ] && break
done
if [ -z "$PIDS" ]; then
  log "WARN: ShowPilot did not bind port $SHOWPILOT_PORT within 10s after start"
else
  log "ShowPilot listening on port $SHOWPILOT_PORT (PID: $PIDS)"
fi

log "=== reset complete ==="
