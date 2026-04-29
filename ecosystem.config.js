// ============================================================
// ShowPilot Demo — PM2 Ecosystem
// ============================================================
// Registers the two long-running processes for the demo LXC:
//   1. showpilot-demo            — the ShowPilot server itself
//   2. showpilot-demo-fakeplugin — the fake plugin that drives it
//
// Used by setup.sh once during initial bootstrap:
//   pm2 start /opt/showpilot-demo/ecosystem.config.js
//   pm2 save
//
// After that, reset.sh and build-seed.sh refer to processes by
// name (`pm2 stop showpilot-demo`) — pm2 remembers them across
// reboots because of `pm2 save` + `pm2 startup`.
// ============================================================

module.exports = {
  apps: [
    {
      name: 'showpilot-demo',
      cwd: '/opt/showpilot-demo',
      script: 'server.js',
      // Keep the demo process modest. ShowPilot's normal memory
      // footprint is well under 200MB; if it spikes past 400MB
      // something is wrong (a leaky route, a stuck SQLite txn, etc.)
      // and a restart is the right call.
      max_memory_restart: '400M',
      // No log timestamps — pm2 already prefixes them
      autorestart: true,
      // Brief wait to avoid restart storms if it keeps crashing
      restart_delay: 2000,
      env: {
        NODE_ENV: 'production',
      },
    },
    {
      name: 'showpilot-demo-fakeplugin',
      cwd: '/opt/showpilot-demo-fakeplugin',
      script: 'fake-plugin.js',
      max_memory_restart: '120M',
      autorestart: true,
      restart_delay: 2000,
      env: {
        SHOWPILOT_URL: 'http://127.0.0.1:3100',
        // Point at the live ShowPilot's secrets file. The fake plugin's
        // default __dirname-relative path resolves to /opt/showpilot/...
        // which doesn't exist on this LXC (we use /opt/showpilot-demo/).
        // Setting this env var explicitly avoids any guesswork.
        SHOWPILOT_SECRETS_PATH: '/opt/showpilot-demo/data/secrets.json',
      },
    },
  ],
};
