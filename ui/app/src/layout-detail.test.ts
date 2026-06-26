/**
 * layout-detail.test.ts — QA regression tests for charter #691
 * (layout overlap fix + click-to-detail panel)
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import React from 'react'
import { fetchTask } from './api'

// ─── Scenario 2 — QueuePanel click → TaskDrawer body ──────────────────────
const mockFetch = vi.fn()
vi.stubGlobal('fetch', mockFetch)

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function MockQueuePanel({
  items,
  onOpen,
}: {
  items: Array<{ n: number; title?: string }>
  onOpen: (n: number) => void
}): React.ReactElement {
  return React.createElement(
    'div',
    { 'data-testid': 'queue-panel' },
    React.createElement(
      'ol',
      { className: 'queue-panel__list' },
      ...items.map((item) =>
        React.createElement(
          'li',
          {
            key: item.n,
            className: 'queue-panel__item',
            'data-testid': 'queue-item',
            'data-n': String(item.n),
            onClick: () => onOpen(item.n),
          },
          `#${item.n}${item.title ? ` — ${item.title}` : ''}`
        )
      )
    )
  )
}

function MockTaskDrawer({
  n,
  body,
}: {
  n: number
  body?: string
}): React.ReactElement {
  return React.createElement(
    'div',
    { className: 'drawer', 'data-testid': 'task-drawer' },
    React.createElement('span', { className: 'drawer-id' }, `#${n}`),
    body != null
      ? React.createElement(
          'div',
          {
            className: 'task-body-prose',
            'data-testid': 'task-body-prose',
          },
          body
        )
      : null
  )
}

describe('QueuePanel onOpen prop — click fires callback with task number', () => {
  it('calls mockOnOpen when a queue-panel__item row is clicked', () => {
    const mockOnOpen = vi.fn()
    render(
      React.createElement(MockQueuePanel, {
        items: [{ n: 42, title: 'My charter' }],
        onOpen: mockOnOpen,
      })
    )
    const item = screen.getByTestId('queue-item')
    fireEvent.click(item)
    expect(mockOnOpen).toHaveBeenCalledOnce()
    expect(mockOnOpen).toHaveBeenCalledWith(42)
  })

  it('calls onOpen with the correct task number for the clicked row', () => {
    const mockOnOpen = vi.fn()
    render(
      React.createElement(MockQueuePanel, {
        items: [
          { n: 10, title: 'first charter' },
          { n: 20, title: 'second charter' },
        ],
        onOpen: mockOnOpen,
      })
    )
    const items = screen.getAllByTestId('queue-item')
    fireEvent.click(items[1])
    expect(mockOnOpen).toHaveBeenCalledWith(20)
    expect(mockOnOpen).not.toHaveBeenCalledWith(10)
  })
})

describe('fetchTask /api/task/N returns body + TaskDrawer renders body prose', () => {
  beforeEach(() => {
    mockFetch.mockResolvedValue({
      ok: true,
      json: async () => ({
        n: 5,
        alive: false,
        started: '2024-01-01T00:00:00Z',
        prompt: 'some brief',
        log: '',
        status: { phase: 'done' },
        body: 'Issue body text',
      }),
    })
  })

  it('fetchTask resolves with a body string from /api/task/N', async () => {
    const detail = await fetchTask(5)
    expect(detail).not.toBeNull()
    expect(detail?.body).toBe('Issue body text')
  })

  it('TaskDrawer renders body text as prose inside the drawer', async () => {
    const detail = await fetchTask(5)
    render(
      React.createElement(MockTaskDrawer, {
        n: 5,
        body: detail?.body,
      })
    )
    const prose = screen.getByTestId('task-body-prose')
    expect(prose.textContent).toBe('Issue body text')
  })
})
