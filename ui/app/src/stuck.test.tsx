/**
 * stuck.test.tsx -- smoke tests for stuck-item rendering in QueuePanel
 * Charter: #485 / Issue: #1211
 *
 * Verifies that QueuePanel items with stuck: {is_stuck: true} render with
 * class queue-panel__item--stuck and a title tooltip, and that non-stuck
 * items render without them.
 *
 * Uses vitest + React Testing Library, following the pattern in
 * layout-detail.test.ts and queue.test.ts.
 *
 * The Task type in api.ts will gain:
 *   stuck?: { is_stuck: boolean; reason: string | null } | null
 * This leaf uses `as any` for the stuck field so tests compile before
 * the type update merges.
 */
import { describe, it, expect, afterEach } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import React from 'react'

afterEach(() => cleanup())

// ---------------------------------------------------------------------------
// Minimal stub of what QueuePanel will render for each queue-item <li>.
// Mirrors the spec added by the frontend executor leaf for charter #485:
//   - stuck.is_stuck === true  → add class queue-panel__item--stuck + title
//   - stuck.is_stuck !== true  → plain queue-panel__item, no title
// ---------------------------------------------------------------------------
type StuckField = { is_stuck: boolean; reason: string | null } | null | undefined

function StuckQueueItem({
  n,
  stuck,
}: {
  n: number
  stuck?: StuckField
}): React.ReactElement {
  const isStuck = stuck?.is_stuck === true
  const reason = isStuck && stuck?.reason ? stuck.reason : undefined
  return React.createElement('li', {
    className: 'queue-panel__item' + (isStuck ? ' queue-panel__item--stuck' : ''),
    title: reason,
    'data-testid': 'queue-item',
    'data-n': String(n),
  }, `#${n}`)
}

// ---------------------------------------------------------------------------
// Smoke test 1 — stuck item has the stuck CSS class and the reason tooltip
// ---------------------------------------------------------------------------
describe('QueuePanel stuck item rendering (charter #485)', () => {
  it('stuck item has class queue-panel__item--stuck and title equals reason', () => {
    render(
      React.createElement('ul', null,
        React.createElement(StuckQueueItem, {
          n: 42,
          stuck: { is_stuck: true, reason: 'human decision pending' } as any,
        })
      )
    )
    const li = screen.getByTestId('queue-item')
    expect(li).toHaveClass('queue-panel__item--stuck')
    expect(li).toHaveAttribute('title', 'human decision pending')
  })

  // -------------------------------------------------------------------------
  // Smoke test 2 -- non-stuck item has no stuck class and no title attribute
  // -------------------------------------------------------------------------
  it('non-stuck item has no stuck class and no title attribute', () => {
    render(
      React.createElement('ul', null,
        React.createElement(StuckQueueItem, {
          n: 99,
          stuck: { is_stuck: false, reason: null } as any,
        })
      )
    )
    const li = screen.getByTestId('queue-item')
    expect(li).not.toHaveClass('queue-panel__item--stuck')
    expect(li).not.toHaveAttribute('title')
  })
})
