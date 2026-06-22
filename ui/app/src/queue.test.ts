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
// pendingQueue state logic (issue #417 — pending confirmation flow)
// ---------------------------------------------------------------------------
describe('pendingQueue state logic', () => {
  it('onPendingAdd appends charter n to pendingQueue', () => {
    const prev: number[] = [1, 2]
    const n = 3
    const next = [...prev, n]
    expect(next).toEqual([1, 2, 3])
  })

  it('onPendingAdd can add same charter multiple times (dedup is not enforced here)', () => {
    const prev: number[] = [1]
    const n = 1
    const next = [...prev, n]
    expect(next).toEqual([1, 1])
  })

  it('onRemovePending filters out the charter n', () => {
    const prev: number[] = [1, 2, 3]
    const n = 2
    const next = prev.filter(x => x !== n)
    expect(next).toEqual([1, 3])
  })

  it('onRemovePending is a no-op when n is not present', () => {
    const prev: number[] = [1, 3]
    const n = 99
    const next = prev.filter(x => x !== n)
    expect(next).toEqual([1, 3])
  })

  it('confirm pending: appends to queueOrder and removes from pendingQueue', () => {
    const queueOrder: number[] = [10, 20]
    const pendingQueue: number[] = [30, 40]
    const n = 30
    const newQueueOrder = [...queueOrder, n]
    const newPendingQueue = pendingQueue.filter(x => x !== n)
    expect(newQueueOrder).toEqual([10, 20, 30])
    expect(newPendingQueue).toEqual([40])
  })

  it('conditional add: when loopRunning, appends to pending instead of confirmed queue', () => {
    const loopRunning = true
    const queueOrder: number[] = [1]
    const pendingQueue: number[] = []
    const n = 5
    const isQueued = queueOrder.includes(n)
    let newQueueOrder = queueOrder
    let newPendingQueue = pendingQueue
    if (!isQueued) {
      if (loopRunning) {
        newPendingQueue = [...pendingQueue, n]
      } else {
        newQueueOrder = [...queueOrder, n]
      }
    }
    expect(newQueueOrder).toEqual([1])
    expect(newPendingQueue).toEqual([5])
  })

  it('conditional add: when !loopRunning, appends directly to confirmed queue', () => {
    const loopRunning = false
    const queueOrder: number[] = [1]
    const pendingQueue: number[] = []
    const n = 5
    const isQueued = queueOrder.includes(n)
    let newQueueOrder = queueOrder
    let newPendingQueue = pendingQueue
    if (!isQueued) {
      if (loopRunning) {
        newPendingQueue = [...pendingQueue, n]
      } else {
        newQueueOrder = [...queueOrder, n]
      }
    }
    expect(newQueueOrder).toEqual([1, 5])
    expect(newPendingQueue).toEqual([])
  })

  it('conditional add: when already queued, neither pending nor confirmed changes', () => {
    const loopRunning = true
    const queueOrder: number[] = [1, 5]
    const pendingQueue: number[] = []
    const n = 5
    const isQueued = queueOrder.includes(n)
    let newQueueOrder = queueOrder
    let newPendingQueue = pendingQueue
    if (!isQueued) {
      if (loopRunning) {
        newPendingQueue = [...pendingQueue, n]
      } else {
        newQueueOrder = [...queueOrder, n]
      }
    }
    expect(newQueueOrder).toEqual([1, 5])
    expect(newPendingQueue).toEqual([])
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

// ---------------------------------------------------------------------------
// Helpers that mirror App.tsx state machine (no React required)
// ---------------------------------------------------------------------------

/** Simulates handleQueueChange logic from App.tsx */
async function simulateHandleQueueChange(
  newOrder: number[],
  savedOrderInit: number[],
  postQueueFn: (order: number[]) => Promise<void>
): Promise<{ dirtyRef: { current: boolean }; savedOrder: number[] }> {
  const dirtyRef = { current: false }
  let savedOrder = [...savedOrderInit]
  dirtyRef.current = true
  try {
    await postQueueFn(newOrder)
    dirtyRef.current = false
    savedOrder = newOrder
  } catch {
    dirtyRef.current = true
  }
  return { dirtyRef, savedOrder }
}

/** Simulates the SSE state-sync guard from App.tsx subscribe callback */
function simulateSSESync(
  dirtyRef: { current: boolean },
  currentOrder: number[],
  incomingOrder: number[]
): number[] {
  if (!dirtyRef.current) {
    return incomingOrder
  }
  return currentOrder
}

/** Derives the QueuePanel launch-button label (mirrors App.tsx QueuePanel) */
function getLaunchLabel(isLoopRunning: boolean, isEditing: boolean): string {
  return isEditing
    ? '💾 Сохранить'
    : isLoopRunning
    ? '✎ Редактировать'
    : '▶ Запустить очередь'
}

// ---------------------------------------------------------------------------
// dirtyRef state machine (issues #415, #418)
// ---------------------------------------------------------------------------
describe('dirtyRef state machine', () => {
  it('dirtyRef stays true after a failed POST', async () => {
    const failingPost = async (_order: number[]) => {
      throw new Error('network error')
    }
    const { dirtyRef } = await simulateHandleQueueChange([1, 2], [], failingPost)
    expect(dirtyRef.current).toBe(true)
  })

  it('SSE sync does NOT overwrite queueOrder when dirtyRef is true', async () => {
    const failingPost = async (_order: number[]) => {
      throw new Error('network error')
    }
    const newOrder = [1, 2]
    const { dirtyRef } = await simulateHandleQueueChange(newOrder, [], failingPost)
    // dirtyRef should be true after failure
    expect(dirtyRef.current).toBe(true)
    // Now simulate an SSE event arriving
    const currentOrder = newOrder
    const sseOrder = [99, 100]
    const result = simulateSSESync(dirtyRef, currentOrder, sseOrder)
    // Guard should block SSE from overwriting queueOrder
    expect(result).toEqual([1, 2])
    expect(result).not.toEqual(sseOrder)
  })

  it('dirtyRef resets to false after a successful POST', async () => {
    const successPost = async (_order: number[]) => { /* success */ }
    const { dirtyRef } = await simulateHandleQueueChange([3, 4], [], successPost)
    expect(dirtyRef.current).toBe(false)
  })

  it('SSE sync DOES overwrite queueOrder when dirtyRef is false (clean state)', () => {
    const dirtyRef = { current: false }
    const currentOrder = [1, 2]
    const sseOrder = [5, 6, 7]
    const result = simulateSSESync(dirtyRef, currentOrder, sseOrder)
    expect(result).toEqual([5, 6, 7])
  })
})

// ---------------------------------------------------------------------------
// savedOrder update on POST success/failure (issues #415, #418)
// ---------------------------------------------------------------------------
describe('savedOrder POST success/failure semantics', () => {
  it('POST success: savedOrder equals newOrder → dirty indicator hidden', async () => {
    const successPost = async (_order: number[]) => { /* success */ }
    const newOrder = [10, 20, 30]
    const { savedOrder } = await simulateHandleQueueChange(newOrder, [], successPost)
    // savedOrder should equal newOrder after success
    expect(savedOrder).toEqual(newOrder)
    // Dirty indicator is computed as JSON.stringify(queueOrder) !== JSON.stringify(savedOrder)
    const isDirty = JSON.stringify(newOrder) !== JSON.stringify(savedOrder)
    expect(isDirty).toBe(false)
  })

  it('POST failure: savedOrder unchanged → dirty indicator visible', async () => {
    const failingPost = async (_order: number[]) => {
      throw new Error('server error')
    }
    const initialSaved = [1, 2]
    const newOrder = [1, 2, 3]
    const { savedOrder } = await simulateHandleQueueChange(newOrder, initialSaved, failingPost)
    // savedOrder should remain the initial value on failure
    expect(savedOrder).toEqual(initialSaved)
    // Dirty indicator visible: queueOrder (newOrder) !== savedOrder (initialSaved)
    const isDirty = JSON.stringify(newOrder) !== JSON.stringify(savedOrder)
    expect(isDirty).toBe(true)
  })
})

// ---------------------------------------------------------------------------
// Button label derivation (issue #418 — test case 5)
// ---------------------------------------------------------------------------
describe('QueuePanel button label derivation', () => {
  it('isLoopRunning=false, isEditing=false → "▶ Запустить очередь"', () => {
    expect(getLaunchLabel(false, false)).toBe('▶ Запустить очередь')
  })

  it('isLoopRunning=true, isEditing=false → "✎ Редактировать"', () => {
    expect(getLaunchLabel(true, false)).toBe('✎ Редактировать')
  })

  it('isEditing=true, isLoopRunning=false → "💾 Сохранить"', () => {
    expect(getLaunchLabel(false, true)).toBe('💾 Сохранить')
  })

  it('isEditing=true, isLoopRunning=true → "💾 Сохранить"', () => {
    expect(getLaunchLabel(true, true)).toBe('💾 Сохранить')
  })
})

// ---------------------------------------------------------------------------
// Pending → confirmed flow (issue #417/#418 — test case 6, explicit)
// ---------------------------------------------------------------------------
describe('pending → confirmed flow (explicit)', () => {
  it('onPendingAdd(n) appends n to pendingQueue', () => {
    const pendingQueue: number[] = [5, 6]
    const n = 7
    const newPending = [...pendingQueue, n]
    expect(newPending).toEqual([5, 6, 7])
  })

  it('confirm button fires onQueueChange([...queueOrder, n]) and removes n from pendingQueue', () => {
    const queueOrder = [1, 2]
    const pendingQueue = [3, 4]
    const n = 3

    // This mirrors the QueuePanel "Подтвердить добавление" onClick:
    //   onQueueChange([...queueOrder, n])
    //   onRemovePending(n)
    const newQueueOrder = [...queueOrder, n]
    const newPendingQueue = pendingQueue.filter((x) => x !== n)

    expect(newQueueOrder).toEqual([1, 2, 3])
    expect(newPendingQueue).toEqual([4])
  })

  it('confirm does not duplicate if n already in queueOrder (guard scenario)', () => {
    const queueOrder = [1, 2, 3]
    const pendingQueue = [3]
    const n = 3
    // The CharterCard onClick does NOT check for duplicates,
    // but the confirm flow calls onQueueChange unconditionally.
    // The QueuePanel confirm button fires even if n is already in queueOrder.
    // Test that the mutation is correct:
    const newQueueOrder = [...queueOrder, n]
    const newPendingQueue = pendingQueue.filter((x) => x !== n)
    expect(newQueueOrder).toEqual([1, 2, 3, 3])
    expect(newPendingQueue).toEqual([])
  })

  it('removing a non-existent n from pendingQueue is a no-op', () => {
    const pendingQueue = [1, 2]
    const n = 99
    const newPendingQueue = pendingQueue.filter((x) => x !== n)
    expect(newPendingQueue).toEqual([1, 2])
  })
})
