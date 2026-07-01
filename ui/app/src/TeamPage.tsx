import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { buildTree, fetchRole, fetchTeam, saveRole, saveTeam, type OrgNode, type RoleDef, type Team, type TreeNode } from './team'

const sig = (nodes: OrgNode[]) => JSON.stringify([...nodes.map((n) => [n.role, n.reports_to])].sort())
type Drag = { role: string; from: 'node' | 'pool' } | null
type RoleModalState = { mode: 'new' | 'edit'; roleName: string } | null

export default function TeamPage() {
  const [team, setTeam] = useState<Team | null>(null)
  const [nodes, setNodes] = useState<OrgNode[]>([])
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const [zoom, setZoom] = useState(1)
  const [drag, setDrag] = useState<Drag>(null)
  const [over, setOver] = useState<string | null>(null)   // role of node hovered, or '__pool__'
  const [msg, setMsg] = useState('')
  const [roleModal, setRoleModal] = useState<RoleModalState>(null)
  const original = useRef<string>('')

  useEffect(() => {
    let on = true
    const load = async () => {
      const t = await fetchTeam(); if (!on) return
      setTeam(t)
      setNodes((prev) => {
        if (!prev.length) { original.current = sig(t.nodes); return t.nodes.map((n) => ({ ...n })) }
        const live: Record<string, number> = {}; t.nodes.forEach((n) => { live[n.role] = n.live || 0 })
        return prev.map((n) => ({ ...n, live: live[n.role] || 0 }))
      })
    }
    load(); const i = setInterval(load, 5000); return () => { on = false; clearInterval(i) }
  }, [])

  const span_max = team?.policy.span_max ?? 5
  const roots = useMemo(() => buildTree(nodes), [nodes])
  const lib = team?.roles ?? []
  const placed = new Set(nodes.map((n) => n.role))
  const pool: RoleDef[] = lib.filter((r) => !placed.has(r.role))
  const kindOf = (r: string) => nodes.find((n) => n.role === r)?.kind ?? lib.find((l) => l.role === r)?.kind
  const childCount = (r: string) => nodes.filter((n) => n.reports_to === r).length
  const descendants = (r: string) => {
    const out = new Set<string>(); const st = [r]
    while (st.length) { const c = st.pop()!; nodes.forEach((n) => { if (n.reports_to === c && !out.has(n.role)) { out.add(n.role); st.push(n.role) } }) }
    return out
  }
  // reason a drop is invalid (null = ok)
  const reasonOnNode = (d: Drag, t: string): string | null => {
    if (!d) return 'none'
    if (kindOf(t) !== 'manager') return 'target must be a manager'
    if (childCount(t) >= span_max) return `span limit (≤${span_max}) reached`
    if (d.from === 'pool') return null
    if (d.role === t) return 'same node'
    if (descendants(d.role).has(t)) return 'cannot move under its own report'
    if (nodes.find((n) => n.role === d.role)?.reports_to === t) return 'already there'
    return null
  }
  const reasonOnPool = (d: Drag): string | null => {
    if (!d || d.from !== 'node') return 'drag a placed role here to remove'
    if (childCount(d.role) > 0) return 'empty its reports first'
    if (nodes.find((n) => n.role === d.role)?.reports_to == null) return 'cannot remove the root'
    return null
  }
  const dirty = sig(nodes) !== original.current

  const onSavedRole = async () => {
    setRoleModal(null)
    const t = await fetchTeam()
    setTeam(t)
    setNodes(t.nodes.map((n) => ({ ...n })))
    original.current = sig(t.nodes)
    setMsg('role saved — team refreshed')
  }

  const dropOnNode = (target: string) => {
    if (!drag) return
    const bad = reasonOnNode(drag, target)
    if (bad) setMsg(`✗ ${drag.role} → ${target}: ${bad}`)
    else if (drag.from === 'pool') {
      const def = lib.find((l) => l.role === drag.role)!
      setNodes((p) => [...p, { role: def.role, reports_to: target, kind: def.kind, domain: def.domain, code_blind: def.code_blind }])
      setMsg(`added ${drag.role} under ${target}`)
    } else { setNodes((p) => p.map((n) => (n.role === drag.role ? { ...n, reports_to: target } : n))); setMsg(`moved ${drag.role} under ${target}`) }
    setDrag(null); setOver(null)
  }
  const dropOnPool = () => {
    if (!drag) return
    const bad = reasonOnPool(drag)
    if (bad) setMsg(`✗ ${drag.role}: ${bad}`)
    else { setNodes((p) => p.filter((n) => n.role !== drag.role)); setMsg(`removed ${drag.role} → pool`) }
    setDrag(null); setOver(null)
  }
  const exportJson = () => {
    const org = { policy: team?.policy ?? {}, departments: team?.departments ?? [], nodes: nodes.map((n) => ({ role: n.role, reports_to: n.reports_to })) }
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([JSON.stringify(org, null, 2)], { type: 'application/json' }))
    a.download = 'org.json'; a.click(); URL.revokeObjectURL(a.href); setMsg('exported org.json')
  }
  const save = async () => { const r = await saveTeam({ ...(team as Team), nodes }); setMsg(r.msg); if (r.ok) original.current = sig(nodes) }
  const revert = () => { if (team) setNodes(team.nodes.map((n) => ({ ...n }))); setMsg('reverted') }

  if (!team) return <div className="empty">loading team…</div>
  const counts = nodes.reduce((m, n) => { m[n.kind] = (m[n.kind] || 0) + 1; return m }, {} as Record<string, number>)
  const withKids = nodes.filter((n) => nodes.some((m) => m.reports_to === n.role)).map((n) => n.role)
  const toggle = (r: string) => setCollapsed((c) => { const s = new Set(c); if (s.has(r)) s.delete(r); else s.add(r); return s })

  return (
    <section className="team">
      <div className="team-bar">
        <div className="team-legend">
          <span className="lg manager">manager {counts.manager || 0}</span>
          <span className="lg analyst">analyst {counts.analyst || 0}</span>
          <span className="lg executor">executor {counts.executor || 0}</span>
        </div>
        <div className="grow" />
        <div className="team-tools">
          {dirty && <button className="btn xs pri" onClick={save}>Save</button>}
          {dirty && <button className="btn xs ghost" onClick={revert}>Revert</button>}
          <button className="btn xs ghost" onClick={exportJson}>Export</button>
          <button className="btn xs ghost" onClick={() => setRoleModal({ mode: 'new', roleName: '' })}>+ New role</button>
          <button className="btn xs ghost" onClick={() => setCollapsed(new Set(withKids))}>Collapse all</button>
          <button className="btn xs ghost" onClick={() => setCollapsed(new Set())}>Expand all</button>
          <div className="zoom">
            <button className="btn xs ghost" onClick={() => setZoom((z) => Math.max(0.4, +(z - 0.15).toFixed(2)))}>−</button>
            <span className="zoom-val">{Math.round(zoom * 100)}%</span>
            <button className="btn xs ghost" onClick={() => setZoom((z) => Math.min(1.4, +(z + 0.15).toFixed(2)))}>＋</button>
          </div>
        </div>
      </div>
      <div className="team-policy-strip">{msg
        ? <span className={msg.startsWith('✗') ? 'msg-bad' : 'msg-ok'}>{msg}</span>
        : <>span ≤ {span_max} · approver: {team.policy.approval_role || '—'} · <b>drag a role onto a manager · drag onto the pool to remove</b></>}</div>

      <div className="orgwrap">
        <div className="orgchart" style={{ zoom }}>
          <ul className="org">{roots.map((n) => (
            <OrgLi key={n.role} n={n} collapsed={collapsed} onToggle={toggle}
              drag={drag} over={over} reason={reasonOnNode} setDrag={setDrag} setOver={setOver}
              onDrop={dropOnNode} onEditRole={(r) => setRoleModal({ mode: 'edit', roleName: r })} />
          ))}</ul>
        </div>
      </div>

      <div className={'pool' + (over === '__pool__' ? (reasonOnPool(drag) ? ' drop-bad' : ' drop-ok') : '')}
        onDragOver={(e) => { if (drag) { e.preventDefault(); setOver('__pool__') } }}
        onDragLeave={() => { if (over === '__pool__') setOver(null) }}
        onDrop={(e) => { e.preventDefault(); dropOnPool() }}>
        <div className="pool-head">Role pool <span className="muted">{pool.length}</span> · drag into the chart, or drop a role here to remove</div>
        <div className="pool-chips">
          {pool.length === 0 ? <span className="muted">all library roles are placed</span>
            : pool.map((r) => (
              <span key={r.role} className={'chip k-' + r.kind} draggable
                onDragStart={(e) => { setDrag({ role: r.role, from: 'pool' }); e.dataTransfer.setData('text/plain', r.role); e.dataTransfer.effectAllowed = 'copy' }}
                onDragEnd={() => { setDrag(null); setOver(null) }}
                title={`${r.kind} · ${r.domain}`}>
                {r.role}
                <button type="button" className="chip-edit-btn"
                  onClick={(e) => { e.stopPropagation(); setRoleModal({ mode: 'edit', roleName: r.role }) }}
                  title="Edit role">✎</button>
              </span>
            ))}
        </div>
      </div>

      {roleModal && (
        <RoleModal
          mode={roleModal.mode}
          roleName={roleModal.roleName}
          onClose={() => setRoleModal(null)}
          onSaved={onSavedRole}
        />
      )}
    </section>
  )
}

type LiProps = {
  n: TreeNode; collapsed: Set<string>; onToggle: (r: string) => void
  drag: Drag; over: string | null; reason: (d: Drag, t: string) => string | null
  setDrag: (d: Drag) => void; setOver: (r: string | null) => void; onDrop: (t: string) => void
  onEditRole: (role: string) => void
}
function OrgLi(p: LiProps) {
  const isCollapsed = p.collapsed.has(p.n.role)
  const hasKids = p.n.children.length > 0
  return (
    <li>
      <NodeCard {...p} hasKids={hasKids} collapsedNode={isCollapsed} />
      {hasKids && !isCollapsed && <ul className="org">{p.n.children.map((c) => <OrgLi {...p} key={c.role} n={c} />)}</ul>}
    </li>
  )
}

function NodeCard({ n, hasKids, collapsedNode, onToggle, drag, over, reason, setDrag, setOver, onDrop, onEditRole }:
  LiProps & { hasKids: boolean; collapsedNode: boolean }) {
  const span = n.children.length
  const dropState = over === n.role && drag ? (reason(drag, n.role) ? 'drop-bad' : 'drop-ok') : ''
  return (
    <div
      className={['node', 'k-' + n.kind, n.live ? 'running' : '', drag?.role === n.role ? 'dragging' : '', dropState].join(' ').trim()}
      draggable
      onDragStart={(e) => { setDrag({ role: n.role, from: 'node' }); e.dataTransfer.setData('text/plain', n.role); e.dataTransfer.effectAllowed = 'move' }}
      onDragEnd={() => { setDrag(null); setOver(null) }}
      onDragOver={(e) => { if (drag) { e.preventDefault(); setOver(n.role) } }}
      onDragLeave={() => { if (over === n.role) setOver(null) }}
      onDrop={(e) => { e.preventDefault(); onDrop(n.role) }}
    >
      <div className="node-top">
        <span className="node-kind">{n.kind}</span>
        {n.code_blind && <span className="node-lock" title="code-blind (no code access)">🔒</span>}
        <span className="grow" />
        {!!n.live && <span className="node-live" title={`${n.live} running`}><span className="phase-dot" />{n.live}</span>}
        <button type="button" className="node-edit-btn"
          onClick={(e) => { e.stopPropagation(); onEditRole(n.role) }}
          title="Edit role">✎</button>
        {hasKids && (
          <button type="button" className={'node-toggle' + (collapsedNode ? ' collapsed' : '')}
            onClick={() => onToggle(n.role)} title={collapsedNode ? `expand ${span}` : 'collapse'}>{collapsedNode ? `+${span}` : '–'}</button>
        )}
      </div>
      <div className="node-role">{n.role}</div>
      <div className="node-meta">
        <span className="node-domain">{n.domain || '—'}</span>
        {span > 0 && <span className="node-span">{span} report{span > 1 ? 's' : ''}</span>}
      </div>
    </div>
  )
}

// ── Role editor modal ─────────────────────────────────────────────────────────
const TOOL_NAMES = ['Read', 'Edit', 'Write', 'Bash', 'Agent']

type RoleFormState = {
  name: string; kind: string; domain: string; tools: string[]
  profile: string; code_blind: boolean; skills: string; model: string; prompt: string
}

function RoleModal({
  mode, roleName, onClose, onSaved,
}: { mode: 'new' | 'edit'; roleName: string; onClose: () => void; onSaved: () => void }) {
  const [form, setForm] = useState<RoleFormState>({
    name: roleName, kind: 'executor', domain: '', tools: ['Read', 'Bash'],
    profile: 'executor', code_blind: false, skills: '', model: '', prompt: '',
  })
  const [loading, setLoading]     = useState(mode === 'edit')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError]         = useState('')

  useEffect(() => {
    if (mode !== 'edit' || !roleName) { setLoading(false); return }
    fetchRole(roleName).then((data) => {
      if (data) {
        const fm = data.frontmatter
        setForm({
          name: data.name,
          kind: fm.kind || 'executor',
          domain: fm.domain || '',
          tools: (fm.tools || '').split(',').map((t) => t.trim()).filter(Boolean),
          profile: fm.profile || '',
          code_blind: fm.code_blind === 'true',
          skills: fm.skills || '',
          model: fm.model || '',
          prompt: data.prompt || '',
        })
      } else {
        setError(`Could not load role "${roleName}" — API offline?`)
      }
      setLoading(false)
    })
  }, [mode, roleName])

  const upd = <K extends keyof RoleFormState>(k: K, v: RoleFormState[K]) =>
    setForm((f) => ({ ...f, [k]: v }))

  const toggleTool = (t: string) =>
    setForm((f) => ({
      ...f,
      tools: f.tools.includes(t) ? f.tools.filter((x) => x !== t) : [...f.tools, t],
    }))

  const toolWarning = (t: string) => {
    if ((form.kind === 'analyst' || form.kind === 'manager') && (t === 'Edit' || t === 'Write' || t === 'Agent'))
      return `${form.kind}s must NOT have ${t}`
    if (form.code_blind && t === 'Read') return 'code_blind roles must NOT have Read'
    return ''
  }

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault()
    setSubmitting(true); setError('')
    const r = await saveRole({
      name: form.name, kind: form.kind, domain: form.domain,
      tools: form.tools.join(', '), profile: form.profile,
      code_blind: form.code_blind, skills: form.skills, model: form.model, prompt: form.prompt,
    })
    setSubmitting(false)
    if (r.ok) { onSaved() } else { setError(r.msg || 'Unknown error') }
  }

  return (
    <div className="modal-bg" onClick={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className="modal role-modal" onClick={(e) => e.stopPropagation()}>
        <h3 style={{ marginBottom: 16 }}>{mode === 'new' ? 'New role' : `Edit role: ${roleName}`}</h3>
        {loading ? (
          <div className="muted" style={{ padding: '14px 0' }}>Loading…</div>
        ) : (
          <form onSubmit={handleSubmit}>
            <div style={{ maxHeight: 'calc(80vh - 160px)', overflowY: 'auto', paddingRight: 4 }}>
              <label className="fld">
                Name&nbsp;<span className="muted" style={{ fontSize: 11 }}>^[a-z0-9-]+$</span>
                <input value={form.name} readOnly={mode === 'edit'}
                  onChange={(e) => upd('name', e.target.value)}
                  placeholder="my-role" required pattern="[a-z0-9-]+"
                  style={mode === 'edit' ? { opacity: 0.55, cursor: 'not-allowed' } : {}} />
              </label>
              <label className="fld">
                Kind
                <select value={form.kind} onChange={(e) => upd('kind', e.target.value)}>
                  <option value="executor">executor</option>
                  <option value="analyst">analyst</option>
                  <option value="manager">manager</option>
                </select>
              </label>
              <label className="fld">
                Domain
                <input value={form.domain} onChange={(e) => upd('domain', e.target.value)} placeholder="backend/go" />
              </label>
              <div className="fld">
                Tools
                <div className="role-tools">
                  {TOOL_NAMES.map((t) => {
                    const w = toolWarning(t)
                    return (
                      <label key={t} className="role-tool" title={w || undefined}>
                        <input type="checkbox" checked={form.tools.includes(t)} onChange={() => toggleTool(t)} />
                        {t}
                        {w && <span className="role-warn" title={w}>⚠</span>}
                      </label>
                    )
                  })}
                </div>
                {(form.kind === 'analyst' || form.kind === 'manager') && (
                  <div className="role-hint">
                    {form.kind === 'analyst' ? 'Analysts' : 'Managers'} must be read-only — Edit/Write/Agent not allowed
                  </div>
                )}
                {form.code_blind && <div className="role-hint">code_blind roles must NOT have Read</div>}
              </div>
              <label className="fld">
                Profile
                <input value={form.profile} onChange={(e) => upd('profile', e.target.value)} placeholder="executor" />
              </label>
              <label className="fld-check">
                <input type="checkbox" checked={form.code_blind} onChange={(e) => upd('code_blind', e.target.checked)} />
                code_blind (no code access — removes Read)
              </label>
              <label className="fld">
                Skills <span className="muted" style={{ fontSize: 11 }}>(optional)</span>
                <input value={form.skills} onChange={(e) => upd('skills', e.target.value)} placeholder="[go, http]" />
              </label>
              <label className="fld">
                Model (claude-* id or 'anthropic')
                <input value={form.model} onChange={(e) => upd('model', e.target.value)} placeholder="anthropic" />
              </label>
              <label className="fld">
                System prompt
                <textarea value={form.prompt} onChange={(e) => upd('prompt', e.target.value)}
                  rows={5} placeholder="Describe what this role does…" />
              </label>
              {error && <pre className="role-error">{error}</pre>}
            </div>
            <div className="m-actions" style={{ marginTop: 16 }}>
              <button type="button" className="btn ghost" onClick={onClose}>Cancel</button>
              <button type="submit" className="btn pri" disabled={submitting}>
                {submitting ? 'Saving…' : 'Save role'}
              </button>
            </div>
          </form>
        )}
      </div>
    </div>
  )
}
