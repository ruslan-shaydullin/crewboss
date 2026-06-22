/**
 * queue.test.ts — unit tests for the Queue Cockpit feature (issue #282)
 *
 * Tests:
 *   - postQueue sends POST /api/queue with correct body and Authorization header
 *   - State type accepts queue field
 *   - Queue order operations (add, remove, reorder) logic
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { postQueue, config } from './api'

// ---------------------------------------------------------------------------
// Mock fetch
// ---------------------------------------------------------------------------
const mockFetch = vi.fn()
vi.stubGlobal('fetch', mockFetch)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function makeFetchOk() {
  mockFetch.mockResolvedValue({
    ok: true,
    json: async () => ({}),
    text: async () => '',
  })
}

beforeEach(() => {
  vi.clearAllMocks()
  makeFetchOk()
})

// ---------------------------------------------------------------------------
// postQueue tests
// ---------------------------------------------------------------------------
describe('postQueue', () => {
  it('sends POST /api/queue with correct URL', async () => {
    await postQueue([1, 2, 3])
    expect(mockFetch).toHaveBeenCalledOnce()
    const [url] = mockFetch.mock.calls[0] as [string, RequestInit]
    expect(url).toBe(config.url + '/api/queue')
  })

  it('sends POST method', async () => {
    await postQueue([1])
    const [, opts] = mockFetch.mock.calls[0] as [string, RequestInit]
    expect(opts.method).toBe('POST')
  })

  it('sends correct JSON body with order', async () => {
    const order = [10, 20, 30]
    await postQueue(order)
    const [, opts] = mockFetch.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(opts.body as string) as { order: number[] }
    expect(body.order).toEqual(order)
  })

  it('sends Authorization header with Bearer token', async () => {
    await postQueue([])
    const [, opts] = mockFetch.mock.calls[0] as [string, RequestInit]
    const headers = opts.headers as Record<string, string>
    expect(headers['Authorization']).toBe('Bearer ' + config.token)
  })

  it('sends Content-Type application/json', async () => {
    await postQueue([])
    const [, opts] = mockFetch.mock.calls[0] as [string, RequestInit]
    const headers = opts.headers as Record<string, string>
    expect(headers['Content-Type']).toBe('application/json')
  })

  it('handles empty order array', async () => {
    await expect(postQueue([])).resolves.toBeUndefined()
    const [, opts] = mockFetch.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(opts.body as string) as { order: number[] }
    expect(body.order).toEqual([])
  })

  it('handles single-item order', async () => {
    await postQueue([42])
    const [, opts] = mockFetch.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(opts.body as string) as { order: number[] }
    expect(body.order).toEqual([42])
  })
})

// ---------------------------------------------------------------------------
// State type — queue field acceptance tests
// ---------------------------------------------------------------------------
describe('State type queue field', () => {
  it('accepts queue with order array', () => {
    // Type-level test: if this compiles, the type accepts queue
    const state: import('./api').State = {
      board: [],
      agents: [],
      budget: { spent: 0, cap: 100, runs: [] },
      flags: { paused: false, killed: false },
      autonomy: { repo: 'test/repo' },
      queue: { order: [1, 2, 3] },
    }
    expect(state.queue?.order).toEqual([1, 2, 3])
  })

  it('accepts queue as null', () => {
    const state: import('./api').State = {
      board: [],
      agents: [],
      budget: { spent: 0, cap: 100, runs: [] },
      flags: { paused: false, killed: false },
      autonomy: { repo: 'test/repo' },
      queue: null,
    }
    expect(state.queue).toBeNull()
  })

  it('accepts missing queue (undefined)', () => {
    const state: import('./api').State = {
      board: [],
      agents: [],
      budget: { spent: 0, cap: 100, runs: [] },
      flags: { paused: false, killed: false },
      autonomy: { repo: 'test/repo' },
    }
    expect(state.queue).toBeUndefined()
  })

  it('queue?.order ?? [] returns [] when queue is null', () => {
    const state: import('./api').State = {
      board: [],
      agents: [],
      budget: { spent: 0, cap: 100, runs: [] },
      flags: { paused: false, killed: false },
      autonomy: { repo: 'test/repo' },
      queue: null,
    }
    expect(state.queue?.order ?? []).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// postQueue error-handling tests (issue #415 — throw on !response.ok)
// ---------------------------------------------------------------------------
describe('postQueue HTTP error handling', () => {
  it('throws when response status is 500', async () => {
    mockFetch.mockResolvedValue({ ok: false, status: 500, json: async () => ({}), text: async () => '' })
    await expect(postQueue([1, 2])).rejects.toThrow('postQueue failed: 500')
  })

  it('throws when response status is 404', async () => {
    mockFetch.mockResolvedValue({ ok: false, status: 404, json: async () => ({}), text: async () => '' })
    await expect(postQueue([1])).rejects.toThrow('postQueue failed: 404')
  })

  it('does NOT throw when response is ok', async () => {
    makeFetchOk()
    await expect(postQueue([1, 2, 3])).resolves.toBeUndefined()
  })
})

// ---------------------------------------------------------------------------
// savedOrder dirty-check logic (issue #415 — dirty indicator)
// ---------------------------------------------------------------------------
describe('savedOrder dirty-check logic', () => {
  it('is dirty when queueOrder differs from savedOrder', () => {
    const queueOrder = [1, 2, 3]
    const savedOrder = [1, 2]
    const isDirty = JSON.stringify(queueOrder) !== JSON.stringify(savedOrder)
    expect(isDirty).toBe(true)
  })

  it('is dirty when order is the same elements but different sequence', () => {
    const queueOrder = [2, 1, 3]
    const savedOrder = [1, 2, 3]
    const isDirty = JSON.stringify(queueOrder) !== JSON.stringify(savedOrder)
    expect(isDirty).toBe(true)
  })

  it('is clean when queueOrder matches savedOrder exactly', () => {
    const queueOrder = [1, 2, 3]
    const savedOrder = [1, 2, 3]
    const isDirty = JSON.stringify(queueOrder) !== JSON.stringify(savedOrder)
    expect(isDirty).toBe(false)
  })

  it('is clean when both are empty', () => {
    const queueOrder: number[] = []
    const savedOrder: number[] = []
    const isDirty = JSON.stringify(queueOrder) !== JSON.stringify(savedOrder)
    expect(isDirty).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// isLoopRunning derivation (issue #415 — derive from SSE state)
// ---------------------------------------------------------------------------
describe('isLoopRunning derivation', () => {
  it('returns false when state is null', () => {
    const state = null as import('./api').State | null
    const isLoopRunning = state?.loop?.running ?? false
    expect(isLoopRunning).toBe(false)
  })

  it('returns false when loop field is absent', () => {
    const state: import('./api').State = {
      board: [], agents: [], budget: { spent: 0, cap: 0, runs: [] },
      flags: { paused: false, killed: false }, autonomy: { repo: '' },
    }
    const isLoopRunning = state?.loop?.running ?? false
    expect(isLoopRunning).toBe(false)
  })

  it('returns true when loop.running is true', () => {
    const state: import('./api').State = {
      board: [], agents: [], budget: { spent: 0, cap: 0, runs: [] },
      flags: { paused: false, killed: false }, autonomy: { repo: '' },
      loop: { running: true, integrate: false, max_ticks: 10, max_parallel: 4, stage: 'idle' },
    }
    const isLoopRunning = state?.loop?.running ?? false
    expect(isLoopRunning).toBe(true)
  })

  it('returns false when loop.running is false', () => {
    const state: import('./api').State = {
      board: [], agents: [], budget: { spent: 0, cap: 0, runs: [] },
      flags: { paused: false, killed: false }, autonomy: { repo: '' },
      loop: { running: false, integrate: true, max_ticks: 5, max_parallel: 2, stage: 'idle' },
    }
    const isLoopRunning = state?.loop?.running ?? false
    expect(isLoopRunning).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// Queue order manipulation logic (pure functions mirroring App.tsx logic)
// ---------------------------------------------------------------------------
describe('queue order manipulation', () => {
  it('add to queue: appends charter n if not present', () => {
    const queueOrder = [1, 2]
    const charterN = 3
    const isQueued = queueOrder.includes(charterN)
    const newOrder = isQueued ? queueOrder : [...queueOrder, charterN]
    expect(newOrder).toEqual([1, 2, 3])
  })

  it('add to queue: does not duplicate if already present', () => {
    const queueOrder = [1, 2, 3]
    const charterN = 2
    const isQueued = queueOrder.includes(charterN)
    const newOrder = isQueued ? queueOrder : [...queueOrder, charterN]
    expect(newOrder).toEqual([1, 2, 3])
  })

  it('remove from queue: removes by index', () => {
    const queueOrder = [10, 20, 30]
    const removeIdx = 1
    const newOrder = queueOrder.filter((_, i) => i !== removeIdx)
    expect(newOrder).toEqual([10, 30])
  })

  it('move up: swaps item with predecessor', () => {
    const queueOrder = [10, 20, 30]
    const idx = 1
    const newOrder = [...queueOrder]
    ;[newOrder[idx - 1], newOrder[idx]] = [newOrder[idx], newOrder[idx - 1]]
    expect(newOrder).toEqual([20, 10, 30])
  })

  it('move down: swaps item with successor', () => {
    const queueOrder = [10, 20, 30]
    const idx = 1
    const newOrder = [...queueOrder]
    ;[newOrder[idx], newOrder[idx + 1]] = [newOrder[idx + 1], newOrder[idx]]
    expect(newOrder).toEqual([10, 30, 20])
  })

  it('move up at idx=0 is a no-op (boundary guard)', () => {
    const queueOrder = [10, 20, 30]
    const idx = 0
    const dir = -1
    const target = idx + dir
    let newOrder = [...queueOrder]
    if (target >= 0 && target < newOrder.length) {
      ;[newOrder[idx], newOrder[target]] = [newOrder[target], newOrder[idx]]
    }
    expect(newOrder).toEqual([10, 20, 30])
  })

  it('move down at last idx is a no-op (boundary guard)', () => {
    const queueOrder = [10, 20, 30]
    const idx = 2
    const dir = 1
    const target = idx + dir
    let newOrder = [...queueOrder]
    if (target >= 0 && target < newOrder.length) {
      ;[newOrder[idx], newOrder[target]] = [newOrder[target], newOrder[idx]]
    }
    expect(newOrder).toEqual([10, 20, 30])
  })
})
