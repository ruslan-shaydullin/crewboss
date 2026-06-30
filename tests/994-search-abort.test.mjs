// 994-search-abort.test.mjs — behavioral "search must not hang" proof
// (charter #994 / qa leaf #1059). Zero external deps: node's built-in test
// runner + assert only. Runnable on stock node v18 with NO npm install:
//
//     node --test tests/994-search-abort.test.mjs
//
// WHY this file exists: search.test.ts is the canonical vitest unit test, but
// vitest is NOT installable in the gate/executor box (no npm registry). So the
// *behavioral* no-hang proof lives here, exercising the REAL frontend abort
// code (ui/app/src/searchAbort.mjs) with zero registry dependency.
//
// MERGEABLE-FIRST CAPABILITY PROBE (red->green): this leaf is created FIRST and
// merges BEFORE the frontend abort module lands. We `await import(...)` the
// module inside try/catch; if it (or the expected export) is absent we t.skip()
// so the file still exits 0 today, then flips to real assertions once the
// frontend leaf ships searchAbort.mjs.
//
// Contract exercised (provided by the frontend leaf's searchAbort.mjs):
//   * fetchWithTimeout(url, init, timeoutMs): aborts a stalled fetch within
//     ~timeoutMs and REJECTS (does not hang). Honors AbortController/signal.
//   * (optional) searchBoard(q): maps a stalled backend to null within timeout.

import { test } from 'node:test'
import assert from 'node:assert/strict'

const MODULE_URL = new URL('../ui/app/src/searchAbort.mjs', import.meta.url)

async function loadModule() {
  try {
    return await import(MODULE_URL.href)
  } catch {
    return null // module not landed yet (frontend leaf pending)
  }
}

// A fetch stub that NEVER resolves on its own — it only ever settles when its
// AbortSignal fires. If the wrapper does not abort, the awaiting test would hang
// (and the runner would time out → red), which is exactly the bug we guard.
function makeNeverResolvingFetch(observed) {
  return (_url, init = {}) =>
    new Promise((_resolve, reject) => {
      const signal = init.signal
      if (signal) {
        if (signal.aborted) {
          observed.aborted = true
          reject(new DOMException('Aborted', 'AbortError'))
          return
        }
        signal.addEventListener('abort', () => {
          observed.aborted = true
          reject(new DOMException('Aborted', 'AbortError'))
        })
      }
      // No signal wired → never settles → caller hangs (the defect).
    })
}

test('fetchWithTimeout aborts a stalled fetch within ~timeout and rejects (no hang)', async (t) => {
  const mod = await loadModule()
  if (!mod || typeof mod.fetchWithTimeout !== 'function') {
    t.skip('ui/app/src/searchAbort.mjs#fetchWithTimeout not present yet (frontend leaf pending)')
    return
  }
  const origFetch = globalThis.fetch
  const observed = { aborted: false }
  globalThis.fetch = makeNeverResolvingFetch(observed)
  try {
    const TIMEOUT = 50
    const start = Date.now()
    await assert.rejects(
      () => mod.fetchWithTimeout('http://127.0.0.1:9/api/search?q=x', {}, TIMEOUT),
      'fetchWithTimeout must reject/abort a stalled fetch — it must NOT hang'
    )
    const elapsed = Date.now() - start
    // Must settle close to the timeout, decisively under any UI-perceptible hang.
    assert.ok(elapsed < 2000, `must abort within ~timeout, took ${elapsed}ms`)
    assert.ok(observed.aborted, 'the wrapper must signal AbortController on timeout')
  } finally {
    globalThis.fetch = origFetch
  }
})

test('fetchWithTimeout returns the response for a fast ok fetch', async (t) => {
  const mod = await loadModule()
  if (!mod || typeof mod.fetchWithTimeout !== 'function') {
    t.skip('ui/app/src/searchAbort.mjs#fetchWithTimeout not present yet (frontend leaf pending)')
    return
  }
  const origFetch = globalThis.fetch
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ results: [] }),
    text: async () => '{"results":[]}',
  })
  try {
    const r = await mod.fetchWithTimeout('http://127.0.0.1:9/api/search?q=y', {}, 1000)
    assert.equal(r.ok, true)
    assert.equal(r.status, 200)
  } finally {
    globalThis.fetch = origFetch
  }
})

// The per-test `timeout` is the real no-hang anchor: node:test has NO default
// per-test timeout, so a genuinely hanging searchBoard would stall forever; the
// 20s budget makes that fail deterministically. We do NOT couple to the frontend
// leaf's exact client-timeout value — only that it is bounded (resolves to null).
// If the impl accepts an explicit timeout arg we pass a tiny one to keep CI fast.
test('searchBoard maps a stalled backend to null within the timeout (no hang)', { timeout: 20000 }, async (t) => {
  const mod = await loadModule()
  if (!mod || typeof mod.searchBoard !== 'function') {
    t.skip('ui/app/src/searchAbort.mjs#searchBoard not exported (frontend leaf pending / lives in api.ts)')
    return
  }
  const origFetch = globalThis.fetch
  const observed = { aborted: false }
  globalThis.fetch = makeNeverResolvingFetch(observed)
  try {
    const start = Date.now()
    const result = mod.searchBoard.length >= 2
      ? await mod.searchBoard('stalls-forever', 100)   // tiny timeout if supported
      : await mod.searchBoard('stalls-forever')        // else its own default
    const elapsed = Date.now() - start
    assert.equal(result, null, 'a stalled backend must resolve searchBoard() to null')
    assert.ok(elapsed < 19000, `searchBoard must be bounded (not hang), took ${elapsed}ms`)
  } finally {
    globalThis.fetch = origFetch
  }
})
