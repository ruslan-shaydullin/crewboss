/**
 * phantom-agents.test.ts — unit tests for phantom-merging fix (#737, charter #718)
 *
 * Tests the running-agent counter contract (Hero component, App.tsx line 275).
 *
 * Current (broken) filter:  a.phase !== 'awaiting'
 *   → counts synthetic integrator chips (pid=null, phase='merging') as "running agents"
 *   → 31 review-leaves inflate running counter by 31
 *
 * New (correct) filter:     a.pid != null
 *   → excludes all synthetic chips (pid=null/undefined regardless of phase)
 *   → only real agent processes (with numeric pid) count as running
 *
 * These tests validate the NEW filter spec in isolation (no React rendering required).
 * The tsx-fix leaf (#739) applies the filter change to App.tsx line 275.
 */

import { describe, it, expect } from 'vitest'
import type { Agent } from './api'

// ---------------------------------------------------------------------------
// Helpers mirroring Hero component filter logic
// ---------------------------------------------------------------------------

/** OLD (broken) filter: phase !== 'awaiting' — counts phantom merging chips */
function runningOldFilter(agents: Agent[]): number {
  return agents.filter((a) => a.phase !== 'awaiting').length
}

/** NEW (correct) filter: pid != null — excludes all synthetic chips */
function runningNewFilter(agents: Agent[]): number {
  return agents.filter((a) => a.pid != null).length
}

/** Build a synthetic integrator chip (pid=undefined/null, as built by build_agents()) */
function syntheticIntegrator(phase: string, task: number): Agent {
  return { task, role: 'integrator', phase, title: `Leaf ${task}`, started: '' }
  // Note: no pid field → pid=undefined → treated as null by != null check
}

/** Build a real agent (pid set to a numeric value) */
function realAgent(pid: number, role: string, phase: string): Agent {
  return { task: null, pid, role, phase, title: role, started: '' }
}

// ---------------------------------------------------------------------------
// Test 1: Phantom merging — 31 synthetic chips, loop_running=True
//   New filter: running=0  (correct — no real processes)
//   Old filter: running=31 (wrong — counted phantom chips with phase='merging')
// ---------------------------------------------------------------------------
describe('phantom-merging: 31 synthetic integrator chips (pid=null)', () => {
  const agents31: Agent[] = Array.from({ length: 31 }, (_, i) =>
    syntheticIntegrator('merging', i + 1)
  )

  it('new filter (pid!=null): running=0 for 31 merging synthetic chips', () => {
    expect(runningNewFilter(agents31)).toBe(0)
  })

  it('old filter (phase!="awaiting"): running=31 — documents the regression', () => {
    // Old filter over-counts: 'merging' !== 'awaiting' → counted as running
    expect(runningOldFilter(agents31)).toBe(31)
  })

  it('new filter correctly excludes all pid=undefined agents', () => {
    const result = agents31.filter((a) => a.pid != null)
    expect(result).toHaveLength(0)
  })
})

// ---------------------------------------------------------------------------
// Test 2: awaiting-integration phase (new phase string post-#738)
//   Both old and new filters handle the new phase correctly:
//   - new filter: pid=null → excluded (running=0) ✓
//   - old filter: 'awaiting-integration' !== 'awaiting' → STILL counted (running=31) ✗
// ---------------------------------------------------------------------------
describe('awaiting-integration phase (post python-fix #738)', () => {
  const agents31ai: Agent[] = Array.from({ length: 31 }, (_, i) =>
    syntheticIntegrator('awaiting-integration', i + 1)
  )

  it('new filter (pid!=null): running=0 for 31 awaiting-integration chips', () => {
    expect(runningNewFilter(agents31ai)).toBe(0)
  })

  it('old filter (phase!="awaiting"): still over-counts awaiting-integration as running', () => {
    // Even after #738, old filter still wrong: 'awaiting-integration' !== 'awaiting'
    expect(runningOldFilter(agents31ai)).toBe(31)
  })
})

// ---------------------------------------------------------------------------
// Test 3: Real agents with numeric pid must still be counted
//   Regression guard: new filter must not exclude real agents.
// ---------------------------------------------------------------------------
describe('real agents with numeric pid must be counted', () => {
  it('single real agent (pid=1234): new filter running=1', () => {
    const agents = [realAgent(1234, 'executor', 'running')]
    expect(runningNewFilter(agents)).toBe(1)
  })

  it('mixed: 31 synthetic + 3 real → new filter running=3', () => {
    const synthetic = Array.from({ length: 31 }, (_, i) =>
      syntheticIntegrator('awaiting-integration', i + 1)
    )
    const real = [
      realAgent(100, 'executor', 'running'),
      realAgent(200, 'executor', 'running'),
      realAgent(300, 'reviewer', 'running'),
    ]
    const agents = [...synthetic, ...real]
    expect(runningNewFilter(agents)).toBe(3)
  })

  it('old filter also counts real agents (no regression on real-agent counting)', () => {
    const agents = [realAgent(1234, 'executor', 'running')]
    // Old filter: 'running' !== 'awaiting' → counted
    expect(runningOldFilter(agents)).toBe(1)
  })

  it('pid=0 (falsy but numeric) is treated as null by != check', () => {
    // pid=0 is falsy, so != null returns true (0 != null is true in JS/TS)
    // This edge case: a real process with pid=0 would be counted correctly
    const agent: Agent = { task: null, pid: 0, role: 'launcher', phase: 'running', title: '', started: '' }
    // pid=0 != null → true → counted (pid=0 is a valid non-null value)
    expect(agent.pid != null).toBe(true)
  })
})

// ---------------------------------------------------------------------------
// Test 4: Selftest gate — build_agents() loop_running=False contract
//   loop_running=False must produce phase='awaiting' for all synthetic chips
//   (both before and after python-fix #738, this is the stable contract).
// ---------------------------------------------------------------------------
describe('loop_running=False: all synthetic chips awaiting (stable contract)', () => {
  it('awaiting chips are excluded by both filters (pid=null AND phase="awaiting")', () => {
    const agent = syntheticIntegrator('awaiting', 1)
    expect(runningNewFilter([agent])).toBe(0)  // pid=null → excluded ✓
    expect(runningOldFilter([agent])).toBe(0)  // phase='awaiting' → excluded ✓
  })
})

// ---------------------------------------------------------------------------
// Test 5: State with null/undefined agents array (defensive)
// ---------------------------------------------------------------------------
describe('null/undefined state edge cases', () => {
  it('null state: running=0 (via optional chaining)', () => {
    const state = null as { agents?: Agent[] } | null
    const running = state?.agents?.filter((a: Agent) => a.pid != null).length ?? 0
    expect(running).toBe(0)
  })

  it('no agents field: running=0 (via optional chaining)', () => {
    const state = { board: [] } as { agents?: Agent[] }
    const running = state?.agents?.filter((a: Agent) => a.pid != null).length ?? 0
    expect(running).toBe(0)
  })

  it('empty agents array: running=0', () => {
    const state = { agents: [] as Agent[] }
    const running = state?.agents?.filter((a: Agent) => a.pid != null).length ?? 0
    expect(running).toBe(0)
  })
})
