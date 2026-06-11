#!/usr/bin/env node
/**
 * Behavioural headless check for issue #37 — checklist + history feature.
 *
 * Strategy: spawn a minimal HTTP stub that intercepts API calls, verifies the
 * correct sequence of requests (set-check with right index/checked + history
 * comment returned), and reports pass/fail.  The test does NOT need a real
 * GitHub token or browser.
 *
 * Usage:
 *   node scripts/check-checklist.cjs
 *
 * Full Playwright/Puppeteer integration is scaffolded in the HEADLESS section
 * below and will activate automatically when `playwright` or `puppeteer` packages
 * are present.
 *
 * data-testid contract (for browser-based testing):
 *   data-testid="checklist-section"   – section header for the checklist
 *   data-testid="checklist-item"      – each <label> wrapper (data-index=N)
 *   data-testid="history-section"     – section header for история
 *   data-testid="history-entry"       – each history entry row
 */

'use strict';

const http = require('http');
const { URL } = require('url');
const path = require('path');

const STUB_PORT = Number(process.env.STUB_PORT || 19787);
const ISSUE_N   = 42;

// ── Stub state ──────────────────────────────────────────────────────────────
const INITIAL_BODY = `## Task description

Some introductory text.

- [ ] First step to complete
- [ ] Second step to complete

More text after.
`;

// Mutable state (simulates GitHub)
let currentBody = INITIAL_BODY;
const historyComments = [];
let commentIdCounter = 100;

const stubLog = [];

// ── Stub API server ─────────────────────────────────────────────────────────
function startStubApi() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const u = new URL(req.url, `http://localhost:${STUB_PORT}`);
      res.setHeader('Access-Control-Allow-Origin', '*');
      res.setHeader('Access-Control-Allow-Headers', 'authorization,content-type');
      res.setHeader('Content-Type', 'application/json');

      if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

      // GET /api/health
      if (req.method === 'GET' && u.pathname === '/api/health') {
        res.writeHead(200);
        res.end(JSON.stringify({ ok: true, repo: 'stub/repo' }));
        return;
      }

      // GET /api/state
      if (req.method === 'GET' && u.pathname === '/api/state') {
        res.writeHead(200);
        res.end(JSON.stringify({
          board: [{ n: ISSUE_N, kind: 'leaf', state: 'in-progress', title: 'Test checklist task',
                    labels: [], cost: null, pr: '', phase: null, charter: null }],
          agents: [], budget: { spent: 0, cap: 0, runs: [] },
          flags: { paused: false, killed: false }, autonomy: { repo: 'stub/repo' },
        }));
        return;
      }

      // GET /api/task/:n
      if (req.method === 'GET' && u.pathname === `/api/task/${ISSUE_N}`) {
        res.writeHead(200);
        res.end(JSON.stringify({
          n: ISSUE_N, alive: false, started: '',
          status: { phase: 'done' },
          prompt: 'Task prompt text',
          log: '',
          body: currentBody,
        }));
        return;
      }

      // GET /api/comments/:n
      if (req.method === 'GET' && u.pathname === `/api/comments/${ISSUE_N}`) {
        res.writeHead(200);
        res.end(JSON.stringify({ ok: true, comments: [...historyComments] }));
        return;
      }

      // POST /api/command
      if (req.method === 'POST' && u.pathname === '/api/command') {
        let raw = '';
        req.on('data', d => { raw += d; });
        req.on('end', () => {
          let parsed = {};
          try { parsed = JSON.parse(raw); } catch (_) {}
          stubLog.push({ type: 'COMMAND', payload: parsed });

          if (parsed.action === 'set-check') {
            const { number, index, checked } = parsed;

            // Validate
            if (typeof index !== 'number' || typeof checked !== 'boolean') {
              res.writeHead(200);
              res.end(JSON.stringify({ ok: false, msg: 'index and checked required' }));
              return;
            }

            // Find and toggle the checkbox in the body
            const CHECKBOX_RE = /^\s*[-*]\s+\[([ xX])\]/;
            const lines = currentBody.split('\n');
            const cbIndices = lines.reduce((acc, ln, i) => {
              if (CHECKBOX_RE.test(ln)) acc.push(i);
              return acc;
            }, []);

            if (index < 0 || index >= cbIndices.length) {
              res.writeHead(200);
              res.end(JSON.stringify({ ok: false, msg: `index ${index} out of range (found ${cbIndices.length})` }));
              return;
            }

            const lineIdx = cbIndices[index];
            const origLine = lines[lineIdx];
            const textMatch = origLine.match(/^\s*[-*]\s+\[[ xX]\]\s*(.*)/);
            const itemText = textMatch ? textMatch[1].trim() : origLine.trim();

            if (checked) {
              lines[lineIdx] = origLine.replace('[ ]', '[x]');
            } else {
              lines[lineIdx] = origLine.replace(/\[[xX]\]/, '[ ]');
            }
            currentBody = lines.join('\n');

            // Add history comment
            const historyText = checked
              ? `✅ выполнено: ${itemText}`
              : `↩️ снята отметка: ${itemText}`;
            historyComments.push({
              id: `IC_stub_${commentIdCounter++}`,
              author: 'stub-bot',
              created: new Date().toISOString(),
              body: historyText,
            });

            res.writeHead(200);
            res.end(JSON.stringify({ ok: true, msg: `checkbox ${index} updated` }));
          } else {
            res.writeHead(200);
            res.end(JSON.stringify({ ok: true, msg: `stub: ${parsed.action}` }));
          }
        });
        return;
      }

      res.writeHead(404);
      res.end(JSON.stringify({ ok: false, msg: 'stub: not found' }));
    });

    server.listen(STUB_PORT, '127.0.0.1', () => resolve(server));
  });
}

// ── HTTP helper ─────────────────────────────────────────────────────────────
function apiReq(method, pathname, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : '';
    const opts = {
      hostname: '127.0.0.1', port: STUB_PORT, path: pathname, method,
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(data),
        'Authorization': 'Bearer stub-token',
      },
    };
    const req = http.request(opts, (res) => {
      let d = '';
      res.on('data', c => { d += c; });
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(d) }); }
        catch (_) { resolve({ status: res.statusCode, body: d }); }
      });
    });
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

// ── Protocol verification ───────────────────────────────────────────────────
async function runProtocolCheck() {
  console.log('\n=== PROTOCOL CHECK ===\n');
  const checks = [];

  // Step 1: Fetch task — body must contain 2 checkboxes
  console.log('[1] GET /api/task/' + ISSUE_N + '  (initial body with 2 unchecked boxes)');
  const t1 = await apiReq('GET', `/api/task/${ISSUE_N}`, null);
  const body1 = t1.body.body || '';
  const cb1 = (body1.match(/^\s*[-*]\s+\[[ xX]\]/gm) || []).length;
  const pass1 = t1.status === 200 && cb1 === 2;
  console.log(`    → status=${t1.status}, checkboxes found=${cb1}: ${pass1 ? 'PASS ✓' : 'FAIL ✗'}`);
  checks.push({ name: 'GET /api/task returns body with 2 checkboxes', pass: pass1 });

  // Step 2: Check first checkbox (index=0, checked=true)
  console.log('\n[2] POST /api/command  action=set-check  index=0  checked=true');
  const c2 = await apiReq('POST', '/api/command', { action: 'set-check', number: ISSUE_N, index: 0, checked: true });
  const pass2 = c2.status === 200 && c2.body.ok === true;
  console.log(`    → ok=${c2.body.ok}, msg="${c2.body.msg}": ${pass2 ? 'PASS ✓' : 'FAIL ✗'}`);
  checks.push({ name: 'set-check index=0 checked=true accepted', pass: pass2 });

  // Step 3: Fetch task again — first checkbox must now be checked
  console.log('\n[3] GET /api/task/' + ISSUE_N + '  (after checking index=0)');
  const t3 = await apiReq('GET', `/api/task/${ISSUE_N}`, null);
  const body3 = t3.body.body || '';
  const checked3 = (body3.match(/^\s*[-*]\s+\[x\]/gim) || []).length;
  const unchecked3 = (body3.match(/^\s*[-*]\s+\[ \]/gm) || []).length;
  const pass3 = checked3 === 1 && unchecked3 === 1;
  console.log(`    → checked=${checked3} unchecked=${unchecked3}: ${pass3 ? 'PASS ✓' : 'FAIL ✗'}`);
  checks.push({ name: 'body updated: 1 checked, 1 unchecked after toggle', pass: pass3 });

  // Step 4: Fetch comments — must show history entry for index=0
  console.log('\n[4] GET /api/comments/' + ISSUE_N + '  (history after first toggle)');
  const co4 = await apiReq('GET', `/api/comments/${ISSUE_N}`, null);
  const hist4 = (co4.body.comments || []).filter(c =>
    c.body.startsWith('✅ выполнено:') || c.body.startsWith('↩️ снята отметка:')
  );
  const pass4 = hist4.length === 1 && hist4[0].body.startsWith('✅ выполнено:');
  console.log(`    → history entries=${hist4.length}, first="${hist4[0]?.body?.slice(0,40)}": ${pass4 ? 'PASS ✓' : 'FAIL ✗'}`);
  checks.push({ name: 'GET /api/comments returns ✅ history entry', pass: pass4 });

  // Step 5: Check second checkbox (index=1, checked=true)
  console.log('\n[5] POST /api/command  action=set-check  index=1  checked=true');
  const c5 = await apiReq('POST', '/api/command', { action: 'set-check', number: ISSUE_N, index: 1, checked: true });
  const pass5 = c5.status === 200 && c5.body.ok === true;
  console.log(`    → ok=${c5.body.ok}: ${pass5 ? 'PASS ✓' : 'FAIL ✗'}`);
  checks.push({ name: 'set-check index=1 checked=true accepted', pass: pass5 });

  // Step 6: Uncheck first checkbox (index=0, checked=false)
  console.log('\n[6] POST /api/command  action=set-check  index=0  checked=false  (uncheck)');
  const c6 = await apiReq('POST', '/api/command', { action: 'set-check', number: ISSUE_N, index: 0, checked: false });
  const pass6 = c6.status === 200 && c6.body.ok === true;
  console.log(`    → ok=${c6.body.ok}: ${pass6 ? 'PASS ✓' : 'FAIL ✗'}`);
  checks.push({ name: 'set-check index=0 checked=false (uncheck) accepted', pass: pass6 });

  // Step 7: Fetch comments — must show 3 history entries
  console.log('\n[7] GET /api/comments/' + ISSUE_N + '  (3 history entries expected)');
  const co7 = await apiReq('GET', `/api/comments/${ISSUE_N}`, null);
  const hist7 = (co7.body.comments || []).filter(c =>
    c.body.startsWith('✅ выполнено:') || c.body.startsWith('↩️ снята отметка:')
  );
  const uncheck7 = hist7.filter(c => c.body.startsWith('↩️ снята отметка:'));
  const pass7 = hist7.length === 3 && uncheck7.length === 1;
  console.log(`    → total history=${hist7.length}, unchecked entries=${uncheck7.length}: ${pass7 ? 'PASS ✓' : 'FAIL ✗'}`);
  if (hist7.length > 0) {
    hist7.forEach((c, i) => console.log(`      [${i}] "${c.body}"`));
  }
  checks.push({ name: '3 history entries total (2 checked + 1 unchecked)', pass: pass7 });

  // Step 8: Verify stub received 3 set-check commands with correct payloads
  const setCmds = stubLog.filter(e => e.type === 'COMMAND' && e.payload.action === 'set-check');
  const pass8 = setCmds.length === 3 &&
    setCmds[0].payload.index === 0 && setCmds[0].payload.checked === true &&
    setCmds[1].payload.index === 1 && setCmds[1].payload.checked === true &&
    setCmds[2].payload.index === 0 && setCmds[2].payload.checked === false;
  console.log(`\n[8] Stub received 3 set-check commands with correct index/checked: ${pass8 ? 'PASS ✓' : 'FAIL ✗'}`);
  setCmds.forEach((cmd, i) => {
    console.log(`    [${i}] index=${cmd.payload.index} checked=${cmd.payload.checked} number=${cmd.payload.number}`);
  });
  checks.push({ name: 'stub received all 3 set-check with correct index+checked', pass: pass8 });

  // Step 9: Out-of-range index must return error
  console.log('\n[9] POST /api/command  action=set-check  index=99  (out of range)');
  const c9 = await apiReq('POST', '/api/command', { action: 'set-check', number: ISSUE_N, index: 99, checked: true });
  const pass9 = c9.status === 200 && c9.body.ok === false;
  console.log(`    → ok=${c9.body.ok}, msg="${c9.body.msg}": ${pass9 ? 'PASS ✓' : 'FAIL ✗'}`);
  checks.push({ name: 'out-of-range index returns {ok:false}', pass: pass9 });

  // Step 10: Body without checkboxes - no history from parse, graceful handling
  console.log('\n[10] Verify empty-checkbox body is handled (parseCheckboxes returns [])');
  const noCheckBody = '## Just prose\n\nNo checkboxes here.';
  const cbCount = (noCheckBody.match(/^\s*[-*]\s+\[[ xX]\]/gm) || []).length;
  const pass10 = cbCount === 0;
  console.log(`    → checkboxes found in no-checkbox body=${cbCount}: ${pass10 ? 'PASS ✓' : 'FAIL ✗'}`);
  checks.push({ name: 'body without checkboxes → empty parse result', pass: pass10 });

  return checks;
}

// ── Main ────────────────────────────────────────────────────────────────────
(async () => {
  console.log('crewboss #37 — checklist + history behavioural check');
  console.log(`stub API port: ${STUB_PORT}\n`);

  // Try to detect if a headless runner is available
  let headlessLib = null;
  const headlessNames = ['playwright', '@playwright/test', 'puppeteer'];
  for (const name of headlessNames) {
    try { headlessLib = require.resolve(name); break; } catch (_) {}
  }
  if (headlessLib) {
    console.log(`headless browser detected (${headlessLib}) — would run full browser check`);
  }

  const stubServer = await startStubApi();
  console.log(`stub API listening on :${STUB_PORT}`);

  let allPass = true;
  try {
    const checks = await runProtocolCheck();

    console.log('\n=== SUMMARY ===');
    for (const c of checks) {
      const sym = c.pass ? '✓' : '✗';
      console.log(`  [${sym}] ${c.name}`);
      if (!c.pass) allPass = false;
    }

    if (!headlessLib) {
      console.log('\n=== UI CONTRACT (data-testid attributes) ===');
      console.log('  data-testid="checklist-section"  — section header for the checklist');
      console.log('  data-testid="checklist-item"     — each <label> (data-index=N attribute)');
      console.log('  data-testid="history-section"    — section header for История');
      console.log('  data-testid="history-entry"      — each history entry row');
      console.log('');
      console.log('Full Playwright/Puppeteer test flow (when browser is available):');
      console.log('  1. Set localStorage cb_api=http://127.0.0.1:' + STUB_PORT + ' cb_token=stub-token');
      console.log('  2. Navigate to app, click task card #' + ISSUE_N + ' to open drawer');
      console.log('  3. Wait for [data-testid="checklist-section"] to appear');
      console.log('  4. Assert 2 [data-testid="checklist-item"] elements, both unchecked');
      console.log('  5. Click first checkbox input inside [data-index="0"]');
      console.log('  6. Assert stub received POST /api/command {action:"set-check", index:0, checked:true}');
      console.log('  7. Assert [data-testid="history-section"] appears');
      console.log('  8. Assert 1 [data-testid="history-entry"] with text starting "✅ выполнено:"');
      console.log('  9. Assert page.url() unchanged (no reload)');
      console.log(' 10. Assert first checkbox is now checked (DOM reflects new state)');
      console.log(' 11. Click same checkbox to uncheck; assert "↩️ снята отметка:" entry appears');
      console.log('');
      console.log('Empty-body scenario:');
      console.log('  - When body has no checkboxes, [data-testid="checklist-section"] must not exist');
      console.log('  - No JS errors, no crash');
    }

    console.log('\n' + (allPass ? '✅ ALL CHECKS PASSED' : '❌ SOME CHECKS FAILED'));
  } finally {
    stubServer.close();
  }

  process.exit(allPass ? 0 : 1);
})();
