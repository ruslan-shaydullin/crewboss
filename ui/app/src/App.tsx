import { useCallback, useEffect, useRef, useState } from 'react'
import { command, config, fetchTask, subscribe, type Agent, type State, type Task, type TaskDetail } from './api'
import { computeXP, getFleetChar, guessKind, xpToLevel, type LevelInfo } from './fleet'
import TeamPage from './TeamPage'

type Toast = { id: number; msg: string; err?: boolean }
type Confirm = { title: string; body: string; onOk: () => void } | null

/** animate a number toward `value` (easeOutCubic) — premium count-up on change. */
function useCountUp(value: number, ms = 600): number {
  const [n, setN] = useState(value)
  const from = useRef(value)
  useEffect(() => {
    const a = from.current, b = value
    if (a === b) { setN(b); return }
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

// --- confetti burst (canvas, pointer-events:none, ~1.5s) ---
const CONFETTI_COLORS = ['#5b9cf0', '#b39bff', '#46ce8e', '#e0b64a', '#f06780', '#f0ac67']
const CONFETTI_N = 110

function launchConfetti(reduced: boolean): void {
  if (reduced) {
    const el = document.createElement('div')
    el.className = 'confetti-flash'
    document.body.appendChild(el)
    setTimeout(() => el.remove(), 550)
    return
  }
  const canvas = document.createElement('canvas')
  canvas.className = 'confetti-canvas'
  canvas.width = window.innerWidth
  canvas.height = window.innerHeight
  document.body.appendChild(canvas)
  const ctx = canvas.getContext('2d')!
  type P = { x: number; y: number; vx: number; vy: number; color: string; w: number; h: number; rot: number; vrot: number }
  const particles: P[] = Array.from({ length: CONFETTI_N }, () => ({
    x: Math.random() * canvas.width,
    y: -10 - Math.random() * 80,
    vx: (Math.random() - 0.5) * 5,
    vy: 3 + Math.random() * 4,
    color: CONFETTI_COLORS[Math.floor(Math.random() * CONFETTI_COLORS.length)],
    w: 7 + Math.random() * 8,
    h: 3 + Math.random() * 5,
    rot: Math.random() * Math.PI,
    vrot: (Math.random() - 0.5) * 0.18,
  }))
  const DURATION = 1500
  const start = performance.now()
  let raf = 0
  const tick = (now: number) => {
    const elapsed = now - start
    const alpha = Math.max(0, 1 - elapsed / DURATION)
    ctx.clearRect(0, 0, canvas.width, canvas.height)
    for (const p of particles) {
      p.x += p.vx; p.y += p.vy; p.rot += p.vrot
      ctx.save()
      ctx.globalAlpha = alpha
      ctx.translate(p.x, p.y)
      ctx.rotate(p.rot)
      ctx.fillStyle = p.color
      ctx.fillRect(-p.w / 2, -p.h / 2, p.w, p.h)
      ctx.restore()
    }
    if (elapsed < DURATION) { raf = requestAnimationFrame(tick) }
    else { cancelAnimationFrame(raf); canvas.remove() }
  }
  raf = requestAnimationFrame(tick)
}

export default function App() {
  const [state, setState] = useState<State | null>(null)
  const [conn, setConn] = useState(false)
  const [toasts, setToasts] = useState<Toast[]>([])
  const [confirm, setConfirm] = useState<Confirm>(null)
  const [settings, setSettings] = useState(false)
  const [view, setView] = useState<'board' | 'team'>('board')
  const [open, setOpen] = useState<number | null>(null)
  const [, setTick] = useState(0)
  const tid = useRef(0)

  // gamification (read from config, reactive via state)
  const [gamification, setGamification] = useState(config.gamification)

  // celebration state
  const [leafCelebrations, setLeafCelebrations] = useState<Set<number>>(new Set())
  const [prAccents, setPrAccents] = useState<Set<number>>(new Set())
  const prevState = useRef<State | null>(null)
  const reducedMotion = useRef(window.matchMedia('(prefers-reduced-motion: reduce)').matches)

  useEffect(() => subscribe(setState, setConn), [])
  useEffect(() => { const i = setInterval(() => setTick((x) => x + 1), 1000); return () => clearInterval(i) }, [])

  // diff snapshots → fire celebrations
  useEffect(() => {
    if (!state) { prevState.current = null; return }
    const prev = prevState.current
    if (prev && gamification) {
      const newDones = new Set<number>()
      const newPRs   = new Set<number>()
      let   charterBurst = false

      for (const t of state.board) {
        const p = prev.board.find((x) => x.n === t.n)
        if (t.kind === 'leaf' && t.state === 'done' && p && p.state !== 'done') {
          newDones.add(t.n)
        }
        if (t.pr && !(p?.pr)) {
          newPRs.add(t.n)
        }
      }

      // charter closed or all its leaves just went done
      const charters = state.board.filter((x) => x.kind === 'charter')
      for (const c of charters) {
        const prevC  = prev.board.find((x) => x.n === c.n)
        const leaves = state.board.filter((x) => x.kind === 'leaf' && x.charter === c.n)
        const prevLv = prev.board.filter((x) => x.kind === 'leaf' && x.charter === c.n)
        const allDoneNow = leaves.length > 0 && leaves.every((l) => l.state === 'done')
        const allDonePrev = prevLv.length > 0 && prevLv.every((l) => l.state === 'done')
        if ((c.state === 'done' && prevC?.state !== 'done') || (allDoneNow && !allDonePrev)) {
          charterBurst = true
        }
      }

      if (newDones.size > 0) setLeafCelebrations((s) => new Set([...s, ...newDones]))
      if (newPRs.size   > 0) setPrAccents((s) => new Set([...s, ...newPRs]))
      if (charterBurst)       launchConfetti(reducedMotion.current)
    }
    prevState.current = state
  }, [state, gamification])

  // auto-clear leaf celebrations
  useEffect(() => {
    if (leafCelebrations.size === 0) return
    const t = setTimeout(() => setLeafCelebrations(new Set()), 1200)
    return () => clearTimeout(t)
  }, [leafCelebrations])

  // auto-clear PR accents
  useEffect(() => {
    if (prAccents.size === 0) return
    const t = setTimeout(() => setPrAccents(new Set()), 2200)
    return () => clearTimeout(t)
  }, [prAccents])

  const toast = useCallback((msg: string, err?: boolean) => {
    const id = ++tid.current
    setToasts((t) => [...t, { id, msg, err }])
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 3400)
  }, [])
  const run = useCallback(async (action: string, number?: number) => {
    const r = await command(action, number); toast(r.msg || (r.ok ? 'ok' : 'failed'), !r.ok)
  }, [toast])
  const ask = useCallback((title: string, body: string, onOk: () => void) => setConfirm({ title, body, onOk }), [])

  const board = state?.board ?? []
  const xp    = computeXP(board)
  const lvl   = xpToLevel(xp)

  return (
    <div className="app">
      <Header state={state} conn={conn} view={view} setView={setView}
        onRun={() => ask('Run launcher', 'Claims every launchable task and runs REAL agents — this spends from your pool ($).', () => run('run'))}
        onPause={() => run(state?.flags.paused ? 'resume' : 'pause')}
        onKill={() => state?.flags.killed ? run('unkill') : ask('Kill-switch', 'Stops the launcher loop at the next tick. In-flight agents finish on their own.', () => run('kill'))}
        onSettings={() => setSettings(true)} />

      {view === 'board' ? (
        <>
          <Hero state={state} />
          <div className="layout">
            <Board state={state} conn={conn} onAction={run} ask={ask} onOpen={setOpen}
              leafCelebrations={leafCelebrations} prAccents={prAccents} />
            <AgentsRail agents={state?.agents ?? []} onOpen={setOpen} lvl={lvl} gamification={gamification} />
          </div>
        </>
      ) : <TeamPage board={board} gamification={gamification} />}

      <div className="toasts">{toasts.map((t) => <div key={t.id} className={'toast' + (t.err ? ' err' : '')}>{t.msg}</div>)}</div>
      {confirm && <Modal title={confirm.title} body={confirm.body}
        onCancel={() => setConfirm(null)} onOk={() => { const f = confirm.onOk; setConfirm(null); f() }} />}
      {settings && <SettingsModal onClose={() => setSettings(false)} onSaved={() => location.reload()}
        gamification={gamification} onGamificationChange={(v) => { config.gamification = v; setGamification(v) }} />}
      {open != null && <TaskDrawer n={open} task={state?.board.find((b) => b.n === open) ?? null}
        onClose={() => setOpen(null)} onAction={run} ask={ask} />}
    </div>
  )
}

function Header({ state, conn, view, setView, onRun, onPause, onKill, onSettings }: {
  state: State | null; conn: boolean; view: 'board' | 'team'; setView: (v: 'board' | 'team') => void
  onRun: () => void; onPause: () => void; onKill: () => void; onSettings: () => void
}) {
  const paused = state?.flags.paused, killed = state?.flags.killed
  return (
    <header className="hdr">
      <div className="hdr-l">
        <span className="brand"><span className="logo">◆</span>crewboss</span>
        <nav className="nav">
          <button className={view === 'board' ? 'on' : ''} onClick={() => setView('board')}>Board</button>
          <button className={view === 'team' ? 'on' : ''} onClick={() => setView('team')}>Team</button>
        </nav>
        <span className={'conn' + (conn ? ' live' : '')}>{conn ? 'live' : 'offline'}</span>
        <span className="repo">{state?.autonomy.repo || '—'}</span>
      </div>
      <div className="hdr-r">
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

function Board({ state, conn, onAction, ask, onOpen, leafCelebrations, prAccents }: {
  state: State | null; conn: boolean
  onAction: (a: string, n?: number) => void; ask: (t: string, b: string, ok: () => void) => void; onOpen: (n: number) => void
  leafCelebrations: Set<number>; prAccents: Set<number>
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
      {charters.map((c) => <CharterCard key={c.n} c={c} leaves={childrenOf(c.n)} onAction={onAction} ask={ask} onOpen={onOpen}
        leafCelebrations={leafCelebrations} prAccents={prAccents} />)}
      {orphans.length > 0 && <CharterCard c={null} leaves={orphans} onAction={onAction} ask={ask} onOpen={onOpen}
        leafCelebrations={leafCelebrations} prAccents={prAccents} />}
    </section>
  )
}

function CharterCard({ c, leaves, onAction, ask, onOpen, leafCelebrations, prAccents }: {
  c: Task | null; leaves: Task[]; onAction: (a: string, n?: number) => void
  ask: (t: string, b: string, ok: () => void) => void; onOpen: (n: number) => void
  leafCelebrations: Set<number>; prAccents: Set<number>
}) {
  const done = leaves.filter((l) => l.state === 'done').length
  const total = leaves.length
  const pct = total > 0 ? Math.round((100 * done) / total) : 0
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
        {c && c.state === 'plan-review' &&
          <button className="btn sm pri" onClick={() => ask('Approve plan #' + c.n,
            "Releases this charter's tasks to be launched (executors run, spending from the pool).",
            () => onAction('approve', c.n))}>Approve plan</button>}
      </div>
      {total > 0 && <div className="task-grid">{leaves.map((l) => <TaskCard key={l.n} t={l} onOpen={onOpen}
        celebrating={leafCelebrations.has(l.n)} prAccent={prAccents.has(l.n)} />)}</div>}
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

function TaskCard({ t, onOpen, celebrating, prAccent }: { t: Task; onOpen: (n: number) => void; celebrating: boolean; prAccent: boolean }) {
  const working = t.state === 'in-progress'
  let cls = 'task'
  if (working)     cls += ' working'
  if (celebrating) cls += ' celebrating'
  if (prAccent)    cls += ' pr-accent'
  return (
    <div className={cls} onClick={() => onOpen(t.n)}>
      <div className="task-top">
        <span className="num">#{t.n}</span>
        <span className={'badge b-' + t.state}>{t.state}</span>
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

function AgentsRail({ agents, onOpen, lvl, gamification }: {
  agents: Agent[]; onOpen: (n: number) => void; lvl: LevelInfo; gamification: boolean
}) {
  return (
    <aside className="rail">
      <div className="rail-head"><span>Agents</span><span className="rail-count">{agents.length}</span></div>
      {agents.length === 0
        ? <div className="rail-empty"><div className="z">z z z</div>no agents running</div>
        : agents.map((a, i) => <AgentCard key={(a.task ?? 'boss') + ':' + i} a={a} onOpen={onOpen} lvl={lvl} gamification={gamification} />)}
    </aside>
  )
}

function AgentCard({ a, onOpen, lvl, gamification }: { a: Agent; onOpen: (n: number) => void; lvl: LevelInfo; gamification: boolean }) {
  const fc = getFleetChar(a.role, guessKind(a.role))
  const pct = Math.round((lvl.progress / lvl.needed) * 100)
  return (
    <div className={'agent role-' + a.role} onClick={() => a.task != null && onOpen(a.task)} style={a.task != null ? { cursor: 'pointer' } : undefined}>
      <div className="agent-mono" style={{ color: fc.color }} title={`${fc.name} · ${fc.ship}`}>
        <span className="fleet-emoji">{fc.emoji}</span>
        <span className="agent-wave" />
      </div>
      <div className="agent-body">
        <div className="agent-top">
          <span className="agent-role">{a.role}</span>
          {a.task != null && <span className="agent-task">#{a.task}</span>}
          <span className="grow" />
          {gamification && <span className="lvl-badge" title={`Fleet level ${lvl.level} · ${lvl.xp} XP`}>L{lvl.level}</span>}
          <span className="agent-elapsed">{elapsed(a.started)}</span>
        </div>
        <div className="agent-title">{a.title || a.phase}</div>
        <div className="agent-phase"><span className="phase-dot" />{a.phase}</div>
        {gamification && (
          <div className="lvl-bar-wrap" title={`${lvl.progress}/${lvl.needed} to L${lvl.level + 1}`}>
            <div className="lvl-bar"><div className="lvl-fill" style={{ width: pct + '%' }} /></div>
          </div>
        )}
      </div>
    </div>
  )
}

function TaskDrawer({ n, task, onClose, onAction, ask }: {
  n: number; task: Task | null; onClose: () => void
  onAction: (a: string, n?: number) => void; ask: (t: string, b: string, ok: () => void) => void
}) {
  const [d, setD] = useState<TaskDetail | null>(null)
  const logRef = useRef<HTMLPreElement>(null)
  useEffect(() => {
    let on = true
    const load = async () => { const x = await fetchTask(n); if (on) setD(x) }
    load(); const i = setInterval(load, 2500); return () => { on = false; clearInterval(i) }
  }, [n])
  useEffect(() => { if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight }, [d?.log])

  const phase = d?.status.phase ?? (d?.alive ? 'running' : '—')
  const cost = d?.status.cost_usd
  const pr = d?.status.pr || task?.pr
  return (
    <div className="drawer-bg" onClick={onClose}>
      <div className="drawer" onClick={(e) => e.stopPropagation()}>
        <div className="drawer-head">
          <div>
            <div className="drawer-id"><span className="num">#{n}</span>{task && <span className={'badge b-' + task.state}>{task.state}</span>}
              {d?.alive && <span className="live-tag"><span className="phase-dot" />live</span>}</div>
            <h2 className="drawer-title">{task?.title ?? 'task #' + n}</h2>
          </div>
          <button className="btn ghost" onClick={onClose}>✕</button>
        </div>

        <div className="drawer-stats">
          <div><span className="ds-label">phase</span><span className="ds-val">{phase}</span></div>
          {d?.started && d.alive && <div><span className="ds-label">elapsed</span><span className="ds-val">{elapsed(d.started)}</span></div>}
          {cost != null && <div><span className="ds-label">cost</span><span className="ds-val">${Number(cost).toFixed(3)}</span></div>}
          {pr && <div><span className="ds-label">pr</span><a className="ds-val pr" href={pr} target="_blank" rel="noreferrer">open ↗</a></div>}
        </div>

        {task && task.state !== 'done' && (
          <div className="drawer-actions">
            {task.state === 'plan-review' && <button className="btn sm pri" onClick={() => ask('Approve plan #' + n, "Releases this charter's tasks to be launched.", () => onAction('approve', n))}>Approve plan</button>}
            {task.state === 'held'
              ? <button className="btn sm" onClick={() => onAction('unhold', n)}>Un-hold</button>
              : <button className="btn sm ghost" onClick={() => onAction('hold', n)}>Hold</button>}
          </div>
        )}

        {d?.prompt && <><div className="drawer-section">Brief</div><div className="brief">{d.prompt}</div></>}
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

function Modal({ title, body, onCancel, onOk }: { title: string; body: string; onCancel: () => void; onOk: () => void }) {
  return (
    <div className="modal-bg" onClick={onCancel}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h3>{title}</h3><p>{body}</p>
        <div className="m-actions"><button className="btn" onClick={onCancel}>Cancel</button><button className="btn pri" onClick={onOk}>Confirm</button></div>
      </div>
    </div>
  )
}

function SettingsModal({ onClose, onSaved, gamification, onGamificationChange }: {
  onClose: () => void; onSaved: () => void; gamification: boolean; onGamificationChange: (v: boolean) => void
}) {
  const [url, setUrl] = useState(config.url)
  const [token, setToken] = useState(config.token)
  return (
    <div className="modal-bg" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h3>Connection</h3>
        <label className="fld">API URL<input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="http://127.0.0.1:8787" /></label>
        <label className="fld">API token<input value={token} onChange={(e) => setToken(e.target.value)} type="password" placeholder="CB_API_TOKEN" /></label>
        <p className="hint">Tunnel: <code>ssh -N -L 8787:127.0.0.1:8787 ec2-user@&lt;ip&gt;</code></p>
        <div className="settings-row">
          <label className="settings-toggle">
            <input type="checkbox" checked={gamification} onChange={(e) => onGamificationChange(e.target.checked)} />
            <span>Gamification</span>
            <span className="hint-inline">celebrations &amp; levels (fleet identities always on)</span>
          </label>
        </div>
        <div className="m-actions"><button className="btn" onClick={onClose}>Close</button>
          <button className="btn pri" onClick={() => { config.url = url.trim(); config.token = token.trim(); onSaved() }}>Save &amp; reconnect</button></div>
      </div>
    </div>
  )
}
