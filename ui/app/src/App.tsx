import { useCallback, useEffect, useRef, useState } from 'react'
import { command, postQueue, searchBoard, subscribe, type Agent, type LoopInfo, type State, type Task } from './api'
import TeamPage from './TeamPage'
import { DEMO_MODE } from './transport'
import { resetDemo } from './demo'
import NewIssueModal from './NewIssueModal'
import TaskDrawer from './TaskDrawer'
import QueuePanel from './QueuePanel'
import { Modal, SettingsModal } from './Dialogs'
import { useCountUp, useFlip, elapsed, prefersReducedMotion, type Toast } from './ui-interactions'

type Confirm = { title: string; body: string; onOk: (reason?: string) => void; withInput?: boolean } | null

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


export default function App() {
  const [session, setSession] = useState(0)
  return <DashboardSession key={session} onReconnect={() => setSession(value => value + 1)} />
}

function DashboardSession({ onReconnect }: { onReconnect: () => void }) {
  // A connection change unmounts all repository-specific state and callbacks.
  // Invalidate immediately, before React's cleanup, to stop delayed operations
  // from using newly saved credentials with an old queue or confirmation.
  const active = useRef(true)
  const reconnect = () => { active.current = false; onReconnect() }
  useEffect(() => { active.current = true; return () => { active.current = false } }, [])
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

  const [searchQuery, setSearchQuery]     = useState('')
  const [searchResults, setSearchResults] = useState<Task[] | null>(null)
  const [searchLoading, setSearchLoading] = useState(false)

  const isLoopRunning = state?.loop?.running ?? false
  const mergeBlockReason: string | undefined =
    state?.loop?.stage === "finale" ? "Loop is already integrating this charter"
    : state?.loop?.integrate ? "Integration loop active -- let auto-integrate finish"
    : undefined

  const onPendingAdd = useCallback((n: number) => {
    setPendingQueue(prev => [...prev, n])
  }, [])

  useEffect(() => subscribe((s) => {
    if (!active.current) return
    setState(s)
    // Sync queue from server only if user is not actively editing
    if (!dirtyRef.current) {
      setQueueOrder(s.queue?.order ?? [])
    }
  }, value => { if (active.current) setConn(value) }), [])
  useEffect(() => { const i = setInterval(() => setTick((x) => x + 1), 1000); return () => clearInterval(i) }, [])

  useEffect(() => {
    if (!searchQuery.trim()) {
      setSearchResults(null)
      setSearchLoading(false)
      return
    }
    setSearchLoading(true)
    let currentSearch = true
    const timer = setTimeout(async () => {
      const results = await searchBoard(searchQuery)
      if (!active.current || !currentSearch) return
      setSearchResults(results)
      setSearchLoading(false)
    }, 300)
    return () => { currentSearch = false; clearTimeout(timer) }
  }, [searchQuery])

  const handleQueueChange = useCallback(async (newOrder: number[]) => {
    if (!active.current) return
    dirtyRef.current = true
    setQueueOrder(newOrder)
    try {
      await postQueue(newOrder)
      if (!active.current) return
      dirtyRef.current = false
      setSavedOrder(newOrder)
    } catch {
      if (!active.current) return
      dirtyRef.current = true
    }
  }, [])

  const toast = useCallback((msg: string, err?: boolean) => {
    if (!active.current) return
    const id = ++tid.current
    setToasts((t) => [...t, { id, msg, err }])
    // Start exit animation before removing
    setTimeout(() => {
      setToasts((t) => t.map((x) => x.id === id ? { ...x, exiting: true } : x))
      setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 300)
    }, 3100)
  }, [])
  const run = useCallback(async (action: string, number?: number, comment?: string) => {
    if (!active.current) return
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
        onReset={() => {
          active.current = false
          resetDemo()
          onReconnect()
        }}
        onNew={() => setNewIssue(true)} />

      {view === 'board' ? (
        <>
          <Hero state={state} />
          <input
            type="search"
            className="board-search"
            placeholder="Поиск (#номер, заголовок, статус)…"
            value={searchQuery}
            onChange={e => setSearchQuery(e.target.value)}
          />
          {searchQuery.trim() ? (
            <div className="board-search-results">
              {searchLoading && <p className="board-search-hint">Поиск…</p>}
              {!searchLoading && searchResults !== null && (
                <>
                  <p className="board-search-hint">Найдено: {searchResults.length}</p>
                  {searchResults.length === 0
                    ? <p className="board-search-hint">Ничего не найдено</p>
                    : searchResults.map(t => (
                        <div key={t.n} data-flip-key={String(t.n)}>
                          <TaskCard t={t} onOpen={setOpen} />
                        </div>
                      ))
                  }
                </>
              )}
            </div>
          ) : (
            <div className="layout">
              <Board state={state} conn={conn} onAction={run} ask={ask} onOpen={setOpen}
                queueOrder={queueOrder} onQueueChange={handleQueueChange}
                loopRunning={isLoopRunning} onPendingAdd={onPendingAdd} mergeBlockReason={mergeBlockReason} />
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
                    onOpen={setOpen}
                  />
                </div>
              </div>
            </div>
          )}
        </>
      ) : view === 'human' ? (
        <HumanDecisionsPage state={state} onOpen={setOpen} onResolve={resolveAsk} onAction={run} ask={ask} />
      ) : <TeamPage />}

      <div className="toasts">
        {toasts.map((t) => (
          <div key={t.id} className={'toast' + (t.err ? ' err' : '') + (t.exiting ? ' exiting' : '')}>{t.msg}</div>
        ))}
      </div>
      {confirm && <Modal title={confirm.title} body={confirm.body}
        onCancel={() => setConfirm(null)} onOk={(reason) => { if (!active.current) return; const f = confirm.onOk; setConfirm(null); f(reason) }}
        withInput={confirm.withInput} />}
      {settings && <SettingsModal onClose={() => setSettings(false)} onSaved={reconnect} />}
      {newIssue && <NewIssueModal state={state} onClose={() => setNewIssue(false)} onToast={toast} />}
      {open != null && <TaskDrawer n={open} task={state?.board.find((b) => b.n === open) ?? null}
        onClose={() => setOpen(null)} onAction={run} ask={ask} mergeBlockReason={mergeBlockReason} />}
    </div>
  )
}

function Header({ state, conn, view, setView, onRun, onPause, onKill, onSettings, onNew, onReset }: {
  state: State | null; conn: boolean; view: 'board' | 'team' | 'human'; setView: (v: 'board' | 'team' | 'human') => void
  onRun: () => void; onPause: () => void; onKill: () => void; onSettings: () => void; onNew: () => void; onReset: () => void
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
        <span className={'conn' + (conn ? ' live' : '')} data-testid={DEMO_MODE ? 'demo-badge' : undefined}>{DEMO_MODE ? 'Local demo' : conn ? 'live' : 'offline'}</span>
        <span className="repo">{state?.autonomy.repo || '—'}</span>
      </div>
      <div className="hdr-r">
        <button className="btn" onClick={onNew}>+ New</button>
        <button className="btn pri" onClick={onRun}>▶ Run</button>
        <button className="btn" onClick={onPause}>{paused ? 'Resume' : 'Pause'}</button>
        <button className={'btn' + (killed ? '' : ' warn')} onClick={onKill}>{killed ? 'Un-kill' : 'Kill'}</button>
        <button className="btn ghost" onClick={DEMO_MODE ? onReset : onSettings} aria-label={DEMO_MODE ? "Reset demo" : "settings"}>{DEMO_MODE ? "Reset demo" : "⚙"}</button>
      </div>
    </header>
  )
}

function Hero({ state }: { state: State | null }) {
  const board = state?.board ?? []
  const running = state?.agents?.filter(a => a.pid != null).length ?? 0
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

function Board({ state, conn, onAction, ask, onOpen, queueOrder, onQueueChange, loopRunning, onPendingAdd, mergeBlockReason }: {
  state: State | null; conn: boolean
  onAction: (a: string, n?: number, comment?: string) => void; ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void; onOpen: (n: number) => void
  queueOrder: number[]; onQueueChange: (order: number[]) => void
  loopRunning: boolean; onPendingAdd: (n: number) => void
  mergeBlockReason: string | undefined
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
  const killSwitch = state.flags.killed
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
            killSwitch={killSwitch}
            onPendingAdd={onPendingAdd}
            mergeBlockReason={mergeBlockReason}
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
          loopRunning={loopRunning} killSwitch={killSwitch} onPendingAdd={onPendingAdd}
          mergeBlockReason={mergeBlockReason}
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
          killSwitch={killSwitch}
          onPendingAdd={onPendingAdd}
          mergeBlockReason={mergeBlockReason}
        />
      )}
    </section>
  )
}

function CharterSection({ sectionKey, label, charters, leaves, expanded, onToggle, onAction, ask, onOpen, getExpanded, doToggle, queueOrder, onQueueChange, loopRunning, killSwitch, onPendingAdd, mergeBlockReason }: {
  sectionKey: string; label: string; charters: Task[]; leaves: Task[]
  expanded: boolean; onToggle: () => void
  onAction: (a: string, n?: number, comment?: string) => void
  ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void
  onOpen: (n: number) => void
  getExpanded: (n: number, def: boolean) => boolean
  doToggle: (n: number, def: boolean) => void
  queueOrder: number[]; onQueueChange: (order: number[]) => void
  loopRunning: boolean; killSwitch: boolean; onPendingAdd: (n: number) => void
  mergeBlockReason: string | undefined
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
            loopRunning={loopRunning} killSwitch={killSwitch} onPendingAdd={onPendingAdd}
            mergeBlockReason={mergeBlockReason} />
        ))}
      </div>
    </div>
  )
}

function MilestoneGroup({ milestone, charters, leaves, onAction, ask, onOpen, expanded, onToggle, getExpanded, doToggle, queueOrder, onQueueChange, loopRunning, killSwitch, onPendingAdd, mergeBlockReason }: {
  milestone: Task; charters: Task[]; leaves: Task[]
  onAction: (a: string, n?: number, comment?: string) => void
  ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void
  onOpen: (n: number) => void
  expanded: boolean; onToggle: () => void
  getExpanded: (n: number, def: boolean) => boolean
  doToggle: (n: number, def: boolean) => void
  queueOrder: number[]; onQueueChange: (order: number[]) => void
  loopRunning: boolean; killSwitch: boolean; onPendingAdd: (n: number) => void
  mergeBlockReason: string | undefined
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
            killSwitch={killSwitch}
            onPendingAdd={onPendingAdd}
            mergeBlockReason={mergeBlockReason}
          />
        ))}
      </div>
    </div>
  )
}

function HumanDecisionsPage({ state, onOpen, onResolve, onAction, ask }: {
  state: State | null; onOpen: (n: number) => void; onResolve: (n: number) => void
  onAction: (a: string, n?: number, comment?: string) => void
  ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void
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
          onAction={onAction}
          ask={ask}
        />
      ))}
      {orphans.length > 0 && (
        <HumanCharterGroup charter={null} tasks={orphans} onOpen={onOpen} onResolve={onResolve} onAction={onAction} ask={ask} />
      )}
    </section>
  )
}

function HumanCharterGroup({ charter, tasks, onOpen, onResolve, onAction, ask }: {
  charter: Task | null; tasks: Task[]; onOpen: (n: number) => void; onResolve: (n: number) => void
  onAction: (a: string, n?: number, comment?: string) => void
  ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void
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
        {tasks.map((t) => <HumanTaskCard key={t.n} t={t} onOpen={onOpen} onResolve={onResolve} onAction={onAction} ask={ask} />)}
      </div>
    </div>
  )
}

function HumanTaskCard({ t, onOpen, onResolve, onAction, ask }: {
  t: Task; onOpen: (n: number) => void; onResolve: (n: number) => void
  onAction: (a: string, n?: number, comment?: string) => void
  ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void
}) {
  const isHD = t.labels.includes('type:human-decision')
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
      {isHD && (
        <div className="task-foot" onClick={(e) => e.stopPropagation()}>
          <button className="btn sm pri" onClick={() => ask('Одобрить #' + t.n,
            'Подтвердите одобрение этой задачи.',
            () => onAction('approve-hd', t.n))}>Одобрить</button>
          <button className="btn sm ghost" onClick={() => ask('На доработку #' + t.n,
            'Опишите, что нужно доработать:',
            (reason) => { if (reason != null) onAction('request-changes-hd', t.n, reason) },
            true)}>На доработку</button>
          <button className="btn sm ghost" onClick={() => ask('Закрыть #' + t.n,
            'Подтвердите закрытие этой задачи.',
            () => onAction('close-hd', t.n))}>Закрыть</button>
        </div>
      )}
    </div>
  )
}

function CharterCard({ c, leaves, onAction, ask, onOpen, expanded, onToggle, queueOrder, onQueueChange, loopRunning, killSwitch, onPendingAdd, mergeBlockReason }: {
  c: Task | null; leaves: Task[]; onAction: (a: string, n?: number, comment?: string) => void
  ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void; onOpen: (n: number) => void
  expanded: boolean; onToggle: () => void
  queueOrder: number[]; onQueueChange: (order: number[]) => void
  loopRunning: boolean; killSwitch: boolean; onPendingAdd: (n: number) => void
  mergeBlockReason: string | undefined
}) {
  const done = leaves.filter((l) => l.state === 'done').length
  const total = leaves.length
  const pct = total > 0 ? Math.round((100 * done) / total) : 0
  const gridRef = useRef<HTMLDivElement>(null)
  useFlip(gridRef)
  const bodyId = `charter-body-${c?.n ?? 0}`
  const [mergeErr, setMergeErr] = useState<string | null>(null)
  const [merging, setMerging] = useState(false)
  const [mergeVerifyOutput, setMergeVerifyOutput] = useState<string | null>(null)
  const [mergeVerifyVerdict, setMergeVerifyVerdict] = useState<string | null>(null)
  const [scopedPending, setScopedPending] = useState(false)
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
        {c && c.state !== 'done' && (
          <button
            className="btn sm pri"
            data-testid="run-scoped-btn"
            disabled={loopRunning || killSwitch || scopedPending}
            onClick={async () => {
              setScopedPending(true)
              await command('run-scoped', c.n)
              setScopedPending(false)
            }}
          >{scopedPending ? '⏳ Running…' : '▶ Scoped'}</button>
        )}
        {c && c.state === 'plan-review' && !c.plan_convergence_active && <>
          <button className="btn sm pri" onClick={() => ask('Approve plan #' + c.n,
            "Releases this charter's tasks to be launched (executors run, spending from the pool).",
            () => onAction('approve', c.n))}>Approve plan</button>
          <button className="btn sm ghost" onClick={() => ask('Request changes #' + c.n,
            'Опишите, что нужно доработать в плане:',
            (reason) => onAction('request-changes', c.n, reason),
            true)}>Request changes</button>
        </>}
        {c && c.state === 'plan-review' && c.plan_convergence_active && (
          <span className="dim">plan-convergence in progress</span>
        )}
        {c && c.state === 'approved' && c.finale_pr && (
          <>
            <button className="btn sm pri" disabled={merging || mergeBlockReason !== undefined} title={mergeBlockReason} onClick={async () => {
              setMergeErr(null)
              setMergeVerifyVerdict(null)
              setMergeVerifyOutput(null)
              setMerging(true)
              const r = await command('merge', c.n)
              setMerging(false)
              if (!r.ok) {
                setMergeErr(r.msg || 'merge failed')
                if (r.verify_verdict) setMergeVerifyVerdict(r.verify_verdict)
                if (r.verify_output) setMergeVerifyOutput(r.verify_output)
              } else if (r.verify_verdict && r.verify_verdict !== 'green') {
                setMergeVerifyVerdict(r.verify_verdict)
                if (r.verify_output) setMergeVerifyOutput(r.verify_output)
              }
            }}>{merging ? '⏳ Merging…' : 'Merge'}</button>
            {mergeErr && <span className="err-inline">{mergeErr}</span>}
            {mergeVerifyVerdict && (
              <span className={mergeVerifyVerdict === 'green' ? 'verify-ok' : 'err-inline'}>
                CI: {mergeVerifyVerdict}
              </span>
            )}
            {mergeVerifyOutput && mergeVerifyVerdict !== 'green' && (
              <details className="verify-details">
                <summary>CI output</summary>
                <pre className="verify-pre">{mergeVerifyOutput}</pre>
              </details>
            )}
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
