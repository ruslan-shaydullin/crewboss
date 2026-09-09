import type { CmdResult, IssueComment, IssuePayload, State, Task } from './api'
import type { RoleDetail, RoleSave, Team } from './team'

const copy = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T
const initialState = (): State => ({
  autonomy: { repo: 'demo/crewboss-alpha' },
  board: [
    { n: 101, kind: 'charter', title: 'Ship the self-hosted alpha', state: 'approved', labels: ['type:charter'], blast_radius: 'low' },
    { n: 102, kind: 'leaf', charter: 101, title: 'Make runtime configuration portable', state: 'done', labels: ['type:agent'], cost: 2.14 },
    { n: 103, kind: 'leaf', charter: 101, title: 'Require authenticated dashboard sessions', state: 'in-progress', labels: ['type:agent'], phase: 'coding', cost: 1.38 },
    { n: 104, kind: 'leaf', charter: 101, title: 'Review installer and sandbox checks', state: 'review', labels: ['type:agent'], phase: 'review', cost: 0.86 },
    { n: 201, kind: 'charter', title: 'Improve review handoffs', state: 'plan-review', labels: ['type:charter'], blast_radius: 'low' },
    { n: 202, kind: 'leaf', charter: 201, title: 'Add a concise verification summary', state: 'open', labels: ['type:agent'] },
    { n: 203, kind: 'leaf', charter: 201, title: 'Choose the release acceptance checklist', state: 'open', labels: ['type:human-decision'] },
    { n: 301, kind: 'charter', title: 'Document the contribution workflow', state: 'done', labels: ['type:charter'] },
    { n: 302, kind: 'leaf', charter: 301, title: 'Publish the contributor check commands', state: 'done', labels: ['type:agent'], cost: 0.54 },
    { n: 303, kind: 'leaf', charter: 301, title: 'Add reproducible issue templates', state: 'done', labels: ['type:agent'], cost: 0.32 },
  ],
  agents: [
    { task: 103, pid: 1001, role: 'executor', phase: 'coding', title: 'Authenticated dashboard sessions', started: new Date(Date.now() - 4 * 60000).toISOString() },
    { task: 104, pid: 1002, role: 'reviewer', phase: 'review', title: 'Installer and sandbox checks', started: new Date(Date.now() - 2 * 60000).toISOString() },
  ],
  budget: { spent: 5.24, cap: 25, runs: [] },
  flags: { paused: false, killed: false },
  loop: { integrate: true, max_ticks: 1800, max_parallel: 4, running: true, stage: 'executing' },
  queue: { order: [101, 201] },
})

const initialTeam = (): Team => ({
  present: true, policy: { span_max: 5, human_approval_above_usd: 5 },
  departments: [{ id: 'delivery', head: 'tech-lead' }],
  nodes: [
    { role: 'cto', reports_to: null, kind: 'manager', domain: 'strategy', code_blind: true },
    { role: 'solution-analyst', reports_to: 'cto', kind: 'analyst', domain: 'analysis' },
    { role: 'tech-lead', reports_to: 'cto', kind: 'manager', domain: 'delivery' },
    { role: 'executor', reports_to: 'tech-lead', kind: 'executor', domain: 'implementation', live: 1 },
    { role: 'reviewer', reports_to: 'tech-lead', kind: 'analyst', domain: 'review', live: 1 },
    { role: 'qa-engineer', reports_to: 'tech-lead', kind: 'executor', domain: 'testing' },
  ],
  roles: [
    { role: 'cto', kind: 'manager', domain: 'strategy', code_blind: true },
    { role: 'solution-analyst', kind: 'analyst', domain: 'analysis' },
    { role: 'tech-lead', kind: 'manager', domain: 'delivery' },
    { role: 'executor', kind: 'executor', domain: 'implementation' },
    { role: 'reviewer', kind: 'analyst', domain: 'review' },
    { role: 'qa-engineer', kind: 'executor', domain: 'testing' },
    { role: 'security-reviewer', kind: 'analyst', domain: 'security' },
    { role: 'infra-engineer', kind: 'executor', domain: 'operations' },
  ],
})

let current = initialState()
let team = initialTeam()
let comments: Record<number, IssueComment[]> = {}
let roles: Record<string, RoleDetail> = {}
const listeners = new Set<(state: State) => void>()
const notify = () => listeners.forEach(listener => listener(copy(current)))
export function resetDemo() {
  current = initialState(); team = initialTeam(); comments = {}; roles = {}; notify()
  return copy(current)
}
export function subscribeDemo(onState: (state: State) => void, onConnection: (ok: boolean) => void) {
  listeners.add(onState); onConnection(true); onState(copy(current))
  return () => { listeners.delete(onState) }
}
const reply = (value: unknown, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { 'Content-Type': 'application/json' },
})
const addComment = (number: number, body: string) => {
  comments[number] ??= []
  comments[number].push({ id: String(Date.now()), author: 'demo-operator', created: new Date().toISOString(), body })
}

function demoCommand(body: Record<string, unknown>): CmdResult {
  const action = String(body.action)
  const number = Number(body.number)
  const task = current.board.find(item => item.n === number)
  const loop = current.loop!
  switch (action) {
    case 'run': case 'run-scoped':
      if (current.flags.killed) return { ok: false, msg: 'Demo: clear the kill switch before running' }
      loop.running = true; current.flags.paused = false; loop.stage = 'executing'; break
    case 'pause': current.flags.paused = true; loop.stage = 'paused'; break
    case 'resume': current.flags.paused = false; loop.stage = 'executing'; break
    case 'kill': current.flags.killed = true; loop.running = false; loop.stage = 'stopped'; current.agents = []; break
    case 'unkill': current.flags.killed = false; break
    case 'approve': case 'hold': case 'unhold': case 'merge': case 'resolve-decision': case 'request-changes':
      if (!task) return { ok: false, msg: 'Demo task not found' }
      task.state = ({ approve: 'approved', hold: 'held', unhold: 'approved', merge: 'done',
        'resolve-decision': 'done', 'request-changes': 'needs-plan' } as Record<string, string>)[action]
      if (body.comment || body.decision_text) addComment(number, String(body.comment || body.decision_text))
      break
    case 'comment': addComment(number, String(body.comment ?? '')); break
    case 'delete-comment': comments[number] = (comments[number] ?? []).filter(item => item.id !== String(body.comment_id)); break
    case 'set-check': addComment(number, 'Demo checklist updated'); break
    default: return { ok: false, msg: 'This operation is unavailable in the local demo' }
  }
  notify()
  return { ok: true, msg: 'Demo: ' + action + ' applied locally' }
}

/** Explicit local adapter: an unknown route never falls through to a network. */
export async function demoRequest(input: string, options: RequestInit = {}): Promise<Response> {
  const url = new URL(input, 'http://demo.local')
  const path = url.pathname
  const method = options.method ?? 'GET'
  const body = typeof options.body === 'string' ? JSON.parse(options.body) as Record<string, unknown> : {}
  if (path === '/api/state') return reply(copy(current))
  if (path === '/api/command' && method === 'POST') return reply(demoCommand(body))
  if (path === '/api/queue' && method === 'POST') {
    current.queue = { order: Array.isArray(body.order) ? body.order.map(Number) : [] }; notify()
    return reply({ ok: true })
  }
  if (path === '/api/search') {
    const q = (url.searchParams.get('q') ?? '').toLowerCase().replace(/^#/, '')
    return reply({ results: current.board.filter(item => item.title.toLowerCase().includes(q) || String(item.n) === q) })
  }
  if (path.startsWith('/api/task/')) {
    const number = Number(path.split('/').pop())
    const task = current.board.find(item => item.n === number)
    return reply({ n: number, status: { phase: task?.phase ?? task?.state, cost_usd: task?.cost },
      alive: task?.state === 'in-progress', started: current.agents.find(item => item.task === number)?.started ?? '',
      prompt: 'Local demonstration fixture. No agent session is running.',
      log: 'Demo activity is simulated in this browser tab.',
      body: `## ${task?.title ?? 'Demo task'}\n\nExplore the delivery workflow with local sample data.\n\n- [x] Define the expected behavior\n- [ ] Review the implementation and evidence` })
  }
  if (path.startsWith('/api/comments/')) return reply({ ok: true, comments: comments[Number(path.split('/').pop())] ?? [] })
  if (path === '/api/team') {
    if (method === 'POST') { team = copy(body as unknown as Team); return reply({ ok: true, msg: 'Demo team saved locally' }) }
    return reply(copy(team))
  }
  if (path.startsWith('/api/role/')) {
    const name = decodeURIComponent(path.split('/').pop() ?? '')
    const role = team.roles.find(item => item.role === name)
    return reply(roles[name] ?? { ok: true, name,
      frontmatter: { name, kind: role?.kind ?? 'executor', domain: role?.domain ?? 'delivery', tools: 'Read, Bash', profile: 'executor', model: 'demo' },
      prompt: 'Example role for the local demo. Does not launch an agent.' })
  }
  if (path === '/api/role' && method === 'POST') {
    const role = body as unknown as RoleSave
    roles[role.name] = { ok: true, name: role.name, prompt: role.prompt,
      frontmatter: { ...role, code_blind: role.code_blind ? 'true' : '' } }
    if (!team.roles.some(item => item.role === role.name)) team.roles.push({ role: role.name, kind: role.kind, domain: role.domain })
    return reply({ ok: true, msg: 'Demo role saved locally' })
  }
  if (path === '/api/issue' && method === 'POST') {
    const issue = body as unknown as IssuePayload
    const number = Math.max(...current.board.map(item => item.n)) + 1
    const task: Task = { n: number, kind: issue.kind === 'charter' ? 'charter' : 'leaf', title: issue.title,
      state: 'open', labels: [issue.kind === 'charter' ? 'type:charter' : 'type:agent'] }
    if (issue.kind === 'task') task.charter = issue.charter
    current.board.push(task); notify()
    return reply({ ok: true, msg: 'Demo issue created locally', number })
  }
  if (path === '/api/facilitate') return reply({ ok: true,
    message: 'Local demo: the brief is ready to preview. A real facilitator is not connected.',
    acceptance_block: '## Acceptance (machine)\n- check: Review the proposed behavior and add a focused regression test' })
  return reply({ ok: false, msg: 'Unknown local demo route' }, 404)
}
