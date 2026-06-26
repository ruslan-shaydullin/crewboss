#!/usr/bin/env node
/**
 * layout-overlap.mjs — Layout regression for issue #698 / charter #717 (#730).
 *
 * With 35 queue items the `.queue-panel--sticky` must NOT geometrically
 * overlap the `.rail` (agents rail).
 *
 * Why the test works:
 *   Pre-fix CSS (`.queue-panel--sticky { flex-shrink:0 }` only, missing
 *   `overflow-y:auto` / `min-height:0`) causes the browser to use the
 *   queue panel's max-content height as its flex-basis, crushing the
 *   `.sidebar { flex:1 }` container to zero height.  The `.rail` inside
 *   the zero-height container still occupies its natural bounding rect
 *   (getBoundingClientRect ignores overflow clipping), so the rail rect
 *   and the queue-panel rect intersect → exit 1.
 *
 *   Fixed CSS (`overflow-y:auto; min-height:0` added) switches the
 *   flex-basis computation to min-content, the sidebar retains space,
 *   and the two rects are non-overlapping → exit 0.
 *
 * Port 9883 (vite preview) does not conflict with smoke.mjs (5181/9881)
 * or visual-regression.mjs / repro-jitter.mjs (5182/9882).
 *
 * Usage:
 *   node ui/app/scripts/layout-overlap.mjs
 *
 * Requirements: playwright in devDependencies + chromium installed.
 */

import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const STUB_PORT = 9884;
const APP_PORT  = 9883;

// ---------------------------------------------------------------------------
// Build stub state with 35 queue items — more than enough to overflow
// ---------------------------------------------------------------------------
const QUEUE_SIZE = 35;
const queueItems = Array.from({ length: QUEUE_SIZE }, (_, i) => i + 2);

const STUB_STATE = {
  board: [
    {
      n: 1, kind: 'charter', state: 'approved', title: 'Overlap Test Charter',
      labels: [], charter: null, cost: null, pr: null, phase: null,
    },
    ...queueItems.map((n) => ({
      n, kind: 'leaf', state: 'open', title: `Task ${n}`,
      labels: [], charter: 1, cost: null, pr: null, phase: null,
    })),
  ],
  queue:  { order: queueItems },
  agents: [
    {
      task: 2, role: 'executor', phase: 'coding', title: 'Task 2',
      started: new Date(Date.now() - 30000).toISOString(),
    },
  ],
  budget:   { spent: 0, cap: 5, runs: [] },
  flags:    { paused: false, killed: false },
  autonomy: { repo: 'test/overlap-repo' },
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
        res.writeHead(200, {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
        });
        res.write(`event: state\ndata: ${JSON.stringify(STUB_STATE)}\n\n`);
        req.on('close', () => {});
      } else if (url.startsWith('/api/task/')) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          n: 2, status: { phase: 'coding', cost_usd: 0 }, alive: true,
          started: new Date(Date.now() - 30000).toISOString(),
          prompt: 'stub', log: '', body: '',
        }));
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
        if (Date.now() - start > timeoutMs) {
          reject(new Error(`Port ${port} not ready after ${timeoutMs}ms`));
          return;
        }
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
  console.log('=== layout-overlap.mjs ===');
  console.log(`[layout] injecting ${QUEUE_SIZE} queue items into the DOM`);

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

  const appDir     = path.resolve(__dirname, '..');
  const distIndex  = path.join(appDir, 'dist', 'index.html');
  const hasDistIdx = fs.existsSync(distIndex);
  const viteMode   = hasDistIdx ? 'preview' : 'dev';

  console.log(`[app] starting vite ${viteMode} on port ${APP_PORT}…`);
  const viteArgs = [viteMode, '--port', String(APP_PORT), '--host', '127.0.0.1'];
  const viteProc = spawn('node_modules/.bin/vite', viteArgs, {
    cwd: appDir, stdio: ['ignore', 'pipe', 'pipe'],
  });
  viteProc.stdout.on('data', (d) => process.stdout.write('[vite] ' + d));
  viteProc.stderr.on('data', (d) => process.stderr.write('[vite] ' + d));

  try {
    await waitForPort(APP_PORT, 25000);
    console.log('[app] server ready');

    const browser = await chromium.launch({ headless: true });
    const ctx     = await browser.newContext({
      viewport: { width: 1280, height: 800 },
    });

    // Route the app to our stub API via localStorage before first request
    await ctx.addInitScript((stubUrl) => {
      localStorage.setItem('cb_api',   stubUrl);
      localStorage.setItem('cb_token', 'overlap-token');
    }, `http://127.0.0.1:${STUB_PORT}`);

    const page = await ctx.newPage();
    await page.goto(`http://127.0.0.1:${APP_PORT}`);

    // Wait for the sidebar elements to appear
    await page.waitForSelector('.queue-panel--sticky', { timeout: 12000 });
    await page.waitForSelector('.rail',                { timeout: 12000 });
    // Wait for at least one queue item — confirms the stub state arrived
    await page.waitForSelector('.queue-panel__item',   { timeout: 12000 });

    // Let React finish rendering all 35 items
    await page.waitForTimeout(600);

    // Confirm 30+ queue items rendered
    const itemCount = await page.locator('.queue-panel__item').count();
    console.log(`[layout] queue items rendered in DOM: ${itemCount}`);
    if (itemCount < 30) {
      throw new Error(
        `Expected ≥30 queue items rendered, got ${itemCount} — ` +
        `check that stub state queue.order is wired correctly`
      );
    }

    // Measure layout — getBoundingClientRect ignores overflow:hidden clipping
    // so elements that are visually hidden by a squashed ancestor still report
    // their natural rect, which is what we need for the overlap check.
    const { queueRect, railRect } = await page.evaluate(() => {
      const queueEl = document.querySelector('.queue-panel--sticky');
      const railEl  = document.querySelector('.rail');
      if (!queueEl) throw new Error('Missing .queue-panel--sticky element');
      if (!railEl)  throw new Error('Missing .rail element');
      return {
        queueRect: queueEl.getBoundingClientRect().toJSON(),
        railRect:  railEl.getBoundingClientRect().toJSON(),
      };
    });

    console.log(
      `[layout] .queue-panel--sticky  ` +
      `top=${queueRect.top.toFixed(1)} bottom=${queueRect.bottom.toFixed(1)} ` +
      `h=${queueRect.height.toFixed(1)}`
    );
    console.log(
      `[layout] .rail                 ` +
      `top=${railRect.top.toFixed(1)} bottom=${railRect.bottom.toFixed(1)} ` +
      `h=${railRect.height.toFixed(1)}`
    );

    // Geometric intersection: two rects overlap iff they overlap on BOTH axes
    const overlapX = queueRect.left < railRect.right  && railRect.left  < queueRect.right;
    const overlapY = queueRect.top  < railRect.bottom && railRect.top   < queueRect.bottom;

    if (overlapX && overlapY) {
      throw new Error(
        `FAIL: .queue-panel--sticky and .rail overlap with ${itemCount} queue items.\n` +
        `  queue rect: top=${queueRect.top.toFixed(1)} bottom=${queueRect.bottom.toFixed(1)}\n` +
        `  rail  rect: top=${railRect.top.toFixed(1)} bottom=${railRect.bottom.toFixed(1)}\n` +
        `  Fix: ensure .queue-panel--sticky has overflow-y:auto and min-height:0`
      );
    }

    console.log(`✅  .queue-panel--sticky and .rail do NOT overlap (${itemCount} queue items)`);

    await browser.close();
    console.log('');
    console.log('=== LAYOUT OVERLAP CHECK PASSED ===');

  } finally {
    viteProc.kill();
    stubServer.close();
  }
}

main().catch((err) => {
  console.error('\n❌  LAYOUT OVERLAP CHECK FAILED:', err.message);
  process.exit(1);
});
