// ============================================================
// ShowPilot Demo — neutered Cloudflare Tunnel routes
// ============================================================
// Replaces the real routes/cloudflared.js on the demo LXC. Visitors
// see the Cloudflare Tunnel UI in its "configured & running" state
// (the pitch state — green pill, healthy status) but every write
// endpoint returns a friendly "demo mode" message instead of doing
// anything.
//
// This file is applied by scripts/apply-demo-overlay.sh after each
// clone/checkout of ShowPilot. The real cloudflared library
// (lib/cloudflared.js) is left untouched — it just never gets
// triggered because no token is ever saved on the demo.
//
// IMPORTANT: this file lives in the ShowPilot-Demo bundle, not in
// ShowPilot main. Demo concerns don't go in main (per the demo
// primer's working-style rule). When ShowPilot's real cloudflared
// route surface changes, this file may need updates to match.
// ============================================================

const express = require('express');
const router = express.Router();

// What State C wants to see in the admin UI: installed, has token,
// running, connected, on a supported arch. Picked specifically so
// the UI renders the "Public Access — Online" green pill and the
// configured-state action panel rather than scary install buttons.
const FAKE_STATUS = {
  installed: true,
  version: 'cloudflared version 2024.10.0 (demo)',
  hasToken: true,
  running: true,
  connected: true,
  connectedAt: new Date(Date.now() - 1000 * 60 * 17).toISOString(), // 17 min ago — looks lived-in
  userIntent: 'started',
  lastSpawnedAt: new Date(Date.now() - 1000 * 60 * 17).toISOString(),
  lastExitCode: null,
  lastExitReason: null,
  respawnAttempts: 1,
  arch: 'amd64',
  archSupported: true,
  platform: 'linux',
};

// Stable fake log snippet. Looks like real cloudflared output to
// anyone who's seen the real thing, but contains no real tunnel ID
// or hostname. The "demo.example.com" domain is reserved by IETF
// (RFC 2606) and intentionally non-routable.
const FAKE_LOGS = [
  '[supervisor] Token found on disk; auto-starting tunnel.',
  '[supervisor] Spawning cloudflared (attempt 1)...',
  '2026-04-29T18:00:01Z INF Starting tunnel tunnelID=00000000-0000-0000-0000-000000000000',
  '2026-04-29T18:00:01Z INF Version 2024.10.0',
  '2026-04-29T18:00:01Z INF GOOS: linux, GOVersion: go1.22, GoArch: amd64',
  '2026-04-29T18:00:02Z INF Generated Connector ID: 00000000-0000-0000-0000-000000000000',
  '2026-04-29T18:00:02Z INF Initial protocol quic',
  '2026-04-29T18:00:03Z INF Registered tunnel connection connIndex=0 location=dfw01',
  '2026-04-29T18:00:03Z INF Registered tunnel connection connIndex=1 location=dfw02',
  '2026-04-29T18:00:04Z INF Registered tunnel connection connIndex=2 location=ord06',
  '2026-04-29T18:00:04Z INF Registered tunnel connection connIndex=3 location=ord08',
  '[supervisor] Tunnel connected.',
].join('\n');

// Friendly message for every write endpoint. Not technical jargon —
// this is what a curious visitor sees, so it should sell the feature
// while explaining the limitation.
const DEMO_MESSAGE =
  'This is a public demo, so the Cloudflare Tunnel controls are read-only. ' +
  'On a real install, this button would manage your tunnel runtime and token. ' +
  'Want to try it for real? Install ShowPilot on your own FPP host.';

function denyWithDemoMessage(res) {
  return res.status(403).json({ ok: false, demo: true, error: DEMO_MESSAGE });
}

router.get('/status', (req, res) => {
  res.json(FAKE_STATUS);
});

router.post('/install',   (req, res) => denyWithDemoMessage(res));
router.post('/token',     (req, res) => denyWithDemoMessage(res));
router.post('/start',     (req, res) => denyWithDemoMessage(res));
router.post('/stop',      (req, res) => denyWithDemoMessage(res));
router.post('/restart',   (req, res) => denyWithDemoMessage(res));
router.post('/uninstall', (req, res) => denyWithDemoMessage(res));

router.get('/logs', (req, res) => {
  res.json({ ok: true, logs: FAKE_LOGS });
});

module.exports = router;
