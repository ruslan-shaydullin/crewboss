#!/usr/bin/env node
/**
 * smoke.mjs — Behavioral smoke test (class-c headless browser, issue #64).
 *
 * Checks performed:
 *   1. Page loads and main nav is present.
 *   2. Switching ALL three tabs (Board / Team / Задачи на человека) renders
 *      the expected section without throwing.
 *   3. Zero console errors and zero pageerror events during the entire run.
 *
 * Usage:
 *   node ui/app/scripts/smoke.mjs
 *
 * Requirements: playwright must be installed (devDependencies) and chromium
 *   downloaded (`npx playwright install chromium`).
 */

import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const STUB_PORT = 9881;
const APP_PORT  = 5181;

// ---------------------------------------------------------------------------
// Stub API state — covers all three tabs
// ---------------------------------------------------------------------------
const STUB_STATE = {
  board: [
    { n: 1, kind: 'charter', state: 'approved', title: 'Alpha Charter', labels: [], charter: null, cost: null, pr: null, phase: null },
    { n: 2, kind: 'leaf', state: 'open',        title: 'Write tests',         labels: [],                       charter: 1, cost: null, pr: null, phase: null },
    { n: 3, kind: 'leaf', state: 'in-progress', title: 'Implement feature',   labels: [],                       charter: 1, cost: 0.012, pr: null, phase: 'coding' },
    { n: 4, kind: 'leaf', state: 'open',        title: 'Choose provider',     labels: ['type:human-decision'],  charter: 1, cost: null, pr: null, phase: null },
    { n: 5, kind: 'leaf', state: 'done',        title: 'Old closed decision', labels: ['type:human-decision'],  charter: 1, cost: null, pr: null, phase: null },
  ],
  agents: [
    { task: 3, role: 'executor', phase: 'coding', title: 'Implement feature', started: new Date(Date.now() - 45000).toISOString() },
  ],
  budget: { spent: 0.012, cap: 5, runs: [] },
  flags:  { paused: false, killed: false },
  autonomy: { repo: 'test/smoke-repo' },
};

// ---------------------------------------------------------------------------
// Stub server
// ---------------------------------------------------------------------------
function startStubServer() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      res.setHeader('Access-Control-Allow-Origin', '*');
      res.setHeader('Access-Control-Allow-Headers', '*');
      if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

      const url = req.url?.split('?')[0] ?? '';

      if (url === '/api/state') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(STUB_STATE));
      } else if (url === '/api/events') {
        res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
        res.write(`event: state\ndata: ${JSON.stringify(STUB_STATE)}\n\n`);
        // Keep the connection open so EventSource doesn't error-reconnect
        req.on('close', () => {});
      } else if (url.startsWith('/api/task/')) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ n: 3, status: { phase: 'coding', cost_usd: 0.012 }, alive: true, started: new Date(Date.now() - 45000).toISOString(), prompt: 'stub prompt', log: '', body: '' }));
      } else if (url === '/api/team') {
        // Return present:false so fetchTeam() falls back to its bundled
        // FALLBACK_TEAM — no 404 console.error from the browser.
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ present: false, nodes: [], roles: [], departments: [], policy: {} }));
      } else {
        res.writeHead(404); res.end('{}');
      }
    });
    server.listen(STUB_PORT, '127.0.0.1', () => {
      console.log(`[stub] API on http://127.0.0.1:${STUB_PORT}`);
      resolve(server);
    });
  });
}

// ---------------------------------------------------------------------------
// Utility: wait for TCP port to accept connections
// ---------------------------------------------------------------------------
function waitForPort(port, timeoutMs = 20000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tryConnect = () => {
      const req = http.get({ host: '127.0.0.1', port, path: '/', timeout: 500 }, () => {
        req.destroy(); resolve();
      });
      req.on('error', () => {
        if (Date.now() - start > timeoutMs) { reject(new Error(`Port ${port} not ready after ${timeoutMs}ms`)); return; }
        setTimeout(tryConnect, 300);
      });
    };
    tryConnect();
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  console.log('=== smoke.mjs ===');

  // Dynamic import so we get a clear error if playwright is missing
  let chromium;
  try {
    ({ chromium } = await import('playwright'));
  } catch {
    try {
      ({ chromium } = await import('@playwright/test'));
    } catch (err) {
      console.error('❌  Playwright not found. Run: npm ci && npx playwright install chromium');
      process.exit(1);
    }
  }

  const stubServer = await startStubServer();

  const appDir   = path.resolve(__dirname, '..');
  const distIndex = path.join(appDir, 'dist', 'index.html');
  const hasDistIndex = fs.existsSync(distIndex);
  const viteMode = hasDistIndex ? 'preview' : 'dev';

  console.log(`[app] starting vite ${viteMode} on port ${APP_PORT}…`);
  const viteArgs = [viteMode, '--port', String(APP_PORT), '--host', '127.0.0.1'];
  const viteProc = spawn('node_modules/.bin/vite', viteArgs, {
    cwd: appDir, stdio: ['ignore', 'pipe', 'pipe'],
  });
  viteProc.stdout.on('data', (d) => process.stdout.write('[vite] ' + d));
  viteProc.stderr.on('data', (d) => process.stderr.write('[vite] ' + d));

  const errors   = [];
  const pageErrs = [];

  try {
    await waitForPort(APP_PORT, 25000);
    console.log('[app] server ready');

    const browser = await chromium.launch({ headless: true });
    const ctx     = await browser.newContext();

    // Route the app to our stub API via localStorage
    await ctx.addInitScript((stubUrl) => {
      localStorage.setItem('cb_api',   stubUrl);
      localStorage.setItem('cb_token', 'smoke-token');
    }, `http://127.0.0.1:${STUB_PORT}`);

    const page = await ctx.newPage();

    // Capture console errors
    page.on('console', (msg) => {
      if (msg.type() === 'error') {
        errors.push(msg.text());
        console.error(`[console.error] ${msg.text()}`);
      }
    });
    // Capture uncaught JS exceptions
    page.on('pageerror', (err) => {
      pageErrs.push(err.message);
      console.error(`[pageerror] ${err.message}`);
    });

    await page.goto(`http://127.0.0.1:${APP_PORT}`);

    // ── Check 1: page loads, nav is present ────────────────────────────────
    await page.waitForSelector('[data-testid="main-nav"]', { timeout: 12000 });
    console.log('✅  Page loaded — main-nav present');

    // ── Check 2: Board tab (default) ───────────────────────────────────────
    // Board is the default view; wait for at least one .charter element
    await page.waitForSelector('.charter', { timeout: 8000 });
    console.log('✅  Board tab — .charter element visible');

    // ── Check 3: Team tab ──────────────────────────────────────────────────
    const teamBtn = page.locator('nav button', { hasText: 'Team' }).first();
    await teamBtn.click();
    // TeamPage renders <section class="team"> once loaded (fallback is synchronous)
    await page.waitForSelector('.team, .empty', { timeout: 8000 });
    console.log('✅  Team tab — team/empty section visible');

    // ── Check 4: Human-decisions tab ───────────────────────────────────────
    const humanBtn = page.locator('[data-testid="tab-human"]');
    await humanBtn.click();
    await page.waitForSelector('[data-testid="human-page"]', { timeout: 8000 });
    console.log('✅  Human tab — human-page section visible');

    // ── Check 5: Return to Board tab ───────────────────────────────────────
    const boardBtn = page.locator('nav button', { hasText: 'Board' }).first();
    await boardBtn.click();
    await page.waitForSelector('.charter', { timeout: 8000 });
    console.log('✅  Board tab — back on board after round-trip');

    // ── Check 6: Zero console errors & pageerrors ──────────────────────────
    // Give any in-flight async errors a moment to surface
    await page.waitForTimeout(500);

    if (errors.length > 0) {
      throw new Error(`FAIL: ${errors.length} console error(s) detected:\n  ${errors.join('\n  ')}`);
    }
    if (pageErrs.length > 0) {
      throw new Error(`FAIL: ${pageErrs.length} pageerror(s) detected:\n  ${pageErrs.join('\n  ')}`);
    }
    console.log('✅  Zero console errors and zero pageerrors');

    await browser.close();
    console.log('');
    console.log('=== ALL SMOKE CHECKS PASSED ===');
  } finally {
    viteProc.kill();
    stubServer.close();
  }
}

main().catch((err) => {
  console.error('\n❌  SMOKE FAILED:', err.message);
  process.exit(1);
});
