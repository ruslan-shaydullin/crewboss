#!/usr/bin/env node
/**
 * repro-jitter.mjs — Regression lock for the FLIP jitter bug (issue #31 / #64).
 *
 * The original bug:
 *   useFlip stored positions via getBoundingClientRect(), which is transform-
 *   inclusive.  The 1-second setTick re-render, combined with the in-flight
 *   `.task` "rise" CSS entry animation, caused every .task card to report a
 *   non-zero dy on every idle render, triggering a perpetual translate
 *   animation (visible jitter).
 *
 * The fix (already on main):
 *   Positions are now read from offsetLeft / offsetTop — layout-box values
 *   that are transform-free and relative to the offset parent.  An idle
 *   re-render therefore yields dy = 0 for every card, and no animation fires.
 *
 * What this test checks:
 *   After the initial render has settled, no .task element should receive a
 *   translate(...) animation during IDLE poll cycles (same state, several
 *   seconds of setTick ticks).
 *
 * Red condition (before fix):
 *   Running this script against commit 1f66da8 (feat: add animation) would
 *   report N > 0 idle translate animations → exit 1.
 *
 * Green condition (current head):
 *   useFlip uses offsetTop/offsetLeft → zero translate animations on idle
 *   renders → exit 0.
 *
 * Usage:
 *   node ui/app/scripts/repro-jitter.mjs
 *
 * Requirements: playwright in devDependencies + chromium installed.
 */

import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const STUB_PORT = 9882;
const APP_PORT  = 5182;

// ---------------------------------------------------------------------------
// Stub state — stable board with several tasks so useFlip has cards to track
// ---------------------------------------------------------------------------
const STUB_STATE = {
  board: [
    { n: 10, kind: 'charter', state: 'approved', title: 'Jitter Charter', labels: [], charter: null, cost: null, pr: null, phase: null },
    { n: 11, kind: 'leaf', state: 'open',        title: 'Task Alpha',   labels: [], charter: 10, cost: null,  pr: null, phase: null },
    { n: 12, kind: 'leaf', state: 'in-progress', title: 'Task Beta',    labels: [], charter: 10, cost: 0.004, pr: null, phase: 'coding' },
    { n: 13, kind: 'leaf', state: 'review',      title: 'Task Gamma',   labels: [], charter: 10, cost: 0.011, pr: null, phase: 'review' },
    { n: 14, kind: 'leaf', state: 'open',        title: 'Task Delta',   labels: [], charter: 10, cost: null,  pr: null, phase: null },
    { n: 15, kind: 'leaf', state: 'open',        title: 'Task Epsilon', labels: [], charter: 10, cost: null,  pr: null, phase: null },
  ],
  agents: [
    { task: 12, role: 'executor', phase: 'coding', title: 'Task Beta', started: new Date(Date.now() - 30000).toISOString() },
  ],
  budget: { spent: 0.015, cap: 5, runs: [] },
  flags:  { paused: false, killed: false },
  autonomy: { repo: 'test/jitter-repo' },
};

// ---------------------------------------------------------------------------
// Stub server — always returns the same state (simulates idle)
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
      } else if (url === '/api/team') {
        // Return present:false so fetchTeam() uses its bundled FALLBACK_TEAM
        // without a 404 console.error from the browser.
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
// Utility: wait for TCP port
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
  console.log('=== repro-jitter.mjs ===');

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

  try {
    await waitForPort(APP_PORT, 25000);
    console.log('[app] server ready');

    const browser = await chromium.launch({ headless: true });
    const ctx     = await browser.newContext();

    // Point the app at our stub API
    await ctx.addInitScript((stubUrl) => {
      localStorage.setItem('cb_api',   stubUrl);
      localStorage.setItem('cb_token', 'jitter-token');
    }, `http://127.0.0.1:${STUB_PORT}`);

    // ── Inject translate-animation spy ─────────────────────────────────────
    // We patch Element.prototype.animate BEFORE React mounts so we capture
    // every WAAPI call.  We count calls where:
    //   • the element has class 'task' (a board task card, managed by useFlip)
    //   • the first keyframe's transform contains 'translate'
    // This is exactly what the FLIP jitter produces.
    await ctx.addInitScript(() => {
      window.__flipTranslateCount  = 0;  // total translate-on-.task calls seen
      window.__flipTranslateSamples = []; // for debugging: first few messages

      const _orig = Element.prototype.animate;
      Element.prototype.animate = function (keyframes, options) {
        try {
          if (this.classList && this.classList.contains('task')) {
            const kfs = Array.isArray(keyframes) ? keyframes : [];
            for (const kf of kfs) {
              if (typeof kf.transform === 'string' && kf.transform.includes('translate')) {
                window.__flipTranslateCount++;
                if (window.__flipTranslateSamples.length < 10) {
                  window.__flipTranslateSamples.push({
                    transform: kf.transform,
                    taskId: this.dataset?.flipKey ?? '?',
                    t: Date.now(),
                  });
                }
                break;
              }
            }
          }
        } catch (_) { /* never throw from spy */ }
        return _orig.apply(this, arguments);
      };
    });

    const page = await ctx.newPage();

    await page.goto(`http://127.0.0.1:${APP_PORT}`);

    // Wait for the board to render task cards
    await page.waitForSelector('.task', { timeout: 12000 });
    console.log('✅  Board rendered with task cards');

    // Let the initial entry animations (the .task "rise" CSS animation,
    // and any first-render FLIP) fully settle before we start counting.
    // 2.5 s ≫ the 300 ms FLIP duration and 0.4 s CSS rise animation.
    const SETTLE_MS = 2500;
    console.log(`[jitter] waiting ${SETTLE_MS}ms for initial animations to settle…`);
    await page.waitForTimeout(SETTLE_MS);

    // Reset counter — only count from here onward (idle phase)
    await page.evaluate(() => {
      window.__flipTranslateCount  = 0;
      window.__flipTranslateSamples = [];
    });
    console.log('[jitter] counter reset — watching idle ticks…');

    // Watch for IDLE_MS ms.  setTick fires every 1000 ms → we see ≥ TICKS ticks.
    // The SSE/poll state never changes (stub always returns the same board).
    // With the fix: no FLIP animation should fire.
    // Without the fix: every tick would fire translate animations on all tasks.
    const IDLE_MS = 4000;
    const TICKS   = Math.floor(IDLE_MS / 1000);
    console.log(`[jitter] idle window: ${IDLE_MS}ms (~${TICKS} setTick cycles)…`);
    await page.waitForTimeout(IDLE_MS);

    const { count, samples } = await page.evaluate(() => ({
      count:   window.__flipTranslateCount,
      samples: window.__flipTranslateSamples,
    }));

    console.log(`[jitter] translate-on-.task animations during idle: ${count}`);
    if (samples.length > 0) {
      console.error('[jitter] sample animations detected:');
      samples.forEach((s) => console.error(`  task=${s.taskId} transform="${s.transform}" at +${s.t}ms`));
    }

    if (count > 0) {
      throw new Error(
        `FAIL: ${count} spurious FLIP translate animation(s) fired on .task elements ` +
        `during ${IDLE_MS}ms idle window — jitter regression detected.`
      );
    }

    console.log('✅  Zero spurious translate animations on .task during idle — jitter fix holds');

    await browser.close();
    console.log('');
    console.log('=== JITTER CHECK PASSED ===');
  } finally {
    viteProc.kill();
    stubServer.close();
  }
}

main().catch((err) => {
  console.error('\n❌  JITTER CHECK FAILED:', err.message);
  process.exit(1);
});
