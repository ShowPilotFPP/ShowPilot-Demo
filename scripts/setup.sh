#!/bin/bash
# ============================================================
# ShowPilot Demo — One-Time LXC Setup
# ============================================================
# Bootstraps a fresh Ubuntu 24.04 LXC into a working demo host:
#   - Installs Node 22, npm, sqlite3, git, curl, build-essential
#   - Installs PM2 globally
#   - Creates the `showpilot` system user
#   - Clones ShowPilot to /opt/showpilot-demo at the pinned version
#   - Installs the fake plugin to /opt/showpilot-demo-fakeplugin
#   - Writes /opt/showpilot-demo/config.js with demoMode:true
#   - Installs the reset script + cron entry
#   - Configures logrotate
#   - Registers both processes with PM2 + sets up pm2 startup
#
# Idempotent: re-running is safe. Use this when you spin up a new
# LXC, or when something has drifted and you want to start over
# (combine with `rm -rf /opt/showpilot-demo*` first for a true
# from-scratch reset).
#
# After this script finishes, the demo will NOT yet be working —
# you need to run build-seed.sh once to construct the seed dir.
# That step is separate so you can customize the seed (theme,
# voting mode, etc.) without re-running the whole bootstrap.
#
# Run as root:
#   sudo bash setup.sh
# ============================================================

set -euo pipefail

SHOWPILOT_VERSION="v0.32.0"
SHOWPILOT_REPO="https://github.com/ShowPilotFPP/ShowPilot.git"

LIVE_DIR="/opt/showpilot-demo"
SEED_DIR="/opt/showpilot-demo-seed"
FAKEPLUGIN_DIR="/opt/showpilot-demo-fakeplugin"

# Where this bundle was extracted. setup.sh lives in scripts/, so the
# bundle root (which contains both scripts/ and fakeplugin/) is one
# directory up. We resolve via BASH_SOURCE so this works regardless
# of whether the user runs `bash scripts/setup.sh` from the bundle
# root, or `bash setup.sh` from inside scripts/, or any other cwd.
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[setup] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (try: sudo bash setup.sh)" >&2
  exit 1
fi

# ============================================================
# 1. System packages
# ============================================================
log "installing apt packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl \
  git \
  sqlite3 \
  build-essential \
  python3 \
  ca-certificates \
  >/dev/null

# Node 22 from NodeSource if not already present at >=20
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -dv -f2 | cut -d. -f1)" -lt 20 ]; then
  log "installing Node.js 22 from NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
log "node $(node -v), npm $(npm -v)"

# ============================================================
# 2. PM2
# ============================================================
if ! command -v pm2 >/dev/null 2>&1; then
  log "installing PM2 globally..."
  npm install -g pm2 --silent
fi

# ============================================================
# 3. showpilot system user
# ============================================================
if ! id showpilot >/dev/null 2>&1; then
  log "creating 'showpilot' system user..."
  useradd --system --create-home --home-dir /var/lib/showpilot --shell /usr/sbin/nologin showpilot
fi

# ============================================================
# 4. Clone / update ShowPilot at pinned version
# ============================================================
if [ -d "$LIVE_DIR/.git" ]; then
  log "updating existing ShowPilot clone..."
  git -C "$LIVE_DIR" fetch --tags --quiet
  git -C "$LIVE_DIR" checkout --quiet "$SHOWPILOT_VERSION"
else
  log "cloning ShowPilot $SHOWPILOT_VERSION..."
  rm -rf "$LIVE_DIR"
  git clone --quiet --branch "$SHOWPILOT_VERSION" --depth 1 "$SHOWPILOT_REPO" "$LIVE_DIR"
fi

log "installing ShowPilot npm deps (this takes a minute, native bcrypt build)..."
cd "$LIVE_DIR"
npm install --production --silent --no-audit --no-fund

# ============================================================
# 5. Install fake plugin
# ============================================================
log "installing fake plugin..."
mkdir -p "$FAKEPLUGIN_DIR"
cp -f "$BUNDLE_DIR/fakeplugin/fake-plugin.js" "$FAKEPLUGIN_DIR/"
cp -f "$BUNDLE_DIR/fakeplugin/package.json"   "$FAKEPLUGIN_DIR/"
# Silent MP3s (one per track in fake-plugin's TRACKS array). Uploaded
# into ShowPilot's audio cache on startup so the viewer player loads
# real bytes and stays in "playing" state instead of "Load failed".
mkdir -p "$FAKEPLUGIN_DIR/audio"
cp -f "$BUNDLE_DIR/fakeplugin/audio/"*.mp3 "$FAKEPLUGIN_DIR/audio/"
# No npm install needed — fake plugin is dependency-free (only uses node stdlib)

# ============================================================
# 6. config.js with demoMode:true
# ============================================================
# Only write if it doesn't exist — preserve hand-edited config across
# re-runs of setup.sh. To force a fresh config, delete it first.
if [ ! -f "$LIVE_DIR/config.js" ]; then
  log "writing demo config.js..."
  cat > "$LIVE_DIR/config.js" <<'EOF'
// Demo instance config. Generated once by setup.sh.
// Edit freely — re-running setup.sh will NOT overwrite this file.
module.exports = {
  // Server
  port: 3100,
  host: '0.0.0.0',

  // Behind nginx-proxy-manager, so trust 1 hop
  trustProxy: 1,

  // Database
  dbPath: './data/showpilot.db',

  // Secrets — auto-generated to data/secrets.json on first run.
  // After build-seed.sh, the seed contains a fixed secrets.json so
  // every reset restores the same showToken (the fake plugin needs
  // a stable token across resets).
  jwtSecret: null,
  sessionCookieName: 'showpilot_session',
  sessionDurationHours: 24 * 30,

  showToken: null,

  viewer: {
    activeWindowSeconds: 30,
    pollIntervalMs: 5000,
    maxJukeboxRequestsPerViewer: 1,
    maxVotesPerRound: 1,
  },

  voting: {
    resetAfterWinnerPlays: true,
  },

  // ===== DEMO MODE =====
  demoMode: true,
  demoResetIntervalMinutes: 10,
  demoCredentialsHint: 'admin / admin',

  logLevel: 'info',
};
EOF
fi

# ============================================================
# 7. Install scripts to /opt/showpilot-demo/scripts/
# ============================================================
log "installing reset.sh and build-seed.sh..."
mkdir -p "$LIVE_DIR/scripts"
cp -f "$BUNDLE_DIR/scripts/reset.sh"              "$LIVE_DIR/scripts/"
cp -f "$BUNDLE_DIR/scripts/build-seed.sh"         "$LIVE_DIR/scripts/"
cp -f "$BUNDLE_DIR/scripts/apply-demo-overlay.sh" "$LIVE_DIR/scripts/"
chmod +x "$LIVE_DIR/scripts/reset.sh" \
         "$LIVE_DIR/scripts/build-seed.sh" \
         "$LIVE_DIR/scripts/apply-demo-overlay.sh"

# Demo overlay — files that replace stock ShowPilot files to neuter
# things visitors shouldn't actually trigger (Cloudflare Tunnel
# install/start, etc.). Copied alongside the scripts so future
# upgrades of ShowPilot can re-apply via apply-demo-overlay.sh
# without needing the original bundle on disk.
log "installing demo overlay files..."
mkdir -p "$LIVE_DIR/scripts/overlay"
cp -rf "$BUNDLE_DIR/overlay/." "$LIVE_DIR/scripts/overlay/"

# Demo viewer templates — pre-made HTML/CSS templates that visitors
# can switch to via Settings → Templates. Copied into LIVE_DIR so
# build-seed.sh can find and import them when (re)building the seed
# DB. Lives beside scripts/ rather than inside it because they're
# data, not executables.
if [ -d "$BUNDLE_DIR/templates" ]; then
  log "installing demo viewer templates..."
  mkdir -p "$LIVE_DIR/templates"
  cp -f "$BUNDLE_DIR/templates/"*.html "$LIVE_DIR/templates/" 2>/dev/null || true
fi

# Apply the overlay over the freshly-cloned ShowPilot tree. Run
# now so the ShowPilot we boot below is already neutered. After
# any subsequent ShowPilot version bump (git checkout vX.Y.Z), the
# operator must re-run apply-demo-overlay.sh — git checkout will
# restore the upstream files.
log "applying demo overlay..."
bash "$LIVE_DIR/scripts/apply-demo-overlay.sh"

# Ecosystem file
cp -f "$BUNDLE_DIR/ecosystem.config.js" "$LIVE_DIR/ecosystem.config.js"

# ============================================================
# 8. Empty seed dir (build-seed.sh fills it later)
# ============================================================
mkdir -p "$SEED_DIR"

# ============================================================
# 9. Permissions
# ============================================================
log "setting ownership on $LIVE_DIR and $FAKEPLUGIN_DIR..."
chown -R showpilot:showpilot "$LIVE_DIR" "$FAKEPLUGIN_DIR"
# Seed dir is touched by reset.sh (root via cron) — leave as root-owned

# ============================================================
# 10. Cron — every 10 min
# ============================================================
log "installing cron entry..."
cat > /etc/cron.d/showpilot-demo <<EOF
# ShowPilot Demo — reset every 10 minutes
# Managed by /opt/showpilot-demo/scripts/setup.sh — do not edit by hand.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/10 * * * * root /opt/showpilot-demo/scripts/reset.sh
EOF
chmod 644 /etc/cron.d/showpilot-demo

# ============================================================
# 11. Logrotate for the reset log
# ============================================================
log "installing logrotate config..."
cat > /etc/logrotate.d/showpilot-demo <<'EOF'
/var/log/showpilot-demo-reset.log {
  daily
  rotate 7
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
}
EOF

# Make sure the log file exists and is writable so the first cron
# run doesn't blow up on a permission error.
touch /var/log/showpilot-demo-reset.log
chmod 644 /var/log/showpilot-demo-reset.log

# ============================================================
# 12. PM2 — register processes and set up boot startup
# ============================================================
# Run pm2 commands as the showpilot user so the dump file lives in
# their home dir. PM2 startup needs root once to install the
# systemd unit; after that, pm2 saves run as the user and survive.
log "registering PM2 processes (as showpilot user)..."
sudo -u showpilot HOME=/var/lib/showpilot pm2 start "$LIVE_DIR/ecosystem.config.js" --silent || true
sudo -u showpilot HOME=/var/lib/showpilot pm2 save --silent

# Install systemd unit for pm2 startup. `pm2 startup` is a two-step
# dance: first run it to print a `sudo env PATH=... pm2 startup systemd
# -u showpilot --hp ...` command, then run THAT command as root. We
# combine both by running pm2 startup directly with the right flags
# and PATH already set — no copy-paste needed. This installs the
# systemd unit so PM2 (and the showpilot processes via pm2 save) start
# at boot.
log "installing pm2 systemd boot unit..."
env PATH="$PATH:/usr/bin" pm2 startup systemd -u showpilot --hp /var/lib/showpilot >/dev/null

# After pm2 startup creates the unit, save the current process list
# AS the showpilot user so the dump file lives in their home and the
# systemd-managed PM2 daemon (which runs as showpilot) finds it.
sudo -u showpilot HOME=/var/lib/showpilot pm2 save --silent

# ============================================================
# Done
# ============================================================
cat <<EOF

================================================================
  ShowPilot Demo — bootstrap complete
================================================================

  Next steps:

    1. Build the seed (one-time):
         sudo /opt/showpilot-demo/scripts/build-seed.sh

       This runs ShowPilot briefly, populates demo sequences,
       clears the must-change-password flag, and snapshots the
       data dir to $SEED_DIR/data.

    2. Verify the demo is up:
         curl http://127.0.0.1:3100/api/public/demo-status

       Should return demoMode:true with a nextResetAt timestamp.

    3. Point your reverse proxy at port 3100 and you're done.

  Useful commands:

    pm2 status                                  # check both processes
    pm2 logs showpilot-demo --lines 50          # ShowPilot logs
    pm2 logs showpilot-demo-fakeplugin --lines 50   # fake plugin logs
    tail -f /var/log/showpilot-demo-reset.log   # cron reset history
    /opt/showpilot-demo/scripts/reset.sh        # force a reset now
    /opt/showpilot-demo/scripts/build-seed.sh snapshot  # re-snapshot
                                                  # current state as
                                                  # the new seed

================================================================
EOF
