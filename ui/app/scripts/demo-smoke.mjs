#!/usr/bin/env node
// Starts a local fixture-only Vite app, checks interactions, and captures docs.
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdir } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { setTimeout as delay } from 'node:timers/promises'
import { chromium } from 'playwright'

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const project = path.resolve(app, '../..')
const port = Number(process.env.CB_DEMO_PORT || 5198)
const origin = `http://127.0.0.1:${port}`
const images = process.env.CB_DEMO_SCREENSHOT_DIR || path.join(project, 'docs/images')
const server = spawn(process.execPath, [path.join(app, 'node_modules/vite/bin/vite.js'),
  '--host', '127.0.0.1', '--port', String(port), '--strictPort'], {
  cwd: app, env: { ...process.env, VITE_CREWBOSS_DEMO: '1' }, stdio: ['ignore', 'pipe', 'pipe'],
})
let output = ''
server.stdout.on('data', data => { output += data })
server.stderr.on('data', data => { output += data })
let browser
try {
  let ready = false
  for (let attempt = 0; attempt < 80; attempt++) {
    if (server.exitCode !== null) throw new Error('Demo server exited: ' + output)
    try { ready = (await fetch(origin)).ok } catch { /* starting */ }
    if (ready) break
    await delay(250)
  }
  assert(ready, 'Demo server did not start: ' + output)
  browser = await chromium.launch({ headless: true,
    ...(process.env.CB_DEMO_BROWSER_EXECUTABLE ? { executablePath: process.env.CB_DEMO_BROWSER_EXECUTABLE } : {}),
  })
  const page = await browser.newPage({ viewport: { width: 1440, height: 1040 }, reducedMotion: 'reduce' })
  const errors = []
  const external = []
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/*', route => {
    const url = new URL(route.request().url())
    if (url.origin !== origin || url.pathname.startsWith('/api/') || url.searchParams.has('token')) {
      external.push(url.href)
      return route.abort()
    }
    return route.continue()
  })
  await page.goto(origin)
  await page.getByTestId('demo-badge').waitFor()
  await page.getByText('Ship the self-hosted alpha', { exact: true }).first().waitFor()
  assert.equal(await page.evaluate(() => localStorage.getItem('cb_token')), null)
  await page.getByRole('button', { name: 'Pause', exact: true }).click()
  await page.getByRole('button', { name: 'Resume', exact: true }).waitFor()
  await page.getByRole('button', { name: 'Reset demo', exact: true }).click()
  await page.getByRole('button', { name: 'Pause', exact: true }).waitFor()
  await page.getByTestId('queue-item').first().click()
  await page.getByTestId('task-body-prose').waitFor()
  await page.locator('.drawer-head button').click()
  await page.locator('.drawer').waitFor({ state: 'hidden' })
  await page.waitForFunction(() => document.querySelectorAll('.toast').length === 0)
  await mkdir(images, { recursive: true })
  await page.screenshot({ path: path.join(images, 'demo-board.png'), fullPage: true })
  await page.getByRole('button', { name: 'Team', exact: true }).click()
  await page.locator('.team').waitFor()
  await page.getByRole('button', { name: '+ New role', exact: true }).waitFor()
  await page.screenshot({ path: path.join(images, 'demo-team.png'), fullPage: true })
  await page.getByTestId('tab-human').click()
  await page.getByText('Choose the release acceptance checklist', { exact: true }).waitFor()
  assert.deepEqual(external, [], 'Demo attempted API, external, or token-bearing requests')
  assert.deepEqual(errors, [], 'Browser errors')
  console.log('Demo browser checks passed: board, pause/reset, task drawer, team, human decisions, no API calls or stored token.')
  console.log('Screenshots: ' + images)
} finally {
  await browser?.close()
  server.kill('SIGTERM')
  await new Promise(resolve => { if (server.exitCode !== null) resolve(); else server.once('exit', resolve) })
}
