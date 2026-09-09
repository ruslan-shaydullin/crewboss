import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { streamState } from './sse'

const encoder = new TextEncoder()
const response = (body: ReadableStream<Uint8Array>, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  headers: { get: (name: string) => name === 'content-type' ? 'text/event-stream' : null },
  body,
})
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve() }

describe('authenticated event transport', () => {
  let stop: (() => void) | undefined

  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(async () => {
    stop?.()
    stop = undefined
    await flush()
    vi.useRealTimers()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('uses an Authorization header and parses fragmented CRLF and multiline frames', async () => {
    let writer!: ReadableStreamDefaultController<Uint8Array>
    const body = new ReadableStream<Uint8Array>({ start(controller) { writer = controller } })
    const fetchMock = vi.fn().mockResolvedValue(response(body))
    vi.stubGlobal('fetch', fetchMock)
    const state = vi.fn()
    const connection = vi.fn()
    stop = streamState('http://127.0.0.1:8787', 'fixture-secret', state, connection)
    await flush()
    writer.enqueue(encoder.encode(': keepalive\r\nevent: sta'))
    writer.enqueue(encoder.encode('te\r\ndata: {"board":\r\ndata: []}\r\n\r'))
    writer.enqueue(encoder.encode('\n'))
    await flush()
    expect(state).toHaveBeenCalledWith({ board: [] })
    expect(connection).toHaveBeenLastCalledWith(true)
    const [url, options] = fetchMock.mock.calls[0]
    expect(url).toBe('http://127.0.0.1:8787/api/events')
    expect(url).not.toContain('fixture-secret')
    expect(options.headers.Authorization).toBe('Bearer fixture-secret')
    expect(options.credentials).toBe('omit')
    expect(options.redirect).toBe('error')
  })

  it('reconnects after stream completion and polls with the same header', async () => {
    let writer!: ReadableStreamDefaultController<Uint8Array>
    const first = new ReadableStream<Uint8Array>({ start(controller) { writer = controller } })
    const second = new ReadableStream<Uint8Array>()
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(response(first))
      .mockResolvedValueOnce({ ok: true, json: async () => ({ board: ['fallback'] }) })
      .mockResolvedValueOnce(response(second))
    vi.stubGlobal('fetch', fetchMock)
    const state = vi.fn()
    stop = streamState('http://api.example', 'fixture', state, vi.fn())
    await flush()
    writer.close()
    await flush()
    expect(state).toHaveBeenCalledWith({ board: ['fallback'] })
    expect(fetchMock.mock.calls[1][0]).toBe('http://api.example/api/state')
    expect(fetchMock.mock.calls[1][1].headers.Authorization).toBe('Bearer fixture')
    await vi.advanceTimersByTimeAsync(1500)
    expect(fetchMock.mock.calls[2][0]).toBe('http://api.example/api/events')
  })

  it('aborts the stream and suppresses callbacks and reconnect after cleanup', async () => {
    const cancelled = vi.fn()
    const body = new ReadableStream<Uint8Array>({ cancel: cancelled })
    const fetchMock = vi.fn().mockResolvedValue(response(body))
    vi.stubGlobal('fetch', fetchMock)
    const state = vi.fn()
    const connection = vi.fn()
    stop = streamState('http://api.example', 'fixture', state, connection)
    await flush()
    const signal = fetchMock.mock.calls[0][1].signal as AbortSignal
    stop()
    await flush()
    await vi.advanceTimersByTimeAsync(16000)
    expect(signal.aborted).toBe(true)
    expect(cancelled).toHaveBeenCalled()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(state).not.toHaveBeenCalled()
    expect(connection).not.toHaveBeenCalled()
  })

  it('ignores a delayed fallback poll after a reconnected stream delivers newer state', async () => {
    let firstWriter!: ReadableStreamDefaultController<Uint8Array>
    let secondWriter!: ReadableStreamDefaultController<Uint8Array>
    let resolvePoll!: (value: unknown) => void
    const first = new ReadableStream<Uint8Array>({ start(controller) { firstWriter = controller } })
    const second = new ReadableStream<Uint8Array>({ start(controller) { secondWriter = controller } })
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(response(first))
      .mockImplementationOnce(() => new Promise(resolve => { resolvePoll = resolve }))
      .mockResolvedValueOnce(response(second))
    vi.stubGlobal('fetch', fetchMock)
    const state = vi.fn()
    const connection = vi.fn()
    stop = streamState('http://api.example', 'fixture', state, connection)
    await flush()
    firstWriter.close()
    await flush()
    await vi.advanceTimersByTimeAsync(1500)
    secondWriter.enqueue(encoder.encode('event: state\ndata: {"revision":2}\n\n'))
    await flush()
    resolvePoll({ ok: true, json: async () => ({ revision: 1 }) })
    await flush()
    expect(state.mock.calls).toEqual([[{ revision: 2 }]])
    expect(connection).toHaveBeenLastCalledWith(true)
  })

  it('renews its inactivity deadline on keepalives and recovers a half-open stream', async () => {
    let writer!: ReadableStreamDefaultController<Uint8Array>
    const first = new ReadableStream<Uint8Array>({ start(controller) { writer = controller } })
    const fetchMock = vi.fn().mockImplementation((url: string) => {
      if (url.endsWith('/api/state')) return Promise.resolve({ ok: true, json: async () => ({ revision: 2 }) })
      return Promise.resolve(response(fetchMock.mock.calls.length === 1 ? first : new ReadableStream<Uint8Array>()))
    })
    vi.stubGlobal('fetch', fetchMock)
    const state = vi.fn()
    stop = streamState('http://api.example', 'fixture', state, vi.fn())
    await flush()
    writer.enqueue(encoder.encode('event: state\ndata: {"revision":1}\n\n'))
    await flush()
    await vi.advanceTimersByTimeAsync(59000)
    writer.enqueue(encoder.encode(': keepalive\n\n'))
    await flush()
    await vi.advanceTimersByTimeAsync(59000)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1000)
    expect(fetchMock.mock.calls[0][1].signal.aborted).toBe(true)
    expect(state).toHaveBeenLastCalledWith({ revision: 2 })
    await vi.advanceTimersByTimeAsync(1500)
    expect(fetchMock.mock.calls.filter(call => call[0].endsWith('/api/events'))).toHaveLength(2)
  })

  it('aborts pending fallback requests and ignores their late responses', async () => {
    let resolvePoll!: (value: unknown) => void
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({ ok: false, body: null })
      .mockImplementationOnce(() => new Promise(resolve => { resolvePoll = resolve }))
    vi.stubGlobal('fetch', fetchMock)
    const state = vi.fn()
    stop = streamState('http://api.example', 'fixture', state, vi.fn())
    await flush()
    const signal = fetchMock.mock.calls[1][1].signal as AbortSignal
    stop()
    resolvePoll({ ok: true, json: async () => ({ board: [] }) })
    await flush()
    expect(signal.aborted).toBe(true)
    expect(state).not.toHaveBeenCalled()
  })

  it('does not send unauthenticated requests while the operator is disconnected', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    const connection = vi.fn()
    stop = streamState('http://api.example', '', vi.fn(), connection)
    await vi.advanceTimersByTimeAsync(16000)
    expect(fetchMock).not.toHaveBeenCalled()
    expect(connection).toHaveBeenCalledWith(false)
  })
})

describe('session credentials', () => {
  afterEach(() => { localStorage.clear(); vi.resetModules() })

  it('removes previously stored credentials and keeps new tokens only in memory', async () => {
    vi.resetModules()
    localStorage.setItem('cb_token', 'old-persisted-secret')
    const { config } = await import('./api')
    expect(localStorage.getItem('cb_token')).toBeNull()
    expect(config.token).toBe('')
    config.token = 'new-session-secret'
    expect(config.token).toBe('new-session-secret')
    expect(localStorage.getItem('cb_token')).toBeNull()
    vi.resetModules()
    expect((await import('./api')).config.token).toBe('')
  })

  it('does not send ordinary API requests until a token is entered', async () => {
    vi.resetModules()
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    try {
      const { config, fetchState, command } = await import('./api')
      config.token = ''
      expect(await fetchState()).toBeNull()
      expect((await command('run')).ok).toBe(false)
      expect(fetchMock).not.toHaveBeenCalled()
    } finally { vi.unstubAllGlobals() }
  })
})
