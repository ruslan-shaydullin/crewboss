export type Task = {
  n: number
  kind: 'charter' | 'leaf'
  state: string
  title: string
  labels: string[]
  cost?: number | null
  pr?: string
  phase?: string | null
  charter?: number | null
}
export type Agent = {
  task: number | null
  pid?: number
  role: string
  phase: string
  title: string
  started: string
}
export type State = {
  board: Task[]
  agents: Agent[]
  budget: { spent: number; cap: number; runs: unknown[] }
  flags: { paused: boolean; killed: boolean }
  autonomy: { repo: string }
}

const KURL = 'cb_api'
const KTOK = 'cb_token'
export const config = {
  get url() { return localStorage.getItem(KURL) || 'http://127.0.0.1:8787' },
  set url(v: string) { localStorage.setItem(KURL, v) },
  get token() { return localStorage.getItem(KTOK) || '' },
  set token(v: string) { localStorage.setItem(KTOK, v) },
}

export async function fetchState(): Promise<State | null> {
  try {
    const r = await fetch(config.url + '/api/state', { headers: { Authorization: 'Bearer ' + config.token } })
    if (!r.ok) return null
    return (await r.json()) as State
  } catch {
    return null
  }
}

/** SSE (token in query — EventSource can't set headers) + slow authed poll fallback. */
export function subscribe(onState: (s: State) => void, onConn: (ok: boolean) => void): () => void {
  let es: EventSource | null = null
  try {
    es = new EventSource(config.url + '/api/events?token=' + encodeURIComponent(config.token))
    es.addEventListener('state', (e) => { onConn(true); onState(JSON.parse((e as MessageEvent).data)) })
    es.onerror = () => onConn(false)
  } catch { /* fall through to poll */ }
  const poll = setInterval(async () => {
    const s = await fetchState()
    if (s) { onConn(true); onState(s) } else onConn(false)
  }, 8000)
  return () => { es?.close(); clearInterval(poll) }
}

export type TaskDetail = {
  n: number
  status: { phase?: string; cost_usd?: number; pr?: string; role?: string; exit_code?: string }
  alive: boolean
  started: string
  prompt: string
  log: string
  body?: string
}
export async function fetchTask(n: number): Promise<TaskDetail | null> {
  try {
    const r = await fetch(config.url + '/api/task/' + n, { headers: { Authorization: 'Bearer ' + config.token } })
    if (!r.ok) return null
    return (await r.json()) as TaskDetail
  } catch { return null }
}

export type IssuePayload =
  | { kind: 'charter'; title: string; what: string; why: string; scope?: string; constraints?: string; acceptance?: string; acceptance_block?: string }
  | { kind: 'task'; title: string; description: string; charter: number; depends_on?: string; acceptance_block?: string }

export type FacilitateMessage = { role: 'user' | 'facilitator'; content: string }
export type FacilitateResult = { ok: boolean; message: string; acceptance_block?: string }
export async function facilitateMessage(
  kind: 'charter' | 'task',
  draft: Record<string, unknown>,
  message: string,
  history: FacilitateMessage[]
): Promise<FacilitateResult> {
  try {
    const r = await fetch(config.url + '/api/facilitate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + config.token },
      body: JSON.stringify({ kind, draft, message, history }),
    })
    if (!r.ok) return { ok: false, message: 'Facilitator backend error: ' + r.status }
    return (await r.json()) as FacilitateResult
  } catch (e) {
    return { ok: false, message: 'Facilitator unavailable: ' + String(e) }
  }
}

export type IssueResult = { ok: boolean; msg: string; number?: number }

export async function createIssue(payload: IssuePayload): Promise<IssueResult> {
  try {
    const r = await fetch(config.url + '/api/issue', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + config.token },
      body: JSON.stringify(payload),
    })
    return (await r.json()) as IssueResult
  } catch (e) {
    return { ok: false, msg: 'request failed: ' + e }
  }
}

export type IssueComment = { id: string; author: string; created: string; body: string }
export async function fetchComments(n: number): Promise<IssueComment[]> {
  try {
    const r = await fetch(config.url + '/api/comments/' + n, { headers: { Authorization: 'Bearer ' + config.token } })
    if (!r.ok) return []
    const data = (await r.json()) as { ok: boolean; comments: IssueComment[] }
    return data.ok ? data.comments : []
  } catch { return [] }
}

export async function deleteComment(n: number, commentId: string): Promise<CmdResult> {
  try {
    const r = await fetch(config.url + '/api/command', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + config.token },
      body: JSON.stringify({ action: 'delete-comment', number: n, comment_id: commentId }),
    })
    return (await r.json()) as CmdResult
  } catch (e) {
    return { ok: false, msg: 'request failed: ' + e }
  }
}

export async function resolveDecision(n: number, decisionText: string): Promise<CmdResult> {
  try {
    const r = await fetch(config.url + '/api/command', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + config.token },
      body: JSON.stringify({ action: 'resolve-decision', number: n, decision_text: decisionText }),
    })
    return (await r.json()) as CmdResult
  } catch (e) {
    return { ok: false, msg: 'request failed: ' + e }
  }
}

export async function setCheck(n: number, index: number, checked: boolean): Promise<CmdResult> {
  try {
    const r = await fetch(config.url + '/api/command', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + config.token },
      body: JSON.stringify({ action: 'set-check', number: n, index, checked }),
    })
    return (await r.json()) as CmdResult
  } catch (e) {
    return { ok: false, msg: 'request failed: ' + e }
  }
}

export type CmdResult = { ok: boolean; msg: string }
export async function command(action: string, number?: number, comment?: string): Promise<CmdResult> {
  try {
    const payload: Record<string, unknown> = { action, number }
    if (comment !== undefined) payload.comment = comment
    const r = await fetch(config.url + '/api/command', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + config.token },
      body: JSON.stringify(payload),
    })
    return (await r.json()) as CmdResult
  } catch (e) {
    return { ok: false, msg: 'request failed: ' + e }
  }
}
