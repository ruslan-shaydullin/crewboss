#!/usr/bin/env node
/**
 * Headless behavioral check for the "Задачи на человека" tab (issue #34).
 *
 * What it does:
 *   1. Spawns a lightweight stub API server on port 9876 that returns /api/state
 *      with 3 tasks:  one type:human-decision with a charter, one without, one closed.
 *   2. Starts the Vite dev-server (or preview) on port 5175 pointing to the stub API.
 *   3. Uses Playwright (if available) to open the page, click the "Задачи на человека"
 *      tab, and assert:
 *        - The tab button is visible
 *        - Exactly 2 charter groups are rendered
 *        - The closed task is NOT in the DOM
 *
 * Usage:
 *   node ui/app/scripts/check-human-tab.js
 *
 * Requirements (optional – falls back to protocol print if not found):
 *   npm install --no-save @playwright/test playwright
 *   npx playwright install chromium
 */

'use strict';

const http = require('http');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const STUB_PORT = 9876;
const APP_PORT  = 5175;

// ---------------------------------------------------------------------------
// Stub state with 3 human-decision tasks
// ---------------------------------------------------------------------------
const STUB_STATE = {
  board: [
    // Charter task
    { n: 10, kind: 'charter', state: 'approved', title: 'Test Charter Alpha', labels: [], charter: null, cost: null, pr: null, phase: null },
    // Task 1: open, has charter → should appear
    { n: 11, kind: 'leaf', state: 'open', title: 'Decide on API design', labels: ['type:human-decision'], charter: 10, cost: null, pr: null, phase: null },
    // Task 2: open, no charter → should appear in "Без чартера"
    { n: 12, kind: 'leaf', state: 'open', title: 'Choose infra provider', labels: ['type:human-decision'], charter: null, cost: null, pr: null, phase: null },
    // Task 3: closed (done) → must NOT appear
    { n: 13, kind: 'leaf', state: 'done', title: 'Already decided', labels: ['type:human-decision'], charter: 10, cost: null, pr: null, phase: null },
  ],
  agents: [],
  budget: { spent: 0, cap: 100, runs: [] },
  flags: { paused: false, killed: false },
  autonomy: { repo: 'test/repo' },
};

// ---------------------------------------------------------------------------
// Utility: wait for a port to be open
// ---------------------------------------------------------------------------
function waitForPort(port, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tryConnect = () => {
      const req = http.get({ host: '127.0.0.1', port, path: '/', timeout: 500 }, () => { resolve(); req.destroy(); });
      req.on('error', () => {
        if (Date.now() - start > timeoutMs) { reject(new Error(`Port ${port} not ready after ${timeoutMs}ms`)); return; }
        setTimeout(tryConnect, 300);
      });
    };
    tryConnect();
  });
}

// ---------------------------------------------------------------------------
// Start stub API server
// ---------------------------------------------------------------------------
function startStubServer() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      res.setHeader('Access-Control-Allow-Origin', '*');
      res.setHeader('Access-Control-Allow-Headers', '*');
      if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
      if (req.url === '/api/state') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(STUB_STATE));
      } else if (req.url && req.url.startsWith('/api/events')) {
        // Simple SSE endpoint
        res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
        res.write(`event: state\ndata: ${JSON.stringify(STUB_STATE)}\n\n`);
      } else {
        res.writeHead(404); res.end('{}');
      }
    });
    server.listen(STUB_PORT, '127.0.0.1', () => {
      console.log(`[stub] API listening on http://127.0.0.1:${STUB_PORT}`);
      resolve(server);
    });
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  console.log('=== check-human-tab.js ===');

  // Check for playwright
  let playwright;
  try {
    playwright = require('playwright');
  } catch (_) {
    try { playwright = require('@playwright/test'); } catch (__) { playwright = null; }
  }

  if (!playwright) {
    console.log('');
    console.log('⚠  Playwright not found in node_modules.');
    console.log('');
    printManualProtocol();
    process.exit(0);
  }

  // Start stub API
  const stubServer = await startStubServer();

  // Start Vite dev server with stub API URL injected via localStorage overrides
  // We'll use `vite preview` on the dist if available, or `vite dev` otherwise.
  // For simplicity we inject the API URL via a query param + window.localStorage set via page.addInitScript.
  const appDir = path.resolve(__dirname, '..');
  const distDir = path.join(appDir, 'dist');
  const hasDistIndex = fs.existsSync(path.join(distDir, 'index.html'));

  console.log(`[app] starting ${hasDistIndex ? 'preview' : 'dev'} server on port ${APP_PORT}…`);
  const viteCmd = hasDistIndex ? 'preview' : 'dev';
  const viteArgs = [viteCmd, '--port', String(APP_PORT), '--host', '127.0.0.1'];
  const viteProc = spawn('node_modules/.bin/vite', viteArgs, {
    cwd: appDir, stdio: ['ignore', 'pipe', 'pipe'],
  });
  viteProc.stdout.on('data', (d) => process.stdout.write('[vite] ' + d));
  viteProc.stderr.on('data', (d) => process.stderr.write('[vite] ' + d));

  try {
    await waitForPort(APP_PORT, 20000);
    console.log('[app] server ready');

    const { chromium } = playwright;
    const browser = await chromium.launch({ headless: true });
    const ctx = await browser.newContext();

    // Inject localStorage so the app talks to our stub API
    await ctx.addInitScript((stubUrl) => {
      localStorage.setItem('cb_api', stubUrl);
      localStorage.setItem('cb_token', 'test-token');
    }, `http://127.0.0.1:${STUB_PORT}`);

    const page = await ctx.newPage();
    await page.goto(`http://127.0.0.1:${APP_PORT}`);

    // Wait for the nav to appear
    await page.waitForSelector('[data-testid="main-nav"]', { timeout: 8000 });

    // --- Check 1: Tab exists ---
    const tabBtn = await page.$('[data-testid="tab-human"]');
    if (!tabBtn) throw new Error('FAIL: "Задачи на человека" tab button not found');
    console.log('✅  Tab button "Задачи на человека" exists');

    // --- Click the tab ---
    await tabBtn.click();
    await page.waitForSelector('[data-testid="human-page"]', { timeout: 5000 });
    console.log('✅  Clicking tab renders human-page section');

    // Wait for data to load (SSE/poll)
    await page.waitForFunction(
      () => document.querySelectorAll('[data-testid="human-charter-group"]').length >= 1,
      { timeout: 10000 }
    );

    // --- Check 2: Exactly 2 groups ---
    const groups = await page.$$('[data-testid="human-charter-group"]');
    if (groups.length !== 2) throw new Error(`FAIL: expected 2 charter groups, got ${groups.length}`);
    console.log(`✅  2 charter groups rendered (one with charter, one "Без чартера")`);

    // --- Check 3: Closed task not shown ---
    const cards = await page.$$('[data-testid="human-task-card"]');
    const cardTaskIds = await Promise.all(cards.map((c) => c.getAttribute('data-task-n')));
    if (cardTaskIds.includes('13')) throw new Error('FAIL: closed task #13 is visible but should not be');
    console.log(`✅  Closed task #13 is NOT rendered`);

    // --- Check 4: Open tasks are shown ---
    if (!cardTaskIds.includes('11')) throw new Error('FAIL: task #11 (open, with charter) should be visible');
    if (!cardTaskIds.includes('12')) throw new Error('FAIL: task #12 (open, no charter) should be visible');
    console.log(`✅  Tasks #11 (with charter) and #12 (no charter) are rendered`);

    await browser.close();
    console.log('');
    console.log('=== ALL CHECKS PASSED ===');
  } finally {
    viteProc.kill();
    stubServer.close();
  }
}

function printManualProtocol() {
  console.log('======================================================');
  console.log('MANUAL TEST PROTOCOL — issue #34 "Задачи на человека"');
  console.log('======================================================');
  console.log('');
  console.log('Prerequisites: the app is running with a backend that has');
  console.log('issues labeled "type:human-decision" (open and/or closed).');
  console.log('');
  console.log('Steps & expected results:');
  console.log('');
  console.log('1. Open the dashboard in a browser.');
  console.log('   EXPECTED: Header nav has 3 buttons: Board | Team | Задачи на человека');
  console.log('   data-testid="tab-human" is present on the third button.');
  console.log('');
  console.log('2. Click "Задачи на человека".');
  console.log('   EXPECTED: data-testid="human-page" section appears.');
  console.log('   Board and AgentsRail are hidden. Hero stats remain visible.');
  console.log('');
  console.log('3. If no open human-decision issues exist:');
  console.log('   EXPECTED: data-testid="human-empty" shows the empty-state text,');
  console.log('   not a blank screen.');
  console.log('');
  console.log('4. If open human-decision issues exist:');
  console.log('   EXPECTED: One data-testid="human-charter-group" per distinct charter');
  console.log('   (issues with charter=#N → group headed "#N <charter title>").');
  console.log('   Issues with charter=null or unknown charter → group headed "Без чартера".');
  console.log('');
  console.log('5. Closed (state="done") issues must NOT appear regardless of labels.');
  console.log('');
  console.log('6. Click a task card.');
  console.log('   EXPECTED: TaskDrawer opens for that issue (same drawer used on Board tab).');
  console.log('');
  console.log('7. Click "Board" nav button.');
  console.log('   EXPECTED: Board view restores, human-page is hidden. Board is unaffected.');
  console.log('');
  console.log('8. TypeScript + build:');
  console.log('   cd ui/app && node_modules/.bin/tsc --noEmit   → 0 errors');
  console.log('   cd ui/app && npm run build                    → succeeds');
  console.log('======================================================');
}

main().catch((err) => {
  console.error('\n❌  CHECK FAILED:', err.message);
  process.exit(1);
});
