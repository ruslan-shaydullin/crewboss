import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

describe('credential-free local demo', () => {
  beforeEach(() => {
    vi.resetModules()
    vi.stubEnv('VITE_CREWBOSS_DEMO', '1')
    vi.stubGlobal('fetch', vi.fn(() => { throw new Error('Demo attempted a network request') }))
    localStorage.clear()
  })
  afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.resetModules() })

  it('runs the live API adapter interface without network or credentials', async () => {
    const api = await import('./api')
    const team = await import('./team')
    expect(api.config.token).toBe('')
    expect((await api.fetchState())?.autonomy.repo).toBe('demo/crewboss-alpha')
    expect((await api.fetchTask(103))?.body).toContain('local sample data')
    expect((await api.searchBoard('portable'))?.map(item => item.n)).toEqual([102])
    expect((await team.fetchTeam()).nodes.length).toBeGreaterThan(3)
    expect((await team.fetchRole('executor'))?.ok).toBe(true)
    expect((await api.facilitateMessage('charter', {}, 'review this', [])).message).toContain('Local demo')
    expect(fetch).not.toHaveBeenCalled()
    expect(localStorage.getItem('cb_token')).toBeNull()
  })

  it('updates subscribed state, honors the kill switch, and resets sample data', async () => {
    const api = await import('./api')
    const { resetDemo } = await import('./demo')
    const state = vi.fn()
    const stop = api.subscribe(state, vi.fn())
    await api.command('pause')
    expect(state.mock.lastCall?.[0].flags.paused).toBe(true)
    await api.command('resume')
    expect(state.mock.lastCall?.[0].flags.paused).toBe(false)
    await api.command('kill')
    expect((await api.command('run')).ok).toBe(false)
    expect((await api.fetchState())?.loop?.running).toBe(false)
    resetDemo()
    expect(state.mock.lastCall?.[0].flags.killed).toBe(false)
    expect(state.mock.lastCall?.[0].agents).toHaveLength(2)
    stop()
    const before = state.mock.calls.length
    await api.command('pause')
    expect(state).toHaveBeenCalledTimes(before)
    expect(fetch).not.toHaveBeenCalled()
  })

  it('keeps issue, queue, comment, and team edits in the local dataset', async () => {
    const api = await import('./api')
    const team = await import('./team')
    const issue = await api.createIssue({ kind: 'charter', title: 'Demo-only work', what: 'Example', why: 'Preview' })
    expect(issue.ok).toBe(true)
    expect((await api.fetchState())?.board.find(item => item.n === issue.number)?.title).toBe('Demo-only work')
    await api.postQueue([issue.number!])
    expect((await api.fetchState())?.queue?.order).toEqual([issue.number])
    await api.command('comment', issue.number, 'Local comment')
    const comments = await api.fetchComments(issue.number!)
    expect(comments[0].body).toBe('Local comment')
    await api.deleteComment(issue.number!, comments[0].id)
    expect(await api.fetchComments(issue.number!)).toEqual([])
    const currentTeam = await team.fetchTeam()
    currentTeam.policy.span_max = 3
    expect((await team.saveTeam(currentTeam)).ok).toBe(true)
    expect((await team.fetchTeam()).policy.span_max).toBe(3)
    expect(fetch).not.toHaveBeenCalled()
  })

  it('does not forward unknown routes to a real server', async () => {
    const { apiRequest } = await import('./transport')
    const response = await apiRequest('https://provider.example/api/unknown')
    expect(response.status).toBe(404)
    expect(fetch).not.toHaveBeenCalled()
  })
})
