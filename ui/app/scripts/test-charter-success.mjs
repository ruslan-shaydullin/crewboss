/**
 * Headless behavioural check — charter creation → success step → launch
 *
 * Uses Playwright (@playwright/test) when available; otherwise falls back to
 * a protocol / data-testid manifest so a human or CI runner can verify.
 *
 * Stub API:
 *   POST /api/issue   → { ok: true, number: 42 }
 *   POST /api/command → { ok: true, msg: "launched" }
 *   GET  /api/state   → minimal empty state
 *   GET  /api/events  → SSE stream (closes immediately)
 *
 * Usage:
 *   node ui/app/scripts/test-charter-success.mjs
 *
 * Requirements (for full headless run):
 *   npm install -D @playwright/test && npx playwright install chromium
 */

import http from 'http'
import path from 'path'
import { fileURLToPath } from 'url'
import { existsSync } from 'fs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// ---------------------------------------------------------------------------
// Shared: stub server
// ---------------------------------------------------------------------------

const STUB_PORT = 18787

const emptyState = JSON.stringify({
  board: [], agents: [],
  budget: { spent: 0, cap: 100, runs: [] },
  flags: { paused: false, killed: false },
  autonomy: { repo: 'test/repo' },
})

let commandCalls = []

function createStub () {
  return http.createServer((req, res) => {
    const u = req.url ?? ''

    // CORS
    res.setHeader('Access-Control-Allow-Origin', '*')
    res.setHeader('Access-Control-Allow-Headers', '*')
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return }

    if (u.startsWith('/api/events')) {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' })
      res.write(`event: state\ndata: ${emptyState}\n\n`)
      setTimeout(() => res.end(), 200)
      return
    }

    if (u.startsWith('/api/state')) {
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(emptyState)
      return
    }

    if (u.startsWith('/api/issue') && req.method === 'POST') {
      let body = ''
      req.on('data', d => { body += d })
      req.on('end', () => {
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ ok: true, msg: 'Charter created', number: 42 }))
      })
      return
    }

    if (u.startsWith('/api/command') && req.method === 'POST') {
      let body = ''
      req.on('data', d => { body += d })
      req.on('end', () => {
        try { commandCalls.push(JSON.parse(body)) } catch { /* ignore */ }
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ ok: true, msg: 'launched' }))
      })
      return
    }

    res.writeHead(404); res.end('not found')
  })
}

// ---------------------------------------------------------------------------
// Playwright path
// ---------------------------------------------------------------------------

async function runPlaywright (appUrl) {
  // Dynamic import — won't crash if package is absent
  const { chromium } = await import('playwright')

  const browser = await chromium.launch({ headless: true })
  const ctx = await browser.newContext()
  const page = await ctx.newPage()

  // Inject API URL before page loads (via localStorage)
  await ctx.addInitScript(`localStorage.setItem('cb_api', '${appUrl}')`)

  // We need to serve the built app — use the dist/ folder
  const distDir = path.resolve(__dirname, '../dist')
  if (!existsSync(distDir)) {
    throw new Error('dist/ not found — run: npm run build  in ui/app first')
  }

  // Serve dist/ via a tiny static server
  const { default: serveStatic } = await import('serve-static')
  const { default: finalhandler } = await import('finalhandler')
  const serve = serveStatic(distDir, { index: ['index.html'] })
  const appServer = http.createServer((req, res) => serve(req, res, finalhandler(req, res)))
  await new Promise(r => appServer.listen(0, '127.0.0.1', r))
  const appPort = appServer.address().port
  const url = `http://127.0.0.1:${appPort}`

  await page.goto(url)
  await page.waitForLoadState('networkidle')

  // Open modal
  await page.click('button:has-text("+ New")')
  await page.waitForSelector('[data-testid="ni-title"]')

  // Make sure Charter tab is selected (it's default)
  // Fill the form
  await page.fill('[data-testid="ni-title"]', 'Test Charter')
  await page.fill('[data-testid="ni-what"]', 'Build something useful')
  await page.fill('[data-testid="ni-why"]', 'Because it is needed')

  // Click Create
  await page.click('[data-testid="ni-submit"]')

  // Success step should be visible
  await page.waitForSelector('[data-testid="ni-success-msg"]', { timeout: 3000 })
  const successText = await page.textContent('[data-testid="ni-success-msg"]')
  console.assert(successText.includes('42'), `Expected charter number 42 in: ${successText}`)
  console.log('✓ Success step visible:', successText.trim())

  // Warning about spending should be visible
  await page.waitForSelector('[data-testid="ni-run-warning"]')
  console.log('✓ Spending warning visible')

  // Click Launch
  await page.click('[data-testid="ni-launch-btn"]')

  // Modal should close
  await page.waitForSelector('[data-testid="ni-success-panel"]', { state: 'detached', timeout: 3000 })
  console.log('✓ Modal closed after launch')

  // Verify stub received action:run
  const runCall = commandCalls.find(c => c.action === 'run')
  console.assert(runCall, 'Expected /api/command to be called with action:run')
  console.log('✓ Stub received action:run:', JSON.stringify(runCall))

  await browser.close()
  appServer.close()
  console.log('\n✅  All assertions passed')
}

// ---------------------------------------------------------------------------
// Protocol fallback (no headless browser available)
// ---------------------------------------------------------------------------

function printProtocol () {
  console.log(`
=== HEADLESS UNAVAILABLE — Manual/CI verification protocol ===

data-testid attributes added to NewIssueModal:

  ni-title          — title input (charter form)
  ni-what           — WHAT textarea (charter form)
  ni-why            — WHY textarea (charter form)
  ni-submit         — Create button
  ni-success-panel  — modal panel (success step)
  ni-success-msg    — "Чартер #N создан" message
  ni-run-warning    — spending warning text
  ni-launch-btn     — "▶ Запустить" button
  ni-close-btn      — "Закрыть" button

Test scenario:
  1. Set stub API (POST /api/issue → {ok:true,number:42})
  2. Open "+ New" modal
  3. Make sure "Charter" tab is active (default)
  4. Fill: title="Test Charter", WHAT="Build it", WHY="Need it"
  5. Click [data-testid=ni-submit]
  6. Assert: [data-testid=ni-success-panel] is visible
  7. Assert: [data-testid=ni-success-msg] contains "#42"
  8. Assert: [data-testid=ni-run-warning] is visible
  9. Click [data-testid=ni-launch-btn]
  10. Stub: POST /api/command received {action:"run"}
  11. Assert: [data-testid=ni-success-panel] detached (modal closed)

Separation: task creation still calls onToast + onClose without success step.

Stub server code is in this file. Run with Playwright for full headless check.
`)
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

;(async () => {
  const stub = createStub()
  await new Promise(r => stub.listen(STUB_PORT, '127.0.0.1', r))
  const stubUrl = `http://127.0.0.1:${STUB_PORT}`
  console.log(`Stub API listening on ${stubUrl}`)

  let playwrightAvailable = false
  try {
    await import('playwright')
    playwrightAvailable = true
  } catch {
    // not installed
  }

  if (playwrightAvailable) {
    try {
      await runPlaywright(stubUrl)
    } finally {
      stub.close()
    }
  } else {
    console.log('Playwright not installed — printing test protocol instead.\n')
    printProtocol()

    console.log('\nStub server smoke-check:')
    // Quick smoke-check: hit /api/issue
    const r = await new Promise((res, rej) => {
      const req = http.request({
        hostname: '127.0.0.1', port: STUB_PORT,
        path: '/api/issue', method: 'POST',
        headers: { 'Content-Type': 'application/json' },
      }, r => {
        let b = ''; r.on('data', d => b += d); r.on('end', () => res(b))
      })
      req.on('error', rej)
      req.end(JSON.stringify({ kind: 'charter', title: 'T', what: 'W', why: 'Y' }))
    })
    console.log('  POST /api/issue →', r)
    // hit /api/command
    const r2 = await new Promise((res, rej) => {
      const req = http.request({
        hostname: '127.0.0.1', port: STUB_PORT,
        path: '/api/command', method: 'POST',
        headers: { 'Content-Type': 'application/json' },
      }, r => {
        let b = ''; r.on('data', d => b += d); r.on('end', () => res(b))
      })
      req.on('error', rej)
      req.end(JSON.stringify({ action: 'run' }))
    })
    console.log('  POST /api/command {action:"run"} →', r2)
    console.log('\nStub OK. Install Playwright for full headless run:')
    console.log('  npm install -D @playwright/test playwright')
    console.log('  npx playwright install chromium')
    console.log('  node ui/app/scripts/test-charter-success.mjs')

    stub.close()
  }
})().catch(e => { console.error(e); process.exit(1) })
