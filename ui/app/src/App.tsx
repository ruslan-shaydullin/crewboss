import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { command, config, createIssue, deleteComment, facilitateMessage, fetchChain, fetchComments, fetchTask, postQueue, resolveDecision, subscribe, type Agent, type ChainData, type FacilitateMessage, type IssueComment, type IssuePayload, type IssueResult, type LoopInfo, type State, type Task, type TaskDetail } from './api'
import TeamPage from './TeamPage'

// ── Lifecycle stage badge helpers ──────────────────────────────────────────
const STATE_LIFECYCLE: Record<string, { label: string; modifier: string }> = {
  'open':        { label: 'concept',      modifier: 'concept' },
  'needs-plan':  { label: 'analysis',     modifier: 'analysis' },
  'plan-review': { label: 'plan-review',  modifier: 'plan-review' },
  'approved':    { label: 'executing',    modifier: 'executing' },
  'in-progress': { label: 'executing',    modifier: 'executing' },
  'review':      { label: 'finale',       modifier: 'finale' },
  'done':        { label: 'done',         modifier: 'done' },
  'blocked':     { label: 'blocked',      modifier: 'blocked' },
  'held':        { label: 'hold',         modifier: 'held' },
}

function stateToLabel(state: string): string {
  return STATE_LIFECYCLE[state]?.label ?? state
}

function stateToModifier(state: string): string {
  return STATE_LIFECYCLE[state]?.modifier ?? state
}

/** Check whether a text contains a valid ## Acceptance (machine) block.
 *  Requires: the header line + at least one "- test: …" or "- check: …" entry. */
function hasValidAcceptanceBlock(text: string): boolean {
  if (!text.trim()) return false
  const lines = text.split('\n')
  let inBlock = false
  for (const line of lines) {
    if (/^## Acceptance \(machine\)/.test(line)) { inBlock = true; continue }
    if (inBlock && /^## /.test(line)) break
    if (inBlock && /^\s*- (test|check): .+/.test(line)) return true
  }
  return false
}

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

  // Queue state
  const [queueOrder, setQueueOrder] = useState<number[]>([])
  const [savedOrder, setSavedOrder] = useState<number[]>([])
  const [pendingQueue, setPendingQueue] = useState<number[]>([])
  const dirtyRef = useRef(false)

  const isLoopRunning = state?.loop?.running ?? false

  const onPendingAdd = useCallback((n: number) => {
    setPendingQueue(prev => [...prev, n])
  }, [])

  useEffect(() => subscribe((s) => {
    setState(s)
    // Sync queue from server only if user is not actively editing
    if (!dirtyRef.current) {
      setQueueOrder(s.queue?.order ?? [])
    }
  }, setConn), [])
  useEffect(() => { const i = setInterval(() => setTick((x) => x + 1), 1000); return () => clearInterval(i) }, [])

  const handleQueueChange = useCallback(async (newOrder: number[]) => {
    dirtyRef.current = true
    setQueueOrder(newOrder)
    try {
      await postQueue(newOrder)
      dirtyRef.current = false
      setSavedOrder(newOrder)
    } catch {
      dirtyRef.current = true
    }
  }, [])

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
  const resolveAsk = useCallback((n: number) => {
    ask(`Решить задачу #${n}`, 'Опишите решение (опционально):', (text) => run('resolve-decision', n, text ?? ''), true)
  }, [ask, run])

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
            <Board state={state} conn={conn} onAction={run} ask={ask} onOpen={setOpen}
              queueOrder={queueOrder} onQueueChange={handleQueueChange}
              loopRunning={isLoopRunning} onPendingAdd={onPendingAdd} />
            <div className="sidebar-col">
              <aside className="sidebar">
                <AgentsRail agents={state?.agents ?? []} onOpen={setOpen} />
              </aside>
              <div className="queue-panel--sticky">
                <QueuePanel
                  queueOrder={queueOrder}
                  savedOrder={savedOrder}
                  board={state?.board ?? []}
                  isLoopRunning={isLoopRunning}
                  onQueueChange={handleQueueChange}
                  onLaunch={async () => { await handleQueueChange(queueOrder); run('run') }}
                  pendingQueue={pendingQueue}
                  onRemovePending={(n) => setPendingQueue(prev => prev.filter(x => x !== n))}
                />
              </div>
            </div>
          </div>
        </>
      ) : view === 'human' ? (
        <HumanDecisionsPage state={state} onOpen={setOpen} onResolve={resolveAsk} />
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
  const running = state?.agents?.filter(a => a.phase !== 'awaiting').length ?? 0
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
      {state?.loop && <LoopBadge loop={state.loop} />}
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

function LoopBadge({ loop }: { loop: LoopInfo }) {
  return (
    <div className="loop-badge" data-testid="loop-badge" data-integrate={String(loop.integrate)}>
      <span className={'loop-integrate' + (loop.integrate ? ' on' : ' off')}>
        {loop.integrate ? 'integration ON' : 'integration OFF'}
      </span>
      <span className="loop-sep">·</span>
      <span className="loop-ticks" title="CB_MAX_TICKS">ticks:{loop.max_ticks}</span>
      <span className="loop-sep">·</span>
      <span className="loop-parallel" title="CB_MAX_PARALLEL">×{loop.max_parallel}</span>
      {loop.running && <><span className="loop-sep">·</span><span className="loop-running">running</span></>}
      {loop.stage && loop.stage !== 'idle' && (
        <>
          <span className="loop-sep">·</span>
          <span
            className={'loop-stage stage-' + loop.stage}
            data-testid="loop-stage"
          >
            {loop.stage}
          </span>
        </>
      )}
    </div>
  )
}

// ── Collapse-state persistence ─────────────────────────────────────────────
const COLLAPSE_LS_KEY = 'cb_collapse'
function readCollapseMap(): Record<string, boolean> {
  try { return JSON.parse(localStorage.getItem(COLLAPSE_LS_KEY) ?? '{}') } catch { return {} }
}
function writeCollapseMap(m: Record<string, boolean>) {
  try { localStorage.setItem(COLLAPSE_LS_KEY, JSON.stringify(m)) } catch {}
}

const CHARTER_SECTIONS = [
  { key: 'sec-inprogress', label: 'В работе',  states: new Set(['approved','in-progress','plan-review','review']),  defaultExpanded: true  },
  { key: 'sec-new',        label: 'Новые',      states: new Set(['open','needs-plan','needs-analysis','team-review','blocked','held']), defaultExpanded: true  },
  { key: 'sec-done',       label: 'Выполнено',  states: new Set(['done','CLOSED']),                                       defaultExpanded: false },
] as const

function Board({ state, conn, onAction, ask, onOpen, queueOrder, onQueueChange, loopRunning, onPendingAdd }: {
  state: State | null; conn: boolean
  onAction: (a: string, n?: number, comment?: string) => void; ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void; onOpen: (n: number) => void
  queueOrder: number[]; onQueueChange: (order: number[]) => void
  loopRunning: boolean; onPendingAdd: (n: number) => void
}) {
  // Collapse state — always call hooks before any early return
  const [collapseMap, setCollapseMap] = useState<Record<string, boolean>>(readCollapseMap)
  const getExpanded = (n: number, def: boolean) => {
    const k = String(n)
    return k in collapseMap ? collapseMap[k] : def
  }
  const doToggle = (n: number, def: boolean) => {
    setCollapseMap((prev) => {
      const k = String(n)
      const cur = k in prev ? prev[k] : def
      const next = { ...prev, [k]: !cur }
      writeCollapseMap(next)
      return next
    })
  }

  const getSectionExpanded = (key: string, def: boolean) =>
    key in collapseMap ? collapseMap[key] : def

  const doSectionToggle = (key: string, def: boolean) => {
    setCollapseMap((prev) => {
      const cur = key in prev ? prev[key] : def
      const next = { ...prev, [key]: !cur }
      writeCollapseMap(next)
      return next
    })
  }

  if (!state) return (
    <section className="board">
      <SkeletonBoard />
      {!conn && <div className="skel-hint">offline — open ⚙ to set API URL + token, and start the SSH tunnel</div>}
    </section>
  )
  const milestones = state.board.filter((x) => x.kind === 'milestone')
  const charters = state.board.filter((x) => x.kind === 'charter')
  const leaves = state.board.filter((x) => x.kind === 'leaf')
  const orphans = leaves.filter((l) => !l.charter || !charters.some((c) => c.n === l.charter))
  const milestonedCharterNs = new Set(
    milestones.flatMap((m) => charters.filter((c) => c.milestone === m.n).map((c) => c.n))
  )
  const unmilestoned = charters.filter((c) => !milestonedCharterNs.has(c.n))
  if (!state.board.length) return <section className="board"><div className="empty">no issues on the board yet</div></section>
  return (
    <section className="board">
      {milestones.map((m) => {
        const milestoneDefault = m.state !== 'CLOSED' && m.state !== 'done'
        return (
          <MilestoneGroup
            key={m.n}
            milestone={m}
            charters={charters.filter((c) => c.milestone === m.n)}
            leaves={leaves}
            onAction={onAction}
            ask={ask}
            onOpen={onOpen}
            expanded={getExpanded(m.n, milestoneDefault)}
            onToggle={() => doToggle(m.n, milestoneDefault)}
            getExpanded={getExpanded}
            doToggle={doToggle}
            queueOrder={queueOrder}
            onQueueChange={onQueueChange}
            loopRunning={loopRunning}
            onPendingAdd={onPendingAdd}
          />
        )
      })}
      {CHARTER_SECTIONS.map((sec) => (
        <CharterSection
          key={sec.key}
          sectionKey={sec.key}
          label={sec.label}
          charters={unmilestoned.filter((c) => sec.states.has(c.state))}
          leaves={leaves}
          expanded={getSectionExpanded(sec.key, sec.defaultExpanded)}
          onToggle={() => doSectionToggle(sec.key, sec.defaultExpanded)}
          onAction={onAction} ask={ask} onOpen={onOpen}
          getExpanded={getExpanded} doToggle={doToggle}
          queueOrder={queueOrder} onQueueChange={onQueueChange}
          loopRunning={loopRunning} onPendingAdd={onPendingAdd}
        />
      ))}
      {orphans.length > 0 && (
        <CharterCard
          c={null}
          leaves={orphans}
          onAction={onAction}
          ask={ask}
          onOpen={onOpen}
          expanded={getExpanded(0, true)}
          onToggle={() => doToggle(0, true)}
          queueOrder={queueOrder}
          onQueueChange={onQueueChange}
          loopRunning={loopRunning}
          onPendingAdd={onPendingAdd}
        />
      )}
    </section>
  )
}

function CharterSection({ sectionKey, label, charters, leaves, expanded, onToggle, onAction, ask, onOpen, getExpanded, doToggle, queueOrder, onQueueChange, loopRunning, onPendingAdd }: {
  sectionKey: string; label: string; charters: Task[]; leaves: Task[]
  expanded: boolean; onToggle: () => void
  onAction: (a: string, n?: number, comment?: string) => void
  ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void
  onOpen: (n: number) => void
  getExpanded: (n: number, def: boolean) => boolean
  doToggle: (n: number, def: boolean) => void
  queueOrder: number[]; onQueueChange: (order: number[]) => void
  loopRunning: boolean; onPendingAdd: (n: number) => void
}) {
  if (charters.length === 0) return null
  const bodyId = `charter-section-body-${sectionKey}`
  const childrenOf = (cn: number) => leaves.filter((l) => l.charter === cn)
  return (
    <div className="charter-section" data-testid="charter-section" data-section-key={sectionKey}>
      <div className="charter-section-head">
        <button
          className={'chevron-btn' + (expanded ? ' expanded' : ' collapsed')}
          aria-expanded={expanded} aria-controls={bodyId} onClick={onToggle}
          aria-label={expanded ? 'Collapse' : 'Expand'}
        ><span className="chevron">▶</span></button>
        <span className="charter-section-label">{label}</span>
        <span className="charter-section-count">{charters.length}</span>
      </div>
      <div id={bodyId} style={expanded ? undefined : { display: 'none' }}>
        {charters.map((c) => (
          <CharterCard key={c.n} c={c} leaves={childrenOf(c.n)}
            onAction={onAction} ask={ask} onOpen={onOpen}
            expanded={getExpanded(c.n, true)} onToggle={() => doToggle(c.n, true)}
            queueOrder={queueOrder} onQueueChange={onQueueChange}
            loopRunning={loopRunning} onPendingAdd={onPendingAdd} />
        ))}
      </div>
    </div>
  )
}

function MilestoneGroup({ milestone, charters, leaves, onAction, ask, onOpen, expanded, onToggle, getExpanded, doToggle, queueOrder, onQueueChange, loopRunning, onPendingAdd }: {
  milestone: Task; charters: Task[]; leaves: Task[]
  onAction: (a: string, n?: number, comment?: string) => void
  ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void
  onOpen: (n: number) => void
  expanded: boolean; onToggle: () => void
  getExpanded: (n: number, def: boolean) => boolean
  doToggle: (n: number, def: boolean) => void
  queueOrder: number[]; onQueueChange: (order: number[]) => void
  loopRunning: boolean; onPendingAdd: (n: number) => void
}) {
  const bodyId = `milestone-body-${milestone.n}`
  const childrenOf = (cn: number) => leaves.filter((l) => l.charter === cn)
  return (
    <div className="milestone-group">
      <div className="charter-head">
        <button
          className={'chevron-btn' + (expanded ? ' expanded' : ' collapsed')}
          aria-expanded={expanded}
          aria-controls={bodyId}
          onClick={onToggle}
          aria-label={expanded ? 'Collapse' : 'Expand'}
        ><span className="chevron">▶</span></button>
        <div className="charter-id">
          <span className="num">#{milestone.n}</span>
          <span className={'badge b-' + milestone.state}>{milestone.state}</span>
        </div>
        <div className="charter-title" onClick={() => onOpen(milestone.n)} style={{ cursor: 'pointer' }}>{milestone.title}</div>
        <div className="grow" />
      </div>
      <div id={bodyId} className="milestone-body" style={expanded ? undefined : { display: 'none' }}>
        {charters.map((c) => (
          <CharterCard
            key={c.n}
            c={c}
            leaves={childrenOf(c.n)}
            onAction={onAction}
            ask={ask}
            onOpen={onOpen}
            expanded={getExpanded(c.n, true)}
            onToggle={() => doToggle(c.n, true)}
            queueOrder={queueOrder}
            onQueueChange={onQueueChange}
            loopRunning={loopRunning}
            onPendingAdd={onPendingAdd}
          />
        ))}
      </div>
    </div>
  )
}

function HumanDecisionsPage({ state, onOpen, onResolve }: {
  state: State | null; onOpen: (n: number) => void; onResolve: (n: number) => void
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
          onResolve={onResolve}
        />
      ))}
      {orphans.length > 0 && (
        <HumanCharterGroup charter={null} tasks={orphans} onOpen={onOpen} onResolve={onResolve} />
      )}
    </section>
  )
}

function HumanCharterGroup({ charter, tasks, onOpen, onResolve }: {
  charter: Task | null; tasks: Task[]; onOpen: (n: number) => void; onResolve: (n: number) => void
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
        {tasks.map((t) => <HumanTaskCard key={t.n} t={t} onOpen={onOpen} onResolve={onResolve} />)}
      </div>
    </div>
  )
}

function HumanTaskCard({ t, onOpen, onResolve }: { t: Task; onOpen: (n: number) => void; onResolve: (n: number) => void }) {
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
        <button
          className="btn sm pri"
          data-testid="resolve-btn"
          onClick={(e) => { e.stopPropagation(); onResolve(t.n) }}
        >Решить</button>
      </div>
    </div>
  )
}

function CharterCard({ c, leaves, onAction, ask, onOpen, expanded, onToggle, queueOrder, onQueueChange, loopRunning, onPendingAdd }: {
  c: Task | null; leaves: Task[]; onAction: (a: string, n?: number, comment?: string) => void
  ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void; onOpen: (n: number) => void
  expanded: boolean; onToggle: () => void
  queueOrder: number[]; onQueueChange: (order: number[]) => void
  loopRunning: boolean; onPendingAdd: (n: number) => void
}) {
  const done = leaves.filter((l) => l.state === 'done').length
  const total = leaves.length
  const pct = total > 0 ? Math.round((100 * done) / total) : 0
  const gridRef = useRef<HTMLDivElement>(null)
  useFlip(gridRef)
  const bodyId = `charter-body-${c?.n ?? 0}`
  const [mergeErr, setMergeErr] = useState<string | null>(null)
  return (
    <div className="charter">
      <div className="charter-head">
        <button
          className={'chevron-btn' + (expanded ? ' expanded' : ' collapsed')}
          aria-expanded={expanded}
          aria-controls={bodyId}
          onClick={onToggle}
          aria-label={expanded ? 'Collapse' : 'Expand'}
        ><span className="chevron">▶</span></button>
        <div className="charter-id">
          {c ? <span className="num">#{c.n}</span> : <span className="num">∅</span>}
          {c && <span className={'badge b-' + c.state}>{c.state}</span>}
          {c && c.rework_n != null && c.rework_n > 0 && (
            <span
              className="rework-badge"
              title={c.rework_n + ' re-check cycle(s)'}
              data-testid="rework-badge"
            >
              {'↺'}{c.rework_n}
            </span>
          )}
          {c && c.git_status === 'needs-conflict-resolution' && (
            <span
              className="conflict-badge"
              title="Branch has merge conflicts — resolve before integrating"
              data-testid="conflict-badge"
            >
              ⚡ conflict
            </span>
          )}
          {c && c.git_status === 'clean' && (
            <span
              className="git-clean-badge"
              title="Branch is current with main — auto-rebase keeps it fresh (#187)"
              data-testid="git-clean-badge"
            >
              ✓ git
            </span>
          )}
          {c && c.blast_radius === 'high' && (
            <span
              className="blast-radius-badge"
              title="High blast-radius: serializes the queue — other charters wait"
              data-testid="blast-radius-badge"
            >
              ⊘ serializes
            </span>
          )}
          {c && (
            <span
              className={`lifecycle-badge lifecycle-badge--${stateToModifier(c.state)}`}
              data-testid="lifecycle-badge"
            >
              {stateToLabel(c.state)}
            </span>
          )}
        </div>
        <div className="charter-title" onClick={() => c && onOpen(c.n)} style={c ? { cursor: 'pointer' } : undefined}>{c ? c.title : 'Unassigned tasks'}</div>
        <div className="grow" />
        {total > 0 && <Ring pct={pct} label={`${done}/${total}`} />}
        {c && (() => {
          const isQueued = queueOrder.includes(c.n)
          return (
            <button
              className={'queue-btn--add' + (isQueued ? ' queue-btn--queued' : '')}
              disabled={isQueued}
              data-testid="queue-add-btn"
              data-charter-n={c.n}
              onClick={() => {
                if (!isQueued) {
                  if (loopRunning) {
                    onPendingAdd(c.n)
                  } else {
                    onQueueChange([...queueOrder, c.n])
                  }
                }
              }}
            >
              {isQueued ? '✓ Queued' : '+ Queue'}
            </button>
          )
        })()}
        {c && c.state === 'plan-review' && <>
          <button className="btn sm pri" onClick={() => ask('Approve plan #' + c.n,
            "Releases this charter's tasks to be launched (executors run, spending from the pool).",
            () => onAction('approve', c.n))}>Approve plan</button>
          <button className="btn sm ghost" onClick={() => ask('Request changes #' + c.n,
            'Опишите, что нужно доработать в плане:',
            (reason) => onAction('request-changes', c.n, reason),
            true)}>Request changes</button>
        </>}
        {c && c.state === 'approved' && c.finale_pr && (
          <>
            <button className="btn sm pri" onClick={async () => {
              setMergeErr(null)
              const r = await command('merge', c.n)
              if (!r.ok) setMergeErr(r.msg || 'merge failed')
            }}>Merge</button>
            {mergeErr && <span className="err-inline">{mergeErr}</span>}
          </>
        )}
      </div>
      <div id={bodyId} style={expanded ? undefined : { display: 'none' }}>
        {total > 0 && (
          <div className="task-grid" ref={gridRef}>
            {leaves.map((l) => <TaskCard key={l.n} t={l} onOpen={onOpen} />)}
          </div>
        )}
        {total === 0 && <div className="leaf-empty">awaiting decomposition…</div>}
      </div>
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

function QueuePanel({ queueOrder, savedOrder, board, isLoopRunning, onQueueChange, onLaunch, pendingQueue, onRemovePending }: {
  queueOrder: number[]
  savedOrder: number[]
  board: Task[]
  isLoopRunning: boolean
  onQueueChange: (order: number[]) => Promise<void>
  onLaunch: () => Promise<void>
  pendingQueue: number[]
  onRemovePending: (n: number) => void
}) {
  const [isEditing, setIsEditing] = useState(false)
  const charterMap = new Map(board.filter((t) => t.kind === 'charter').map((t) => [t.n, t]))
  const isDirty = JSON.stringify(queueOrder) !== JSON.stringify(savedOrder)
  const move = (idx: number, dir: -1 | 1) => {
    const newOrder = [...queueOrder]
    const target = idx + dir
    if (target < 0 || target >= newOrder.length) return
    ;[newOrder[idx], newOrder[target]] = [newOrder[target], newOrder[idx]]
    onQueueChange(newOrder)
  }
  const remove = (idx: number) => {
    const newOrder = queueOrder.filter((_, i) => i !== idx)
    onQueueChange(newOrder)
  }
  const launchLabel = isEditing
    ? '💾 Сохранить'
    : isLoopRunning
    ? '✎ Редактировать'
    : '▶ Запустить очередь'
  const handleLaunchBtn = async () => {
    if (isEditing) {
      setIsEditing(false)
    } else if (isLoopRunning) {
      setIsEditing(true)
    } else {
      await onLaunch()
    }
  }
  return (
    <div className="queue-panel" data-testid="queue-panel">
      <div className="queue-panel__head">
        <span>Queue</span>
        <span className="queue-panel__count">{queueOrder.length}</span>
        {isDirty && (
          <span className="queue-panel__dirty" data-testid="queue-dirty-indicator" title="Unsaved changes">●</span>
        )}
      </div>
      {queueOrder.length === 0 ? (
        <div className="queue-panel__empty" data-testid="queue-empty">
          Queue is empty — click + Queue on a charter card
        </div>
      ) : (
        <ol className="queue-panel__list">
          {queueOrder.map((n, idx) => {
            const charter = charterMap.get(n)
            return (
              <li key={n} className="queue-panel__item" data-testid="queue-item" data-n={n}>
                <span className="queue-panel__pos">{idx + 1}.</span>
                <span className="queue-panel__label">
                  <span className="num">#{n}</span>
                  {charter && <span className="queue-panel__title"> — {charter.title}</span>}
                </span>
                <div className="queue-panel__controls">
                  <button className="btn ghost xs" onClick={() => move(idx, -1)} disabled={idx === 0} aria-label="Move up">↑</button>
                  <button className="btn ghost xs" onClick={() => move(idx, 1)} disabled={idx === queueOrder.length - 1} aria-label="Move down">↓</button>
                  <button className="btn ghost xs" onClick={() => remove(idx)} aria-label="Remove from queue" data-testid="queue-remove-btn">✕</button>
                </div>
              </li>
            )
          })}
        </ol>
      )}
      <button
        className="queue-btn--launch"
        disabled={!isEditing && !isLoopRunning && queueOrder.length === 0}
        data-testid="queue-launch-btn"
        onClick={handleLaunchBtn}
      >
        {launchLabel}
      </button>
      {pendingQueue.length > 0 && (
        <div className="queue-panel__pending" data-testid="queue-pending-section">
          <div className="queue-panel__pending-head">Pending</div>
          <ol className="queue-panel__list">
            {pendingQueue.map((n) => {
              const charter = charterMap.get(n)
              return (
                <li key={n} className="queue-panel__item queue-panel__item--pending" data-testid="queue-pending-item" data-n={n}>
                  <span className="queue-panel__label">
                    <span className="num">#{n}</span>
                    {charter && <span className="queue-panel__title"> — {charter.title}</span>}
                  </span>
                  <button
                    className="btn sm pri"
                    data-testid="queue-pending-confirm-btn"
                    onClick={() => {
                      onQueueChange([...queueOrder, n])
                      onRemovePending(n)
                    }}
                  >Подтвердить добавление</button>
                </li>
              )
            })}
          </ol>
        </div>
      )}
    </div>
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
      className={'agent role-' + a.role + (a.phase === 'awaiting' ? ' agent--awaiting' : '')}
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
  const [resolveText, setResolveText] = useState('')
  const [resolving, setResolving] = useState(false)
  const [mergeErr, setMergeErr] = useState<string | null>(null)
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

  const close = () => animateOverlayOut(bgRef, panelRef, onClose, 'right')

  const phase = d?.status.phase ?? (d?.alive ? 'running' : '—')
  const cost = d?.status.cost_usd
  const pr = d?.status.pr || task?.pr

  const checkboxItems = parseCheckboxes(d?.body ?? '')
  const historyComments = comments.filter((c) => HISTORY_MARKERS.some((p) => c.body.startsWith(p)))
  const discussionComments = comments.filter((c) => !HISTORY_MARKERS.some((p) => c.body.startsWith(p)))

  const CONVERGENCE_MARKERS = [
    'needs-rework', 'verify-merged', 're-check', 'request-changes',
    'plan failed', 'rework', 'analyst',
  ]
  const convComments = comments.filter((c) => {
    const lower = c.body.toLowerCase()
    return CONVERGENCE_MARKERS.some((m) => lower.includes(m))
  })

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

        {task?.kind === 'charter' && (
          <div className="convergence-section" data-testid="convergence-section">
            <div className="drawer-section">
              Convergence
              {(task.rework_n ?? 0) > 0
                ? <span className="conv-count" data-testid="conv-count">
                    {'↺'}{task.rework_n} re-check{task.rework_n === 1 ? '' : 's'}
                  </span>
                : <span className="conv-clean" data-testid="conv-clean">clean</span>
              }
            </div>
            {convComments.length > 0 ? (
              <div className="conv-feed" data-testid="conv-feed">
                {convComments.map((c) => (
                  <div key={c.id} className="conv-event">
                    <span className="conv-meta">
                      <span className="conv-author">{c.author}</span>
                      <span className="conv-ts">
                        {new Date(c.created).toLocaleString()}
                      </span>
                    </span>
                    <pre className="conv-body">
                      {c.body.length > 320 ? c.body.slice(0, 320) + '…' : c.body}
                    </pre>
                  </div>
                ))}
              </div>
            ) : (
              <div className="conv-empty" data-testid="conv-empty">no re-checks yet</div>
            )}
          </div>
        )}

        {task?.kind === 'charter' && (task.state === 'needs-plan' || task.state === 'plan-review') && (
          <>
            <div className="drawer-section">Role Chain</div>
            <RoleChain n={n} />
          </>
        )}

        {task?.kind === 'charter' && ['approved', 'in-progress', 'review', 'done'].includes(task.state) && (
          <>
            <div className="drawer-section">Pipeline</div>
            <PipelineView n={n} />
          </>
        )}

        {task && task.state !== 'done' && (
          <div className="drawer-actions">
            {task.state === 'plan-review' && <>
              <button className="btn sm pri" onClick={() => ask('Approve plan #' + n, "Releases this charter's tasks to be launched.", () => onAction('approve', n))}>Approve plan</button>
              <button className="btn sm ghost" onClick={() => ask('Request changes #' + n,
                'Опишите, что нужно доработать в плане:',
                (reason) => onAction('request-changes', n, reason),
                true)}>Request changes</button>
            </>}
            {task.state === 'approved' && task.finale_pr && (
              <>
                <button className="btn sm pri" onClick={async () => {
                  setMergeErr(null)
                  const r = await command('merge', n)
                  if (!r.ok) setMergeErr(r.msg || 'merge failed')
                }}>Merge</button>
                {mergeErr && <span className="err-inline">{mergeErr}</span>}
              </>
            )}
            {task.state === 'held'
              ? <button className="btn sm" onClick={() => onAction('unhold', n)}>Un-hold</button>
              : <button className="btn sm ghost" onClick={() => onAction('hold', n)}>Hold</button>}
          </div>
        )}

        {task && task.labels.includes('type:human-decision') && task.state !== 'done' && (
          <>
            <div className="drawer-section">Решить задачу</div>
            <div className="disc-compose">
              <textarea
                className="disc-input"
                value={resolveText}
                onChange={(e) => setResolveText(e.target.value)}
                placeholder="Текст решения (опционально)…"
                rows={3}
                data-testid="resolve-text"
              />
              <button
                className="btn sm pri"
                data-testid="resolve-submit-btn"
                disabled={resolving}
                onClick={async () => {
                  setResolving(true)
                  const r = await resolveDecision(n, resolveText)
                  setResolving(false)
                  toast(r.msg || (r.ok ? 'resolved' : 'failed'), !r.ok)
                  if (r.ok) close()
                }}
              >{resolving ? 'Решение…' : 'Решить'}</button>
            </div>
          </>
        )}

        {d?.prompt && <><div className="drawer-section">Brief</div><div className="brief">{d.prompt}</div></>}

        {checkboxItems.length > 0 && (
          <>
            <div className="drawer-section" data-testid="checklist-section">Checklist</div>
            <div className="checklist">
              {checkboxItems.map((item) => (
                <div
                  key={item.index}
                  className="checklist-item"
                  data-testid="checklist-item"
                  data-index={item.index}
                >
                  <span className={'checklist-box' + (item.checked ? ' checklist-box-checked' : '')} aria-hidden="true">
                    {item.checked ? '✓' : ''}
                  </span>
                  <span className={item.checked ? 'checked' : ''}>{item.text}</span>
                </div>
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

// ── RoleChain: pre-approval composition view ─────────────────────────────
function RoleChain({ n }: { n: number }) {
  const [chain, setChain] = useState<ChainData | null>(null)
  const [expanded, setExpanded] = useState<Set<number>>(new Set())

  useEffect(() => {
    let active = true
    fetchChain(n).then((data) => { if (active) setChain(data) }).catch(() => {})
    return () => { active = false }
  }, [n])

  if (!chain || chain.length === 0) return <div className="role-chain-empty muted">нет данных о цепочке ролей</div>

  const toggle = (idx: number) => {
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(idx)) next.delete(idx); else next.add(idx)
      return next
    })
  }

  return (
    <div className="role-chain" data-testid="role-chain">
      {chain.map((step, i) => (
        <div key={step.step_index} className="role-chain-node" onClick={() => toggle(step.step_index)} title="Нажмите для просмотра плана">
          <div className="role-chain-node-inner">
            <span className="role-chain-index">{i + 1}</span>
            <span className="role-chain-label">{step.role}</span>
            <span className="role-chain-chevron">{expanded.has(step.step_index) ? '▾' : '▸'}</span>
          </div>
          {expanded.has(step.step_index) && (
            <div className="role-chain-plan">
              {step.plan ? step.plan : 'в планировании'}
            </div>
          )}
          {i < chain.length - 1 && <div className="role-chain-connector" aria-hidden="true" />}
        </div>
      ))}
    </div>
  )
}

// ── PipelineView: post-approval GHA-style pipeline ───────────────────────
function PipelineView({ n }: { n: number }) {
  const [chain, setChain] = useState<ChainData | null>(null)

  useEffect(() => {
    let active = true
    fetchChain(n).then((data) => { if (active) setChain(data) }).catch(() => {})
    return () => { active = false }
  }, [n])

  if (!chain || chain.length === 0) return <div className="pipeline-empty muted">нет данных о пайплайне</div>

  return (
    <div className="pipeline-view" data-testid="pipeline-view">
      {chain.map((step, i) => (
        <div key={i} className="pipeline-step-wrap">
          <div className={'pipeline-step pipeline-step--' + step.status} title={step.role + ' · ' + step.status}>
            <span className="pipeline-step-role">{step.role}</span>
            <span className={'pipeline-step-dot pipeline-dot--' + step.status} />
          </div>
          {i < chain.length - 1 && <div className="pipeline-arrow" aria-hidden="true">→</div>}
        </div>
      ))}
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
  const [autoPlanApprove, setAutoPlanApprove] = useState(false)
  const [autoMerge, setAutoMerge] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [step, setStep] = useState<'form' | 'discuss' | 'summary'>('form')
  const [charterSuccess, setCharterSuccess] = useState<IssueResult | null>(null)
  const [launching, setLaunching] = useState(false)

  // Facilitator discussion state
  const [chatMessages, setChatMessages] = useState<FacilitateMessage[]>([])
  const [chatInput, setChatInput] = useState('')
  const [facilitating, setFacilitating] = useState(false)
  const [acceptanceBlock, setAcceptanceBlock] = useState('')
  const [facilitatorError, setFacilitatorError] = useState<string | null>(null)

  const charters = (state?.board ?? []).filter((x) => x.kind === 'charter')
  const charterLabel = charters.find((c) => String(c.n) === charterN)

  const isValid = kind === 'charter'
    ? !!(title.trim() && what.trim() && why.trim())
    : !!(title.trim() && description.trim() && charterN)

  const isBlockValid = hasValidAcceptanceBlock(acceptanceBlock)

  const handleFacilitate = async () => {
    const msg = chatInput.trim()
    if (!msg) return
    setChatInput('')
    const newHistory: FacilitateMessage[] = [...chatMessages, { role: 'user', content: msg }]
    setChatMessages(newHistory)
    setFacilitating(true)
    setFacilitatorError(null)
    try {
      const draft: Record<string, unknown> = kind === 'charter'
        ? { title, what, why, scope, constraints }
        : { title, description, charter: charterN, depends_on: dependsOn }
      const r = await facilitateMessage(kind, draft, msg, chatMessages)
      if (r.ok) {
        setChatMessages([...newHistory, { role: 'facilitator', content: r.message }])
        if (r.acceptance_block) {
          setAcceptanceBlock(r.acceptance_block)
        }
      } else {
        setFacilitatorError(r.message)
      }
    } finally {
      setFacilitating(false)
    }
  }

  const handleSubmit = async () => {
    if (!isValid || submitting) return
    const p: IssuePayload = kind === 'charter'
      ? { kind: 'charter', title, what, why, scope, constraints, acceptance, acceptance_block: acceptanceBlock.trim() || undefined, auto_plan_approve: autoPlanApprove, auto_merge: autoMerge }
      : { kind: 'task', title, description, charter: Number(charterN), depends_on: dependsOn.trim() || undefined, acceptance_block: acceptanceBlock.trim() || undefined }
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

  if (step === 'discuss') {
    return (
      <div className="modal-bg" data-testid="ni-discuss-backdrop" onClick={onClose}>
        <div className="modal ni-modal ni-discuss-modal" data-testid="ni-discuss-panel" onClick={(e) => e.stopPropagation()}>
          <div className="ni-head">
            <h3>Обсуждение с фасилитатором</h3>
            <button className="btn ghost" onClick={onClose}>✕</button>
          </div>

          {/* Chat section */}
          <div className="ni-chat" data-testid="ni-facilitator-chat">
            {chatMessages.length === 0 && !facilitatorError && (
              <div className="ni-chat-hint muted">
                Опишите что нужно — фасилитатор задаст уточняющие вопросы и предложит блок Acceptance (machine). Или заполните блок ниже вручную.
              </div>
            )}
            {facilitatorError && (
              <div className="ni-facilitator-error" data-testid="ni-facilitator-error">
                {facilitatorError}
              </div>
            )}
            {chatMessages.map((m, i) => (
              <div
                key={i}
                className={'ni-chat-msg ni-chat-' + m.role}
                data-testid="ni-chat-message"
                data-role={m.role}
              >
                <span className="ni-chat-role">{m.role === 'user' ? 'Вы' : 'Фасилитатор'}</span>
                <span className="ni-chat-content">{m.content}</span>
              </div>
            ))}
            {facilitating && <div className="ni-chat-loading muted">Фасилитатор думает…</div>}
          </div>

          {/* Chat input */}
          <div className="ni-chat-compose">
            <textarea
              className="disc-input"
              data-testid="ni-chat-input"
              value={chatInput}
              onChange={(e) => setChatInput(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey) && chatInput.trim() && !facilitating) handleFacilitate() }}
              placeholder="Ваш ответ или уточнение…"
              rows={2}
              disabled={facilitating}
            />
            <button
              className="btn sm pri"
              data-testid="ni-chat-send"
              disabled={!chatInput.trim() || facilitating}
              onClick={handleFacilitate}
            >{facilitating ? 'Отправка…' : 'Отправить'}</button>
          </div>

          {/* Acceptance block manual entry / auto-populated */}
          <div className="ni-acceptance-section">
            <label className="fld">
              <span>Acceptance (machine) <span className="ni-required">*</span></span>
              <textarea
                data-testid="ni-acceptance-input"
                className="ni-acceptance-textarea"
                value={acceptanceBlock}
                onChange={(e) => setAcceptanceBlock(e.target.value)}
                placeholder={'## Acceptance (machine)\n- check: make test\n- test: path/to/test.sh'}
                rows={5}
              />
            </label>
            {acceptanceBlock.trim() && (
              isBlockValid
                ? <div className="ni-acceptance-valid" data-testid="ni-acceptance-valid">✓ Валидный блок</div>
                : <div className="ni-acceptance-invalid" data-testid="ni-acceptance-invalid">✗ Нужен заголовок «## Acceptance (machine)» и минимум одна строка «- test: …» или «- check: …»</div>
            )}
          </div>

          <div className="m-actions">
            <button className="btn" data-testid="ni-discuss-back" onClick={() => setStep('form')}>← Назад</button>
            <button
              className="btn pri"
              data-testid="ni-discuss-continue"
              disabled={!isBlockValid}
              onClick={() => setStep('summary')}
            >Продолжить →</button>
          </div>
        </div>
      </div>
    )
  }

  if (step === 'summary') {
    return (
      <div className="modal-bg" data-testid="ni-summary-backdrop" onClick={onClose}>
        <div className="modal ni-modal ni-summary-modal" data-testid="ni-summary-panel" onClick={(e) => e.stopPropagation()}>
          <div className="ni-head">
            <h3>Подтвердить создание</h3>
            <button className="btn ghost" onClick={onClose}>✕</button>
          </div>
          <div className="ni-summary" data-testid="ni-summary-body">
            <div className="ni-summary-kind" data-testid="ni-summary-kind">
              {kind === 'charter' ? 'Charter' : 'Task'}
            </div>
            <div className="ni-summary-title" data-testid="ni-summary-title">{title}</div>
            {kind === 'charter' ? (
              <div className="ni-summary-sections">
                <div className="ni-summary-section">
                  <div className="ni-summary-label">WHAT</div>
                  <div className="ni-summary-value" data-testid="ni-summary-what">{what}</div>
                </div>
                <div className="ni-summary-section">
                  <div className="ni-summary-label">WHY</div>
                  <div className="ni-summary-value" data-testid="ni-summary-why">{why}</div>
                </div>
                {scope.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Скоуп</div>
                    <div className="ni-summary-value">{scope}</div>
                  </div>
                )}
                {constraints.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Констрейнты</div>
                    <div className="ni-summary-value">{constraints}</div>
                  </div>
                )}
                {acceptance.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Acceptance</div>
                    <div className="ni-summary-value">{acceptance}</div>
                  </div>
                )}
                {acceptanceBlock.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Acceptance (machine)</div>
                    <div className="ni-summary-value" data-testid="ni-summary-acceptance-block">{acceptanceBlock}</div>
                  </div>
                )}
              </div>
            ) : (
              <div className="ni-summary-sections">
                <div className="ni-summary-section">
                  <div className="ni-summary-label">Description</div>
                  <div className="ni-summary-value" data-testid="ni-summary-description">{description}</div>
                </div>
                <div className="ni-summary-section">
                  <div className="ni-summary-label">Charter</div>
                  <div className="ni-summary-value" data-testid="ni-summary-charter">
                    #{charterN}{charterLabel ? ` ${charterLabel.title}` : ''}
                  </div>
                </div>
                {dependsOn.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Depends-on</div>
                    <div className="ni-summary-value" data-testid="ni-summary-depends">#{dependsOn.trim()}</div>
                  </div>
                )}
                {acceptanceBlock.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Acceptance (machine)</div>
                    <div className="ni-summary-value" data-testid="ni-summary-acceptance-block">{acceptanceBlock}</div>
                  </div>
                )}
              </div>
            )}
          </div>
          <div className="m-actions">
            <button className="btn" data-testid="ni-edit-btn" onClick={() => setStep('discuss')}>Редактировать</button>
            <button className="btn pri" data-testid="ni-confirm-btn" disabled={submitting} onClick={handleSubmit}>
              {submitting ? 'Creating…' : 'Подтвердить'}
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
            <label>
              <input type="checkbox" checked={autoPlanApprove}
                     onChange={e => setAutoPlanApprove(e.target.checked)} />
              {" "}Auto-approve plan (skip manual plan-review gate for this charter)
            </label>
            <label>
              <input type="checkbox" checked={autoMerge}
                     onChange={e => setAutoMerge(e.target.checked)} />
              {" "}Auto-merge on green CI (skip manual merge gate for this charter)
            </label>
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
          <button className="btn pri" data-testid="ni-submit" disabled={!isValid || submitting} onClick={() => { if (isValid) setStep('discuss') }}>{submitting ? 'Creating…' : 'Create'}</button>
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
