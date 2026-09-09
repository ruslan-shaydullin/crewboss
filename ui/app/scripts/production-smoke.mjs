#!/usr/bin/env node
// Verify the release bundle, not Vite's development CSS injection.
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtemp, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { setTimeout as delay } from 'node:timers/promises'
import { chromium } from 'playwright'

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const directory = await mkdtemp(path.join(os.tmpdir(), 'crewboss-ui-production-'))
const port = Number(process.env.CB_PRODUCTION_UI_PORT || 5199)
const origin = `http://127.0.0.1:${port}`
let server
let browser
try {
  const build = spawn(process.execPath, ['build.cjs'], {
    cwd: app, env: { ...process.env, CB_UI_OUT_DIR: directory, VITE_CREWBOSS_DEMO: '' }, stdio: 'inherit',
  })
  assert.equal(await new Promise(resolve => build.once('exit', resolve)), 0, 'Production build failed')
  server = spawn(process.execPath, [path.join(app, 'node_modules/vite/bin/vite.js'),
    'preview', '--host', '127.0.0.1', '--port', String(port), '--strictPort', '--outDir', directory],
  { cwd: app, stdio: ['ignore', 'pipe', 'pipe'] })
  let output = ''
  server.stdout.on('data', data => { output += data })
  server.stderr.on('data', data => { output += data })
  let ready = false
  for (let attempt = 0; attempt < 80; attempt++) {
    if (server.exitCode !== null) throw new Error(output)
    try { ready = (await fetch(origin)).ok } catch { /* starting */ }
    if (ready) break
    await delay(250)
  }
  assert(ready, 'Production preview did not start')
  browser = await chromium.launch({ headless: true,
    ...(process.env.CB_DEMO_BROWSER_EXECUTABLE ? { executablePath: process.env.CB_DEMO_BROWSER_EXECUTABLE } : {}),
  })
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 }, reducedMotion: 'reduce' })
  const unexpected = []
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/*', route => {
    const url = new URL(route.request().url())
    if (url.origin !== origin || url.pathname.startsWith('/api/')) {
      unexpected.push(url.href)
      return route.abort()
    }
    return route.continue()
  })
  await page.goto(origin)
  await page.getByRole('button', { name: 'settings', exact: true }).waitFor()
  assert.equal(await page.locator('[data-testid="demo-badge"]').count(), 0)
  assert.equal(await page.evaluate(() => getComputedStyle(document.querySelector('.hdr')).display), 'flex')
  assert(await page.evaluate(() => [...document.styleSheets].some(sheet => sheet.href?.endsWith('/main.css'))),
    'Generated index must load the emitted stylesheet')
  await page.getByRole('button', { name: 'settings', exact: true }).click()
  await page.getByRole('heading', { name: 'Connection', exact: true }).waitFor()
  assert.equal(await page.getByPlaceholder('CB_API_TOKEN').inputValue(), '')
  assert.equal(await page.evaluate(() => localStorage.getItem('cb_token')), null)
  await page.getByRole('button', { name: 'Close', exact: true }).click()
  await page.getByRole('button', { name: 'Team', exact: true }).click()
  await page.locator('.team').waitFor()
  assert.deepEqual(unexpected, [], 'Disconnected release UI must not request an API')
  assert.deepEqual(errors, [])
  console.log('Production browser checks passed: styled CSS bundle, live connection settings, no demo/token/API calls.')
} finally {
  await browser?.close()
  if (server) {
    server.kill('SIGTERM')
    await new Promise(resolve => { if (server.exitCode !== null) resolve(); else server.once('exit', resolve) })
  }
  await rm(directory, { recursive: true, force: true })
}
