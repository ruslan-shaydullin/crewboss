import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { State } from './api'

const mocks = vi.hoisted(() => ({
  listeners: [] as Array<(state: State) => void>,
  stops: [] as Array<ReturnType<typeof vi.fn>>,
  postQueue: vi.fn(), command: vi.fn(), searchBoard: vi.fn(),
}))
vi.mock('./api', async importOriginal => ({
  ...await importOriginal<typeof import('./api')>(),
  subscribe: (listener: (state: State) => void) => {
    mocks.listeners.push(listener)
    const stop = vi.fn()
    mocks.stops.push(stop)
    return stop
  },
  postQueue: mocks.postQueue,
  command: mocks.command,
  searchBoard: mocks.searchBoard,
  fetchTask: async () => null,
  fetchComments: async () => [],
}))
import App from './App'
import { config } from './api'

const board = (n: number): State => ({
  board: [{ n, kind: 'charter', state: 'approved', title: `Repository task ${n}`, labels: [] }],
  agents: [], budget: { spent: 0, cap: 100, runs: [] },
  flags: { paused: false, killed: false }, autonomy: { repo: `fixture/repository-${n}` },
  queue: { order: [n] }, loop: { running: false, integrate: false, max_ticks: 10, max_parallel: 1, stage: 'idle' },
})

beforeEach(() => {
  localStorage.clear()
  mocks.listeners.length = 0; mocks.stops.length = 0
  mocks.postQueue.mockReset(); mocks.command.mockReset(); mocks.searchBoard.mockReset()
  mocks.command.mockResolvedValue({ ok: true })
  vi.stubGlobal('matchMedia', () => ({ matches: true }))
  config.url = 'http://old.example'; config.token = 'old-fixture'
})
afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.useRealTimers(); localStorage.clear() })

function reconnect() {
  fireEvent.click(screen.getByRole('button', { name: 'settings' }))
  fireEvent.change(screen.getByLabelText('API URL'), { target: { value: 'http://new.example' } })
  fireEvent.change(screen.getByLabelText('API token'), { target: { value: 'new-fixture' } })
  fireEvent.click(screen.getByRole('button', { name: 'Save & reconnect' }))
}

it('discards a dirty queue and prevents its pending launch from reaching a new connection', async () => {
  let finishSave!: () => void
  mocks.postQueue.mockImplementation(() => new Promise<void>(resolve => { finishSave = resolve }))
  render(<App />)
  act(() => mocks.listeners[0](board(41)))
  fireEvent.click(screen.getByTestId('queue-launch-btn'))
  expect(mocks.postQueue).toHaveBeenCalledWith([41])
  fireEvent.click(screen.getByTestId('queue-item'))
  reconnect()
  expect(mocks.stops[0]).toHaveBeenCalledOnce()
  act(() => mocks.listeners[1](board(77)))
  await act(async () => { finishSave(); await Promise.resolve() })
  act(() => mocks.listeners[0](board(41)))
  expect(screen.getAllByTestId('queue-item').map(item => item.dataset.n)).toEqual(['77'])
  expect(mocks.command).not.toHaveBeenCalled()
  expect(config.url).toBe('http://new.example')
  expect(config.token).toBe('new-fixture')
  expect(document.querySelector('.drawer-bg')).toBeNull()
})

it('clears search and confirmation and ignores delayed search results after reconnect', async () => {
  vi.useFakeTimers()
  let finishSearch!: (value: State['board']) => void
  mocks.searchBoard.mockImplementation(() => new Promise(resolve => { finishSearch = resolve }))
  render(<App />)
  act(() => mocks.listeners[0](board(41)))
  fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'old query' } })
  await act(async () => { await vi.advanceTimersByTimeAsync(300) })
  fireEvent.click(screen.getByRole('button', { name: '▶ Run' }))
  expect(screen.getByText('Run launcher')).toBeInTheDocument()
  reconnect()
  act(() => mocks.listeners[1](board(77)))
  await act(async () => { finishSearch(board(41).board); await Promise.resolve() })
  expect(screen.getByRole('searchbox')).toHaveValue('')
  expect(screen.queryByText('Run launcher')).toBeNull()
  expect(screen.queryByText('Repository task 41')).toBeNull()
  expect(mocks.command).not.toHaveBeenCalled()
})
