# ShowPilot Demo LXC Bundle

This bundle provisions a public demo instance of ShowPilot — a fake-plugin-driven
ShowPilot install that resets itself to a known state every 10 minutes so visitors
can poke at the admin UI without permanently breaking anything.

## What's in this bundle

| File | Purpose |
|---|---|
| `scripts/setup.sh` | One-time LXC bootstrap: installs deps, clones ShowPilot, registers PM2 processes, sets up cron + logrotate |
| `scripts/build-seed.sh` | Constructs the "golden" seed data dir that resets restore from |
| `scripts/reset.sh` | Cron'd every 10 min: stops processes, restores seed, restarts |
| `scripts/apply-demo-overlay.sh` | Copies `overlay/` files over the live ShowPilot tree (neuters Cloudflare Tunnel install/start endpoints). Re-run after every `git checkout vX.Y.Z` of ShowPilot — git restores the upstream files on checkout |
| `overlay/routes/cloudflared.js` | Demo replacement for ShowPilot's tunnel routes — UI shows the "online" state, every write endpoint returns a friendly "demo mode, can't do that" message |
| `fakeplugin/fake-plugin.js` | Pretends to be FPP+ShowPilot-plugin; cycles 4 holiday tracks at ~2.5min each |
| `fakeplugin/package.json` | Fake plugin's package metadata (zero deps) |
| `ecosystem.config.js` | PM2 ecosystem registering both processes by name |

## How it works

```
┌────────────────────────────────────────────────────────────────┐
│ Demo LXC                                                       │
│                                                                │
│  ┌──────────────────────┐     ┌──────────────────────────┐     │
│  │ showpilot-demo       │←────│ showpilot-demo-          │     │
│  │ (PM2)                │     │  fakeplugin (PM2)        │     │
│  │ port 3100            │     │ posts /heartbeat,        │     │
│  │ demoMode:true        │     │ /playing, /position to   │     │
│  │ admin user no-prompt │     │ ShowPilot every 1s       │     │
│  └──────────┬───────────┘     └──────────────────────────┘     │
│             │                                                  │
│             │ reads                                            │
│             ▼                                                  │
│  ┌──────────────────────┐                                      │
│  │ /opt/showpilot-demo/ │                                      │
│  │   data/              │ ← restored from seed every 10 min    │
│  │     showpilot.db     │                                      │
│  │     secrets.json     │                                      │
│  │     demo-next-       │                                      │
│  │       reset.json     │ ← written by reset.sh                │
│  └──────────────────────┘                                      │
│                                                                │
│  ┌──────────────────────┐                                      │
│  │ /opt/showpilot-demo- │                                      │
│  │  seed/               │ ← read-only golden state             │
│  │   data/...           │   (built once by build-seed.sh,      │
│  └──────────────────────┘    re-snapshotted on demand)         │
│                                                                │
│  ┌──────────────────────┐                                      │
│  │ /etc/cron.d/         │                                      │
│  │  showpilot-demo      │ ← */10 * * * * reset.sh              │
│  └──────────────────────┘                                      │
└────────────────────────────────────────────────────────────────┘
              │
              │ HTTP, port 3100
              ▼
        Reverse proxy (NPM)
              │
              ▼
        demo.showpilot.dev
```

## First-time setup

On a fresh Ubuntu 24.04 LXC (Proxmox or otherwise):

```bash
# 1. Get this bundle onto the LXC. Assuming you've extracted the
#    tarball to /tmp/showpilot-demo-lxc/:
cd /tmp/showpilot-demo-lxc

# 2. Run the bootstrap (root). Installs Node 22, npm, sqlite3, PM2,
#    creates the showpilot user, clones ShowPilot, writes config.js,
#    registers PM2 processes, sets up cron + logrotate + boot startup.
sudo bash scripts/setup.sh

# 3. Build the seed (root). Boots ShowPilot fresh, runs the fake plugin
#    briefly to populate sequences, clears the must_change_password
#    flag, snapshots the data dir to /opt/showpilot-demo-seed/.
sudo /opt/showpilot-demo/scripts/build-seed.sh

# 4. Verify it's running
curl http://127.0.0.1:3100/api/public/demo-status
# Should print: {"demoMode":true,"credentialsHint":"admin / admin", ...}

pm2 status
# Both showpilot-demo and showpilot-demo-fakeplugin should be "online"
```

That's it. The cron entry runs every 10 minutes and restores the seed.

## Customizing the demo's preconfigured state

You almost certainly want to change the demo's defaults — pick a theme, set voting
or jukebox mode, customize the viewer template, add fake vote tallies, etc. Do this
through the admin UI, then snapshot:

```bash
# 1. Visit your demo in a browser, log in (admin/admin), make changes
# 2. Snapshot the live state as the new seed:
sudo /opt/showpilot-demo/scripts/build-seed.sh snapshot
```

`snapshot` mode briefly stops both processes (for a consistent SQLite snapshot),
copies the live data dir over the seed, and restarts. The next reset will restore
your customizations.

To start over from scratch, run without the `snapshot` argument:

```bash
sudo /opt/showpilot-demo/scripts/build-seed.sh
# Or explicitly:
sudo /opt/showpilot-demo/scripts/build-seed.sh fresh
```

`fresh` mode wipes everything, including the auto-generated `secrets.json`, and
generates a brand-new showToken. The fake plugin auto-discovers the new token
on its next 60s polling cycle.

## Operational commands

```bash
# Status
pm2 status

# Logs
pm2 logs showpilot-demo --lines 50
pm2 logs showpilot-demo-fakeplugin --lines 50
tail -f /var/log/showpilot-demo-reset.log

# Force a reset right now
sudo /opt/showpilot-demo/scripts/reset.sh

# Restart processes manually (e.g. after editing config.js)
pm2 restart showpilot-demo

# Update ShowPilot to a newer version
cd /opt/showpilot-demo
sudo -u showpilot git fetch --tags
sudo -u showpilot git checkout vX.Y.Z
sudo -u showpilot npm install --production
sudo /opt/showpilot-demo/scripts/build-seed.sh   # rebuild seed against new schema
```

## Reverse proxy

The demo speaks plain HTTP on port 3100. Front it with whatever you already use:

**NPM (Nginx Proxy Manager):**
- New Proxy Host: `demo.showpilot.dev` → `http://192.168.x.x:3100`
- Block scheme: `http` (not https — terminate TLS at NPM)
- Websockets Support: **on** (ShowPilot uses socket.io for live position updates)
- Forward Hostname / IP: the demo LXC's IP
- Force SSL + HTTP/2: on

If you put it on a path prefix (e.g. `lightsondrake.org/demo`), be aware that
ShowPilot doesn't do path-prefix-aware URLs the way ShipPilot does. Use a
dedicated subdomain.

## Troubleshooting

**"both processes are online but the page says 'Show isn't playing'"**
The fake plugin probably can't read `secrets.json`. Check its logs:
```bash
pm2 logs showpilot-demo-fakeplugin --lines 30
```
Likely cause: ownership on `/opt/showpilot-demo/data/secrets.json` isn't `showpilot:showpilot`. Re-run setup.sh's chown step:
```bash
sudo chown -R showpilot:showpilot /opt/showpilot-demo/data
```

**"the banner says 'Resets in —' (no countdown)"**
That means `data/demo-next-reset.json` is missing or malformed. The first-ever
boot before reset.sh has run is the only legitimate time you'd see this. Either
wait for the next cron tick (≤10 min) or force a reset:
```bash
sudo /opt/showpilot-demo/scripts/reset.sh
```

**"after a reset, the demo still shows yesterday's votes"**
Browser cache, probably. The viewer page polls live state every 5s, but cached
HTML may show stale info momentarily. Hard-refresh.

**"the cron isn't running"**
Check the log:
```bash
sudo cat /var/log/showpilot-demo-reset.log
sudo systemctl status cron   # cron daemon up?
sudo cat /etc/cron.d/showpilot-demo   # entry exists?
```

**"I want a different reset interval"**
Three things must agree:
1. `/etc/cron.d/showpilot-demo` — the `*/N * * * *` schedule
2. `/opt/showpilot-demo/config.js` — `demoResetIntervalMinutes`
3. `reset.sh` — `RESET_INTERVAL_MIN` env var (or the default)

Easiest is to edit (1) and (2), and either edit reset.sh's default or pass
`RESET_INTERVAL_MIN=N` from the cron entry. The countdown displayed on the
banner uses (3) implicitly since reset.sh writes the timestamp.

## What the fake plugin pretends to be

It POSTs the same shape of payloads as the real ShowPilot FPP plugin would,
authenticated with the same Bearer-token scheme. ShowPilot can't tell the
difference (and shouldn't — the protocol is the abstraction).

Tracks are hardcoded in `fake-plugin.js`. To add or remove tracks, edit the
`TRACKS` array. After editing, re-run `build-seed.sh` so the seed picks up
the new sequence list — otherwise resets will keep restoring the old sequences
table while the fake plugin tries to sync new ones, which works but creates
temporary inconsistency between resets.

## Files NOT in this bundle (yet)

These were considered and deferred:

- **HTTPS termination on the LXC itself.** Relies on NPM in front. Cookies
  stay non-Secure for that reason.
- **A "captcha" or rate-limit on the admin login.** Demo password is public,
  so bots will try to log in and run admin actions. Reset cycle is the only
  defense — after 10 min, anything they did is gone. If this becomes a real
  problem, add a Cloudflare challenge at the proxy layer.
- **Disabling Cloudflare Tunnel admin UI** (v0.29.0+ feature). Visitors could
  in principle try to set up a tunnel via the demo. Reset wipes any state,
  but the ephemeral tunnel itself runs as a child process. If this is a
  concern, the safest thing is to remove `cloudflared` from the LXC entirely
  so the admin UI can't actually start one — `apt remove cloudflared`.
- **Multiple-instance demos** (e.g. one in voting mode, one in jukebox mode).
  Currently single-instance. To run multiple, replicate this bundle with
  different ports + PM2 names + cron entries.

## Bundle version

`demo-lxc-v0.1.0` — built against ShowPilot v0.31.0 (the version that introduced
the `demoMode` flag and `/api/public/demo-status` endpoint).
