// ============================================================
// ShowPilot Demo — Fake Plugin
// ============================================================
// Pretends to be Falcon Player + the ShowPilot FPP plugin so the demo
// instance has something to display. Cycles through a fixed set of
// "tracks" (no real audio — the viewer won't have an audio gate
// because demo mode disables location verification anyway, and we
// just want the now-playing UI to animate).
//
// Endpoints called (all require Bearer <showToken>):
//   POST /api/plugin/heartbeat     — every 30s, with version
//   POST /api/plugin/sync-sequences — once on start, then every 5 min
//   POST /api/plugin/playing       — on track change
//   POST /api/plugin/position      — every 1s during a track
//   POST /api/plugin/next          — when track changes (announces upcoming)
//
// Token source: read from $SHOWPILOT_TOKEN env, or from
// ../showpilot/data/secrets.json (whichever is set).
//
// Usage:
//   SHOWPILOT_URL=http://127.0.0.1:3100 \
//   SHOWPILOT_TOKEN=$(jq -r .showToken ../showpilot/data/secrets.json) \
//   node fake-plugin.js
//
// Ships with a sane default URL of 127.0.0.1:3100. When ShowPilot
// is reset by the cron, this process can stay running — it'll just
// log connection refused for a few seconds and reconnect.
// ============================================================

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { URL } = require('url');

const SHOWPILOT_URL = process.env.SHOWPILOT_URL || 'http://127.0.0.1:3100';
const SECRETS_PATH = process.env.SHOWPILOT_SECRETS_PATH ||
  path.join(__dirname, '..', 'showpilot', 'data', 'secrets.json');
// Silent MP3 files live next to fake-plugin.js in audio/. They're
// pre-generated (one per track in TRACKS, durations matching) and
// uploaded into ShowPilot's audio cache so /api/audio-stream/* serves
// them without "Load failed" on the viewer.
const AUDIO_DIR = path.join(__dirname, 'audio');
const VERSION = '0.0.1-demo';

// ============================================================
// Demo tracks
// ============================================================
// Each track is what FPP would call a "sequence": a name (the FPP
// filename, used as the sync key), display name, artist, length, and
// a stable image URL we'll seed into the sequences table for cover art.
// 4 tracks at ~2:30 each → 10 minute cycle, matching the reset cycle
// roughly so visitors see at least one track change per visit.
const TRACKS = [
  {
    name: 'Wizards_in_Winter',
    displayName: 'Wizards in Winter',
    artist: 'Trans-Siberian Orchestra',
    durationSeconds: 150,
    imageUrl: '',
    mediaName: 'wizards_in_winter.mp3',
  },
  {
    name: 'Carol_of_the_Bells',
    displayName: 'Carol of the Bells',
    artist: 'Pentatonix',
    durationSeconds: 145,
    imageUrl: '',
    mediaName: 'carol_of_the_bells.mp3',
  },
  {
    name: 'Linus_and_Lucy',
    displayName: 'Linus & Lucy',
    artist: 'Vince Guaraldi Trio',
    durationSeconds: 160,
    imageUrl: '',
    mediaName: 'linus_and_lucy.mp3',
  },
  {
    name: 'All_I_Want_for_Christmas',
    displayName: 'All I Want for Christmas Is You',
    artist: 'Mariah Carey',
    durationSeconds: 155,
    imageUrl: '',
    mediaName: 'all_i_want_for_christmas.mp3',
  },
];

// ============================================================
// Token loading
// ============================================================
function loadToken() {
  if (process.env.SHOWPILOT_TOKEN) return process.env.SHOWPILOT_TOKEN.trim();
  try {
    const raw = fs.readFileSync(SECRETS_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed.showToken === 'string') return parsed.showToken;
  } catch (err) {
    // File may not exist yet on the very first boot before showpilot
    // has generated secrets. We'll retry below.
  }
  return null;
}

// ============================================================
// State
// ============================================================
// trackIndex: which track is "playing" right now
// trackStartedAt: ms timestamp when this track began
// lastSyncAt: ms timestamp of last sync-sequences call
// needsReannounce: set true after a token recovery; tick() will
//   re-send /playing and /sync-sequences so ShowPilot's freshly-
//   reset state knows what's playing and which sequences exist.
let trackIndex = 0;
let trackStartedAt = Date.now();
let lastSyncAt = 0;
let token = null;
let lastTokenAttempt = 0;
let needsReannounce = false;

// Cooldown logging — avoid filling logs when ShowPilot is down,
// but use SEPARATE cooldowns per kind of error so e.g. one transient
// timeout doesn't suppress an auth error 5s later. Keys: 'http',
// 'network', 'timeout'.
const lastErrLogAt = { http: 0, network: 0, timeout: 0 };
function logErr(kind, label, msg) {
  const now = Date.now();
  if (now - (lastErrLogAt[kind] || 0) < 30000) return;
  lastErrLogAt[kind] = now;
  console.warn('[fake-plugin] ' + label + ': ' + msg);
}

// ============================================================
// HTTP helpers
// ============================================================
function rawRequest(method, urlPath, body, tok) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlPath, SHOWPILOT_URL);
    const lib = url.protocol === 'https:' ? https : http;
    const payload = body ? JSON.stringify(body) : null;
    const opts = {
      method,
      headers: {
        'Authorization': 'Bearer ' + tok,
        'User-Agent': 'showpilot-fake-plugin/' + VERSION,
      },
    };
    if (payload) {
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['Content-Length'] = Buffer.byteLength(payload);
    }
    const req = lib.request(url, opts, (res) => {
      let chunks = '';
      res.on('data', (c) => { chunks += c; });
      res.on('end', () => resolve({ status: res.statusCode, body: chunks }));
    });
    req.on('error', reject);
    req.setTimeout(8000, () => { req.destroy(new Error('timeout')); });
    if (payload) req.write(payload);
    req.end();
  });
}

// post() is the auth-aware wrapper around rawRequest. It:
//   - logs network errors
//   - on 401, re-reads secrets.json once and retries with the new token
//   - on retry success after a 401, sets needsReannounce so the next
//     tick re-syncs sequences and re-announces the current track
//   - logs any other 4xx/5xx as a warning (without retry — only auth
//     is recoverable here)
//
// Returns true on 2xx, false on anything else.
async function post(path, body) {
  if (!token) return false;
  let r;
  try {
    r = await rawRequest('POST', path, body, token);
  } catch (err) {
    if (String(err.message || err).includes('timeout')) {
      logErr('timeout', path, 'request timed out');
    } else {
      logErr('network', path, err.message || String(err));
    }
    return false;
  }

  if (r.status >= 200 && r.status < 300) return true;

  if (r.status === 401) {
    // Token rejected. Re-read secrets.json — the seed restore may
    // have rotated the token under us. If we get a different token
    // back, retry the request once with it; on success, mark that
    // we need to re-announce state so ShowPilot's fresh restart
    // sees what's playing and which sequences exist.
    const fresh = loadToken();
    if (fresh && fresh !== token) {
      console.log('[fake-plugin] 401 on ' + path + ' — token rotated, refreshing');
      token = fresh;
      lastTokenAttempt = Date.now();
      try {
        r = await rawRequest('POST', path, body, token);
        if (r.status >= 200 && r.status < 300) {
          needsReannounce = true;
          return true;
        }
      } catch (_e) { /* fall through to log */ }
    }
    logErr('http', path, '401 unauthorized (token may be stale)');
    return false;
  }

  logErr('http', path, 'HTTP ' + r.status);
  return false;
}

// ============================================================
// Tick — run every 1 second
// ============================================================
async function tick() {
  // Refresh token periodically (in case secrets.json was rewritten by
  // a reset) — every 60s, and immediately if we have no token yet.
  const now = Date.now();
  if (!token || now - lastTokenAttempt > 60000) {
    const fresh = loadToken();
    if (fresh && fresh !== token) {
      token = fresh;
      console.log('[fake-plugin] loaded token (length=' + token.length + ')');
    }
    lastTokenAttempt = now;
  }
  if (!token) return;

  // If we just recovered from an auth failure (or first boot), bring
  // ShowPilot's state back in line: re-sync sequences and re-announce
  // the current track. We force-bypass the 5-min cooldown here because
  // ShowPilot was just restarted with a clean DB and needs everything.
  if (needsReannounce) {
    needsReannounce = false;
    lastSyncAt = 0;
    // After a reset, the audio cache was wiped along with the rest
    // of the data dir. Force a re-upload by clearing the success
    // flag and letting uploadAudioFiles() retry on its next tick.
    audioUploadsSucceeded = false;
    audioUploadsAttemptedAt = 0;
    await syncSequences();
    await uploadAudioFiles();
    const cur = TRACKS[trackIndex];
    const elapsedSec = (now - trackStartedAt) / 1000;
    await post('/api/plugin/playing', {
      sequence: cur.name,
      // Pass current elapsed so the now_playing position is right.
      seconds_played: Math.max(0, Math.floor(elapsedSec)),
    });
    const next = TRACKS[(trackIndex + 1) % TRACKS.length];
    await post('/api/plugin/next', { sequence: next.name });
    console.log('[fake-plugin] re-announced: ' + cur.displayName + ' @ ' + Math.floor(elapsedSec) + 's');
  }

  const cur = TRACKS[trackIndex];
  const elapsed = (now - trackStartedAt) / 1000;

  // Track has finished — advance.
  if (elapsed >= cur.durationSeconds) {
    trackIndex = (trackIndex + 1) % TRACKS.length;
    trackStartedAt = now;
    const next = TRACKS[trackIndex];
    console.log('[fake-plugin] now playing: ' + next.displayName);
    await post('/api/plugin/playing', { sequence: next.name, seconds_played: 0 });
    const upcoming = TRACKS[(trackIndex + 1) % TRACKS.length];
    await post('/api/plugin/next', { sequence: upcoming.name });
    return; // skip position this tick — we'll send next tick
  }

  // Within a track — send position update. ShowPilot uses this to
  // bump now_playing.last_updated, which gates the viewer's
  // "Show isn't playing" banner. Without this succeeding, the
  // viewer falls back to "show isn't running" within ~10 seconds.
  await post('/api/plugin/position', { sequence: cur.name, position: elapsed });
}

// ============================================================
// Slower cadence: heartbeat every 30s, sync-sequences every 5min
// ============================================================
async function heartbeat() {
  if (!token) return;
  await post('/api/plugin/heartbeat', { pluginVersion: VERSION });
}

async function syncSequences() {
  if (!token) return;
  const now = Date.now();
  if (now - lastSyncAt < 5 * 60 * 1000) return;
  lastSyncAt = now;
  const ok = await post('/api/plugin/sync-sequences', {
    playlistName: 'Demo Playlist',
    sequences: TRACKS.map((t, i) => ({
      name: t.name,
      displayName: t.displayName,
      artist: t.artist,
      imageUrl: t.imageUrl,
      mediaName: t.mediaName,
      durationSeconds: t.durationSeconds,
      playlistIndex: i + 1,
    })),
  });
  // If sync failed, reset lastSyncAt so we retry on the next tick
  // rather than waiting 5 min for the next scheduled attempt.
  if (!ok) lastSyncAt = 0;
}

// ============================================================
// Audio cache uploads
// ============================================================
// Each track in TRACKS has a corresponding silent MP3 in ./audio/
// (e.g. wizards_in_winter.mp3 for the Wizards in Winter track). We
// upload these into ShowPilot's audio cache via the same plugin
// endpoint the real ShowPilot FPP plugin uses. Once cached and
// stamped onto sequences.audio_hash, /api/audio-stream/<sequence>
// serves the silent file from disk — the viewer player loads it
// successfully (no "Load failed: audio load failed"), shows the
// cover/title/artist, and the play icon stays in playing state.
//
// The audio is silent so visitors can use the viewer page without
// a real show audio file, and the demo's track-cycling timing
// matches what the fake plugin's TRACKS array advertises.

let audioUploadsAttemptedAt = 0;
let audioUploadsSucceeded = false;

// Upload a Buffer of raw bytes to a query-string-parametered endpoint.
// Used only for /audio-cache/upload — JSON wouldn't fit. Mirrors
// post() in error handling: 401 → re-read token + retry once;
// 4xx/5xx → log; ok → return true.
async function uploadRaw(urlPath, bodyBuf, contentType) {
  if (!token) return false;
  function send(tok) {
    return new Promise((resolve, reject) => {
      const url = new URL(urlPath, SHOWPILOT_URL);
      const lib = url.protocol === 'https:' ? https : http;
      const req = lib.request(url, {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer ' + tok,
          'User-Agent': 'showpilot-fake-plugin/' + VERSION,
          'Content-Type': contentType,
          'Content-Length': bodyBuf.length,
        },
      }, (res) => {
        let chunks = '';
        res.on('data', c => { chunks += c; });
        res.on('end', () => resolve({ status: res.statusCode, body: chunks }));
      });
      req.on('error', reject);
      // Audio uploads are larger than JSON requests, so a more generous
      // timeout. 30s is plenty for ~600KB on localhost.
      req.setTimeout(30000, () => { req.destroy(new Error('timeout')); });
      req.write(bodyBuf);
      req.end();
    });
  }

  let r;
  try { r = await send(token); }
  catch (err) { logErr('network', urlPath, err.message || String(err)); return false; }

  if (r.status >= 200 && r.status < 300) return true;

  if (r.status === 401) {
    const fresh = loadToken();
    if (fresh && fresh !== token) {
      console.log('[fake-plugin] 401 on ' + urlPath + ' — token rotated, refreshing');
      token = fresh;
      lastTokenAttempt = Date.now();
      try {
        r = await send(token);
        if (r.status >= 200 && r.status < 300) {
          needsReannounce = true;
          return true;
        }
      } catch (_e) { /* fall through */ }
    }
    logErr('http', urlPath, '401 unauthorized (token may be stale)');
    return false;
  }

  logErr('http', urlPath, 'HTTP ' + r.status + ' — ' + r.body.slice(0, 200));
  return false;
}

// Upload all audio files for the configured TRACKS. Idempotent —
// checks the cache manifest first and only uploads files ShowPilot
// doesn't already have. Re-runnable: a reset clears the cache, and
// the next call here will re-upload.
async function uploadAudioFiles() {
  if (!token) return;
  // Re-check no more than once a minute to avoid hot-looping on
  // a partial failure (one upload succeeds, next 4xxs).
  const now = Date.now();
  if (audioUploadsSucceeded) return;
  if (now - audioUploadsAttemptedAt < 60000) return;
  audioUploadsAttemptedAt = now;

  // Load all the silent MP3s from disk + compute hashes.
  const files = [];
  for (const t of TRACKS) {
    const filePath = path.join(AUDIO_DIR, t.mediaName);
    let buf;
    try { buf = fs.readFileSync(filePath); }
    catch (err) {
      console.warn('[fake-plugin] missing audio file: ' + filePath);
      return; // Bail rather than partial — fix the bundle install.
    }
    const hash = crypto.createHash('sha256').update(buf).digest('hex');
    files.push({ track: t, buf, hash });
  }

  // Ask ShowPilot which hashes it already has, so we don't re-upload.
  // We use post() for a regular JSON GET-equivalent here? No — the
  // manifest endpoint is GET. Use a minimal direct request.
  let haveHashes = [];
  try {
    const r = await new Promise((resolve, reject) => {
      const url = new URL('/api/plugin/audio-cache/manifest', SHOWPILOT_URL);
      const lib = url.protocol === 'https:' ? https : http;
      const req = lib.request(url, {
        method: 'GET',
        headers: { 'Authorization': 'Bearer ' + token, 'User-Agent': 'showpilot-fake-plugin/' + VERSION },
      }, (res) => {
        let chunks = '';
        res.on('data', c => { chunks += c; });
        res.on('end', () => resolve({ status: res.statusCode, body: chunks }));
      });
      req.on('error', reject);
      req.setTimeout(8000, () => { req.destroy(new Error('timeout')); });
      req.end();
    });
    if (r.status >= 200 && r.status < 300) {
      const parsed = JSON.parse(r.body);
      haveHashes = Array.isArray(parsed.haveHashes) ? parsed.haveHashes : [];
    }
  } catch (err) {
    logErr('network', 'audio-cache/manifest', err.message || String(err));
    return; // Try again later; not fatal.
  }

  // Upload only what's missing. Each upload re-stamps audio_hash
  // onto matching sequences (server-side), so a single round of
  // uploads is enough — no need to re-call sync-sequences after.
  let allOk = true;
  for (const f of files) {
    if (haveHashes.includes(f.hash)) continue;
    const q = new URLSearchParams({
      hash: f.hash,
      mediaName: f.track.mediaName,
      mimeType: 'audio/mpeg',
    }).toString();
    const ok = await uploadRaw('/api/plugin/audio-cache/upload?' + q, f.buf, 'audio/mpeg');
    if (ok) {
      console.log('[fake-plugin] uploaded ' + f.track.mediaName + ' (' + f.buf.length + ' bytes)');
    } else {
      allOk = false;
    }
  }
  if (allOk) {
    audioUploadsSucceeded = true;
    console.log('[fake-plugin] all audio uploaded — viewer audio will load from cache');
  }
}

// ============================================================
// Initial play announcement on startup
// ============================================================
async function announceStart() {
  if (!token) return;
  const cur = TRACKS[trackIndex];
  const ok1 = await post('/api/plugin/playing', { sequence: cur.name, seconds_played: 0 });
  const next = TRACKS[(trackIndex + 1) % TRACKS.length];
  await post('/api/plugin/next', { sequence: next.name });
  if (ok1) console.log('[fake-plugin] announced start: ' + cur.displayName);
}

// ============================================================
// Main loop
// ============================================================
console.log('[fake-plugin] starting');
console.log('[fake-plugin] target: ' + SHOWPILOT_URL);
console.log('[fake-plugin] secrets: ' + SECRETS_PATH);
console.log('[fake-plugin] tracks: ' + TRACKS.length + ' × ~2.5min = ~10min cycle');

// Wait for token, then sync, then announce, then start ticking
(async function bootstrap() {
  // Loop until we get a token (showpilot may still be starting up)
  while (!token) {
    token = loadToken();
    if (!token) {
      await new Promise(r => setTimeout(r, 2000));
    }
  }
  console.log('[fake-plugin] token acquired');
  await syncSequences();
  await heartbeat();
  await uploadAudioFiles();
  await announceStart();
})();

setInterval(tick, 1000);
setInterval(heartbeat, 30000);
setInterval(syncSequences, 60000); // checks once a minute, only sends every 5
// Also retry audio uploads periodically — handles the reset case
// where ShowPilot's cache was wiped to seed state. If everything
// is already uploaded, this is a one-line manifest GET (cheap).
setInterval(() => { uploadAudioFiles().catch(() => {}); }, 60000);

// Graceful shutdown
process.on('SIGTERM', () => { console.log('[fake-plugin] SIGTERM'); process.exit(0); });
process.on('SIGINT',  () => { console.log('[fake-plugin] SIGINT');  process.exit(0); });
