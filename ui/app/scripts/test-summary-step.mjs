/**
 * Headless behavioural check — two-step summary confirmation flow (issue #38)
 *
 * Scenario:
 *   1. Open "+ New" modal, fill charter form.
 *   2. Click Create → summary step appears; /api/issue is NOT called yet.
 *   3. Click "Редактировать" → form step restored; all field values preserved.
 *   4. Click Create again → summary again.
 *   5. Click "Подтвердить" → /api/issue called exactly ONCE.
 *
 * Uses Playwright when available; falls back to protocol print + stub smoke-check.
 *
 * Usage:
 *   node ui/app/scripts/test-summary-step.mjs
 *
 * Requirements (for full headless run):
 *   npm install -D @playwright/test playwright
 *   npx playwright install chromium
 */

import http from 'http'
import path from 'path'
import { fileURLToPath } from 'url'
import { existsSync } from 'fs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// ---------------------------------------------------------------------------
// Stub server
// ---------------------------------------------------------------------------

const STUB_PORT = 18790

const emptyState = JSON.stringify({
  board: [],
  agents: [],
  budget: { spent: 0, cap: 100, runs: [] },
  flags: { paused: false, killed: false },
  autonomy: { repo: 'test/repo' },
})

let issueCalls = []

function createStub() {
  return http.createServer((req, res) => {
    const u = req.url ?? ''

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
        try { issueCalls.push(JSON.parse(body)) } catch { /* ignore */ }
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ ok: true, msg: 'Charter created', number: 77 }))
      })
      return
    }

    if (u.startsWith('/api/command') && req.method === 'POST') {
      let body = ''
      req.on('data', d => { body += d })
      req.on('end', () => {
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ ok: true, msg: 'ok' }))
      })
      return
    }

    res.writeHead(404); res.end('not found')
  })
}

// ---------------------------------------------------------------------------
// Playwright path
// ---------------------------------------------------------------------------

async function runPlaywright(stubUrl) {
  const { chromium } = await import('playwright')

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
  const appUrl = `http://127.0.0.1:${appPort}`
  console.log(`[app] static server → ${appUrl}`)

  const browser = await chromium.launch({ headless: true })
  const ctx = await browser.newContext()

  // Inject API URL before page loads
  await ctx.addInitScript(`localStorage.setItem('cb_api', '${stubUrl}')`)

  const page = await ctx.newPage()
  await page.goto(appUrl)
  await page.waitForLoadState('networkidle')

  // ─── OPEN MODAL ───────────────────────────────────────────────────────────
  await page.click('button:has-text("+ New")')
  await page.waitForSelector('[data-testid="ni-title"]')
  console.log('✓ Modal opened')

  // ─── FILL CHARTER FORM ────────────────────────────────────────────────────
  const TITLE = 'My Test Charter'
  const WHAT  = 'Build the feature'
  const WHY   = 'Users need it'

  await page.fill('[data-testid="ni-title"]', TITLE)
  await page.fill('[data-testid="ni-what"]',  WHAT)
  await page.fill('[data-testid="ni-why"]',   WHY)
  console.log('✓ Form filled')

  const issueCountBefore = issueCalls.length

  // ─── CLICK CREATE → should go to SUMMARY, not submit ─────────────────────
  await page.click('[data-testid="ni-submit"]')
  await page.waitForSelector('[data-testid="ni-summary-panel"]', { timeout: 5000 })
  console.log('✓ Summary panel visible after clicking Create')

  // Verify /api/issue was NOT called yet
  if (issueCalls.length !== issueCountBefore) {
    throw new Error(`FAIL: /api/issue was called (${issueCalls.length - issueCountBefore}x) before confirmation`)
  }
  console.log('✓ /api/issue NOT called yet (correct)')

  // Verify summary shows the right content
  const summaryTitle = await page.textContent('[data-testid="ni-summary-title"]')
  if (!summaryTitle.includes(TITLE)) throw new Error(`FAIL: summary title mismatch: "${summaryTitle}"`)
  console.log('✓ Summary title matches:', summaryTitle.trim())

  const summaryWhat = await page.textContent('[data-testid="ni-summary-what"]')
  if (!summaryWhat.includes(WHAT)) throw new Error(`FAIL: summary WHAT mismatch: "${summaryWhat}"`)
  console.log('✓ Summary WHAT matches:', summaryWhat.trim())

  const summaryWhy = await page.textContent('[data-testid="ni-summary-why"]')
  if (!summaryWhy.includes(WHY)) throw new Error(`FAIL: summary WHY mismatch: "${summaryWhy}"`)
  console.log('✓ Summary WHY matches:', summaryWhy.trim())

  // ─── CLICK РЕДАКТИРОВАТЬ → back to form ──────────────────────────────────
  await page.click('[data-testid="ni-edit-btn"]')
  await page.waitForSelector('[data-testid="ni-submit"]', { timeout: 3000 })
  console.log('✓ Clicked "Редактировать" — back on form step')

  // Verify fields are preserved
  const titleVal = await page.inputValue('[data-testid="ni-title"]')
  if (titleVal !== TITLE) throw new Error(`FAIL: title field reset — got "${titleVal}", expected "${TITLE}"`)
  console.log('✓ Title field preserved:', titleVal)

  const whatVal = await page.inputValue('[data-testid="ni-what"]')
  if (whatVal !== WHAT) throw new Error(`FAIL: WHAT field reset — got "${whatVal}"`)
  console.log('✓ WHAT field preserved:', whatVal)

  const whyVal = await page.inputValue('[data-testid="ni-why"]')
  if (whyVal !== WHY) throw new Error(`FAIL: WHY field reset — got "${whyVal}"`)
  console.log('✓ WHY field preserved:', whyVal)

  // /api/issue still not called
  if (issueCalls.length !== issueCountBefore) {
    throw new Error(`FAIL: /api/issue was called while editing`)
  }
  console.log('✓ /api/issue still NOT called (correct)')

  // ─── CLICK CREATE AGAIN → summary ────────────────────────────────────────
  await page.click('[data-testid="ni-submit"]')
  await page.waitForSelector('[data-testid="ni-summary-panel"]', { timeout: 5000 })
  console.log('✓ Summary shown again after second Create click')

  // ─── CLICK ПОДТВЕРДИТЬ → creates issue ───────────────────────────────────
  await page.click('[data-testid="ni-confirm-btn"]')

  // For charter, success step is shown next
  await page.waitForSelector('[data-testid="ni-success-msg"]', { timeout: 5000 })
  console.log('✓ Success step visible after confirmation')

  // /api/issue called exactly ONCE
  const newCalls = issueCalls.length - issueCountBefore
  if (newCalls !== 1) throw new Error(`FAIL: /api/issue called ${newCalls} times, expected 1`)
  console.log('✓ /api/issue called exactly 1 time — payload:', JSON.stringify(issueCalls[issueCalls.length - 1]))

  // Success step shows charter number
  const successText = await page.textContent('[data-testid="ni-success-msg"]')
  if (!successText.includes('77')) throw new Error(`FAIL: success msg missing charter number: "${successText}"`)
  console.log('✓ Success message contains charter number #77:', successText.trim())

  await browser.close()
  appServer.close()
  console.log('\n✅  All assertions passed')
}

// ---------------------------------------------------------------------------
// Protocol fallback
// ---------------------------------------------------------------------------

function printProtocol() {
  console.log(`
=== HEADLESS UNAVAILABLE — Manual/CI verification protocol (issue #38) ===

data-testid attributes in NewIssueModal:

  Form step:
    ni-title              — title input
    ni-what               — WHAT textarea (charter)
    ni-why                — WHY textarea (charter)
    ni-submit             — "Create" button (goes to summary, not to API)

  Summary step:
    ni-summary-backdrop   — modal background
    ni-summary-panel      — modal panel
    ni-summary-body       — summary container
    ni-summary-kind       — "Charter" or "Task"
    ni-summary-title      — issue title read-only
    ni-summary-what       — WHAT value (charter)
    ni-summary-why        — WHY value (charter)
    ni-summary-description— description (task)
    ni-summary-charter    — charter ref (task)
    ni-summary-depends    — depends-on (task, optional)
    ni-edit-btn           — "Редактировать" → back to form (fields preserved)
    ni-confirm-btn        — "Подтвердить" → calls /api/issue

  Success step (charter only — from issue #36):
    ni-success-panel      — success modal
    ni-success-msg        — "Чартер #N успешно создан"
    ni-run-warning        — spending warning
    ni-launch-btn         — "▶ Запустить"
    ni-close-btn          — "Закрыть"

Test scenario (charter):
  1. Open "+ New" modal.
  2. Tab "Charter" (default).
  3. Fill: title, WHAT, WHY.
  4. Click [ni-submit] "Create".
  5. Assert: [ni-summary-panel] visible, form not visible.
  6. Assert: [ni-summary-title] contains entered title.
  7. Assert: [ni-summary-what]  contains entered WHAT.
  8. Assert: [ni-summary-why]   contains entered WHY.
  9. Assert: /api/issue NOT called (stub call counter = 0).
 10. Click [ni-edit-btn] "Редактировать".
 11. Assert: form step visible again ([ni-submit] visible).
 12. Assert: title input = entered title (field preserved).
 13. Assert: WHAT textarea = entered WHAT (field preserved).
 14. Assert: WHY textarea  = entered WHY  (field preserved).
 15. Assert: /api/issue still NOT called.
 16. Click [ni-submit] again.
 17. Assert: [ni-summary-panel] visible.
 18. Click [ni-confirm-btn] "Подтвердить".
 19. Assert: [ni-success-msg] visible and contains charter number.
 20. Assert: /api/issue called exactly ONCE.

Test scenario (task):
  1. Open modal, switch to "Task" tab.
  2. Fill: title, description; select a charter; optionally set depends-on.
  3. Click Create → summary shows description, Charter ref, Depends-on (if set).
  4. /api/issue NOT called yet.
  5. Click Редактировать → fields preserved.
  6. Click Create → Подтвердить → /api/issue called once → modal closes, toast shown.
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
    // POST /api/issue
    const r = await new Promise((resolve, reject) => {
      const req = http.request({
        hostname: '127.0.0.1', port: STUB_PORT,
        path: '/api/issue', method: 'POST',
        headers: { 'Content-Type': 'application/json' },
      }, res => {
        let b = ''; res.on('data', d => b += d); res.on('end', () => resolve(b))
      })
      req.on('error', reject)
      req.end(JSON.stringify({ kind: 'charter', title: 'T', what: 'W', why: 'Y' }))
    })
    console.log('  POST /api/issue →', r)
    console.log('  issueCalls count:', issueCalls.length, '(expected 1)')
    if (issueCalls.length !== 1) throw new Error('Stub smoke-check failed')
    console.log('\nStub OK. Install Playwright for full headless run:')
    console.log('  cd ui/app && npm install -D @playwright/test playwright serve-static finalhandler')
    console.log('  npx playwright install chromium')
    console.log('  npm run build')
    console.log('  node scripts/test-summary-step.mjs')

    stub.close()
  }
})().catch(e => { console.error(e); process.exit(1) })
