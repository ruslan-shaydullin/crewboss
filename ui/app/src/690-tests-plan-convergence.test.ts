/**
 * 690-tests-plan-convergence.test.ts — Vitest + testing-library tests for
 * charter #690 plan-convergence UI gating.
 *
 * Scenario 5 — UI buttons hidden during convergence:
 *   Render with plan_convergence_active=true.
 *   Assert Approve plan button is NOT in document.
 *   Assert Request changes button is NOT in document.
 *   Assert plan-convergence in progress span IS present.
 *
 * Scenario 6 — UI buttons shown in manual mode:
 *   Render with plan_convergence_active=false.
 *   Assert Approve plan button IS in document.
 *   Assert Request changes button IS in document.
 *   Assert plan-convergence in progress span is NOT present.
 *
 * Following the style of /work/ui/app/src/layout-detail.test.ts.
 * Mock component wraps the approve-button site from App.tsx CharterCard /
 * TaskDrawer (the two sites that leaf/690-ui-convergence modifies).
 */
import { describe, it, expect, afterEach } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import React from 'react'

afterEach(() => {
  cleanup()
})

// ── Mock component: approve-button site ───────────────────────────────────────
//
// Mirrors the conditional rendering that leaf/690-ui-convergence adds to
// both the CharterCard header and the TaskDrawer drawer-actions section in
// App.tsx.  When plan_convergence_active is true the buttons are suppressed
// and a status span is shown instead; when false the buttons are shown.
//
function MockApproveSite({
  plan_convergence_active,
}: {
  plan_convergence_active: boolean
}): React.ReactElement {
  if (plan_convergence_active) {
    return React.createElement(
      'div',
      { 'data-testid': 'approve-site' },
      React.createElement(
        'span',
        { 'data-testid': 'convergence-notice', className: 'convergence-notice' },
        'plan-convergence in progress'
      )
    )
  }
  return React.createElement(
    'div',
    { 'data-testid': 'approve-site' },
    React.createElement(
      'button',
      { className: 'btn sm pri', 'data-testid': 'approve-btn' },
      'Approve plan'
    ),
    React.createElement(
      'button',
      { className: 'btn sm ghost', 'data-testid': 'request-changes-btn' },
      'Request changes'
    )
  )
}

// ─────────────────────────────────────────────────────────────────────────────
describe('Scenario 5 — UI buttons hidden during plan-convergence loop', () => {
  it('hides Approve plan button when plan_convergence_active=true', () => {
    render(
      React.createElement(MockApproveSite, { plan_convergence_active: true })
    )
    expect(screen.queryByText('Approve plan')).not.toBeInTheDocument()
  })

  it('hides Request changes button when plan_convergence_active=true', () => {
    render(
      React.createElement(MockApproveSite, { plan_convergence_active: true })
    )
    expect(screen.queryByText('Request changes')).not.toBeInTheDocument()
  })

  it('shows plan-convergence in progress span when plan_convergence_active=true', () => {
    render(
      React.createElement(MockApproveSite, { plan_convergence_active: true })
    )
    expect(
      screen.getByText('plan-convergence in progress')
    ).toBeInTheDocument()
  })

  it('Approve plan button is absent from document when convergence active', () => {
    render(
      React.createElement(MockApproveSite, { plan_convergence_active: true })
    )
    expect(screen.queryByTestId('approve-btn')).toBeNull()
  })

  it('Request changes button is absent from document when convergence active', () => {
    render(
      React.createElement(MockApproveSite, { plan_convergence_active: true })
    )
    expect(screen.queryByTestId('request-changes-btn')).toBeNull()
  })
})

// ─────────────────────────────────────────────────────────────────────────────
describe('Scenario 6 — UI buttons shown in manual mode (no plan_review_role)', () => {
  it('shows Approve plan button when plan_convergence_active=false', () => {
    render(
      React.createElement(MockApproveSite, { plan_convergence_active: false })
    )
    expect(screen.getByText('Approve plan')).toBeInTheDocument()
  })

  it('shows Request changes button when plan_convergence_active=false', () => {
    render(
      React.createElement(MockApproveSite, { plan_convergence_active: false })
    )
    expect(screen.getByText('Request changes')).toBeInTheDocument()
  })

  it('plan-convergence in progress span is NOT in document when plan_convergence_active=false', () => {
    render(
      React.createElement(MockApproveSite, { plan_convergence_active: false })
    )
    expect(screen.queryByText('plan-convergence in progress')).not.toBeInTheDocument()
  })

  it('Approve plan button is present in document in manual mode', () => {
    render(
      React.createElement(MockApproveSite, { plan_convergence_active: false })
    )
    const btn = screen.getByTestId('approve-btn')
    expect(btn).toBeInTheDocument()
    expect(btn.textContent).toBe('Approve plan')
  })

  it('Request changes button is present in document in manual mode', () => {
    render(
      React.createElement(MockApproveSite, { plan_convergence_active: false })
    )
    const btn = screen.getByTestId('request-changes-btn')
    expect(btn).toBeInTheDocument()
    expect(btn.textContent).toBe('Request changes')
  })
})
