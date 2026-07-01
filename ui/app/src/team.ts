import { config } from './api'

export type OrgNode = {
  role: string
  reports_to: string | null
  kind: string          // executor | analyst | manager
  domain: string
  tools?: string
  code_blind?: boolean
  live?: number          // live agents of this role right now (overlay)
}
export type RoleDef = { role: string; kind: string; domain: string; code_blind?: boolean }
export type Team = {
  present: boolean
  nodes: OrgNode[]
  roles: RoleDef[]   // full library; pool = roles minus placed nodes
  departments: { id: string; head: string }[]
  policy: { span_max?: number; analysis_roles?: string[]; approval_role?: string; human_approval_above_usd?: number }
}

/** Bundled snapshot of team-example so the org chart renders offline (no box / no spend).
 *  The live /api/team (when the box is up) overrides this and adds the `live` overlay. */
export const FALLBACK_TEAM: Team = {
  present: true,
  policy: { span_max: 5, analysis_roles: ['solution-analyst'], approval_role: 'cto', human_approval_above_usd: 1.0 },
  departments: [{ id: 'backend', head: 'backend-head' }],
  nodes: [
    { role: 'cto', reports_to: null, kind: 'manager', domain: 'org', code_blind: true },
    { role: 'solution-analyst', reports_to: 'cto', kind: 'analyst', domain: 'analysis' },
    { role: 'backend-head', reports_to: 'cto', kind: 'manager', domain: 'backend' },
    { role: 'qa-engineer', reports_to: 'cto', kind: 'executor', domain: 'qa' },
    { role: 'go-lead', reports_to: 'backend-head', kind: 'manager', domain: 'backend/go' },
    { role: 'go-backend-dev', reports_to: 'go-lead', kind: 'executor', domain: 'backend/go' },
    { role: 'go-algo-dev', reports_to: 'go-lead', kind: 'executor', domain: 'backend/go' },
  ],
  roles: [
    { role: 'cto', kind: 'manager', domain: 'org', code_blind: true },
    { role: 'solution-analyst', kind: 'analyst', domain: 'analysis' },
    { role: 'backend-head', kind: 'manager', domain: 'backend' },
    { role: 'qa-engineer', kind: 'executor', domain: 'qa' },
    { role: 'go-lead', kind: 'manager', domain: 'backend/go' },
    { role: 'go-backend-dev', kind: 'executor', domain: 'backend/go' },
    { role: 'go-algo-dev', kind: 'executor', domain: 'backend/go' },
    // library roles not currently placed -> show up in the pool
    { role: 'java-lead', kind: 'manager', domain: 'backend/java' },
    { role: 'java-backend-dev', kind: 'executor', domain: 'backend/java' },
    { role: 'python-dev', kind: 'executor', domain: 'backend/python' },
    { role: 'ts-frontend-dev', kind: 'executor', domain: 'frontend/ts' },
    { role: 'security-reviewer', kind: 'analyst', domain: 'security' },
    { role: 'infra-engineer', kind: 'executor', domain: 'infra' },
    { role: 'design-lead', kind: 'manager', domain: 'design' },
  ],
}

export async function fetchTeam(): Promise<Team> {
  try {
    const r = await fetch(config.url + '/api/team', { headers: { Authorization: 'Bearer ' + config.token } })
    if (r.ok) {
      const t = (await r.json()) as Team
      if (t && t.present && t.nodes?.length) return t
    }
  } catch { /* offline -> fallback */ }
  return FALLBACK_TEAM
}

export async function saveTeam(t: Team): Promise<{ ok: boolean; msg: string }> {
  try {
    const r = await fetch(config.url + '/api/team', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + config.token },
      body: JSON.stringify(t),
    })
    return await r.json()
  } catch (e) { return { ok: false, msg: 'save failed (box offline?) — use Export' } }
}

// ── Role CRUD ────────────────────────────────────────────────────────────────
export type RoleFrontmatter = {
  name?: string
  kind?: string
  domain?: string
  tools?: string
  profile?: string
  code_blind?: string   // "true" | "" (raw string from YAML-frontmatter)
  skills?: string
  model?: string
}

export type RoleDetail = {
  ok: boolean
  name: string
  frontmatter: RoleFrontmatter
  prompt: string
}

export type RoleSave = {
  name: string
  kind: string
  domain: string
  tools: string
  profile: string
  code_blind: boolean
  skills: string
  model: string
  prompt: string
}

export async function fetchRole(name: string): Promise<RoleDetail | null> {
  try {
    const r = await fetch(config.url + '/api/role/' + encodeURIComponent(name), {
      headers: { Authorization: 'Bearer ' + config.token },
    })
    if (r.ok) {
      const data = (await r.json()) as RoleDetail
      if (data?.ok) return data
    }
  } catch { /* offline */ }
  return null
}

export async function saveRole(role: RoleSave): Promise<{ ok: boolean; msg?: string }> {
  try {
    const r = await fetch(config.url + '/api/role', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + config.token },
      body: JSON.stringify(role),
    })
    return (await r.json()) as { ok: boolean; msg?: string }
  } catch (e) {
    return { ok: false, msg: 'save failed (box offline?): ' + e }
  }
}

// ── Tree ──────────────────────────────────────────────────────────────────────
export type TreeNode = OrgNode & { children: TreeNode[] }
export function buildTree(nodes: OrgNode[]): TreeNode[] {
  const by: Record<string, TreeNode> = {}
  nodes.forEach((n) => { by[n.role] = { ...n, children: [] } })
  const roots: TreeNode[] = []
  nodes.forEach((n) => {
    const node = by[n.role]
    if (n.reports_to && by[n.reports_to]) by[n.reports_to].children.push(node)
    else roots.push(node)
  })
  return roots
}
