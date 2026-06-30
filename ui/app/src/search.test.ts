/**
 * search.test.ts — unit tests for searchBoard() in api.ts (issue #825)
 *
 * Tests:
 *   1  URL: searchBoard('foo') calls fetch with /api/search?q=foo
 *   2  Method: fetch is called with GET (no explicit method or method:'GET')
 *   3  Authorization header: Bearer token present
 *   4  Happy path: ok response → returns Task[]
 *   5  Non-ok response (401) → returns null
 *   6  Network error (fetch throws) → returns null
 *   7  Empty query string → still calls fetch with q= (guard lives in App.tsx)
 *   8  Special chars encoded: '#42' → q=%2342
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { searchBoard, config } from './api'

// ---------------------------------------------------------------------------
// Mock fetch
// ---------------------------------------------------------------------------
const mockFetch = vi.fn()
vi.stubGlobal('fetch', mockFetch)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function makeFetchOk(body: unknown = { results: [] }) {
  mockFetch.mockResolvedValue({
    ok: true,
    json: async () => body,
    text: async () => JSON.stringify(body),
  })
}

function makeFetchNotOk(status = 401) {
  mockFetch.mockResolvedValue({
    ok: false,
    status,
    json: async () => ({}),
    text: async () => '',
  })
}

beforeEach(() => {
  vi.clearAllMocks()
  makeFetchOk()
})

// ---------------------------------------------------------------------------
// Test 1 — URL
// ---------------------------------------------------------------------------
describe('searchBoard URL', () => {
  it('Test 1: calls fetch with config.url + /api/search?q=foo', async () => {
    await searchBoard('foo')
    expect(mockFetch).toHaveBeenCalledOnce()
    const [url] = mockFetch.mock.calls[0] as [string, RequestInit]
    expect(url).toBe(config.url + '/api/search?q=foo')
  })
})

// ---------------------------------------------------------------------------
// Test 2 — Method
// ---------------------------------------------------------------------------
describe('searchBoard method', () => {
  it('Test 2: fetch is called without explicit method (GET) or with method GET', async () => {
    await searchBoard('foo')
    const [, opts] = mockFetch.mock.calls[0] as [string, RequestInit | undefined]
    // GET is the default; impl may omit method or set it explicitly
    const method = opts?.method
    expect(method === undefined || method === 'GET').toBe(true)
  })
})

// ---------------------------------------------------------------------------
// Test 3 — Authorization header
// ---------------------------------------------------------------------------
describe('searchBoard Authorization header', () => {
  it('Test 3: includes Authorization: Bearer <token>', async () => {
    await searchBoard('foo')
    const [, opts] = mockFetch.mock.calls[0] as [string, RequestInit]
    const headers = opts.headers as Record<string, string>
    expect(headers['Authorization']).toBe('Bearer ' + config.token)
  })
})

// ---------------------------------------------------------------------------
// Test 4 — Happy path
// ---------------------------------------------------------------------------
describe('searchBoard happy path', () => {
  it('Test 4: ok response with results array → returns Task[]', async () => {
    const fixture = {
      results: [{ n: 1, kind: 'leaf', state: 'open', title: 'T', labels: [] }],
    }
    makeFetchOk(fixture)
    const result = await searchBoard('T')
    expect(result).toEqual(fixture.results)
  })

  it('Test 4b: ok response with empty results → returns []', async () => {
    makeFetchOk({ results: [] })
    const result = await searchBoard('nothing')
    expect(result).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// Test 5 — Non-ok response
// ---------------------------------------------------------------------------
describe('searchBoard non-ok response', () => {
  it('Test 5: fetch resolves with ok:false (401) → returns null, does not throw', async () => {
    makeFetchNotOk(401)
    const result = await searchBoard('foo')
    expect(result).toBeNull()
  })

  it('Test 5b: fetch resolves with ok:false (500) → returns null', async () => {
    makeFetchNotOk(500)
    const result = await searchBoard('bar')
    expect(result).toBeNull()
  })
})

// ---------------------------------------------------------------------------
// Test 6 — Network error
// ---------------------------------------------------------------------------
describe('searchBoard network error', () => {
  it('Test 6: fetch rejects (network error) → returns null, does not re-throw', async () => {
    mockFetch.mockRejectedValue(new Error('network failure'))
    const result = await searchBoard('foo')
    expect(result).toBeNull()
  })

  it('Test 6b: fetch rejects with TypeError → returns null', async () => {
    mockFetch.mockRejectedValue(new TypeError('Failed to fetch'))
    const result = await searchBoard('bar')
    expect(result).toBeNull()
  })
})

// ---------------------------------------------------------------------------
// Test 7 — Empty query string
// ---------------------------------------------------------------------------
describe('searchBoard empty query', () => {
  it('Test 7: searchBoard("") still calls fetch with q= (guard belongs in App.tsx)', async () => {
    await searchBoard('')
    expect(mockFetch).toHaveBeenCalledOnce()
    const [url] = mockFetch.mock.calls[0] as [string, RequestInit]
    expect(url).toBe(config.url + '/api/search?q=')
  })
})

// ---------------------------------------------------------------------------
// Test 8 — Special chars encoded
// ---------------------------------------------------------------------------
describe('searchBoard special character encoding', () => {
  it('Test 8: searchBoard("#42") calls fetch with q=%2342', async () => {
    await searchBoard('#42')
    const [url] = mockFetch.mock.calls[0] as [string, RequestInit]
    expect(url).toBe(config.url + '/api/search?q=%2342')
  })

  it('Test 8b: searchBoard("#123") calls fetch with q=%23123', async () => {
    await searchBoard('#123')
    const [url] = mockFetch.mock.calls[0] as [string, RequestInit]
    expect(url).toBe(config.url + '/api/search?q=%23123')
  })

  it('Test 8c: searchBoard("a b") calls fetch with encoded space', async () => {
    await searchBoard('a b')
    const [url] = mockFetch.mock.calls[0] as [string, RequestInit]
    expect(url).toBe(config.url + '/api/search?q=' + encodeURIComponent('a b'))
  })
})


// ---------------------------------------------------------------------------
// Test 9 — Abort / no-hang (charter #994 — "search must not hang")
// ---------------------------------------------------------------------------
// The live defect: a stalled backend (HTTP 000, 40s+) made the cockpit search
// hang. The fix wires an AbortController + timeout signal into the search fetch,
// so a never-resolving backend is aborted within the client timeout and
// searchBoard() resolves to null instead of hanging forever.
//
// NOTE: vitest is the canonical runner for this file but is NOT installable in
// the executor/gate box (no npm registry). The BEHAVIORAL no-hang proof that
// runs on stock node v18 with zero deps lives in tests/994-search-abort.test.mjs.
describe('searchBoard abort / no-hang', () => {
  it('Test 9: a stalled backend (fetch never resolves) is aborted within the timeout → null, does NOT hang', async () => {
    vi.useFakeTimers()
    // fetch never resolves on its own; it only settles when its AbortSignal fires.
    mockFetch.mockImplementation((_url: string, init?: RequestInit) => {
      return new Promise((_resolve, reject) => {
        const signal = init?.signal
        if (signal) {
          if (signal.aborted) {
            reject(new DOMException('Aborted', 'AbortError'))
            return
          }
          signal.addEventListener('abort', () => {
            reject(new DOMException('Aborted', 'AbortError'))
          })
        }
        // no signal → would hang; the assertion below would then time out (red).
      })
    })
    const p = searchBoard('stalls-forever')
    // advance past any plausible client timeout; the abort must fire and resolve p.
    await vi.advanceTimersByTimeAsync(60_000)
    const result = await p
    expect(result).toBeNull()
    vi.useRealTimers()
  })

  it('Test 10: searchBoard passes an AbortSignal to fetch (timeout is wired)', async () => {
    makeFetchOk()
    await searchBoard('foo')
    const [, opts] = mockFetch.mock.calls[0] as [string, RequestInit]
    expect(opts.signal).toBeDefined()
  })
})
