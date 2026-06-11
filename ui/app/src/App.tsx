import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { command, config, createIssue, deleteComment, fetchComments, fetchTask, setCheck, subscribe, type Agent, type IssueComment, type IssuePayload, type IssueResult, type State, type Task, type TaskDetail } from './api'
import TeamPage from './TeamPage'

type Toast = { id: number; msg: string; err?: boolean; exiting?: boolean }
type Confirm = { title: string; body: string; onOk: (reason?: string) => void; withInput?: boolean } | null

/** Respect prefers-reduced-motion globally */
function prefersReducedMotion(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

/** animate a number toward `value` (easeOutCubic) — premium count-up on change. */
function useCountUp(value: number, ms = 600): number {
  const [n, setN] = useState(value)
  const from = useRef(value)
  useEffect(() => {
    const a = from.current, b = value
    if (a === b) { setN(b); return }
    if (prefersReducedMotion()) { from.current = b; setN(b); return }
    let raf = 0, start = 0
    const tick = (t: number) => {
      if (!start) start = t
      const p = Math.min(1, (t - start) / ms)
      const e = 1 - Math.pow(1 - p, 3)
      setN(a + (b - a) * e)
      if (p < 1) raf = requestAnimationFrame(tick); else { from.current = b; setN(b) }
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [value, ms])
  return n
}

/** Relative position of an element within its FLIP container. */
type FlipPos = { left: number; top: number }

/**
 * FLIP hook: measures children by data-flip-key before/after renders and
 * plays translate animations for moved items.
 *
 * Positions are read from offsetLeft/offsetTop (the LAYOUT box, relative to
 * offsetParent) — NOT getBoundingClientRect, which includes the element's
 * current CSS transform. A transform-inclusive read makes the hook ingest its
 * own in-flight .animate() output (and the `.task` `rise` entry animation),
 * fabricating a phantom ~5px delta on every render → a self-sustaining jitter
 * that fires on every idle re-render (e.g. the 1s setTick). offsetTop/offsetLeft
 * are transform-free, so an idle render yields dy=0 and nothing animates; cards
 * only FLIP on a genuine layout change (real reorder / add / remove).
 */
function useFlip(containerRef: React.RefObject<HTMLElement | null>) {
  const snapshot = useRef<Map<string, FlipPos>>(new Map())

  useLayoutEffect(() => {
    const el = containerRef.current
    if (!el) return

    const prev = snapshot.current
    const reduced = prefersReducedMotion()

    // INVERT + PLAY: animate children from old layout positions to new
    Array.from(el.children).forEach((child) => {
      const c = child as HTMLElement
      const key = c.dataset.flipKey
      if (!key) return
      const oldPos = prev.get(key)
      if (!oldPos) return
      const dx = oldPos.left - c.offsetLeft
      const dy = oldPos.top - c.offsetTop
      if ((Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) || reduced) return
      c.animate(
        [{ transform: `translate(${dx}px,${dy}px)` }, { transform: 'none' }],
        { duration: 300, easing: 'cubic-bezier(.2,.7,.2,1)' }
      )
    })

    // FIRST (for next render): snapshot current layout positions (transform-free)
    const next = new Map<string, FlipPos>()
    Array.from(el.children).forEach((child) => {
      const c = child as HTMLElement
      const key = c.dataset.flipKey
      if (key) next.set(key, { left: c.offsetLeft, top: c.offsetTop })
    })
    snapshot.current = next
  })
}

export default function App() {
  const [state, setState] = useState<State | null>(null)
  const [conn, setConn] = useState(false)
  const [toasts, setToasts] = useState<Toast[]>([])
  const [confirm, setConfirm] = useState<Confirm>(null)
  const [settings, setSettings] = useState(false)
  const [newIssue, setNewIssue] = useState(false)
  const [view, setView] = useState<'board' | 'team' | 'human'>('board')
  const [open, setOpen] = useState<number | null>(null)
  const [, setTick] = useState(0)
  const tid = useRef(0)

  useEffect(() => subscribe(setState, setConn), [])
  useEffect(() => { const i = setInterval(() => setTick((x) => x + 1), 1000); return () => clearInterval(i) }, [])

  const toast = useCallback((msg: string, err?: boolean) => {
    const id = ++tid.current
    setToasts((t) => [...t, { id, msg, err }])
    // Start exit animation before removing
    setTimeout(() => {
      setToasts((t) => t.map((x) => x.id === id ? { ...x, exiting: true } : x))
      setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 300)
    }, 3100)
  }, [])
  const run = useCallback(async (action: string, number?: number, comment?: string) => {
    const r = await command(action, number, comment); toast(r.msg || (r.ok ? 'ok' : 'failed'), !r.ok)
  }, [toast])
  const ask = useCallback((title: string, body: string, onOk: (reason?: string) => void, withInput?: boolean) => setConfirm({ title, body, onOk, withInput }), [])

  return (
    <div className="app">
      <Header state={state} conn={conn} view={view} setView={setView}
        onRun={() => ask('Run launcher', 'Claims every launchable task and runs REAL agents — this spends from your pool ($).', () => run('run'))}
        onPause={() => run(state?.flags.paused ? 'resume' : 'pause')}
        onKill={() => state?.flags.killed ? run('unkill') : ask('Kill-switch', 'Stops the launcher loop at the next tick. In-flight agents finish on their own.', () => run('kill'))}
        onSettings={() => setSettings(true)}
        onNew={() => setNewIssue(true)} />

      {view === 'board' ? (
        <>
          <Hero state={state} />
          <div className="layout">
            <Board state={state} conn={conn} onAction={run} ask={ask} onOpen={setOpen} />
            <AgentsRail agents={state?.agents ?? []} onOpen={setOpen} />
          </div>
        </>
      ) : view === 'human' ? (
        <HumanDecisionsPage state={state} onOpen={setOpen} />
      ) : <TeamPage />}

      <div className="toasts">
        {toasts.map((t) => (
          <div key={t.id} className={'toast' + (t.err ? ' err' : '') + (t.exiting ? ' exiting' : '')}>{t.msg}</div>
        ))}
      </div>
      {confirm && <Modal title={confirm.title} body={confirm.body}
        onCancel={() => setConfirm(null)} onOk={(reason) => { const f = confirm.onOk; setConfirm(null); f(reason) }}
        withInput={confirm.withInput} />}
      {settings && <SettingsModal onClose={() => setSettings(false)} onSaved={() => location.reload()} />}
      {newIssue && <NewIssueModal state={state} onClose={() => setNewIssue(false)} onToast={toast} />}
      {open != null && <TaskDrawer n={open} task={state?.board.find((b) => b.n === open) ?? null}
        onClose={() => setOpen(null)} onAction={run} ask={ask} />}
    </div>
  )
}

function Header({ state, conn, view, setView, onRun, onPause, onKill, onSettings, onNew }: {
  state: State | null; conn: boolean; view: 'board' | 'team' | 'human'; setView: (v: 'board' | 'team' | 'human') => void
  onRun: () => void; onPause: () => void; onKill: () => void; onSettings: () => void; onNew: () => void
}) {
  const paused = state?.flags.paused, killed = state?.flags.killed
  return (
    <header className="hdr">
      <div className="hdr-l">
        <span className="brand"><span className="logo">◆</span>crewboss</span>
        <nav className="nav" data-testid="main-nav">
          <button className={view === 'board' ? 'on' : ''} onClick={() => setView('board')}>Board</button>
          <button className={view === 'team' ? 'on' : ''} onClick={() => setView('team')}>Team</button>
          <button className={view === 'human' ? 'on' : ''} onClick={() => setView('human')} data-testid="tab-human">Задачи на человека</button>
        </nav>
        <span className={'conn' + (conn ? ' live' : '')}>{conn ? 'live' : 'offline'}</span>
        <span className="repo">{state?.autonomy.repo || '—'}</span>
      </div>
      <div className="hdr-r">
        <button className="btn" onClick={onNew}>+ New</button>
        <button className="btn pri" onClick={onRun}>▶ Run</button>
        <button className="btn" onClick={onPause}>{paused ? 'Resume' : 'Pause'}</button>
        <button className={'btn' + (killed ? '' : ' warn')} onClick={onKill}>{killed ? 'Un-kill' : 'Kill'}</button>
        <button className="btn ghost" onClick={onSettings} aria-label="settings">⚙</button>
      </div>
    </header>
  )
}

function Hero({ state }: { state: State | null }) {
  const board = state?.board ?? []
  const running = state?.agents?.length ?? 0
  const review = board.filter((x) => x.kind === 'leaf' && x.state === 'review').length
  const done = board.filter((x) => x.kind === 'leaf' && x.state === 'done').length
  const blocked = board.filter((x) => x.kind === 'leaf' && x.state === 'blocked').length
  const b = state?.budget ?? { spent: 0, cap: 0, runs: [] }
  const pct = b.cap > 0 ? Math.min(100, (100 * b.spent) / b.cap) : 0
  const spent = useCountUp(b.spent)
  return (
    <div className="hero">
      <Stat n={running} label="agents running" live={running > 0} accent="prog" />
      <Stat n={review} label="in review" accent="review" />
      <Stat n={done} label="shipped" accent="done" />
      {blocked > 0 && <Stat n={blocked} label="blocked" accent="blocked" />}
      <div className="stat budget-stat">
        <div className="stat-label">pool</div>
        <div className="stat-budget">${spent.toFixed(2)} <span className="muted">/ ${b.cap.toFixed(0)}</span></div>
        <div className="bar"><div className="fill" style={{ width: pct + '%' }} /></div>
      </div>
    </div>
  )
}
function Stat({ n, label, live, accent }: { n: number; label: string; live?: boolean; accent: string }) {
  const shown = Math.round(useCountUp(n))
  return (
    <div className="stat">
      <div className={'stat-n a-' + accent}>{shown}{live && <span className="stat-pulse" />}</div>
      <div className="stat-label">{label}</div>
    </div>
  )
}

function Board({ state, conn, onAction, ask, onOpen }: {
  state: State | null; conn: boolean
  onAction: (a: string, n?: number, comment?: string) => void; ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void; onOpen: (n: number) => void
}) {
  if (!state) return (
    <section className="board">
      <SkeletonBoard />
      {!conn && <div className="skel-hint">offline — open ⚙ to set API URL + token, and start the SSH tunnel</div>}
    </section>
  )
  const charters = state.board.filter((x) => x.kind === 'charter')
  const leaves = state.board.filter((x) => x.kind === 'leaf')
  const childrenOf = (cn: number) => leaves.filter((l) => l.charter === cn)
  const orphans = leaves.filter((l) => !l.charter || !charters.some((c) => c.n === l.charter))
  if (!state.board.length) return <section className="board"><div className="empty">no issues on the board yet</div></section>
  return (
    <section className="board">
      {charters.map((c) => <CharterCard key={c.n} c={c} leaves={childrenOf(c.n)} onAction={onAction} ask={ask} onOpen={onOpen} />)}
      {orphans.length > 0 && <CharterCard c={null} leaves={orphans} onAction={onAction} ask={ask} onOpen={onOpen} />}
    </section>
  )
}

function HumanDecisionsPage({ state, onOpen }: {
  state: State | null; onOpen: (n: number) => void
}) {
  if (!state) return (
    <section className="board" data-testid="human-page">
      <div className="empty">Загрузка…</div>
    </section>
  )
  const charters = state.board.filter((x) => x.kind === 'charter')
  const tasks = state.board.filter(
    (x) => x.kind === 'leaf' && x.labels.includes('type:human-decision') && x.state !== 'done'
  )
  if (tasks.length === 0) return (
    <section className="board" data-testid="human-page">
      <div className="empty" data-testid="human-empty">
        Нет открытых задач, требующих решения человека.<br />
        <span style={{ fontSize: 13 }}>Когда появятся issues с меткой <code>type:human-decision</code>, они отобразятся здесь.</span>
      </div>
    </section>
  )

  const chartersWithTasks = charters.filter((c) => tasks.some((t) => t.charter === c.n))
  const orphans = tasks.filter((t) => !t.charter || !charters.some((c) => c.n === t.charter))

  return (
    <section className="board" data-testid="human-page">
      {chartersWithTasks.map((c) => (
        <HumanCharterGroup
          key={c.n}
          charter={c}
          tasks={tasks.filter((t) => t.charter === c.n)}
          onOpen={onOpen}
        />
      ))}
      {orphans.length > 0 && (
        <HumanCharterGroup charter={null} tasks={orphans} onOpen={onOpen} />
      )}
    </section>
  )
}

function HumanCharterGroup({ charter, tasks, onOpen }: {
  charter: Task | null; tasks: Task[]; onOpen: (n: number) => void
}) {
  return (
    <div className="charter" data-testid="human-charter-group" data-charter={charter?.n ?? 'none'}>
      <div className="charter-head">
        <div className="charter-id">
          {charter ? <span className="num">#{charter.n}</span> : <span className="num">∅</span>}
        </div>
        <div className="charter-title">
          {charter ? `#${charter.n} ${charter.title}` : 'Без чартера'}
        </div>
        <div className="grow" />
        <span className="muted" style={{ fontSize: 12 }}>{tasks.length} задач{tasks.length === 1 ? 'а' : tasks.length < 5 ? 'и' : ''}</span>
      </div>
      <div className="task-grid">
        {tasks.map((t) => <HumanTaskCard key={t.n} t={t} onOpen={onOpen} />)}
      </div>
    </div>
  )
}

function HumanTaskCard({ t, onOpen }: { t: Task; onOpen: (n: number) => void }) {
  return (
    <div
      className="task"
      data-testid="human-task-card"
      data-task-n={t.n}
      onClick={() => onOpen(t.n)}
    >
      <div className="task-top">
        <span className="num">#{t.n}</span>
        <span className={'badge b-' + t.state}>{t.state}</span>
        <span className="grow" />
        {t.cost != null && String(t.cost) !== '' && <span className="cost">${Number(t.cost).toFixed(3)}</span>}
      </div>
      <div className="task-title">{t.title}</div>
      <div className="task-foot">
        <span className="badge" style={{ fontSize: 10, background: 'rgba(70,206,142,.1)', color: 'var(--done)', border: '1px solid rgba(70,206,142,.25)' }}>human-decision</span>
        {t.pr ? <a className="pr" href={t.pr} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>view PR ↗</a> : <span className="muted xs-link">open ↗</span>}
      </div>
    </div>
  )
}

function CharterCard({ c, leaves, onAction, ask, onOpen }: {
  c: Task | null; leaves: Task[]; onAction: (a: string, n?: number, comment?: string) => void
  ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void; onOpen: (n: number) => void
}) {
  const done = leaves.filter((l) => l.state === 'done').length
  const total = leaves.length
  const pct = total > 0 ? Math.round((100 * done) / total) : 0
  const gridRef = useRef<HTMLDivElement>(null)
  useFlip(gridRef)
  return (
    <div className="charter">
      <div className="charter-head">
        <div className="charter-id">
          {c ? <span className="num">#{c.n}</span> : <span className="num">∅</span>}
          {c && <span className={'badge b-' + c.state}>{c.state}</span>}
        </div>
        <div className="charter-title" onClick={() => c && onOpen(c.n)} style={c ? { cursor: 'pointer' } : undefined}>{c ? c.title : 'Unassigned tasks'}</div>
        <div className="grow" />
        {total > 0 && <Ring pct={pct} label={`${done}/${total}`} />}
        {c && c.state === 'plan-review' && <>
          <button className="btn sm pri" onClick={() => ask('Approve plan #' + c.n,
            "Releases this charter's tasks to be launched (executors run, spending from the pool).",
            () => onAction('approve', c.n))}>Approve plan</button>
          <button className="btn sm ghost" onClick={() => ask('Request changes #' + c.n,
            'Опишите, что нужно доработать в плане:',
            (reason) => onAction('request-changes', c.n, reason),
            true)}>Request changes</button>
        </>}
      </div>
      {total > 0 && (
        <div className="task-grid" ref={gridRef}>
          {leaves.map((l) => <TaskCard key={l.n} t={l} onOpen={onOpen} />)}
        </div>
      )}
      {total === 0 && <div className="leaf-empty">awaiting decomposition…</div>}
    </div>
  )
}

function Ring({ pct, label }: { pct: number; label: string }) {
  const R = 15, C = 2 * Math.PI * R
  return (
    <div className="ring" title={`${pct}% complete`}>
      <svg width="38" height="38" viewBox="0 0 38 38">
        <circle cx="19" cy="19" r={R} className="ring-bg" />
        <circle cx="19" cy="19" r={R} className="ring-fg" strokeDasharray={C} strokeDashoffset={C * (1 - pct / 100)} transform="rotate(-90 19 19)" />
      </svg>
      <span className="ring-label">{label}</span>
    </div>
  )
}

/** Color glow per state for card highlight animation */
const STATE_GLOW: Record<string, string> = {
  'in-progress': 'rgba(91,156,240,.55)',
  'review':      'rgba(179,155,255,.55)',
  'done':        'rgba(70,206,142,.55)',
  'blocked':     'rgba(240,103,106,.55)',
  'held':        'rgba(232,151,74,.55)',
  'plan-review': 'rgba(224,182,74,.55)',
  'approved':    'rgba(70,206,142,.4)',
}

function TaskCard({ t, onOpen }: { t: Task; onOpen: (n: number) => void }) {
  const working = t.state === 'in-progress'
  const cardRef = useRef<HTMLDivElement>(null)
  const badgeRef = useRef<HTMLSpanElement>(null)
  const mountedRef = useRef(false)

  useEffect(() => {
    // Skip animation on initial mount
    if (!mountedRef.current) { mountedRef.current = true; return }
    if (prefersReducedMotion()) return

    // Badge: cross-fade/scale in with new color
    if (badgeRef.current) {
      badgeRef.current.animate(
        [{ opacity: 0, transform: 'scale(0.6)' }, { opacity: 1, transform: 'scale(1)' }],
        { duration: 280, easing: 'cubic-bezier(.2,.7,.2,1)' }
      )
    }
    // Card: brief glow with new state color
    if (cardRef.current) {
      const color = STATE_GLOW[t.state] ?? 'rgba(255,255,255,.2)'
      cardRef.current.animate(
        [
          { boxShadow: `0 0 0 3px ${color}`, offset: 0 },
          { boxShadow: `0 0 0 3px ${color}`, offset: 0.25 },
          { boxShadow: '0 0 0 0 transparent', offset: 1 },
        ],
        { duration: 750, easing: 'ease-out' }
      )
    }
  }, [t.state]) // only re-runs when state changes

  return (
    <div
      ref={cardRef}
      className={'task' + (working ? ' working' : '')}
      data-flip-key={String(t.n)}
      onClick={() => onOpen(t.n)}
    >
      <div className="task-top">
        <span className="num">#{t.n}</span>
        <span ref={badgeRef} className={'badge b-' + t.state}>{t.state}</span>
        <span className="grow" />
        {t.cost != null && String(t.cost) !== '' && <span className="cost">${Number(t.cost).toFixed(3)}</span>}
      </div>
      <div className="task-title">{t.title}</div>
      <div className="task-foot">
        {t.pr ? <a className="pr" href={t.pr} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>view PR ↗</a> : <span className="muted xs-link">open ↗</span>}
        {working && <span className="working-tag">working</span>}
      </div>
    </div>
  )
}

function SkeletonBoard() {
  return (
    <>
      {[0, 1].map((i) => (
        <div className="charter skel-card" key={i}>
          <div className="charter-head"><span className="skel skel-badge" /><span className="skel skel-line" /></div>
          <div className="task-grid">{[0, 1, 2].map((j) => (
            <div className="task skel-task" key={j}><span className="skel skel-line" /><span className="skel skel-line short" /></div>
          ))}</div>
        </div>
      ))}
    </>
  )
}

function AgentsRail({ agents, onOpen }: { agents: Agent[]; onOpen: (n: number) => void }) {
  const listRef = useRef<HTMLElement>(null)
  useFlip(listRef as React.RefObject<HTMLElement | null>)
  return (
    <aside className="rail" ref={listRef as React.RefObject<HTMLElement>}>
      <div className="rail-head"><span>Agents</span><span className="rail-count">{agents.length}</span></div>
      {agents.length === 0
        ? <div className="rail-empty"><div className="z">z z z</div>no agents running</div>
        : agents.map((a) => (
            <AgentCard
              key={String(a.task ?? 'boss') + ':' + a.role}
              a={a}
              onOpen={onOpen}
            />
          ))}
    </aside>
  )
}

function AgentCard({ a, onOpen }: { a: Agent; onOpen: (n: number) => void }) {
  const initial = a.role[0]?.toUpperCase() ?? '?'
  const flipKey = String(a.task ?? 'boss') + ':' + a.role
  return (
    <div
      className={'agent role-' + a.role}
      data-flip-key={flipKey}
      onClick={() => a.task != null && onOpen(a.task)}
      style={a.task != null ? { cursor: 'pointer' } : undefined}
    >
      <div className="agent-mono">{initial}<span className="agent-wave" /></div>
      <div className="agent-body">
        <div className="agent-top">
          <span className="agent-role">{a.role}</span>
          {a.task != null && <span className="agent-task">#{a.task}</span>}
          <span className="grow" /><span className="agent-elapsed">{elapsed(a.started)}</span>
        </div>
        <div className="agent-title">{a.title || a.phase}</div>
        <div className="agent-phase"><span className="phase-dot" />{a.phase}</div>
      </div>
    </div>
  )
}

/** Plays a short exit animation on the overlay refs, then calls `done`. */
function animateOverlayOut(
  bgRef: React.RefObject<HTMLElement | null>,
  panelRef: React.RefObject<HTMLElement | null>,
  done: () => void,
  slideDir: 'scale' | 'right' = 'scale'
) {
  if (prefersReducedMotion() || !bgRef.current || !panelRef.current) { done(); return }
  const dur = 180
  bgRef.current.animate([{ opacity: 1 }, { opacity: 0 }], { duration: dur, easing: 'ease-in', fill: 'forwards' })
  const panelKf = slideDir === 'right'
    ? [{ transform: 'translateX(0)', opacity: 1 }, { transform: 'translateX(40px)', opacity: 0 }]
    : [{ transform: 'scale(1)', opacity: 1 }, { transform: 'scale(.97)', opacity: 0 }]
  panelRef.current.animate(panelKf, { duration: dur, easing: 'ease-in', fill: 'forwards' })
  setTimeout(done, dur + 10)
}

/** Parse checkbox lines from a markdown body string. Returns items in order. */
function parseCheckboxes(body: string): { index: number; checked: boolean; text: string }[] {
  if (!body) return []
  const lines = body.split('\n')
  const result: { index: number; checked: boolean; text: string }[] = []
  let idx = 0
  for (const line of lines) {
    const m = line.match(/^\s*[-*]\s+\[([ xX])\]\s*(.*)$/)
    if (m) {
      result.push({ index: idx++, checked: m[1].toLowerCase() === 'x', text: m[2].trim() })
    }
  }
  return result
}

/** History marker prefixes emitted by set-check */
const HISTORY_MARKERS = ['✅ выполнено:', '↩️ снята отметка:']

function TaskDrawer({ n, task, onClose, onAction, ask }: {
  n: number; task: Task | null; onClose: () => void
  onAction: (a: string, n?: number, comment?: string) => void; ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void
}) {
  const [d, setD] = useState<TaskDetail | null>(null)
  const [comments, setComments] = useState<IssueComment[]>([])
  const [commentText, setCommentText] = useState('')
  const [sending, setSending] = useState(false)
  const [pendingChecks, setPendingChecks] = useState<Set<number>>(new Set())
  const logRef = useRef<HTMLPreElement>(null)
  const tid = useRef(0)
  const [toasts, setToasts] = useState<Toast[]>([])
  const toast = useCallback((msg: string, err?: boolean) => {
    const id = ++tid.current
    setToasts((t) => [...t, { id, msg, err }])
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 3400)
  }, [])
  const bgRef = useRef<HTMLDivElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    let on = true
    const load = async () => { const x = await fetchTask(n); if (on) setD(x) }
    load(); const i = setInterval(load, 2500); return () => { on = false; clearInterval(i) }
  }, [n])
  useEffect(() => { if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight }, [d?.log])

  const loadComments = useCallback(async () => {
    const cs = await fetchComments(n); setComments(cs)
  }, [n])
  useEffect(() => {
    loadComments()
    const i = setInterval(loadComments, 15000)
    return () => clearInterval(i)
  }, [loadComments])

  const sendComment = async () => {
    const text = commentText.trim()
    if (!text) return
    setSending(true)
    const r = await command('comment', n, text)
    setSending(false)
    toast(r.msg || (r.ok ? 'ok' : 'failed'), !r.ok)
    if (r.ok) { setCommentText(''); loadComments() }
  }

  const handleCheckboxToggle = async (item: { index: number; checked: boolean }) => {
    const newChecked = !item.checked
    setPendingChecks((s) => new Set(s).add(item.index))
    const r = await setCheck(n, item.index, newChecked)
    if (!r.ok) {
      toast(r.msg || 'update failed', true)
    } else {
      const [newTask] = await Promise.all([fetchTask(n), loadComments()])
      if (newTask) setD(newTask)
    }
    setPendingChecks((s) => { const ns = new Set(s); ns.delete(item.index); return ns })
  }

  const close = () => animateOverlayOut(bgRef, panelRef, onClose, 'right')

  const phase = d?.status.phase ?? (d?.alive ? 'running' : '—')
  const cost = d?.status.cost_usd
  const pr = d?.status.pr || task?.pr

  const checkboxItems = parseCheckboxes(d?.body ?? '')
  const historyComments = comments.filter((c) => HISTORY_MARKERS.some((p) => c.body.startsWith(p)))
  const discussionComments = comments.filter((c) => !HISTORY_MARKERS.some((p) => c.body.startsWith(p)))

  return (
    <div ref={bgRef} className="drawer-bg" onClick={close}>
      <div ref={panelRef} className="drawer" onClick={(e) => e.stopPropagation()}>
        <div className="drawer-head">
          <div>
            <div className="drawer-id"><span className="num">#{n}</span>{task && <span className={'badge b-' + task.state}>{task.state}</span>}
              {d?.alive && <span className="live-tag"><span className="phase-dot" />live</span>}</div>
            <h2 className="drawer-title">{task?.title ?? 'task #' + n}</h2>
          </div>
          <button className="btn ghost" onClick={close}>✕</button>
        </div>

        <div className="drawer-stats">
          <div><span className="ds-label">phase</span><span className="ds-val">{phase}</span></div>
          {d?.started && d.alive && <div><span className="ds-label">elapsed</span><span className="ds-val">{elapsed(d.started)}</span></div>}
          {cost != null && <div><span className="ds-label">cost</span><span className="ds-val">${Number(cost).toFixed(3)}</span></div>}
          {pr && <div><span className="ds-label">pr</span><a className="ds-val pr" href={pr} target="_blank" rel="noreferrer">open ↗</a></div>}
        </div>

        {task && task.state !== 'done' && (
          <div className="drawer-actions">
            {task.state === 'plan-review' && <>
              <button className="btn sm pri" onClick={() => ask('Approve plan #' + n, "Releases this charter's tasks to be launched.", () => onAction('approve', n))}>Approve plan</button>
              <button className="btn sm ghost" onClick={() => ask('Request changes #' + n,
                'Опишите, что нужно доработать в плане:',
                (reason) => onAction('request-changes', n, reason),
                true)}>Request changes</button>
            </>}
            {task.state === 'held'
              ? <button className="btn sm" onClick={() => onAction('unhold', n)}>Un-hold</button>
              : <button className="btn sm ghost" onClick={() => onAction('hold', n)}>Hold</button>}
          </div>
        )}

        {d?.prompt && <><div className="drawer-section">Brief</div><div className="brief">{d.prompt}</div></>}

        {checkboxItems.length > 0 && (
          <>
            <div className="drawer-section" data-testid="checklist-section">Checklist</div>
            <div className="checklist">
              {checkboxItems.map((item) => (
                <label
                  key={item.index}
                  className={'checklist-item' + (pendingChecks.has(item.index) ? ' pending' : '')}
                  data-testid="checklist-item"
                  data-index={item.index}
                >
                  <input
                    type="checkbox"
                    checked={item.checked}
                    disabled={pendingChecks.has(item.index)}
                    onChange={() => handleCheckboxToggle(item)}
                  />
                  <span className={item.checked ? 'checked' : ''}>{item.text}</span>
                </label>
              ))}
            </div>
          </>
        )}

        {historyComments.length > 0 && (
          <>
            <div className="drawer-section" data-testid="history-section">История</div>
            <div className="history">
              {historyComments.map((c, i) => (
                <div key={c.id || i} className="history-entry" data-testid="history-entry">
                  <span className="history-body">{c.body}</span>
                  <span className="history-meta muted">{c.author}{c.created ? ' · ' + elapsed(c.created) : ''}</span>
                </div>
              ))}
            </div>
          </>
        )}

        <div className="drawer-section">Discussion</div>
        <div className="discussion">
          {discussionComments.length === 0
            ? <div className="disc-empty muted">no comments yet</div>
            : discussionComments.map((c, i) => (
              <div className="disc-comment" key={c.id || i} data-testid="disc-comment">
                <div className="disc-meta">
                  <span className="disc-author">{c.author}</span>
                  {c.created && <span className="disc-time muted">{elapsed(c.created)}</span>}
                  <button
                    className="btn ghost disc-del"
                    data-testid="delete-comment-btn"
                    title="Delete comment"
                    onClick={() => ask(
                      'Delete comment',
                      'Are you sure you want to delete this comment? This cannot be undone.',
                      async () => {
                        const r = await deleteComment(n, c.id)
                        if (!r.ok) toast(r.msg || 'delete failed', true)
                        else loadComments()
                      }
                    )}
                  >✕</button>
                </div>
                <div className="disc-body">{c.body}</div>
              </div>
            ))}
          <div className="disc-compose">
            <textarea
              className="disc-input"
              value={commentText}
              onChange={(e) => setCommentText(e.target.value)}
              placeholder="Leave a comment…"
              rows={3}
            />
            <button
              className="btn sm pri"
              disabled={!commentText.trim() || sending}
              onClick={sendComment}
            >{sending ? 'Sending…' : 'Send'}</button>
          </div>
        </div>
        {toasts.map((t) => <div key={t.id} className={'toast' + (t.err ? ' err' : '')}>{t.msg}</div>)}

        <div className="drawer-section">Agent log {d?.alive && <span className="muted">· live</span>}</div>
        <pre className="log" ref={logRef}>{d?.log?.trim() || (d?.alive ? 'agent working… (output appears when it streams/finishes)' : 'no log yet')}</pre>
      </div>
    </div>
  )
}

function elapsed(iso: string): string {
  if (!iso) return ''
  const t = Date.parse(iso); if (isNaN(t)) return ''
  let s = Math.max(0, Math.floor((Date.now() - t) / 1000))
  const m = Math.floor(s / 60); s = s % 60
  return m > 0 ? `${m}m ${s}s` : `${s}s`
}

function Modal({ title, body, onCancel, onOk, withInput }: {
  title: string; body: string; onCancel: () => void; onOk: (reason?: string) => void; withInput?: boolean
}) {
  const [reason, setReason] = useState('')
  const bgRef = useRef<HTMLDivElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)
  const cancel = () => animateOverlayOut(bgRef, panelRef, onCancel)
  const ok = () => animateOverlayOut(bgRef, panelRef, () => onOk(withInput ? reason : undefined))
  return (
    <div ref={bgRef} className="modal-bg" onClick={cancel}>
      <div ref={panelRef} className="modal" onClick={(e) => e.stopPropagation()}>
        <h3>{title}</h3><p>{body}</p>
        {withInput && (
          <label className="fld"><textarea rows={4} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Причина…" /></label>
        )}
        <div className="m-actions">
          <button className="btn" onClick={cancel}>Cancel</button>
          <button className="btn pri" disabled={withInput === true && !reason.trim()} onClick={ok}>Confirm</button>
        </div>
      </div>
    </div>
  )
}

function NewIssueModal({ state, onClose, onToast }: {
  state: State | null
  onClose: () => void
  onToast: (msg: string, err?: boolean) => void
}) {
  const [kind, setKind] = useState<'charter' | 'task'>('charter')
  const [title, setTitle] = useState('')
  const [what, setWhat] = useState('')
  const [why, setWhy] = useState('')
  const [scope, setScope] = useState('')
  const [constraints, setConstraints] = useState('')
  const [acceptance, setAcceptance] = useState('')
  const [description, setDescription] = useState('')
  const [charterN, setCharterN] = useState('')
  const [dependsOn, setDependsOn] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [charterSuccess, setCharterSuccess] = useState<IssueResult | null>(null)
  const [launching, setLaunching] = useState(false)

  const charters = (state?.board ?? []).filter((x) => x.kind === 'charter')

  const isValid = kind === 'charter'
    ? !!(title.trim() && what.trim() && why.trim())
    : !!(title.trim() && description.trim() && charterN)

  const handleSubmit = async () => {
    if (!isValid || submitting) return
    const p: IssuePayload = kind === 'charter'
      ? { kind: 'charter', title, what, why, scope, constraints, acceptance }
      : { kind: 'task', title, description, charter: Number(charterN), depends_on: dependsOn.trim() || undefined }
    setSubmitting(true)
    try {
      const r = await createIssue(p)
      if (r.ok && kind === 'charter') {
        setCharterSuccess(r)
      } else {
        onToast(r.msg || (r.ok ? 'created' : 'failed'), !r.ok)
        if (r.ok) onClose()
      }
    } catch (e: unknown) {
      onToast('request failed: ' + String(e), true)
    } finally {
      setSubmitting(false)
    }
  }

  const handleLaunch = async () => {
    setLaunching(true)
    try {
      const r = await command('run')
      onToast(r.msg || (r.ok ? 'Launcher started' : 'failed'), !r.ok)
    } catch (e: unknown) {
      onToast('request failed: ' + String(e), true)
    } finally {
      setLaunching(false)
      onClose()
    }
  }

  if (charterSuccess) {
    return (
      <div className="modal-bg" data-testid="ni-success-backdrop">
        <div className="modal ni-modal" data-testid="ni-success-panel" onClick={(e) => e.stopPropagation()}>
          <div className="ni-head">
            <h3>Чартер создан</h3>
            <button className="btn ghost" onClick={onClose}>✕</button>
          </div>
          <div className="ni-success" data-testid="ni-success-msg">
            <div className="ni-success-icon">✓</div>
            <div className="ni-success-text">
              Чартер <strong>#{charterSuccess.number}</strong> успешно создан
            </div>
          </div>
          <div className="ni-run-warning" data-testid="ni-run-warning">
            ⚠ Запуск лаунчера захватит все доступные задачи и запустит реальных агентов — это тратит средства из вашего пула ($).
          </div>
          <div className="m-actions">
            <button className="btn" data-testid="ni-close-btn" onClick={onClose}>Закрыть</button>
            <button className="btn pri" data-testid="ni-launch-btn" disabled={launching} onClick={handleLaunch}>
              {launching ? 'Запуск…' : '▶ Запустить'}
            </button>
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="modal-bg" onClick={onClose}>
      <div className="modal ni-modal" onClick={(e) => e.stopPropagation()}>
        <div className="ni-head">
          <h3>New issue</h3>
          <button className="btn ghost" onClick={onClose}>✕</button>
        </div>
        <div className="ni-tabs">
          <button className={'ni-tab' + (kind === 'charter' ? ' on' : '')} onClick={() => setKind('charter')}>Charter</button>
          <button className={'ni-tab' + (kind === 'task' ? ' on' : '')} onClick={() => setKind('task')}>Task</button>
        </div>
        <label className="fld">Title *<input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Short descriptive title" data-testid="ni-title" /></label>
        {kind === 'charter' ? (
          <>
            <label className="fld">WHAT *<textarea value={what} onChange={(e) => setWhat(e.target.value)} placeholder="What exactly needs to be built/done?" rows={2} data-testid="ni-what" /></label>
            <label className="fld">WHY *<textarea value={why} onChange={(e) => setWhy(e.target.value)} placeholder="Why is this needed? Business / user value." rows={2} data-testid="ni-why" /></label>
            <label className="fld">Scope<textarea value={scope} onChange={(e) => setScope(e.target.value)} placeholder="In-scope / out-of-scope" rows={2} /></label>
            <label className="fld">Constraints<textarea value={constraints} onChange={(e) => setConstraints(e.target.value)} placeholder="Technical, time, or budget constraints" rows={2} /></label>
            <label className="fld">Acceptance<textarea value={acceptance} onChange={(e) => setAcceptance(e.target.value)} placeholder="Acceptance criteria (checklist)" rows={3} /></label>
          </>
        ) : (
          <>
            <label className="fld">Description *<textarea value={description} onChange={(e) => setDescription(e.target.value)} placeholder="What this task does" rows={3} /></label>
            <label className="fld">Charter *
              <select value={charterN} onChange={(e) => setCharterN(e.target.value)}>
                <option value="">— select charter —</option>
                {charters.map((c) => <option key={c.n} value={String(c.n)}>#{c.n} {c.title}</option>)}
              </select>
            </label>
            <label className="fld">Depends-on (optional)<input value={dependsOn} onChange={(e) => setDependsOn(e.target.value)} placeholder="Issue number, e.g. 42" /></label>
          </>
        )}
        <div className="m-actions">
          <button className="btn" onClick={onClose}>Cancel</button>
          <button className="btn pri" data-testid="ni-submit" disabled={!isValid || submitting} onClick={handleSubmit}>{submitting ? 'Creating…' : 'Create'}</button>
        </div>
      </div>
    </div>
  )
}

function SettingsModal({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const [url, setUrl] = useState(config.url)
  const [token, setToken] = useState(config.token)
  const bgRef = useRef<HTMLDivElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)
  const close = () => animateOverlayOut(bgRef, panelRef, onClose)
  return (
    <div ref={bgRef} className="modal-bg" onClick={close}>
      <div ref={panelRef} className="modal" onClick={(e) => e.stopPropagation()}>
        <h3>Connection</h3>
        <label className="fld">API URL<input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="http://127.0.0.1:8787" /></label>
        <label className="fld">API token<input value={token} onChange={(e) => setToken(e.target.value)} type="password" placeholder="CB_API_TOKEN" /></label>
        <p className="hint">Tunnel: <code>ssh -N -L 8787:127.0.0.1:8787 ec2-user@&lt;ip&gt;</code></p>
        <div className="m-actions"><button className="btn" onClick={close}>Close</button>
          <button className="btn pri" onClick={() => { config.url = url.trim(); config.token = token.trim(); onSaved() }}>Save & reconnect</button></div>
      </div>
    </div>
  )
}
