#!/usr/bin/env node
/**
 * visual-regression.mjs — Visual regression test for crewboss UI panels (issue #575).
 *
 * Captures screenshots of the three UI panels (Board / Team / Human) and compares
 * them against committed baseline images using pixelmatch.
 *
 * Usage:
 *   node ui/app/scripts/visual-regression.mjs              # compare mode (CI)
 *   node ui/app/scripts/visual-regression.mjs --update-baselines  # generate/update baselines
 *
 * Requirements:
 *   - playwright (devDependency, chromium downloaded via `npx playwright install chromium`)
 *   - pixelmatch, pngjs (devDependencies)
 *
 * Exit 0 = all panels within threshold; exit 1 = any panel exceeded threshold.
 */

import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const STUB_PORT  = 9882;  // different from smoke.mjs (9881) to allow parallel runs
const APP_PORT   = 5182;
const DIFF_THRESHOLD = 100;  // max allowed differing pixels per panel

const PANELS = [
  {
    name: 'board',
    nav:  null,           // default tab; no click needed
    wait: '.charter',
  },
  {
    name: 'team',
    nav:  'button:has-text("Team")',
    wait: '.team, .empty',
  },
  {
    name: 'human',
    nav:  '[data-testid="tab-human"]',
    wait: '[data-testid="human-page"]',
  },
];

// ---------------------------------------------------------------------------
// Stub API state — mirrors smoke.mjs STUB_STATE
// ---------------------------------------------------------------------------
const STUB_STATE = {
  board: [
    { n: 1, kind: 'charter', state: 'approved', title: 'Alpha Charter', labels: [], charter: null, cost: null, pr: null, phase: null },
    { n: 2, kind: 'leaf',    state: 'open',        title: 'Write tests',       labels: [],                       charter: 1, cost: null, pr: null, phase: null },
    { n: 3, kind: 'leaf',    state: 'in-progress', title: 'Implement feature', labels: [],                       charter: 1, cost: 0.012, pr: null, phase: 'coding' },
    { n: 4, kind: 'leaf',    state: 'open',        title: 'Choose provider',   labels: ['type:human-decision'],  charter: 1, cost: null, pr: null, phase: null },
  ],
  agents: [
    { task: 3, role: 'executor', phase: 'coding', title: 'Implement feature', started: new Date(Date.now() - 45000).toISOString() },
  ],
  budget:   { spent: 0.012, cap: 5, runs: [] },
  flags:    { paused: false, killed: false },
  autonomy: { repo: 'test/visual-repo' },
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
        req.on('close', () => {});
      } else if (url.startsWith('/api/task/')) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ n: 3, status: { phase: 'coding', cost_usd: 0.012 }, alive: true, started: new Date(Date.now() - 45000).toISOString(), prompt: 'stub', log: '', body: '' }));
      } else if (url === '/api/team') {
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
// PNG comparison via pixelmatch + pngjs
// ---------------------------------------------------------------------------
async function comparePNG(actualBuf, baselinePath) {
  const { PNG } = await import('pngjs');
  const pixelmatch = (await import('pixelmatch')).default;

  const actual = PNG.sync.read(actualBuf);

  if (!fs.existsSync(baselinePath)) {
    throw new Error(`Baseline not found: ${baselinePath}`);
  }
  const expected = PNG.sync.read(fs.readFileSync(baselinePath));

  if (actual.width !== expected.width || actual.height !== expected.height) {
    throw new Error(
      `Dimension mismatch for ${path.basename(baselinePath)}: ` +
      `actual ${actual.width}x${actual.height} vs baseline ${expected.width}x${expected.height}. ` +
      `Re-run with --update-baselines to regenerate.`
    );
  }

  const diff = pixelmatch(
    actual.data, expected.data, null,
    actual.width, actual.height,
    { threshold: 0.1 }
  );

  return diff;
}

// ---------------------------------------------------------------------------
// Write a screenshot buffer as the new baseline PNG
// ---------------------------------------------------------------------------
function writeBaseline(buf, baselinePath) {
  fs.mkdirSync(path.dirname(baselinePath), { recursive: true });
  fs.writeFileSync(baselinePath, buf);
  console.log(`  [baseline] wrote ${path.relative(process.cwd(), baselinePath)}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const updateBaselines = process.argv.includes('--update-baselines');
  console.log(`=== visual-regression.mjs (mode: ${updateBaselines ? 'UPDATE BASELINES' : 'compare'}) ===`);

  // Dynamic import so we get a clear error if playwright is missing
  let chromium;
  try {
    ({ chromium } = await import('playwright'));
  } catch {
    try {
      ({ chromium } = await import('@playwright/test'));
    } catch {
      console.error('❌  Playwright not found. Run: npm ci && npx playwright install chromium');
      process.exit(1);
    }
  }

  const stubServer = await startStubServer();

  const appDir    = path.resolve(__dirname, '..');
  const distIndex = path.join(appDir, 'dist', 'index.html');
  const hasDistIndex = fs.existsSync(distIndex);
  const viteMode  = hasDistIndex ? 'preview' : 'dev';

  console.log(`[app] starting vite ${viteMode} on port ${APP_PORT}…`);
  const viteArgs = [viteMode, '--port', String(APP_PORT), '--host', '127.0.0.1'];
  const viteProc = spawn('node_modules/.bin/vite', viteArgs, {
    cwd: appDir, stdio: ['ignore', 'pipe', 'pipe'],
  });
  viteProc.stdout.on('data', (d) => process.stdout.write('[vite] ' + d));
  viteProc.stderr.on('data', (d) => process.stderr.write('[vite] ' + d));

  const failures = [];
  let browser;

  try {
    await waitForPort(APP_PORT, 25000);
    console.log('[app] server ready');

    browser = await chromium.launch({ headless: true });
    const ctx = await browser.newContext({
      viewport: { width: 1280, height: 800 },
    });

    // Route the app to our stub API via localStorage
    await ctx.addInitScript((stubUrl) => {
      localStorage.setItem('cb_api',   stubUrl);
      localStorage.setItem('cb_token', 'visual-token');
    }, `http://127.0.0.1:${STUB_PORT}`);

    const page = await ctx.newPage();

    await page.goto(`http://127.0.0.1:${APP_PORT}`);
    await page.waitForSelector('[data-testid="main-nav"]', { timeout: 12000 });
    console.log('[ok] page loaded');

    const baselines = path.resolve(__dirname, 'baselines');

    for (const panel of PANELS) {
      console.log(`\n--- panel: ${panel.name} ---`);

      // Navigate to the panel
      if (panel.nav) {
        await page.locator(panel.nav).first().click();
      }

      // Wait for panel content to be visible
      await page.waitForSelector(panel.wait, { timeout: 8000 });

      // Allow animations to settle
      await page.waitForTimeout(300);

      // Capture screenshot
      const buf = await page.screenshot({ fullPage: false });
      console.log(`  [screenshot] captured ${buf.length} bytes`);

      const baselinePath = path.join(baselines, `${panel.name}.png`);

      if (updateBaselines) {
        writeBaseline(buf, baselinePath);
      } else {
        try {
          const diff = await comparePNG(buf, baselinePath);
          if (diff > DIFF_THRESHOLD) {
            console.error(`  FAIL: ${panel.name} diff=${diff}px (threshold=${DIFF_THRESHOLD})`);
            failures.push({ name: panel.name, diff });
          } else {
            console.log(`  ✅  ${panel.name} diff=${diff}px — within threshold`);
          }
        } catch (err) {
          console.error(`  FAIL: ${panel.name} comparison error: ${err.message}`);
          failures.push({ name: panel.name, diff: -1, error: err.message });
        }
      }
    }

    await browser.close();
    browser = undefined;

  } finally {
    if (browser) {
      try { await browser.close(); } catch (_) {}
    }
    viteProc.kill();
    stubServer.close();
  }

  console.log('');
  if (updateBaselines) {
    console.log('=== BASELINES UPDATED ===');
    process.exit(0);
  }

  if (failures.length === 0) {
    console.log('=== ALL VISUAL REGRESSION CHECKS PASSED ===');
    process.exit(0);
  } else {
    for (const f of failures) {
      if (f.error) {
        console.error(`FAIL: ${f.name} error=${f.error}`);
      } else {
        console.error(`FAIL: ${f.name} diff=${f.diff}px`);
      }
    }
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('\n❌  VISUAL REGRESSION FAILED:', err.message);
  process.exit(1);
});
