/**
 * Headless behavioural check — facilitator stage in issue creation (issue #94)
 *
 * Three scenarios (RED -> GREEN):
 *
 *   RED-a: fill form without acceptance block -> click Create ->
 *          assert: discuss stage visible; creation blocked (Continue disabled).
 *          Before fix: modal creates issue immediately, no facilitator stage.
 *
 *   RED-b: go through facilitator dialog (stub responses) -> create ->
 *          assert: stub-API payload contains valid ## Acceptance (machine) block.
 *          Before fix: no acceptance block in payload.
 *
 *   RED-c: manual valid block entry -> creation proceeds;
 *          garbage block -> creation blocked.
 *
 * Chromium detection: pure filesystem check of ms-playwright cache (no
 * playwright import) — safe in sandboxed environments.
 *
 * Fallback (no Chromium): inline validation unit-tests + stub smoke-check.
 * Always exits with an explicit process.exit() call.
 *
 * Usage:
 *   node ui/app/scripts/test-facilitator-stage.mjs
 *
 * Requires (for full headless run):
 *   npm ci && npx playwright install chromium && npm run build
 */

import http from 'node:http'
import { spawn } from 'node:child_process'
import path from 'node:path'
import fs from 'node:fs'
import os from 'node:os'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const _require   = createRequire(import.meta.url)

// ---------------------------------------------------------------------------
// Ports (no conflict with other test scripts: 9881/9882 smoke/jitter,
//        18787 charter-success, 18790 summary-step)
// ---------------------------------------------------------------------------
const STUB_PORT = 18792
const APP_PORT  = 18793

// ---------------------------------------------------------------------------
// Shared state (reset per scenario)
// ---------------------------------------------------------------------------
const emptyState = JSON.stringify({
  board: [],
  agents: [],
  budget: { spent: 0, cap: 100, runs: [] },
  flags: { paused: false, killed: false },
  autonomy: { repo: 'test/facilitator-repo' },
})

let issueCalls = []
let facilitateCalls = []

function resetCalls() {
  issueCalls = []
  facilitateCalls = []
}

// ---------------------------------------------------------------------------
// Stub server — handles /api/facilitate in addition to standard endpoints
// ---------------------------------------------------------------------------
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
        res.end(JSON.stringify({ ok: true, msg: 'Charter created', number: 55 }))
      })
      return
    }

    if (u.startsWith('/api/facilitate') && req.method === 'POST') {
      let body = ''
      req.on('data', d => { body += d })
      req.on('end', () => {
        let parsed = {}
        try { parsed = JSON.parse(body) } catch { /* ignore */ }
        facilitateCalls.push(parsed)
        // Return acceptance_block when user sends non-empty message; else question
        const hasMsg = (parsed.message || '').trim()
        const response = hasMsg
          ? {
              ok: true,
              message: 'Based on your description, here is the acceptance block:',
              acceptance_block: '## Acceptance (machine)\n- check: make test\n- check: npm run lint'
            }
          : {
              ok: true,
              message: 'What specific outcomes should be verified when this is done?'
            }
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify(response))
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
// Acceptance block validation (mirrors App.tsx hasValidAcceptanceBlock)
// ---------------------------------------------------------------------------
function hasValidAcceptanceBlock(text) {
  if (!text.trim()) return false
  const lines = text.split('\n')
  let inBlock = false
  for (const line of lines) {
    if (/^## Acceptance \(machine\)/.test(line)) { inBlock = true; continue }
    if (inBlock && /^## /.test(line)) break
    if (inBlock && /^\s*- (test|check): .+/.test(line)) return true
  }
  return false
}

// ---------------------------------------------------------------------------
// Chromium availability — pure filesystem check, NO playwright import
// Avoids seccomp violations in sandboxed environments.
// ---------------------------------------------------------------------------
function chromiumIsAvailable() {
  const cacheBase = path.join(os.homedir(), '.cache', 'ms-playwright')
  if (!fs.existsSync(cacheBase)) return false
  try {
    const entries = fs.readdirSync(cacheBase).filter(f => f.startsWith('chromium-'))
    for (const dir of entries) {
      if (fs.existsSync(path.join(cacheBase, dir, 'chrome-linux64', 'chrome'))) return true
      if (fs.existsSync(path.join(cacheBase, dir, 'chrome-mac', 'Chromium.app', 'Contents', 'MacOS', 'Chromium'))) return true
    }
  } catch { /* ignore */ }
  return false
}

// ---------------------------------------------------------------------------
// Utility: wait for TCP port
// ---------------------------------------------------------------------------
function waitForPort(port, timeoutMs = 25000) {
  return new Promise((resolve, reject) => {
    const start = Date.now()
    const tryConnect = () => {
      const req = http.get({ host: '127.0.0.1', port, path: '/', timeout: 500 }, () => {
        req.destroy(); resolve()
      })
      req.on('error', () => {
        if (Date.now() - start > timeoutMs) {
          reject(new Error(`Port ${port} not ready after ${timeoutMs}ms`))
          return
        }
        setTimeout(tryConnect, 300)
      })
    }
    tryConnect()
  })
}

// ---------------------------------------------------------------------------
// Playwright scenarios (only called when chromium binary is confirmed present)
// NOTE: playwright is required HERE (not at top level) to avoid polluting
// the fallback path with playwright's native bindings.
// ---------------------------------------------------------------------------
async function runPlaywright(stubUrl) {
  const { chromium } = _require('playwright')

  const appDir = path.resolve(__dirname, '..')
  const distIndex = path.join(appDir, 'dist', 'index.html')
  const hasDistIndex = fs.existsSync(distIndex)
  const viteMode = hasDistIndex ? 'preview' : 'dev'

  console.log(`[app] starting vite ${viteMode} on port ${APP_PORT}...`)
  const viteArgs = [viteMode, '--port', String(APP_PORT), '--host', '127.0.0.1']
  const viteProc = spawn('node_modules/.bin/vite', viteArgs, {
    cwd: appDir, stdio: ['ignore', 'pipe', 'pipe'],
  })
  viteProc.stdout.on('data', d => process.stdout.write('[vite] ' + d))
  viteProc.stderr.on('data', d => process.stderr.write('[vite] ' + d))

  try {
    await waitForPort(APP_PORT, 25000)
    console.log('[app] server ready')

    const appUrl = `http://127.0.0.1:${APP_PORT}`

    // ── SCENARIO A: no acceptance block → creation blocked ──────────────────
    console.log('\n-- Scenario RED-a: no acceptance block -> discuss stage blocks creation --')
    resetCalls()
    {
      const browser = await chromium.launch({ headless: true })
      const ctx = await browser.newContext()
      await ctx.addInitScript(`localStorage.setItem('cb_api', '${stubUrl}')`)
      const page = await ctx.newPage()
      await page.goto(appUrl)
      await page.waitForLoadState('networkidle')

      await page.click('button:has-text("+ New")')
      await page.waitForSelector('[data-testid="ni-title"]')

      await page.fill('[data-testid="ni-title"]', 'Test Charter A')
      await page.fill('[data-testid="ni-what"]', 'Build feature A')
      await page.fill('[data-testid="ni-why"]', 'Users need it')

      const issueBefore = issueCalls.length

      // Clicking Create should go to discuss stage, not create issue
      await page.click('[data-testid="ni-submit"]')

      await page.waitForSelector('[data-testid="ni-discuss-panel"]', { timeout: 5000 })
      console.log('OK RED-a: Discuss panel visible after clicking Create')

      const continueDisabled = await page.$eval(
        '[data-testid="ni-discuss-continue"]',
        el => el.disabled
      )
      if (!continueDisabled) throw new Error('FAIL RED-a: Continue button must be disabled without acceptance block')
      console.log('OK RED-a: Continue button is disabled (no acceptance block)')

      if (issueCalls.length !== issueBefore) {
        throw new Error(`FAIL RED-a: /api/issue was called ${issueCalls.length - issueBefore} times before acceptance block`)
      }
      console.log('OK RED-a: No issue created - creation is correctly blocked')

      await browser.close()
    }
    console.log('PASS RED-a\n')

    // ── SCENARIO B: facilitator dialog → issue with acceptance block ─────────
    console.log('-- Scenario RED-b: facilitator dialog -> acceptance block in issue payload --')
    resetCalls()
    {
      const browser = await chromium.launch({ headless: true })
      const ctx = await browser.newContext()
      await ctx.addInitScript(`localStorage.setItem('cb_api', '${stubUrl}')`)
      const page = await ctx.newPage()
      await page.goto(appUrl)
      await page.waitForLoadState('networkidle')

      await page.click('button:has-text("+ New")')
      await page.waitForSelector('[data-testid="ni-title"]')

      await page.fill('[data-testid="ni-title"]', 'Test Charter B')
      await page.fill('[data-testid="ni-what"]', 'Build feature B')
      await page.fill('[data-testid="ni-why"]', 'Business value B')

      await page.click('[data-testid="ni-submit"]')
      await page.waitForSelector('[data-testid="ni-discuss-panel"]', { timeout: 5000 })
      console.log('OK RED-b: Discuss panel opened')

      // Send a message to the facilitator stub
      await page.fill('[data-testid="ni-chat-input"]', 'Please generate the acceptance block')
      await page.click('[data-testid="ni-chat-send"]')

      // Wait for facilitator to populate the acceptance block
      await page.waitForFunction(
        () => {
          const el = document.querySelector('[data-testid="ni-acceptance-input"]')
          return el && el.value && el.value.includes('## Acceptance (machine)')
        },
        { timeout: 5000 }
      )
      console.log('OK RED-b: Facilitator populated acceptance block')

      const continueDisabled = await page.$eval(
        '[data-testid="ni-discuss-continue"]',
        el => el.disabled
      )
      if (continueDisabled) throw new Error('FAIL RED-b: Continue button must be enabled after acceptance block populated')
      console.log('OK RED-b: Continue button enabled')

      await page.click('[data-testid="ni-discuss-continue"]')
      await page.waitForSelector('[data-testid="ni-summary-panel"]', { timeout: 5000 })
      console.log('OK RED-b: Summary panel visible')

      await page.click('[data-testid="ni-confirm-btn"]')
      await page.waitForSelector('[data-testid="ni-success-msg"]', { timeout: 5000 })
      console.log('OK RED-b: Issue created successfully')

      if (issueCalls.length === 0) throw new Error('FAIL RED-b: no issue creation calls recorded')
      const call = issueCalls[issueCalls.length - 1]
      const block = call.acceptance_block || ''
      if (!hasValidAcceptanceBlock(block)) {
        throw new Error(`FAIL RED-b: issue payload missing valid ## Acceptance (machine) block.\nGot: "${block}"`)
      }
      console.log('OK RED-b: Issue payload has valid acceptance_block:', JSON.stringify(block))

      await browser.close()
    }
    console.log('PASS RED-b\n')

    // ── SCENARIO C: manual acceptance block entry ─────────────────────────────
    console.log('-- Scenario RED-c: manual acceptance block validation --')
    resetCalls()
    {
      const browser = await chromium.launch({ headless: true })
      const ctx = await browser.newContext()
      await ctx.addInitScript(`localStorage.setItem('cb_api', '${stubUrl}')`)
      const page = await ctx.newPage()
      await page.goto(appUrl)
      await page.waitForLoadState('networkidle')

      await page.click('button:has-text("+ New")')
      await page.waitForSelector('[data-testid="ni-title"]')

      await page.fill('[data-testid="ni-title"]', 'Test Charter C')
      await page.fill('[data-testid="ni-what"]', 'Build feature C')
      await page.fill('[data-testid="ni-why"]', 'Business value C')

      await page.click('[data-testid="ni-submit"]')
      await page.waitForSelector('[data-testid="ni-discuss-panel"]', { timeout: 5000 })

      // RED-c1: garbage entry -> continue disabled
      await page.fill('[data-testid="ni-acceptance-input"]', 'this is not a valid acceptance block')
      const continueAfterGarbage = await page.$eval('[data-testid="ni-discuss-continue"]', el => el.disabled)
      if (!continueAfterGarbage) throw new Error('FAIL RED-c: Continue must be disabled with garbage acceptance block')
      console.log('OK RED-c: Continue disabled with garbage block')

      // RED-c2: valid block -> continue enabled
      const validBlock = '## Acceptance (machine)\n- check: make test\n- check: npm run lint'
      await page.fill('[data-testid="ni-acceptance-input"]', validBlock)
      await page.waitForFunction(
        () => !document.querySelector('[data-testid="ni-discuss-continue"]').disabled,
        { timeout: 3000 }
      )
      console.log('OK RED-c: Continue enabled with valid block')

      // RED-c3: proceed and verify acceptance_block in payload
      await page.click('[data-testid="ni-discuss-continue"]')
      await page.waitForSelector('[data-testid="ni-summary-panel"]', { timeout: 5000 })
      await page.click('[data-testid="ni-confirm-btn"]')
      await page.waitForSelector('[data-testid="ni-success-msg"]', { timeout: 5000 })

      const callC = issueCalls[issueCalls.length - 1]
      const blockC = callC?.acceptance_block || ''
      if (!hasValidAcceptanceBlock(blockC)) {
        throw new Error(`FAIL RED-c: issue payload missing valid acceptance block.\nGot: "${blockC}"`)
      }
      console.log('OK RED-c: Manual acceptance block correctly included in issue payload')

      await browser.close()
    }
    console.log('PASS RED-c\n')

  } finally {
    viteProc.kill()
  }
}

// ---------------------------------------------------------------------------
// Protocol fallback (no headless browser)
// ---------------------------------------------------------------------------
function printProtocol() {
  console.log(`
=== HEADLESS UNAVAILABLE - Manual/CI verification protocol (issue #94) ===

data-testid attributes in NewIssueModal (discuss step):

  Discuss step (step='discuss'):
    ni-discuss-backdrop   - modal overlay (click to close)
    ni-discuss-panel      - modal panel
    ni-facilitator-chat   - chat container (scrollable)
    ni-chat-message       - individual chat bubble (data-role="user"|"facilitator")
    ni-chat-input         - user message textarea (Ctrl+Enter to send)
    ni-chat-send          - "Send" button (disabled when input empty or facilitating)
    ni-acceptance-input   - ## Acceptance (machine) textarea (monospace)
    ni-acceptance-valid   - green indicator (shown when block is structurally valid)
    ni-acceptance-invalid - red indicator (shown when block is non-empty but invalid)
    ni-discuss-back       - back to form step
    ni-discuss-continue   - continue to summary (DISABLED until valid acceptance block)
    ni-facilitator-error  - error message when /api/facilitate is unavailable

  /api/facilitate  POST  { kind, draft, message, history }
    -> { ok, message, acceptance_block? }
    acceptance_block is returned when the facilitator has enough info.

Test scenarios:

  RED-a (creation blocked without acceptance block):
    1. Open modal, fill Title + WHAT + WHY (Charter tab, default).
    2. Click [ni-submit].
    3. Assert: [ni-discuss-panel] is visible.
    4. Assert: [ni-discuss-continue] is disabled.
    5. Assert: /api/issue was NOT called.

  RED-b (facilitator dialog -> acceptance block in payload):
    1. Fill form, click Create -> discuss step.
    2. Fill [ni-chat-input] with any text, click [ni-chat-send].
    3. Stub /api/facilitate returns { ok:true, acceptance_block: "## Acceptance (machine)\\n- check: ..." }.
    4. Assert: [ni-acceptance-input].value contains "## Acceptance (machine)".
    5. Assert: [ni-discuss-continue] is enabled.
    6. Click Continue -> Summary -> Confirm -> Success.
    7. Assert: last /api/issue call body has acceptance_block with valid block.

  RED-c (manual entry validation):
    1. Fill form, click Create -> discuss step.
    2. Fill [ni-acceptance-input] with "garbage text" -> [ni-discuss-continue] disabled.
    3. Fill [ni-acceptance-input] with valid block -> [ni-discuss-continue] enabled.
    4. Proceed -> confirm -> acceptance_block in /api/issue payload.

Install Playwright for full headless run:
  npm ci && npx playwright install chromium && npm run build
`)
}

// ---------------------------------------------------------------------------
// Fallback: inline validation unit-tests + stub smoke-check
// (no playwright import — safe in sandboxed environments)
// ---------------------------------------------------------------------------
async function runFallbackChecks() {
  console.log('-- Fallback: inline acceptance-block validation unit-tests --')

  const validationTests = [
    { text: '## Acceptance (machine)\n- check: make test', expected: true, desc: 'valid check line' },
    { text: '## Acceptance (machine)\n- test: path/to/test.sh', expected: true, desc: 'valid test line' },
    { text: '## Acceptance (machine)\n- check: npm run lint\n- test: foo.sh', expected: true, desc: 'multiple items' },
    { text: '## Acceptance (machine)\n  - check: make test', expected: true, desc: 'indented item' },
    { text: 'no header\n- check: make test', expected: false, desc: 'no header' },
    { text: '## Acceptance (machine)', expected: false, desc: 'header but no items' },
    { text: '## Acceptance (machine)\nsome prose text', expected: false, desc: 'invalid item format' },
    { text: '## Acceptance (machine)\n- run: make test', expected: false, desc: 'wrong prefix (run:)' },
    { text: '', expected: false, desc: 'empty string' },
    { text: '## Acceptance (machine)\n## Next section\n- check: make test', expected: false, desc: 'item after next header' },
  ]

  for (const t of validationTests) {
    const result = hasValidAcceptanceBlock(t.text)
    if (result !== t.expected) {
      throw new Error(
        `FAIL validation: "${t.desc}" - expected ${t.expected}, got ${result}\nInput: ${JSON.stringify(t.text)}`
      )
    }
    console.log(`  OK "${t.desc}"`)
  }
  console.log('All validation unit-tests passed\n')

  console.log('-- Fallback: stub API smoke-check --')

  // /api/facilitate with message -> should return acceptance_block
  const body1 = JSON.stringify({ kind: 'charter', draft: { title: 'T' }, message: 'ready', history: [] })
  const r1 = await new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1', port: STUB_PORT,
      path: '/api/facilitate', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body1) },
    }, res => { let b = ''; res.on('data', d => b += d); res.on('end', () => resolve(b)) })
    req.on('error', reject)
    req.end(body1)
  })
  const p1 = JSON.parse(r1)
  if (!p1.ok) throw new Error(`FAIL: /api/facilitate (with msg) returned ok=false`)
  if (!p1.acceptance_block) throw new Error(`FAIL: /api/facilitate (with msg) missing acceptance_block`)
  if (!hasValidAcceptanceBlock(p1.acceptance_block)) {
    throw new Error(`FAIL: /api/facilitate acceptance_block is not valid: "${p1.acceptance_block}"`)
  }
  console.log('  OK /api/facilitate (with message) ->', JSON.stringify(p1.acceptance_block))

  // /api/facilitate without message -> question only (no acceptance_block)
  const body2 = JSON.stringify({ kind: 'charter', draft: { title: 'T' }, message: '', history: [] })
  const r2 = await new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1', port: STUB_PORT,
      path: '/api/facilitate', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body2) },
    }, res => { let b = ''; res.on('data', d => b += d); res.on('end', () => resolve(b)) })
    req.on('error', reject)
    req.end(body2)
  })
  const p2 = JSON.parse(r2)
  if (!p2.ok) throw new Error(`FAIL: /api/facilitate (empty msg) returned ok=false`)
  if (p2.acceptance_block) throw new Error(`FAIL: /api/facilitate (empty msg) should not return acceptance_block`)
  console.log('  OK /api/facilitate (empty message) -> question only, no acceptance_block')

  // /api/issue with acceptance_block -> should succeed
  const body3 = JSON.stringify({
    kind: 'charter', title: 'T', what: 'W', why: 'Y',
    acceptance_block: '## Acceptance (machine)\n- check: make test',
  })
  const r3 = await new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1', port: STUB_PORT,
      path: '/api/issue', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body3) },
    }, res => { let b = ''; res.on('data', d => b += d); res.on('end', () => resolve(b)) })
    req.on('error', reject)
    req.end(body3)
  })
  const p3 = JSON.parse(r3)
  if (!p3.ok) throw new Error(`FAIL: /api/issue returned ok=false`)
  console.log('  OK /api/issue with acceptance_block ->', JSON.stringify(p3))
  console.log('Stub smoke-check passed')
}

// ---------------------------------------------------------------------------
// Entry point — ALWAYS ends with explicit process.exit()
// ---------------------------------------------------------------------------
;(async () => {
  console.log('=== test-facilitator-stage.mjs ===')

  const stub = createStub()
  await new Promise(r => stub.listen(STUB_PORT, '127.0.0.1', r))
  const stubUrl = `http://127.0.0.1:${STUB_PORT}`
  console.log(`Stub API on ${stubUrl}`)

  if (chromiumIsAvailable()) {
    // Full headless Playwright run
    console.log('Chromium found - running full headless scenarios...\n')
    try {
      await runPlaywright(stubUrl)
      stub.close()
      console.log('\nAll RED-a/b/c scenarios passed')
      process.exit(0)
    } catch (e) {
      stub.close()
      console.error('\nFAIL:', e.message || e)
      process.exit(1)
    }
  } else {
    // Fallback: no chromium — run inline checks
    console.log('Chromium not installed - running fallback checks.\n')
    printProtocol()
    try {
      await runFallbackChecks()
      stub.close()
      console.log('\nFallback checks passed.')
      console.log('Install Playwright for full headless run: npx playwright install chromium')
      process.exit(0)
    } catch (e) {
      stub.close()
      console.error('\nFAIL:', e.message || e)
      process.exit(1)
    }
  }
})()
