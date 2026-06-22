/**
 * chain.test.tsx — role-chain pipeline end-to-end tests (issue #517)
 *
 * Coverage:
 *   1. Endpoint happy path: fetchChain returns a list where every element has
 *      keys role / status / plan / step_index.
 *   2. Endpoint 404: fetchChain throws when the server returns 404.
 *   3. Role sequence: roles = ["analyst","tech-lead"]*(rework_n+1) ++ execution_roles.
 *   4. Active-index: exactly one "active" step; before → "done", after → "pending".
 *      States tested: needs-plan, plan-review, approved / in-progress, review.
 *   5. RoleChain renders for needs-plan and plan-review states.
 *   6. PipelineView renders and the active-step node has the highlight class.
 *   7. Rework-cycle count: tech-lead count == rework_n + 1 in PipelineView.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { fetchChain, config, type ChainStep } from '../api'
import { RoleChain, PipelineView } from '../App'

// ── Global fetch mock ────────────────────────────────────────────────────────
const mockFetch = vi.fn()
vi.stubGlobal('fetch', mockFetch)

function makeOk(data: unknown) {
  mockFetch.mockResolvedValue({
    ok: true,
    status: 200,
    json: async () => data,
    text: async () => JSON.stringify(data),
  })
}

function makeErr(status: number) {
  mockFetch.mockResolvedValue({
    ok: false,
    status,
    json: async () => ({ error: 'not found' }),
    text: async () => '',
  })
}

beforeEach(() => vi.clearAllMocks())

// ── Pure synthesis helper (mirrors Python build_chain) ────────────────────────
/** Mirrors the active_index formula from crewboss-api.py / build_chain. */
function computeActiveIndex(
  st: string,
  reworkN: number,
  executionRolesLen: number
): number {
  if (st === 'done') return -1 // all done, no active
  if (['needs-plan', 'needs-analysis', 'open'].includes(st)) return reworkN * 2
  if (st === 'plan-review') return reworkN * 2 + 1
  if (['approved', 'in-progress'].includes(st)) return (reworkN + 1) * 2
  if (st === 'review') return (reworkN + 1) * 2 + Math.max(executionRolesLen - 1, 0)
  return reworkN * 2 // held / blocked / unknown → analyst slot
}

/** Produce a ChainStep[] matching the backend formula. */
function buildChain(
  st: string,
  reworkN: number,
  executionRoles: string[],
  plan = ''
): ChainStep[] {
  const convergence: string[] = []
  for (let i = 0; i <= reworkN; i++) {
    convergence.push('analyst', 'tech-lead')
  }
  const allRoles = [...convergence, ...executionRoles]
  const ai = computeActiveIndex(st, reworkN, executionRoles.length)

  return allRoles.map((role, i) => ({
    role,
    status:
      st === 'done'
        ? 'done'
        : i < ai
        ? 'done'
        : i === ai
        ? 'active'
        : 'pending',
    plan,
    step_index: i,
  }))
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Endpoint happy path
// ─────────────────────────────────────────────────────────────────────────────
describe('fetchChain — happy path', () => {
  const SAMPLE_CHAIN: ChainStep[] = [
    { role: 'analyst', status: 'done', plan: 'step plan', step_index: 0 },
    { role: 'tech-lead', status: 'active', plan: 'step plan', step_index: 1 },
    { role: 'executor', status: 'pending', plan: 'step plan', step_index: 2 },
  ]

  it('returns an array of steps', async () => {
    makeOk(SAMPLE_CHAIN)
    const chain = await fetchChain(306)
    expect(Array.isArray(chain)).toBe(true)
    expect(chain.length).toBeGreaterThan(0)
  })

  it('every step has role / status / plan / step_index', async () => {
    makeOk(SAMPLE_CHAIN)
    const chain = await fetchChain(306)
    for (const step of chain) {
      expect(step).toHaveProperty('role')
      expect(step).toHaveProperty('status')
      expect(step).toHaveProperty('plan')
      expect(step).toHaveProperty('step_index')
    }
  })

  it('calls the correct endpoint URL', async () => {
    makeOk(SAMPLE_CHAIN)
    await fetchChain(42)
    const [url] = mockFetch.mock.calls[0] as [string, RequestInit]
    expect(url).toBe(config.url + '/api/chain/42')
  })

  it('sends Authorization header', async () => {
    makeOk(SAMPLE_CHAIN)
    await fetchChain(1)
    const [, opts] = mockFetch.mock.calls[0] as [string, RequestInit]
    expect((opts.headers as Record<string, string>)['Authorization']).toBe(
      'Bearer ' + config.token
    )
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 2. Endpoint 404
// ─────────────────────────────────────────────────────────────────────────────
describe('fetchChain — 404', () => {
  it('throws when server returns 404', async () => {
    makeErr(404)
    await expect(fetchChain(99999999)).rejects.toThrow('fetchChain failed: 404')
  })

  it('throws when server returns 500', async () => {
    makeErr(500)
    await expect(fetchChain(99999999)).rejects.toThrow('fetchChain failed: 500')
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 3. Role sequence assertion
// ─────────────────────────────────────────────────────────────────────────────
describe('role sequence', () => {
  const EXEC = ['executor', 'qa-engineer', 'reviewer']

  it('rework_n=0: sequence = [analyst,tech-lead] + execution_roles', () => {
    const chain = buildChain('approved', 0, EXEC)
    const roles = chain.map((s) => s.role)
    expect(roles).toEqual(['analyst', 'tech-lead', ...EXEC])
  })

  it('rework_n=1: sequence = [analyst,tech-lead]*2 + execution_roles', () => {
    const chain = buildChain('approved', 1, EXEC)
    const roles = chain.map((s) => s.role)
    expect(roles).toEqual([
      'analyst', 'tech-lead',
      'analyst', 'tech-lead',
      ...EXEC,
    ])
  })

  it('rework_n=2: sequence = [analyst,tech-lead]*3 + execution_roles', () => {
    const chain = buildChain('approved', 2, EXEC)
    const roles = chain.map((s) => s.role)
    expect(roles).toEqual([
      'analyst', 'tech-lead',
      'analyst', 'tech-lead',
      'analyst', 'tech-lead',
      ...EXEC,
    ])
  })

  it('convergence prefix length is (rework_n+1)*2', () => {
    for (const rn of [0, 1, 2]) {
      const chain = buildChain('needs-plan', rn, EXEC)
      const prefix = chain.slice(0, (rn + 1) * 2).map((s) => s.role)
      const expected = Array.from({ length: rn + 1 }).flatMap(() => ['analyst', 'tech-lead'])
      expect(prefix).toEqual(expected)
    }
  })

  it('step_index values are 0-based sequential', () => {
    const chain = buildChain('approved', 0, EXEC)
    chain.forEach((s, i) => expect(s.step_index).toBe(i))
  })

  it('fetchChain: roles from mocked API match expected sequence (rework_n=0)', async () => {
    const expected = buildChain('approved', 0, EXEC)
    makeOk(expected)
    const chain = await fetchChain(306)
    expect(chain.map((s) => s.role)).toEqual(['analyst', 'tech-lead', ...EXEC])
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 4. Active-index assertion
// ─────────────────────────────────────────────────────────────────────────────
describe('active-index — exactly one active step, done before it, pending after', () => {
  const EXEC = ['executor', 'qa-engineer', 'reviewer']

  function assertActiveInvariant(st: string, reworkN: number) {
    const chain = buildChain(st, reworkN, EXEC)
    if (st === 'done') {
      expect(chain.every((s) => s.status === 'done')).toBe(true)
      return
    }
    const activeSteps = chain.filter((s) => s.status === 'active')
    expect(activeSteps).toHaveLength(1)
    const ai = activeSteps[0].step_index
    const before = chain.filter((s) => s.step_index < ai)
    const after = chain.filter((s) => s.step_index > ai)
    expect(before.every((s) => s.status === 'done')).toBe(true)
    expect(after.every((s) => s.status === 'pending')).toBe(true)
  }

  it('needs-plan, rework_n=0: analyst (idx 0) is active', () => {
    assertActiveInvariant('needs-plan', 0)
    const chain = buildChain('needs-plan', 0, EXEC)
    expect(chain[0]).toMatchObject({ role: 'analyst', status: 'active' })
  })

  it('plan-review, rework_n=0: tech-lead (idx 1) is active', () => {
    assertActiveInvariant('plan-review', 0)
    const chain = buildChain('plan-review', 0, EXEC)
    expect(chain[1]).toMatchObject({ role: 'tech-lead', status: 'active' })
  })

  it('approved, rework_n=0: first execution role (idx 2) is active', () => {
    assertActiveInvariant('approved', 0)
    const chain = buildChain('approved', 0, EXEC)
    expect(chain[2]).toMatchObject({ role: 'executor', status: 'active' })
  })

  it('in-progress, rework_n=0: first execution role is active', () => {
    assertActiveInvariant('in-progress', 0)
    const chain = buildChain('in-progress', 0, EXEC)
    expect(chain[2]).toMatchObject({ role: 'executor', status: 'active' })
  })

  it('review, rework_n=0: last execution role is active', () => {
    assertActiveInvariant('review', 0)
    const chain = buildChain('review', 0, EXEC)
    // active_index = (0+1)*2 + (3-1) = 4  → reviewer
    expect(chain[4]).toMatchObject({ role: 'reviewer', status: 'active' })
  })

  it('done: all steps are done', () => {
    const chain = buildChain('done', 0, EXEC)
    expect(chain.every((s) => s.status === 'done')).toBe(true)
  })

  it('needs-plan, rework_n=1: second analyst (idx 2) is active', () => {
    assertActiveInvariant('needs-plan', 1)
    const chain = buildChain('needs-plan', 1, EXEC)
    // active_index = 1*2 = 2 → second analyst
    expect(chain[2]).toMatchObject({ role: 'analyst', status: 'active' })
  })

  it('plan-review, rework_n=1: second tech-lead (idx 3) is active', () => {
    assertActiveInvariant('plan-review', 1)
    const chain = buildChain('plan-review', 1, EXEC)
    expect(chain[3]).toMatchObject({ role: 'tech-lead', status: 'active' })
  })

  it('review, rework_n=1: last execution role is still active', () => {
    assertActiveInvariant('review', 1)
    const chain = buildChain('review', 1, EXEC)
    // active_index = (1+1)*2 + (3-1) = 4+2 = 6 → reviewer (index 6 in 8-step chain)
    expect(chain[6]).toMatchObject({ role: 'reviewer', status: 'active' })
  })

  it('invariant holds across all states', () => {
    const states = ['needs-plan', 'plan-review', 'approved', 'in-progress', 'review', 'done']
    for (const st of states) {
      assertActiveInvariant(st, 0)
    }
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 5. RoleChain renders for pre-approval states
// ─────────────────────────────────────────────────────────────────────────────
describe('RoleChain component rendering', () => {
  it('renders role-chain container for needs-plan state', async () => {
    const chain = buildChain('needs-plan', 0, ['executor', 'qa-engineer'])
    makeOk(chain)
    render(<RoleChain n={1} />)
    await waitFor(() => {
      expect(screen.getByTestId('role-chain')).toBeTruthy()
    })
  })

  it('renders role-chain container for plan-review state', async () => {
    const chain = buildChain('plan-review', 0, ['executor'])
    makeOk(chain)
    render(<RoleChain n={2} />)
    await waitFor(() => {
      expect(screen.getByTestId('role-chain')).toBeTruthy()
    })
  })

  it('renders one node per chain step', async () => {
    const chain = buildChain('needs-plan', 0, ['executor', 'qa-engineer'])
    makeOk(chain)
    render(<RoleChain n={3} />)
    await waitFor(() => {
      const nodes = document.querySelectorAll('.role-chain-node')
      expect(nodes.length).toBe(chain.length)
    })
  })

  it('node labels match the role names in order', async () => {
    const chain = buildChain('plan-review', 0, ['executor'])
    makeOk(chain)
    render(<RoleChain n={4} />)
    await waitFor(() => {
      const labels = Array.from(document.querySelectorAll('.role-chain-label')).map(
        (el) => el.textContent
      )
      expect(labels).toEqual(chain.map((s) => s.role))
    })
  })

  it('shows empty placeholder when chain is empty', async () => {
    makeOk([])
    render(<RoleChain n={5} />)
    await waitFor(() => {
      expect(screen.getByText(/нет данных о цепочке ролей/)).toBeTruthy()
    })
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 6. PipelineView renders and active step has highlight class
// ─────────────────────────────────────────────────────────────────────────────
describe('PipelineView component rendering', () => {
  it('renders pipeline-view container for approved state', async () => {
    const chain = buildChain('approved', 0, ['executor', 'qa-engineer'])
    makeOk(chain)
    render(<PipelineView n={10} />)
    await waitFor(() => {
      expect(screen.getByTestId('pipeline-view')).toBeTruthy()
    })
  })

  it('renders one step-wrap per chain step', async () => {
    const chain = buildChain('approved', 0, ['executor', 'qa-engineer'])
    makeOk(chain)
    render(<PipelineView n={11} />)
    await waitFor(() => {
      const wraps = document.querySelectorAll('.pipeline-step-wrap')
      expect(wraps.length).toBe(chain.length)
    })
  })

  it('active step has pipeline-step--active class', async () => {
    const chain = buildChain('approved', 0, ['executor', 'qa-engineer'])
    makeOk(chain)
    render(<PipelineView n={12} />)
    await waitFor(() => {
      const active = document.querySelectorAll('.pipeline-step--active')
      expect(active.length).toBe(1)
    })
  })

  it('done steps have pipeline-step--done class, pending have pipeline-step--pending', async () => {
    const chain = buildChain('approved', 0, ['executor', 'qa-engineer'])
    makeOk(chain)
    render(<PipelineView n={13} />)
    await waitFor(() => {
      const doneSteps = document.querySelectorAll('.pipeline-step--done')
      const pendingSteps = document.querySelectorAll('.pipeline-step--pending')
      const activeSteps = document.querySelectorAll('.pipeline-step--active')
      const expectedDone = chain.filter((s) => s.status === 'done').length
      const expectedPending = chain.filter((s) => s.status === 'pending').length
      expect(doneSteps.length).toBe(expectedDone)
      expect(pendingSteps.length).toBe(expectedPending)
      expect(activeSteps.length).toBe(1)
    })
  })

  it('active-step dot has pipeline-dot--active class', async () => {
    const chain = buildChain('in-progress', 0, ['executor'])
    makeOk(chain)
    render(<PipelineView n={14} />)
    await waitFor(() => {
      expect(document.querySelector('.pipeline-dot--active')).toBeTruthy()
    })
  })

  it('shows empty placeholder when chain is empty', async () => {
    makeOk([])
    render(<PipelineView n={15} />)
    await waitFor(() => {
      expect(screen.getByText(/нет данных о пайплайне/)).toBeTruthy()
    })
  })

  it('review state: last execution role step is active', async () => {
    const execRoles = ['executor', 'qa-engineer', 'reviewer']
    const chain = buildChain('review', 0, execRoles)
    makeOk(chain)
    render(<PipelineView n={16} />)
    await waitFor(() => {
      const steps = Array.from(document.querySelectorAll('.pipeline-step'))
      const activeIdx = steps.findIndex((s) => s.classList.contains('pipeline-step--active'))
      // active_index = (0+1)*2 + (3-1) = 4 → reviewer
      expect(chain[activeIdx].role).toBe('reviewer')
    })
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// 7. Rework-cycle count assertion
// ─────────────────────────────────────────────────────────────────────────────
describe('rework-cycle count in PipelineView', () => {
  it('rework_n=1: exactly 2 tech-lead nodes in pipeline', async () => {
    const chain = buildChain('approved', 1, ['executor'])
    makeOk(chain)
    render(<PipelineView n={20} />)
    await waitFor(() => {
      const labels = Array.from(document.querySelectorAll('.pipeline-step-role')).map(
        (el) => el.textContent
      )
      const techLeadCount = labels.filter((l) => l === 'tech-lead').length
      expect(techLeadCount).toBe(2) // rework_n + 1 = 1 + 1 = 2
    })
  })

  it('rework_n=2: exactly 3 tech-lead nodes in pipeline', async () => {
    const chain = buildChain('approved', 2, ['executor'])
    makeOk(chain)
    render(<PipelineView n={21} />)
    await waitFor(() => {
      const labels = Array.from(document.querySelectorAll('.pipeline-step-role')).map(
        (el) => el.textContent
      )
      const techLeadCount = labels.filter((l) => l === 'tech-lead').length
      expect(techLeadCount).toBe(3) // rework_n + 1 = 2 + 1 = 3
    })
  })

  it('convergence prefix matches ["analyst","tech-lead"]*(rework_n+1) for rework_n=1', async () => {
    const chain = buildChain('approved', 1, ['executor'])
    makeOk(chain)
    render(<PipelineView n={22} />)
    await waitFor(() => {
      const allLabels = Array.from(document.querySelectorAll('.pipeline-step-role')).map(
        (el) => el.textContent ?? ''
      )
      // rework_n=1 → prefix = ['analyst','tech-lead','analyst','tech-lead']
      expect(allLabels.slice(0, 4)).toEqual([
        'analyst', 'tech-lead',
        'analyst', 'tech-lead',
      ])
    })
  })

  it('rework_n=0: exactly 1 tech-lead node in pipeline', async () => {
    const chain = buildChain('approved', 0, ['executor', 'qa-engineer'])
    makeOk(chain)
    render(<PipelineView n={23} />)
    await waitFor(() => {
      const labels = Array.from(document.querySelectorAll('.pipeline-step-role')).map(
        (el) => el.textContent
      )
      const techLeadCount = labels.filter((l) => l === 'tech-lead').length
      expect(techLeadCount).toBe(1) // rework_n + 1 = 0 + 1 = 1
    })
  })

  it('full chain roles for rework_n=1 match expected sequence', () => {
    const execRoles = ['executor', 'qa-engineer']
    const chain = buildChain('approved', 1, execRoles)
    const roles = chain.map((s) => s.role)
    expect(roles).toEqual([
      'analyst', 'tech-lead',
      'analyst', 'tech-lead',
      'executor', 'qa-engineer',
    ])
  })

  it('rework_n=1 review: active step is the last execution role', () => {
    const execRoles = ['executor', 'qa-engineer']
    const chain = buildChain('review', 1, execRoles)
    // active_index = (1+1)*2 + (2-1) = 4+1 = 5 → qa-engineer
    const activeStep = chain.find((s) => s.status === 'active')
    expect(activeStep?.role).toBe('qa-engineer')
    expect(activeStep?.step_index).toBe(5)
  })
})
