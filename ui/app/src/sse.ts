/** Fetch-based SSE transport. Bearer credentials never become part of a URL. */
export function streamState<T>(
  url: string,
  token: string,
  onState: (state: T) => void,
  onConnection: (connected: boolean) => void,
): () => void {
  let stopped = false
  let connected = false
  let streamRevision = 0
  let retry: ReturnType<typeof setTimeout> | undefined
  let idleTimeout: ReturnType<typeof setTimeout> | undefined
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined
  const requests = new Set<AbortController>()
  const headers = { Authorization: 'Bearer ' + token }

  const state = (value: T) => {
    if (!stopped) { onConnection(true); onState(value) }
  }
  const poll = async () => {
    if (stopped || connected || !token) return
    const revision = streamRevision
    const controller = new AbortController()
    requests.add(controller)
    const timeout = setTimeout(() => controller.abort(), 5000)
    try {
      const response = await fetch(url + '/api/state', {
        headers, signal: controller.signal, redirect: 'error', credentials: 'omit',
      })
      if (!response.ok) throw new Error('State request failed')
      const value = await response.json() as T
      // A poll begun during an outage must not overwrite a newer SSE frame,
      // even if that replacement stream has already disconnected again.
      if (!connected && streamRevision === revision) state(value)
    } catch {
      if (!stopped && !connected && streamRevision === revision) onConnection(false)
    } finally {
      clearTimeout(timeout)
      requests.delete(controller)
    }
  }

  const connect = async () => {
    if (stopped || !token) return
    const controller = new AbortController()
    requests.add(controller)
    let activeReader: ReadableStreamDefaultReader<Uint8Array> | undefined
    const renewDeadline = () => {
      clearTimeout(idleTimeout)
      // The API normally emits state or a keepalive every 10 seconds. Allow a
      // full minute for a slow refresh, then recover a half-open connection.
      idleTimeout = setTimeout(() => {
        controller.abort()
        void activeReader?.cancel().catch(() => {})
      }, 60000)
    }
    renewDeadline()
    try {
      const response = await fetch(url + '/api/events', {
        headers, signal: controller.signal, redirect: 'error', credentials: 'omit',
      })
      if (stopped) { await response.body?.cancel(); return }
      if (!response.ok || !response.body
          || !response.headers.get('content-type')?.startsWith('text/event-stream')) {
        await response.body?.cancel()
        throw new Error('Event stream unavailable')
      }
      activeReader = response.body.getReader()
      reader = activeReader
      const decoder = new TextDecoder()
      let pending = ''
      let event = ''
      let data: string[] = []
      let eventSize = 0
      while (!stopped) {
        const chunk = await activeReader.read()
        if (chunk.done) break
        renewDeadline()
        pending += decoder.decode(chunk.value, { stream: true })
        if (pending.length + eventSize > 1024 * 1024) throw new Error('Event stream frame too large')
        let newline: number
        while ((newline = pending.indexOf('\n')) !== -1) {
          const line = pending.slice(0, newline).replace(/\r$/, '')
          pending = pending.slice(newline + 1)
          if (!line) {
            if (event === 'state' && data.length) {
              const value = JSON.parse(data.join('\n')) as T
              connected = true
              streamRevision++
              state(value)
            }
            event = ''; data = []; eventSize = 0
          } else if (!line.startsWith(':')) {
            const separator = line.indexOf(':')
            const field = separator === -1 ? line : line.slice(0, separator)
            const value = separator === -1 ? '' : line.slice(separator + 1).replace(/^ /, '')
            if (field === 'event') event = value
            if (field === 'data') { data.push(value); eventSize += value.length }
          }
        }
      }
    } catch {
      // A disconnected stream falls back to authenticated polling and retries.
    } finally {
      connected = false
      clearTimeout(idleTimeout)
      requests.delete(controller)
      await activeReader?.cancel().catch(() => {})
      activeReader?.releaseLock()
      if (reader === activeReader) reader = undefined
      if (!stopped) {
        onConnection(false)
        void poll()
        retry = setTimeout(() => { void connect() }, 1500)
      }
    }
  }

  const interval = setInterval(() => { void poll() }, 8000)
  if (token) void connect()
  else onConnection(false)
  return () => {
    stopped = true
    clearInterval(interval)
    clearTimeout(retry)
    clearTimeout(idleTimeout)
    requests.forEach(controller => controller.abort())
    requests.clear()
    void reader?.cancel().catch(() => {})
  }
}
